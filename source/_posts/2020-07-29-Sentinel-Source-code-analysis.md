---
title: Sentinel 熔断等指标如何统计以及如何判断熔断点
date: 2020-07-29 14:14:51
category: [java]
tags: [source]
---

# Sentinel 熔断等指标如何统计以及如何判断熔断点

#### Sentinel 使用
在分析源码之前首先看下，Sentinel 如何使用
##### 建立规则
```java
        // 建立规则
        List<DegradeRule> rule = new ArrayList<DegradeRule>();
        DegradeRule ruleRatio = new DegradeRule();
        ruleRatio.setResource("sourceTest");
        ruleRatio.setCount(100);
        ruleRatio.setGrade(1);
        ruleRatio.setTimeWindow(60)
        ruleRatio.setMinRequestAmount(2);
        ruleRatio.setRtSlowRequestAmount(2);
        rules.add(ruleRatio);
        
        // 加载规则
        DegradeRuleManager.loadRules(rules);
```

##### 使用规则
```java
        Entry entry = null;
        try {
            entry = SphU.entry( "sourceTest" )
            print("Do something.");
        } catch( DegradeException degradeException ) {
            logger.error("触发熔断,熔断器：{}", JSON.toJSONString(degradeException.rule) )
            throw new DegradeException("触发熔断"+degradeException.rule.resource, degradeException)
        } catch (Exception e) {
            Tracer.trace(e)
            logger.error("有异常")
            throw e
        } finally {
            if (entry != null) {
                // 退出 Entry 并统计
                entry.exit()
            }
        }
```
从上面的代码中大致可以看出，sentinel 通过 `SphU.entry` 验证规则并开始统计，如果其中某条规则不通过将会抛出对应的异常， 通过 `entry.exit()` 结束统计。

下面进入到源码中分析具体的实现原理
![CtSph类图](https://note.youdao.com/yws/api/personal/file/1AD25B53EDBD4EDD81103BD302296467?method=download&shareKey=8ea22ed909a257924ca94194bfc76aab)

```java
    public static final Sph sph = new CtSph();
    
    public static Entry entry(String name) throws BlockException {
        return Env.sph.entry(name, EntryType.OUT, 1, OBJECTS0); // @1 -> @2
    }
    
    // @2
    // Env.sph.entry
    public Entry entry(String name, EntryType type, int count, Object... args) throws BlockException {
        // 创建一个资源名包装类
        StringResourceWrapper resource = new StringResourceWrapper(name, type);
        return entry(resource, count, args); // @3 -> @4
    }
    
    // @4
    public Entry entry(ResourceWrapper resourceWrapper, int count, Object... args) throws BlockException {
        return entryWithPriority(resourceWrapper, count, false, args); // @5 -> @6
    }
    
    // @6
    private Entry entryWithPriority(ResourceWrapper resourceWrapper, int count, boolean prioritized, Object... args)
        throws BlockException {
        // 从线程变量中获取当前上下文
        Context context = ContextUtil.getContext();
        // ... 省略部分代码
        if (context == null) {
            // Using default context.
            // 如果没有上下文，创建一个默认的上下文和一个EntranceNode
            context = InternalContextUtil.internalEnter(Constants.CONTEXT_DEFAULT_NAME);
        }

        // 如果全局开关关闭，不需要检查规则和统计
        // Global switch is close, no rule checking will do.
        if (!Constants.ON) {
            return new CtEntry(resourceWrapper, null, context);
        }

        // 找到所有的处理责任链【责任链模式】
        ProcessorSlot<Object> chain = lookProcessChain(resourceWrapper);

        /*
         * 说明责任链数量已经超出最大允许数量，后面将没有规则会被检查
         * Means amount of resources (slot chain) exceeds {@link Constants.MAX_SLOT_CHAIN_SIZE},
         * so no rule checking will be done.
         */
        if (chain == null) {
            return new CtEntry(resourceWrapper, null, context);
        }

        // 创建当前条目
        Entry e = new CtEntry(resourceWrapper, chain, context);
        try {
            // 触发责任链（从第一个开始执行到最后一个责任链节点，主要有创建节点、统计指标、验证各种规则...）
            chain.entry(context, resourceWrapper, null, count, prioritized, args);
        } catch (BlockException e1) {
            // 被阻塞后退出当前条目，并统计指标
            e.exit(count, args);
            throw e1;
        } catch (Throwable e1) {
            // This should not happen, unless there are errors existing in Sentinel internal.
            RecordLog.info("Sentinel unexpected exception", e1);
        }
        return e;
    }

    
    
```

### 责任链模式
以上 `entryWithPriority` 源码中可以 sentinel 用到了责任链模式，通过责任链创建节点、统计指标、验证规则...。
接下看下 Sentinel 是如何实现责任链模式又是如何统计指标和验证规则的。

```java
    // 在没有调用链，并且调用链没有超过最大允许数时，初始化一个
    chain = SlotChainProvider.newSlotChain();
    Map<ResourceWrapper, ProcessorSlotChain> newMap = new HashMap<ResourceWrapper, ProcessorSlotChain>(
        chainMap.size() + 1);
    newMap.putAll(chainMap);
    newMap.put(resourceWrapper, chain);
    chainMap = newMap;
```

```java
    // 获取到一个默认的slot调用链构建器，并开始构建
    slotChainBuilder = SpiLoader.loadFirstInstanceOrDefault(SlotChainBuilder.class, DefaultSlotChainBuilder.class);
    slotChainBuilder.build();

```

```java
    public ProcessorSlotChain build() {
        // 创建调用链对象
        ProcessorSlotChain chain = new DefaultProcessorSlotChain();

        // Note: the instances of ProcessorSlot should be different, since they are not stateless.
        // 通过SPI发现并加载并排序所有的调用链节点
        List<ProcessorSlot> sortedSlotList = SpiLoader.loadPrototypeInstanceListSorted(ProcessorSlot.class);
        for (ProcessorSlot slot : sortedSlotList) {
            if (!(slot instanceof AbstractLinkedProcessorSlot)) {
                RecordLog.warn("The ProcessorSlot(" + slot.getClass().getCanonicalName() + ") is not an instance of AbstractLinkedProcessorSlot, can't be added into ProcessorSlotChain");
                continue;
            }
            // 按顺序依次将调用链节点添加都最后一个，并关联下一个节点
            chain.addLast((AbstractLinkedProcessorSlot<?>) slot);
        }

        return chain;
    }
```

```java
    public static <T> List<T> loadPrototypeInstanceListSorted(Class<T> clazz) {
        try {
            // @1
            // Not use SERVICE_LOADER_MAP, to make sure the instances loaded are different.
            ServiceLoader<T> serviceLoader = ServiceLoaderUtil.getServiceLoader(clazz);

            List<SpiOrderWrapper<T>> orderWrappers = new ArrayList<>();
            for ( T spi : serviceLoader ) {
                // @2
                int order = SpiOrderResolver.resolveOrder(spi);
                
                // @3
                // Since SPI is lazy initialized in ServiceLoader, we use online sort algorithm here.
                SpiOrderResolver.insertSorted(orderWrappers, spi, order);
                RecordLog.debug("[SpiLoader] Found {} SPI: {} with order {}", clazz.getSimpleName(),
                        spi.getClass().getCanonicalName(), order);
            }
            List<T> list = new ArrayList<>(orderWrappers.size());
            // @4
            for (int i = 0; i < orderWrappers.size(); i++) {
                list.add(orderWrappers.get(i).spi);
            }
            return list;
        } catch (Throwable t) {
            RecordLog.error("[SpiLoader] ERROR: loadPrototypeInstanceListSorted failed", t);
            t.printStackTrace();
            return new ArrayList<>();
        }
    }
```
* @1 SPI 发现并加载ProcessorSlot接口对象集合。通过[META-INF/services/com.alibaba.csp.sentinel.slotchain.ProcessorSlot]找到所有的调用链节点
* @2 每个实现类上都有一个注解 `@SpiOrder` 取出注解上的值，用于后续的排序 
* @3 按 `@SpiOrder` 从小到大冒泡排序，将 `spi` 插入到 `orderWrappers` 中
* @4 创建一个新的集合并将 `spi` 按顺序存入

在完成以上步骤后，调用链将被初始化成

|顺序|节点 |作用 |下一个节点
---|---|---|---
1|DefaultProcessorSlotChain|第一个节点 |NodeSelectorSlot
2|NodeSelectorSlot|创建当前Node |ClusterBuilderSlot
3|ClusterBuilderSlot|创建全局Cluster节点|LogSlot
4|LogSlot|记录日志|StatisticSlot
5|StatisticSlot|统计各项指标|AuthoritySlot
6|AuthoritySlot|验证认证规则|SystemSlot
7|SystemSlot|验证系统指标（CPU等指标） |FlowSlot
8|FlowSlot|验证限流指标|DegradeSlot
9|DegradeSlot|验证熔断指标|Null

### 责任链调用
#### NodeSelectorSlot 源码分析

```java
        DefaultNode node = map.get(context.getName());
        if (node == null) {
            synchronized (this) {
                node = map.get(context.getName());
                if (node == null) {
                    node = new DefaultNode(resourceWrapper, null);
                    HashMap<String, DefaultNode> cacheMap = new HashMap<String, DefaultNode>(map.size());
                    cacheMap.putAll(map);
                    cacheMap.put(context.getName(), node);
                    map = cacheMap;
                    // Build invocation tree
                    ((DefaultNode) context.getLastNode()).addChild(node);
                }

            }
        }

        context.setCurNode(node);
        fireEntry(context, resourceWrapper, node, count, prioritized, args);
```
`NodeSelectorSlot` 源码比较简单，主要逻辑就是根据 `context` 名找到一个对应的 `Node` 如果没有就创建一个，并标记为 `context` 的
当前 `node`

#### ClusterBuilderSlot 源码分析
```java
        if (clusterNode == null) {
            synchronized (lock) {
                if (clusterNode == null) {
                    // Create the cluster node.
                    clusterNode = new ClusterNode(resourceWrapper.getName(), resourceWrapper.getResourceType());
                    HashMap<ResourceWrapper, ClusterNode> newMap = new HashMap<>(Math.max(clusterNodeMap.size(), 16));
                    newMap.putAll(clusterNodeMap);
                    newMap.put(node.getId(), clusterNode);

                    clusterNodeMap = newMap;
                }
            }
        }
        node.setClusterNode(clusterNode);
```
* clusterNode 是相对资源唯一
* 因为一个资源只会有一个责任链，只有在初始化的时候需要进行缓存，所以这里只需要用 HashMap 用来存储这个 clusterNode， 并且在初始化的时候加上锁就可以了（后续只会读）。

#### LogSlot 源码分析
```java
        try {
            // @1
            fireEntry(context, resourceWrapper, obj, count, prioritized, args);
        } catch (BlockException e) {
            // @2
            EagleEyeLogUtil.log(resourceWrapper.getName(), e.getClass().getSimpleName(), e.getRuleLimitApp(),
                context.getOrigin(), count);
            throw e;
        } catch (Throwable e) {
            // @3
            RecordLog.warn("Unexpected entry exception", e);
        }
```
* @1 先调用后面的责任链节点
* @2 当后面的责任链节点触发 BlockException 异常后记录 Block 次数到鹰眼
* @3 当后面的责任链触发其他异常后打出警告日志

#### StatisticSlot 源码分析
`StatisticSlot` 是 `Sentinel` 核心的一个类，统计各项指标用于后续的限流、熔断、系统保护等策略，接下来看下 `Sentinel` 是如何通过 `StatisticSlot` 进行指标统计的
```java
        // ...省略部分代码
        // Do some checking.
        // @1
        fireEntry(context, resourceWrapper, node, count, prioritized, args);

        // Request passed, add thread count and pass count.
        // @2
        node.increaseThreadNum();
        node.addPassRequest(count);
        // ...省略部分代码    
```
* @1 触发后面的责任链节点
* @2 记录通过的线程数`+1`和通过请求 `+count`
这里的 `node` 就是第二个责任链节点 `NodeSelectorSlot` 创建的 `DefaultNode`
在分析源码前可以先简单了解下 `Context`、`Entry`、`DefaultNode`、`ClusterNode` 的关系
![Context 关系图](https://note.youdao.com/yws/api/personal/file/56B9E3EE9D89479F93F62FB5E16DE7DE?method=download&shareKey=e6bfd5cf37270f55437be94f1a7d2efa)
* `Context` 每个线程是独享的，但是不同线程的 `Context` 可以使用同一个名字
* `EntranceNode` 是根据 `Context` 名共享的，也就是说一个 `Context.name` 对应一个 `EntranceNode`。每次调用的时候都会创建，用于记录
* `Entry` 是相对于每个 `Context` 独享的即是同一个 `Context.name`，包含了资源名、curNode（当前统计节点）、originNode（来源统计节点）等信息
* `DefaultNode` 一个 `Context.name` 对应一个统计某资源调用链路上的指标
* `ClusterNode` 一个资源对应一个，统计一个资源维度的指标
* `DefaultNode` 和 `ClusterNode` 都继承至 `StatisticNode` 都包含两个 `ArrayMetric` 类型的字段 `rollingCounterInSecond`、`rollingCounterInMinute` 分别用于存储秒级和分钟级统计指标
* 而 `ArrayMetric` 类包含了一个 `LeapArray<MetricBucket>` 类型字段 `data`, `data` 中存放了一个 `WindowWrap<MetricBucket>` 元素的数组（滑动窗口）, 而这个数组就是各项指标最终存储的位置 

```java
node.increaseThreadNum();
```
这行代码其实就是对 `StatisticNode.curThreadNum` 进行自增操作

```java
    public void addPassRequest(int count) {
        super.addPassRequest(count);
        this.clusterNode.addPassRequest(count);
    }
```
添加通过的数量， 除了 `DefaultNode` 记录一次外，在 `ClusterNode` 上也需要记录一次【注意：`ClusterNode` 是按照资源维度统计的，这里指向的 `ClusterNode` 与同一资源不同 `Context` 指向的 `ClusterNode` 是同一个】。一个 `Node` 在调用了 `addPassRequest`
后发生了什么呢？
```java
    public void addPassRequest(int count) {
        rollingCounterInSecond.addPass(count);
        rollingCounterInMinute.addPass(count);
    }
```
在以上代码可以看到 `rollingCounterInSecond` 、`rollingCounterInMinute` 两个字段，它们分别用来统计秒级指标和分钟级指标。而实际上这两个字段使用了滑动时间窗口数据结构用于存储指标。接下来看下 `Sentinel` 滑动窗口的设计:
时间滑动窗口主要用到的几个类有：
* ArrayMetric: 负责初始化时间滑动窗口和维护
* LeapArray: 一个滑动时间窗口主体
* WindowWrap: 一个时间窗口主体
* LongAdder：指标统计的计数类

`ArrayMetric` 构造器：
```java
    public ArrayMetric(int sampleCount, int intervalInMs) {
        this.data = new OccupiableBucketLeapArray(sampleCount, intervalInMs);
    }

    public ArrayMetric(int sampleCount, int intervalInMs, boolean enableOccupy) {
        if (enableOccupy) {
            this.data = new OccupiableBucketLeapArray(sampleCount, intervalInMs);
        } else {
            this.data = new BucketLeapArray(sampleCount, intervalInMs);
        }
    }

    /**
     * For unit test.
     */
    public ArrayMetric(LeapArray<MetricBucket> array) {
        this.data = array;
    }
```
`ArrayMetric` 主要有三种构造器，最后一种只是用来跑单元测试使用，而前两种构造器主要为了初始化 `data` 字段。
从代码中我们可以看到 `LeapArray` 有两种实现方式 `OccupiableBucketLeapArray` 和 `BucketLeapArray`，而两种都继承至 `LeapArray`。

*LeapArray 类图*
[LeapArray类图](https://note.youdao.com/yws/api/personal/file/F75D9590517F4F899ACB4F5D58989F2A?method=download&shareKey=7143a970038fb64081b92019d9633390)
`LeapArray` 类主要包含以下几个字段：
* `int windowLengthInMs` 一个时间窗口的长度，用毫秒表示
* `int sampleCount` 表示用几个时间窗口统计
* `int intervalInMs` 轮回时间，也就是所有时间窗口加起来的总时长
* `AtomicReferenceArray<WindowWrap<T>> array`  时间窗口实例集合，数组的长度等于 `sampleCount`


那么我们在回头看下 `rollingCounterInSecond` 、`rollingCounterInMinute` 用到了哪种 `LeapArray`
```java
    /**
     * SampleCountProperty.SAMPLE_COUNT = 2
     * IntervalProperty.INTERVAL = 1000
     * Holds statistics of the recent {@code INTERVAL} seconds. The {@code INTERVAL} is divided into time spans
     * by given {@code sampleCount}.
     */
    private transient volatile Metric rollingCounterInSecond = new ArrayMetric(SampleCountProperty.SAMPLE_COUNT,
        IntervalProperty.INTERVAL);

    /**
     * Holds statistics of the recent 60 seconds. The windowLengthInMs is deliberately set to 1000 milliseconds,
     * meaning each bucket per second, in this way we can get accurate statistics of each second.
     */
    private transient Metric rollingCounterInMinute = new ArrayMetric(60, 60 * 1000, false);
```
从上述代码中我们可以看到秒级统计初始化了一个 `OccupiableBucketLeapArray` 轮回时间为 1000ms 也就是 1s，分两个时间窗口每个各 500ms，而分钟级统计初始化了 `BucketLeapArray` 轮回时间为 60000ms 也就是 1Min ，分 60 个时间窗口每个窗口 1s。

```java
    // ArrayMetric.addPass
    public void addPass(int count) {
        WindowWrap<MetricBucket> wrap = data.currentWindow();
        wrap.value().addPass(count);
    }
```
在添加通过指标前先获取到当前的时间窗口，再将通过数量统计到窗口对应的 `MetricBucket` 中，那么如何获取当前窗口呢？
```java
    public WindowWrap<T> currentWindow() {
        return currentWindow(TimeUtil.currentTimeMillis());
    }
    
    public WindowWrap<T> currentWindow(long timeMillis) {
        if (timeMillis < 0) {
            return null;
        }

        //     private int calculateTimeIdx(long timeMillis) {
        //         long timeId = timeMillis / windowLengthInMs;
        //         // Calculate current index so we can map the timestamp to the leap array.
        //         return (int)(timeId % array.length());
        //     }
        int idx = calculateTimeIdx(timeMillis);
        // Calculate current bucket start time.
        long windowStart = calculateWindowStart(timeMillis);

        /*
         * Get bucket item at given time from the array.
         *
         * (1) Bucket is absent, then just create a new bucket and CAS update to circular array.
         * (2) Bucket is up-to-date, then just return the bucket.
         * (3) Bucket is deprecated, then reset current bucket and clean all deprecated buckets.
         */
        while (true) {
            WindowWrap<T> old = array.get(idx);
            if (old == null) {
                WindowWrap<T> window = new WindowWrap<T>(windowLengthInMs, windowStart, newEmptyBucket(timeMillis));
                if (array.compareAndSet(idx, null, window)) {
                    return window;
                } else {
                    Thread.yield();
                }
            } else if (windowStart == old.windowStart()) {
                return old;
            } else if (windowStart > old.windowStart()) {
                if (updateLock.tryLock()) {
                    try {
                        // Successfully get the update lock, now we reset the bucket.
                        return resetWindowTo(old, windowStart);
                    } finally {
                        updateLock.unlock();
                    }
                } else {
                    // Contention failed, the thread will yield its time slice to wait for bucket available.
                    Thread.yield();
                }
            } else if (windowStart < old.windowStart()) {
                // Should not go through here, as the provided time is already behind.
                return new WindowWrap<T>(windowLengthInMs, windowStart, newEmptyBucket(timeMillis));
            }
        }
    }
```
第一步首先获取到当前的时间戳毫秒，通过时间戳计算出时间窗口数组的下标。在计算下标时首先将当前时间戳除以单个窗口时长，计算出当前所在从0ms开始到现在的第几个窗，再对窗口数取模得出当前窗口的在数组中所在下标。从这里我们大概可以看出，这里数组中的时间窗口对象是反复使用的只是代表的时间不同了。
我们以秒级统计为例模拟计算下，当前时间戳为：`1595495124658`，按照 `timeMillis / windowLengthInMs` 可以得出 `timeId` 为 `3190990249`。 `(int)(timeId % array.length())` 就是 `3190990249 % 2` 算出结果为 `1`，也就是说 `1` 下标位置的时间窗口是当前时间窗口。

第二步在计算出当前窗口所在下标后，需要计算出当前窗口的开始时间 `timeMillis - timeMillis % windowLengthInMs`，`timeMillis % windowLengthInMs` 表示当前窗口开始时间到当前时间的时长，所有当前时间减去时长即可得出当前窗口的开始时间，按上面的例子算出的结果就是 `1595495124500` 
```java
    WindowWrap<T> old = array.get(idx);
    if (old == null) {
        WindowWrap<T> window = new WindowWrap<T>(windowLengthInMs, windowStart, newEmptyBucket(timeMillis));
        if (array.compareAndSet(idx, null, window)) {
            return window;
        } else {
            Thread.yield();
        }
    }
```
第三步根据下标取出我们的当前窗口的实例，如果实例还没有被创建过新建一个窗口实例并初始化同时通过 `CAS` 的方式更新到窗口数组中，如果更新失败让出 `CPU` 等待下次 `CPU` 执行本线程。

第四步如果下标位置已经存在一个窗口实例，并且窗口的开始时间跟本次窗口开始时间一致（同一个窗口），直接返回下标中的窗口

第五步如果当前窗口的开始时间大于下标窗口的开始时间，说明下标窗口已过期，需要重置数组下标中的窗口（把下标窗口的开始时间改完当前窗口时间，并将指标计数都置成 0 ）

第六步当前窗口时间小于下标窗口时间，重新实例化一个窗口（不太有这个可能，`sentinel` 内部实现了自己的时间戳）

在拿到当前时间所在窗口后，将当前的指标累加记录到 `MetriBucket` 中
* MetriBucket 累加通过指标 *
```java
    public void addPass(int n) {
        add(MetricEvent.PASS, n);
    }

    public MetricBucket add(MetricEvent event, long n) {
        counters[event.ordinal()].add(n);
        return this;
    }
```

* `counters` 是一个 `LongAdder` 类型的数组
* `MetricEvent` 是指标类型，分别有：PASS 通过、BLOCK 阻塞、 EXCEPTION 异常、 SUCCESS 成功、 RT 平均响应时间、 OCCUPIED_PASS 通过未来的配额
* `counters[event.ordinal()].add(n)` 在指定的指标计数器上累加计数

看到这里我们知道了 `pass` 指标是在资源通过 `StatisticSlot` 后几个节点的验证后立即进行指标计数，那么剩下的 `BLOCK`、 `EXCEPTION`、 `SUCCESS`、 `RT`、 `OCCUPIED_PASS` 这几个是在什么时候做记录的呢?

##### BLOCK 统计
```java
        ...省略部分代码...
        } catch (BlockException e) {
            ...省略部分代码...
            // Add block count.
            node.increaseBlockQps(count);
            if (context.getCurEntry().getOriginNode() != null) {
                context.getCurEntry().getOriginNode().increaseBlockQps(count);
            }

            if (resourceWrapper.getEntryType() == EntryType.IN) {
                // Add count for global inbound entry node for global statistics.
                Constants.ENTRY_NODE.increaseBlockQps(count);
            }

            // Handle block event with registered entry callback handlers.
            for (ProcessorSlotEntryCallback<DefaultNode> handler : StatisticSlotCallbackRegistry.getEntryCallbacks()) {
                handler.onBlocked(e, context, resourceWrapper, node, count, args);
            }

            throw e;
        }
```
在后续的责任链节点中（`StatisticSlot` 之后的节点），如果捕获到了阻塞异常，将对 `DefaultNode`、`OriginNode`、`ENTRY_NODE` 几个 `node` 进行指标累计。同样也是添加到当前窗口 `MetricBucket` 中不再进行过多描述

##### EXCEPTION 统计
```java
        try {
            // Do some checking.
            fireEntry(context, resourceWrapper, node, count, prioritized, args);
            ...省略部分代码
        } catch (Throwable e) {
            // Unexpected error, set error to current entry.
            context.getCurEntry().setError(e);

            // This should not happen.
            node.increaseExceptionQps(count);
            if (context.getCurEntry().getOriginNode() != null) {
                context.getCurEntry().getOriginNode().increaseExceptionQps(count);
            }

            if (resourceWrapper.getEntryType() == EntryType.IN) {
                Constants.ENTRY_NODE.increaseExceptionQps(count);
            }
            throw e;
        }
```
类似的 `exception` 统计在后续的责任链节点中（`StatisticSlot` 之后的节点），如果捕获到了异常，将对 `DefaultNode`、`OriginNode`、`ENTRY_NODE` 几个 `node` 进行指标累计。

除了 `StatisticSlot` 自动捕获异常外，在资源调用过程中如果出现了异常将通过调用 `Tracer.trace(e)` 手动统计异常指标
```java
    public static void trace(Throwable e, int count) {
        traceContext(e, count, ContextUtil.getContext());
    }
    public static void traceContext(Throwable e, int count, Context context) {
        if (!shouldTrace(e)) {
            return;
        }

        if (context == null || context instanceof NullContext) {
            return;
        }

        DefaultNode curNode = (DefaultNode)context.getCurNode();
        traceExceptionToNode(e, count, context.getCurEntry(), curNode);
    }
```
首先从线程变量中出去当前线程的 `Context` 在从中取出 DefaultNode 和 ClusterNode 并进行异常指标累计

#####  `SUCCESS`、 `RT` 统计
平均响应时间和成功次数的统计是在资源退出的时候调用 `entry.exit()` 进行统计，代码如下：
```java
    // StatisticSlot#exit()
    public void exit(Context context, ResourceWrapper resourceWrapper, int count, Object... args) {
        DefaultNode node = (DefaultNode)context.getCurNode();

        if (context.getCurEntry().getError() == null) {
            // Calculate response time (max RT is statisticMaxRt from SentinelConfig).
            long rt = TimeUtil.currentTimeMillis() - context.getCurEntry().getCreateTime();
            int maxStatisticRt = SentinelConfig.statisticMaxRt();
            if (rt > maxStatisticRt) {
                rt = maxStatisticRt;
            }

            // Record response time and success count.
            node.addRtAndSuccess(rt, count);
            if (context.getCurEntry().getOriginNode() != null) {
                context.getCurEntry().getOriginNode().addRtAndSuccess(rt, count);
            }

            node.decreaseThreadNum();

            if (context.getCurEntry().getOriginNode() != null) {
                context.getCurEntry().getOriginNode().decreaseThreadNum();
            }

            if (resourceWrapper.getEntryType() == EntryType.IN) {
                Constants.ENTRY_NODE.addRtAndSuccess(rt, count);
                Constants.ENTRY_NODE.decreaseThreadNum();
            }
        } else {
            // Error may happen.
        }

        // Handle exit event with registered exit callback handlers.
        Collection<ProcessorSlotExitCallback> exitCallbacks = StatisticSlotCallbackRegistry.getExitCallbacks();
        for (ProcessorSlotExitCallback handler : exitCallbacks) {
            handler.onExit(context, resourceWrapper, count, args);
        }

        fireExit(context, resourceWrapper, count);
    }
```
退出也是责任链调用退出每个节点，这里直接跳过了大部分代码。退出统计大致流程如下：
* 获取得到当前时间戳和资源调用的时间，相减算出这次整个资源调用所花费的总时间
* 将总时间记录和成功次数累加记录当前窗口，本次总时间如果超过最大统计时间以最大统计时间作为本次统计时间
* 对 Node 扣减一次当前线程数
* 触发下一个责任链节点退出


### LongAdder 源码分析

```java
    public void add(long x) {
        Cell[] as = cells;
        long b = base;
        long v;
        HashCode hc;
        Cell a;
        int n;
        if (cells != null || !casBase(base, b + x)) {
            boolean uncontended = true;
            hc = threadHashCode.get()
            int h = hc.code;
            n = as.length;
            a = as[(n - 1) & h]
            uncontended = a.cas(v = a.value, v + x)
            if (as == null || as.length < 1 ||
                a == null ||
                !uncontended) {
                 retryUpdate(x, hc, uncontended);
            }
        }
    }
```
LongAdder 中有一个Cell数组用于存储数值，当高并发时对数组中某个值进行加法运算减少同一个数值并发。（+1） 或者 （+ -1）

```java
    public long sum() {
        long sum = base;
        Cell[] as = cells;
        if (as != null) {
            int n = as.length;
            for (int i = 0; i < n; ++i) {
                Cell a = as[i];
                if (a != null) { sum += a.value; }
            }
        }
        return sum;
    }
```
取值时把 Cell 数组中所有元素的取出算总数


#### 熔点判断
```java
    DegradeRuleManager.checkDegrade(resourceWrapper, context, node, count);

    public static void checkDegrade(ResourceWrapper resource, Context context, DefaultNode node, int count)
        throws BlockException {

        Set<DegradeRule> rules = degradeRules.get(resource.getName());
        if (rules == null) {
            return;
        }

        for (DegradeRule rule : rules) {
            if (!rule.passCheck(context, node, count)) {
                throw new DegradeException(rule.getLimitApp(), rule);
            }
        }
    }
```
熔点的判断是由 `DegradeRuleManager` 管理。 `DegradeRuleManager` 会根据资源名取出所有的熔断规则，然后检查所有的规则如果触发其中一个直接抛出 `DegradeException` 异常触发熔断机制。

* RT *

```java
        double rt = clusterNode.avgRt();
        if (rt < this.count) {
            passCount.set(0); // 计数，用于判断连续超 RT 多少次
            return true;
        }

        // Sentinel will degrade the service only if count exceeds.
        if (passCount.incrementAndGet() < rtSlowRequestAmount) {
            return true;
        }

        ...省略部分代码
        return false;
```
* 从 `clusterNode` 中计算出平均响应时间
* 如果平均响应时间小于规则设置时间，将统计连续超时计数器重置为`0`
* 如果平均响应时间大于规则设置时间，并且连续超时计数器超过了规则设置的大小，判为到达熔断点抛出熔断异常

统计平均 RT 的方法（秒级）：
* 取出所有窗口（秒级只定义了两个时间窗口）的 RT，并求总和
* 取出所有窗口（秒级只定义了两个时间窗口）的 success，并求总和
* 所有窗口的 RT 总和 除以 success 总和 得出平均RT

异常比例熔断也是类似的逻辑（秒级）
* 取出所有窗口的 exception 数求和，并除以一个间隔时间（秒为单位）【每秒总异常数】
* 取出所有窗口的 success 数求总和，并除以一个间隔时间（秒为单位）【每秒总退出成功数，包含了异常数】
* 取出所有窗口的 pass 总和 加上所有窗口 block 总数，并除以一个间隔时间（秒为单位）【算每秒总调用量】
* 如果每秒总调用量小于 minRequestAmount 判为未到达熔断点
* 如果每秒总异常数没有超过 minRequestAmount 判为未到达熔断点
* 每秒总退出成功数 / 每秒总异常数（异常比例）如果超过规则指定比例，判为到达熔断点抛出熔断异常

异常数就比例（分钟级）
* 取出所有窗口的 exception 数总和，判断如果超过规则配置数，抛出熔断异常


### 总结
Sentinel 通过责任链，触发节点创建、监控统计、日志、认证、系统限流、限流、熔断，因为Sentinl 是由 SPI 创建的责任链所以我们可以自定义链节点拿到指标根据自己的业务逻辑定义。
Sentinel 通过将所有的指标统计到时间窗口中，记录在 MetricBucket 类实例中

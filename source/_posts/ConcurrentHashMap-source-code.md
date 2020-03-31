---
title: ConcurrentHashMap 源码分析
date: 2020-03-13 13:25:51
category: [java]
tags: [source]
---
# ConcurrentHashMap 源码分析

众所周知 ConcurrentHashMap 是线程安全的一个 Map，那么他是如何实现线程安全的呢？以下就以 `jdk1.8.0_172` 的源码进行分析

#### put 方法源码，带注释
```JAVA
    /** Implementation for put and putIfAbsent */
    final V putVal(K key, V value, boolean onlyIfAbsent) {
        if (key == null || value == null) throw new NullPointerException();
        
        int hash = spread(key.hashCode());  // 通过扰动函数获取计算出一个 hash
        int binCount = 0;                   // 默认为 0， 节点已经存在一个元素时 1表示元素 hash 大于等于0，2 表示存在红黑树

        for (Node<K,V>[] tab = table;;) { // 无限循环

            Node<K,V> f;    // 根据算出来的 i(index)取到的 node 节点
            int n;          // 当前 table 的长度
            int i;          // (n - 1) & hash 应该是 index，这样的话每次长度可能是不一样的算出来的index能一致么（扩容后如何重新存放数据）？
            int fh;         // f 节点的hash值

            if (tab == null || (n = tab.length) == 0) {
                tab = initTable();                      // 如果 table 不存在就初始化一个

            } else if ((f = tabAt(tab, i = (n - 1) & hash)) == null) {  // 数组下标位置空缺，调用 unsafe 类的本地方法 getObjectVolatile 使用volatile的加载语义获取指定位置
                
                if (casTabAt(tab, i, null, new Node<K,V>(hash, key, value, null)))  // CAS 对比原值是否被改动，如果没有改动则替换原值
                    break;                   // no lock when adding to empty bin    // CAS是一条CPU的原子指令（cmpxchg指令），不会造成所谓的数据不一致问题，属于乐观锁

            } else if ((fh = f.hash) == MOVED) {    // hash for forwarding nodes
                tab = helpTransfer(tab, f);

            } else {        // hash 冲突，当前 hash 对应数组下标已经有值了
                V oldVal = null;

                synchronized ( f ) {
                    if ( tabAt(tab, i) == f ) {   // 在取一次数据确保数据在加锁前没有被修改过
                        if ( fh >= 0 ) {          // hash 大于等于0（hash 什么情况下会小于0？）
                            binCount = 1;
                            for ( Node<K,V> e = f ;; ++binCount ) {        // 死循环并计数
                                K ek;           // f 的key

                                // 取出来的node key、hash跟传入进来的key是同一个没变
                                if ( e.hash == hash && ((ek = e.key) == key || (ek != null && key.equals(ek))) ) {
                                    oldVal = e.val;
                                    if ( !onlyIfAbsent ) // 不是 只有在空缺时进行存入操作，直接把新值存进去
                                        e.val = value;  
                                    break;
                                }

                                // 如果对应数组下标值key跟现在要存的key是不一样的
                                Node<K,V> pred = e;     // e 就是f,根据算出来的 i(index)取到的 node 节点
                                if ((e = e.next) == null) { // 下一个 node，如果是空的
                                    pred.next = new Node<K,V>(hash, key, value, null);  // 直接链表的下一个节点
                                    break;
                                }
                            }
                        } else if ( f instanceof TreeBin ) {  // f 的 hash 小于 0 并且f 是一颗二叉树（树的hash肯定小于0么？）
                            Node<K,V> p;
                            binCount = 2;
                            if ( ( p = ((TreeBin<K,V>)f).putTreeVal(hash, key, value) ) != null ) { // 找到一个节点或者新建一个节点
                                oldVal = p.val;
                                if ( !onlyIfAbsent )  // 不是 只有在空缺时进行存入操作，直接把新值存进新树节点
                                    p.val = value;
                            }
                        }
                    }
                }

                if (binCount != 0) {    // 链表或者是二叉树
                    if (binCount >= TREEIFY_THRESHOLD)      // 链表的长度如果超过或等于8
                        treeifyBin(tab, i);                 // 将链表转换为二叉树
                    if (oldVal != null)
                        return oldVal;						// 如果原来有值则返回原来的值
                    break;
                }
            }
        }

        addCount(1L, binCount);								// 元素计数并判断是否需要扩容
        
        return null;
    }
```

## put 方法流程图
![image](https://note.youdao.com/yws/api/personal/file/DE5DE46C6C4740279EA45C6C27C66C15?method=download&shareKey=c97f3124a814f2687a30e23eb4d33d01)

在 put 插入数据时存在这么几种情况：
* 数组 table 不存在 或者没有初始化长度（懒加载）
* 数据插入到哪个地址
* 期望插入的地址已经有数据了
* 在插入数据时如何避免有其他线程同时操作插入或者其他线程在执行扩容
* 存储数据已经存满了，该怎么办

下面针对以上几种情况进行分析 ConcurrentHashMap 时如何处理这些问题的

#### 数组 table 不存在或者没有初始化长度
对于这个情况肯定是初始化一个数组就好了，在这里我们主要想分析的是如何初始化一个数组。对于初始化数组可能会存在的一个并发问题就是，在 A 线程初始化数组同时 B 线程也在执行初始化。

那 ConcurrentHashMap 是如何处理这个问题的。这里 ConcurrentHashMap 设置了一个 int 类型的属性 sizeCtl ，用于判断是否有其他线程在执行扩容或者初始化等调整大小的操作。先看下 sizeCtl 的注释：

 > Table initialization and resizing control.  When negative, the table is being initialized or resized: -1 for initialization,  else -(1 + the number of active resizing threads).  Otherwise, when table is null, holds the initial table size to use upon creation, or 0 for default. After initialization, holds the next element count value upon which to resize the table.

大致意思是
 > 表初始化和大小调整控制。如果为负，则表将被初始化或调整大小：-1用于初始化， -（1 +活动的调整大小线程数）表示调整大小。否则，当table为null时，保留创建时要使用的初始表大小， 或者默认为0。 初始化之后，保留下一个要调整表大小的元素计数值。
 
 代码中实现的逻辑是 siezeCtl 小于 0 的时候（也就是有其他线程对数组执行初始化或者调整大小），放弃 CPU 执行本线程，等待下次本线程抢到执行权（到时候在看还有没有其他线程在执行）
 
 在确保只有本线程在执行初始化后，先对 sizeCtl 进行赋值 -1 准备开始初始化。在这里赋值时又有一个新的并发问题，如何保证在这一瞬间只有一个线程在执行赋值呢？这里 ConcurrentHashMap 调用了 Unsafe.compareAndSwapInt 方法去执行赋值操作，保证了本次赋值操作为原子操作。
 
 那么这里可能又会产生一个新的疑问为什么 Unsafe.compareAndSwapInt 方法就是原子操作呢。翻看源码可以发现 compareAndSwapInt 是一个本地方法这类方法称为 CAS，实际最终调用的是一条 CPU 指令 compxchg。比较值是否被改动过，如果被改动过不做操作否则直接赋值数据，从操作中可以看出来这就是一个乐观锁的执行过程。
 
 在上步加锁操作完成后，终于可以进入到初始化数组阶段了。到了这一步就很简单了，初始化一个 Node 数组，长度为默认 16 或者是 sizeCtl 有大于 0  的值就用 sizeCtl 做为数组长度。最后一个操作就是注释中提到的，保留下一个要调整表大小的元素计数值 （n - (n >>> 2)）n 为最新长度。

#### 数据插入到哪个地址，也就是定位索引，计算数组下标
```java
int hash = (key.hashCode() ^ (key.hashCode() >>> 16)) & 0x7fffffff;  // 扰动函数
int i = (n - 1) & hash)
```

#### 期望插入的地址已经有数据了，如何解决 Hash 冲突
插入的地址中已经有值，一般有两种情况
* 一种就是这个 key 已经存过一次了
* 另一种就是存在另外一个 key 跟当前 key 计算出的 hash 是一样的

第一种情况存的是同一个 key ，记录下老的数据，同时如果存入规则是允许数组下标对应元素非空缺时覆盖，则做覆盖操作否则不做操作。

第二种情况就是面试经常会问到的 hash 冲突。ConcurrentHashMap 使用了常用的解决 hash 冲突的方法，采用链表结构（HashMap、redis的字典都是采用链表解决 hash 冲突）。但是链表有一个问题，当链表越来越长时查询链表的效率会越来越低，所以 1.8 版本后 ConcurrentHashMap 引入红黑树来解决此问题。当链表长度超过 8 后将会尝试转换为红黑树。转换为红黑树有个前提是数组的长度必须大于 64，不然只是重新调整节点位置。

#### 在插入数据时如何避免有其他线程同时操作插入或者其他线程在执行扩容
插入数据分为以下几种情况：
* 没有 hash 冲突，hash 对应的数组下标没有元素存在
* 存入的 key 与 hash 对应的元素是一样的
* 有 hash 冲突为链表结构数据
* 有 hash 冲突为红黑树结构数据

##### 没有 hash 冲突，hash 对应的数组下标没有元素存在
与初始化方法类型用了 CAS 进行赋值
```
U.compareAndSwapObject(tab, ((long)i << ASHIFT) + ABASE, c, v);
```

##### 另外三种情况
* 存入的 key 与 hash 对应的元素是一样的
* 有 hash 冲突为链表结构数据
* 有 hash 冲突为红黑树结构数据
以上都是通过 synchronized 在数组中对应 Node 上加锁，以上三种情况同一时间只能有一个线程执行操作。


#### 存储数据已经存满了，该怎么办，如何扩容
在解决以上问题是我们先考虑一个问题，如何判断数组已经满了？

实际上 ConcurrentHashMap 并不会等到数组元素满了之后在进行扩容，有两种情况下需要进行扩容

* 一种是在新增节点后等到数组元素超过了装载系数0.75（也就是装满75%）后就会立即进行扩容
* 另一种是链表转换为红黑树时，如果数组长度没超过 64，将不会转换为红黑树而是进行扩容重新调整节点位置

以下为计数时候扩容代码加注释

```java
	/**
     * Adds to count, and if table is too small and not already
     * resizing, initiates transfer. If already resizing, helps
     * perform transfer if work is available.  Rechecks occupancy
     * after a transfer to see if another resize is already needed
     * because resizings are lagging additions.
     *
     * @param x the count to add
     * @param check if <0, don't check resize, if <= 1 only check if uncontended
     * 默认为 0 ， 节点已经存在一个元素时 1表示元素 hash 大于等于0，2 表示存在红黑树
     */
    private final void addCount(long x, int check) {
        CounterCell[] as;	// 计数器集合，非空的时候是大小2的幂次方
		// baseCount, Base counter value, used mainly when there is no contention, 
        // but also as a fallback during table initialization races. Updated via CAS.
        long b；				// baseCount
        long s;				// 元素的总数

        // as 非空说明出现过竞争（需要找到自己线程的计数器进行计数）
        // 计数器 +x 失败说明存在赋值竞争（需要通过计数器集合计数）
        if ( (as = counterCells) != null || !U.compareAndSwapLong(this, BASECOUNT, b = baseCount, s = b + x) ) {

            CounterCell a; // 计数器
            long v;	  	   // 当前线程的从 as 中随机取出的值
            int  m;	       // as 的最大下标
            boolean uncontended = true;

            // 如果计数器数组是空的，需要初始化计数器数组
            if (as == null || (m = as.length - 1) < 0 ||
            	// 当前线程的计数（probe每个线程独享，类似于hash的作用用于寻址）如果是空的，需要初始化
                (a = as[ThreadLocalRandom.getProbe() & m]) == null ||
                // 通过CAS给计数器 +x 如果失败需要进入
                !(uncontended =
                  U.compareAndSwapLong(a, CELLVALUE, v = a.value, v + x))) {	// 给cellvalue赋值
                fullAddCount(x, uncontended);
                return;
            }
            if (check <= 1)
                return;
            // 统计计数
            s = sumCount();
        }

        // 是否需要扩容
	    if (check >= 0) {
	        Node<K,V>[] tab, nt;
	        // 表长度
	        int n;
			
			// sizeCtrl
	        int sc;
	        // sizeCtl
	        //  -1 表示在初始化 
	        //  -(1+在扩容的线程数) 表示在扩容
	        //  如果表是 null, sizeCtl 的值就表示需要初始化的大小，默认是 0
	        //  在初始化完成之后，sizeCtl 的值则表示下一个扩容的阈值（n-(n >>> 2) 等于 n * 0.75 向上取整

	        // 元素总数超过 sizeCtrl，并且表不为Null并且 表的长度没超过最大容量
	        while (s >= (long)(sc = sizeCtl) && (tab = table) != null &&
	               (n = tab.length) < MAXIMUM_CAPACITY) {
	            int rs = resizeStamp(n);
	        	// 负数表示在初始化（-1）或者在扩容（-1 + -number of Threads）, 这里判断是否有其他线程正在进行扩容
	            if (sc < 0) {
	            	// 判断扩容是否结束，结束则中断循环
	                if ((sc >>> RESIZE_STAMP_SHIFT) != rs || sc == rs + 1 ||
	                    sc == rs + MAX_RESIZERS || (nt = nextTable) == null ||
	                    transferIndex <= 0)
	                    break;
	                // sizeCtrl +1 表示扩容线程 +1
	                if (U.compareAndSwapInt(this, SIZECTL, sc, sc + 1))
	                    transfer(tab, nt);
	            // 触发扩容（第一个扩容的线程）
	            // 高16位是一个对n的数据校验的标志位，低16位表示参与扩容操作的线程个数 + 1。
	            } else if (U.compareAndSwapInt(this, SIZECTL, sc,
	                                         (rs << RESIZE_STAMP_SHIFT) + 2)) {
	                transfer(tab, null);
	            }
	            // 统计元素总数
	            s = sumCount();
	        }
	    }
    }
        
    private final void fullAddCount(long x, boolean wasUncontended) {
        int h;
        if ((h = ThreadLocalRandom.getProbe()) == 0) {
            ThreadLocalRandom.localInit();      // force initialization
            h = ThreadLocalRandom.getProbe();
            wasUncontended = true;
        }

        boolean collide = false;                // True if last slot nonempty
        for (;;) {
            CounterCell[] as; // 计数器数组
            CounterCell a;     
            int n;            // 计数器数组长度
            long v;
            // 计数器数组不为空，已经初始化过了（存在以下两种情况）
            // 一、最开始没初始化，当前线程进来一瞬间被其他线程初始化了
            // 二、已经初始化了，但是在上一步当前线程给自己在计数器数组中的值加X时候有冲突导致失败了
            if ((as = counterCells) != null && (n = as.length) > 0) {
                // 当前线程在计数器数组中没有值
                if ((a = as[(n - 1) & h]) == null) {
                    // 查看锁状态是否被锁住，（cellsBusy 是在计数器数组扩容或者创建计数器时用的锁）
                    if (cellsBusy == 0) {            // Try to attach new Cell
                        CounterCell r = new CounterCell(x); // Optimistic create
                        // 给 cellsBusy 上锁，准备初始化计数器
                        if (cellsBusy == 0 &&
                            U.compareAndSwapInt(this, CELLSBUSY, 0, 1)) {
                            boolean created = false;
                            try {               // Recheck under lock
                                CounterCell[] rs; int m, j;
                                // 进入到锁里面后，重新检查下计数器数组，确保当前线程计数器没有初始化过
                                if ((rs = counterCells) != null &&
                                    (m = rs.length) > 0 &&
                                    rs[j = (m - 1) & h] == null) {
                                    // 初始化当前线程的计数器
                                    rs[j] = r;  
                                    created = true;
                                }
                            } finally {
                                // 释放锁
                                cellsBusy = 0;
                            }
                            // 如果线程成功初始化计数器，则结束，否则继续回头起点重新初始化计数器
                            if (created)
                                break;
                            continue;           // Slot is now non-empty
                        }
                    }
                    collide = false;
                }
                else if (!wasUncontended)       // CAS already known to fail
                    wasUncontended = true;      // Continue after rehash
                // 当前线程在计数器数组中有值，直接通过 cas 加x
                else if (U.compareAndSwapLong(a, CELLVALUE, v = a.value, v + x))
                    break;
                // 当前计数器数组长度超过了 CPU 的数量，或者计数器被修改了
                else if (counterCells != as || n >= NCPU)
                    collide = false;            // At max size or stale
                else if (!collide)
                    collide = true;
                // 对计数器数组进行扩容
                else if (cellsBusy == 0 &&
                         U.compareAndSwapInt(this, CELLSBUSY, 0, 1)) {
                    try {
                        if (counterCells == as) {// Expand table unless stale
                            CounterCell[] rs = new CounterCell[n << 1];
                            for (int i = 0; i < n; ++i)
                                rs[i] = as[i];
                            counterCells = rs;
                        }
                    } finally {
                        cellsBusy = 0;
                    }
                    collide = false;
                    continue;                   // Retry with expanded table
                }
                // 重新计算hash
                h = ThreadLocalRandom.advanceProbe(h);
            }
            // 计数器数组没被初始化过，通过cellsBusy 上锁 准备开始初始化计数器数组
            else if (cellsBusy == 0 && counterCells == as &&
                     U.compareAndSwapInt(this, CELLSBUSY, 0, 1)) {
                boolean init = false;
                try {                           // Initialize table
                    if (counterCells == as) {
                        CounterCell[] rs = new CounterCell[2];
                        rs[h & 1] = new CounterCell(x);
                        counterCells = rs;
                        init = true;
                    }
                } finally {
                    cellsBusy = 0;
                }
                if (init)
                    break;
            }
            // 初始化计数器数组上锁失败，尝试直接在 basecount 中计数
            else if (U.compareAndSwapLong(this, BASECOUNT, v = baseCount, v + x))
                break;                          // Fall back on using base
        }
    }
    
    /**
     * Moves and/or copies the nodes in each bin to new table. See
     * above for explanation.
     */
    private final void transfer(Node<K,V>[] tab, Node<K,V>[] nextTab) {
        int n = tab.length;		 // 原表长度
        int stride;				 // 一次操作多少条数据
        
        // 根据 CPU 数量来划分一次操作多少条数据，最小是 16 条
        if ((stride = (NCPU > 1) ? (n >>> 3) / NCPU : n) < MIN_TRANSFER_STRIDE)	// MIN_TRANSFER_STRIDE = 16 
            stride = MIN_TRANSFER_STRIDE; // subdivide range

        if (nextTab == null) {            // initiating
            try {
                @SuppressWarnings("unchecked")
                // n << 1 就是 n * 2，表示原来的两倍
                Node<K,V>[] nt = (Node<K,V>[])new Node<?,?>[n << 1];
                nextTab = nt;
            } catch (Throwable ex) {      // try to cope with OOME
                sizeCtl = Integer.MAX_VALUE;
                return;
            }
            nextTable = nextTab;
            transferIndex = n;	// 一直指向最小边界
        }
        int nextn = nextTab.length;
        // A node inserted at head of bins during transfer operations.
        ForwardingNode<K,V> fwd = new ForwardingNode<K,V>(nextTab);
        boolean advance = true;
        boolean finishing = false; // to ensure sweep before committing nextTab

        // i 指向最大边界 bound 指向最小边界
        for (int i = 0, bound = 0;;) {
            Node<K,V> f; int fh;
            
            // 给当前线程分配任务（移动指针指向一个操作范围）
            while (advance) {
                int nextIndex; // 过度用的临时存储变量
                int nextBound; // 
                // --i >= bound 表示 或者 任务已经完成
                if (--i >= bound || finishing) {
                    advance = false;

                // 一个任务的指针如果小于0 表示任务分配完毕
                } else if ((nextIndex = transferIndex) <= 0) {
                    i = -1;
                    advance = false;
                // 分配下一个迁移任务范围
                } else if (U.compareAndSwapInt(this, TRANSFERINDEX, nextIndex, 
                	nextBound = (nextIndex > stride ? nextIndex - stride : 0))) {

                    bound = nextBound;
                    i = nextIndex - 1;
                    advance = false;
                }
            }

            // i < 0 任务完成
            // i >= n 任务完成后
            // i + n >= nextn 任务完成后
            if (i < 0 || i >= n || i + n >= nextn) {
                int sc;
                // 如果所有任务都已经完成，重置数据
                if (finishing) {
                    nextTable = null;
                    table = nextTab;
                    // 设置下一个阈值
                    sizeCtl = (n << 1) - (n >>> 1);
                    return;
                }
                // 当前线程数减一
                if (U.compareAndSwapInt(this, SIZECTL, sc = sizeCtl, sc - 1)) {

                    if ((sc - 2) != resizeStamp(n) << RESIZE_STAMP_SHIFT)
                        return;
                    finishing = advance = true;
                    i = n; // recheck before commit
                }
            }
            // 如果i (最大边界) 的值是空的不需要迁移，直接插入 forwardNode 告知其他线程这块已经处理过了
            else if ((f = tabAt(tab, i)) == null)
                advance = casTabAt(tab, i, null, fwd);
            // 数据已经拷贝到新表中
            else if ((fh = f.hash) == MOVED)
                advance = true; // already processed
            else {
            	// f 节点加锁
                synchronized (f) {
                	// 加锁后再次确认数据没有被修改过
                    if (tabAt(tab, i) == f) {
                        Node<K,V> ln; // 用来存放保留原位置的链表
                        Node<K,V> hn; // 用来存放迁移到 原位置+n 的链表
                        // 节点 hash code 不为负数表示为链表
                        if (fh >= 0) {
                        	// fh 为需要迁移节点hash, n 为原表长度
                        	// f 为需要迁移起始节点
                        	
                        	// hash & n 只会计算出 n 或者 0 值
                        	// n 为原表长度为2的幂次方，所以二进制肯定是 一个1后面带几个零，如16： 10000
                        	// 任何值 & 上 10000 只会有两个结果 10000 或者 0
                        	// 计算结果为n的，直接迁移到 原位置index + n 的位置
                        	// 计算结果为0的，保留在原位置
                        	// 为什么这么做呢？后面在讲...
                            int runBit = fh & n;
                            Node<K,V> lastRun = f;

                            // 循环遍历找到链表最后几个连续的同一类型节点（都保留原位置的或者都要迁移到 原位置+n 的节点）
                            for (Node<K,V> p = f.next; p != null; p = p.next) {
                                int b = p.hash & n;
                                // 找到链表最后几个连续同一类型节点中的头节点
                                if (b != runBit) {
                                    runBit = b;
                                    lastRun = p;
                                }
                            }
                            // 如果本次找到的连续节点是保留原位置的放到 ln 链表
                            if (runBit == 0) {
                                ln = lastRun;
                                hn = null;
                            }
                            // 如果本次找到的连续节点是迁移到 原位置+n 位置的放到 hn 链表
                            else {
                                hn = lastRun;
                                ln = null;
                            }

                            // 继续把其他的节点进行分类
                            // 保留原位置的插入到 ln 链表起始位置
                            // 迁移到 原位置+n 的插入到 hn 链表起始位置
                            // 这里都是插入到起始位置，所以链表不会跟 1.7 jdk 一样发生链表倒置问题
                            for (Node<K,V> p = f; p != lastRun; p = p.next) {
                                int ph = p.hash;
                                K pk = p.key;
                                V pv = p.val;

                                if ((ph & n) == 0)
                                    ln = new Node<K,V>(ph, pk, pv, ln);
                                else
                                    hn = new Node<K,V>(ph, pk, pv, hn);
                            }

                            // 迁移数据
                            setTabAt(nextTab, i, ln);
                            setTabAt(nextTab, i + n, hn);
                            // 原表原位置插上 forwardNode 节点表示已经迁移完毕
                            setTabAt(tab, i, fwd);
                            advance = true;
                        }
                        // 如果已经被转成红黑树了
                        else if (f instanceof TreeBin) {
                            TreeBin<K,V> t = (TreeBin<K,V>)f;			// 需要迁移的节点，转成树类型
                            TreeNode<K,V> lo = null, loTail = null;		// 
                            TreeNode<K,V> hi = null, hiTail = null;		// 
                            int lc = 0, hc = 0;
                            
                            // TreeNode 本身也就是链表
                            // 跟链表一样先分成两类，然后一起迁移
                            for (Node<K,V> e = t.first; e != null; e = e.next) {
                                int h = e.hash;
                                TreeNode<K,V> p = new TreeNode<K,V>(h, e.key, e.val, null, null);

                                // 保持原位节点
                                if ((h & n) == 0) {
                                    if ((p.prev = loTail) == null)
                                        lo = p;
                                    else
                                        loTail.next = p;
                                    loTail = p;
                                    ++lc;
                                }
                                // 迁移到 原位+n 节点
                                else {
                                    if ((p.prev = hiTail) == null)
                                        hi = p;
                                    else
                                        hiTail.next = p;
                                    hiTail = p;
                                    ++hc;
                                }
                            }

							// 元素数量没有超过6，退化成链表
                            ln = (lc <= UNTREEIFY_THRESHOLD) ? untreeify(lo) :
                            	// new TreeBin<K,V>(lo) 会把lo TreeNode 链表重新构建成一个新的红黑树
                                (hc != 0) ? new TreeBin<K,V>(lo) : t;			
                            hn = (hc <= UNTREEIFY_THRESHOLD) ? untreeify(hi) :
                                (lc != 0) ? new TreeBin<K,V>(hi) : t;

                            setTabAt(nextTab, i, ln);
                            setTabAt(nextTab, i + n, hn);
                            setTabAt(tab, i, fwd);
                            advance = true;
                        }
                    }
                }
            }
        }
    }
```

  
<br/>
<br/>
<br/>
  
__参考资料__：
ConcurrentHashMap: [https://www.cnblogs.com/zyrblog/p/9881958.html](https://www.cnblogs.com/zyrblog/p/9881958.html)  
Map: [https://sylvanassun.github.io/2018/03/16/2018-03-16-map_family/#more](https://sylvanassun.github.io/2018/03/16/2018-03-16-map_family/#more)  
cmpxchg：[http://heather.cs.ucdavis.edu/~matloff/50/PLN/lock.pdf](http://heather.cs.ucdavis.edu/~matloff/50/PLN/lock.pdf)  
CAS1：[https://juejin.im/post/5a73cbbff265da4e807783f5](https://juejin.im/post/5a73cbbff265da4e807783f5)  
CAS2：[https://liuzhengyang.github.io/2017/05/11/cas/](https://liuzhengyang.github.io/2017/05/11/cas/)  
CAS3：[https://zhuanlan.zhihu.com/p/34556594](https://zhuanlan.zhihu.com/p/34556594)  

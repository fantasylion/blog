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

        addCount(1L, binCount);								// 判断是否需要扩容
        
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
  
<br/>
<br/>
<br/>
  
__参考资料__：

cmpxchg：[http://heather.cs.ucdavis.edu/~matloff/50/PLN/lock.pdf](http://heather.cs.ucdavis.edu/~matloff/50/PLN/lock.pdf)  
CAS1：[https://juejin.im/post/5a73cbbff265da4e807783f5](https://juejin.im/post/5a73cbbff265da4e807783f5)  
CAS2：[https://liuzhengyang.github.io/2017/05/11/cas/](https://liuzhengyang.github.io/2017/05/11/cas/)  
CAS3：[https://zhuanlan.zhihu.com/p/34556594](https://zhuanlan.zhihu.com/p/34556594)  

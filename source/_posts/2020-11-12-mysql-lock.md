---
title: MySql 锁机制整理
date: 2020-11-12 00:03:51
category: [MySql]
tags: [MySql]
---

## MySql 锁机制整理

最近因为公司经常出现数据库死锁长事务等问题，所以研究了下 MySql 锁机制。本文主要用于梳理最近的研究成果可能会有很多理解错误的地方。

在 MySql 下不同的存储引擎会使用不同的锁，这里主要梳理常见的InnoDB存储引擎使用的锁。

### MySql 锁划分
从 mysql 层面划分包含以下锁
![图片1](https://note.youdao.com/yws/api/personal/file/B72D59C256944CE79C6713AFF2590F8E?method=download&shareKey=e0595ff350ee00c277d7bc2a46b1575d)

# Lock

**X Lock 排他锁**，允许事务删除或更新一行数据，此时无法再加上其他锁。

**S Lock 共享锁**，允许事务读一行数据，此时可以再加共享锁（S Lock/IS Lock）

**Auto-Inc Locks 自增长锁** ，主键自增长，为了提高插入的性能，自增长锁不是一个事务完成后才释放，而是在完成对自增长值插入的SQL语句后立即是释放的。

**IS Lock 意向共享锁**，事务想要获得一张表中某几行的共享锁

**IX Lock 意向排他锁**，事务想要获得一张表中某几行的排他锁

意向锁位表级别锁，设计的目的主要是为了在一个事务中国揭示下一行将被请求的锁类型


#### 互斥或兼容关系
 None | X Lock | S Lock
---|---|---
**X Lock** | 不兼容 | 不兼容
**S Lock** | 不兼容 | 兼容


None | AI Lock | IS Lock | IX Lock | S Lock | X Lock
---|---|---|---|---|---
**AI Lock** | 不兼容 | 兼容 | 兼容 | 不兼容 | 不兼容
**IS Lock** | 兼容   | 兼容 | 兼容 | 兼容   | 不兼容 
**IX Lock** | 兼容   | 兼容 | 兼容 | 不兼容 | 不兼容
**S Lock**  | 不兼容 | 兼容 | 不兼容 | 兼容 | 不兼容
**X Lock**  | 不兼容 | 不兼容 |  不兼容 |  不兼容 |  不兼容



### 隐式锁
隐式锁（implicit lock）必然为 x-lock ，是指索引记录逻辑上有 x-lock，但实际在内存对象中并不包含有这个锁信息。

聚集索引记录的隐式锁，通过聚集索引记录的事务ID 可以查询到该事务为活跃事务，则此聚集索引记录上有隐式索引

辅助索引记录的隐式锁，通过 page header 的 PAGE_MAX_TRX_ID（保存的最大事务ID）进行判断，或通过辅助索引记录的聚集索引事务判断


### 显式锁
显式锁（explicit lock），分为 gap explicit lock 和 no gap explicit lock（gap 通过 type_mode 中 LOCK_GAP 来进行设置）。

no gap explict lock 锁住的是记录以及记录之前的范围，否则，仅锁住范围。explicit lock 可以是 s-lock 也可以是 x-lock。


#### 算法
**Record Lock** 单个行记录上的锁，会去锁住索引记录。如果Inno DB 存储引擎表在建立的时候没有设置任务一个索引，那么这时 InnoDB 存储引擎会使用隐式的主键来进行锁定。

**Gap Lock** 间隙锁，锁定一个范围，但不包含记录本身

**Next-Key Lock** Gap Lock + Record Lock，锁定一个范围，并且锁定记录本身。设计的目的是为了解决 Phantom Problem（幻读）

以上三种算法都属于行级锁，从下方代码中可以看出行锁是根据页的组织形式来进行管理的，并以 bitmap 的形式记录页中哪些数据上了锁。

```c
struct lock_rec_struct{
    ulint space;    /* space id */
    ulint page_no;  /* page number */
    ulint n_bits;   /* number of bits in the lock bitmap */
}
```

```c
/* A table lock */
typedef struct lock_table_struct lock_table_t;
struct lock_table_struct{
    dict_table_t* table;          /* database table in dictionary cache */
    UT_LIST_NODE_T(lock_t)locks;  /* list of locks on the same table */
}
```

```c
/* Lock struct */
struct lock_struct{
    trx_t* trx;                      /* transaction owning the lock */ 
    UT_LIST_NODE_T(lock_t)trx_locks; /* list of the locks of thetransaction */
    ulint type_mode;                 /* lock type, mode, gap flag, andwait flag, 0Red */                
    hash_node_t hash;                /* hash chain node for a record lock */
    dict_index_t* index;             /* index for a record lock */
    union{
        lock_table_t tab_lock;  /* table lock */
        lock_rec_t rec_lock;    /* record lock */
    } un_member;
}

```
 
#### 粒度
* 表锁
* 页锁
* 行锁


## MVCC Multi-Version Concurrency Control 多版本并发控制
多版本并发控制(Multiversion concurrency control， MCC 或 MVCC)，是数据库管理系统常用的一种并发控制，也用于程序设计语言实现事务内存。

MVCC意图解决读写锁造成的多个、长时间的读操作饿死写操作问题。每个事务读到的数据项都是一个历史快照（snapshot)并依赖于实现的隔离级别。写操作不覆盖已有数据项，而是创建一个新的版本，直至所在操作提交时才变为可见。快照隔离使得事物看到它启动时的数据状态。

### 一致性非锁定读
如果读取的行正在执行 DELETE 或 UPDATE 操作，这个时读取操作不会因此去等待行上锁的释放。相反地，InnoDB 存储引擎会去读取行的一个快照数据。

### 一致性锁定读
事务隔离级别 REPEATABLE READ 模式下，InnoDB select 操作使用一致性非锁定读，但在某些情况下，用户需要显式地对数据库读取操作进行加锁以保证数据逻辑的一致性。InnoDB 对 select 语句支持两种一致性的锁定读操作：
* `SELECT ... FOR UPDATE` 加上一个 **X Lock**
* `SELECT ... LOCK IN SHARE MODE` 加上一个 **S Lock**

# Latch
**Latch** 是用来保证并发线程炒作临界资源的正确性，通常又非为 Mutex（互斥锁）和 RWLock（读写锁）

**Mutex**（英文Mutual Exclusion 缩写），InnoDB用于表示内部内存数据结构并对其执行强制互斥锁的低级对象。
一旦获取了锁，就可以防止任何其他进程，线程等获取相同的锁。
与rw-locks形成对比，InnoDB使用rw-locks表示并强制对内部内存数据结构的共享访问锁。

---
title: "GitFlow 开发模式"
layout: post
category: [tool]
tags: [tool]
excerpt: "GitFlow 开发模式"
date: 2015-05-06 00:00:00
---

翻译自：https://nvie.com/posts/a-successful-git-branching-model/

在这篇文章中，主要介绍 Git 分支模型。不会谈论任何项目的细节，只讨论分支策略和发布管理。

## Git分布式和集中式理解
我们配置了中央存储库可以很完美的配合该分支模型工作。这里需要注意下，这个仓库只是被认为 是中央仓库（因为 Git 是 DVCS （分布式版本管理系统），在技术层面上没有中央仓库）。我们将这个中央仓库称为 origin ，应该所有 Git 用户都熟悉这个名称。

每个开发人员都会从中央库 pull 并 push origin 。但除了集中式 pull push  关系之外，每个开发人员还可以从其他开发人员的库中获取更改以形成子团队。例如，在将正在开发的代码 push origin  之前，获取到其他开发人员的代码。这对于与一个大的新功能上的两个或更多开发人员一起工作可能是有用的 。在上图中，有 alice 和 bob，alice 和 david 以及 clair 和 david 的子团队。

从技术上讲，这意味着 Alice 已经定义了一个 Git 遥控器，名为 bob ，指向 Bob 的存储库，反之亦然。

### 主要分支

在核心，开发模型受到现有模型的极大启发。中央仓库拥有两个主要分支，具有无限的生命周期：

* master
* develop

该 master 分支在 origin 应该存在于每一个用户的 Git 。另一个与 master 并行的分支是 develop 。

我们认为 origin/master 是主要分支，这个分支 HEAD 源码始终反映生产就绪状态 ，简单来说就是 master 分支上的代码与生产使用的代码始终保持一致。这样有个好处就是，当生产代码出现紧急 bug 的时候，可以快速从 master 上 fork 出一个 hotfix 分支用来修复 bug 并发布，而不会因为修复线上 bug ，影响正在开发过程中的下一个版本的代码

我们认为 origin/develop 是主要开发分支，其 HEAD 源码始终反映了下一版本中最新交付的开发更改的状态。有些人称之为“整合分支”。这是可以用来建立夜间自动构建的分支。如果我们对此非常严格的执行，从理论上讲，我们可以使用Git钩子脚本在每次提交时自动构建和推出我们的项目到我们的测试服务器。

当 develop 分支中的源代码到达稳定点并准备好发布时，所有更改都应以某种方式合并到 master ，然后使用版本号进行标记。如何执行后面将详细讨论。

因此，每次将更改合并回 master 时，根据我们的定义，这就是一个新的生产版本。

 

### 支持分支
接下来除了两个主分支 master 和 develop ，我们的开发模型使用各种支持分支来帮助团队成员之间的并行开发，轻松跟踪功能，准备生产版本以及帮助快速修复实时生产问题。与主分支不同，这些分支的寿命有限，因为它们最终会被删除。

我们使用的不同类型的分支分别是：

* 功能分支             命名方式：feature-*
* 发布分支             命名方式：release-*
* 修补bug分支          命名方式：hotfix-*  

这些分支中每一个都有特定的目的，并且有着严格的规则：从哪些分支中 fork 出来，又合并到那些分支中。

分支类型根据我们如何使用它们进行分类。

### 功能分支

* 分支出自：  develop  
* 必须合并回： develop  
* 分支命名约定： 最好是 feature-[功能名]，当然如果是想自己定义其他名字只要不是 master, develop, release-*, or hotfix-* 就都可以

功能分支主要用于为下一个版本开发新功能。在开始开发功能时，此功能的发布版本可能在此处未知。功能分支的本质是，只要功能处于开发阶段，它就会存在，但最终会合并回 develop （以便将新功能添加到即将发布的版本中）或丢弃（在产品经理放弃这个功能的时候）。

功能分支通常仅存在于开发人员本地存储库中，而不存在于 origin 。

创建功能分支
在开始处理新功能时，从 develop 分支分支。

```shell
$ git checkout -b myfeature develop
Switched to a new branch "myfeature"
```

在开发中加入完成的功能
完成的功能分支会合并到 develop 分支中，以确保将它们添加到即将发布的版本中：

```shell
$ git checkout develop
Switched to branch 'develop'
$ git merge --no-ff myfeature
Updating ea1b82a..05e9557
(Summary of changes)
$ git branch -d myfeature
Deleted branch myfeature (was 05e9557).
$ git push origin develop
```

该 --no-ff 参数使合并始终创建新的 commit ，最新版中 git merge 默认的就是 --no-ff 。这样可以避免丢失功能分支的历史信息，并将所有添加功能的 commit  组合到一个 commit 中。对比：

在后一种情况下，不可能从 Git 历史中看到哪些 commit 实现了一个功能 - 您必须手动读取所有日志消息。恢复整个功能（即一组提交）在后一种情况下也是比较头痛的，而如果使用该 --no-ff 标志则很容易完成 。

虽然它会创建一些（空的）commit ，但增益远远大于成本。

 

### 发布分支
* 分支出自：develop
* 必须合并回：develop 和 master
* 分支命名约定：release-[版本号]

发布分支主要用来发布新的版本到生产。它可以用来修复最后一分钟的 bug ，当在发布的过程中发现了新的 bug ，可以直接在 release 分支中修改。develop  分支将接收下一个大版本的功能。

需要注意的是在 develop 上创建一个新的发布分支的时候， develop 分支的代码应该是测试完毕后准备发布的代码，至少下一个版本所有的功能都已经合并到 develop 分支 。

当新建了发布分支分配新的版本号，从这个时候开始 develop 分支反映的将应该是下一个版本的代码。比如新建了release-1.6 后 1.6 版本的代码将不再允许提交到 develop 分支中。

创建发布分支
发布分支是从 develop 分支创建的。例如，假设版本 1.1.5 是当前的生产版本，我们即将推出一个大版本。状态 develop 为“下一个版本”做好了准备，我们已经决定这将版本 1.2（而不是 1.1.6或2.0 ）。

因此，我们分支并为发布分支提供反映新版本号的名称：

```shell
$ git checkout -b release-1.2 develop
Switched to a new branch "release-1.2"
$ ./bump-version.sh 1.2
Files modified successfully, version bumped to 1.2.
$ git commit -a -m "Bumped version number to 1.2"
[release-1.2 74d9424] Bumped version number to 1.2
1 files changed, 1 insertions(+), 1 deletions(-)
```

创建新分支并切换到它后，我们会更新版本号。这 bump-version.sh 是一个虚构的shell脚本，它可以更改工作副本中的某些文件以反映新版本。（这当然可以是手动更改 - 关键是某些文件会发生变化。）然后提交了最新的版本号。

这个新分支可能存在一段时间，直到新版发布。在此期间，可以在此分支中修复 bug（而不是在 develop 分支上）。严禁在此处添加大型新功能，新功能必须合并到 develop 等待下一个大版本。

完成发布分支
当 release 分支准备好真正发布的时候，需要执行一些操作。首先，release 分支合并到 master（因为每次提交master都是按照定义的新版本）。接下来，master必须标记 (tag) 该提交，以便将来参考此历史版本。最后，需要将发布分支上的更改合并回来 develop ，以便将来的版本也包含这些错误修复。

Git 中的前两个步骤：

```shell
$ git checkout master
Switched to branch 'master'
$ git merge --no-ff release-1.2
Merge made by recursive.
(Summary of changes)
$ git tag -a 1.2
```

该版本现已完成，并标记以供将来参考。

编辑：您可以使用 -s 或 -u <key> 标记以加密方式对您的标记进行签名。

为了保持 release 分支中所做的更改，我们需要将这些更改合并到 develop。在 Git 中：

```shell
$ git checkout develop
Switched to branch 'develop'
$ git merge --no-ff release-1.2
Merge made by recursive.
(Summary of changes)
```

这一步很可能导致合并冲突（可能是因为我们已经更改了版本号）。如果是出现这种情况，请修复并提交。
现在我们已经完成了，这个时候我们可以删除发布分支，因为我们不再需要它了：

```shell
$ git branch -d release-1.2
Deleted branch release-1.2 (was ff452fe).
```

 

### 修补程序分支

* 分支出自：master
* 必须合并回：develop 和 master
* 分支命名约定：hotfix-*

hotfix 分支主要用来修复生产的紧急 bug ，比如当开发人员正在 feature、develop 分支 开发下一个版本的功能，而生产出现了紧急 bug  必须立刻修复并发布。而你又不想把当前未完成的版本发布到生产，这个时候我们可以在 master 分支上 fork 一个新的 hotfix 分支用来修复bug
，这样的话就不会影响到下一个版本的开发。

### 创建修补 Bug 分支
从 master 分支创建修复 bug 分支。例如，假设版本 1.2 是当前生产版本正在运行并且由于严重错误而影响生产正常使用。但是 develop 分支代码仍然不稳定。然后我们可以 fork hotfix 分支并开始修复问题：

```shell
$ git checkout -b hotfix-1.2.1 master
Switched to a new branch "hotfix-1.2.1"
$ ./bump-version.sh 1.2.1
Files modified successfully, version bumped to 1.2.1.
$ git commit -a -m "Bumped version number to 1.2.1"
[hotfix-1.2.1 41e61bb] Bumped version number to 1.2.1
1 files changed, 1 insertions(+), 1 deletions(-)
```

新建分支后不要忘记标记小版本号！然后修复 bug 并提交一个或多个单独 commit。

```shell
$ git commit -m "Fixed severe production problem"
[hotfix-1.2.1 abbe5d6] Fixed severe production problem
5 files changed, 32 insertions(+), 17 deletions(-)
```

### 完成修补 Bug 分支
完成后，需要将 hotfix 分支合并回 master，同时也需要合并回 develop ，以保证修复bug的代码也包含在下一个版本中。这与发布分支的完成方式相似。

首先，更新 master 并标记版本。

```shell
$ git checkout master
Switched to branch 'master'
$ git merge --no-ff hotfix-1.2.1
Merge made by recursive.
(Summary of changes)
$ git tag -a 1.2.1
```

编辑：您还可以使用 -s 或 -u <key> 标记以加密方式对您的标记进行签名。

接下来，合并 hotfix 到 develop：

```shell
$ git checkout develop
Switched to branch 'develop'
$ git merge --no-ff hotfix-1.2.1
Merge made by recursive.
(Summary of changes)
```

此处有一个例外就是， 在当前 release 分支存在时，只需要将 hotfix 分支合并到该 release 分支中即可，而不是 develop 。将 hotfix 分支合并到 release 分支中，修复的代码最终也会在 release 分支完成时被合并到 develop。（当然如果 develop 立刻需要此修复 bug 代码，不能等到 release 分支完成，您也可以直接地将 hotfix 合并到 develop。）

最后，删除这个临时分支：

```shell
$ git branch -d hotfix-1.2.1
Deleted branch hotfix-1.2.1 (was abbe5d6).
```
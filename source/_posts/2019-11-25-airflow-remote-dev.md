---
title: "Windows 本地搭建 Airflow 开发环境"
layout: post
category: [tool]
tags: [tool]
excerpt: "Windows 本地搭建 Airflow 开发环境"
date: 2020-01-07 00:00:00
---
## 背景
因为 Airflow 无法在windows搭建开发环境导致开发过程比较麻烦。下面提供一个方法用来在windows环境中debug。以下方法的前提是在 Pycharm IDE中开发

#### 第一步：本地开启 debug 端口
![图1](https://note.youdao.com/yws/api/personal/file/AF4C7F7C9CEA4981AB96EBB4CAE8D671?method=download&shareKey=288bb922aec53c40f32eda03527a0a3d)

![图2](https://note.youdao.com/yws/api/personal/file/223F24C94A664EDE8B9B8B47907C5940?method=download&shareKey=7b8027d61c707934baef6bfa4eeb38b4)

![图3](https://note.youdao.com/yws/api/personal/file/4AA9A0DA28A447A8A273A09C4F013CCB?method=download&shareKey=fe00c67b07e9ba4db5f37fd8275fe346)

![图4](https://note.youdao.com/yws/api/personal/file/13C3E5878F3549CF83B26A17DD756400?method=download&shareKey=80cfb246dbf60b87631bce27eaf652bc)

#### 第二步：给远程服务器安装`pydevd`模块
图2中的断点代码拷贝到服务器后无法立即生效还会报错，因为缺少了模块。
在 pycharm 安装目录下找到 `pycharm-debug.egg` 文件，放到远程服务器python目录下我放到了`site-package`目录下，pycharm-debug-py3k.egg 提供给python3版本使用，我这边是2.7用第一个即可
![图6](https://note.youdao.com/yws/api/personal/file/526F8AE46EA6411EAC2B0A168CF200BD?method=download&shareKey=8a99c3eb58b6cda8c008f617358cf3ab)

完成以上步骤可以在服务器`python`中执行下
```PYTHON
>>> import pydevd
```
如果没有报错说明安装成功

#### 第三步：开始debug
点击右上角小虫启动，console 中出现 waiting 后说明开始等待远程的debug请求了
![图7](https://note.youdao.com/yws/api/personal/file/F3E9D418B3BD4886AB4513820D846898?method=download&shareKey=60d802a2b06d092ad1ea1b7f2d0549b8)

运行远程服务器的代码后，本地对应代码将进入对应代码段
![图9](https://note.youdao.com/yws/api/personal/file/F02A108263F24069BC0B40EF02C148CF?method=download&shareKey=6f7c67705cb87decd66d32c876b7c494)

**参考资料：**

[pycharm官网远程debug教程](https://blog.jetbrains.com/pycharm/2010/12/python-remote-debug-with-pycharm/)

**Linux和Mac搭建开发环境资料：**

https://github.com/apache/airflow/blob/master/LOCAL_VIRTUALENV.rst
https://github.com/apache/airflow/blob/master/BREEZE.rst#testing-and-debugging-in-breeze
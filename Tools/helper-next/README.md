# QQ Music 运行组件

这个目录是**构建时物化目录**，不是组件源码仓库，也不保存二进制真源。

精确版本、Release 资产与 SHA-256 只在
[`qqmusic/integration/components.lock.json`](../../qqmusic/integration/components.lock.json)
维护。执行：

```sh
./scripts/bootstrap.sh --component qqmusic
```

会下载并校验锁定的 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)
macOS Release 与 [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) macOS ARM64 资产。

生成的可执行文件、manifest 和许可证材料由 `.gitignore` 排除。HelperNext 的接口、端点与
协议实现属于 HelperNext 仓库；本仓库只维护宿主如何启动、配置和消费它，不复制组件内部知识。

应用优先从 `~/Library/Application Support/kmgccc.player/QQMusicHelperNext/` 加载外部组件，
bundle 内副本作为默认交付。外部替换后的可执行文件需要清除 quarantine/xattr 并重新做 ad-hoc 签名。

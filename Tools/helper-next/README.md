# HelperNext（在线音源的数据组件，构建产物）

这个目录放的是 **HelperNext 组件的构建产物**：`qqmusic-helper-next`（约 2.3 MB，静态链接，
无解释器）。应用优先从外部目录加载它：

```
~/Library/Application Support/kmgccc.player/QQMusicHelperNext/qqmusic-helper-next
```

bundle 内这份只是兜底。**源码不在本仓库**——在
[QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)（Rust，
基于 QQMusicApi 的跨平台组件）。要更新它：

```sh
git clone https://github.com/LeeDespo/QQMusicApi_HelperNext
cd QQMusicApi_HelperNext && cargo build --release
cp target/release/qqmusic-helper-next <本目录>/
cp target/release/qqmusic-helper-next \
  ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/
```

来源版本：可在运行中的应用「QQ 音乐设置 → Helper 组件」里看到组件版本与协议版本；
协议与旧 helper 逐字兼容（一行一个 JSON，响应回带 `id`），所以应用的进程客户端无需改动。

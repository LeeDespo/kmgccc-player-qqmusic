# QQ Music Changelog

这里只记录本 fork 的 QQ Music / fork 集成变化。播放器上游历史仍保留在根 `CHANGELOG.md`。

## [Unreleased]

- QQ Music 运行组件改为 lock + Release + SHA-256 物化，不再把可执行文件提交到 Git。
- replayable patch 开始覆盖 bootstrap 与 bundle 检查，避免 main 与补丁构建链漂移。

## [1.1.0]

- HelperNext 成为唯一 QQ Music 数据组件，淘汰旧 Python helper 与应用内第二套直连实现。
- 引入 Aria2 Next 下载引擎、下载任务 UI、限流/熔断配置与逐字歌词链路。
- 完善分页、喜欢写入和歌手/专辑等宿主兼容行为。

详见 [release-notes/v1.1.0.md](release-notes/v1.1.0.md)。

## [1.0.0]

首个公开 QQ Music patch Release；属于早期架构，已被后续版本替代。
详见 [release-notes/v1.0.0.md](release-notes/v1.0.0.md)。

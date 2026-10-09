# QQ Music Changelog

这里只记录本 fork 的 QQ Music / fork 集成变化。播放器上游历史仍保留在根 `CHANGELOG.md`。

## [1.2.0]

- 上游基线升级到 kmgccc_player 2.3.4 之后的 `main`，重新迁移并验证集成（含一处 git 看不出的语义冲突）。
- QQ Music 运行组件改为 lock + Release + SHA-256 物化，不再把可执行文件提交到 Git。
- 设置页的「组件」与「Aria2Next 下载引擎」各自带「更新组件」按钮，指向该组件自己的 Release 页面。
- 修复在线页空白：上游新增的宿主判定只认本地主页——全窗口宿主会被隐藏（AppKit 层），在线根要么不被
  构造、要么被画成透明不可点（SwiftUI 层）。现在「宿主画什么」只有一个判定，可见性与命中都跟随它。
- replayable patch 覆盖 bootstrap 与 bundle 检查，避免 main 与补丁构建链漂移。

详见 [release-notes/v1.2.0.md](release-notes/v1.2.0.md)。

## [1.1.0]

- HelperNext 成为唯一 QQ Music 数据组件，淘汰旧 Python helper 与应用内第二套直连实现。
- 引入 Aria2 Next 下载引擎、下载任务 UI、限流/熔断配置与逐字歌词链路。
- 完善分页、喜欢写入和歌手/专辑等宿主兼容行为。

详见 [release-notes/v1.1.0.md](release-notes/v1.1.0.md)。

## [1.0.0]

首个公开 QQ Music patch Release；属于早期架构，已被后续版本替代。
详见 [release-notes/v1.0.0.md](release-notes/v1.0.0.md)。

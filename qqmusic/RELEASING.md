# QQ Music Release Rules

> 本文件是本 fork 的 QQ Music 发布规则唯一真源。

## 身份与版本

本仓库是 kmgccc_player 维护型 fork。四类变化信息各有一个真源：

- 上游播放器版本：Xcode project 的 `MARKETING_VERSION`；
- QQ Music 功能版本：`QQMusicComponentProcess.patchVersion`；
- replayable patch 上游 commit：`qqmusic/integration/BASE`；
- HelperNext / Aria2 Next：`qqmusic/integration/components.lock.json`。

长期文档不得另抄“当前”版本或基线。

## Release 资产

正式 Release 可包含：

- `kmgccc_player-<upstream>+QQMusic.<patch>-arm64.dmg`；
- `...-patch.tar.gz`；
- `...-component.tar.gz`（便捷的派生组件包）。

component tar 不是第三方组件第二真源：它必须从 lock 指向的正式 Release 资产生成，并携带 lock、
HelperNext manifest/NOTICE/第三方许可证以及 Aria2 Next GPL 文本。

Tag 使用 `v<upstream-version>+QQMusic.<patch-version>`，并与应用报告的 patchVersion 对齐。

## 发布前

只从 clean tree 发布，并依次通过：

```sh
./qqmusic/check-repository-rules.sh
./qqmusic/integration/sync.sh --check
./scripts/verify.sh
./qqmusic/release.sh
```

同时确认 BASE 确实经过 replay 验证、component lock 能重新下载并校验、App bundle 带齐许可证材料。

## 打包与签名

`qqmusic/release.sh` 是正式本地打包入口。它读取版本、BASE 和 component lock，不在脚本里维护第二份快照。

当前发布采用 ad-hoc 签名，没有 Apple Developer ID / notarization。Release 和安装说明必须准确描述 Gatekeeper 状态。

## 历史

- 长期 QQ Music 变化：`qqmusic/CHANGELOG.md`；
- 单版本说明：`qqmusic/release-notes/v<patch-version>.md`；
- 通用安装文案：`qqmusic/release/*.template.md` 或无版本模板。

不要保留 `notes.md` 作为“最新说明”。

## 禁止事项

- dirty tree 发布；
- 直接维护 integration 生成物后打包；
- 把 HelperNext/Aria2 可执行文件提交进 Git；
- 本地随手重编 HelperNext 作为正式资产；
- component tar 脱离 lock；
- patch 未从 BASE 重放验证就发布；
- 恢复继承自上游、但本 fork 不运营的 Pages/FUNDING/更新元数据。

# AGENTS.md

本文件只负责本 fork 的**身份、边界、真源路由和质量门**。实现细节不要复制到这里。

## Repository Role

本仓库是 `kmgccc_player` 的 QQ 音乐维护型 fork，同时发布可重放到明确上游基线的 patch package。

- `main`：实际可构建、可测试、可发布的集成工作树，是宿主代码真源。
- `qqmusic/integration/`：从工作树相对上游基线生成的发行表示，不是第二套手工源码。
- GitHub fork 关系是长期架构的一部分，不应为了“独立”而去掉。

## Boundaries

**本仓库负责**

- QQ Music 的 Swift UI、导航、状态、缓存、播放/下载入库与设置；
- HelperNext 子进程的生命周期、配置、请求/响应适配和兼容性边界；
- 上游 kmgccc_player 的集成改动与 replayable patch；
- 本 fork 的测试、组件锁、打包与 Release。

**本仓库不负责**

- QQ Music endpoint/module/method/queryId、签名算法和响应解析知识库；
- HelperNext 内部实现、Aria2 Next 内部实现；
- 复制第三方仓库源码或把下载的可执行文件当 Git 源码维护。

需要修改上游协议行为时去 `QQMusicApi_HelperNext`；本仓库只改变宿主消费契约。

## Sources of Truth

| 主题 | 真源 |
|---|---|
| 实际 QQ Music 宿主实现 | `kmgccc_player/Services/QQMusic/`、`kmgccc_player/Views/QQMusic/` 及对应集成改动 |
| 宿主行为测试 | `kmgccc_playerTests/` 中相关测试 |
| QQ Music 功能版本 | `QQMusicComponentProcess.swift` 的 `patchVersion` |
| replayable patch 上游基线 | `qqmusic/integration/BASE` |
| replayable patch 内容 | 工作树经 `qqmusic/integration/sync.sh` 生成；禁止直接维护生成文件 |
| HelperNext / Aria2 精确版本与 SHA | `qqmusic/integration/components.lock.json` |
| QQ Music 架构/功能入口 | `qqmusic/README.md` |
| 发布规则 | `qqmusic/RELEASING.md` |
| QQ Music 版本历史 | `qqmusic/CHANGELOG.md` + `qqmusic/release-notes/` |
| 上游播放器通用技术文档 | `docs/` |

## Change Routing

- 改 QQ Music 功能 → 改生产工作树与测试，再运行 `qqmusic/integration/sync.sh`。
- 改已有上游文件 → 同样先改工作树；对应 patch 由 sync 生成。
- 新增文件 → 先放真实目标路径；对应 `modules/` 副本由 sync 生成。
- 删除基线文件 → 由 sync 写入 `removals.txt`。
- 更新 HelperNext / Aria2 → 只改 `components.lock.json`，通过 bootstrap 验证资产与许可证。
- 升级上游基线 → 先完成真实迁移和测试，再更新 BASE 并重新生成全部 patch 表示。
- 发布 → 只遵循 `qqmusic/RELEASING.md`。

## Non-negotiable Rules

- 不直接编辑 `qqmusic/integration/modules/` 或 `patches/` 来实现功能。
- 不在 Swift、README 或 AGENTS 复制 HelperNext endpoint 实现知识。
- 不重新引入应用内第二套 QQ Music HTTP 客户端作为“兜底”。
- 不把 HelperNext / Aria2 可执行文件提交进 Git。
- 不让本地笔记、旧方案或已合并 feature branch 继续成为活文档依赖。
- 仓库整理不得顺手重构与当前治理无关的播放器业务代码。

## Quality Gates

提交前按顺序执行：

```sh
./qqmusic/check-repository-rules.sh
./qqmusic/integration/sync.sh --check
./scripts/verify.sh
```

`verify.sh` 会 bootstrap 锁定组件、构建 ARM64 App、跑回归/XCTest 并检查 App bundle。
真实账号或会改变账号状态的验证不属于默认 CI。

<div align="center">
  <h1>kmgccc_player · QQ Music</h1>
  <p>为 kmgccc_player 集成 QQ 音乐在线内容、播放与下载的维护型 Fork</p>
  <a href="https://github.com/LeeDespo/kmgccc-player-qqmusic/actions/workflows/macos-ci.yml"><img src="https://github.com/LeeDespo/kmgccc-player-qqmusic/actions/workflows/macos-ci.yml/badge.svg?branch=main" alt="macOS CI"></a>
  <a href="https://github.com/LeeDespo/kmgccc-player-qqmusic/releases"><img src="https://img.shields.io/github/v/release/LeeDespo/kmgccc-player-qqmusic?label=release" alt="Release"></a>
  <a href="https://github.com/LeeDespo/kmgccc-player-qqmusic/blob/main/LICENSE.txt"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="AGPL-3.0"></a>
  <a href="https://github.com/kmgcc/kmgccc_player"><img src="https://img.shields.io/badge/project-maintained%20fork-purple" alt="Maintained fork"></a>
</div>

---

> [!IMPORTANT]
> **音乐平台不易，请尊重版权，支持正版。**
>
> 本项目是 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 的**非官方 QQ 音乐维护型 Fork**，与腾讯 / QQ 音乐无官方关系。当前提供的 macOS 安装包采用 ad-hoc 签名，**未经 Apple 公证**；首次启动请阅读对应 [Release 的安装说明](https://github.com/LeeDespo/kmgccc-player-qqmusic/releases)。

## 📖 项目介绍

**本仓库是在 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 基础上维护的完整播放器应用**，不是只存放补丁的工具仓库。

它保留上游播放器的源码与 GitHub Fork 关系，将 QQ 音乐在线浏览、登录、搜索、播放、下载入库、歌词及设置接入现有本地曲库与播放体验。同时提供 [可重放补丁包](qqmusic/integration/README.md)，以便审计并重建相对指定上游基线的改动。

项目的 QQ 音乐协议能力由独立的 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) 提供；**本仓库只维护播放器的宿主集成与发行**，不复制其接口、签名或响应解析实现。

## ✨ 功能概要

| 模块 | 功能 |
|---|---|
| 🧭 **在线浏览** | 首页推荐、歌单、专辑、歌手、排行榜、电台及在线搜索 |
| 👤 **账号与收藏** | QQ / Web 登录、登录状态、账号相关曲库内容 |
| 🎵 **播放与歌词** | 在线播放衔接播放器现有播放链，支持逐字歌词 |
| 📥 **下载与入库** | 下载任务与进度、暂停 / 继续 / 取消、音质偏好；下载歌曲进入本地资料库 |
| 🖼️ **封面与元数据** | 在线与本地曲目的封面、元数据补全 |
| ⚙️ **宿主集成** | QQ 音乐设置、状态管理、缓存与运行组件管理 |

功能范围及 Swift 宿主架构见 [QQ Music 集成文档](qqmusic/README.md)。具体接口行为与可用方法以 [HelperNext 仓库](https://github.com/LeeDespo/QQMusicApi_HelperNext) 为准。

## 🚀 快速开始

### 下载与安装

前往 **[GitHub Releases](https://github.com/LeeDespo/kmgccc-player-qqmusic/releases)** 下载适合的 DMG 安装包。

| 项目 | 当前交付范围 |
|---|---|
| **系统** | macOS 26 或更新版本 |
| **架构** | Apple Silicon（ARM64） |
| **分发形式** | DMG；ad-hoc 签名、未公证 |
| **账号与资料库** | QQ 音乐内容下载入库需使用可写的托管资料库 |

> [!NOTE]
> 未经 Apple Developer ID 签名及公证不代表安装包已获系统信任。请按 [Release 说明](https://github.com/LeeDespo/kmgccc-player-qqmusic/releases) 进行首次启动操作，不要把手动放行理解为应用通过了 Apple 公证。

### 从源码构建

需要 Apple Silicon Mac、macOS 26+ 及兼容的 Xcode（项目 CI 使用 Xcode 26 系列）。

```sh
git clone --recurse-submodules https://github.com/LeeDespo/kmgccc-player-qqmusic.git
cd kmgccc-player-qqmusic

./scripts/bootstrap.sh
./scripts/verify.sh
```

[bootstrap](scripts/bootstrap.sh) 会根据 [组件锁文件](qqmusic/integration/components.lock.json) 下载、校验并准备运行时组件；[verify](scripts/verify.sh) 则执行 ARM64 构建、回归测试、XCTest 与 App bundle 完整性检查。第三方组件的下载产物**不进入 Git**。

### 使用可重放补丁包

除了直接安装 App，[Releases](https://github.com/LeeDespo/kmgccc-player-qqmusic/releases) 还提供供审计和重建使用的补丁包：

| 资产 | 用途 |
|---|---|
| **DMG** | 直接安装播放器 |
| **Patch tar.gz** | 将本 Fork 的改动重放到指定上游基线 |
| **Component tar.gz** | 按锁定版本派生的便捷组件包，不是独立组件真源 |

基线以 [integration/BASE](qqmusic/integration/BASE) 为准，应用方式见 [补丁使用说明](qqmusic/integration/README.md)。在本仓库的完整 Git checkout 中，可直接验证干净基线重放：

```sh
./qqmusic/integration/verify-replay.sh
```

## 🧩 组件边界与真源

```text
kmgccc_player（Swift UI / 缓存 / 播放 / 下载入库）
                       │
                       ▼
           QQMusicComponentProcess
                       │ stdio / JSON lines
                       ▼
             QQMusicApi_HelperNext
                       │
                       ├── QQ 音乐请求、签名、解析与凭据
                       └── Aria2 Next（可选下载引擎）
```

| 内容 | 权威位置 |
|---|---|
| **播放器与宿主实现** | [kmgccc_player/](kmgccc_player/) |
| **QQ 音乐行为测试** | [kmgccc_playerTests/](kmgccc_playerTests/) |
| **协议与组件实现** | [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) |
| **可选下载引擎** | [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) |
| **组件版本与 SHA-256** | [components.lock.json](qqmusic/integration/components.lock.json) |
| **上游补丁基线** | [integration/BASE](qqmusic/integration/BASE) |
| **发布与版本规则** | [qqmusic/RELEASING.md](qqmusic/RELEASING.md) |

[modules/](qqmusic/integration/modules/) 与 [patches/](qqmusic/integration/patches/) 是从生产工作树生成的发行表示，**不是第二套需要手工维护的源码**。修改应用后通过 [sync.sh](qqmusic/integration/sync.sh) 更新，CI 同时检查内容一致性和干净基线重放。

## 🛠️ 开发与质量验证

开发和贡献前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；问题应提交到负责该行为的仓库。

```sh
./qqmusic/check-repository-rules.sh
./qqmusic/integration/sync.sh --check
./qqmusic/integration/verify-replay.sh
./scripts/verify.sh
```

[macOS CI](https://github.com/LeeDespo/kmgccc-player-qqmusic/actions/workflows/macos-ci.yml) 会自动检查仓库边界、补丁一致性、全仓残留、干净上游重放，以及构建、测试和 App bundle 完整性。上游播放器的通用问题请优先反馈至 [kmgccc_player 上游仓库](https://github.com/kmgcc/kmgccc_player)；本 Fork 的集成问题可通过 [Issues](https://github.com/LeeDespo/kmgccc-player-qqmusic/issues) 反馈。

## 📚 文档导航

* **[qqmusic/README.md](qqmusic/README.md)** —— QQ 音乐宿主架构、组件职责和功能边界
* **[qqmusic/integration/README.md](qqmusic/integration/README.md)** —— 可重放补丁的生成、应用与验证
* **[qqmusic/RELEASING.md](qqmusic/RELEASING.md)** —— 版本、组件资产、许可证与发布规则唯一真源
* **[qqmusic/CHANGELOG.md](qqmusic/CHANGELOG.md)** —— QQ 音乐长期变更记录
* **[docs/README.md](docs/README.md)** —— 播放器通用技术文档入口
* **[CONTRIBUTING.md](CONTRIBUTING.md)** —— 贡献流程和问题归属
* **[SECURITY.md](SECURITY.md)** —— 安全问题报告方式
* **[AGENTS.md](AGENTS.md)** —— Agent 的仓库边界与真源路由

## ⚠️ 用途与版权声明

QQ 音乐相关能力用于个人使用、技术研究与互操作性验证。请尊重平台服务条款、版权及其他权利人的合法权益；不要将本项目视为腾讯或 QQ 音乐官方客户端。

本声明说明项目定位，**不构成对开源许可证的额外限制**。具体源码授权以仓库许可证为准。

## 📄 许可证与致谢

* **本项目及上游应用源码**：[AGPL-3.0](LICENSE.txt)。
* **QQMusicApi_HelperNext**：[GPL-3.0-or-later](https://github.com/LeeDespo/QQMusicApi_HelperNext/blob/main/LICENSE)。
* **Aria2 Next**：[GPL-2.0](https://github.com/AnInsomniacy/aria2-next/blob/main/COPYING)。
* 其他第三方来源与分发边界见 [NOTICE](NOTICE)，具体构建产物的许可证随运行组件打包。

感谢 [kmgcc/kmgccc_player](https://github.com/kmgcc/kmgccc_player) 的播放器基础，以及 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) 与 [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) 的独立组件维护。

## 致谢

上游播放器在开发过程中使用并修改了以下开源项目：

- **[applemusic-like-lyrics (AMLL)](https://github.com/amll-dev/applemusic-like-lyrics)** — 歌词背景网格动效，通过项目维护的 [integration fork](https://github.com/kmgcc/applemusic-like-lyrics-kmgcccplayer-integration) 集成
- **[MelismaKit](https://github.com/kmgcc/melismakit)** — 原生 Swift 歌词排版与动效渲染引擎
- **[LDDC](https://github.com/chenmozhijin/LDDC)** — 歌词获取与匹配
- **[apple-audio-visualization](https://github.com/taterboom/apple-audio-visualization)** — 音频频谱分析与可视化算法
- **[ncmdump](https://github.com/taurusxin/ncmdump)** — NCM 格式解密
- **[sacad](https://github.com/desbma/sacad)** — 专辑封面搜索与下载
- **[QQMusicApi](https://github.com/L-1124/QQMusicApi)** — QQ 音乐元数据与封面查询
- **[MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter)** — macOS 外部播放状态读取与控制
- **[WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit)** — 应用更新说明展示
- **[PLCrashReporter](https://github.com/microsoft/plcrashreporter)** — 主 App 进程崩溃报告捕获
- **[Sparkle](https://github.com/sparkle-project/Sparkle)** — 软件自动更新检查与交付框架

## 常见问题

- **AMLL submodule 缺失或 commit 不一致**：运行 `git submodule sync --recursive`，再 `git submodule update --init --recursive`。
- **找不到 node 或 corepack**：安装 Node.js 22，确认两个命令都在 PATH 中。
- **Python 版本或架构不符**：安装 ARM64 Python 3.12，或用 `KMGCCC_ARM_PYTHON=/path/to/python3.12 ./scripts/bootstrap.sh` 指定。
- **找不到 CMake**：安装 CMake 3.15 或更新版本（MediaRemoteAdapter 需要）。
- **Xcode 报外部组件产物缺失**：回到仓库根目录运行 `./scripts/bootstrap.sh`。
- **产物被判定为 stale**：用 `./scripts/bootstrap.sh --force --component <name>` 重建对应组件。失败时查看 `.build/logs/`。
- **Swift Package 解析失败**：确认网络可访问 GitHub 后重试。

## 参与贡献

缺陷和功能建议可提交到 [GitHub Issues](https://github.com/LeeDespo/kmgccc-player-qqmusic/issues)。请先搜索已有 Issue，附上 macOS 版本、Mac 架构、复现步骤和预期结果。安全问题不要发公开 Issue，请按 `SECURITY.md` 的私密渠道报告；上游播放器本身的缺陷请提到 [上游仓库](https://github.com/kmgcc/kmgccc_player/issues)。

贡献代码前请阅读 `CONTRIBUTING.md`。

## 美术素材版权声明

除代码及另有说明的第三方内容外，本项目相关的美术素材（包括界面插画、UI 装饰、贴图、角色设计、图形元素及其他视觉素材）均为作者原创作品，著作权及相关权利均由作者保留。未经作者事先书面授权，不得复制、转载、分发、修改、改编、商用、二次创作、提取，或用于机器学习与生成式 AI 相关用途。

保留一切权利。Copyright © kmg. All rights reserved.

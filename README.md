<p align="center">
  <img src="pages/assets/icon.png" width="192" alt="kmgccc_player Icon" />
</p>

<h1 align="center">kmgccc_player</h1>

<p align="center">
  面向 macOS 26 的本地音乐播放器。<br>
  原生开发，注重美学与沉浸式体验。
</p>

> [!WARNING]
> kmgccc_player 是个人项目，可能存在缺陷、未完成特性或行为变动。不建议在重要环境中作为唯一播放器使用。欢迎通过官网或 Issue 反馈问题。

[kmgccc_player 官网](https://player.kmgccc.cn)

作为喜欢音乐，绘画多年的枸，我想为音乐播放器添加一份随性与独特的美感。感谢你的使用和喜欢！

## 本仓库是什么

这是 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 的一个改版（folk）：保留原应用的全部本地能力，**在上面加装 QQ 音乐在线音源**——在线浏览、搜索、试听、下载入库，以及围绕它的缓存与批量下载。

玩法与原应用一致：**在线歌曲先下载、再走原有导入管线入库、最后交给原有播放引擎播放**。因此无缝播放、原生歌词、频谱、Now Playing、多选排序全部自动继承，播放引擎一行没改。切歌不卡是因为协调器在你听当前这首时已经把后面的下载好了。

- **浏览器式的页面**：落地页的歌单/专辑/排行榜/电台推荐，详情页是原应用那套 220pt 头部 + 曲目行；返回/前进、搜索、刷新、批量下载都在**窗口工具栏**里，和原应用同一层玻璃、同一套交互。
- **歌曲列表照原应用**：整行单击播放，行尾是「更多」菜单（播放 / 下一首播放 / 查看详情 / 查看艺人 / 查看专辑）；选择下载时靠**整行变色**表示选中，连续选中连成一块。
- **缓存分两类**：歌单、推荐、排行榜、浏览态封面缓存在资料库的 `QQMusic/` 目录（与应用自身的 `Cache/` 平级且分开）；歌词不单缓存——下载时取一次，随导入写进曲库。
- **歌曲缓存只约束自动下载的部分**：只有为了播放而预取的才算缓存、可回收；你自己点过下载的属于曲库，永不回收。

功能细节、设计取舍与全部踩过的坑见 **`qqmusic/README.md`** 与 `AGENTS.md`。

## 目录结构

上游的文件保持原样（补丁包的 `patches/` 会明确记录我们改过哪几处），本功能自己的东西集中在一处：

```
kmgccc_player/            应用源码：上游 + 本功能的接入点改动（就地）
kmgccc_playerTests/       测试（含本功能自己的测试）
qqmusic/                  ← 本功能除源码之外的一切
  integration/            补丁包：modules/（新文件）+ patches/（上游 diff）+ 脚本
  README.md               功能说明、目录划分、维护指南
upstream/                 未改动的上游源码，冻结参照（不进仓库）
testarea/                 每次从 upstream/ 重建的测试区（不进仓库）
docs/qqmusic/             设计、方案与实现记录（不进仓库）
```

## 从源码构建（本仓库）

```sh
./scripts/bootstrap.sh                      # 构建外部组件（含 QQ 音乐 helper）
./scripts/build_and_run.sh                  # 构建并运行
```

本机注意：工程里钉的是原作者的签名 team，你需要用**自己的** team id 覆盖：

```sh
DEVELOPMENT_TEAM=<你的 teamID> ./scripts/build_and_run.sh
```

helper 重建后要同步到外部目录才会被优先使用（`test-cycle.sh` 会自动做）：

```sh
cp -R .build/products/qqmusic-helper/* \
  ~/Library/Application\ Support/kmgccc.player/QQMusicHelper/
```

## 打补丁（把本功能植入任意上游版本）

补丁包是功能的**可重放形式**：把它应用到一个未改动的上游源码上，就得到完整功能。
所以「本仓库 = 上游 + 一份可审计的变更集」，上游更新时把功能搬过去即可，不必手工重做。

```sh
cp -R qqmusic/integration /path/to/kmgccc_player/
cd /path/to/kmgccc_player
./qqmusic/integration/apply.sh --repo . --verify
./scripts/bootstrap.sh --component qqmusic-helper
./scripts/build_and_run.sh
```

改完功能之后同步补丁包，并在**干净基线**上跑完整循环（重建 → 重放 → 构建 → 测试 → 启动）：

```sh
./qqmusic/integration/sync.sh          # 从开发树重新生成 modules/ + patches/
./qqmusic/integration/test-cycle.sh --sync
```

补丁应用失败是**预期行为**：表示上游动了同一处，需要人工移植意图。步骤见 `qqmusic/integration/README.md`。

## 参考的项目

本功能建立在原应用之上，另外用到：

- **[qqmusic-api-python](https://github.com/L-1124/QQMusicApi)** — QQ 音乐接口的 Python 实现，helper 的目录、排行、电台、歌手、歌词与取流都走它
- **[kmgccc_player](https://github.com/kmgcc/kmgccc_player)**（上游）—— 播放器本体；它的 README 下文列出的 AMLL、LDDC、SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础

## 主要功能

- **现代本地曲库**：支持多资料库独立管理与原位目录引用，无需移动或复制音频文件即可直接映射既有文件夹，并提供专辑、艺人与文件夹层级平行的双轴浏览体验。
- **原生 Swift 歌词**：采用纯原生 Core Text 排版与 Core Animation 动效管线，紧随音频硬件时钟起伏实现细腻的逐字呼吸与弹簧滚动，能耗与发热显著降低，并完美支持 ProMotion 120Hz 高刷新率。
- **外部播放协同**：无缝读取 Apple Music 及系统全局媒体的正在播放状态，自动关联高精度歌词与高清封面。
- **多元视听皮肤**：内置多款精心调校的 Now Playing 与全屏皮肤，支持随乐曲脉动的多形态实时音频频谱与波形可视化。
- **动态色彩系统**：从专辑封面中提炼具有视觉张力的 OKLCH 语义色，自适应生成舒适通透的视窗质感与高可读性歌词配色。
- **纯粹本地优先**：全部元数据解析、全文搜索索引与偏好统计皆在 Mac 本地无声运行，无需注册账号，零网络依赖，尊重听者的隐私与数据掌控。

## 系统要求

- macOS 26.0 或更新版本
- Apple Silicon Mac

## 从源码构建

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
./scripts/bootstrap.sh
./scripts/verify.sh
open kmgccc_player.xcodeproj
```

如果已经用普通 `git clone` 下载，先补齐 submodule：

```sh
git submodule update --init --recursive
```

`bootstrap.sh` 会下载并构建 AMLL、LDDC Fetch Core、QQ Music Helper、MediaRemoteAdapter 和 SACAD 五个外部运行组件。首次运行需要下载依赖并编译多个 ARM64 产物，耗时较长；之后会比对源码和工具链状态，未变化的组件直接复用缓存。

`verify.sh` 在提交改动前运行，依次执行 bootstrap、ARM64 Debug 构建、LRC 回归测试、单元测试和 App bundle 检查。

构建并运行 Debug App：

```sh
./scripts/build_and_run.sh
```

验证 Release 构建及 App bundle 完整性：

```sh
./scripts/build_app.sh Release
```

本机可选构建输入通过 `Config/LocalOverrides.xcconfig` 配置；可从同目录的 `.example` 复制。该文件缺失时工程照常构建，`verify.sh` 与 `build_app.sh` 会显式禁用本机构建扩展，确保结果可由 clean clone 复现。

开发环境需要：

- Xcode 26.2 或更新版本（Swift 6）
- Node.js 22（含 Corepack）
- ARM64 Python 3.12
- CMake 3.15 或更新版本
- Git、curl 和 Xcode Command Line Tools

外部组件的详细说明见 `docs/dependencies.md`。

## 技术文档

我们在 [`docs/README.md`](docs/README.md) 中系统梳理了应用的架构理念、核心算法与工程实现，文档面向开源贡献者与对实现细节感兴趣的开发者：

- [应用架构](docs/architecture.md)：应用组合根、资料库 Session 隔离、本地与外部播放主链路及统一展示模型；
- [原生 Swift 歌词系统](docs/native-lyrics.md)：Core Text 字体排版度量、Core Animation 遮罩动效、弹簧物理滚动与硬件时钟同步；
- [现代本地音乐资料库体系](docs/library-system.md)：原位引用与托管双模式、多资料库隔离、标签与目录双轴浏览哲学；
- [色彩系统](docs/color-system.md)：基于 OKLCH 与 Display P3 的封面取色、语义映射与局部可读性算法；
- [曲库搜索](docs/search.md) 与 [偏好随机播放](docs/smart-shuffle.md)：基于 SQLite FTS5 的本地检索以及结合听觉行为的探索衰减模型；
- [实现约束与坑](docs/PITFALLS.md)：关键业务逻辑中生效的硬性约束与避坑备忘录。

## 常见问题

- **AMLL submodule 缺失或 commit 不一致**：运行 `git submodule sync --recursive`，再 `git submodule update --init --recursive`。
- **找不到 node 或 corepack**：安装 Node.js 22，确认两个命令都在 PATH 中。
- **Python 版本或架构不符**：安装 ARM64 Python 3.12，或用 `KMGCCC_ARM_PYTHON=/path/to/python3.12 ./scripts/bootstrap.sh` 指定。
- **找不到 CMake**：安装 CMake 3.15 或更新版本（MediaRemoteAdapter 需要）。
- **Xcode 报外部组件产物缺失**：回到仓库根目录运行 `./scripts/bootstrap.sh`。
- **产物被判定为 stale**：用 `./scripts/bootstrap.sh --force --component <name>` 重建对应组件。失败时查看 `.build/logs/`。
- **Swift Package 解析失败**：确认网络可访问 GitHub 后重试。

## 参与贡献

缺陷和功能建议可提交到 [GitHub Issues](https://github.com/kmgcc/kmgccc_player/issues)。请先搜索已有 Issue，附上 macOS 版本、Mac 架构、复现步骤和预期结果。安全问题不要发公开 Issue，请按 `SECURITY.md` 的私密渠道报告。

贡献代码前请阅读 `CONTRIBUTING.md`。

## 致谢

本项目在开发过程中使用并修改了以下开源项目：

- **[applemusic-like-lyrics (AMLL)](https://github.com/amll-dev/applemusic-like-lyrics)** — 歌词渲染引擎，通过项目维护的 [integration fork](https://github.com/kmgcc/applemusic-like-lyrics-kmgcccplayer-integration) 集成
- **[LDDC](https://github.com/chenmozhijin/LDDC)** — 歌词获取与匹配
- **[apple-audio-visualization](https://github.com/taterboom/apple-audio-visualization)** — 音频频谱分析与可视化算法
- **[ncmdump](https://github.com/taurusxin/ncmdump)** — NCM 格式解密
- **[sacad](https://github.com/desbma/sacad)** — 专辑封面搜索与下载
- **[QQMusicApi](https://github.com/L-1124/QQMusicApi)** — QQ 音乐元数据与封面查询
- **[MediaRemote Adapter](https://github.com/ungive/mediaremote-adapter)** — macOS 外部播放状态读取与控制
- **[WhatsNewKit](https://github.com/SvenTiigi/WhatsNewKit)** — 应用更新说明展示
- **[PLCrashReporter](https://github.com/microsoft/plcrashreporter)** — 主 App 进程崩溃报告捕获

## 美术素材版权声明

除代码及另有说明的第三方内容外，本项目相关的美术素材（包括界面插画、UI 装饰、贴图、角色设计、图形元素及其他视觉素材）均为作者原创作品，著作权及相关权利均由作者保留。未经作者事先书面授权，不得复制、转载、分发、修改、改编、商用、二次创作、提取，或用于机器学习与生成式 AI 相关用途。

保留一切权利。Copyright © kmg. All rights reserved.

## 许可证

代码基于 GNU Affero General Public License v3.0 (AGPL-3.0) 发布。第三方组件遵循各自的开源许可证，详见应用内 About 页面及 `Licenses` 目录。

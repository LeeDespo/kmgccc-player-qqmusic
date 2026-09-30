<p align="center">
  <img src="pages/assets/icon.png" width="192" alt="kmgccc_player Icon" />
</p>

<h1 align="center">kmgccc_player + QQ 音乐在线音源</h1>

<p align="center">
  <b>上游 2.3.1 + QQMusic 1.0.0</b><br>
  给 <a href="https://github.com/kmgcc/kmgccc_player">kmgccc_player</a> 加装 QQ 音乐在线音源的一份补丁包。
</p>

> [!WARNING]
> 本仓库是个人改版，只对**上游 `b0de7aa6`（2.3.1）**验证过，没有 Apple 开发者签名，也没有公证。
> 上游是个人项目（作者原话：可能存在缺陷、未完成特性或行为变动），本补丁继承了这一点。

## 一、这个仓库是什么

**它不是播放器的另一个分支，而是一份可重放的变更集。**

- 播放器本体是 [kmgccc_player](https://github.com/kmgcc/kmgccc_player)，版权与实现都属于原作者。
- 本仓库在它之上**只做加法**：给应用加一个 QQ 音乐在线音源（浏览、搜索、播放、下载入库、收藏）。
- 所以本仓库 = **上游 2.3.1 + 一份可审计的变更集**。变更集以补丁包
  （[`qqmusic/integration/`](qqmusic/integration/)：`modules/` 新文件 + `patches/` 对上游文件的 diff）的形式存在，
  把它应用到一个未改动的上游源码上就得到完整功能，上游更新时可以把功能搬过去，而不必手工重做。

想直接用它：[下载 Release](../../releases) 里的 DMG。想自己从源码构建、或把功能搬到别的上游版本上：
看下面的「[打补丁](#四打补丁把本功能植入上游源码)」，补丁包同样在 Release 页附件里。

## 二、这个补丁加了什么

保留原应用的全部本地能力，在其之上加一个 QQ 音乐在线音源：

- **浏览**——落地页顶部是精选大卡片（取「猜你喜欢」，可换一首；卡面显示歌曲简介，文字颜色按封面明暗自动取深/浅），
  往下是收藏歌单、收藏专辑、关注的歌手、新歌电台、排行榜、电台、猜你喜欢，可下钻到歌单 / 专辑 / 排行榜 /
  电台 / 歌手详情页。返回、前进、搜索、刷新、批量下载都在**窗口工具栏**里，与原应用同一层玻璃、同一套交互。
  搜索分歌曲 / 歌手 / 专辑 / 歌单四类；歌手页的歌曲与专辑都可按热门或最新排序；歌手简介与原应用一样
  可以就地滚动、点开读全文。
- **播放**——点击列表任意一行即从这一行开始播：顺序播放往下走到表尾，随机播放覆盖**整张**在线列表
  （而不是只覆盖已下载的那几首）。在线歌曲**先下载、经原有导入管线入库、再交给原有播放引擎播放**，
  因此无缝播放、原生歌词、频谱、Now Playing、播放历史全部自动继承，播放引擎一行没改。
- **账号**——扫码或网页登录（两者等价）；「我喜欢」、收藏歌单、收藏专辑；行内收藏/取消收藏写回上游。
- **缓存与回收**——歌单、推荐、排行榜与浏览态封面缓存在资料库的 `QQMusic/` 目录（与应用自身的 `Cache/` 平级且分开）；
  歌曲缓存只约束「为了播放而自动下载」的那部分，可设上限并回收——你自己点过下载的属于曲库，永不回收。
- **一个数据组件，与应用解耦**——在线内容的读取、登录、限流与熔断都在独立进程里
  （HelperNext 组件），应用只跟它说 JSON；上游接口变化时换那个二进制即可，无需重新构建应用。

同时**关闭了自动更新、崩溃上报与匿名统计**（默认关且不可再开）：更新源属于上游项目，装上去会覆盖本版本的功能
改动；崩溃与匿名统计会发到上游作者的服务器，而对方无法据此做任何事。

功能细节、设计取舍与全部踩过的坑见 [`qqmusic/README.md`](qqmusic/README.md)。

## 三、数据组件（HelperNext）

在线音源的接口调用只有一层：**HelperNext 组件**——一个静态链接的 Rust 二进制
（约 2.4 MB，无解释器、无第三方 SDK），应用通过 stdin/stdout 一行一个 JSON 跟它说话。

```
kmgccc_player（Swift）
   │  stdin/stdout 一行一个 JSON   {"id","method","params"} → {"id","ok",…}
   ▼
qqmusic-helper-next（Tools/helper-next/qqmusic-helper-next，构建产物）
   │  HTTPS（组件内部：签名、cookie、限流、熔断）
   ▼
腾讯的接口
```

**它顶替了两样东西**：上一版的 Python helper（内含整个解释器与 `qqmusic-api-python`，约 56 MB）
和**应用内的 HTTP 客户端** `QQMusicWebAPI`。以后者为例：同一个能力有两份实现时，
"一条坏了另一条兜底"掩盖的是它们的行为差异，而落库与缓存判断还得同时考虑两者——
合并之后，上游变化只换这一个二进制。组件里的请求参数与解析路径是从 `qqmusic-api-python`
逐条比对来的（包括它的坑：`ptqrtoken` 用 seed 0 的 `hash33`，而 `g_tk` 用 5381）。

**组件自己管凭据**：`…/QQMusicHelperNext/Credential/qqmusic-credential.json`。
扫码登录与网页登录两条路径产出的都是 `uin` + `qm_keyst` 这一对 cookie，二者等价
（`qm_keyst` 同时就是 VIP 取流所需的播放票据）。

**应用优先加载外部那份**（`~/Library/Application Support/kmgccc.player/QQMusicHelperNext/`），
bundle 内的只是兜底——所以使用者的修法是"替换那个文件"，而不是重装应用。
**源码不在本仓库**：在 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)，
本仓库只放构建产物与它的 README（含兼容性约定）。

**保留下来的 Python helper**：`Tools/QQMusicHelper/`（上游的目录，我们改过 `main.py`）仍在仓库里，
`bootstrap.sh` 也仍会构建它，但**应用的代码已不再引用**——它作为回退路径存在，
换回去的办法是重新构建并让应用指向旧目录。这段历史记录在 `Tools/helper-next/README.md`。
一个如实的补充：应用侧**只显示**组件自报的版本号（设置 → Helper 组件），**没有版本闸门**——
换上一个响应形状不兼容的组件，表现会是某个页面报错或字段变空，而不是启动时明确拒绝。

## 四、打补丁（把本功能植入上游源码）

```sh
# 1. 拿到基线源码
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
git checkout b0de7aa6

# 2. 应用补丁包（Release 附件里的 tar.gz，或本仓库的 qqmusic/integration/）
cp -R /path/to/kmgccc_player-2.3.1+QQMusic.1.0.0-patch/integration ./qqmusic/integration
./qqmusic/integration/apply.sh --repo . --verify

# 3. 构建（helper 需要 Python 3.12 / Node 22 / CMake）
./scripts/bootstrap.sh
DEVELOPMENT_TEAM=<你的 team id> ./scripts/build_and_run.sh
```

这几条**已验证**：在一份干净的 `b0de7aa6` 上应用补丁包后照抄执行，构建成功、应用能启动。
工程里钉的是**上游作者**的签名 team，别人用不了，所以要覆盖成你自己的——本补丁包对
`scripts/build_and_run.sh` 的唯一改动就是把这个环境变量转发给 `xcodebuild`（没有证书可以改用
`CODE_SIGNING_ALLOWED=NO ./scripts/build_and_run.sh`；`Config/LocalOverrides.xcconfig` 改不动它，
那个 key 写在工程的 target build settings 里，优先级更高）。

补丁应用失败是**预期行为**：`patches/` 里的 diff 只有在上下文仍然匹配时才干净应用，上游动了同一处就会失败——
输出会指名是哪个文件、哪份补丁，一条失败不挡住其余的。步骤与移植办法见
[`qqmusic/integration/README.md`](qqmusic/integration/README.md)。

不想本地编译 helper？Release 里那份 DMG 中的应用已经带了构建好的 helper，复制过去即可：

```sh
cp -R /Applications/kmgccc_player.app/Contents/Resources/Tools/qqmusic-helper/* \
      ~/Library/Application\ Support/kmgccc.player/QQMusicHelper/
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelper   # 不能省，见下
```

第二行不能省：从下载来的 DMG 复制出的文件带 `com.apple.quarantine`，带隔离属性的 helper 会被系统直接杀掉
（退出码 137），而应用只会写一行日志——表现是"在线音源整个不工作"，看起来像接口失效。

## 五、安装 DMG 版

把 `kmgccc_player.app` 拖进「应用程序」。应用是 **ad-hoc 签名**（`codesign -s -`）：没有开发者证书、
没有 TeamID、没有公证。这不是"坏了"，但也不是"受信任"——从网上下载后 Gatekeeper 会拦一次，
提示大意是"Apple 无法验证它是否包含恶意软件 / 来自身份不明的开发者"，**不会**提示"已损坏"。
放行任选一种（第一条在任何 macOS 版本上都管用）：

```sh
xattr -dr com.apple.quarantine /Applications/kmgccc_player.app
```

- 或者先双击一次让它被拦下，然后 **系统设置 → 隐私与安全性 → 安全性 → 仍要打开**。
  （macOS 15 起 Apple 取消了"右键 → 打开"这条快捷方式，只在更旧的系统上还有效。）

为什么可以确认不是"已损坏"：打包脚本在写完构建戳记后做 ad-hoc 签名，并**断言**
`codesign --verify --deep --strict` 通过（这一步在 `qqmusic/release.sh` 里，失败就中止打包）。
直接用 `CODE_SIGNING_ALLOWED=NO` 构建出来的 bundle 签名是**坏的**（`codesign -vv` 报
`code has no resources but signature indicates they must be present`），macOS 把那种情况当"已损坏"，
而"清 quarantine / 仍要打开"都修不了它——所以这一条不能省。

系统要求：macOS 26.0 或更新版本、Apple Silicon Mac。第一次用 QQ 音乐时，点侧边栏的「QQ 音乐」扫码登录；
注意**在线下载需要「托管」资料库**——原位引用模式的资料库只能浏览，因为导入管线不接受应用自己产生的文件。

系统要求：macOS 26.0 或更新版本、Apple Silicon Mac。第一次用 QQ 音乐时，点侧边栏的「QQ 音乐」扫码登录；
注意**在线下载需要「托管」资料库**——原位引用模式的资料库只能浏览，因为导入管线不接受应用自己产生的文件。

## 六、本仓库的目录与工作流

上游的文件保持原样（`patches/` 明确记录我们改过哪几处），本功能自己的东西集中在一处：

```
kmgccc_player/            应用源码：上游 + 本功能的接入点改动（就地）
kmgccc_playerTests/       测试（含本功能自己的测试）
qqmusic/                  ← 本功能除源码之外的一切
  integration/            补丁包：modules/（新文件）+ patches/（上游 diff）+ 脚本 + 基线 BASE
  README.md               功能说明、数据来源、缓存策略、参考项目
upstream/                 未改动的上游源码，冻结参照（不进仓库）
testarea/                 每次从 upstream/ 重建的测试区（不进仓库）
docs/qqmusic/             设计、方案与实现记录（不进仓库）
```

开发这台机器上的两条命令：

```sh
./qqmusic/integration/sync.sh           # 把开发树的改动重新生成进 modules/ + patches/
./qqmusic/integration/test-cycle.sh --sync
# 重建 testarea/ → 重放补丁包并校验 → 构建 → 跑测试 → 启动应用
```

**「补丁能应用」不等于「补丁能构建、能跑」**，所以提交前以 `test-cycle.sh` 为准：它从干净基线重放，
打印 `passed: N failed: M`（执行数为 0 也算失败，因为 `xcodebuild` 在测试文件没登记进工程时照样报
`TEST SUCCEEDED`），最后启动应用。

应用内「QQ 音乐设置 → Helper 组件」里有**本功能版本**与**本功能构建**两行：功能以补丁包交付，一台机器上可能
同时存在多个构建，没有这两行「旧构建」与「没修好」从外面看一模一样。

## 七、上游原有能力（本补丁未改动）

以下都是上游 kmgccc_player 的能力，来自它的 README，本补丁只在必要的接入点上做了最小改动：

- **现代本地曲库**：多资料库独立管理与原位目录引用，不移动或不复制音频即可映射既有文件夹，
  专辑、艺人与文件夹层级平行浏览。
- **原生 Swift 歌词**：纯原生 Core Text 排版与 Core Animation 动效，逐字呼吸与弹簧滚动，支持 ProMotion 120Hz。
- **外部播放协同**：读取 Apple Music 及系统全局媒体的正在播放状态，自动关联歌词与封面。
- **多元视听皮肤**：多款 Now Playing 与全屏皮肤，随乐曲脉动的实时频谱与波形可视化。
- **动态色彩系统**：从专辑封面提炼 OKLCH 语义色，自适应生成视窗质感与高可读性歌词配色。
- **纯粹本地优先**：元数据解析、全文搜索索引与偏好统计皆在本地运行，无需注册账号。

## 八、参考的项目

- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现，helper 的目录、
  排行、电台、歌手、歌词与取流都走它
- 上游 README 致谢的 AMLL、LDDC、SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础

## 九、从源码构建与本机开发环境

```sh
git clone --recurse-submodules <this repo>
cd kmgccc_player_for_QQMusic
./scripts/bootstrap.sh        # 构建外部组件（AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD）
./scripts/verify.sh           # Debug 构建 + LRC 回归 + 单元测试 + App bundle 检查
./scripts/build_app.sh Release   # Release 构建及 bundle 完整性校验
open kmgccc_player.xcodeproj
```

开发环境需要 Xcode 26.2 或更新版本（Swift 6）、Node.js 22（含 Corepack）、ARM64 Python 3.12、
CMake 3.15 或更新版本、Git、curl 与 Xcode Command Line Tools。构建输入可选地在
`Config/LocalOverrides.xcconfig` 配置（可从同目录 `.example` 复制）。

- **AMLL submodule 缺失或 commit 不一致**：`git submodule sync --recursive` 再 `git submodule update --init --recursive`。
- **找不到 node 或 corepack**：装 Node.js 22，确认两者都在 PATH 中。npm 官方源不通时可用 `registry.npmmirror.com`。
- **Python 版本或架构不符**：装 ARM64 Python 3.12，或用 `KMGCCC_ARM_PYTHON=/path/to/python3.12 ./scripts/bootstrap.sh`。
- **Xcode 报外部组件产物缺失**：回仓库根目录跑 `./scripts/bootstrap.sh`。
- **产物被判为 stale**：`./scripts/bootstrap.sh --force --component <name>` 重建，失败日志在 `.build/logs/`。

## 十、技术文档（上游）

上游在 [`docs/README.md`](docs/README.md) 中系统梳理了架构理念、核心算法与工程实现：应用架构、
原生歌词系统、资料库体系、色彩系统、曲库搜索与偏好随机播放、实现约束与坑。本补丁自己的设计与实现记录
在 `docs/qqmusic/`（不进仓库）。

## 十一、许可证与致谢

代码基于 GNU Affero General Public License v3.0 (AGPL-3.0) 发布，与上游一致；第三方组件遵循各自的开源许可证，
详见应用内 About 页面及 `Licenses` 目录。

上游 README 的「美术素材版权声明」与「致谢」对上游内容继续有效：美术素材著作权归上游作者保留，
AMLL、LDDC、apple-audio-visualization、ncmdump、sacad、QQMusicApi、MediaRemote Adapter、WhatsNewKit、
PLCrashReporter 等项目的贡献属于它们各自的作者。本补丁只新增 QQ 音乐在线音源相关的代码与文案。

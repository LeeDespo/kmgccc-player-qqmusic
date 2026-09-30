# kmgccc_player 2.3.1 + QQMusic 1.0.0

给 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 加装 QQ 音乐在线音源的补丁包。
本仓库 = **上游 2.3.1 + 一份可审计的变更集**：变更集以补丁包形式交付（`modules/` 新文件 + `patches/` 对上游文件的 diff），
把它应用到一个未改动的上游源码上就得到完整功能。

- 基线：`b0de7aa6`（kmgccc_player 2.3.1）
- 补丁版本：`1.0.0`（应用内 QQ 音乐设置 → Helper 组件 → 「本功能版本」显示为 `2.3.1 + QQMusic 1.0.0`）
- 验证：在一份干净的 `b0de7aa6` 检出上重放 → 构建成功 → 434 项单元测试通过 → 应用能启动

## 附件

- **`kmgccc_player-2.3.1+QQMusic.1.0.0-arm64.dmg`** — 已经打好补丁的 macOS 应用（Apple Silicon，macOS 26+）。
  内含 `/Applications` 快捷方式与 `安装说明.txt`。应用是 **ad-hoc 签名**（无证书、无 TeamID、无公证），
  首次打开需要放行一次——具体会发生什么见下面「安装」一节。
- **`kmgccc_player-2.3.1+QQMusic.1.0.0-patch.tar.gz`** — 补丁包本体。用它可以：
  自己从上游源码构建；或者把功能搬到别的上游版本上（上游更新后重放，冲突需人工移植）。

## 给原应用加了什么

保留原应用的全部本地能力（本地曲库、原生歌词、皮肤、外部播放协同、动态色彩……），在其之上加一个在线音源：

- **浏览**：落地页顶部是精选大卡片（取「猜你喜欢」，可换一首；卡面显示歌曲简介，文字颜色按封面明暗自动取深/浅），
  下面是收藏歌单、收藏专辑、关注的歌手、新歌电台、排行榜、电台、猜你喜欢；可下钻到歌单 / 专辑 / 排行榜 /
  电台 / 歌手详情页。返回、前进、搜索、刷新、批量下载都在窗口工具栏里，与原应用同一层玻璃、同一套交互。
- **播放**：点击列表任意一行即从这一行开始播——顺序播放往下走到表尾，随机播放覆盖**整张**在线列表
  （而不是只覆盖已下载的那几首）。在线歌曲先下载、经**原有导入管线**入库，再交给**原有播放引擎**播放，
  因此无缝播放、原生歌词、频谱、Now Playing、播放历史全部自动继承，播放引擎一行没改。
- **账号与收藏**：扫码或网页登录（两条路径等价）；「我喜欢」、收藏歌单、收藏专辑；行内收藏/取消收藏写回上游。
- **缓存与回收**：歌单、推荐、排行榜与浏览态封面缓存在资料库的 `QQMusic/` 目录（与应用自身的 `Cache/` 平级且分开）；
  歌曲缓存只约束「为了播放而自动下载」的那部分，可设上限并回收——你自己点过下载的属于曲库，永不回收。
- **一个数据组件，与应用解耦**：在线内容的读取、登录、限流与熔断全部在 HelperNext 组件（独立进程）里，
  应用只跟它说 JSON；上游接口变化时换那个二进制即可，无需重新构建应用。

另外**关闭了自动更新、崩溃上报与匿名统计**（默认关且不可再开）：更新源属于上游项目，装上去会覆盖本版本的功能改动；
崩溃与匿名统计会发到上游作者的服务器，而对方无法据此做任何事。

## 安装（DMG）

1. 打开 DMG，把 `kmgccc_player.app` 拖进「应用程序」。
2. **首次打开会被 Gatekeeper 拦一次**，这是预期的。提示大意是"Apple 无法验证它是否包含恶意软件"或
   "来自身份不明的开发者"——**不是**"已损坏"。任选一种放行（第一条在任何 macOS 版本上都能用）：

   ```sh
   xattr -dr com.apple.quarantine /Applications/kmgccc_player.app
   ```

   - 或者先双击一次让它被拦下，再进 **系统设置 → 隐私与安全性 → 安全性 → 仍要打开**。
     （macOS 15 起 Apple 取消了"右键 → 打开"这条快捷方式，只在更旧的系统上还有效。）

   为什么可以确定不是"已损坏"：打包脚本在写完构建戳记后做 ad-hoc 签名，并**断言** `codesign --verify
   --deep --strict` 通过，否则中止发布。用 `CODE_SIGNING_ALLOWED=NO` 直接构建出来的 bundle 签名是坏的
   （`code has no resources but signature indicates they must be present`），macOS 把它当"已损坏"，
   而且"清 quarantine / 仍要打开"都修不了——所以这一步不能省。
3. 启动后点侧边栏最下面的「QQ 音乐」，用手机 QQ 扫码登录。
4. 注意：**在线下载需要「托管」资料库**——原位引用模式的资料库只能浏览，因为导入管线不接受应用自己产生的文件。

系统要求：macOS 26.0 或更新版本、Apple Silicon Mac。

## 数据组件（HelperNext）

在线音源的接口调用只有一层：**HelperNext 组件**——一个静态链接的 Rust 二进制（约 2.4 MB，
无解释器、无第三方 SDK）。应用（Swift）通过 stdin/stdout 一行一个 JSON 跟它说话。

```
kmgccc_player（Swift）
   │  stdin/stdout：{"id","method","params"} → {"id","ok",…}
   ▼
qqmusic-helper-next（Tools/helper-next/qqmusic-helper-next）
   │  HTTPS（签名、cookie、平台参数、限流、熔断都在组件里）
   ▼
腾讯的接口
```

**它顶替了两样东西**：上一版的 Python helper（含整个解释器与 qqmusic-api-python，约 56 MB），
以及**应用内的 HTTP 客户端** `QQMusicWebAPI`。两者都删了——同一个能力有两份实现时，
"一条坏了另一条兜底"掩盖的是它们的行为差异，而落库与缓存判断还得同时考虑两者。
组件的请求参数与解析路径逐条对照 qqmusic-api-python 写过（包括它的坑：扫码轮询的 `ptqrtoken`
用 seed 0 的 `hash33`，而 `g_tk` 用 5381——用错就是 HTTP 403）。

**可独立替换**：应用优先加载
`~/Library/Application Support/kmgccc.player/QQMusicHelperNext/qqmusic-helper-next`，
bundle 内副本只作兜底，所以上游接口变化时换那个文件即可，不必重新构建应用。
组件**自己管凭据**（同目录下 `Credential/qqmusic-credential.json`）。
应用内「QQ 音乐设置 → Helper 组件」会显示组件版本与协议版本。

`Tools/QQMusicHelper`（本项目改过的 Python helper，继承上游目录）仍留在仓库里、`bootstrap.sh` 也仍会构建它，
但**应用的代码已不再引用**——它作为回退路径存在。

## 从源码构建（用补丁包）

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
git checkout b0de7aa6

# 把补丁包里的 integration/ 放到 qqmusic/integration/
cp -R /path/to/kmgccc_player-2.3.1+QQMusic.1.0.0-patch/integration ./qqmusic/integration
./qqmusic/integration/apply.sh --repo . --verify

./scripts/bootstrap.sh                        # 构建外部组件（AMLL 需要 Node 22，helper 需要 Python 3.12）
DEVELOPMENT_TEAM=<你的 team id> ./scripts/build_and_run.sh
```

工程里钉的是上游作者的签名 team，所以要覆盖成你自己的——补丁包对 `scripts/build_and_run.sh` 的唯一改动就是
把这个环境变量转发给 `xcodebuild`（`Config/LocalOverrides.xcconfig` 改不动它：那个 key 在工程的
target build settings 里，优先级更高）。没有证书就用 `CODE_SIGNING_ALLOWED=NO ./scripts/build_and_run.sh`。

补丁应用失败是**预期行为**：`patches/` 里的 diff 只有在上下文仍然匹配时才干净应用；输出会指名是哪个文件、
哪份补丁，一条失败不挡住其余的。细节见补丁包内 `integration/README.md`。

数据组件**不需要构建**：DMG 里的应用已经带了它（`Tools/helper-next/qqmusic-helper-next`，
预编译的 Rust 二进制）。应用默认就用 bundle 里那份；只有当你想**单独替换组件**（上游接口变化时最省事的修法）
才需要复制到外部目录——这时第二行不能省（复制出来的文件带 `com.apple.quarantine`，带隔离属性的可执行文件
会被系统直接杀掉，退出码 137 且没有任何输出，应用只会写一行日志）：

```sh
cp /Applications/kmgccc_player.app/Contents/Resources/Tools/qqmusic-helper-next/qqmusic-helper-next \
   ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext
```

## 已知限制

- **ad-hoc 签名**（`codesign -s -`），没有开发者签名、没有公证——签名只保证 bundle 与内容一致，
  不代表受信任，所以首次打开必须放行一次。
- 只对基线 `b0de7aa6`（2.3.1）验证过。上游更新后重放补丁大概率有冲突，需要人工移植。
- QQ 音乐接口是逆向来的，随时可能变化。数据组件可独立替换，接口变化时优先换它而不是重新构建应用。
- 应用侧**没有做组件版本闸门**：只把版本号显示出来。换上一个响应形状不兼容的组件，表现会是某个页面报错
  或某个字段变空，而不是启动时明确拒绝——组件的能力清单与兼容约定写在 `Tools/helper-next/README.md` 里。
- 这个构建：见 DMG 内 `安装说明.txt`，或应用内「QQ 音乐设置 → Helper 组件 → 本功能构建」。

## 参考的项目

- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）；它的 README 致谢的 AMLL、LDDC、
  SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现；数据组件的请求
  参数与解析路径逐条对照它写过（它本身仍留在仓库的 Python helper 里）
- [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) —— 数据组件的源码

## 许可证

与上游一致：AGPL-3.0；第三方组件遵循各自许可证。上游的美术素材著作权归上游作者保留。

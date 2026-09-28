# kmgccc_player 2.3.1 + QQMusic 1.0.0

给 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 加装 QQ 音乐在线音源的补丁包。
本仓库 = **上游 2.3.1 + 一份可审计的变更集**：变更集以补丁包形式交付（`modules/` 新文件 + `patches/` 对上游文件的 diff），
把它应用到一个未改动的上游源码上就得到完整功能。

- 基线：`b0de7aa6`（kmgccc_player 2.3.1）
- 补丁版本：`1.0.0`（应用内 QQ 音乐设置 → Helper 组件 → 「本功能版本」显示为 `2.3.1 + QQMusic 1.0.0`）
- 验证：在一份干净的 `b0de7aa6` 检出上重放 → 构建成功 → 431 项单元测试通过 → 应用能启动

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
- **两条通道，各取所长**：常读内容直连上游网页接口（快约三倍），其余走 helper 组件；每类内容可指定先用哪条，
  **没选中的那条在它失败时自动兜底**，设置页逐行写明并显示最近一次实际由谁回答。
- **helper 与应用解耦**：helper 是独立进程，可从外部目录替换；上游接口变化时换那个二进制即可，无需重新构建应用。

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

## Helper 组件是什么（它和 qqmusic-api-python 的关系）

在线音源的接口调用分两层：[qqmusic-api-python](https://github.com/L-1124/QQMusicApi) 是**第三方 Python 库**；
`Tools/QQMusicHelper` 是**本项目自己的 Python 程序**，它把那个库当作底层引擎，再往上包一层应用能用的东西。
应用（Swift）从不直接调用这个库——两者之间是一条 stdin/stdout 的 JSON 协议。

```
kmgccc_player（Swift）
   │  stdin/stdout 一行一个 JSON
   ▼
qqmusic-helper（本项目：Tools/QQMusicHelper/main.py，PyInstaller 打成独立二进制）
   │  直接调用
   ▼
qqmusic_api（第三方库：Client / Credential / 各模块 / 签名 / 数据模型）
```

**库负责**：请求签名、cookie 拼装、平台参数、响应到模型的解析，以及各模块方法
（`client.song/album/singer/lyric/search/top/songlist/recommend/user/login.*`）。逐字歌词来自
`client.lyric.get_lyric`，取流地址与 vkey 来自 `client.song.get_song_urls`。

**helper 自己负责**：① 协议层（一行一个 JSON、方法白名单、`get_helper_info` 自报版本与能力）；
② 库里没有包成公开方法的接口——用 `client.song._build_cgi` / `_build_http` 直接打上游（新歌、我喜欢、
收藏专辑、专辑曲目、我的歌单、歌单写操作、电台等，共 10 处）；③ 归一化（把搜索/歌单/电台/榜单不同嵌套
形状统一成一套字段，封面强制 https）；④ 业务动作（取流音质阶梯、凭据落盘、60 秒空闲自杀、限流退避）。
它还兼着上游原本的用途：本地歌曲的元数据补全。

**可独立替换**：helper 优先从 `~/Library/Application Support/kmgccc.player/QQMusicHelper/` 加载，
bundle 内副本只作兜底，所以上游接口变化时换那个二进制即可，不必重新构建应用。`requirements.txt` 钉
`qqmusic-api-python==0.7.3`，PyInstaller 把 Python 运行时和这个库一起打包，**使用者的机器不需要装 Python**。
应用内「QQ 音乐设置 → Helper 组件」会显示 helper 版本、协议版本与库版本。

应用里另有**一条完全独立的通道** `QQMusicWebAPI`（自己直连 `u.y.qq.com/cgi-bin/musicu.fcg`，不经 helper
也不经这个库）；设置里的「在线内容 → 获取通道」决定谁先试、另一条兜底。

## 从源码构建（用补丁包）

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
git checkout b0de7aa6

# 把补丁包里的 integration/ 放到 qqmusic/integration/
cp -R /path/to/kmgccc_player-2.3.1+QQMusic.1.0.0-patch/integration ./qqmusic/integration
./qqmusic/integration/apply.sh --repo . --verify

./scripts/bootstrap.sh                        # 构建外部组件（helper 需要 Python 3.12 / Node 22 / CMake）
DEVELOPMENT_TEAM=<你的 team id> ./scripts/build_and_run.sh
```

工程里钉的是上游作者的签名 team，所以要覆盖成你自己的——补丁包对 `scripts/build_and_run.sh` 的唯一改动就是
把这个环境变量转发给 `xcodebuild`（`Config/LocalOverrides.xcconfig` 改不动它：那个 key 在工程的
target build settings 里，优先级更高）。没有证书就用 `CODE_SIGNING_ALLOWED=NO ./scripts/build_and_run.sh`。

补丁应用失败是**预期行为**：`patches/` 里的 diff 只有在上下文仍然匹配时才干净应用；输出会指名是哪个文件、
哪份补丁，一条失败不挡住其余的。细节见补丁包内 `integration/README.md`。

不想本地编译 helper？这份 DMG 里的应用已经带了构建好的 helper，复制过去即可（第二行不能省，下载来的文件带
`com.apple.quarantine`，带隔离属性的 helper 会被系统直接杀掉，而应用只会写一行日志）：

```sh
cp -R /Applications/kmgccc_player.app/Contents/Resources/Tools/qqmusic-helper/* \
      ~/Library/Application\ Support/kmgccc.player/QQMusicHelper/
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelper
```

## 已知限制

- **ad-hoc 签名**（`codesign -s -`），没有开发者签名、没有公证——签名只保证 bundle 与内容一致，
  不代表受信任，所以首次打开必须放行一次。
- 只对基线 `b0de7aa6`（2.3.1）验证过。上游更新后重放补丁大概率有冲突，需要人工移植。
- QQ 音乐接口是逆向来的，随时可能变化。helper 可独立替换，接口变化时优先换它而不是重新构建应用。
- 应用侧**没有做 helper 版本闸门**：`main.py` 注释里说"宿主会拒绝不兼容的协议版本"，实际只把版本号显示出来。
  换上一个响应形状不兼容的 helper，表现会是某个页面报错（再退回另一条通道），而不是启动时明确拒绝。
- 这个构建：见 DMG 内 `安装说明.txt`，或应用内「QQ 音乐设置 → Helper 组件 → 本功能构建」。

## 参考的项目

- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）；它的 README 致谢的 AMLL、LDDC、
  SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现，helper 的目录、
  排行、电台、歌手、歌词与取流都走它

## 许可证

与上游一致：AGPL-3.0；第三方组件遵循各自许可证。上游的美术素材著作权归上游作者保留。

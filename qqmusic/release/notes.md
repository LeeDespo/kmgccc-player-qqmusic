# kmgccc_player 2.3.1 + QQMusic 1.0.0

给 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 加装 QQ 音乐在线音源的补丁包。
本仓库 = **上游 2.3.1 + 一份可审计的变更集**：变更集以补丁包形式交付（`modules/` 新文件 + `patches/` 对上游文件的 diff），
把它应用到一个未改动的上游源码上就得到完整功能。

- 基线：`b0de7aa6`（kmgccc_player 2.3.1）
- 补丁版本：`1.0.0`（应用内 QQ 音乐设置 → Helper 组件 → 「本功能版本」显示为 `2.3.1 + QQMusic 1.0.0`）
- 验证：在一份干净的 `b0de7aa6` 检出上重放 → 构建成功 → 431 项单元测试通过 → 应用能启动

## 附件

- **`kmgccc_player-2.3.1+QQMusic.1.0.0-arm64.dmg`** — 已经打好补丁的 macOS 应用（Apple Silicon，macOS 26+）。
  拖进「应用程序」即可；没有开发者签名与公证，首次打开需要放行（见下）。
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
2. 首次打开会被 Gatekeeper 拦住（应用只有 ad-hoc 签名、没有公证，这是**正常的未受信任**提示，
   不是"已损坏"），任选一种放行：
   - 右键点它 → 打开 → 再点「打开」；
   - 或执行一次 `xattr -dr com.apple.quarantine /Applications/kmgccc_player.app`。
3. 启动后点侧边栏最下面的「QQ 音乐」，用手机 QQ 扫码登录。
4. 注意：**在线下载需要「托管」资料库**——原位引用模式的资料库只能浏览，因为导入管线不接受应用自己产生的文件。

系统要求：macOS 26.0 或更新版本、Apple Silicon Mac。

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
- 这个构建：见 DMG 内 `安装说明.txt`，或应用内「QQ 音乐设置 → Helper 组件 → 本功能构建」。

## 参考的项目

- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）；它的 README 致谢的 AMLL、LDDC、
  SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现，helper 的目录、
  排行、电台、歌手、歌词与取流都走它

## 许可证

与上游一致：AGPL-3.0；第三方组件遵循各自许可证。上游的美术素材著作权归上游作者保留。

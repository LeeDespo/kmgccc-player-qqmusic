# kmgccc_player 2.3.1 + QQMusic 1.1.0

给 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 加装 QQ 音乐在线音源的补丁包。
本仓库 = **上游 2.3.1 + 一份可审计的变更集**：变更集以补丁包形式交付（`modules/` 新文件 +
`patches/` 对上游文件的 diff + `removals.txt` 要删掉的上游文件），
把它应用到一个未改动的上游源码上就得到完整功能。

- 基线：`b0de7aa6`（kmgccc_player 2.3.1）
- 补丁版本：`1.1.0`（应用内 QQ 音乐设置 → Helper 组件 → 「本功能版本」显示为 `2.3.1 + QQMusic 1.1.0`）
- 验证：在一份干净的 `b0de7aa6` 检出上重放 → 构建成功 → 434 项单元测试通过 → 应用能启动

## 附件

- **`kmgccc_player-2.3.1+QQMusic.1.1.0-arm64.dmg`** — 已经打好补丁的 macOS 应用（Apple Silicon，macOS 26+）。
  内含 `/Applications` 快捷方式与 `安装说明.txt`。应用是 **ad-hoc 签名**（无证书、无 TeamID、无公证），
  首次打开需要放行一次——见「安装」一节。
- **`kmgccc_player-2.3.1+QQMusic.1.1.0-patch.tar.gz`** — 补丁包本体。用它可以自己从上游源码构建，
  或者把功能搬到别的上游版本上（上游更新后重放，冲突需人工移植）。

## 这一版做了什么

### 换了数据组件：一个 HelperNext，取代两套实现

上一版里在线数据有两个来源：**Python helper**（内含整个解释器与 `qqmusic-api-python`，约 56 MB）
和**应用内直连上游 HTTP 的 `QQMusicWebAPI`**。同一个能力有两份实现，差异靠"谁先试、另一条兜底"
掩盖，而落库与缓存判断还得同时考虑两者。

现在只剩**一个数据组件**：`qqmusic-helper-next`——静态链接的 Rust 二进制，约 2.4 MB，没有解释器。
读取、登录、限流、熔断全在它内部，应用通过 stdin/stdout 的 JSON 协议跟它说话。
收益不只是体积：**上游接口变化时换这一个文件即可**，不必重新构建应用；组件还自己管凭据。

替换前逐方法做了**实机对拍**（同一凭据、同一请求，逐键比较新旧响应），因此修掉了几处
"页面能打开但内容是空的"的静默故障：详情接口缺 `detail` 包装、排行榜与电台分组缺非可选的 `name`、
取流响应缺 `extension`/`restriction`、风控码 `2001` 被当成"没有结果"（搜索被限流时显示成空页面）。
取流也从 web profile 改到 **android profile**——票据绑在设备会话上，同一首歌此前只能取到 128
甚至被直接拒绝，现在能拿到 flac。

**Python helper 整个目录已删除**，`bootstrap.sh` 也不再构建它。

### 引入下载引擎：Aria2 Next

歌曲的字节现在由 [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) 搬运——aria2 的活跃分支，
随组件一同发布，由组件按需拉起（私有回环端口 + 每次启动重新生成的 RPC 密钥），应用通过标准
JSON-RPC 说"要这个文件"。多连接分块、断点续传、并发数与限速都由引擎负责。

**下载引擎在设置里可调**：状态（含版本与实际端口）、重启、分块数量、单服务器连接数、
同时下载任务、最小分块、总下载限速、RPC 端口。改数字立即生效（不重启、不打断在下的任务）；
端口除外——监听套接字搬不了，它在下次启动时生效，设置项里写明了。

**下载清单是"你要什么"的清单**：点开工具栏的下载进度框，看到的是**整个选择**——
歌名-歌手与文件名、每首的实时进度，分段控制器区分 **下载中 / 失败 / 完成**。
可以单个或全部**暂停 / 继续 / 取消**（取消会一并删掉临时文件）。
进度框只在**有下载中或失败**时才出现，干净跑完的批次会把它一起收走。

### 修掉的问题

- **预下载只下一首 / 随机播放没有下一首**：取流走错了 profile（见上）。
- **歌手页从曲目行的「查看艺人」进来没有头像和信息**：页面此前渲染上一页顺手带来的引用，
  现在自己把自己的资料读全。
- **搜索页歌单没有封面**（那条接口的封面键是 `logo`）、**切换分段会跳回顶部**。
- **批量下载一直显示 0/1**、**点下载之后选择模式不退出**、**并发设置看起来没用**
  （应用此前只按并发数逐批交给引擎，引擎手里永远只有一两个任务）。
- **重启下载引擎会让任务卡死**（轮询把"引擎丢了任务"当成"还没好"）。
- **关注的歌手读不到**：组件此前要求凭据里有 `encrypt_uin`，而现在的登录流程不产出它；
  实测该接口接受数字账号 id。
- **发布会在最后一步中止**：打包脚本仍断言存在 Python helper。

### 设置页

说明文字不再以"小字"堆在每一项下面，改到标签旁的信息按钮里（悬停也有提示）；
熔断与限流参数真正送到组件（此前只改应用侧镜像，用户看到的是"改了没用"）；
限流新增一道总闸：可设"多少秒内最多多少次请求"，超出**排队**而不是丢弃，默认 10 秒 100 次。

### 移除

- Python helper（`Tools/QQMusicHelper/`）与它的构建组件；
- 应用内的第二套取数实现（`QQMusicWebAPI`）与"两条通道"机制，连同设置页「在线内容 → 通道」分区；
- 仓库里那份过期的组件源码快照（源码在它自己的仓库里）。

## 安装（DMG）

1. 打开 DMG，把 `kmgccc_player.app` 拖进「应用程序」。
2. **首次打开会被 Gatekeeper 拦一次**，这是预期的。提示大意是"Apple 无法验证它是否包含恶意软件"或
   "来自身份不明的开发者"——**不是**"已损坏"。任选一种放行（第一条在任何 macOS 版本上都能用）：

   ```sh
   xattr -dr com.apple.quarantine /Applications/kmgccc_player.app
   ```

   - 或者先双击一次让它被拦下，再进 **系统设置 → 隐私与安全性 → 安全性 → 仍要打开**。
     （macOS 15 起 Apple 取消了"右键 → 打开"这条快捷方式，只在更旧的系统上还有效。）

   为什么可以确定不是"已损坏"：打包脚本在写完构建戳记后做 ad-hoc 签名，并**断言**
   `codesign --verify --deep --strict` 通过，否则中止发布。
3. 启动后点侧边栏最下面的「QQ 音乐」，用手机 QQ 扫码登录。
4. 注意：**在线下载需要「托管」资料库**——原位引用模式的资料库只能浏览，因为导入管线不接受
   应用自己产生的文件。

系统要求：macOS 26.0 或更新版本、Apple Silicon Mac。

## 数据组件与下载引擎

在线音源的接口调用只有一层：`qqmusic-helper-next`（静态链接的 Rust 二进制）。
应用通过 stdin/stdout 一行一个 JSON 跟它说话；下载的字节由它拉起的 `aria2-next` 搬运。

```
kmgccc_player（Swift）
   │  stdin/stdout：{"id","method","params"} → {"id","ok",…}
   ▼
qqmusic-helper-next ──拉起──► aria2-next（JSON-RPC，回环端口）
   │  HTTPS（签名、cookie、平台参数、限流、熔断都在组件里）
   ▼
腾讯的接口
```

**可独立替换**：应用优先加载
`~/Library/Application Support/kmgccc.player/QQMusicHelperNext/` 下的文件，bundle 内副本只作兜底，
所以上游接口变化时换那几个文件即可，不必重新构建应用。组件**自己管凭据**
（同目录下 `Credential/qqmusic-credential.json`）。应用内「QQ 音乐设置 → Helper 组件」
显示组件版本与协议版本，「下载引擎」区显示引擎状态与版本。

`Tools/QQMusicHelper`（上一版的 Python helper）已从仓库移除，应用的代码不再引用它。

## 从源码构建（用补丁包）

```sh
git clone https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
git checkout b0de7aa6

cp -R /path/to/kmgccc_player-2.3.1+QQMusic.1.1.0-patch/integration ./qqmusic/integration
./qqmusic/integration/apply.sh --repo . --verify

./scripts/bootstrap.sh                        # 构建上游自己的外部组件（AMLL 需要 Node 22）
DEVELOPMENT_TEAM=<你的 team id> ./scripts/build_and_run.sh
```

数据组件不需要自己构建：补丁包自带预编译的 `qqmusic-helper-next` 与 `aria2-next`，
`Tools/helper-next/README.md` 写明它们的来源仓库与更新方式。
工程里钉的是上游作者的签名 team，所以要覆盖成你自己的；没有证书就用
`CODE_SIGNING_ALLOWED=NO ./scripts/build_and_run.sh`。

补丁应用失败是**预期行为**：`patches/` 里的 diff 只有在上下文仍然匹配时才干净应用；
输出会指名是哪个文件、哪份补丁，一条失败不挡住其余的。

## 已知限制

- **ad-hoc 签名**（`codesign -s -`），没有开发者签名、没有公证——签名只保证 bundle 与内容一致，
  不代表受信任，所以首次打开必须放行一次。
- 只对基线 `b0de7aa6`（2.3.1）验证过。上游更新后重放补丁大概率有冲突，需要人工移植。
- QQ 音乐接口是逆向来的，随时可能变化。数据组件可独立替换，接口变化时优先换它。
- 应用侧**没有做组件版本闸门**：只把版本号显示出来。换上一个响应形状不兼容的组件，
  表现会是某个页面报错或某个字段变空，而不是启动时明确拒绝——组件的能力清单与兼容约定写在
  `Tools/helper-next/README.md` 里。
- 收藏/取消收藏的写路径、我的歌单、收藏专辑、关注的歌手都已在真实账号上验证；
  扫码登录换取凭据的三步（`check_sig` → `authorize` → `QQLogin`）也在真实扫码下走通，
  但上游一调整就可能失效——症状是扫完没有反应，日志里会写明卡在哪一步。
- 这个构建：见 DMG 内 `安装说明.txt`，或应用内「QQ 音乐设置 → Helper 组件 → 本功能构建」。

## 致谢

在线音源这一层站在这些项目上面：

- [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) —— **数据组件本身**：
  在线内容的全部读取、登录、限流与熔断都在这里，本仓库只放它的构建产物。
- [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) —— **下载引擎**（aria2 的活跃分支，
  由 Motrix Next 的作者维护）：多连接分块、断点续传、并发与限速。歌曲的字节全部由它搬运。
- [BoltFFI](https://github.com/boltffi/boltffi) —— 组件的类型与协议绑定生成器。
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现。
  组件已不再依赖它，但组件的请求参数与解析路径是逐条对照它写出来的，扫码登录、取流与歌词
  那几处的坑也是从它那里学到的。
- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）。
  它的 README 致谢的 AMLL、LDDC、SACAD、MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础。

## 许可证

与上游一致：AGPL-3.0；第三方组件遵循各自许可证。上游的美术素材著作权归上游作者保留。

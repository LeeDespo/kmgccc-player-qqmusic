# HelperNext（在线音源的数据组件，构建产物）

这个目录放的是 **HelperNext 组件的构建产物**：`qqmusic-helper-next`（约 2.4 MB，静态链接，无解释器）。
应用优先从外部目录加载它：

```
~/Library/Application Support/kmgccc.player/QQMusicHelperNext/qqmusic-helper-next
```

bundle 内这份只是兜底。**源码不在本仓库**——在
[QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)（Rust）。
要更新它：

```sh
cd QQMusicApi_HelperNext && cargo build --release && cargo test
cp target/release/qqmusic-helper-next <本目录>/
cp target/release/qqmusic-helper-next \
  ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/
```

来源版本：可在运行中的应用「QQ 音乐设置 → Helper 组件」里看到组件版本与协议版本；
协议与旧 helper 逐字兼容（一行一个 JSON，响应回带 `id`），所以应用的进程客户端无需改动。

## 它是唯一的数据来源

应用侧**没有自己的 HTTP 客户端**（原来的 `QQMusicWebAPI` 与「两条通道」机制已删除）：
在线内容的读取、登录、限流与熔断全部在这里。

组件**自己管凭据**：`<目录>/Credential/qqmusic-credential.json`，目录由应用通过
`QQMUSIC_HELPER_NEXT_DIR` 告诉它。二维码登录（`start_login` / `poll_login`）产出的凭据也写在这里。


## 设置项怎么送给组件（协议里的两个配置方法）

组件的限流与熔断由应用推送，**每次组件重启后都会重推**（组件是独立进程，退出即忘）。
两者都是"设置推送"而不是上游读取：组件用自己的状态回答，登录与否都能用。

```json
// 请求频率总闸。windowSeconds/maxRequests 会被 clamp 到 [1,3600] / [1,100000]。
{"id":"1","method":"set_rate_limit","params":{
  "enabled":true,"windowSeconds":10,"maxRequests":100}}
{"id":"1","ok":true,"rateLimit":{"enabled":true,"windowSeconds":10,"maxRequests":100}}

// 熔断器。failureThreshold/failureWindowSeconds/openSeconds 会被 clamp 到 [1,100]/[1,3600]/[1,3600]。
// enabled=false 只是"不因失败开路"，失败本身照常报给调用方。
{"id":"2","method":"set_breaker","params":{
  "enabled":true,"failureThreshold":3,"failureWindowSeconds":120,"openSeconds":300}}
{"id":"2","ok":true,"breaker":{"enabled":true,"failureThreshold":3,
  "failureWindowSeconds":120,"openSeconds":300}}
```

**语义要点**（踩过的坑都在这）：

- **超限是等待，不是丢弃**。限流与熔断都只 delay：每一次调用都是用户等着的读取，
  失败比延迟更糟。上游自己的限流会返回"成功但空"的结果集，那正是要避免的。
- **改配置会清空状态**：`set_breaker` 会把已经开路的熔断器关回闭合、并清掉失败计数——
  否则"改了数字却没变化"看起来像设置没送达。
- **`get_status` 会回显两者**（`status.rateLimit.config` 与 `status.breakerConfig`），
  所以应用能显示"组件当前生效"的值，而不是显示用户输入的数字。


## 下载引擎：Aria2 Next（随组件一同发布）

歌曲的字节不在这里搬。组件启动 **Aria2 Next**（[AnInsomniacy/aria2-next](https://github.com/AnInsomniacy/aria2-next)，
aria2 的活跃分支，2.7.5）——它就在组件旁边：`<组件目录>/aria2-next`，随同一个发行包发布。

```
应用 → 组件（aria2_add）→ Aria2 Next（JSON-RPC，回环端口 16800）→ CDN
```

**为什么是另一个进程**：组件管的是"跟腾讯的接口说话"（签名、cookie、限流、解析），
搬字节是另一件事，aria2 有成熟实现（多连接、断点续传、限速）。应用那边因此只剩一句"要这个文件"。

**协议方法**：

```json
// 状态。ensure=true 会顺手把引擎拉起来；设置页用 false，只报告不启动。
{"id":"1","method":"aria2_status","params":{"ensure":false}}
{"id":"1","ok":true,"aria2":{"installed":true,"running":true,"version":"2.7.5","port":16800,
  "active":1,"downloadSpeed":4765284,"options":{"split":5,"maxConnectionPerServer":5,
  "maxConcurrentDownloads":1,"minSplitSizeMiB":1,"maxOverallDownloadLimitKiB":0}}}

// 重启（设置页的「重启引擎」）
{"id":"2","method":"aria2_restart","params":{}}

// 调整参数：立即生效（aria2.changeGlobalOption），不重启、不打断在下的任务
{"id":"3","method":"aria2_configure","params":{"split":5,"maxConnectionPerServer":5,
  "maxConcurrentDownloads":1,"minSplitSizeMiB":1,"maxOverallDownloadLimitKiB":0}}

// 排队一个文件，out 是引擎目录里的文件名（应用挑它，导入才拿得到期望的名字）
{"id":"4","method":"aria2_add","params":{"url":"https://isure.stream.qqmusic.qq.com/...","out":"0039MnYb0qxYhV-ab12cd34.flac"}}
{"id":"4","ok":true,"download":{"gid":"d1cdc604873d9e10"}}

// 轮询进度（status 为 complete / error / removed 时结束）
{"id":"5","method":"aria2_tell","params":{"gid":"d1cdc604873d9e10"}}
{"id":"5","ok":true,"download":{"status":"active","completed":8290304,"total":19844411,
  "speed":4032580,"path":".../Downloads/xxx.flac","error":"","errorCode":"0"}}
```

**几个要点**：

- 端口固定 **16800**（不是 aria2 默认的 6800——那正是用户自己的守护进程会占的），只监听回环，
  `--rpc-secret` 每次启动重新生成。
- 引擎**按需启动**：打开设置页不会拉起进程，只有真的要下载时才启动。
- 参数会被 clamp（split/连接数 1–16、任务数 1–10、最小分块 1MB 起）——上游对这些字段是零容忍的。
- 引擎缺席（老版本组件目录）时，应用**自动退回自己的下载实现**，功能不受影响。

### 安装/替换时注意

`aria2-next` 与组件一样，**复制到新位置后要 ad-hoc 签名**：

```sh
cp <新组件>/aria2-next ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/
xattr -cr ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext
codesign --force --sign - ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/aria2-next
codesign --force --sign - ~/Library/Application\ Support/kmgccc.player/QQMusicHelperNext/qqmusic-helper-next
```

不签名的可执行文件在带 `com.apple.provenance` 的位置（外部目录、/tmp 都算）会被系统**直接杀掉**：
退出码 137、stdout/stderr 一个字都没有——实测过，`xattr -cr` 单独不够，必须签名。

## 兼容性不是"差不多就行"

应用按固定的键名解码每个响应，缺键不会报错——**只会让那个字段静默为空**。
2026-09-30 做过一次逐方法的实测比对（同一凭据下，新旧组件的响应逐键对比），因此补齐了：

- `fetch_song_detail` / `fetch_album_detail` / `fetch_artist_detail`：能按**名字**解析（本地曲库补全
  手里没有 mid），回答包在 `detail` 里，并带 `source` / `imageURL` / `genreTags` / `releaseYear` /
  `labelOrCompany` / `metadataFetchedAt` / `confidence` 等应用要读的键；
- `fetch_artist_biography`：包在 `artistDetail`（不是 `detail`）里——应用读的是这个键；
- `fetch_toplist_categories` / `fetch_radio_stations`：分组同时给 `name` 与 `title`（`name` 是应用解码的键，
  且非可选——少了它整页解不出来）；
- `resolve_song_url`：成功与失败都给全（`extension` / `tried` / `restriction` / `source`），
  否则下载会按 `.mp3` 命名一个 flac 文件、失败也说不出原因；
- 歌单与排行榜**分页并回报总数**（`dirinfo.songnum` / `totalNum`），歌单按 `page` 而不是只认 `offset`；
- 风控（`code 2001`）等拒绝码一律报错，**不再**伪装成"没有结果"。

# HelperNext — 在线音源的数据组件

QQ 音乐在线音源**唯一**的数据获取组件：所有在线内容的读取与登录都在这里，应用只跟它说一句话式的 JSON。

## 为什么要有它

上一版把这件事拆成了两处——Python helper（内含整个解释器 + `qqmusic-api-python`，约 56 MB）和
应用内的 Swift 网页通道（`QQMusicWebAPI`）——同一个能力常常有两份实现，而且两条通道要各自维护。
HelperNext 用一个静态链接的二进制把两者合并：**2.0 MB**，没有解释器、没有第三方 SDK，
上游接口或解析方式变化时**只换这个二进制**，不重新构建应用。

## 协议（与旧 helper 逐字兼容）

stdin 一行一个请求，stdout 一行一个响应；stdout 只走协议，诊断走 stderr。

```json
请求   {"id": "1", "method": "fetch_liked_songs", "params": {"page": 1, "limit": 50}}
响应   {"id": "1", "ok": true, "likedSongs": {"title": "我喜欢", "total": 479, "tracks": [ ... ]}}
失败   {"id": "1", "ok": false, "error": "需要登录后才能读取"}
```

**`id` 必须回带**：应用按它把响应配给请求；少写一个 id 不会报错，只会等到应用 15 秒超时
（Python helper 上真踩过这个坑）。

兼容旧协议是有意的：应用侧的进程客户端不用改，迁移期间没搬完的方法可以继续由旧 helper 提供。

## 构建与运行

```sh
cargo build --release          # 产物 target/release/qqmusic-helper-next
cargo test                     # 单元测试（凭据、限流、熔断、解析、日期换算）
```

凭据与旧 helper **同一个文件**（`~/Library/Application Support/kmgccc.player/QQMusicHelper/Credential/
qqmusic-credential.json`），所以已有登录直接可用，两个组件可以来回替换而不用重新登录。
目录可用 `QQMUSIC_HELPER_DIR` 覆盖（测试用）。

## 已实现

| 方法 | 说明 |
|---|---|
| `get_helper_info` | 版本、协议版本、方法表（不发网络请求） |
| `get_login_status` | 直接问上游，能区分"没登录"与"登录过期" |
| `import_cookies` | 用网页登录拿到的 cookie（`qm_keyst` + `uin`）建立登录 |
| `logout` | 清除凭据 |
| `fetch_liked_songs` | 我喜欢，分页，带 `total` |
| `fetch_playlist_tracks` | 歌单/排行榜曲目（`CgiGetDiss`，`dirinfo.songnum` 就是总数） |
| `fetch_user_playlists` | 我的歌单（走 `c.y.qq.com` 老 fcgi，`reqtype=3`） |
| `fetch_liked_albums` | 收藏专辑（同一 fcgi，`reqtype=2`） |
| `fetch_followed_artists` | 关注的歌手（`HostUin` 用 `encrypt_uin`） |

**待实现**（清单与每个接口的 module/method/param 见 `docs/qqmusic/25-helper-next.md`）：
专辑曲目、歌手歌曲/专辑/资料/简介、排行榜分组与曲目、电台分组与曲目、新歌、搜索（歌曲/歌手/专辑/歌单）、
猜你喜欢、歌曲与专辑简介、歌词（含逐字）、取流地址、收藏与取消收藏的写操作、扫码登录（登录交互）。

## 限流与熔断

两个机制都在组件里，因为现在只有它看得见全部流量：

- **限流**：按内容类别分桶的固定窗口——`Read` 30/10s、`Interactive`（搜索、电台）12/10s、
  `Playback` 20/10s、`Account`（我喜欢、歌单）12/10s、`Write`（收藏）6/10s。超限**等待**而不是丢弃：
  每一次调用都是用户看得见的读取，延迟比失败好。
- **熔断**：60 秒窗口内失败 5 次即开路 30 秒，期间直接返回原因（不发请求）；到期后放**一个**探测请求，
  成功即闭合。参数与旧 helper 的设置项同义，所以设置页那几项仍然说得通。

## 目录

```
Cargo.toml
src/main.rs        stdio 协议循环、方法分发、凭据落盘
src/protocol（内含 main.rs）  请求/响应形状
src/upstream.rs    musicu.fcg 与老 fcgi 两个上游客户端、g_tk、字段取值工具
src/credential.rs  凭据读写、cookie 导入、hash33
src/guard.rs       限流 + 熔断
src/methods.rs     各端点与载荷映射
```

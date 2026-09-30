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

# QQ 音乐在线音源

`qqmusic/` 是这个改版**除应用源码之外的一切**。应用源码（`kmgccc_player/`）里只有本功能必需的接入点改动，
每一处都登记在 `AGENTS.md` 的「对上游的改动」表里；其余全部集中在这里，便于上游更新时搬迁。

```
qqmusic/
  README.md           ← 本文件：功能做什么、怎么实现、怎么维护
  integration/        补丁包：modules/（上游没有的新文件）+ patches/（上游文件的 diff）+ 脚本
    BASE              打这个包所依据的上游 commit
    apply.sh          把补丁包重放到一个检出上
    sync.sh           从开发树重新生成补丁包
    test-cycle.sh     干净基线上一路走完：重建 → 重放 → 构建 → 测试 → 启动
```

本地工作笔记（设计、方案、实现记录、API 笔记）在 `docs/qqmusic/`，按约定不进仓库。

## 一、功能做什么

保留原应用的全部本地能力，在其之上加一个 QQ 音乐在线音源：

- **浏览**：落地页最上方是精选大卡片（内容取「猜你喜欢」，换一首换一张，卡面显示歌曲简介——点它读全文），往下是收藏歌单、收藏专辑、关注的歌手、新歌电台、排行榜、电台、猜你喜欢；向下钻到歌单 / 专辑 / 排行榜 / 电台 / 歌手的详情页。行内「更多」菜单可查看详情、查看歌曲描述、查看艺人、查看专辑。搜索支持歌曲 / 歌手 / 专辑 / 歌单四类；歌手页的歌曲与专辑都能按热门或最新排序；歌手简介与本地页面一样可滚动、点开读全文。
- **播放**：点击列表里的一行即播放。顺序播放从**你点的那一首**往下走到表尾（不回头到表头）；随机播放先放这一首，其余整表打乱——两种模式下队列里排队的就是接下来真正会播的那些。
- **下载入库**：在线歌曲下载后走原应用的导入管线入库，于是无缝播放、原生歌词、频谱、Now Playing 全部自动继承。批量下载在选择模式下勾选（整行变色表示选中），已手动下载过的曲目不可再选、排在最前。
- **我的**：我喜欢、收藏歌单、收藏专辑；行内可收藏/取消收藏（写回上游）。
- **缓存与回收**：歌单/推荐/排行榜/浏览态封面缓存在资料库的 `QQMusic/` 目录，歌曲缓存只约束「为了播放而自动下载」的那部分，可设定上限并回收；用户自己点过下载的属于曲库，永不回收。

## 二、怎么实现（要点）

**先下载，后本地播放。** 播放引擎（`AVAudioPlaybackService`）基于 `AVAudioFile`，只认本地文件。
在线歌曲一律先下载入库，再作为普通本地曲目播放。这是"零改动继承原应用一切能力"的原因。

**两条通道，一条规则。** 在线数据来自两个客户端：

| 通道 | 是什么 | 用于 |
|---|---|---|
| `Services/QQMusic/QQMusicWebAPI.swift` | 直连 `u.y.qq.com/cgi-bin/musicu.fcg` 的 HTTP 请求 | **有网页接口的读**：我喜欢、收藏专辑、收藏歌单、歌单分页、排行榜分页、歌词、关注的歌手、歌曲简介 |
| `Tools/QQMusicHelper/`（Python，基于 `qqmusic-api-python`） | 独立子进程，stdin/stdout JSON | **没有网页接口的一切**：专辑曲目、歌手、电台、新歌、搜索、排行榜分组、推荐流、取流，以及**唯一的写**（收藏/取消收藏）；同时是网页读的**兜底** |

规则由 `QQMusicOnlineCoordinator.webFirst(_:web:helper:)` 一处执行：按**每类内容各自的偏好**（QQ 音乐设置
→ 在线内容）先试选中的那条，失败就退回另一条并记一行日志——所以选哪条都不会把页面弄坏，方向反过来也一样。
偏好按内容分组（`QQMusicChannelSubject`）：账号列表、曲目列表、歌曲描述默认走网页（两边返回的内容相同，
网页快约四倍）；**歌词默认走 Helper**（它的歌词可含逐字时间）。只有一条通道能取的内容在设置里显示但置灰，
并写明原因。

**Helper 那一格的内部还有一层：`qqmusic-api-python`（第三方 Python 库）↔ `Tools/QQMusicHelper/main.py`
（本项目自己的程序）。** 库负责签名、cookie、平台参数与模块方法（`client.lyric.get_lyric` 是逐字歌词的来源，
`client.song.get_song_urls` 是取流）；helper 负责 JSON 协议与能力自报、**库里没包成公开方法的接口**
（用 `client.song._build_cgi` / `_build_http` 直接打上游，共 10 处）、字段归一化（含补上库模型没有的
`albumId` / `singers`）、以及取流音质阶梯等业务动作。所以"helper 可独立替换"这件事包含换库版本：
`requirements.txt` 钉 `qqmusic-api-python==0.7.3`，PyInstaller 把运行时和库一起打进 `_internal.bundle/`，
使用者的机器不需要装 Python。应用侧**只显示、不校验** helper 的版本号（设置 → Helper 组件）。
详见根 `README.md` 的「Helper 组件」一节。

有一个例外要记住：**整表读取时网页返回空列表按"没作答"处理，改问另一条；而歌曲简介返回空就是答案**——
大多数歌本来就没有简介，把空当成"没答"会让每首歌都白跑两条通道。
|
没有网页接口的路径不必假装有——`fetchListPage` 里排行榜只走网页，就明确写了原因（helper 那条路由不接受
page/offset，只能答第一批，拿它当"下一页"会死循环）。

**缓存策略：先显示缓存，取到完整的在线数据，不符才整体替换。** 会变但变得不多的列表
（我喜欢、收藏歌单、收藏专辑、歌单/专辑/排行榜的曲目）都走同一套：

1. 缓存里有什么就先画什么——我喜欢的缓存是**完整列表**（一个 payload），所以页面一进来就是完整的；
2. 去上游取**完整**的那一份；
3. 与屏幕上的一致就什么都不做；不一致才**一次性替换**。

绝不逐页往正在显示的列表里塞、也绝不为了加载而清空页面。刷新时同样：替换用的是完整列表，
拿第一页去替换会把 400 首的歌单缩成 100 首再长回来。

**数据与缓存不和应用混放。** 在线数据放在资料库的 `QQMusic/`（与应用自身的 `Cache/` 平级且分开），
helper 凭据放在 helper 目录的 `Credential/`。

**失败只写日志。** 曾经有一条挂在工具栏下方的提示条承载失败与各种确认，按用户要求整条删除
（连设置里那两个开关一起）；失败仍可在日志里查，日志插值里的 `noteFailure(error)` 还负责记录限流退避。

## 三、怎么构建

```sh
./scripts/bootstrap.sh              # 构建外部组件（含 QQ 音乐 helper）
./scripts/build_and_run.sh          # 构建并运行
DEVELOPMENT_TEAM=<你的teamID> ./scripts/build_and_run.sh   # 本机需要覆盖签名 team
```

helper 重建后要同步到外部目录才会被应用优先使用（`test-cycle.sh` 会自动做）：

```sh
cp -R .build/products/qqmusic-helper/* \
  ~/Library/Application\ Support/kmgccc.player/QQMusicHelper/
```

## 四、怎么打补丁 / 维护

```sh
./qqmusic/integration/sync.sh           # 改完功能：从开发树重新生成 modules/ + patches/
./qqmusic/integration/sync.sh --check   # 提交前：是否落后（落后则非零退出）
./qqmusic/integration/test-cycle.sh --sync   # 改完必跑：重建 → 重放 → 构建 → 测试 → 启动
```

改动只有走完 `test-cycle.sh` 才算完成："补丁能应用"不等于"补丁能构建、能跑"。
把它重放到别人的上游版本上：

```sh
cp -R qqmusic/integration /path/to/kmgccc_player/
cd /path/to/kmgccc_player
./qqmusic/integration/apply.sh --repo . --verify
```

补丁失败是**预期行为**，表示上游改动了同一个文件；处理步骤见 `integration/README.md`。

## 五、参考的项目

- **[qqmusic-api-python](https://github.com/L-1124/QQMusicApi)** — QQ 音乐接口的 Python 实现，helper 的浏览、搜索、电台、歌手、歌词与取流都走它。
- **[kmgccc_player](https://github.com/kmgcc/kmgccc_player)** — 播放器本体（上游）。它的 README 里列出的
  AMLL、LDDC、apple-audio-visualization、ncmdump、sacad、QQMusicApi、MediaRemote Adapter 等组件同样构成本项目的基础；
  本功能只是在这套能力之上接了一层在线音源。

# QQ 音乐在线音源 · 补丁包（1.0.0）

这是给 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) **2.3.1** 加装 QQ 音乐在线音源的补丁包。

它不是一个改过的源码压缩包，而是一份**可重放的变更集**：`modules/` 是新文件（整份复制，不会冲突），
`patches/` 是对上游既有文件的 diff。把它应用到一个未改动的上游源码上，就得到完整功能——
所以「装了补丁的仓库 = 上游 + 一份可审计的变更集」，上游更新时可以把功能搬过去，而不必手工重做。

- 基线（`BASE`）：`b0de7aa6` — kmgccc_player 2.3.1
- 补丁版本：`1.0.0`（与上游版本分开，见应用内 QQ 音乐设置 → Helper 组件 → 「本功能版本」）
- 已在一份干净的 `b0de7aa6` 检出上验证：重放后产物与开发分支一致，构建成功、单元测试通过、应用能启动

---

## 一、这个补丁加了什么

保留原应用的全部本地能力，在其之上加一个 QQ 音乐在线音源：

- **浏览**——落地页顶部是精选大卡片（取「猜你喜欢」，可换一首，卡面有歌曲简介，文字颜色按封面明暗自动取深/浅），
  下面是收藏歌单、收藏专辑、关注的歌手、新歌电台、排行榜、电台、猜你喜欢；可下钻到歌单 / 专辑 / 排行榜 /
  电台 / 歌手的详情页。返回、前进、搜索、刷新、批量下载都在窗口工具栏里，与原应用同一层玻璃、同一套交互。
- **播放**——点击列表任意一行即从这一行开始播：顺序播放往下走到表尾，随机播放覆盖整张在线列表
  （而不是只覆盖已下载的那几首）。在线歌曲先下载、经**原有导入管线**入库，再交给**原有播放引擎**播放，
  因此无缝播放、原生歌词、频谱、Now Playing、播放历史全部自动继承。
- **收藏与登录**——扫码或网页登录；在线收藏/取消收藏写回上游；「我喜欢」、收藏歌单、收藏专辑。
- **缓存与回收**——歌单/推荐/排行榜/浏览态封面缓存在资料库的 `QQMusic/` 目录（与应用自身的 `Cache/` 平级且分开）；
  歌曲缓存只约束「为了播放而自动下载」的那部分，可设上限并回收，你自己点过下载的属于曲库、永不回收。
- **两条通道**——常读的内容走直连网页接口（快约三倍），其余走 helper 组件；每条内容可以指定先用哪条，
  **没选中的那条在它失败时自动兜底**（设置 → 在线内容里有逐行说明，并显示最近一次实际由谁回答）。
- **一行 helper 之外零依赖**——helper 是独立进程，可从外部目录替换，接口变化时无需重新构建应用。

本补丁还**关闭了自动更新、崩溃上报与匿名统计**（默认关且不可开）：更新源属于上游项目，装上去会覆盖本版本的
功能改动；崩溃与统计会发到上游作者的服务器，而对方无法据此做任何事。

功能的完整设计说明见 `FEATURES.md`（即仓库里的 `qqmusic/README.md`）。

## 二、怎么用这个补丁包

### 1. 拿到基线源码

```sh
git clone --recurse-submodules https://github.com/kmgcc/kmgccc_player.git
cd kmgccc_player
git checkout b0de7aa6
```

### 2. 应用补丁

```sh
cp -R /path/to/这个补丁包/integration ./qqmusic/integration
./qqmusic/integration/apply.sh --repo . --verify
```

`--verify` 会逐条校验应用后的内容；`--dry-run` 只看会改哪些文件。

应用失败是**预期行为**，不是 bug：`patches/` 里的 diff 只有在上下文仍然匹配时才干净应用。
输出会指名是哪个文件、哪份补丁，一条失败不会挡住其余的。上游动了同一处时，按
`integration/README.md` 的说明人工移植意图即可。

### 3. 构建

```sh
./scripts/bootstrap.sh                        # 构建外部组件（含 QQ 音乐 helper，需要 Python 3.12 / Node 22 / CMake）
DEVELOPMENT_TEAM=<你的 team id> ./scripts/build_and_run.sh
```

工程里钉的是原作者（上游）的签名 team，所以要覆盖成你自己的。

> 不想在本地编译 helper？本补丁包的 Release 页里那份 DMG 中的应用已经带了构建好的 helper，
> 解法在下一节。

### 4. helper：可外部替换的独立组件

应用优先从下面这个目录加载 helper，bundle 内的副本只作兜底：

```
~/Library/Application Support/kmgccc.player/QQMusicHelper/
```

所以有两个办法：`./scripts/bootstrap.sh --component qqmusic-helper` 自己构建，或者把 DMG 里
`kmgccc_player.app/Contents/Resources/Tools/qqmusic-helper`（连同 `_internal.bundle`）整个复制到上面那个目录。

## 三、注意事项

- 下载功能需要**托管**资料库；原位引用（referenced）模式的资料库只能浏览——导入管线不接受应用自己产生的文件。
- 在线接口是逆向来的，随时可能变化；变化时优先替换 helper，而不是重新构建应用。
- 本补丁只对**基线 `b0de7aa6`** 验证过。上游更新后重放，`patches/` 大概率有冲突需要人工处理。

## 四、参考的项目

- [kmgccc_player](https://github.com/kmgcc/kmgccc_player) —— 播放器本体（上游）；它依赖的 AMLL、LDDC、SACAD、
  MediaRemote Adapter、ncmdump 等组件同样构成本项目的基础
- [qqmusic-api-python](https://github.com/L-1124/QQMusicApi) —— QQ 音乐接口的 Python 实现，helper 的目录、
  排行、电台、歌手、歌词与取流都走它

## 五、许可证

与上游一致：AGPL-3.0。第三方组件遵循各自许可证。

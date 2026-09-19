# QQ 音乐在线音源 — 上游更新后的快速植入包

本目录让「把 QQ 音乐功能植入一个更新后的 kmgccc_player」变成一条命令的事。

**基线**：`b0de7aa6`（上游 `docs: reorganize public technical architecture documentation (#47)`）
**已验证**：在一份干净的 `b0de7aa6` 检出上执行 `./apply.sh` 后，产物与开发分支**逐字节一致**，且**构建成功**。

---

## 一、用法

```sh
# 1. 拿到上游新版本（例如已 clone 到 /path/to/kmgccc_player）
#    把本目录复制进去（或直接在本仓库里执行）
cp -R qqmusic-integration /path/to/kmgccc_player/

# 2. 植入
cd /path/to/kmgccc_player
./qqmusic-integration/apply.sh --repo .

# 3. 构建
./scripts/bootstrap.sh --component qqmusic-helper
./scripts/build_and_run.sh
```

先看会做什么、不实际改动：

```sh
./qqmusic-integration/apply.sh --repo . --dry-run
```

---

## 二、两类改动，行为完全不同

理解这一点，就能看懂脚本的输出。

### 第一类：`modules/` — 新增文件（10 个）

上游**没有**这些文件，所以直接复制，**永远不会冲突**：

```
kmgccc_player/Services/QQMusic/
  QQMusicOnlineCoordinator.swift    浏览状态、下载入库、播放会话与后台预取
  QQMusicDownloadService.swift      取流、下载音频、抓封面与歌词
  QQMusicCacheStore.swift           在线产物的磁盘缓存
  QQMusicWebLoginWindow.swift       网页登录（WKWebView 捕获 cookie）
  QQMusicWindowManager.swift        QQ 音乐窗口的呈现状态
  QQMusicQualityPreference.swift    下载品质偏好
kmgccc_player/Views/QQMusic/
  QQMusicOnlineView.swift           浏览页（我的/猜你喜欢/电台/新歌/搜索/排行榜）
  QQMusicArtistDetailView.swift     在线歌手页（复刻本应用艺人界面 + 专辑页）
  QQMusicArtworkView.swift          走缓存的封面视图
kmgccc_player/Views/Settings/
  QQMusicSettingsView.swift         QQ 音乐窗口（账号/在线内容/播放/Helper/缓存）
```

### 第二类：`patches/` — 修改上游文件（20 个）

这些文件上游**也有**，改动以 diff 形式存放。**它们只在周围代码仍然匹配时才能干净应用。**

上游一旦改了这些文件，补丁可能失败——**这是预期行为，不是工具坏了**。

---

## 三、补丁失败时怎么办

脚本会继续执行并汇总需要处理的文件。失败意味着**上游改动了那个文件**，需要人工移植意图：

```sh
# 看这个补丁想做什么
cat qqmusic-integration/patches/kmgccc_player_Views_Sidebar_SidebarView.swift.patch

# 在新代码里手工实现同样的意图，然后重跑
./qqmusic-integration/apply.sh --repo .
```

**不要**用 `git apply --force` 硬来，也不要直接把补丁里的旧代码整段覆盖上去——那会把上游的新改动抹掉。

### 补丁清单与改动性质

| 文件 | 改动 | 冲突风险 |
|---|---|---|
| `Services/QQMusic/QQMusicHelperProcess.swift` | 新增大量方法 + 修 stdout 字节缓冲、可配置熔断/空闲、可重试 | **高**（上游此文件较大，且我们动过既有函数体）|
| `Views/Sidebar/SidebarView.swift` | 新增入口按钮 + sheet | 中 |
| `Services/LibrarySession/LibrarySession.swift` | 持有并构造协调器、推送设置、预加载钩子 | 中 |
| `Models/AppSettings.swift` | 新增若干 `@AppStorage` 设置项 | 低（纯追加）|
| `Services/Import/FileImportService.swift` | 新增 `importProducedAudio` / `applyProvenance` | 低（纯追加）|
| `Services/Import/FileImportServiceProtocol.swift` | `ImportMetadataOverride` 加 `artworkData` / `lyrics` | 低 |
| `Services/Import/ImportPlanner.swift` | 让上述两字段优先于文件标签 | 低 |
| `Services/Import/ImportPlacement.swift` | 新增 `LibraryImportOrigin.onlineDownload` 与 `OnlineImportProvenance` | 低 |
| `Services/LibrarySession/LibraryPaths.swift` | 新增 `QQMusic/` 缓存路径 | 低 |
| `ViewModels/AppSessionHost.swift` | 暴露 `qqMusicOnlineCoordinator` | 低 |
| `ViewModels/UIStateViewModel.swift` | 新增 `ContentMode.qqMusicOnline` | 低 |
| `AppKit/AppKitMainSplitPanes.swift` | 新增 `.qqMusicOnline` 渲染分支 | 低 |
| `Views/MiniPlayer/MiniPlayerView.swift` | 播放栏收藏按钮 | 中 |
| `Views/Controls/MediaControlSymbolShapes.swift`、`Views/Library/TrackRowView.swift` | 4 处 `Shape` 加 `nonisolated` | 低，但**可能已上游修复**（见下）|
| `Tools/QQMusicHelper/*`、`scripts/components/qqmusic-helper.sh` | helper 扩展、依赖版本、打包参数 | 中 |
| `.gitignore` | 忽略本地文档目录 | 低 |

---

## 四、两个已知的上游差异点（可以先检查再决定要不要打）

1. **`Shape` 的 `nonisolated`（2 个文件，4 处）**
   这是**上游既有代码在 Xcode 27 下的编译错误**，与 QQ 音乐功能无关。工程面向 Xcode 26.2，其 `Shape` 协议的 actor 隔离检查更宽松。
   若上游已升级到 Xcode 27（或已自行修复），**这两个补丁可以跳过**：
   ```sh
   rm qqmusic-integration/patches/kmgccc_player_Views_Controls_MediaControlSymbolShapes.swift.patch
   rm qqmusic-integration/patches/kmgccc_player_Views_Library_TrackRowView.swift.patch
   ```

2. **`Tools/QQMusicHelper/*`**
   上游已有的 helper 只做元数据/封面。我们的补丁把它扩展为完整的浏览/登录/取流能力，**包括把 `qqmusic-api-python` 从 0.5.3 升到 0.7.3**。
   若上游已自行升级过该文件，补丁会失败——此时应**以本目录的实现为准**重新对照（我们的 helper 是功能主体，不能丢）。

---

## 五、构建前置条件

- **helper 必须重建**：`./scripts/bootstrap.sh --component qqmusic-helper`。
  外部目录（`~/Library/Application Support/kmgccc.player/QQMusicHelper/`）优先于 bundle 内副本，替换该目录即可更新，无需重建应用。
- **AMLL 子模块**：`git submodule update --init --recursive`。
- **签名**：原工程用作者自己的 team（`TYU73KR9WW`）。本机构建需覆盖：
  ```sh
  xcodebuild ... DEVELOPMENT_TEAM=<你的teamID>
  ```
- **Node 22 + corepack**（AMLL 构建）：npm 官方源不通时用 `registry.npmmirror.com`。

---

## 六、植入后验证清单

按顺序做，前一项不过就不要往后走：

1. **构建通过**：`./scripts/build_and_run.sh`
2. **应用启动**，本地曲库、播放、歌词、频谱、全屏、设置**与原来一致**（这是最重要的一条：新功能不得损害原有行为）
3. Debug 构建通过 → 侧边栏底部出现地球按钮 → 打开 QQ 音乐窗口
4. 切到「猜你喜欢」有内容；「我的」能读到收藏与自建歌单
5. 点播一首 → 下载 → 入库 → 播放；播放栏出现收藏按钮
6. 排行榜点进去能加载（这条曾因 stdout 分块解码 bug 失败）
7. 搜索页搜索后切换标签，其他标签**不再显示搜索结果**

---

## 七、目录结构

```
qqmusic-integration/
├── README.md        本文件
├── apply.sh         一键植入脚本（支持 --dry-run）
├── modules/         10 个新增文件，直接复制
└── patches/         20 个上游文件补丁，可能需要人工合并
```

---

## 八、维护约定

- **改动了任意一处，请同步更新本目录**：新文件放进 `modules/`，上游文件改动重新生成补丁。
  重新生成全部补丁（在开发分支上，`BASE` 为上游基线提交）：
  ```sh
  BASE=b0de7aa6
  for f in $(git diff --name-status $BASE HEAD | grep "^M" | awk '{print $2}'); do
    safe=$(echo "$f" | tr '/' '_')
    git diff $BASE HEAD -- "$f" > "qqmusic-integration/patches/${safe}.patch"
  done
  ```
- **不要把本目录加进 `.gitignore`**：它是给未来的自己用的工具，应当随仓库走。
  （与之相反，`docs/qqmusic/` 是开发笔记，按约定不进仓库。）

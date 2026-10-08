# kmgccc_player · QQ Music

这是 [kmgccc_player](https://github.com/kmgcc/kmgccc_player) 的 **QQ 音乐维护型 fork**。

本仓库保留上游播放器的完整源码与 GitHub fork 关系，在其基础上维护 QQ 音乐在线浏览、搜索、
播放/下载入库、登录、缓存与设置集成；同时提供一套可重放的补丁包，方便审计本 fork 相对指定
上游基线做了什么。

> 本项目不是 kmgccc_player 官方发行版，也与腾讯 / QQ 音乐无官方关系。

## 使用方式

### 直接安装

从本仓库的 [Releases](https://github.com/LeeDespo/kmgccc-player-qqmusic/releases) 下载最新 DMG。
当前发行面向 **Apple Silicon / macOS 26+**，采用 ad-hoc 签名且未公证；首次启动需要按 Release
说明在 macOS 中手动放行。

QQ 音乐下载会进入播放器的本地曲库，因此需要使用可写的“托管”资料库。

### 从源码构建

```sh
git clone --recurse-submodules https://github.com/LeeDespo/kmgccc-player-qqmusic.git
cd kmgccc-player-qqmusic
./scripts/bootstrap.sh
./scripts/verify.sh
```

`bootstrap.sh` 会按照仓库中的锁文件下载并校验 QQ Music 运行组件；这些可执行文件不是 Git 源码，
也不会提交进仓库。

### 重放 QQ Music 补丁

Release 同时提供 replayable patch package。其上游基线只以
[`qqmusic/integration/BASE`](qqmusic/integration/BASE) 为准，使用方法见
[`qqmusic/integration/README.md`](qqmusic/integration/README.md)。

## QQ 音乐功能

- 在线首页、搜索、歌单、专辑、歌手、排行榜、电台与推荐；
- QQ / Web 登录与登录状态管理；
- 在线歌曲下载后进入本地资料库并沿用播放器播放链；
- 下载队列、进度、暂停/继续/取消，以及质量偏好；
- QQ Music 逐字歌词与现有歌词渲染链集成；
- 在线/本地曲目的封面与元数据补全。

功能边界与宿主架构见 [qqmusic/README.md](qqmusic/README.md)。

## 仓库结构

| 路径 | 角色 |
|---|---|
| `kmgccc_player/` | 实际可构建的播放器工作树；QQ Music 宿主代码也在这里 |
| `kmgccc_playerTests/` | 本 fork 的生产行为测试 |
| `qqmusic/integration/BASE` | replayable patch 的唯一上游基线 |
| `qqmusic/integration/modules/` | 相对基线新增文件的**生成副本** |
| `qqmusic/integration/patches/` | 相对基线修改文件的**生成 diff** |
| `qqmusic/integration/removals.txt` | 相对基线删除的文件 |
| `qqmusic/integration/components.lock.json` | HelperNext / Aria2 Next 精确版本与 SHA-256 |
| `qqmusic/RELEASING.md` | 本 fork 发布规则唯一真源 |
| `AGENTS.md` | Agent 的仓库边界与真源路由 |

`modules/` 与 `patches/` 不是第二套手工源码。修改实际工作树后运行
`qqmusic/integration/sync.sh` 生成它们，CI 会用 `--check` 阻止漂移。

## 组件边界

本仓库是**消费端 / 宿主**：

- Swift 侧负责 UI、导航、缓存、下载入库、播放与设置；
- [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) 负责 QQ 音乐协议请求、
  签名、响应解析、凭据和上游保护；
- [Aria2 Next](https://github.com/AnInsomniacy/aria2-next) 是可选下载引擎。

HelperNext 的端点、queryId/module/method、解析规则不在本仓库复制维护。精确组件版本与哈希只在
`components.lock.json` 中保存。

## 上游与更新

保留 GitHub fork 身份是有意的：本项目仍然建立在 kmgccc_player 之上。升级上游时，先迁移实际工作树，
完成构建/测试后再以新的上游 commit 重新生成 replayable patch；不要直接在 `patches/` 里手改冲突。

贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

播放器及本 fork 源码遵循根目录 [LICENSE](LICENSE) 中的 **AGPL-3.0**。运行时第三方组件有各自许可证：

- QQMusicApi_HelperNext：GPL-3.0-or-later；
- Aria2 Next：GPL-2.0；
- 其他上游依赖与运行资源沿用 kmgccc_player 的许可证文件和声明。

来源与分发边界见 [NOTICE](NOTICE)。

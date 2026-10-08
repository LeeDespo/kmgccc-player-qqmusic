# QQ Music 集成

本目录描述 **kmgccc_player 宿主如何集成 QQ Music**。QQ 音乐协议本身由
[QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext) 维护，本仓库不复制其 endpoint 知识。

## 责任分层

```text
Swift UI / navigation / cache / local library / playback
                     │
                     ▼
       QQMusicComponentProcess (stdio adapter)
                     │ JSON lines
                     ▼
             qqmusic-helper-next
                     │
                     ├─ QQ Music upstream protocol
                     └─ aria2-next (optional download engine)
```

本仓库负责横线以上的宿主行为以及进程边界；HelperNext 负责协议请求、签名、解析、凭据和上游保护。

## 宿主侧主要模块

- `Services/QQMusic/QQMusicComponentProcess.swift`：组件生命周期、stdio 请求关联、配置与版本信息；
- `QQMusicOnlineCoordinator.swift`：在线页面数据编排与宿主状态；
- `QQMusicDownloadService.swift`：下载任务到本地资料库的衔接；
- `QQMusicCacheStore.swift` / `QQMusicCacheBudget.swift`：宿主缓存；
- `Views/QQMusic/`：浏览、搜索、详情、下载与选择 UI；
- `Views/Settings/QQMusicSettingsView.swift`：QQ Music 设置与组件状态。

公开行为由 `kmgccc_playerTests/` 的相关测试覆盖。测试应验证宿主生产行为，而不是保存第三方 endpoint 的历史故事。

## 组件版本

精确组件版本、Release 资产与 SHA-256 只在
[`integration/components.lock.json`](integration/components.lock.json) 保存。

```sh
./scripts/bootstrap.sh --component qqmusic
./scripts/bootstrap.sh --check --component qqmusic
```

bootstrap 会下载锁定资产、校验哈希并物化运行时许可证；生成文件不进入 Git。

## Replayable Patch

`integration/` 是本 fork 相对某个上游 commit 的可重放表示：

- `BASE`：唯一上游基线；
- `modules/`：新增文件的生成副本；
- `patches/`：修改文件的生成 diff；
- `removals.txt`：删除列表；
- `sync.sh`：从当前工作树重新生成上述内容；
- `apply.sh`：把补丁应用到干净上游；
- `test-cycle.sh`：从干净基线重放、构建和测试。

维护规则见 [integration/README.md](integration/README.md)。

## 版本与发布

QQ Music 功能版本由生产代码中的 `patchVersion` 定义；不要在长期文档里另抄当前版本。
发布规则只看 [RELEASING.md](RELEASING.md)，历史变化见 [CHANGELOG.md](CHANGELOG.md)。

## 凭据与外部组件

HelperNext 的凭据目录由宿主提供并位于用户 Application Support 下；凭据、cookie、token、
真实账号响应和用户曲库内容不得进入仓库、日志或测试 fixture。

Aria2 Next 缺席时宿主保留自己的下载 fallback；是否 bundled、版本为何，仍以组件 lock 和构建结果为准。

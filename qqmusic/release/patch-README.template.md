# QQ Music Replayable Patch

此包用于 **kmgccc_player @UPSTREAM_VERSION@**。

- 上游基线：`@UPSTREAM_BASE@`
- QQ Music patch：`@PATCH_VERSION@`
- 精确 HelperNext / Aria2：`integration/components.lock.json`

在干净上游 checkout 中：

```sh
git checkout @UPSTREAM_BASE@
# 将本包 integration/ 放到 ./qqmusic/integration/
./qqmusic/integration/apply.sh --repo . --verify
./scripts/bootstrap.sh
./scripts/verify.sh
```

`modules/`、`patches/` 和 `removals.txt` 都是生成物，不应手改。
第三方可执行文件不会放进 patch package；bootstrap 会从正式 Release 下载并按 lock 校验。

上游版本变化后应重新迁移工作树并生成 patch，而不是强行把旧 diff 套到新版本。

许可证：本 fork / kmgccc_player 为 AGPL-3.0；QQMusicApi_HelperNext 为 GPL-3.0-or-later；
Aria2 Next 为 GPL-2.0。

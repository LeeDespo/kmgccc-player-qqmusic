# Contributing

这个仓库是 kmgccc_player 的 QQ Music 维护型 fork。

## 先判断问题属于哪里

- 未修改的 kmgccc_player 也能复现的问题：优先提交到 [上游](https://github.com/kmgcc/kmgccc_player)；
- QQ Music、HelperNext 宿主集成或本 fork 回归：提交到本仓库；
- QQ Music endpoint/签名/解析本身：提交到 [QQMusicApi_HelperNext](https://github.com/LeeDespo/QQMusicApi_HelperNext)。

## 开发

实际实现只改根工作树。不要直接编辑 `qqmusic/integration/modules/` 或 `patches/`；
完成代码和测试后运行 `qqmusic/integration/sync.sh` 生成发行表示。

第三方运行组件通过 `components.lock.json` 更新，不提交下载后的二进制。

提交前运行：

```sh
./qqmusic/check-repository-rules.sh
./qqmusic/integration/sync.sh --check
./scripts/verify.sh
```

业务修改应测试生产行为，不要用只比较常量或日期的测试保存迁移故事。

升级上游时先在真实工作树解决冲突并验证，再更新 BASE 和生成 patch。仓库治理、上游迁移与业务重构尽量分开提交。

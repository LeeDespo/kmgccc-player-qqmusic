# Replayable QQ Music Patch

本目录是 **当前工作树相对指定 kmgccc_player 上游基线的可重放发行表示**。

它不是第二套源码。目标是让维护者能从干净上游重建并审计当前 QQ Music 集成。

## 真源

- 上游基线：[`BASE`](BASE)，唯一基线真源；
- 实际实现：仓库根的生产工作树；
- 精确 QQ Music 运行组件：[components.lock.json](components.lock.json)；
- `modules/`、`patches/`、`removals.txt`：生成物。

不要手工修改生成物来修功能。先改生产工作树与测试，然后：

```sh
./qqmusic/integration/sync.sh
./qqmusic/integration/sync.sh --check
```

CI 会执行 `--check`，生成表示与工作树漂移应直接失败；同时运行 `verify-replay.sh`，在由 BASE 导出的干净上游树中应用补丁，并逐文件比对生产源码。

## 内容

```text
integration/
├── BASE
├── components.lock.json
├── modules/
├── patches/
├── removals.txt
├── sync.sh
├── apply.sh
├── verify-replay.sh
└── test-cycle.sh
```

## 应用补丁

把 Release 中的 `integration/` 放进干净的 kmgccc_player checkout：

```sh
./qqmusic/integration/apply.sh --repo . --verify
./scripts/bootstrap.sh
./scripts/verify.sh
```

`apply.sh` 负责源码变化；bootstrap 根据 lock 获取第三方运行组件。补丁包不携带隐藏的手工二进制真源。

在 fork 的完整 Git checkout 中运行 `./qqmusic/integration/verify-replay.sh`：从 BASE 导出干净上游树，重放模块、补丁和删除清单，逐字节比对相关生产文件。这项检查无需 Apple 签名；`test-cycle.sh` 则用于本地带签名的构建与启动验证。

## 普通维护

1. 修改根工作树和测试；
2. 完成本地验证；
3. 运行 `sync.sh`；
4. 再运行 `sync.sh --check`；
5. 审查生成的 modules/patches/removals。

## 升级上游

先在真实工作树迁移 QQ Music 集成并解决冲突，跑完整测试后，再用
`sync.sh --base <new-commit>` 重新生成并记录新 BASE。不要直接修补旧 diff 让它“勉强能套”。

`test-cycle.sh` 用于从冻结基线重放、物化组件、构建和运行测试，它验证的是补丁本身的可重现性。

历史迁移过程不属于活文档；Git 历史和 Release notes 已经保存这些信息。

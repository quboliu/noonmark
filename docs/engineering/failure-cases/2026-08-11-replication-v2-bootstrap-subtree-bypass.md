# FAIL-2026-08-11-13：Replication V2 marker 未约束完整子树

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T14:00:00-04:00 至 2026-08-11T14:59:59-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 repository bootstrap 最初只检查根目录 child name
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

一个已有 canonical V2 marker 的 repository 只要根目录仍是 marker 与 `v2`，旧实现便会把它当成合法 V2。`v2` 本身可以是 symlink，或 `objects` 下可以混入未知文件。App 随后可能沿 symlink 写入 repository 边界外的既有目录，或把不属于 exact V2 grammar 的资料与新 publication 混放；这违反开发期 clean cut、零兼容与零写入 fail-closed 要求。

## 时间线

- 初版 bootstrap 已拒绝无 marker 的非空 V1 根，并校验根目录只含 marker／`v2`。
- 双轴审查指出根目录校验没有递归约束 `v2` 子树，也没有以 `lstat` 拒绝 symlink。
- 新增真实临时文件系统 tracer；旧实现对未知 nested object 与 `v2` symlink 都没有抛错，测试稳定判红。
- bootstrap 加入 exact recursive grammar 与每层 file type 检查后，两条 tracer 及全部 bootstrap 用例转绿。

## 复现与证据

`ReplicationRepositoryBootstrapTests/testMarkedRepositoryRejectsUnknownNestedObjectWithoutWriting` 建立有效 marker 后写入 `v2/objects/chunk/legacy.bin`。修复前 `XCTAssertThrowsError` 报告「did not throw」；修复后返回 `legacyRepositoryRequiresManualReset`，原 bytes 不变。

`ReplicationRepositoryBootstrapTests/testMarkedRepositoryRejectsNestedSymlinkWithoutTouchingItsTarget` 把 `v2/objects` 设为指向另一既有目录的 symlink，并在目标中放置 sentinel。修复前 bootstrap 会跟随 symlink并成功返回；修复后 fail-closed，目标 inventory 与 sentinel bytes 完全不变。另一个 dangling symlink tracer 证明目标不存在时也不能被 `fileExists` 误判为路径缺席。

## 排除的假设

- 不是 marker 内容损坏：两条 tracer 都先通过 public `openOrCreate` 生成 canonical marker。
- 不是 Endpoint publication decoder 可补救：bootstrap 已在 Endpoint 建立前错误接受 repository，后续 decoder 无法证明未知资料或 symlink target 的边界安全。
- 不能只检查 root child name：`v2` 名称合法不代表 inode type、后代目录与文件名合法。
- 不能自动清理或修复：用户铁命禁止 App、Agent、脚本或测试删除、覆盖、移动、改名任何 iCloud 资料。

## 根因与破坏机制

初版 `validateKnownRootChildren` 把「根目录没有未知名称」误当成「repository 是 exact V2」。它没有验证 `v2`、`objects` 与 `announcements` 的 inode type，也没有验证 digest、generation、producer、sequence 与 suffix grammar。随后又发现 `fileExists` 会把 dangling symlink 当成不存在。文件系统可透明跟随 symlink，因此下一次 exclusive create 可能离开已批准的 repository boundary。

## 根因修复

`FileReplicationRepositoryBootstrap` 在读取并验证 marker 后递归执行 `validateV2Tree`：

- 每一层使用 `lstat`，只接受实际 directory 或 regular file，任何 symlink／特殊 inode 均拒绝；
- `v2` 只接受 `objects`、`announcements` 与 append-only `staging`；
- object 只接受已知 kind 与 canonical digest JSON；
- announcement 必须匹配 marker generation、canonical producer UUID、20 位正 sequence 与 digest grammar；staging 只接受已知 area 与 canonical UUID `.stage` regular file；
- marker 竞争胜出后的 reopen 走同一验证，拒绝期间不执行写入、修复或清理。

## 验证结果

- 两条 public bootstrap tracer 均由「未抛错」红转绿。
- `ReplicationRepositoryBootstrapTests` 八项全绿，包括 legacy root、canonical marker、并发初始化、marker 中断恢复、损坏 marker、未知 nested object、普通 symlink 与 dangling symlink target。
- `ContentAddressedFileReplicationEndpointTests/testPublicCleanOpenAdoptsExistingCanonicalRepositoryWithoutMutation` 继续通过，合法 V2 repository 可正常重开且 inventory 不变。
- 未启动、读取或修改 production；测试只使用本机临时目录。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行完整 `ReplicationRepositoryBootstrapTests`，并由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 在真实临时文件系统执行 public clean-open，证明未知 nested object 与 `v2` symlink 均零写入 fail-closed；由 `scripts/check` 强制调用。

## 发行与回滚

V2 尚未发行。若回归，只撤回未发行的 bootstrap slice并重建非 production profile；不恢复宽松 validator，不读取 V1 repository，也不得以回滚为由清理任何 iCloud 资料。案例须在修复提交回填后才可标记「已修复」。

## 教训与永久约束

format marker 只声明意图，不证明整棵 repository tree 合法。凡下一步会把外部文件系统当 protocol authority，bootstrap 必须先验证完整 grammar 与 inode boundary；任何未知资料都只能要求用户手工处理，App 永不猜测、迁移或清理。

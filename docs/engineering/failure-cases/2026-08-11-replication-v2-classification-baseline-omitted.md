# FAIL-2026-08-11-11：Replication V2 初始 baseline 遗漏既有分类状态

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T13:00:00-04:00 至 2026-08-11T13:59:59-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 clean-cut baseline 最初直接复用 ordinary `SyncRecordMapper.records(from:)`
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

真实签名隔离 App 成功导入用户资料包后，首次建立 V2 clean-cut baseline 连续失败。诊断只出现 `syncProtocol/403`，用户层对应「部分本机数据无法安全生成同步记录」；资料仍留在本机，但同步无法开始。

## 时间线

- 签名 `e2e` App 经真实 Store import transaction 导入资料包。
- 三次首次同步均以 `syncProtocol/403` 失败。
- 新增 classified clean-cut tracer 后，旧实现稳定复现 `classificationStateRequiresCommitRecords`。
- 引入专用 snapshot builder 后，第二份独立 SQLite store 精确取得来源分类 projection 与 immutable history。
- 同一真实资料包压力路径随后完成增删改、同步与重启闭环。

## 复现与证据

`LocalFirstReplicationTests/testCleanCutBaselineCarriesExistingClassificationStateToASecondStore` 从一份含既有分类资料的 authoritative snapshot 建立空白 V2 repository，再由第二份 store apply baseline。修复前直接抛出 `classificationStateRequiresCommitRecords`；修复后两份 store 的完整 `TaskClassificationState` 相等。

真实签名 App 门禁经产品 import seam 导入 1,013 条任务，并在全新 append-only iCloud round 完成 120 次新增、80 次修改、40 次删除以及重启后的 30／20／10 操作；两阶段均收敛且 outbox 清空。

## 排除的假设

- 资料包损坏已排除：真实 Store import 成功，领域 snapshot 可由 `NoonmarkEngine` 与 SQLite 回读。
- iCloud 或文件 Endpoint 不可写已排除：失败发生在首次 publication 建立前，诊断固定为 mapper code 403。
- 不能删除或忽略 classification state：这会造成可见资料损失，也会破坏 immutable classification audit history。
- 不能读取 V1 journal 补齐：开发期 clean cut 明确禁止把旧 sync state 当 V2 truth。

## 根因与破坏机制

ordinary `SyncRecordMapper.records(from:)` 正确拒绝非空 classification state，因为普通 current-value snapshot 无法自行证明逐次 classification commit history。V2 clean-cut、空 repository reseed、双 watermark recovery 与 fork repair 却把它误当成完整 baseline builder，导致任何已有分类资料的真实 snapshot 都无法生成首份 publication。

## 根因修复

新增 `ReplicationSnapshotRecordBuilder` 作为 V2 完整 snapshot 的唯一边界。它先以空 classification projection 映射普通 current-value entity，再附加 canonical `ClassificationBaselineEnvelope`，同时保存验证过的完整分类 projection 与 immutable history。四条完整 baseline 路径统一使用该 builder；不读取 V1 journal、不跳过资料、不增加兼容层。

## 验证结果

- classified clean-cut tracer 由 `syncProtocol/403` 红转绿，目标 SQLite 分类状态逐项相等。
- 27 项 `LocalFirstReplicationTests` 全绿。
- 真实签名隔离 App 资料导入、高密度增删改、71 次跨领域 mutation、423 次真实 iCloud reconcile 与重启路径全绿。
- 两阶段 `lastSyncedAt`／`lastEffectiveSyncedAt` 均存在，pending outbox 为 0，diagnostic failure 与 mutation rejection 均为 0。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行含既有分类状态的 clean-cut 双 store tracer，并由 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 通过真实签名 `e2e` App 导入调用者明确提供的资料包，在全新 append-only iCloud round 完成增删改、同步与重启；`scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

V2 尚未发行。若回归，只撤回未发行的 V2 slice并重建非 production profile；不得触碰 production，也不得删除、覆盖或迁移任何 iCloud 资料。修复提交已回填，案例标记为「已修复」；production 发行仍受独立门禁阻断。

## 教训与永久约束

「完整 snapshot」不是普通 current-value mapper 的别名。凡领域同时拥有 projection 与 immutable history，baseline builder 必须显式携带两者，并以第二资料库实际重建作为正确性证明。

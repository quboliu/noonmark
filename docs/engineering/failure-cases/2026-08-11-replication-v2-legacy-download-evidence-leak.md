# FAIL-2026-08-11-16：V1 下载证据越过 V2 clean-cut authority

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:45:00-04:00 至 2026-08-11T16:05:17-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 runtime 初版继续复用未分代的 V1 download coordinator tables
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

当前 schema 的资料库若在安装 V2 authority 前遗留 V1 pending download、terminal rejection、conflict、audit 或 cursor metadata，首次 V2 reconcile 会把它们解释成当前 repository 的证据。结果可能是无关记录被重试、旧 terminal 拒绝污染新 immutable history，或新 repository 从旧 cursor 开始读取；这直接违反用户批准的零兼容 clean cut。

## 时间线

- 审查发现 V2 merge 仍经 `SQLiteSyncDownloadCoordinator` 读取 `pendingDownloads()` 与 `terminalRejectionEvidence()`。
- schema migration 只在部分旧版本升级时清理这些表；已经是 current schema、但尚无 V2 authority 的资料库不会触发清理。
- 扩展 clean-cut tracer 后，旧实现的五项「应为空」断言全部判红。
- 清理进入首次 authority 安装的同一 `BEGIN IMMEDIATE` transaction 后，同一测试转绿。

## 复现与证据

`LocalFirstReplicationTests/testCleanCutBaselineIgnoresLegacyJournalAndCapturesOnlyLaterMutations` 在同一真实临时 SQLite 中先写入 V1 journal、pending record、terminal rejection、conflict、audit 与 metadata，再执行 public `openCleanCut`。修复前 pending、terminal、conflict、audit 与 metadata 全部仍在；修复后它们全部为空，而领域 snapshot、设备设置与原 V1 journal bytes 保持不变，后续 V2 mutation 只进入 V2 outbox。

## 排除的假设

- `SyncPendingDownloadRecord.generationID` 不是 repository generation；它属于 record evidence，无法隔离 V1／V2 repository。
- 只在 migration 删除不充分：current schema 的未切换资料库同样可以持有 V1 runtime evidence。
- 不删除整个 journal：批准方案要求旧 V1 journal 失活保留，新 mutation 由 authority trigger 捕获到 V2 outbox；删除它会超出用户已审定边界。

## 根因与破坏机制

clean cut 只安装 V2 publication authority，没有原子撤销 V1 download runtime authority。两代协议因此在 SQLite 内共享一组无 repository generation 的消费证据，V2 actor 能把旧状态当成当前输入。

## 根因修复

`SQLiteReplicationLedger.installCleanCutAuthorityAndBaseline` 在 empty-authority fence 成立后、写入 baseline 前，于同一事务删除 V1 pending dependencies／records、terminal rejections、conflicts、audit 与 sync metadata。领域事实、`sync_device_identity`、`sync_settings` 与失活 V1 journal 不受影响；事务失败则清理与 authority 一起回滚。

## 验证结果

- 原始 tracer：修复前五个症状断言判红，修复后 1 项、0 失败。
- 完整 `LocalFirstReplicationTests`：28 项、0 失败。
- 两份 SQLite 的 V2 baseline、增量、fork repair 与重启路径持续通过。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 clean-cut legacy evidence tracer，并由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 Storage suite，真实 SQLite transaction、V2 runtime 与后续 outbox 行为任一漂移即判红。

## 发行与回滚

当前未发行。若事务门禁失败，停止 V2 cutover；回滚仅撤回未发行代码，不恢复双代消费，也不触碰任何 iCloud 资料。灰度继续限定非 production profile；监控 clean-cut 后 V1 runtime table count 必须为零、V2 authority 与 baseline 必须同时存在。

## 教训与永久约束

新 authority 的建立必须与旧 authority 的撤销原子发生。schema version 相同不等于运行代际相同；任何未带 generation 的消费证据都不得越过 clean-cut transaction。

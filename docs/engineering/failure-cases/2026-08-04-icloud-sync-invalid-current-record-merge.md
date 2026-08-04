# FAIL-2026-08-04-22：iCloud 同步 current-record 合并拒绝循环

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04T07:14:23Z（首次 `operationFailed`）；2026-08-04T08:24:15Z 用户主动导出诊断包 `Noonmark-Diagnostics-20260804-162415.noonmarkdiagnostics`
- 影响版本／构建：0.2.0（5），source commit `0bdf8a7eb8b69a38a37a47ad8a7c910ff87b4085`；属同类事故复发，首次事故发生在 2026-08-01 前后（当时无现场证据，根因未定）
- 引入提交：未知；根因数据状态由哪个变更或用户操作引入尚无证据
- Git author／committer：未知
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

用户日常使用 production App 时反复弹出「同步未完成，本机数据仍安全保留。请检查同步端点、账户、网络和可用磁盘空间后重试。」，诊断编号 `0F923C30`。本机任务数据全部安全，但约 69 分钟内每一次同步都被拒绝，本机变更无法上传 iCloud，形成阻塞在上传队列头部的确定性失败循环。

## 时间线

- 2026-08-04T07:09:31Z：最后一次成功同步，远端 243 条记录，pending 0、applied 0、conflict 0。
- 07:09–07:14 之间：本机产生至少一条待上传变更（诊断 schema 不记录变更内容，精确操作未知）。
- 07:14:23Z：首次同步失败，`syncProtocol:7` + `failureDetail syncProtocol:202`。
- 07:14–08:23：同一 session 内每约 5 分钟重试一次，共 19 次失败，错误码与远端计数（243 records／243 files／533,258 bytes）完全不变。
- 08:24:15Z：用户经 Help 菜单主动导出诊断包。

## 复现与证据

诊断包 4,255 条 typed records 与 8 个 operation capsule 证明：

- 全部 19 次失败的外层错误为 `syncProtocol:7`（`transportOrStorage` 通用分类，`Sources/NoonmarkStorage/SQLiteLocalFirstSyncCoordinator.swift`），底层 `failureDetail` 恒为 `syncProtocol:202`（`SyncRecordTransportError.invalidCurrentRecordMerge`，`Sources/NoonmarkSync/DiagnosticFailureMappings.swift`）。
- 每次失败的阶段链稳定为 `localLoad → transportFetch（成功读取远端 243 条）→ baselinePrepare → upload → transportLockAcquired（0ms）→ transportLockReleased → operationFailed`，失败发生在持锁后的验证／合并环节、任何字节写出之前。
- `persistedSyncFailureLoaded` 记录证明失败被持久化并在后续同步前被加载重试；`SQLiteSyncUploadCoordinator` 每轮重选 `pendingUpload` 与 `failed` 条目，同一批记录被反复物质化、反复被拒。

## 排除的假设

- 排除 iCloud 账户或 Drive 不可用：对应诊断码 102／103 从未出现。
- 排除网络、磁盘、权限等系统层故障：19 次失败无一携带系统错误域，全部稳定为 `syncProtocol:202`。
- 排除 transport lock 竞争或停滞：两次 lock wait 均为 0ms。
- 排除远端仓库损坏或冲突副本：每次 fetch 完整成功，243／243／533,258 三个计数 19 次完全不变。
- 排除 immutable CAS 冲突：对应诊断码 201 未出现。
- 排除合并层误拒合法数据（合并器自身 bug）：暂无证据支持或排除，保留为待验证假设。

## 根因与破坏机制

已定位层：本机 pending journal 物质化出的某条记录无法通过 current-record 校验或与远端同身份记录合法合并，`CurrentSyncRecordMerger` fail-closed 抛出 `invalidCurrentRecordMerge`，整批上传被拒；失败条目被标记 `failed` 后每轮与 `pendingUpload` 一起重选，形成确定性毒记录重试循环，阻塞后续全部上传。

未定位层：具体是哪一个实体、触犯哪一条合并规则（内容／突变时钟、各实体身份冲突、附言条目、复活见证、payload 解码、记录头不一致）。事故发生时 merger 各 catch 点把内部 typed 错误（`CurrentSyncRecordMergeError`、`TaskNoteEntryMergeError`、`SyncRecordMapperError` 等）一律吞掉统一转为 `invalidCurrentRecordMerge(recordID)`，诊断 schema 又因隐私设计不记录 recordID／entityType，两层信息丢失叠加导致本次导出包无法支撑最终归因。

## 根因修复

第一步（本案例当前包含的改动）：诊断增强。新增隐私安全的 `SyncRecordMergeFailureReason`，穿透 merger 与各 transport 的全部吞错点，把被违反的合并规则映射为 `syncProtocol` 域 250-259 稳定子码（250 记录头不一致、251 内容／突变时钟、252-255 各实体身份冲突、256 复活见证、257 附言条目、258 附言创建时钟冲突、259 payload 解码或校验失败；`unknown` 保持 202 兜底语义）。子码只标识规则，不携带记录身份、实体内容或时间戳。

根本修复：待下次复发时由子码直接定位规则后再行修复，修复 commit 必须回填本案例。

## 验证结果

- `NoonmarkSyncTests` 308 项、`NoonmarkStorageTests` 242 项、`NoonmarkDiagnosticsTests` 66 项全部通过。
- 既有 7 处 fail-closed 测试断言升级为同时校验 reason；新增 reason→code 稳定映射、隐私哨兵与六条穿透链测试（250 记录头、252 周期系列身份、254 定义身份、255 轨迹身份、256 见证解码、259 领域完整性），以及协调器 terminal 事件携带 251 子码的端到端断言。
- 独立 review 后补强：复活见证解码／校验失败统一归为 256（不再落回 202 或错报 259），`NoonmarkError.invalidInput` 归为 259，CloudKit 事件回调保留 typed sync 错误（不再二次包装为 309），降级为逐条冲突的 canonicalization 路径显式记录「有意丢弃 reason」的设计注释。
- 新增 fast 契约 `scripts/test-sync-merge-failure-reason-contract`（26 项断言），任何吞错点退回到无 reason 的 `invalidCurrentRecordMerge` 即判红。
- 症状级复现（production 毒记录）尚未由红转绿，根本修复未完成，案例保持「处理中」。

## 永久门禁

- Fast：`scripts/test-sync-merge-failure-reason-contract`，由 `scripts/check` 强制执行；从 merger 内部 typed 错误出发，覆盖 250-259 各规则经 transport error 到 `DiagnosticFailure` 子码的穿透链、协调器 terminal 事件的子码落地与隐私哨兵。
- Symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制执行；证明真实 App 的「同步失败 → transport lock wait → 修改拒绝 → 重启 → Help 菜单导出」诊断采集闭环完整。该门禁覆盖事故采集能力本身，不制造 current-record 合并拒绝；250-259 子码的端到端断言由 fast 层承担。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

本案例当前只包含诊断增强，不改变同步接受／拒绝语义，合并器 fail-closed 行为保持不变。用户侧恢复路径（保留 canonical JSON 导出、删除自己的 production 同步目录、重装并导入）仍由用户本人明确执行；开发／测试不得读取、删除或迁移 production 资料。若诊断增强自身引入回归，整体回滚该 commit 即可恢复到仅 202 的旧行为。

## 教训与永久约束

- fail-closed 边界的错误分类必须在抛出点保留 typed 原因；统一吞错会把可诊断故障变成不可诊断故障。
- 隐私脱敏不等于丢弃可分类信息：规则级枚举码可以在不记录身份与内容的前提下保留归因能力。
- 重试循环必须由持久化失败状态显式驱动并可被证据串起，否则同一毒记录会在后台无限放大用户可见症状。

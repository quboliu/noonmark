# FAIL-2026-08-06-01：子任务可变字段被 merger 当作不可变身份，同步毒记录循环

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-06T01:52:48Z（首次 `operationFailed`）；2026-08-06T05:34:02Z 用户主动导出诊断包 `Noonmark-Diagnostics-20260806-133402.noonmarkdiagnostics`
- 影响版本／构建：0.2.2（8），source commit `37d627007ecbc9efc96c7909d9d6e7a5b9cb3d36`；属 FAIL-2026-08-04-22 同类事故第二次复发
- 引入提交：`cd7f29f935e0d931139d6df9d130530b7537976d` fix(task): Unify task draft and transition semantics
- Git author／committer：quboliu <38942505+quboliu@users.noreply.github.com>（author 与 committer 相同）
- 实际修改者：未知（仓库证据只能确认 Git identity，无法确认实际操作者）
- 修复提交：`4d2530ae0369454f9e01a537a516e50b9b7f9dbe` fix(sync): merge mutable subtask fields as content instead of identity

## 用户症状与影响

用户日常使用 production App 时反复弹出「同步未完成，本机数据仍安全保留。请检查同步端点、账户、网络和可用磁盘空间后重试。」，诊断编号 `18A651A2`。本机任务数据全部安全，但 2026-08-06T01:52:48Z 起每一次同步都被拒绝（诊断包可见 43 次，约 3 小时 41 分），本机变更无法上传 iCloud，形成阻塞在上传队列头部的确定性毒记录循环。这是 FAIL-2026-08-04-22 之后同类事故的第二次复发；上一次因诊断缺少规则子码无法归因，本次由新落地的 250-259 子码直接读出被违反的合并规则。

## 时间线

- 2026-08-06T00:25:49Z：0.2.2（8）新 session 启动，同步连续成功 11 次。
- 01:21–01:37Z：用户集中编辑（远端记录计数 390→417→408），同步全部成功。
- 01:47:34Z：最后一次成功同步，远端 408 条记录，pending 0。
- 01:47–01:52Z：本机产生至少一条待上传变更（诊断 schema 不记录变更内容，精确操作未知）。
- 01:52:48Z：首次同步失败，`syncProtocol:7` + `failureDetail syncProtocol:251`。
- 01:52–05:33Z：每约 5 分钟重试一次，共 43 次失败，错误码与阶段链完全稳定。
- 05:34:02Z：用户经 Help 菜单主动导出诊断包。

## 复现与证据

诊断包 3,934 条 typed records 与 8 个 operation capsule 证明：

- 全部 43 次失败外层错误为 `syncProtocol:7`，底层 `failureDetail` 恒为 `syncProtocol:251`（`SyncRecordTransportError.invalidCurrentRecordMerge` + reason `.invalidContentClock`，`Sources/NoonmarkSync/DiagnosticFailureMappings.swift:34`）。
- 每次失败的阶段链稳定为 `localLoad → transportFetch（成功）→ baselinePrepare → upload → transportLockAcquired → transportLockReleased → operationFailed`，失败发生在上传 preflight 的验证／合并环节，任何字节写出之前，无 `downloadMerge` 阶段——毒记录在本机 pending 侧。
- 修复前复现（红）：`CurrentSyncRecordMergerTests.testTransportBatchMergesSubtaskTitleEditAsContent` 以真实引擎「建任务 → 排期 → 加子任务 → 上传 → `updateSubtaskTitle` 改名 → 再上传 preflight」确定性抛出 `invalidCurrentRecordMerge(reason: invalidContentClock)`；`SQLiteLocalFirstSyncCoordinatorTests.testSubtaskRenameSurvivesUploadAfterInitialSync` 经真实 SQLite + 协调器 + transport 全链路抛出同一错误（临时回退修复验证，抛错点 `SQLiteLocalFirstSyncCoordinator.swift:470`）。
- 修复后（绿）：两个复现测试通过，远端记录收敛为新标题，journal 无 pending／failed 残留，后续例行同步不再失败。

## 排除的假设

- 排除 iCloud 账户或 Drive 不可用：诊断码 102／103 未出现，transportFetch 每轮完整成功。
- 排除网络、磁盘、权限等系统层故障：43 次失败无一携带系统错误域，全部稳定为 `syncProtocol:251`。
- 排除 transport lock 竞争或停滞：lock wait 均为 0ms。
- 排除远端仓库损坏：远端计数稳定，失败发生在本机 pending 的上传 preflight，无 downloadMerge。
- 排除飞光（IdeaEntry）tombstone／restore／置顶路径：`IdeaEntry` 领域操作由构造保证 `deletedAt == updatedAt` 等不变量（`Sources/NoonmarkCore/Models.swift:796-859`）。
- 排除附言 note entries：相关失败映射为 257／258 子码，非 251。
- 排除自动分组／标签 job：不写任务定义内容，分类 commit 走 immutable 记录，模板分类写回推进 `updatedAt`。
- 排除任务定义／日轨迹自包含非法：每次 save 全量 `validateIntegrity`，本机无法落盘自包含非法实体。
- 排除多设备同时钟同内容冲突（:826／:948 的 sameVersion 分支）：单设备无「改内容不推时钟」的产生机制，用户无证据表明第二设备参与。
- 精确的触发操作（子任务改名、撤回延期、重复计划模板传播三者中的哪一个）不可考：诊断 schema 按隐私设计不记录操作内容与记录身份，写「未知」。三条路径撞同一个 guard，修复全覆盖。

## 根因与破坏机制

`CurrentSyncRecordMerger.mergeSubtask`（`Sources/NoonmarkSync/CurrentSyncRecordMerger.swift`）把 `lineageID / traceID / title / position / carriedFromSubtaskID / createdAt` 六个字段全部当作不可变身份，任一等不起即抛 `invalidContentClock`。该 guard 由 `3d5cc9e`（2026-07-18）引入时尚无问题；`cd7f29f`（2026-07-22）引入 `updateSubtaskTitle` 子任务改名能力时没有同步更新 merger 不变量，merger 假设从此陈旧。引擎侧还有两条同类路径：`withdrawDeferral` 改写 `title/position/traceID/carriedFromSubtaskID`，重复计划模板传播 `replaceTaskCycleTraceSubtasks` 改写已物质化子任务标题。

破坏机制：子任务旧版本记录上传过 iCloud 后，用户经任一上述路径改写这些字段，下一轮上传 preflight 拿本机 pending 记录与远端旧版比较，guard 必抛 251；失败条目被标记 `failed` 后每轮与 `pendingUpload` 一起重选，零字节写出、结果不变，形成确定性毒记录循环并阻塞后续全部上传。

## 根因修复

`mergeSubtask` 的身份 guard 收窄为真正不可变的 `lineageID + createdAt`；`title / position / traceID / carriedFromSubtaskID` 恢复为内容语义，随 LWW winner 合并（`isSanctionedCancelledSubtaskUndo` 豁免与 cancelledDraft 优先逻辑保持不变）。本修复同时回填 FAIL-2026-08-04-22 预留的「根本修复」：250-259 子码按设计在复发时直接读出了被违反的规则（251），使根因从「不可归因」变为一次审计即可定位。

## 验证结果

- 修复前红：`testTransportBatchMergesSubtaskTitleEditAsContent`（merger 层）与 `testSubtaskRenameSurvivesUploadAfterInitialSync`（协调器全链路层）均确定性抛出 production 同款 `invalidCurrentRecordMerge(reason: invalidContentClock)`。
- 修复后绿：上述两测试通过；新增 `testTransportBatchMergesSubtaskCarryRewriteAsContent`（撤回延期四字段改写双向 LWW 收敛）与 `testTransportBatchRejectsSubtaskLineageOrCreationCollision`（`lineageID`／`createdAt` 身份冲突仍 fail-closed）通过。
- 回归：`NoonmarkSyncTests` 311 项、`NoonmarkStorageTests` 253 项、`NoonmarkCoreTests` 286 项全部通过；`make check` 通过。

## 永久门禁

- Fast：`scripts/test-unit`，由 `scripts/check` 强制执行；`CurrentSyncRecordMergerTests` 固定子任务改名／撤回改写按 LWW 合并、lineage／createdAt 身份冲突继续 fail-closed，guard 重新把可变字段身份化即判红。
- Symptom：`scripts/test-integration`，由 `scripts/check` 强制执行；`SQLiteLocalFirstSyncCoordinatorTests.testSubtaskRenameSurvivesUploadAfterInitialSync` 以真实 SQLite、协调器与 transport 走「首版上传 → 改名 → 再上传 → 远端收敛 → journal 清空 → 例行同步恢复」完整用户路径，修复前确定性判红。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

修复不改变接受／拒绝语义的边界，只把合法可变字段从错误的身份约束中释放；`lineageID`／`createdAt` 身份冲突与各自包含校验保持 fail-closed。用户侧恢复路径：安装修复构建后第一轮同步即按 LWW 上传被阻塞的改名记录与队列积压变更，不需要导出数据包、删除同步目录或重装。若修复引入回归，整体回滚修复 commit 即可恢复到旧 guard（同时恢复毒记录风险）。

## 教训与永久约束

- merger 的「不可变身份」白名单必须与领域写能力同源维护：新增任何实体字段的合法改写路径时，必须同 commit 审查对应合并 guard，否则 fail-closed 会把合法用户操作变成确定性同步阻塞。
- 领域实体字段默认应视为内容（LWW），只有明确不可变的字段才允许进入身份 guard；guard 里每加一个字段都需要写出「为什么没有任何领域路径能合法改它」的论证。
- 250-259 规则子码按设计完成了归因使命：同类事故第二次复发即定位到具体合并规则，验证了「隐私脱敏不等于丢弃可分类信息」的诊断设计。

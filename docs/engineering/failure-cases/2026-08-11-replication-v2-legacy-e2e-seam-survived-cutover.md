# FAIL-2026-08-11-22：V2 cutover 后遗留 V1 E2E seam

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-11T17:30:00-04:00 至 2026-08-11T17:42:00-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 App cutover 初版没有同步替换 Preferences 与诊断闭环的 V1 automation
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

正式 App 已经切到 Replication V2，但 Preferences Clock 与诊断故障闭环仍读取 `SQLiteLocalFirstSyncCoordinator` 的 V1 status metadata、V1 repository lock 及 V1 persisted-failure race seam。结果是门禁继续证明已经不可达的状态机，无法证明用户真正关心的 V2 行为：远端等待时本机修改可用、真实本机持久化失败仍会拒绝 exact mutation 并留下关联证据、关闭／退出会先完成 durable fence 与 endpoint join、重启不重放旧 warning、重新启用后可收敛。

## 时间线

- 最终 `make check` 在 Preferences 静态 contract 暴露 `PersistedSyncFailureRestoreE2EGate` 仍被要求。
- 全仓 search 进一步确认 `PreferencesClockE2EAutomation` 与 `DiagnosticEvidenceClosureE2EAutomation` 仍依赖 V1 coordinator／status；旧四进程 restore-race 脚本也仍在聚合入口。
- 移除 V1 seam 并换成 V2 Endpoint wrapper 后，真实签名 App 首轮运行进一步暴露 warning 提交与 disabled state subscription 的真实交错；这些问题在旧 V1 automation 下不可观察。
- V2 三进程 Preferences 与诊断闭环最终分别转绿。
- 双轴发布审查随后用外部 SQLite `BEGIN IMMEDIATE` 证明 `shutdown()` 的 durable generation fence 可以先失败；App 旧调用点以 `try?` 吞掉错误后仍释放 Runtime，形成未 join endpoint 的 zombie 风险。同一审查也发现诊断 V2 改写只保留“正常 mutation 成功”，误删了强制要求的真实 mutation rejection 证据。

## 复现与证据

- `scripts/test-preferences-checkbox-interaction-target-contract` 在修复前要求 `PersistedSyncFailureRestoreE2EGate`；静态 search 能定位 production App／E2E 中的 V1 coordinator、status 及 restore-race 参数。
- 旧 Preferences automation 直接解码 `localFirst.sync.lastStatus`，以 repository `flock` 模拟同步阻塞，并要求同步期间 task mutation 被拒绝；这与 V2「远端等待不占 mutation gate」的架构不变量相反。
- 旧诊断 automation 从 V1 status 恢复 correlation；第一次 V2 clean cut 又把 rejection 整体删除。发布审查新增组合 oracle：同一个 stalled V2 operation 下，普通本机 mutation 必须成功；随后由真实 SQLite persistence failure 拒绝的 exact mutation 必须不进入 engine，并以同一 operation／incident 跨异常终止恢复。
- shutdown 红灯以外部 SQLite writer 阻断 generation fence：旧实现第一次 `shutdown()` 抛错，App 却立即取消状态订阅并把 Runtime 设为 nil；endpoint cancel／join 未发生。释放 writer 后已没有同一 owner 可以重试收束 task tree。
- 所有复现只使用 `e2e` profile、隔离 SQLite 与 Local Folder；没有启动或读取 production，也没有触碰 iCloud。

## 排除的假设

- 不是 production V2 Runtime 仍调用 V1 writer：production cutover 搜索与既有 V2压力门禁已证明 writer authority 已切换；遗漏集中在测试 automation 与 Store 的测试专用 seam。
- 不是仅修改静态 contract 即可：真实 App 必须通过物理 checkbox、跨进程重启和持久化状态对账，才能证明 V2 生命周期。
- 不保留 V1 automation 作兼容：项目处于开发期 clean cut，用户已经明确不兼容 V1 路径或资料。

## 根因与破坏机制

cutover 的 reachability audit 主要检查 production writer／transport，没有把 E2E automation、测试专用 Store property 和聚合脚本视作同一架构 surface。V1 测试代码仍可编译，因此没有产生普通 build error；它反而持续输出与 V2 无关的“通过”，形成 false confidence，并阻止测试捕获 V2 cancel + join、warning suppression 与 mutation availability 的真实回归。

## 根因修复

- 删除 `PersistedSyncFailureRestoreE2EGate`、V1 status reader、V1 repository-lock automation 与第四个 restore-race process。
- 新增仅对 exact `app.noonmark.mac.e2e` 加专用参数才可安装的 `ReplicationV2LifecycleE2EEndpoint`；它包裹真实 `ReplicationEndpoint`，只受控注入 read failure／blocked read／cancel join，不另造同步状态机。
- Preferences 使用三个真实 App process 验证建立 baseline、同步收敛、故障、远端等待期间正常 task mutation、物理关闭、stopping／join、durable disabled、重启 suppression、重新启用及 retry 收敛。
- 诊断闭环改为 V2 failed operation capsule、`transportPrepare` await、mutation committed、SIGKILL、restart interrupted capsule 与 Help UI 导出。
- 诊断闭环在 endpoint wait 中先提交普通任务，再注入一次真实 persistence failure；被拒绝任务不进入 engine，`mutationRejected` 绑定当前 V2 sync operation，incident 同时成为 abnormal termination capsule 与 `previousSessionInterrupted` 的跨重启关联键。
- Runtime retirement 改为可重试的两阶段协议：先标记 `retirementInProgress` 并拒绝新 command，只有 durable generation fence、worker cancel／await 与 endpoint join 全部成功后才永久关闭 command surface。失败时清除 retirement 标志但保留同一 Runtime owner；App 只有在成功后才能取消订阅并释放 Runtime，import 与 termination 也必须 fail-closed 等待该结果。
- fast gate fail-closed 禁止 App 与 `scripts/test-e2e` 再出现 V1 coordinator、status 或 restore-race seam。

## 验证结果

- `scripts/test-preferences-checkbox-interaction-target-contract` 已转绿。
- `LocalFirstReplicationTests.testDisableJoinsBlockedWorkerAndRestartsAsDurablyDisabled` 已通过，覆盖 running → stopping → stoppingDelayed → disabled、join 完成及重启首态 disabled。
- `LocalFirstReplicationTests.testFailedShutdownFenceCanBeRetriedAndStillJoinsEndpoint` 已通过：首个 fence 在真实 SQLite writer lock 下失败且 endpoint 未 cancel／join；释放 lock 后同一 Runtime retry 成功 join，下一代 Runtime 保持 enabled policy。
- 真实签名 Preferences 路径得到 SQLite probe `1 1 0 4 1 1 0`：V2 preference facts 精确、worker disabled、incident 清除、重启 suppression 与重新启用收敛全部成立。
- 诊断 fast gate 已强制组合 oracle：V2 endpoint wait → ordinary mutation committed → injected SQLite persistence failure rejects exact mutation → operation／incident correlation → restart evidence。真实签名闭环运行 `20260812T035748Z-64356` 已按该组合 oracle 通过。
- 完整 `make check` 运行 `20260812T041033Z-39844` 以 `suite_exit_status=0` 完成，且运行前后 worktree tree OID 一致。修复提交已回填；实际私有 DMG release gate 尚待本任务后续完成，因此案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-preferences-checkbox-interaction-target-contract` 禁止 V1 automation 重返 App／E2E，并固定 V2 Endpoint seam、物理 checkbox、disabled warning suppression 与 restart recovery；`scripts/test-replication-v2-recovery-contract` 固定 shutdown fence 失败后 Runtime 不释放且可以 retry join；`scripts/test-e2e-evidence-contract` 固定诊断 normal-commit 与 exact-rejection 组合 oracle。三者均由 `scripts/check` 强制调用。
- symptom：`scripts/test-e2e` 以真实签名 App 分别执行 Preferences 与诊断三进程 V2 用户路径；由 `scripts/test-all` 强制调用。
- release：`scripts/verify-development-validation-evidence` 在私有 DMG 前消费同 source／run 的完整 E2E 生命周期证据；由 `scripts/release-private-dmg` 强制调用。

## 发行与回滚

风险等级为 P：涉及同步并发、SQLite durable state、启动、退出与诊断。完整门禁全绿前不发行。若 V2 automation 或 product fix 回归，整体撤回本轮未发行 lifecycle slice并重建非 production profile；不恢复 V1 seam、不启动 production、不删除任何 iCloud 对象。灰度固定为单元阻塞 Endpoint → Local Folder 签名 `e2e` 三进程 → 完整本地发行证据。监控只记录 policy、worker stage、join、pending、typed incident、warning 是否存在与耗时分桶。

## 教训与永久约束

架构 cutover 的删除清单必须覆盖 production、测试 seam、automation、脚本和诊断 oracle。仍能编译的旧测试比 build error 更危险；它可能证明一个已经不可达的系统，而不是保护当前产品。

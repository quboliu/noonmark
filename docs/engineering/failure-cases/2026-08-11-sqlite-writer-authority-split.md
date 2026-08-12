# FAIL-2026-08-11-12：同步与正常修改分裂 SQLite writer authority

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T14:00:00-04:00 至 2026-08-11T14:59:59-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；既有 `SQLiteStoreRuntime` 只维持 WAL anchor，没有完整持有同进程单写者 authority
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

真实签名 App 在同步大型 baseline 的同时执行正常任务新增时，任一方可能收到 SQLite code 5。运行中先观察到两次 `localFirstSync` 在 `transportPrepare` 失败；扩大取证后又捕获正常任务写入直接抛出 `EnginePersistenceCommitError`。这与用户此前「同步时修改被拒绝／同步未完成」属于同一破坏机制。

## 时间线

- 首轮真实资料压力测试在同步与第一条任务写入重叠时出现一次 `SQLITE_BUSY`，后续 retry 虽收敛，但诊断门禁正确判红。
- 48 路并发门禁显示 13 条正常写入失败，全部为 SQLite code 5；失败集中于未纳入显式 transaction 的 autocommit metadata writer。
- 补齐部分 transaction lock 后，签名 App 仍稳定出现两次 `sqlite/5/transportPrepare`。
- 结构化取证依次定位为 `execute → BEGIN IMMEDIATE → replication ledger`；另一次调度顺序中则由 engine persistence 先失败。
- path-scoped strong lock 仍未关闭症状，证明 SQLite 正确性不能依赖 repository／runtime／URL identity 恰好重合。
- writer authority 提升为 NoonmarkStorage process-wide coordinator 后，同一压力路径及重启轮全绿。

## 复现与证据

`SQLiteStoreRuntimeTests/testAllRepositoriesShareOneProcessWriterLane` 同时启动 96 条 engine、replication ledger、sync metadata 的读写操作。旧实现稳定产生 SQLite code 5；补齐 autocommit 与完整 transaction lease 后连续通过。

真实签名 App symptom gate 在真实 iCloud 同步运行态内通过正常 `NoonmarkStore.commitEngineMutation` 新增第一条任务，随后持续执行 371 次任务及跨领域 mutation 与 423 次 reconcile。旧实现分别捕获 replication ledger `BEGIN IMMEDIATE` 失败及 engine persistence 失败；最终实现两阶段 diagnostic failure 与 mutation rejection 均为 0。

## 排除的假设

- 不是 iCloud 网络或文件 Endpoint：复现固定使用本机隔离 content-addressed repository，失败发生在 `transportPrepare` 的 SQLite transaction 起点。
- 不是资料 payload：同一资料在无竞争时可保存、同步及重启回读。
- 不是可接受的瞬态：任何一方失败都会直接形成用户同步失败或修改失败，后续 retry 收敛不能抹掉已经发生的拒绝。
- busy timeout 不构成修复：它只改变失败时机，不能建立唯一 writer authority。
- runtime weak lifetime与 canonical path 单独不足：强持有 lease及 path-scoped lock 后，真实 App 仍可复现。

## 根因与破坏机制

SQLite WAL 支持并发 reader，但同一时刻仍只有一个 writer。既有 repository 各自打开 connection；`SQLiteStoreRuntime` 只维护 WAL anchor，没有把完整写事务、autocommit writer 与 runtime identity 漂移统一收口。V2 ledger 与正常 engine mutation 因而能同时执行 `BEGIN IMMEDIATE`，调度顺序决定谁向用户暴露 code 5。

## 根因修复

`SQLiteStoreRuntime` 现在提供 NoonmarkStorage process-wide writer coordinator。Engine、Sync Repository、Replication Ledger、Automatic Classification、schema prepare、资料导入 replacement 与 termination checkpoint 的所有写边界均持有 lease 至 COMMIT／ROLLBACK 或单条 autocommit 完成；lease 强持有 runtime，避免 transaction 中途丢失 WAL owner。协调是结构性互斥，不使用 retry、sleep 或 busy-timeout 作为成功条件。

## 验证结果

- 96 路跨 repository 读写门禁全绿；此前 code 5 计数稳定非零。
- 真实签名 App 首轮：导入 1,013 条任务，120 新增、80 修改、40 删除、71 次跨领域 mutation、367 次真实 iCloud reconcile，pending outbox 0，confirmed outbox 542。
- 重启轮：30 新增、20 修改、10 删除、56 次真实 iCloud reconcile，pending outbox 0，confirmed outbox 652。
- 两轮 convergence 均为 `converged`，最近同步与最近有效同步均存在，diagnostic sync failure 0，mutation rejection 0。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 `SQLiteStoreRuntimeTests`，并由 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 固定真实签名 App 的同步中正常写入、高密度增删改、重启、durable ledger 与 typed diagnostics 对账；`scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

V2 尚未发行。若回归，只撤回未发行 slice并重建非 production profile；不得启动、读取或修改 production。进程级 coordinator 不涉及 iCloud object；任何回滚均不得删除或覆盖 iCloud 资料。修复提交已回填，案例标记为「已修复」；production 发行仍受独立门禁阻断。

## 教训与永久约束

SQLite 单写者是数据库级线性化 invariant，不能由调用方运气、runtime weak registry、URL identity 或超时重试代替。真实用户路径必须同时断言「同步成功」与「同期修改从未失败」，后续成功不能覆盖先前失败证据。

# 要求 validated sync base 与原子 current components

**Status**: Accepted

同步 merge 会为 raw snapshot 建立 identity index，并把多个 current records 投影成新的任务拓扑。若 base snapshot 含重复 identity，index initializer 可能 trap；若相关 current records 逐条发布，中间状态又可能暂时形成双 current definition、双 active trace、断裂 continuation 或错误 subtask lineage。同步边界因此改为先证明完整 base，再按结构组件 staging，最后只发布通过全 snapshot integrity 的结果。

## Decision

- 对外 `SyncRecordMerger.merge` 只接受 `ValidatedSyncSnapshot`。wrapper 构造时执行完整 `NoonmarkSnapshot.validateIntegrity()`，并把 raw snapshot 保持为模块内私有值；Storage fixed-point 的每一轮都必须重新包装上一轮结果，不能绕回未经验证的 index 路径。
- base validation 在任何 `Dictionary(uniqueKeysWithValues:)` 前拒绝重复 Day date／identity、chain／definition／trace／subtask identity、悬空 parent、非 finite 或倒退 clock、非法 terminal facts、planned subtask、classification 以及 definition／trace／subtask topology。
- same-ID 输入先按 exact record evidence canonicalize。current records 以 snapshot-aware merger 合并；immutable record 同 identity 的不同 exact evidence 永远是 terminal collision，不能按到达顺序选赢家、覆盖文件或改写既有 terminal anchor。
- Day、chain、definition、trace 与 subtask current records 按共享 identity、parent、successor、continuation、priority、lineage 和 cancellation token 连成 structural components。每个 component 在复制的 merge context 中整体应用并重试本阶段 waiting；只有完整 snapshot validation 通过才 commit，否则整组 rollback，再把可修复的缺依赖记录列为 waiting，把不可修复碰撞列为 deterministic conflict。
- `TaskDefinitionValidator` 与 `TrajectoryTopologyValidator` 是 Core snapshot 和 Sync projection 共用的唯一拓扑规则。缺 successor／parent／continuation 可以等待对应 exact dependency；双 current definition、cycle、重复 active trace／priority／lineage／cancellation identity 等结构冲突必须 fail-closed。
- 缺 Day 时必须等待 `.day(LocalDate)`，不得随机合成 Day identity；所有 waiting 都保存完整 exact `SyncRecord`、reactivation witnesses 和具体 dependency。`currentSnapshotIntegrity` 只表达尚缺结构事实的临时等待，不得掩盖已证明不可修复的 payload。
- Storage 在一个 `BEGIN IMMEDIATE` 事务中原子保存 merged snapshot、conflict／terminal ledger、waiting、audit 和 metadata。pending row 使用 `generationID`、exact record、exact dependencies、first／last attempt bit patterns 与 attempt count 组成完整 observed token；更新、保留或删除都用该 token 做 CAS，以防并发更新丢失和删除后重建的 ABA。
- audit 必须按 exact incoming variant 归因；同 record ID 的 applied、waiting 与 conflict variants 不得互相冒领结果。fixed-point 只在本轮确实 applied 时继续，未知或 terminal dependency 不得无限重试。

## Considered Options

- 在 merger 内部顺手调用 validation：公开签名仍允许未来调用者先从 raw snapshot 建 index，边界不可证明。
- current records 逐条 apply 后最终验证：会丢失原子组件中本来可共同成立的合法更新，也可能留下部分 applied／waiting 归因。
- pending 只以 record ID 删除：并发替换或 ABA 后会删除并非本轮观察到的记录。
- 缺 parent 时生成 placeholder：会制造跨设备不一致的随机 identity，并把缺依赖伪装成合法事实。

## Consequences

- malformed base 以领域错误停止，不再以 Swift precondition trap 终止进程；合法相关更新可以原子收敛，输入排列不改变结果。
- waiting、terminal rejection 和 immutable collision 成为 durable 协议状态，而非一次 merge 的临时数组；磁盘占用增加是可恢复与可审计语义的成本。
- 新增 current entity 或拓扑关系时，必须同时声明 component token、dependency、shared validator、canonical clock 与 durable SQLite encoding。

## Risk And Rollout

- 风险等级：P。主要风险是错误把永久冲突留在 waiting、component token 漏掉关系导致部分提交、CAS token 不完整导致并发数据丢失，以及 validator 在 Core 与 Sync 漂移。
- 灰度：先通过 malformed base、same-ID valid／invalid、immutable collision、definition／trajectory topology、component permutation/property、durable waiting／CAS／audit 和 SQLite restart 专项；当前专项结果不替代本轮最终完整 E2E、`make check` 与 DMG 安装验收。
- 监控：对账 applied／waiting／conflict／terminal 数量、pending generation 与 attempt count、exact audit origin、fixed-point 轮数和重启后 snapshot；任何 trap、随机 Day identity、同一 exact record 多种 outcome、pending token changed-after-read 或 terminal record 再次进入 waiting 都是阻断信号。
- 回滚：必须整体 revert validated wrapper、component staging、shared validators、terminal ledger 与 pending CAS schema，并执行 clean cut。不得只恢复 raw merge 入口、放宽 validator，或保留新 durable rows 却用旧 record-ID-only 删除逻辑读取。

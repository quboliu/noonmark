# FAIL-2026-08-11-06：Replication V2 producer fork 被降格为通用 Runtime 故障

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:58:07-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初的 file endpoint fork tracer 与 Runtime Interface 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

问题尚未进入发行或 production。file endpoint 已能保留同一 producer／sequence 的两个 immutable 分支并拒绝任选 winner，但 Runtime read 路径只收到 adapter exception，最终持久化 `runtimeFailure` 并向 App 抛错。若直接 cutover，用户无法区分可操作的资料分叉与普通程序故障，也无法进入后续 repair 流程。

## 时间线

- 既有 endpoint 测试已证明 fork 双分支文件均被保留，publication 不会覆盖。
- 2026-08-11T09:58:07-04:00：新增公开 Runtime tracer，因 `LocalFirstReplicationIncident` 没有 `producerForkDetected` 而判红。
- 2026-08-11T09:58:30-04:00：共享 read state 与 Runtime incident 投影完成，同一 tracer 转绿。

## 复现与证据

测试向真实临时 content-addressed repository 发布 producer A sequence 1，再尝试发布同 identity、不同 digest 的另一分支。endpoint 按设计保留两个 announcement 并拒绝第二次 publish。producer B 通过公开 `LocalFirstReplication.send(_:)` 读取该 repository；旧 Interface 只能抛 `FileReplicationEndpointError.producerFork`，没有协议级 incident。

## 排除的假设

- 不是资料覆盖：两个 fork announcement 都保留，第一分支 bytes 未改变。
- 不是合法乱序 confirmation：冲突发生在相同 producer／sequence 的不同 immutable digest。
- 不是领域 merge 冲突：fork 在 publication chain validation 阶段已成立，任何 branch records 都尚未 apply。

## 根因与破坏机制

fork detection 只存在于具体 file adapter error，`ReplicationEndpoint` 的 read result 与 `LocalFirstReplicationIncident` 都没有相同的 typed 语义。Deep Module 因而无法把 endpoint 已知的协议事实传给 App，通用 catch 又错误地把它归类为 Runtime 故障。

## 根因修复

共享 `ReplicationReadState` 新增携带 validated evidence 的 `blockedProducerFork`。file endpoint 完整打开 branch graph 的 announcement、seal、root 与 chunk，形成与发现顺序无关的 deterministic resolution ID；不把任一 branch 混入普通 linear page。Runtime 先把 exact evidence 与 `branchesValidated` 写入 SQLite durable resolution ledger，再统一投影为 `producerForkDetected`，不要求 App 识别具体 adapter error。存在领域冲突时保持 `convergence=blocked` 且不写成功时间；无冲突时 state stream 仍先公开 actionable incident，再由独立 repair transaction 自动闭合。

## 验证结果

- 原始 Runtime fork tracer：1 项、0 失败。
- fork evidence 双分支保留的 endpoint 测试继续通过。
- 正反 branch 发现顺序形成相同 resolution ID；`branchesValidated` 跨 SQLite 重启恢复且重复记录幂等。
- state stream 明确出现 `producerForkDetected`，不会降格为 `runtimeFailure`。
- 领域冲突路径保持 blocked，两个成功时间均为空；无冲突路径只在 exact baseline confirmed 与空增量复核后清除 incident。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 fork detection 到 Runtime incident 的公开 tracer，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，由 `scripts/check` 强制调用；fork 若被任选、抛成通用故障或污染成功时间即判红。

## 发行与回滚

当前没有 production cutover。若 fork incident 门禁失败，停止 repair、cutover 与发行工作并回滚未发行 Interface 变更；不得删除任一分支、选择较新时间、重写 producer identity 或隐藏 incident。灰度必须在 deterministic repair 与 N-device convergence 完成后才可前进。

## 教训与永久约束

adapter 已检测出的协议事件必须在 Deep Module Interface 保持同等语义，不能通过通用异常丢失。fork detection 只是 fail-closed 的入口；没有 durable resolution state 与双分支 apply 之前，不得宣称 repair 已完成。

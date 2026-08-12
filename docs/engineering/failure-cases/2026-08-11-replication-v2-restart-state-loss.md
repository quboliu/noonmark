# FAIL-2026-08-11-04：Replication V2 重启时以默认状态覆盖 durable pending truth

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:49:56-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初的 `LocalFirstReplication` tracer 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

问题尚未进入发行或 production。若原实现直接 cutover，publication 已写入 endpoint、但 confirmation 尚未落盘时发生退出或崩溃，重启后的公开状态会显示 `pending=0` 且丢失上次 `runtimeFailure`。资料仍在 ledger，但 UI 和 Runtime 初始投影对 durable truth 撒谎，可能让用户误判没有待恢复工作。

## 时间线

- 初始 tracer 证明正常 publication、confirmation、第二资料库 apply 与双端重启可收敛。
- 2026-08-11T09:49:56-04:00：新增 publish 后、observe 前中断 tracer；重启状态稳定返回 `incident=nil`、`pending=0`，原始症状判红。
- 修复后，同一测试重启即返回 `runtimeFailure`、`pending=1`，下一轮幂等确认并让目标资料库只 apply 一次。

## 复现与证据

测试通过公开 `LocalFirstReplication.send(_:)` 与 `states()` seam，endpoint 边界在 publication 已完整写入真实 content-addressed 临时 repository 后中断第一次 observation。进程重建 Runtime 时，SQLite replication ledger 仍有一份 sealed pending publication；旧构造器却无条件建立 `waitingForEndpoint`、零计数、无 incident 的内存默认状态。

## 排除的假设

- 不是 immutable publication 丢失：重启后相同 publication 可幂等确认。
- 不是 ledger 没有持久化：恢复轮不需重新 materialize journal，self watermark 可推进。
- 不是目标端重复 apply：首次 apply 为一，第二次为零，领域资料只有一份。

## 根因与破坏机制

`LocalFirstReplication` 被设计为 durable replication truth 的公开门面，但初始化完全绕过 SQLite state metadata 与 `SQLiteReplicationLedger`，把 actor 内存默认值当成重启真值。Runtime 因此虽然能在下一次 reconcile 偶然恢复工作，却无法在 reconcile 前向 App 报告真实状态。

## 根因修复

Runtime 初始化改为可失败的 durable restore：严格解码持久化 state metadata，并以 ledger pending publication 与未完成 journal 重新推导 convergence 和 pending 数量。跨进程不存在的 `running`／`stopping` 一律恢复为 `idle`；invalid metadata fail-closed，不使用默认值掩盖损坏。

## 验证结果

- 原始 restart tracer：修复前两个断言失败；修复后 1 项、0 失败。
- publication 在确认前中断后仍使用原 identity 恢复，目标端首次 apply 一次，第二次零次。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行确认前中断与重启状态恢复 tracer，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，由 `scripts/check` 强制调用，公开 Runtime、真实临时 SQLite 与 content-addressed endpoint 任一层漂移均判红。

## 发行与回滚

当前没有 production cutover。若恢复门禁失败，停止后续 V2 切片并回滚未发行 Runtime 变更；不得用 UI 默认文案、清空 ledger 或重新生成 publication 绕过。灰度继续停留在隔离资料库，直至 crash matrix 全部闭合。

## 教训与永久约束

durable deep module 的第一份公开状态也必须来自 durable truth。能够在下一次操作中恢复，不等于重启状态正确；pending、incident 与成功时间必须在 App 订阅前完成重建。

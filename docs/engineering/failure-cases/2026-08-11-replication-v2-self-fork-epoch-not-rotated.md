# FAIL-2026-08-11-09：Replication V2 self-fork 无法退休旧 producer epoch

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T10:38:27-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初 Runtime 把 producer identity 固定为只读启动参数
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

问题尚未进入发行或 production。当本机 producer 因回退或重复 sequence 形成 fork 时，双分支即使没有领域冲突也会在 repair baseline 阶段抛出 Runtime failure；每次重启仍使用相同旧 producer，无法恢复同步。若绕过错误继续在旧 chain 发布，还会制造更多同 sequence 不同 digest。

## 时间线

- 现有 fork repair 已能原子 apply 分支、推进 resolved cursor 并关闭 resolution，但 `producerID` 是只读启动参数。
- 2026-08-11T10:38:27-04:00：新增 self-fork 症状 tracer，稳定抛出 `forked local producer requires a new producer epoch`。
- 2026-08-11T10:40:15-04:00：加入 durable active epoch 与原子 rotation transaction 后，同一 tracer 转绿。
- 2026-08-11T10:41:44-04:00：CAS fence 负向测试通过，过时 retiring epoch 不会留下 replacement baseline 或改变 active epoch。

## 复现与证据

真实临时 content-addressed repository 保存 producer A sequence 1 的两个合法 immutable branch；同一 SQLite Runtime 也以 producer A 启动。分支 records 使用不同 task identity，因此领域 merge 可确定性完成。修复前 resolution 已 close，但 baseline seal 因 producer 相同而直接失败。红测从公开 `LocalFirstReplication.send(.reconcile)` 取得原始异常，不依赖源码推断。

## 排除的假设

- 不是领域冲突：两个 branch 使用不同 identity，repair snapshot 已可生成。
- 不是 endpoint overwrite：Endpoint 只 exclusive-create immutable objects，两个 branch 均被保留。
- 不是重启可自然消解：旧实现每次由调用者重新注入相同 producer A，没有 durable replacement identity。
- 不能先改 metadata 再 seal baseline：两步 transaction 会留下“新 epoch 无 baseline”或“旧 epoch 仍 active”的 crash window。

## 根因与破坏机制

producer epoch 没有被纳入 Replication Deep Module 的 durable state，Runtime 只保存构造时的只读 UUID。self-fork resolution close 后，repair code 只能拒绝在旧 epoch 上发布，却没有安全退休、替换和重启恢复协议。

## 根因修复

SQLite metadata 现在保存唯一 active V2 producer epoch。首次启动只在 key 不存在时安装调用者 seed；后续重启忽略旧 seed并恢复 durable active epoch。

self-fork resolution close 后，Runtime 建立全新 UUID 与 sequence 1 authoritative baseline。`SQLiteReplicationLedger` 在一个 `BEGIN IMMEDIATE` transaction 内验证 active epoch CAS、closed resolution 的 generation／forked producer、replacement chain 为空，随后 seal 携带 exact `basedOnResolutionID` 的 baseline并替换 active epoch。任一验证失败时整笔 rollback。transaction 成功后 Runtime 才切换内存 producer；旧 epoch 后续不再 publish、observe 或承载本机 mutation。

## 验证结果

- self-fork 症状 tracer：双分支合并、resolution close、新 epoch baseline exact confirmed，最终 converged。
- 重启 tracer：仍传入旧 producer seed 时恢复 durable 新 epoch；新增本机任务后成功发布，旧 producer 的本机 ledger 仍没有 publication。
- CAS 负向 tracer：错误 retiring epoch 被拒绝，replacement publication 不存在，active epoch 保持原值。
- 相关 `LocalFirstReplicationTests` 九项与 `SQLiteReplicationLedgerTests` 三项均 0 失败。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行 self-fork 重启与 CAS rollback 两条测试，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，覆盖真实临时 SQLite、文件 Endpoint、公开 Runtime 与重启后本机 mutation。

## 发行与回滚

当前没有 production cutover。任一 epoch rotation 门禁失败都停止 rollback dual watermark、N-device、lifecycle、cutover 与发行工作；回滚未发行 V2 slice，保留 V1 production authority。不得恢复旧 producer、复用 sequence、删除远端 branch或用随机 winner 绕过。

## 教训与永久约束

producer identity 是 durable protocol state，不是启动参数。退休旧 epoch、新 epoch identity 与第一份 authoritative baseline 必须是一个 SQLite CAS transaction；重启 seed 永远不能覆盖 durable replacement。SQLite／ThisDeviceOnly Keychain 双 watermark 已由 `FAIL-2026-08-11-10` 独立追踪；本案例不把 self-fork epoch 轮换与 rollback detection 混为同一证据。

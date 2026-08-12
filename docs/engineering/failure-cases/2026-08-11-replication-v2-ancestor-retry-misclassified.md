# FAIL-2026-08-11-27：后代已发布时祖先精确重试被误判为 fork

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T20:18:24-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；content-addressed endpoint 初版只允许当前 head 做 exact retry
- Git author／committer：不适用；错误改动仍在未提交工作树
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

真实签名隔离 App 在上一条 publication 尚待 iCloud 确认时继续接受用户修改，并成功发布后续序列。下一轮同步随后在 `transportPrepare` 失败，Runtime 进入 durable `runtimeFailure` incident。用户本机修改没有被拒绝，但同步停止收敛，真实压力门禁以 `sync-incident-detected` 判红。

## 时间线

- 2026-08-11T20:17:48-04:00：新建 append-only iCloud round 开始真实 App exercise。
- 2026-08-11T20:18:06-04:00：第一条 publication 获确认，`pending=0`。
- 2026-08-11T20:18:12-04:00：后续本机修改产生一条待确认 publication，`pending=1`。
- 2026-08-11T20:18:18-04:00：再一批修改后后代也已发布，`pending=2`。
- 2026-08-11T20:18:24-04:00：下一轮同步更新本机 publication watermark，读取三条 announcement 后在 `transportPrepare` 失败。
- 2026-08-11T20:20:39-04:00：本机精确红测以 `producerFork(sequence: 1)` 复现“后代存在后重试完全相同祖先”。
- 2026-08-11T20:21:11-04:00：共享 endpoint 根因修复后同一红测转绿。

## 复现与证据

- 真实证据：签名 `e2e` App 的 operation 日志先连续成功，pending 从 1 增至 2；下一轮 `operationFailed` 的 stage 为 `transportPrepare`，没有 mutation rejection。
- 源码证据：`LocalFirstReplication.publishAndObserve` 每轮按 at-least-once 语义重发全部未确认 publication；`validatePublishPredecessor` 只在 `head.tipSequence == retry.sequence` 时允许 exact retry。
- fast 红测：先发布 sequence 1，再发布以它为 predecessor 的 sequence 2，最后重试完全相同的 sequence 1。旧实现错误抛出 `producerFork`。
- 隔离与安全：两轮真实测试都先通过 append-only guard，只创建新 session／round；未删除、覆盖、移动或改名任何 iCloud 对象。

## 排除的假设

- 不是并发 SQLite 写锁：失败前命令正常封存 publication 并更新 Keychain watermark，SQLite failure point 为空。
- 不是 mutation 拒绝：真实结果的 rejection count 为零。
- 不是 iCloud 账号或目录不可用：同一 round 已完成多个 publish／observe operation，其中第一条已确认。
- 不是实际 fork：本机确定性红测使用完全相同的 sealed publication 与 immutable bytes，仍被误判。
- 不是测试应忽略的短暂 waiting：Runtime 已持久化 failure incident，而非健康的 awaiting materialization。

## 根因与破坏机制

Runtime 的 delivery 语义是 at-least-once：未取得远端确认前，每轮都会重发全部 pending publication。endpoint 的 predecessor guard 却把 exact retry 错误限制为当前 tip。当 sequence 2 已发布而 sequence 1 仍未被 iCloud evidence classifier 确认，下一轮重发 sequence 1 时，head 已是 sequence 2，于是完全相同的 immutable publication 被当成 fork。pending 数量越多，越容易稳定触发。

## 根因修复

- 在共享 `ContentAddressedFileReplicationEndpoint.publish` 内先验证 sealed publication 的全部 object reference 与 bytes。
- predecessor／fork 判定前，逐个核对对应最终 URL 的 bytes、byte count 与 content digest；全部精确一致时直接返回相同 receipt，且不创建新 stage、不执行写入。
- 只要任一对象缺失，就继续走既有 predecessor 与 append-only publish；任一已存在对象 bytes 不同或损坏则 fail-closed 为 invalid object。
- 保留 same-sequence different-digest fork evidence、missing predecessor、partial publication recovery 与 no-overwrite 行为。

## 验证结果

- 新增精确红测在修复前稳定抛出 `producerFork(sequence: 1)`，修复后转绿。
- `ContentAddressedFileReplicationEndpointTests` 12 项全绿，覆盖 ancestor exact retry、current-tip retry、fork evidence、missing predecessor、partial final、restart 与 immutable bytes 不变。
- `scripts/test-replication-v2-recovery-contract` 全绿，覆盖真实 fork、partial publication、双 watermark、重启恢复、SQLite 单写者与 Keychain。
- 第三轮真实签名 App 在多个 publication 同时 pending 的路径完成 exercise 与 restart，最终 pending outbox 为零、convergence 为 `converged`、同步失败与 mutation rejection 均为零。
- 第二 SQLite 首次应用 14 个 publication 后精确收敛，restart apply count 为零；原有 168 个 iCloud 文件保持不变，最终只追加至 176。
- 独立 live-iCloud gate 另建两个新 round 并全部收敛，各有 18 个 repository 文件且 mutable head count 为零；`scripts/test-replication-v2-real-validation` 全绿。
- 案例仍保持「处理中」，等待修复 commit 与最终完整回归回填。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行 `testExactAncestorRetryRemainsIdempotentAfterDescendantPublication`，要求后代存在后重试祖先仍返回同一 receipt、永久 staging 集合不变、immutable bytes 不变且读取链无 fork。
- symptom：`scripts/test-replication-v2-app-stress` 必须让多个 publication 同时等待真实 iCloud 确认，继续大量用户修改，并最终完成 exercise、restart 与第二 SQLite 精确收敛；由 `scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

当前未发行，不进入 production 或公开发版。若 exact retry 修复破坏 fork evidence、partial publish recovery 或 immutable byte contract，回滚整个未发行 endpoint 切片并停止发版；不得在 Runtime 跳过 pending ancestor、清空 outbox 或吞掉 incident。灰度仅使用每轮新建且永久保留的隔离 iCloud round，监控 pending／confirmed publication 数、incident、mutation rejection、restart replay 和第二 SQLite snapshot 对账。

## 教训与永久约束

content-addressed append-only endpoint 的幂等键不是“当前 head”，而是完整 immutable publication 的精确 identity。predecessor 规则约束新分支；它不能否定已经存在且逐 byte 相同的祖先重试。所有 at-least-once transport 都必须覆盖“后代已经送达、祖先确认仍延迟”的乱序确认场景。

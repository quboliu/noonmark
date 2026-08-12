# FAIL-2026-08-11-05：iCloud promised item 等待被误分类为 Runtime 故障

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:52:31-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初的 iCloud V2 read adapter tracer 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

问题尚未进入发行或 production，但机制与用户此前看到的“同步未完成”相同：iCloud promised item 尚未 materialize 是正常等待，旧 adapter 在发起下载后却抛出 `downloadIncomplete`；Runtime 的通用 catch 把它持久化为 `runtimeFailure` 并向调用者抛错。若直接 cutover，网络正常但资料仍在下载时会显示故障，而不是“等待 iCloud 下载”。

## 时间线

- 真实 iCloud tracer 已证明 exact URL 可以处于 ubiquitous uploaded positive，并建立 coordinated read。
- 2026-08-11T09:52:31-04:00：审查 placeholder 路径发现 `startDownloadingUbiquitousItem` 后立即抛错；公开 Runtime 没有等待态 read result。
- 2026-08-11T09:53:44-04:00：新增 promised-item tracer 并完成由红转绿；第一次 reconcile 诚实 waiting 且无 incident，第二次资料 ready 后才记录最近同步。

## 复现与证据

测试只在 `ReplicationEndpoint.read` 系统边界返回一次 `awaitingMaterialization`，不 mock Runtime 内部 collaborator。旧 Interface 无法表达该状态，编译即判红；补齐 Interface 后，Runtime 第一次返回 `worker=idle`、`convergence=waitingForEndpoint`、`incident=nil`、两个成功时间皆为空，第二次 stable observation 才收敛。

## 排除的假设

- 不是 publication corruption：等待期间没有 digest mismatch、缺 seal 或 fork 证据。
- 不是同步成功：placeholder 尚未 materialize 时没有空增量 stable observation，因此不得写 `lastSyncedAt`。
- 不是需要 App retry workaround：等待语义属于 Endpoint 与 Deep Module，应在共享边界一次解决。

## 根因与破坏机制

`ReplicationReadPage` 只有 publications、cursor 与分页计数，无法区分“稳定空增量”和“资料存在但尚未 materialize”。iCloud adapter 只能用异常逃离读取；Runtime 再把所有异常统一解释为 `runtimeFailure`，把协议等待与程序故障混为一谈。

## 根因修复

`ReplicationReadPage` 新增 typed `ReplicationReadState`。iCloud adapter 发现 promised item 时请求系统下载并返回 `awaitingMaterialization`，不打开 placeholder、不推进 cursor，也不抛成故障。Runtime 收到等待态后保留 durable work，返回 `waitingForEndpoint`、无 incident，并且不更新最近同步；后续 stable 空增量 observation 才允许闭合。

## 验证结果

- promised-item public seam tracer：1 项、0 失败。
- 第一次 observation 不产生 incident 或成功时间；第二次 stable observation 才写 `lastSyncedAt`，`lastEffectiveSyncedAt` 继续为空，因为没有本机 confirmation 或远端事实 apply。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 promised-item typed waiting tracer，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，由 `scripts/check` 强制调用；Runtime 若再次把 materialization wait 抛错或提前写成功时间即判红。

## 发行与回滚

当前没有 production cutover。若门禁失败，停止 V2 灰度并回滚未发行 Interface 切片；不得用无限 retry、吞错、超时后成功或 UI 文案覆盖。真实 placeholder 的双实体 Mac 验证仍是 cutover 前置条件。

## 教训与永久约束

“没有可读资料”至少包含稳定为空与尚待 materialize 两种不同事实。Endpoint Interface 必须显式表达二者；expected waiting 不应借异常通道穿过 Deep Module，更不能污染 incident 或成功时间。

# 以增量复制取代全量镜像同步

**Status**: Accepted

晷迹的第一版同步 transport 以 `fetchAll()` 返回完整远端镜像；Local Folder／iCloud Drive 每次上传又重放所有 commit、合并完整 current set，并修复所有 record mirror 与 snapshot。协调器为证明端点稳定和完整覆盖，在单次用户同步中最多调用 17 次 `fetchAll()`。因此日常同步成本随历史总量增长，而不是随本轮变化增长；CloudKit adapter 也把 CKSyncEngine 的增量 change 再展开成完整本机 mirror。

## Decision

- 直接把 `SyncRecordTransport` 改成增量复制协议，不并行保留第二套版本：`push(batch) -> acceptance receipt`、`pull(after: frontier, limit:) -> change page`、`confirmationStatus(for:)`。显式 bootstrap 可以从空 frontier 分页读取，但稳态代码不得调用全量 mirror API。
- SQLite 是协调器的 durable Outbox 与 apply frontier；transport 必须拥有 durable、可重放的 Inbox evidence。文件端点直接以 immutable batch 充当 evidence，CloudKit adapter 在推进 engine state 前另存 durable Inbox。领域 snapshot、冲突、waiting／terminal disposition、审计与 apply frontier 在同一个 `BEGIN IMMEDIATE` 事务提交。崩溃可以导致幂等重放，不得导致记录丢失。
- iCloud Drive／Local Folder 使用每个安装 epoch 一条独立 hash chain：`heads/<epoch>.json` 只保存 `tipSequence` 与 `tipHash`，`batches/<epoch>/<20 位 sequence>.json` 保存 immutable `{epochID, sequence, previousHash, records, bodyHash}`。batch 的 SHA-256 对落盘 canonical bytes 计算，`bodyHash` 让分页 reader 在应用非 tip batch 前也能拒绝语义内容损坏；同一 epoch／sequence 只能 exclusive create 或 exact-match，head 以临时文件、`fsync` 与 atomic rename 发布。
- 安装 epoch 是随机、本机持久的 transport identity，不等于领域 `SyncDeviceID`，也不进入数据包。导入保留目标 Mac 的领域设备身份，但建立新的 transport epoch 与空 frontier。跨 producer 可任意交错；同一 producer 只能严格按 sequence 应用。缺 batch、hash 断链、同 sequence 异内容或 frontier 所指 producer 消失时阻断同步，不猜测修复。
- pull 只枚举小型 `heads/` 目录，然后按 frontier 精确打开 `f+1...tip`，不得扫描全部 batch。稳态复杂度目标是 `O(pending + unseen + producers)`；只有从空 frontier 重建才允许 `O(total history)`。
- Outbox 状态区分 `pendingUpload`、`publishedLocal`、`uploaded`、`blockedUserAttention` 与 `blockedCorruption`。确定性物化失败立即隔离，不得阻塞无关记录，但任何 blocked entry 都使整体状态保持失败。iCloud Drive 的本机文件发布只进入 `publishedLocal`；batch 与覆盖它的 head 都由 ubiquitous metadata 确认上传后才进入 `uploaded`。不得用本机 write success 或空 pending 队列冒充跨设备同步成功。
- CloudKit 保留 CKSyncEngine receipt cursor，同时在 adapter persistence 中保存 append-only Inbox 与独立 apply sequence。一个 fetch cycle 先持久化全部解码记录到 Inbox，最后才把 deferred engine state 与当前 Inbox 一起保存；任一 record event 持久化失败都不得推进 receipt，崩溃至多导致重放。通用协调器只读 durable Inbox。CloudKit server acceptance 可直接确认上传，但 engine token 不能替代领域 apply frontier。
- v18 是同步 runtime 的 clean cut：保留 SQLite 领域事实、endpoint 设置与本机设备身份，清空旧 journal、pending download、terminal rejection、conflict 与 sync metadata，再由本机 snapshot 生成新仓库的完整 baseline。旧 journal 的 `uploaded` 只证明旧格式，绝不能拿来证明新仓库覆盖完整。
- pending／established baseline 绑定 transport namespace；重建中途更换端点必须失败，不能把旧端点的 receipt 当作新端点覆盖证明。用户须先清空旧 iCloud repository，再首次启动和同步 v18；反过来清理会使已经建立的 frontier 失效，需要重新执行 sync runtime clean cut。
- 不在本次重构中实现远端 GC。只有未来存在可验证 consumer acknowledgement、设备退役和 checkpoint 协议后才允许删除 batch。

## Reliability boundary

这是一套通用的 at-least-once 增量复制方案：transport 负责不丢失、可分页、可确认的 change evidence；SQLite／NoonmarkCore 负责幂等、确定性领域合并。它适用于 CloudKit、文件型端点和未来有游标的服务端，但不是“任意文件服务自动安全”的承诺。iCloud Drive 没有跨设备 CAS 或 consumer receipt，故只能证明系统上传完成，不能证明另一台设备已经应用；真正的 server acknowledgement 与推送能力仍以 CloudKit 为长期默认目标。

## Risk And Rollout

- 风险等级：P。主要风险是 frontier 越过未提交领域事实、文件链分叉、iCloud placeholder／上传状态误判、毒记录重新形成 head-of-line block，以及 CloudKit engine token 先于 Inbox 持久化。
- 灰度：先跑 InMemory／Local Folder 确定性测试，再跑 `e2e` profile 的真实 iCloud Drive metadata 与双 SQLite，随后两台实体设备；CloudKit 继续受 ADR-0019 的 Development、Production schema 与双物理设备门禁保护，本次不切换 production 默认 transport。
- 监控：只记录 producer、head／batch／record／byte 数量、frontier distance、Outbox 各状态数量、Inbox backlog、确认阶段与 typed failure；不得记录正文、payload、端点路径或 CloudKit record name。
- 回滚：普通 `git revert` 回退代码；用户按既定 clean cut 自行清空对应 iCloud repository，再由旧版本重建。开发与测试只清理自己的固定非 production profile，任何 agent 或脚本不得读取、备份、启动或重置 production 数据。

## Consequences

日常 iCloud Drive／Local Folder 同步不再因历史增长而反复读取和重写全仓；崩溃恢复、乱序、缺口与上传确认变成协议的一等状态。代价是需要持久 frontier／Inbox、更多故障状态和严格的链校验；文件端点仍只能作为受限 fallback。CloudKit transport 已改为增量 Inbox，但其现有 SQLite adapter persistence 仍会在 session commit 编码 current mirror snapshot；在把该 persistence 规范化为增量表、并通过全部 live 门禁前，CloudKit 不得成为默认端点。

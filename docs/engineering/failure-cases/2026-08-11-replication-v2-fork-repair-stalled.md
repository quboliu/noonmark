# FAIL-2026-08-11-08：Replication V2 无冲突 fork 永久停在检测态

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T10:21:10-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初只实现 fork detection 与 `branchesValidated` 的 Interface 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

问题尚未进入发行或 production。即使两个 fork branch 完全没有领域冲突，Runtime 也只会持续返回 `producerForkDetected`，不会 apply 任一分支、推进安全 cursor 或发布 repair baseline；用户每次重开与重试都会看到同一同步阻断，资料永远无法自动收敛。

## 时间线

- 既有切片已能保留、验证并 durable 记录完整 fork evidence，但状态固定停在 `branchesValidated`。
- 2026-08-11T10:21:10-04:00：新增无冲突 end-to-end tracer，出现 10 个症状失败：blocked、0 apply、0 confirmation、空领域资料、resolution 未关闭、无 baseline，重启继续 blocked。
- 2026-08-11T10:25:06-04:00：领域 snapshot、resolved cursor 与 resolution close 原子提交后，只剩 baseline/confirmation 两项失败。
- 2026-08-11T10:27:39-04:00：exact-resolution baseline、confirmation 与空增量复核完成，原始 tracer 全绿。
- 2026-08-11T10:29:29-04:00：领域 identity collision 负向测试通过，证明冲突路径没有被自动 close。
- 2026-08-11T10:30:40-04:00：未绑定本机 closed resolution 的伪造 baseline 被 typed 拒绝。
- 2026-08-11T12:17:31-04:00：新增 conflict persistence tracer 后，resolution-specific conflict set、重复 reconcile 幂等与重启 state restore 由红转绿。
- 2026-08-11T12:21:31-04:00 至 12:22:56-04:00：`keepCurrent` command tracer、漏项决定与过期 engine generation 负向门禁、当时的 Schema 六表迁移契约全部转绿；后续 fork conflict／outbox／authority 扩展后的 current contract 已统一为八张 V2 ledger 表。

## 复现与证据

真实临时 content-addressed repository 保存 producer A sequence 1 的两个 immutable branch；每条 branch 携带不同 task identity，因此可确定性合并。producer B 的公开 `LocalFirstReplication.send(.reconcile)` 修复前只记录 evidence 并返回 blocked。红测直接对账领域 SQLite、resolution ledger、本机 publication、最终状态和重启结果，排除了单纯 UI 投影错误。

## 排除的假设

- 不是 branch corruption：两条 publication 的全部 immutable objects 都由 production builder 产生并逐 digest 通过。
- 不是领域冲突：两个 branch 使用不同 task identity；同一 identity 的 divergent task-definition 另有负向测试，仍保持 blocked。
- 不是 cursor 可以先行：若 cursor 与领域 snapshot／resolution close 不在同一 transaction，任一 crash window都会跳过未提交 facts。
- 不是普通 journal publication：repair baseline 没有本机 mutation journal，必须以 `basedOnResolutionID` 明确证明来源。
- 不是文件存在即可成功：baseline 必须 exact confirmed，之后还须一轮空增量 observation。

## 根因与破坏机制

早期 V2 slice 只定义了 fork detection 和 evidence ledger，没有把 domain merger、resolved cursor、resolution transition 与新 producer baseline 纳入同一个 Deep Module protocol。任何单独补其中一项都会产生半修复：先 cursor 会丢资料，先 apply 会在重启后重复 incident，普通 baseline 无法证明基于哪次 fork，提前 success 又会领先于 confirmation。

## 根因修复

`ReplicationReadCursor` 新增 exact resolved-fork position；Endpoint 每次重读完整 graph，只有 resolution ID 完全相同才跳过旧 producer。Runtime 把双分支 records 送入既有 deterministic merger；只有 waiting 与 conflict 都为空时，`SQLiteSyncRepository` 才在一个 transaction 内提交领域 snapshot、resolved cursor 与 resolution close。

close 后 ledger 找出尚无本机 baseline 的 resolution；Runtime 从 authoritative snapshot 建立 `basedOnResolutionID` publication。ledger 只允许已关闭 resolution 使用空 journal mapping，普通 publication 仍必须绑定真实 pending journal。baseline seal 后走同一 publish／observe confirmation 集合与 self watermark，再由 resolved cursor 执行空增量复核。接收方若本机没有同一 closed resolution，返回 `repairBaselineRejected`，不 apply、不推进 cursor。

领域 merger 报 waiting 或 conflict 时不提交 snapshot、cursor 或 close，resolution 保持 `branchesValidated`。merger 产出的 canonical conflict evidence 另在同一 engine generation fence 下写入第八张 V2 ledger 表；每个 set 绑定 exact resolution、engine epoch／revision 与 conflict ID，重复计算同一代必须 exact match，新一代只追加新 set。Runtime state 只投影 resolution、conflict type 与 entity type 的有界摘要，重启直接从 ledger 恢复，不依赖进程内存。

用户决定 command 必须一次覆盖当前 conflict set 的全部 ID；Runtime 排除这些 exact branch evidence 后重跑 merger。漏项、额外项、重复项、过期 engine generation、waiting 或新 conflict 全部 fail-closed。成功时，engine-generation CAS、非冲突 snapshot、resolved cursor、每项决定与 resolution close 在同一 SQLite transaction 提交；随后仍必须完成 exact-resolution baseline、confirmation 与空增量复核。初始 `keepCurrent` tracer 后，`acceptRemote` 已补齐“追加前向 definition revision并保留历史”的领域语义，`copyAsNew` 已补齐确定性 identity、完整模板复制与历史隔离；三种决定共用同一原子 command／manifest replay 路径。self-fork 的 producer epoch 轮换由 `FAIL-2026-08-11-09` 独立闭环。

## 验证结果

- 无冲突 end-to-end tracer：双 task branch 全部进入领域资料，resolution closed，repair baseline exact confirmed，最终 converged。
- 重启 tracer：0 duplicate apply、0 duplicate confirmation，旧 fork 不再重现。
- late-writer tracer：任一 descendant 改变 graph identity并建立新 resolution，不被 resolved cursor 跳过。
- 领域冲突 tracer：两轮均 blocked、0 apply、0 baseline、0 成功时间，resolution 保持 `branchesValidated`。
- conflict persistence tracer：canonical evidence 与 observed engine generation 跨重复 reconcile、SQLite reopen 与 Runtime restart 保持同一 actionable summary；没有任务正文、payload、路径或自由文本进入 Runtime state。
- `keepCurrent` tracer：漏项决定先 fail-closed；本机 snapshot 在用户查看期间变化后，旧 generation 决定被拒绝且 snapshot、cursor、decision、resolution 都不改变。重新 reconcile 追加新 conflict set 后，exact 决定保留两项本机事实、关闭 resolution、发布绑定 baseline并取得 confirmation。
- 未授权 baseline tracer：两轮均 `repairBaselineRejected`，领域 snapshot 与 cursor 不前进。
- 完整回归：`NoonmarkSyncTests` 295 项与 `NoonmarkStorageTests` 280 项均 0 失败；Storage 唯一 skip 是必须显式开启的 live iCloud 用例。
- 真实 iCloud append-only tracer：session `530707f0-43e0-42c0-a802-3f5fbc3cf3d4` 的两个全新 round 在 37.673 秒内通过，每轮含 4 个 immutable publication object 与 1 个 canonical repository marker、0 mutable head，后轮完成后前轮 inventory／digest 保持不变；测试对象依铁命永久保留。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行无冲突 repair、领域 conflict persistence／restart／exact `keepCurrent` command、过期 generation、late-writer 与 baseline 授权测试，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，覆盖真实临时 SQLite、文件 Endpoint、Runtime state stream、重启和持久化对账，由 `scripts/check` 强制调用。

## 发行与回滚

当前没有 production cutover。任一 repair 门禁失败都停止后续 rollback／lifecycle／cutover 与发行工作；回滚未发行 V2 slice，保留 V1 production authority。不得通过任意 winner、LWW publication、提前推进 cursor、伪造 journal、跳过 confirmation 或隐藏 incident 绕过。

## 教训与永久约束

fork repair 是一个 transaction protocol，不是一组松散 patch。领域事实、resolved cursor、resolution state 与 baseline provenance 必须由同一个 Deep Module 协调；成功时间永远是全部 durable truth 和 exact endpoint evidence闭合后的派生结果。

# Noonmark Local-First Replication V2

- Task-ID：`noonmark-local-first-replication-v2`
- 风险等级：P
- 状态：本机实现、append-only 真实 iCloud、签名压力、完整 E2E 与 `make check` 已完成；待修复 commit、双实体 Mac 与 72 小时 soak，production cutover 尚未获批
- 决策来源：ADR-0047；Kimi Code K3 第五轮终审 `approve`

## 需求与成功标准

目标是以 `LocalFirstReplication` Deep Module 完整取代当前 App、RunController、三个 Coordinator、SQLite Repository 与 transport 共同持有同步正确性状态的浅层集群，从根本上关闭以下已经发生或已由运行证据证明的机制问题：

- 合法 iCloud confirmation 乱序／部分到达被误判为资料损坏；
- mutable head 的路径级 uploaded 状态不能证明 exact generation；
- iCloud promised item／placeholder 被普通文件 I/O 误判缺失或卡在 waiting；
- 同步远端等待长期占有 App mutation gate；
- disable、retry、status restore 与 worker lifecycle 由多个旁路 Task 分散持有；
- producer epoch／frontier 在 SQLite rollback 后可能重用；
- V1 repository 没有 clean V2 format boundary，旧对象不能被误当成 V2 truth。

完成必须同时满足：

1. App 只发送 command、订阅 durable state，不直接调用 upload/download/repository transition。
2. publication 采用 content-addressed chunks、root、seal 与 immutable announcement；mutable index 不属于 truth。
3. confirmation 集合化、单调持久，并只推进最长连续 self watermark。
4. Apple exact evidence、promised-item materialization、typed retry/user-attention/corruption 真值表通过非生产真实 iCloud 门禁。
5. fork 双分支保存、确定性 resolution、N-device repair 与双 watermark rollback fail-closed。
6. V1→V2 执行无兼容 clean cut：只有空白或 exact V2 repository 可启动，初始 baseline 与 post-cutoff capture 不漏本机事实。
7. disable 先 durable fence，再 cancel+join 全部 task；无 timeout、abandon、zombie 或晚到提交。
8. 最近同步与最近有效同步只在完整闭合后写入；waiting、空 pending 或本机写入不冒充成功。
9. fast、真实 symptom、签名 App、release、双实体 Mac 与 72 小时 soak 门禁全部通过后，才允许请求 production cutover 审批。

## 现状与根因证据

- 当前调用链是 `Settings → NoonmarkStore → LocalFirstSyncRunController → SQLiteLocalFirstSyncCoordinator → Upload／Download Coordinator → SQLiteSyncRepository → SyncRecordTransport → iCloud／Local Folder`。每层都持有一部分不可独立验证的协议状态。
- build 29 的直接故障由 `SQLiteSyncUploadCoordinator` 对 receipt 的无序分组，与 `SQLiteSyncRepository` 对单次调用连续 sequence 的要求组合产生。`sequence 2 → sequence 1` 是合法 confirmation 顺序，却被错误当成 gap/corruption。
- `ICloudDriveSyncTransport` 只读取路径级 `ubiquitousItemIsUploaded` 与 uploading error；receipt 又包含会被覆盖的 mutable head 路径，无法把 Apple positive 绑定到 exact bytes/generation。
- V1 iCloud pull 直接复用普通文件 I/O，也没有把 discovery capability 与实际签名身份绑定，不能可靠区分 absent、placeholder、downloading 与 corrupt。2026-08-11 的真实运行进一步证明：通过 CloudDocs mirror fallback 运行的 XCTest 可从精确 URL 取得完整 ubiquitous resource evidence，但 app-container 专属 `NSMetadataQueryUbiquitous*Scope` 固定返回空集合；因此不能把该 query scope 当成所有运行身份共有的前提。
- 当前 engine generation CAS 可以保护短 merge transaction，应保留；整个同步 operation 的 App-wide exclusive mutation gate 应删除。

## 实施切片

1. 乱序 confirmation ledger：先红后绿钉住 `2 → restart → 1` 与最长连续 watermark。
2. 单 publication 黄金路径：outbox、chunk、root、seal、confirmation、第二资料库 apply 与双端重启。
3. crash／retry／placeholder：逐个覆盖 chunk、root、seal、receipt 与 coordinated materialization 中断点。
4. fork／repair／rollback：双分支、resolution state、N-device convergence、SQLite／Keychain watermark mismatch。
5. lifecycle：durable generation、全 task tree cancel+join、stoppingDelayed、disable restart。
6. V1 clean cut：空 repository marker、旧 repository fail-closed、baseline/capture 原子点、post-cutoff replay；无 staging import、legacy reader 或 late-writer 兼容。
7. App cutover：Store facade 只转发 command／state，删除旧 production authority 与过时内部测试。
8. 真实门禁：Local Folder、签名 E2E、dmg-validation、两台实体 Mac、72 小时 soak。

## 2026-08-11 append-only 真实 iCloud tracer

- 项目铁命与静态 guard 固定禁止删除、覆盖、替换、移动或清理任何 iCloud 对象；真实测试只在 `Noonmark-E2E/AppendOnlyLiveTests/<session-UUID>/<round-UUID>/` exclusive-create。
- 审查捕获 direct-final write 的崩溃窗口后，marker 与所有 immutable object 改由同一个 `AppendOnlyFilePublisher` 发布：唯一 staging 完整写入并 `fsync` 后，以不覆盖的 `linkat` 原子建立最终键；中断只留下永久 stage，最终键不会半写。V2 已删除 mutable head policy、heads tree 与 replace／rename 能力。全新真实 iCloud capability round 已证明 hard link 成功、stage／final inode 与 bytes exact，现场永久保留。
- reset safety 同时收紧：`scripts/reset-dev-data` 不再拥有任何 iCloud target；本机 profile reset 必须保留所有 iCloud canary 与 append-only live round。遗留 CloudKit zone 删除入口也已移除。
- 首次 tracer 揭露并否定「无 iCloud container entitlement 的 XCTest 仍可使用 ubiquitous query scope」这一假设：同一轮 4 个 publication object 的精确 URL resource evidence 全部为 uploaded positive，目录限定的 Spotlight 查询也找到这 4 个对象，但 `NSMetadataQueryUbiquitous*Scope` 返回 0，门禁诚实保持 waiting；repository inventory 另含 1 个 canonical marker。
- 修正后的 adapter 以 immutable exact URL 为证据单元；只有 byte count、SHA-256 与全部 Apple ubiquitous upload properties 同时为明确 positive 才 confirmed。pull 只枚举本轮 root，placeholder 先请求 materialization，文件内容通过 `NSFileCoordinator` 读取。
- 两个独立真实 session `e6250837-fd2e-4ec6-b887-049ed9ffd10e` 与 `a6b291be-c501-4867-b91b-746da8f2bcbc` 各自完成两个全新 round；每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 个 mutable head，双 SQLite 收敛、目标重启零重复 apply，第二轮结束后第一轮对象集合与 digest 不变。所有测试对象依铁命永久保留。
- 扩大回归曾捕获 schema 19 夹具漂移；用户随后明确批准开发期零兼容，因此最终门禁固定 current V2 ledger 八张表契约，并要求 v15／v17／v18 在任何迁移或资料改写前拒绝。第七张表承载 fork resolution，第八张表承载 resolution-specific conflict set。普通 Storage 套件不启用 live iCloud，真实证据只由显式 append-only symptom gate 提供。

## 2026-08-11 crash、materialization 与 fork detection

- publish 完成、confirmation observation 前中断的公开 Runtime tracer 已由红转绿。重启第一份 state 从 SQLite metadata 与 ledger 恢复 `runtimeFailure` 与 `pending=1`，随后以相同 publication identity 幂等确认；目标资料库只 apply 一次。
- chunk、root、seal、announcement 四种 immutable prefix 中断均已验证：重启 retry 不替换既有 bytes、补齐剩余对象，最终只读取一份 sealed publication。
- marker 与任一 object 的 partial write 中断另有 5-byte fault seam：最终键保持不存在，原 partial stage 永不删除或改写。marker 缺失使 repository ownership 无法证明，因此非空 root 的 reopen 必须零写入 fail-closed，由开发期人工重置；已有 exact marker 的可信 V2 repository 中，immutable object retry 才可使用全新 stage 发布完整 bytes。首次 V2 authority transaction同时清除未分代的 V1 pending／terminal／conflict／audit／metadata，防止旧下载证据越过 clean cut；领域 facts、设置、设备 identity 与失活 V1 journal 保留。
- `ReplicationReadPage` 现以 typed state 区分 stable 与 promised-item materialization waiting。等待不再抛成 Runtime failure、不推进 cursor、不写成功时间；后续 stable 空增量 observation 才闭合最近同步。
- producer fork 已从具体 file adapter exception 提升为 `blockedProducerFork → producerForkDetected`；Endpoint 完整验证从首次分叉点开始的 immutable branch graph，并以排序后的全部 publication references 产生 deterministic resolution ID。任一分支追加 descendant 都形成新的 durable resolution，不会被旧 incident 静默忽略。Runtime 在返回 incident 前把 exact evidence 与 `branchesValidated` 持久化到第七张 V2 ledger 表。
- 无领域冲突的第一条 repair tracer 已贯通：双分支 records、领域 snapshot、resolved cursor 与 resolution close 在一个 SQLite transaction 内提交；随后本机 producer 发布携带 `basedOnResolutionID` 的完整 baseline，取得 exact confirmation 与空增量 observation 后才报告 converged，重启不重复 apply。waiting／领域冲突时 transaction 不提交，仍保持 actionable incident；未绑定本机 closed resolution 的 baseline 被 typed 拒绝且不推进 cursor。self-fork 会在同一 SQLite transaction 内 CAS 退休旧 active producer、建立全新 epoch并 seal exact-resolution baseline；重启及后续本机 mutation 不会回到旧 chain。SQLite／ThisDeviceOnly publication watermark 的双向 mismatch tracer 已贯通，旧 epoch 在 Keychain CAS 前不能进入 Endpoint；Data Protection Keychain 的签名 `e2e` 正向门禁也已通过。resolution-specific conflict set、重启 state restore、`keepCurrent`、`acceptRemote`、`copyAsNew` 的逐领域语义与 N-device manifest replay 均已贯通。
- 修改 read state 后新增真实 append-only session `47196365-07b7-465e-8121-130c746461ee`，两个全新 round `ab328f4f-c2b2-45ca-a142-35b41c7d5c5f` 与 `6d44f2a8-d2df-4aba-8fe4-79ceb53a274d` 在 51.573 秒内通过；每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 mutable head，旧轮 inventory／digest 保持不变，所有对象永久保留。
- fork graph closure、原子 repair transaction 与 exact-resolution baseline 完成后，再新增真实 append-only session `530707f0-43e0-42c0-a802-3f5fbc3cf3d4`；两个全新 round `9a5bd8e0-c9cc-425a-969c-c61aee64c0e5` 与 `40d1aaab-24a6-4dfc-a8c8-c9413839d6f2` 在 37.673 秒内通过。每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 mutable head，前轮 inventory／digest 在后轮完成后保持不变，所有对象永久保留。
- self-fork 与双 publication watermark kernel 完成后，新增真实 append-only session `a1b0ebff-e625-4d28-b1e0-4cbc243a9404`；两个全新 round `16fd73b8-7ad6-4fac-ae3e-6eb5f118a641` 与 `6044e247-7241-4b18-9fc7-a1d35e982154` 在 37.446 秒内通过。每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 mutable head，目标 SQLite 收敛且重启没有重复 apply；既有对象没有删除、覆盖、替换、移动或改名，所有新对象永久保留。
- 当前完整 `swift test` 回归为 1,576 项、0 失败、1 项显式 live-iCloud skip，另有 14 项 Swift Testing 套件全绿；独立真实 iCloud gate 已通过。V2 recovery／fork／dual-watermark 契约（包括 conflict persistence、重启 restore、exact 三类决定与过期 engine-generation 拒绝）、Schema 四项、89 项 failure-case 映射、496 个 SwiftFormat 文件、SwiftLint 零 error、runtime profile 隔离、iCloud append-only guard 与 `git diff --check` 全部通过。`scripts/test-replication-v2-recovery-contract` 与 failure case `FAIL-2026-08-11-04` 至 `14` 已进入 `scripts/check` 静态聚合关系。
- 签名 Keychain symptom gate 已接入 `e2e` App 的三次独立启动。它先真实复现无 provisioning entitlement 的 `-34018`，也证明手工伪造 entitlement 会被 LaunchServices 以 POSIX 153 拒绝；经用户批准后，Xcode automatic provisioning 为精确 `app.noonmark.mac.e2e` 身份建立 development profile。build 现在 fail-closed 校验 profile、bundle identity、同 Team Keychain group 与最终 signed claims。两轮全新 scope 的真实签名 gate 连续通过 `nil → 1 → 2`、stale CAS、`AfterFirstUnlockThisDeviceOnly`、`synchronizable=false` 和第三次重启读取；该 rollback slice 已取得运行产物级正向证据，但不等于完整 V2 或 production cutover 已完成。

## 2026-08-11 fork conflict persistence 与决定 seam 设计

- 需求：领域 merger 已识别的 exact conflict 必须绑定 deterministic `resolutionID` 持久化；重启后的第一份 Runtime state 必须仍呈现同一有界 conflict summary。用户 command 不能只改一个 UI flag，必须在决定仍基于同一 engine generation 时完成真实领域 repair；漏决定、额外决定、过期 generation、waiting 或新 conflict 全部 fail-closed，cursor、snapshot 与 resolution 不得半提交。
- 现状：fork merge 出现 waiting／conflict 时，`SQLiteSyncDownloadCoordinator` 直接返回 `committed=false`。这个行为正确保护了领域 snapshot、cursor 与 resolution close，却也丢弃了 merger 已算出的 conflict evidence；现有 `SQLiteSyncRepository.resolveConflict` 只更新 V1 `sync_conflicts.resolution`，不会重跑 merger、推进 V2 cursor 或关闭 resolution，不能作为 V2 authority。
- 设计：新增 `sync_replication_fork_conflicts` 作为第八张 V2 ledger 表，以 `(resolution_id, conflict_id)` 为主键，外键绑定 fork resolution 与 canonical `sync_conflicts` evidence，并保存 exact observed engine epoch／revision、typed decision 与决定时间。相同 resolution 的 conflict set 与 generation 必须整体 exact match；只有尚无决定的 set 可由同一 fork evidence 在新 engine generation 下整体替换，禁止逐行补丁造成混代证据。
- command／state：Runtime state 只投影 `resolutionID`、canonical conflict ID、type、entity type 与实际允许的决定，不携带任务正文、路径、payload 或自由文本。所有当前 conflict ID 必须一次覆盖且不重复；Runtime 以 `keepCurrent`、`acceptRemote` 或 `copyAsNew` 的逐领域语义消费 exact branch evidence。只有结果不再 waiting／conflict 时，SQLite 才以 engine-generation CAS 在同一 transaction 提交前向事实、resolved cursor、每项决定与 resolution close，随后沿 exact-resolution baseline／confirmation／空增量复核路径收敛。
- 演进结果：`acceptRemote` 已实现前向 definition revision，`copyAsNew` 已实现确定性 identity 与完整任务模板复制；两者与 `keepCurrent` 共用相同 transaction protocol 和 N-device manifest replay。当前 schema 19 与 V2 均未发行，非生产资料按既定 clean cut；不新增兼容层、不触碰 production。
- 风险／回滚／监控：最大风险是 conflict set 与领域 snapshot 混代、用户决定漏项或 cursor 领先于事实。门禁必须覆盖首次 conflict、重启、重复 reconcile、过期 generation、漏项／额外项、决定 transaction 中断与最终 baseline；任一失败只撤回未发行 V2 slice并重建非 production profile，不恢复 V1 writer。监控只投影 typed incident 与 conflict count，不记录 resolution／conflict identity、payload 或 Keychain／iCloud 路径。

## 2026-08-11 acceptRemote／copyAsNew 前向语义设计

- 需求：决定必须改变真实领域结果，且不能覆盖或删除既有历史。Runtime state 必须逐条公开实际允许的决定；App 不得对不可安全执行的冲突显示假按钮。用户仍须一次覆盖当前 exact conflict set，混合决定必须在同一 engine-generation fence 内完成。
- 现状：`SyncConflictResolution.acceptRemote`／`copyAsNew` 目前只是 V1 row flag，没有领域效果。merger 的 `invalidRecordPayload`、缺失引用、结构循环、非法 delete 与 classification audit collision 代表远端 evidence 本身不能通过当前领域边界；把它们“强制应用”会破坏 snapshot integrity。另一方面，`taskDefinitionMutation`、`historicalTraceMutation`、`historicalSubtaskMutation` 与 `duplicateActiveTrace` 携带可恢复的任务内容，但既有历史身份不能原地重写。
- 决定矩阵：`keepCurrent` 对全部 conflict type 可用。`acceptRemote` 只对 exact `.taskDefinitionMutation + .taskDefinition` 可用，语义是在同一 TaskChain 追加一个全新 definition revision、保留旧 definition 与历史 trace，并只让仍为 pending 的当前／未来 trace 指向新 revision；同一 command 对同一目标最多接受一个远端候选。`copyAsNew` 只对 `.taskDefinitionMutation`、`.historicalTraceMutation`、`.historicalSubtaskMutation`、`.duplicateActiveTrace` 中能够从 exact branch graph 与 authoritative snapshot 重建完整任务模板的 evidence 可用；它建立全新任务池 TaskChain，复制标题、描述、活动附言、planned／visible subtask 结构与当前分类，重置日期、status、progress、continuation 与历史。
- identity 与持久化：前向 definition、TaskChain、TaskDefinition、note、planned-subtask 与 classification audit identity 由 `resolutionID + conflictID + typed role/index` 确定性派生，禁止依赖每台设备各自的随机 UUID。junction row 除 decision／decidedAt 外保存 typed result reference：`acceptRemote → taskDefinition`、`copyAsNew → taskChain`、`keepCurrent → nil`。相同决定重放必须产生逐字相同 snapshot；结果 reference 将进入后续 N-device resolution manifest。
- 原子协议：decision resolver 只接收 authoritative snapshot、immutable branch graph、当前 conflict set 与 exact selections，先在内存中生成 forward snapshot，再让普通 deterministic merger处理全部未被决定消费的 branch evidence。只有 forward snapshot 与剩余 evidence 均无 waiting／new conflict 时，SQLite 才在一个 transaction 内提交 engine-generation CAS、snapshot、cursor、decision outcome、resolution close；任何 decode、重建、allowed-decision、CAS 或 integrity 失败均保持原 snapshot／cursor／decision／resolution 不变。
- seam 与门禁：用户行为 seam 固定为 `LocalFirstReplication.send(.resolveForkConflicts)` 与其 durable state；可恢复性 seam 固定为 SQLite 原子 commit。tracer 依次覆盖 allowed-decision projection、`acceptRemote` 前向 revision、`copyAsNew` 独立任务、混合决定、重启幂等、同一实体双 accept 拒绝、无法重建模板拒绝和 stale generation。测试不得绕过 Runtime 直接伪造已解决 row。
- 风险／回滚／灰度／监控：最大风险是把不可接受 evidence 伪装成成功、复制丢内容、跨设备随机 identity 分叉或 decision commit 半完成。V2 尚未 cutover，可整片撤回未发行代码并重建非 production profile，但不恢复 V1 writer；灰度先仅在隔离 Local Folder／E2E profile 打开决定 UI，N-device manifest 与对等门禁转绿前不接 production App。监控只记录 conflict type、allowed-decision bitset、decision kind、result entity type 与计数，不记录任务正文、identity、payload 或路径。

## 2026-08-11 N-device resolution manifest 设计

- 需求：同一 immutable fork 被多台设备观察时，只允许一台设备要求用户作决定。其他设备必须验证并自动重放同一个决定，保留各自与该 fork 无关的本机事实；重启、不同发现顺序或多份等价 repair baseline 均不得再次弹出决定，也不得覆盖整份本机 snapshot。
- 现状证据：Endpoint 的 `observedHeads` 一遇 producer fork 就立即返回空的 blocked page，因此不会交付其他 producer 随后发布的 repair baseline。现有 Root 与 `ReplicationPublicationReference` 只携带 `basedOnResolutionID`，没有 exact conflict set、decision、decidedAt 或 typed result reference；`repairBaselinesAreAuthorized` 又只接受本机已经 closed 的 resolution。故第三台设备目前无法证明 baseline 代表什么决定，也无法安全自动 close 本机 resolution。
- 协议：repair publication 的 content-addressed Root 必须内嵌 canonical、不可变的 resolution manifest，包含 exact `resolutionID`、统一 `decidedAt` 与按 conflict ID 排序的 decision outcomes；outcome 包含 decision kind 和 typed result reference。Root digest、Seal 与 Announcement 现有链条共同保护 manifest。普通 publication 禁止携带 manifest；repair publication 必须同时携带 exact matching `basedOnResolutionID` 与 manifest，空 conflict 的自动 repair 使用空 outcome manifest。
- 分叉读取：blocked page 仍以原始 fork evidence 为 authority，但可额外交付从其他非分叉 producer chain 找到、且 `manifest.resolutionID == evidence.resolutionID` 的 immutable repair baseline。候选读取有数量／bytes budget，不能推进正常 cursor。多个候选若 manifest 不一致必须 fail-closed；相同 manifest 的重复 baseline 是幂等证据，不代表多个决定。
- 自动重放与原子性：接收端先把本机同一 fork evidence 持久化并重算 exact conflict set，再验证 manifest conflict IDs、allowed-decision matrix、decidedAt 与本机 set 完全一致。随后使用本机 authoritative snapshot 和 immutable branch graph调用同一个 deterministic decision resolver；本机计算出的 result references 必须逐项等于 manifest。只有重放结果及 baseline records 均无 waiting／new conflict 时，才在一个 SQLite transaction 内提交 engine-generation CAS、merged snapshot、cursor、decision outcomes 与 resolution close。不得直接以远端完整 snapshot 覆盖本机，也不得先 close 再 apply。
- seam 与门禁：公开症状 seam 固定为三份独立 SQLite store 共用一个 content-addressed Local Folder Endpoint：设备 A 产生 fork，设备 B 作出 `acceptRemote`／`copyAsNew` 混合决定并发布 manifest baseline，设备 C 不发送 decision command，仅 reconcile 后得到与 B 相同的决定结果，同时保留 C 的无关本机事实；C 重启后不得重复 apply 或恢复 actionable conflict。另覆盖缺 manifest、resolution mismatch、不同 manifest、结果 reference 篡改、stale engine generation 与中断原子性。
- 风险／回滚／灰度／监控：最大风险是把任意 baseline 当授权、选择竞争决定、远端 snapshot 覆盖本机变化或 close／cursor 领先于事实。V2 未 cutover，失败时整体撤回未发行 manifest slice并重建非 production profile；不恢复 V1 writer，也不新增旧 V2 wire format 兼容层。灰度只走隔离 Local Folder、签名 `e2e` 的全新 append-only round、再到双实体 Mac；上述门禁及长时观察全绿前不请求 production cutover。监控只记录候选数、manifest 验证结果码、自动重放 decision kind 计数、CAS 结果、waiting／conflict 数和收敛耗时分桶，不记录 resolution／conflict／entity identity、正文、payload、路径或原始 Error。

## 2026-08-11 durable worker lifecycle 设计

- 需求：`disable` 必须先成为 SQLite durable truth，再停止全部属于旧 generation 的工作。命令返回前必须完成 cancel + join；不允许 timeout、abandon、zombie 或伪造“已停止”。join 较慢时只投影非终态 `stoppingDelayed`，完成后自动消解。重启后的第一份 state 必须直接恢复 disabled policy，旧 generation 的任何 endpoint 晚返回均不得提交 publication confirmation、repair、download snapshot、cursor、成功时间或 warning。
- 现状证据：当前 Runtime 只持有内存 `enabled` Bool。`.disable` 先把内存 state 改为 stopping，然后调用 Endpoint `cancelAndJoin`，但 Runtime 不拥有正在执行 `.reconcile` 的 Task handle，也没有 SQLite control generation；reconcile 在 Endpoint `await` 后没有 generation fence，仍可继续调用 ledger／download commit。`restoreState` 只参考上次 UI state 与 pending rows，无法证明 disabled intent 与旧 worker 是否属于同一代。
- durable control：新增单一 `localFirst.replication.v2.control` metadata，canonical 保存 policy、严格单调 UInt64 generation 与 exact updatedAt。首次安装为 enabled generation 1；enable／disable 都在 `BEGIN IMMEDIATE` 内 compare-and-set 当前 generation 并增加一代。Runtime init 先严格解码 control，再据此推导第一份 worker state；损坏、溢出或 CAS mismatch 全部 fail-closed。
- worker 所有权：公开 `.reconcile` 不再直接借用调用者 Task 执行整条链，而由 Runtime 创建并持有唯一 generation-bound worker Task；并发 reconcile 只 await 同一 Task。disable transaction 成功后先发布 stopping、cancel worker，再调用 Endpoint cancel+join，最后 await worker 与 stopping monitor 全部退出，才持久化 disabled 终态。enable 只创建新 generation，不复用旧 Task。
- commit fence：旧 generation 每次跨 Endpoint await 返回后必须重新验证内存与 durable control；所有会写 replication ledger、download snapshot／cursor 或 Runtime state 的 SQLite transaction 都在持有写锁后检查 expected enabled generation。disable 若先取得写锁，则后到旧 worker 必须回滚；旧 worker若已经在 transaction 内完成，则 disable 随后持久化的新 generation 成为线性化点。不可变对象可能在 disable 线性化前已由 Endpoint 完成创建，但未确认 publication 会作为 durable pending 留待未来显式 enable，不得在 disabled generation 冒充成功。
- stoppingDelayed：disable 启动一个同 generation 的有界 heartbeat monitor；超过可注入的监控阈值只把 worker stage从 stopping 改为 `stoppingDelayed`，不取消 join、不改变 policy、不返回成功。join 完成后 cancel 并 join monitor；监控只记录 typed stage、旧 worker 是否仍在、pending count 与耗时分桶。
- seam 与门禁：阻塞 Endpoint 在 read／observe await 点受控停住；测试必须证明 cancel hook 看到 SQLite 已是 disabled 新 generation、stoppingDelayed 可观察但 disable command 尚未返回、释放 join 后旧 worker不能写 cursor／lastSyncedAt／confirmation，Runtime 重启首态为 disabled，显式 enable 后新 generation可重新 reconcile。另覆盖并发 reconcile 共用唯一 worker、disable CAS collision、control corruption、worker error 与重复 disable／enable。
- 风险／回滚／灰度／监控：最大风险是 generation 只检查在 transaction 外形成 TOCTOU、disable 与 worker互相等待、旧 worker覆盖 disabled state或 monitoring task 自身变成 zombie。V2 未 cutover，失败时整体撤回未发行 lifecycle slice并重建非 production profile；不恢复 V1 writer，也不新增兼容旧 control metadata 的猜测路径。灰度依次为阻塞 Local Folder tracer、签名 `e2e` 三次独立启动、真实 append-only iCloud cancel／restart，再到双实体 Mac。只记录 policy、generation 单调关系、stage、join 结果、pending count与耗时分桶，不记录 identity、路径、payload、正文或原始 Error。

## 2026-08-11 开发期 clean cut 与 App cutover 设计

- 用户决策：项目尚未发布，V1 sync path 与 V1 sync data 不兼容。取消 V1 staging importer、legacy remote reader、dual read／dual write、late-writer sentinel 和 runtime fallback。用户手工删除旧 iCloud 同步目录后重新同步是唯一重置路径；App、Agent、脚本与测试均没有删除权限。
- 本机资料与导入边界：App 只创建空白 schema 19 或打开 exact schema 19；v15、v17、v18 及其他非空 schema 全部在写入前拒绝，不运行 migration。数据包只接受 canonical current format 7；format 6 与其他历史格式全部拒绝。用户提供的 2026-08-11 压力验收备份已确认是 format 7，因此仍走当前真实导入路径。
- repository bootstrap：新增 canonical immutable V2 marker，只接受空目录或 exact marker + V2 object grammar。marker 以 exclusive-create-or-exact-match 建立，含 format version 与随机 repository generation ID；并发初始化的 loser 必须重读 winner，不覆盖 marker。读取 marker 后必须以 `lstat` 递归校验整棵 `v2` 子树、每层 inode type、generation／producer／sequence／digest／suffix grammar；任何 symlink、特殊 inode、未知 nested object、marker 缺失、不同 marker bytes 或边界逃逸全部在写入前 fail-closed 为 `legacyRepositoryRequiresManualReset`。
- 本机 authority：V2 不把 V1 `change_journal.sync_state`、receipt 或 frontier 当 protocol truth。SQLite 新增 V2 authority/outbox；首次启用在 engine-generation CAS 保护的 transaction 内安装 generation、producer 与完整 snapshot baseline，同时开启 post-baseline capture。之后每笔领域 save 在原 transaction 内把新 journal identity 映射到 V2 outbox；旧 V1 rows 不会被封装、改状态或删除。Runtime 若没有 exact clean-cut authority／generation 直接拒绝启动，不再读取 V1 pending journal、sealed journal ID 或 unfinished count 猜测恢复。baseline exact confirmed 前，post-baseline publication 不可发布。
- 崩溃边界：CAS 前中断时没有 V2 authority，可从最新 authoritative snapshot 重试；CAS 后中断时 baseline bytes、capture fence 和 outbox 都必须可从 SQLite 恢复。不允许出现“已开 capture 但 baseline identity 不存在”的持久状态。导入数据包前必须 shutdown + join Runtime；导入只保留 domain facts 与本机 device identity，然后重建全新 V2 authority/baseline，不保留旧 sync state。
- App 对等：`NoonmarkStore` 只持有 Runtime facade、转发 enable／disable／manual reconcile／endpoint／mode command，并订阅 durable state。automatic loop、confirmation retry、backoff、failure restore、shutdown join 和 status timestamp 全部收入 Runtime task tree。退出 App 使用保留 policy 的 `shutdown` generation fence，不把每次退出写成用户 `disable`。长时 iCloud 等待不再占用 `exclusiveEngineOperation`，本机修改持续可用。
- Endpoint 对等：Local Folder 与 iCloud Drive 都使用同一 content-addressed grammar、immutable announcement 和 marker，mutable head 禁用。真实自动化 iCloud 仍只能绑定全新 `Noonmark-E2E/AppendOnlyLiveTests/<session>/<round>/`；production root 只由用户启动的 production App 自然使用，不进入 Agent 验证。CloudKit V1 Store 属性、启动 automation、remote-notification callback、Settings 分支、live script 与 Make 入口均已删除；正式 App 不存在 CloudKit fallback。
- iCloud root 解析由独立 `ICloudDriveRepositoryLocator` 持有。正式 V2 Store、V2 endpoint 与 append-only test namespace 不再引用 `ICloudDriveSyncTransport`；旧 writer transport 不能借静态 helper 重新进入当前依赖图。
- 门禁：先红后绿覆盖非空旧目录零写入拒绝、空目录初始化、并发 marker、marker partial 后零写入 fail-closed、baseline/CAS 中断、baseline 前禁止 delta publish、capture 无缺口、导入重建、可重试 shutdown fence／endpoint join、退出/restart、手动／自动同步、状态时间戳、远端等待时普通 mutation 成功、真实 persistence failure 的 exact mutation 拒绝、旧 App writer 不可达，以及旧 iCloud inventory 不变。
- 风险／回滚／灰度／监控：最大风险是初始 baseline 遗漏并发本机 mutation、旧 journal 误进 V2、非空目录被误初始化、App 退出把 policy 关闭，或旧 Coordinator 仍可达。App cutover 前可回退未发行 V2 代码并重建非 production profile；不操作 iCloud 旧目录。灰度依次为临时 Local Folder、签名 `e2e` 全新 round、用户备份压力路径、`dmg-validation`、双实体 Mac 和 72 小时 soak。监控只记录 format verdict、baseline/delta 计数、outbox stage、worker stage、typed incident 和耗时分桶，不记录正文、路径、identity、payload 或原始 Error。

## 风险、回滚、灰度与监控

详细方案以 ADR-0047 为唯一架构来源。实施期若任何 tracer bullet 发现 approved invariant 不成立，立即停止继续铺代码，把假设转为运行证据并重新评审。

- App cutover 前可回滚隔离 profile 的 V2 runtime；不得触碰 production。
- App cutover 后只允许关闭同步和 roll-forward，不恢复 V1 writer，不增加历史兼容。
- 灰度顺序不可跳级；同机双 SQLite 不代替双实体 Mac。
- 监控只记录 typed code 与安全计数；不得记录 identity、digest、路径或 payload。

## 真实备份隔离压力验收

- cutover 前必须使用用户明确提供的真实备份，经真实 App 导入入口进入签名 `e2e` identity；不得直接写 SQLite、手工补 fixture 或启动 production App。备份正文、导出路径与任务 identity 不进入仓库、诊断、日志或测试报告。
- 每次压力验收创建全新的 `Noonmark-E2E/AppendOnlyLiveTests/<session-UUID>/<round-UUID>/`，debug／`e2e` App 的 Replication Endpoint 固定绑定该 round。禁止连接 `Noonmark/SyncRepository` 或其他既有根；禁止删除、覆盖、替换、移动、改名或清理任何 iCloud 对象，包括本轮新建对象。
- 导入成功后通过真实 App 用户路径执行有界但高密度的新增、编辑、领域删除／tombstone、排期、完成、附言、子任务、飞光、设置修改、立即退出、重启、前后台切换与重复同步。领域删除只追加 tombstone publication，绝不映射为 iCloud object deletion。
- 结构化观测至少覆盖 command／operation 数量、pending／sealed／confirmed／applied watermark、cursor、immutable object 数与 bytes、materialization waiting、CAS retry、fork、conflict、cancel+join、lastSyncedAt／lastEffectiveSyncedAt 和每轮收敛耗时；只记录 typed code、布尔值、计数、分桶耗时与不可逆摘要，不记录正文、路径、payload、原始 Error 或自由文本。
- symptom gate 必须对账导入前后 App 投影、SQLite authoritative snapshot、源／目标隔离资料库、重启后状态和 iCloud immutable inventory／digest。任何资料丢失、重复 apply、成功时间提前、无限 waiting、未闭合 task、mutable object、日志隐私哨兵或旧轮 inventory 改变都判红，并阻断 App cutover 与 DMG。

## 2026-08-11 真实备份压力结果与新增根因

- 首次签名 App import 暴露 `syncProtocol/403`：V2 完整 baseline 误用 ordinary mapper，而后者会正确拒绝无法携带 immutable commit history 的非空 classification state。新增 `ReplicationSnapshotRecordBuilder` 后，clean cut、空 repository reseed、双 watermark recovery 与 fork repair 统一携带 classification projection＋history；双 SQLite tracer 精确相等。
- 同一压力路径随后暴露 SQLite writer authority 分裂：同步与正常修改并发时，replication ledger 或 engine 任一方会在 `BEGIN IMMEDIATE` 收到 code 5。autocommit、显式 transaction、import replacement 与 schema prepare 全部收口后，path-scoped lock 仍被真实 App 证伪；最终 authority 提升为 NoonmarkStorage process-wide coordinator，不再依赖 repository／runtime／URL identity。
- 真实签名 `e2e` App 已导入 1,013 条任务。最终 exercise 完成 120 新增、80 修改、40 删除、71 次跨领域 mutation 与 367 次 reconcile；跨领域范围含 10 条备注、10 个计划子任务、10 次排期、5 组子任务及主任务完成、20／10／5 次飞光增改删和 1 次主题修改。restart 完成 30 新增、20 修改、10 删除与 56 次 reconcile。两轮 pending outbox 均为 0、convergence 均为 `converged`、最近同步与最近有效同步均存在、diagnostic failure 与 mutation rejection 均为 0。
- 资料包路径与正文未写入仓库、诊断或结果。门禁只接受调用者以环境变量传入的 absolute regular file，并复制到 canonical 隔离临时根。上述结果先在独立 SQLite 与 Local Folder V2 repository 捕获并关闭两项根因；它不是用户要求的最终 iCloud 压力验收。
- 根因修复后，append-only 真实 iCloud session `d4b8f14b-daa0-4dd6-925a-6c48b93792e9` 的两个全新 round `9b53cc57-d65b-4fdd-9b52-f67ca527cad0` 与 `9d77d3ba-ee49-486b-a11b-b8c27a274867` 在 55.802 秒内通过。每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 mutable head，目标 SQLite 收敛且重启零重复 apply；第一轮 inventory／digest 在第二轮后保持不变，所有对象永久保留。

## 2026-08-11 真实备份 × 签名 App × iCloud 最终 seam

- 原始缺口证据：`scripts/test-replication-v2-app-stress` 与 `ReplicationV2StressE2EAutomation` 曾把 endpoint 固定为 `.localFolder`；单独的小型 iCloud tracer 虽证明 Adapter 与 append-only protocol，却没有证明用户提供的 1,013 条任务 baseline、同步中修改及 300 次后续 mutation 能经真实 iCloud 收敛。因此补齐本 seam 前不得宣称最终完成。
- 边界：脚本只生成不可预测的 session／round UUID；签名 `e2e` App 自己通过 `ICloudAppendOnlyTestNamespace` 在固定容器的 `Noonmark-E2E/AppendOnlyLiveTests` 下独占创建。首次 exercise 只允许创建不存在的 exact session／round；restart 只允许严格重开相同 existing round。任意 production identity、任意路径参数、既存 round、边界逃逸或 symlink 均 fail-closed。
- Runtime seam：仅当 bundle identity 为 `app.noonmark.mac.e2e` 且存在专用 stress launch contract 时，`.iCloud` Endpoint 才可由 exact `ICloudAppendOnlyTestRound` 构造；正式 App 继续只按 profile repository name 构造。自动化不把 iCloud 路径传给 App，也不允许 `--sync-folder-url` 冒充 iCloud。
- 验证：同一 fresh round 贯穿 exercise 与 verify-restart，执行已经转绿的完整资料导入、同步中首笔正常修改、120／80／40 与重启后 30／20／10 增删改，并覆盖备注、计划子任务、排期、完成、飞光、主题设置，以及每轮 exact confirmation、pending outbox、成功时间、diagnostic failure、mutation rejection 和 restart state 对账。脚本先在本机独立 SQLite／V2 repository 对同一资料运行相同领域操作，成功后才允许创建新 iCloud round。测试自然日从资料包最大领域日期的下一天确定，预检、exercise 与 restart 共用相同 fixed-clock，避免把锁定历史日误当可写日。所有远端 publication 只追加；测试结束永久保留整轮对象。
- 风险／回滚／灰度／监控：最大风险是内部参数绕过 profile root、restart 意外重新创建 round、真实 iCloud 等待导致假成功，或为了清理测试现场引入删除能力。回滚只撤回未发行 E2E seam并保留全部 iCloud 对象；灰度固定为 Local Folder 压力已绿 → 小型真实 iCloud 两轮已绿 → 本 seam 单轮全量压力 → 双实体 Mac／72 小时 soak。监控沿用有界 typed 计数，不落盘资料正文、路径、identity、payload 或原始 Error。
- 运行结果：签名 `e2e` App 在全新 session `f023782c-f246-4da9-84eb-3b96a95a5d61`、round `f4eb346c-ae6d-4b72-89e6-5b3be704d1f4` 完成最终 seam。exercise 真实导入 1,013 条任务，完成 120 新增、80 修改、40 删除与 381 次真实 iCloud reconcile，440／440 outbox confirmed；verify-restart 完成 30 新增、20 修改、10 删除与 66 次 reconcile，550／550 confirmed。两阶段 pending 均为 0、convergence 均为 `converged`、最近同步与最近有效同步均存在、diagnostic failure 与 mutation rejection 均为 0。
- 扩域过程如实保留三轮失败现场：session `13bbbcba-f79c-4f29-bd7c-0029ce5156cd` 的 round `7912fa0a-19da-4835-90cc-7b8561dd48e3` 揭露测试先完成父任务却未完成复制出的子任务；session `c31cb7a3-cfa3-43d7-8dbc-007e06fb393b` 的 round `6709ad81-8663-468b-8ec1-f1e0f71dfde3` 首次把失败收窄至排期阶段；session `3b860064-413c-4cf3-8dd0-8e29ab870bdd` 的 round `a2c1f780-d462-4244-9f4c-e8c14a3a0166` 进一步证明 e2e 默认 fixed-clock 落在已锁定历史日。三轮同步诊断均为 0 failure、0 mutation rejection；它们是门禁场景错误，不是 V2 同步重新失败，且所有远端对象永久保留。
- 修正后的最终扩域运行使用资料包最大日期下一日作为测试自然日。签名 `e2e` App 在全新 session `4e2626e3-d8cb-4400-9ef7-5b9549d4db0e`、round `a7575dc2-61f8-465c-966b-19614462ac08` 导入 1,013 条任务；exercise 完成 120／80／40 增改删、71 次跨领域 mutation 与 367 次 reconcile，542／542 outbox confirmed；verify-restart 完成 30／20／10 增改删与 56 次 reconcile，652／652 confirmed。两阶段 pending 均为 0、convergence 均为 `converged`、最近同步与最近有效同步均存在、diagnostic sync failure 与 mutation rejection 均为 0。
- 不可变性结果：该 round 只由 content-addressed exclusive-create-or-exact-match Endpoint 写入，mutable head 禁用；guard 与源码门禁确认没有 remote delete／replace／move／rename／cleanup API。测试退出只删除本机临时 SQLite 与资料包副本，整份 iCloud session／round 及其中全部 immutable object 永久保留。
- 第二消费者扩域首先暴露 provenance 内层对完整批次反复 validation／decode／context canonicalization：4,015 条 record、约 200 个多版本 identity 令单轮 merge 耗时 `224067 ms`。重构后完整 context 一次建立；非授权敏感 fold 直接复用，只有 taskChain／dayTrace 状态转换从已验证、已解码 facts 建立 reduced context。deterministic 门禁由 `9.359 s` 降至 `0.059–0.067 s`。
- 精确 snapshot 对账随后证明所有领域实体与分类状态一致，唯一初始差异是 device-local preferences；旧 oracle 错把来源设备的备份、同步端点等本机设置当成 replicated state。修正后的 ground truth 精确同步主题／语言及版本，同时要求 target 的 dataMode、backupPolicy、localFirstSyncPolicy、settingsPoemDisplayPolicy 与 syncEndpointOptions 原样保留；失败输出只保留计数、UUID 与 digest，不再展开业务正文。
- 最终闭环运行在全新 session `cf9ba92f-6303-4db7-aace-ae2d18686918`、round `790ec257-01bb-4666-9f15-4259adf66777` 完成。exercise 导入 1,013 条任务并执行 120／80／40 增改删、71 次跨领域 mutation、361 次 reconcile，542 份 outbox confirmed；verify-restart 再执行 30／20／10 增改删、56 次 reconcile，652 份 confirmed。两阶段 pending、diagnostic sync failure 与 mutation rejection 均为 0，convergence、最近同步与最近有效同步全部成立。
- 同一最终 round 的第二 SQLite 首轮 `43462 ms` 应用 18 份远端 publication，下一轮 `204 ms` 把自身 baseline confirmed 且 pending 归零；重启轮 `188 ms`、remote apply 为 0。完整领域资料与共享 preferences 精确一致，target device-local preferences 保持不变。第二消费者进入前的 198 个 immutable 文件全部保留原 digest，最终只追加至 206 个，零 mutable head；整轮永久保留。

## 2026-08-11 V2 App 生命周期与诊断 clean-cut 结果

- cutover audit 最终发现 Preferences 与诊断 E2E 仍依赖 V1 coordinator、status metadata、repository lock、mutation rejection 和 persisted-failure restore race。上述 seam 已全部删除；fast gate 对 App 与聚合脚本执行 forbidden search，V1 automation 不再作为 V2 发行证据。
- 新的 `ReplicationV2LifecycleE2EEndpoint` 只在 exact `app.noonmark.mac.e2e` 加专用参数时包裹真实 Endpoint，可注入 read failure、blocked read 和 cancel join。它不建立第二套 ledger／Runtime，也不改变 production identity 或 endpoint。
- Preferences 三进程真实签名路径已证明：baseline 收敛且最近同步／最近有效同步有值；V2 failure 形成 typed incident；endpoint wait 期间 task mutation 成功；物理 checkbox 触发 stopping 并等待 join；释放后 durable disabled、incident／warning 清除；重启首态 disabled 且 warning suppressed；显式重新启用后 retry 至 converged。SQLite probe 为 `1 1 0 4 1 1 0`。
- 诊断三进程真实签名路径已证明：真实 V2 failed capsule → `transportPrepare` endpoint wait → 本机 mutation committed → exact SIGKILL → restart interrupted capsule／event → Help 菜单导出。导出包容量与私隐哨兵通过，最终 evidence manifest 为 `suite_exit_status=0`，没有新增系统 crash report。
- 通用 E2E 现在强制使用调用者提供的 absolute regular provisioning profile、Data Protection Keychain signing 与 stable UI signing；缺失 entitlement 在 App 启动前 fail-closed，不以 in-memory watermark 降级。
- V2 Local Folder transport 的 permanent stage／hardlink final 属于协议状态，不进入诊断 artifact root。证据 helper 继续拒绝 multi-link file；诊断 transport 使用本轮独立临时根，helper 的 `.repository.lock` 只保留在证据 scope，退出后精确回收临时根。整个本轮只使用 Local Folder 和非 production profile，没有创建、修改、移动、覆盖或删除任何 iCloud 对象。

## 2026-08-12 本机闭环结果

- 最终签名 App 压力运行使用全新真实 iCloud session `aee5e99d-e511-48e3-9835-51d3ef3cd4`、round `4ab4673c-8bf8-4587-b6f1-dacc1ef89e20`。exercise 导入 1,013 条任务，完成 120／80／40 增改删、71 次跨领域 mutation 与 42 次同步；542 份 outbox 全部 confirmed。restart 再完成 30／20／10 增改删与 48 次同步；652 份 outbox 全部 confirmed。两阶段 pending、diagnostic sync failure 与 mutation rejection 均为 0，最近同步、最近有效同步与 convergence 全部成立。
- 同一 round 的独立第二 SQLite 首轮 apply 14 份 publication，重启 apply 0；第二消费者进入前的 168 个 immutable 对象全部保持原 digest，结束时只追加至 176 个，mutable head 为 0。整轮对象永久保留，没有删除、覆盖、替换、截断、移动或改名。
- 最终独立 live adapter session `833463b3-4c06-491a-b4e6-3f87927d2e67` 的两个全新 round `16dad330-3a25-4f3d-ae5d-0ece4924d224` 与 `993fbaa2-d503-4694-8a36-55cc29ac3109` 各创建 18 个 immutable 对象、0 mutable head；前轮 inventory／digest 在后轮后不变，所有对象永久保留。
- 扩大完整 E2E 时另定位两项非同步业务根因：烛龙 pending-gate 仍要求已经退役的 V1 baseline journal；共享 WindowServer 输入驱动把 AppKit key window 错当作物理最前窗口。前者改为 schema 19 clean-cut 正向 oracle；后者在任何 mouseDown 前要求 exact physical hit window，并以签名 App native-command exercise／restart 连续 8／8 轮通过证明。
- 完整签名 App E2E 运行 `20260812T021133Z-72054` 覆盖 48 个场景、英文 10／10、烛龙 pending gate、current format 7 导入、诊断异常终止闭环、V2 lifecycle 与两次 Search，`suite_exit_status=0`；source start／end、App binary、helper binary 均一致，新增 DiagnosticReports 为 0。
- 完整 `make check` 运行 `20260812T022243Z-83938` 以 `suite_exit_status=0` 结束；source start／end worktree OID 一致，104 个故障案例门禁通过，SwiftFormat 为 0／499。SwiftLint 没有 error；允许的既有 warning 不作为成功替代，真实症状证据以上述签名 App 与 iCloud 运行产物为准。
- 审查整改后的完整签名 App E2E 运行 `20260812T035748Z-64356` 再次覆盖 48 个场景、英文 10／10、V2 lifecycle、同步失败／endpoint wait／正常 mutation／真实 persistence rejection／异常终止／重启／诊断导出闭环，`suite_exit_status=0`；source start／end worktree OID、App binary 与 helper binary 均一致。随后完整 `make check` 运行 `20260812T041033Z-39844` 以 `suite_exit_status=0` 结束，source start／end worktree OID 一致。
- 审查整改后的最终真实压力链先在签名 App Local Folder 完成 1,013 条导入、exercise 120／80／40 增改删与 71 次跨领域 mutation、restart 30／20／10 增改删；两阶段 542／652 份 outbox 全部 confirmed、pending 为 0、最近同步与最近有效同步均存在、diagnostic failure 与 mutation rejection 均为 0。其后才创建 iCloud session `53cf43bf-e3cd-4e84-a64e-932d99ec954f`、round `fe9e23b9-9a1a-4a38-9bf5-870d8959557b`，以相同操作得到相同领域结果；第二 SQLite 首轮应用 7 份 publication、重启应用 0，进入前 112 个 immutable 对象全部保持原 digest，最终只追加至 120 个，mutable head 为 0。
- 最终独立多轮 adapter session `1bc4817c-1a1b-4b56-8ede-1b371676ccee` 的两个全新 round `b0b5436f-e5ec-4840-aafd-9e1d5ae5d18d` 与 `2cc42e7c-e482-4a55-8a97-0b665af5e033` 各创建 18 个 immutable 对象、0 mutable head；每轮均经 Apple positive evidence 收敛，前轮 inventory／digest 在后轮完成后保持不变。以上全部 iCloud 对象永久保留，没有删除、覆盖、替换、截断、移动或改名。
- 当前尚未完成的不是本机实现或本机验证，而是治理与跨设备门禁：修复 commit 尚未建立，双实体 Mac 与连续 72 小时 soak 尚无运行产物。因此不得宣称 production cutover 或 release ready；同机双 SQLite 只证明协议与领域收敛，不冒充双实体 Mac。

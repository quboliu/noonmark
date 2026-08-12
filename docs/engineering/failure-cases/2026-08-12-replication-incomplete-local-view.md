# FAIL-2026-08-12-03：同步把不完整本机文件视图误作远端权威事实

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-12；全仓静态 audit M3／M4，随后由公开 transport seam 运行复现
- 影响版本／构建：未发行的 `main`；Replication V2 自 `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73` 至 `79e684a`
- 引入提交：M3 为 `1f264ff9c38047c8ac959e9d0cd624c70d495116`（`fix(sync): replace full-history replication`）；M4 为 `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）
- Git author／committer：M3 为 `mxt <mxt@local.com>`／`mxt <mxt@local.com>`；M4 为 `quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；仓库只能证明 Git identity，不能证明实际操作者
- 修复提交：`3834260aec6707f65ec4d5b65654df2e606200b7`（`fix(sync): recover incomplete replication views`）

## 用户症状与影响

第一条路径在 immutable batch 已 fsync、mutable head 尚未发布时崩溃。用户继续修改后再同步，Local Folder transport 重用 head 推导出的同一 sequence，把自己上一次崩溃留下的完整 batch 误判为 hostile fork；每次 retry 都在同一位置失败，上传永久停滞。

第二条路径发生在 V2 iCloud 接收端。若 sequence 1 与 3 已在本机可见、sequence 2 的目录或 announcement JSON 尚未 materialize，endpoint 把第一段连续 prefix 当成完整链并回报 stable／`hasMore=false`。即使 announcement 后来可见，它引用的 seal／root／chunk 也可能继续乱序缺失；旧错误不携带精确对象 key，系统仍无法主动请求。接收端因此看似追平或进入不可自愈 runtime failure，但 sequence 2 以后事实没有被应用。

M3 的 `LocalFolderSyncTransport` 已不属于正式 App 的 V2 writer，但仍是现存公开 transport 与旧测试路径；M4 位于正式 App 当前使用的 `ContentAddressedFileReplicationEndpoint`／`ICloudDriveReplicationEndpoint`。两者共同暴露同一结构缺陷：局部文件系统 observation 被直接提升为远端协议 truth。

## 时间线

- 2026-08-08T01:00:15-04:00：`1f264ff9` 建立 head 推导 sequence、batch 先于 head 发布及 existing bytes mismatch → fork 的组合，但只覆盖 exact retry。
- 2026-08-12T00:50:04-04:00：`6a16e02` 建立 V2 immutable announcement chain；连续扫描遇到缺号便静默结束。
- 2026-08-12：静态 audit 报告 M3／M4；源码与 Git history 复核确认两者引入来源不同。
- 2026-08-12：M3 tracer 在 batch 1 写完、head 缺失、retry 内容改变时稳定得到 `producerFork(sequence: 1)`。
- 2026-08-12：M4 tracer 只物化 sequence 1／3 时稳定得到 stable chain-end；目录 2 已出现但 JSON 缺失时又被误判为 fork／invalid object。
- 2026-08-12：独立 Standards／Spec review 发现 fixture 把 announcement 与其跨目录引用对象一次性全部物化，掩盖了 seal／root／chunk 的同根缺口；同时确认最高空目录可能只是 announcement publish 崩溃遗留，不是远端 promise。
- 2026-08-12：补齐逐 item materialization 与 terminal orphan 反向边界后，七条 tracer 全部转绿。
- 2026-08-12：完整 `make check` 在具备 `/bin/ps` 与 Git index 权限的环境首次通过，确认先前中断只是受限沙箱所致。
- 2026-08-12：提交后双轴 review 以 Foundation 运行产物证实读取期缺失会返回 Cocoa 260，而初版只识别 FileManager code 4；案例维持处理中，补齐同根映射与第八条 tracer 后重新验证。
- 2026-08-12：最终修复提交 `3834260aec6707f65ec4d5b65654df2e606200b7` 完成；相同提交上的第二轮完整 `make check` 于 `2026-08-12T17:16:51Z` 以 `suite_exit_status=0` 结束。

## 复现与证据

- `LocalFolderSyncTransportTests.testCrashAfterBatchWriteWithChangedRetryAppendsAfterOrphan` 使用真实临时 repository 与既有 `.didPublishBatch` fault point。修复前第二次 push 精确抛出 `producerFork`；没有 mock transport 内部 collaborator。
- `LocalFolderSyncTransportTests.testPostProbeCompetingWriterStillFailsClosedAsProducerFork` 在 sequence probe 后、immutable create 前注入互斥 bytes，证明真正竞争仍由 `.withoutOverwriting` 判为 producer fork。
- `ContentAddressedFileReplicationEndpointTests.testAnnouncementGapCannotBeReportedAsAStableChainEnd` 通过真实 `ReplicationPublicationBuilder` 建立 sequence 1 → 2 → 3，只把 1 与 3 的 immutable objects 放进接收视图。修复前 read 成功回报稳定链尾，直接捕获静默截断。
- `ContentAddressedFileReplicationEndpointTests.testICloudAnnouncementGapRequestsTheExactMissingSequence` 保持 sequence 2 目录完全缺失。fixture 每轮只物化本次精确请求的 item：先 announcement sequence 目录，再依 read dependency 顺序逐个物化 seal、root 与 chunk；每一轮都必须保持 origin cursor、`hasMore=true`，全部引用齐备后才可一次取得 1／2／3 并回报 stable。
- `ContentAddressedFileReplicationEndpointTests.testICloudReadTimeMissingObjectRequestsExactMaterializationTarget` 在 `fileExists` 已成功后的读取系统边界注入 Foundation 实际使用的 Cocoa 260；iCloud wrapper 必须保持 origin cursor、请求精确 seal key 并回报 waiting，下一轮读取再稳定收敛。
- `ContentAddressedFileReplicationEndpointTests.testMaterializedInternalSequenceDirectoryWithoutAnnouncementCannotCloseChain` 覆盖相邻同根边界：sequence 3 已见、sequence 2 目录存在但 JSON 仍未物化时，只能回报 typed gap，不能静默丢弃该 sequence evidence。
- `ContentAddressedFileReplicationEndpointTests.testEmptyTerminalSequenceDirectoryIsNotAPublicationPromise` 证明最高空目录不会被提升为远端 promise；它可能只是 publisher 建目录后、final link 前崩溃留下的永久 orphan。
- 全部 fixture 只使用独立临时目录；没有启动、读取、定位、reset 或写入 production，也没有接触真实 iCloud。

## 排除的假设

- 不是正常 fork：M3 orphan 的 producer、sequence、previous hash、canonical body hash 与当前已验证链完全衔接；已发布 head 或链 hash 不一致仍会失败。
- 不是 V2 已有另一个 authoritative tip：ADR-0047 与当前源码都明确禁止 mutable head，immutable announcement 是唯一发现事实。
- 不是 `hasMore` 文案问题：旧 read 已把 cursor／stable observation 交给 Runtime；必须在 endpoint truth boundary 阻止稳定闭合。
- 不是只缺 sequence directory：较低目录存在但 JSON 尚未物化时，0 个文件同样不是“两份 branch”的 fork 证据。
- 不是下载 announcement 目录就会连带下载 publication：content-addressed seal／root／chunk 位于独立 `v2/objects/...` 路径，必须按 announcement 引用逐个请求。
- 不是所有空目录都证明 incomplete remote chain：只有已见更高 sequence 才能把较低空目录定性为 gap；terminal 空目录没有有效 announcement，不是同步事实。
- 不是 production `NSFileCoordinator` 失败：受限临时目录不能代表签名 iCloud container；fixture 只注入 materialization system boundary，正式 initializer 继续固定 coordinated read。
- 不是只有 `NSFileNoSuchFileError` code 4：本机 Foundation 运行产物证明 `Data(contentsOf:)` 对缺失文件返回 `NSCocoaErrorDomain` code 260；POSIX `ENOENT` 也属于同一 typed incomplete observation。

## 根因与破坏机制

两个实现都没有把「本机目前看见什么」与「远端协议已经证明什么」分层。M3 只从 head 分配下一 sequence，却没有验证并接回 head 之后的完整 immutable prefix；M4 只从一次 directory listing 推导 tip，缺号、内部缺 JSON 或 announcement 引用对象缺失都没有带精确目标的 typed incomplete observation。结果是同一类暂态分别被误报成永久 fork、稳定成功或不可自愈 runtime failure。

## 根因修复

- Local Folder push 在 repository lock 内从已验证 head 后逐 sequence 探测。每个 existing successor 都必须通过 exact producer、sequence、previous hash、body digest 与 file digest 校验后才可成为 recovered prefix；本次内容追加到首个空槽，head 最后一次指向完整连续链。existing destination 在 probe 后发生不同 bytes 竞争时，原 `publishImmutable` fork 检查继续 fail-closed。
- V2 endpoint 先只验证 sequence directory grammar并排序，再检查 `1...highestObservedSequence` 是否连续；内部缺号回报带精确 missing sequence 与已知上界的 `announcementGap`，不再进入 stable read。
- 已见更高 sequence 时，较低 sequence 目录中 JSON 为 0 同样回报 gap；最高空目录没有有效 announcement，因此保持非事实。任一 sequence 出现两份或以上 JSON 仍是 producer fork，既有双 branch evidence 路径保持不变。
- content-addressed reader 对完全缺失或读取期间消失的精确引用对象回报 validated repository-relative key；FileManager code 4、Cocoa file-read code 260 与 POSIX `ENOENT` 统一进入同一 typed observation，不再泄漏 raw error 或丢成无定位信息的 `missingObject`。
- iCloud wrapper 捕获 sequence gap 或引用对象缺失后，只对精确目录／item 调用 `startDownloadingUbiquitousItem`，返回 `awaitingMaterialization`、`hasMore=true`、零 publication 与原 cursor。完整 dependency chain 补齐后的新一轮读取才可回报 stable。

## 验证结果

- 聚焦 incomplete-local-view gate：8 项、0 失败；覆盖 changed retry、post-probe 真竞争、directory／内部 JSON gap、announcement 与引用对象逐项 materialization、读取期 Cocoa 260、terminal 空目录非事实，以及同 sequence 双 digest fork fail-closed。
- `NoonmarkSyncTests` 执行 319 项、0 失败；此前受限沙箱中的 Keychain OSStatus `-25291` 已不再出现，真实 Keychain session tracer 同样通过。
- `NoonmarkStorageTests` 执行 307 项、0 失败；2 项明确要求 `NOONMARK_LIVE_ICLOUD_SYNC=1` 的实体 iCloud 测试按设计未启用。本任务没有授权或执行真实 iCloud round。
- endpoint 最终修正后再执行 `LocalFirstReplicationTests` 29 项、0 失败，覆盖 V2 runtime、fork、restart、waiting 与双 SQLite 收敛。
- Standards／Spec 双轴 review 找到的跨目录引用对象、terminal 空目录与读取期 Cocoa 260 问题均已补门禁；实现没有剩余高／中风险 finding。review 同时指出当前 symptom gate 尚未经过签名 App 的真实 iCloud 用户路径，因此案例不能标记为已修复。
- 原样 `make check` 在修复提交 `3834260aec6707f65ec4d5b65654df2e606200b7` 完整通过：Swift build、UT、IT、ST、1593 项 system tests（2 项明确 live iCloud 测试按设计未启用）、确定性仿真、Replication V2 recovery、107 个 failure-case mapping、SwiftLint 与 SwiftFormat 均执行完成；evidence run `20260812T165709Z-37229` 的 `suite_exit_status=0`，开始与结束的 HEAD／worktree tree OID 各自相同。SwiftLint 只有仓库既有的非阻断 warning，SwiftFormat 为 0／499 个文件需要格式化。
- `make check` 只 reset 固定隔离的 `audit` profile，并明确保留 iCloud；两项要求显式 live 开关的实体 iCloud 测试按设计未启用。本任务没有授权或执行真实 iCloud round、production App、DMG 打包或发行流程。

## 永久门禁

- fast：`scripts/test-replication-incomplete-local-view` 直接执行当前 Local Folder 与 V2 content-addressed／iCloud public seams，并静态绑定真实 App 目前选择的 `ICloudDriveReplicationEndpoint`／`ContentAddressedFileReplicationEndpoint`，同时保留现有真正 fork tracer；由 `scripts/test-replication-v2-recovery-contract` 强制调用，后者由 `scripts/check` 强制调用。
- symptom：同一 gate 以真实临时 filesystem、immutable publication bytes 与 materialization boundary 重放原始崩溃／乱序症状；由 `scripts/test-all` 强制调用。未来 rewrite 若删除或绕过当前 V2 endpoint，具名测试会在编译、filter 或行为断言处判红。

## 待闭环事项

当前 fast gate 与 transport-level symptom gate 已稳定转绿，但还没有在签名 `e2e` App 的真实用户同步路径中重放 announcement／object 乱序 materialization。该证据不能由临时 filesystem fixture、静态 App binding 或 `make check` 中的 signed-App contract 代替。由于本任务明确禁止接触真实用户 iCloud，也没有授权开启 append-only live iCloud round，案例保持「处理中」。后续只有在先通过 append-only 静态门禁与本机症状门禁后，使用全新 session／round UUID，在获授权的 `Noonmark-E2E/AppendOnlyLiveTests/...` 路径完成真实 signed-App symptom gate 并登记到 `gates.tsv`，才可改为「已修复」；测试对象永久保留，不得清理。

## 发行与回滚

风险等级为 P：涉及同步资料完整性、hash-chain、fork 与 iCloud waiting truth。完整 fast／symptom 门禁全绿前不得发行或进入真实 iCloud 新 round。回滚只可撤回本地未发行修复提交；不得删除、覆盖、移动、改名或清理任何现存 repository 对象，也不得恢复 V1 writer。灰度固定为临时 filesystem → 完整 Sync／Storage → 签名 `e2e` App → 用户另行授权的 append-only 实体 iCloud 门禁。监控只记录 typed waiting、known sequence gap、fork count、pending 与 cursor distance，不记录 producer identity、digest、路径或 payload。

## 教训与永久约束

append-only transport 的 filesystem listing 只是 observation，不是 completeness proof。链尾必须由连续已验证 announcement 与其完整引用对象得出；已知后继前的缺口永远不是成功，未被有效 announcement 引用的 terminal orphan 也永远不是 promise。fork 必须有两份互斥且完整的 immutable evidence，不能用「当前看不见」代替。每个 crash window 与 lazy-materialization window 都必须在当前 public seam 保留可运行 tracer，而不是依赖已 cutover 的旧 coordinator。

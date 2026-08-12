# 以 durable replication runtime 收口同步协议状态

**Status**: Accepted

**Task-ID**: `noonmark-local-first-replication-v2`

ADR-0046 把同步从全量 mirror 改为 durable incremental replication，但协议正确性仍分散在 App、RunController、LocalFirst／Upload／Download Coordinator、SQLite Repository 与 transport。build 29 进一步证明现有 Interface 仍然过浅：上传层把已经发布的 journal rows 按 receipt 无序分组，Repository 却要求每次调用都从当前本机 frontier 的下一 sequence 开始形成连续前缀。iCloud 合法的乱序或部分 confirmation 因而被误判为资料损坏；App 又自行拥有 retry、failure restore、worker task 与 stopping 状态，无法由一个 durable truth 重建。

## Decision

### Deep Module 与 Interface

- 建立 `LocalFirstReplication` Deep Module。App Interface 只提供 `send(_:)` 与 `states()`；App 只转发用户 command 和投影 durable state，不得再编排 transport、receipt、frontier、baseline、confirmation retry、failure restore、journal recovery或 worker 生命周期。
- `SQLiteReplicationLedger` 是协议状态唯一的 durable truth。Runtime actor 只拥有可由 ledger 重建的 reactor task；纯 `ReconciliationKernel` 根据 durable snapshot 与 Endpoint observation 计算 transition，所有 transition 由 ledger 在一个 SQLite transaction 中验证和提交。
- Endpoint Seam 只提供幂等 `publish(sealed:)`、集合化 `observe(pending:)` 与增量 `read(after:budget:)`。`read` 必须区分 stable observation、等待 promised-item materialization 与 producer fork，不得用通用异常让 App 猜测协议状态。Adapter 只认识 validated relative key、canonical bytes、byte count、digest 与 provider typed evidence，不认识领域 Outbox、frontier 或 UI 状态。
- `SQLiteEngineRepository.save(...recordingChangesFor...)` 继续作为领域 mutation 与 canonical local event 的同事务入口。`SyncRecordMaterializer`、`SyncRecordMerger`、`CurrentSyncRecordMerger` 与 `ValidatedSyncSnapshot` 作为 Deep Module 内部实现资产保留，不再成为 App 可见编排点。

### Sealed publication 与可发现性

- 任何远端 I/O 前，ledger 必须先封装 stable publication identity、repository generation、per-install producer epoch、sequence、previous digest、canonical records 与 body digest。
- publication 由一个或多个 immutable content-addressed chunk、一个 root manifest 和一个 seal 组成。chunk 与 root 可乱序到达；只有 root 覆盖的全部 chunk 通过 digest 校验且 seal 有效，publication 才成为可 apply 的同步事实。
- Endpoint Adapter 只能 append-only-stage-link-or-exact-match。每份 bytes 先写入唯一且永久保留的 staging key，完整 `fsync` 后以不覆盖的 `linkat` 原子建立最终 key；中断不得暴露半写最终对象。内容寻址 key 与 bytes／digest 不一致属于 typed corruption；同一 `(generation, producer, sequence)` 的不同 digest 必须保留为 fork evidence，不能覆盖、任意选 winner 或 LWW。
- immutable announcement 是唯一可发现性事实。V2 不建立 mutable head、可变索引或 repair-on-read 写路径；producer tip 只从完整 announcement chain 计算。
- 不实施远端同步 storage GC。local-only tombstone 保留在产生它的安装；只有未来具备 consumer acknowledgement、设备退役与 checkpoint 协议，并再次获得用户批准后，才可讨论远端删除。这与 Go／Java runtime GC 无关。

### Confirmation 与 Apple evidence

- confirmation 以 immutable artifact identity、digest 与 control generation 幂等、集合化落盘，允许重复、乱序与部分到达。confirmed 一旦持久化便单调不回退；placeholder、下载驱逐或 metadata 暂时不可用只影响本轮 observation，不撤销既有确认。
- ledger 从 durable self watermark 后计算最长连续 confirmed prefix。后继 confirmed 而前驱 pending 是诚实 waiting，不是 corruption；前驱随后 confirmed 时，同一个 transaction 一次推进整个连续前缀。
- iCloud Drive Adapter 只有在 publication 与其 immutable announcement 都满足以下条件时才可返回 confirmed：exclusive-created relative key 与 canonical byte count／digest 精确匹配当前 generation；Apple `isUbiquitous == true`、`isExcludedFromSync == false`、无 unresolved conflict、`isUploading == false`、`isUploaded == true` 且 `uploadingError == nil`。missing、unknown、placeholder、uploading 或 observation incomplete 一律返回 typed waiting。由于远端 key 不允许覆盖，`isUploaded` 不可能被同一路径旧 generation 冒充。
- quota error `4354` 是 user-attention；server unavailable `4355` 是 retryable waiting。未知 upload error 不得确认，也不得永久污染健康 Outbox。
- iCloud discovery 必须与运行身份的实际 capability 绑定。已获授权的 app ubiquity container 可以在精确 generation predicate 下等待 `NSMetadataQueryDidFinishGathering` 后冻结 observation；CloudDocs mirror fallback 不得调用只有 app-container entitlement 才能返回资料的 ubiquitous query scope，也不得把其空结果解释成 repository 为空。fallback 只枚举精确 repository／测试 round，fetch 针对 promised-item URL 请求 materialization，并在 coordinated read 内校验 byte count 与 digest。materialization 尚未完成时，read page 返回 typed waiting、不推进 cursor、不建立 incident；任何 deadline 只可令门禁失败，不能把 pending 转成 confirmed。
- Apple evidence truth table 与本机 Xcode SDK／官方文档无法证明上述 positive 时，iCloud Adapter 必须保持 unavailable，不得进入 default／production endpoint。

### Fork、repair 与多设备收敛

- stable re-read 仍出现同一 producer／sequence 的不同 digest 时，建立 typed actionable `producerForkDetected` incident，并阻断 endpoint verified、watermark 与成功时间戳。
- resolution durable state 固定为 `detected → branchesValidated → branchesApplied → domainConflictsResolved → closed`。Endpoint 必须完整验证从首次分叉点开始的整个 immutable branch graph：每个 announcement、seal、root 与 chunk 都可达前一 sequence 的 exact seal；按 `sequence + seal digest` 排序后的完整 publication reference 集合形成与发现顺序无关的 deterministic `resolutionID`。任一 branch 后续追加 descendant 都产生新的 resolution，不得被既有 incident 或 resolved cursor 忽略；Runtime 在公开 incident 前至少持久化至 `branchesValidated`。原 producer frontier 冻结在 common prefix；新 producer epoch 可以建立 identity，但在同一 `resolutionID` durable closed 前不得 seal／publish 第一份 baseline。
- resolutionID 必须是 immutable fork evidence 对及 common prefix 的确定性函数。repair 自动重放双分支；存在 typed 领域冲突时保持 incident 打开，等待用户决定。没有领域冲突时可自动进入 closed，但必须保留安全审计事实。
- 无冲突 repair 的领域 snapshot、resolved cursor 与 resolution close 必须在同一 SQLite transaction 提交；merge 出现 waiting 或 conflict 时三者全部不提交。close 后 Runtime 从 authoritative snapshot 建立携带 `basedOnResolutionID` 的完整 baseline，以本机 producer chain seal／publish／exact confirm，再取得一轮空增量 observation 后才允许 convergence success。收到 repair baseline 的设备只有在本机同一 resolution durable closed 后才可 apply；未绑定或伪造的 baseline 必须以 typed incident 拒绝且不推进 cursor。
- 每台实际安装继续拥有独立 ThisDeviceOnly producer epoch。多个设备可针对同一 resolutionID 各自发布 `basedOnResolutionID` baseline；不仲裁单一新 epoch，避免引入跨设备共识与新的 split-brain。任何未绑定本机 closed resolution 的 repair baseline 都被拒绝；merger 对 N 个合法 baseline 确定性去重并逐字段收敛。
- resolution 期间远端 branch 若继续增长，Endpoint 重读完整 branch graph，后续 immutable evidence 形成下一轮 resolution；resolved cursor 只可跳过与本机 closed resolution 完全相同的 graph。不得把新 descendant 混入已关闭 resolution，也不得建立永久双事实源。

### Rollback watermark

- 每个 producer 同时维护 SQLite monotonic `publicationWatermark` 与 Keychain ThisDeviceOnly watermark。SQLite watermark 由 active producer 的最后一个 durable sealed reference 派生；Keychain payload 只含同一 scope 的 sequence 与 seal digest。任何 publish 前两者必须精确相等。
- Keychain Adapter 固定使用 macOS Data Protection Keychain、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 与 `kSecAttrSynchronizable=false`；六个 runtime profile 使用互不相同的 service。没有 `com.apple.application-identifier` entitlement 的 ad-hoc XCTest 会被系统以 `-34018` 拒绝，这是 fail-closed 证据；正向属性与持久化验证必须在精确 provisioning profile 授权的签名非 production App 门禁执行，不得 skip 或退回 legacy Keychain 冒充。`e2e` gate 已以三次独立 App 启动、两轮全新 scope 证明 exact CAS、跨重启持久化、ThisDeviceOnly accessibility 与非 synchronizable。
- seal publication 时先在 SQLite transaction 内提交 publication，再以 expected watermark 做 Keychain monotonic CAS；只有 CAS 成功后才能进入 Endpoint publish。任意 crash window 产生不等；不等即 fail-closed，SQLite CAS 退休旧 active epoch、建立新 epoch、以 sequence 1 从 authoritative local facts 重建 baseline，再把新 watermark 写入 Keychain。未完成 journal 随后在新 chain seal，禁止猜测追平或继续旧 producer。
- Time Machine 把 SQLite 回退但 Keychain 较新时，publish 前立即阻断。若平台无法证明 SQLite 与 Keychain 不会被同一快照联合回退，remote fork detection 是第二层 fail-closed。诊断不得记录 producer identity、watermark、digest、Keychain service 或路径。

### 开发期 V1 → V2 clean cut

- 项目尚未发布且没有外部用户。V2 不读取、导入、转换或侦测任何 V1 remote evidence、frontier、receipt、failure metadata 或旧设备 writer；不建立 staging importer、legacy decoder、dual read／dual write、late-join 或 runtime fallback。
- V2 正式 App 继续使用 runtime profile 所属的同一 logical sync repository。repository 必须为空或已含 exact V2 immutable format marker：
  - 空 repository 以 append-only staging + atomic no-overwrite link 建立唯一 V2 marker，marker 固定格式版本并携带该 repository 的 generation ID；
  - 多设备并发初始化时，只有一份 marker 可成功创建，其他设备重读并采用已存在的 exact marker；
  - marker 通过后仍须以 `lstat` 递归验证完整 `v2` 子树；目录／regular file 类型、object kind、generation、producer、20 位 sequence、digest、永久 staging area 与 suffix 必须全部符合 exact grammar，symlink、特殊 inode 或任何未知后代均不得被文件系统透明跟随；
  - marker 缺失且 repository 非空、marker 格式不符、完整子树 grammar 不符或任何非 V2 object 存在时全部在 Endpoint 写入前 fail-closed，只提示用户手工删除旧 iCloud 同步目录后重新同步。
- App、Agent、测试、脚本与 Endpoint 永不删除、覆盖、替换、移动、改名或清理旧 iCloud 资料。用户手工删除旧目录是唯一允许的重置路径，不是 App capability。
- 本机 store 同样 clean cut：只允许空 SQLite 建立 current schema 19，或 exact schema 19 原样打开；任何其他 `user_version` 或非空未知 schema 都在启用 WAL、开启 transaction 或执行 DDL／DML 前 fail-closed。App 不迁移、不删除也不改写旧本机资料。
- 本机 authoritative domain snapshot 可以成为空 V2 repository 的第一份完整 baseline，但任何 V1 sync state 不进入 V2。安装 V2 authority 与封装该 snapshot 必须在 engine-generation CAS 保护下完成；之后的 mutation 只进入 V2 outbox。Runtime 初始化必须取得 exact clean-cut authority／generation，否则直接拒绝；不得从 V1 pending journal、sealed journal identity 或 unfinished count 推导 V2 pending truth。
- 数据包导入是当前产品能力，不是 V1 sync migration。导入只接受 exact canonical current format 7，只恢复 domain facts，不恢复任何 sync state；format 6 或其他历史／未知格式全部拒绝。导入后建立全新 V2 baseline，不增加历史格式兼容。
- V2 完成 App 对等后，V1 RunController、Coordinator 和 writer transport 从正式 App 路径删除；CloudKit V1 Store authority、启动 automation、notification callback、Settings 分支与 live-validation 入口一并删除，正式 App 没有 CloudKit fallback。

### Lifecycle、并发与用户状态

- durable control generation 隔离旧 worker。关闭同步先持久化 disabled intent 与新 generation，再 cancel 并 join 唯一 reactor 及其 metadata query、download、coordination、automation、backoff 与 confirmation 子任务；任何旧 generation 的晚返回都不能提交 ledger、status 或 warning。Runtime 重建后的第一份公开 state 必须严格解码 durable metadata，并以 ledger pending publication 与未完成 journal 重新推导，不得先发布内存默认状态。
- 不使用 timeout、force abandon、zombie worker 或“停止成功”假状态。join 完成前 worker state 只能是 `stopping`；超过监控阈值只产生 typed `stoppingDelayed` stage／heartbeat／用户提示，正常 join 后自动消解。
- 外部 I/O、iCloud 等待、placeholder materialization 与 backoff 不持有 mutation lease。领域 merge 只使用短 SQLite transaction 与 engine revision fence；CAS 冲突时基于最新 authoritative snapshot 重新计算，并采用有界重试，不能覆盖并发本机 mutation或无界自旋。
- waiting 不等于 success 或 failure。只有 Outbox sealed 且 confirmed、durable Inbox／waiting 排空、checkpoint 与领域 merge 原子提交，并取得一个空增量 observation 后，才更新最近同步；最近有效同步只在本机资料首次获 endpoint confirmation 或远端资料实际改变本机 facts 时更新。
- UI 必须可区分 policy、worker、convergence 与 incident。`producerForkDetected` 与 unresolved domain conflict 是 actionable；`stoppingDelayed` 只说明仍在安全 join，不得伪造终态。
- 同一 process 内所有连接同属 SQLite 单写者约束。`NoonmarkStorage` 以 process-wide writer coordinator 统一持有 schema prepare、Engine、Replication Ledger、Sync metadata、classification、import replacement 与 termination checkpoint 的完整 transaction／autocommit 写边界；不依赖 Repository 实例、Runtime lifetime、URL identity、busy timeout 或 retry 建立正确性。外部 I/O 仍必须在 writer lease 外执行。
- V2 完整 baseline 不得复用只表达 current-value 的 ordinary mapper。`ReplicationSnapshotRecordBuilder` 必须同时编码领域 current facts、classification projection 与 immutable classification history；clean cut、空 repository reseed、双 watermark recovery 与 fork repair 统一走该边界，并以第二 SQLite store 精确重建证明完整性。
- current-record batch 在 transport 边界只可对每份 exact evidence validation／decode 一次，并只建立一次完整 merge context。provenance 最小化不得按候选重扫完整 batch；不消费 reactivation authorization 的 fold 直接复用完整 context，只有 taskChain／dayTrace 的授权敏感状态转换才从预验证 facts 建立 reduced context。fast gate 同时约束结果、provenance 与有界完成时间。
- `AppPreferences` 明确分为 replicated theme／language version 与 device-local runtime configuration。跨设备 apply 只更新 theme、language、clock 与 writer；dataMode、backupPolicy、localFirstSyncPolicy、settingsPoemDisplayPolicy 与 syncEndpointOptions 必须保留目标设备原值。第二 SQLite ground truth 必须同时证明共享资料相等与本机字段未被覆盖，不得直接比较来源设备的完整 preferences。

## Correctness invariants

1. Remote visibility = valid seal；orphan chunk／root／announcement 不是同步事实。
2. Success metadata 永远不领先于 durable confirmation、apply checkpoint 或领域事实。
3. Self watermark 只按 durable confirmed set 的最长连续 prefix 单调前进。
4. V2 不存在 mutable head；文件存在、空 pending、无 upload error 或本机 write success 均不能单独证明成功。
5. Fork 两个分支都保留并验证；repair 不丢 branch、不任意选 winner。
6. V1 与 V2 任一时刻只有一个 writer authority。
7. stop 返回即整个 runtime task tree 已 join；返回后旧 generation 无提交能力。
8. 正常同步与 cutover 期间，本机 mutation 保持可用且所有事实可由 SQLite 重启恢复。

## Test seams and rollout gates

- 第一颗 tracer bullet 固定 build 29 原始症状：sequence 2 先确认、重启、sequence 1 后确认；前者合法持久化但 watermark 停在 0，后者在同一 transaction 推进到 2，并证明 source pull 零 self-echo。
- 第二颗贯穿 `SQLite outbox → chunk → root → seal → Endpoint confirmed → confirmation set → self watermark → 第二 SQLite apply → 双端重启对账`。
- 后续依次覆盖每个 crash window、orphan artifact、fork／N-device repair、双 watermark rollback、cancel+join generation fence、空 repository clean cut、旧 repository fail-closed 与 placeholder materialization。chunk、root、seal 与 announcement 任一 immutable prefix 中断后，retry 必须保留已有 bytes、补齐剩余对象并只暴露一份 sealed publication；publish 后、confirmation 前中断则必须在重启第一份 state 中恢复 pending truth。
- fast gate 进入 `make check`；真实双 SQLite／真实文件 Endpoint symptom gate 与签名 `e2e` App gate 进入 `scripts/test-all`；发行 gate 必须消费同 source/run 的 `dmg-validation` cutover 证据和两台实体 Mac／72 小时 iCloud soak manifest。
- 所有运行 V2 Runtime 的真实 `e2e` App 必须从带 exact provisioning 与 Data Protection Keychain entitlement 的统一 build 入口产生；缺少 profile 在启动 App 前 fail-closed，不得以 in-memory watermark、legacy Keychain 或 ad-hoc 签名降级。
- V2 App automation 只能包裹真实 `ReplicationEndpoint` 注入 failure／blocked await／cancel join，不得保留 V1 coordinator、status metadata、repository-lock 或 persisted-failure continuation seam。Preferences 必须以三个独立 App process 覆盖收敛、failure、同步等待期间本机 mutation、物理 disable、join、disabled restart suppression 与重新启用。
- 诊断证据 scope 与 replication transport scope 必须分离。V2 transport 可以按协议保留 permanent stage + hardlink final；artifact inventory 继续只接受 owned single-link regular file。测试不得删除 permanent stage，也不得放宽证据 helper；Local Folder transport 使用本轮独立临时根，Help 导出 helper 只在证据根持有单链接 lock evidence。
- 同机双 SQLite 只能证明领域与文件协议，不得冒充两台实体设备 iCloud 收敛。
- 真实 iCloud append-only tracer 必须先通过 `scripts/test-icloud-append-only-guard`，每次建立全新 session 与至少两个全新 round；后轮结束后重新计算前轮 immutable inventory 与 digest，任何对象减少、变化或 mutable head 出现都判红且不清理现场。
- 用户资料压力 gate 必须先用同一资料包在独立 SQLite／V2 repository 运行领域预检，再启动签名 `e2e` App。测试 fixed-clock 取资料包最大领域日期的下一天，并在 exercise／restart 间保持不变；真实 App 依次验证同步中修改、任务增改删、备注、计划子任务、排期、完成、飞光、设置、重启、exact confirmation、成功时间与 typed diagnostics。App 退出后必须再以第二份独立 SQLite 消费同一 round，与 App database authoritative replicated state 精确对账、证明 target device-local preferences 未被覆盖，并证明再次重启零重复 apply；第二消费者写入前后的既有 iCloud inventory／digest 必须逐项不变。对账失败只可输出有界计数、UUID 与 digest，不得展开业务正文。预检失败时不得创建 iCloud session；真实阶段产生的任何 round 无论成功或失败都永久保留。

## Risk And Rollout

- 风险等级：P。主要风险是 frontier 越过未提交 facts、并发 mutation 被旧 snapshot 覆盖、iCloud placeholder 被误判 corruption、rollback 后旧 epoch 重用、fork repair 丢失分支、非空旧 repository 被误当成 V2、最终键半写，以及初始 baseline 与首批本机 mutation 之间出现缺口。永久 staging 会增加远端 object count 与容量，这是遵守零删除铁命下有意接受的成本，必须以 allocated bytes 与增长率监控。
- 回滚：App cutover 前可回退未发行 V2 代码并重建非 production profile；不得以“回滚”为由读写或清理任何现存 iCloud repository。App cutover 后异常只允许关闭同步与 roll-forward，不恢复 V1 writer。
- 灰度：纯 kernel／真实临时 SQLite → Local Folder 双资料库与崩溃恢复 → 签名 `e2e` App → 同一专用测试 iCloud account 的两台实体 Mac → 72 小时 soak → `dmg-validation` → 用户显式批准 production cutover。
- 监控：只记录安全标量和 typed code，包括 unsealed／prepared／confirmed 数量、confirmed-prefix gap、Inbox／waiting、checkpoint distance、worker generation、self-echo、closure time、cutover stage、fork count 与 Adapter state；不得记录 producer identity、digest、路径、payload 或用户资料。

## Consequences

同步正确性集中到一个具有 Depth 与 Locality 的 Module。合法乱序 confirmation 不再依赖调用顺序；App、Adapter 与 UI 无法单独改写 protocol truth；本机 mutation 不再被远端等待长期拒绝。代价是必须新增 V2 ledger/schema、content-addressed file repository、永久 append-only staging、Apple ubiquitous Adapter、统一 SQLite writer authority 与完整双实体设备门禁。永久 staging 以额外对象与容量换取零删除铁命下的 crash-safe final visibility，必须监控 allocated bytes 与增长率。开发期 clean cut 明确不实现 V1 staging importer、legacy remote reader、CloudKit V1 fallback 或其他历史兼容；全部 seal/cutover gate 完成前不得请求 production cutover。

本 ADR supersede ADR-0046 中 `SyncRecordTransport`、逐阶段 Coordinator、journal-row receipt、mutable head confirmation 与同步期间长期 mutation gate 的 Interface 决策；保留其 per-producer immutable history、增量复杂度、durable Inbox、领域 deterministic merge 与禁止无 acknowledgement GC 的原则。

# FAIL-2026-08-11-10：Replication V2 缺少 SQLite／ThisDeviceOnly Keychain 双 watermark

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T10:43:36-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初 V2 只持久化 confirmation prefix，没有 publication rollback witness
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

问题尚未进入发行或 production。Time Machine／资料库回退后，SQLite 可能回到较旧 sequence，而旧代码只从 SQLite 计算下一 publication；同一 producer 会复用已经在远端出现过的 sequence并产生不同 digest，形成 self-fork。反向 crash window 中，SQLite 已 seal 但外部 rollback witness 尚未提交；若直接 publish，重启无法证明本机链没有回退。

## 时间线

- 既有 `sync_replication_self_watermarks` 只表示 exact confirmation 的最长连续前缀，不是 seal 时的 publication watermark。
- 2026-08-11T10:43:36-04:00：确认现有 Runtime 没有 Keychain watermark seam，publish 前也不做双副本对账。
- 2026-08-11T10:45:22-04:00：真实 Data Protection Keychain 尝试在 ad-hoc XCTest 中被 macOS 以 `-34018` 拒绝，证明正向门禁必须运行签名 App，不能用普通 CLI Keychain 冒充。
- 2026-08-11T10:49:51-04:00：Keychain 超前／SQLite 回退 tracer 转绿。
- 2026-08-11T10:50:28-04:00：SQLite seal 超前／Keychain CAS 中断 tracer 转绿，旧 publication 在远端保持 0。
- 2026-08-11T11:05:45-04:00：新增签名 E2E symptom gate；首轮在 20 秒边界内没有结果，证明 App 启动 seam 尚未接入。
- 2026-08-11T11:06:29-04:00：接入三阶段 App automation 后，Apple Development 签名 App 稳定返回 `keychain-status--34018`，原始签名包没有 application identifier entitlement。
- 2026-08-11T11:07:56-04:00：把手工构造的 application identifier 与 keychain access group 写入签名后，`codesign --verify --deep --strict` 通过，但 LaunchServices 以 launchd spawn POSIX 153 拒绝启动。机器上没有 provisioning profile；试验性签名改动已撤回，普通 E2E App 启动边界没有被破坏。
- 2026-08-11T12:06:00-04:00 至 12:08:55-04:00：经用户批准后，Xcode automatic provisioning 为精确 `app.noonmark.mac.e2e` 身份建立 development profile；两轮全新 scope 的真实签名门禁连续转绿，随后完整安全回归通过。

## 复现与证据

第一条真实临时 SQLite＋文件 Endpoint tracer 先正常发布 producer A sequence 1，再把外部 watermark 设置为 sequence 2，模拟 SQLite 回退。新增本机 task 后重启 Runtime。旧实现没有外部 store Interface，红测无法编译；接入后对账运行产物证明 producer A 不再增长，新 epoch 以 baseline sequence 1 与 journal sequence 2 收敛。

第二条 tracer 在 SQLite seal 完成后的首次 external CAS 注入失败。中断时 ledger 已有 producer A sequence 1，但 Endpoint read 为 0 publication；重启检测 SQLite／external 不等后轮换，新 epoch 两条 publication confirmed，旧 producer 从未写入远端。

## 排除的假设

- confirmation watermark 不能替代 publication watermark：confirmation 发生在远端 publish 之后，无法保护 publish 之前的 sequence reuse。
- 不能以较大一方覆盖较小一方：无法证明哪一份经历回退，猜测追平会保留错误 producer identity。
- 不能只检查 sequence：同 sequence 不同 seal digest 正是 fork，必须 exact pair 对账。
- legacy macOS Keychain 不足以证明 `ThisDeviceOnly`；Apple 要求 `kSecAttrAccessible` 配合 Data Protection Keychain。
- ad-hoc XCTest 的 `-34018` 不是可 skip 环境问题；它证明该进程没有签名 App entitlement，正向验证必须移到签名门禁。
- Apple Development 证书本身不能授权 restricted entitlement：手工嵌入的声明即使通过静态 `codesign` 验证，缺少 provisioning profile 时仍会被系统阻止启动。不能用静态 entitlement plist 冒充正向 Keychain 证据。

## 根因与破坏机制

早期 V2 把 `selfWatermark` 定义为 remote confirmation prefix，却遗漏了 seal 时跨 SQLite snapshot 回退仍存活的独立 witness。Runtime 因而只有单一可回退真值，也没有能力把 Keychain 不一致转成 producer retirement。

## 根因修复

新增 `ReplicationPublicationWatermarkStore` Deep Module seam，以 `(generationID, producerID)` scope 保存 sequence＋seal digest，并提供幂等 monotonic compare-and-set。production Adapter 使用 Data Protection Keychain、`AfterFirstUnlockThisDeviceOnly`、明确 `synchronizable=false` 和 profile 独立 service；canonical payload 漂移、CAS stale、sequence regression 与 Security error 全部 typed fail-closed。

Runtime 在每次 reconcile 起点和每次 Endpoint publish 前，把 Keychain 值与 SQLite active producer 最后一个 sealed reference exact 对账。正常 seal 顺序固定为 SQLite transaction → Keychain CAS → Endpoint publish。任一不等都在远端 I/O 前建立全新 producer，并在一个 SQLite CAS transaction 内退休旧 active epoch、seal authoritative sequence 1 baseline；之后才写新 Keychain watermark并把 pending journal seal 到新 chain。旧 epoch 永不补写、覆盖或删除远端对象。

## 验证结果

- Keychain 超前 tracer：旧 producer 停在 sequence 1，新 epoch baseline＋journal 两条 confirmed，第二次重启 0 duplicate apply／confirmation。
- SQLite 超前 tracer：CAS 中断时 Endpoint publication 为 0；重启后新 epoch 两条 confirmed，远端全部 reference 均不是旧 producer。
- store contract：in-memory seam 通过幂等、stale CAS 与 regression；ad-hoc Data Protection Keychain query／add 明确验证无 entitlement 时系统 fail-closed。
- signed App：两轮独立 gate 各启动三个全新 `e2e` App process，依次完成 `nil → sequence 1`、拒绝 stale CAS、`sequence 1 → 2`、再次重启读取 sequence 2 与幂等 CAS。Security attributes 明确为 `AfterFirstUnlockThisDeviceOnly`，以 `synchronizable=true` 查询固定返回 item not found；每轮只精确删除自己的 Keychain 测试记录。
- signing boundary：build 先解码并校验未过期 provisioning profile、精确 bundle identity 与同 Team Keychain group，再嵌入 profile、生成 DER entitlement并重新读取 signed claims；缺 profile、ad-hoc identity、identity 不匹配或 entitlement 漂移全部 fail-closed。
- runtime profile：六个 Swift 与 shell profile 的 watermark Keychain service 两两不同；17 项 profile 测试与完整 isolation contract 通过。
- 完整回归：`NoonmarkSyncTests` 297 项、0 失败；`NoonmarkStorageTests` 284 项、0 失败，唯一 skip 是未显式启用的 live iCloud 用例；recovery、Schema 四项、runtime profile 隔离、iCloud append-only guard、85 项 failure-case 映射、489 个 SwiftFormat 文件与 `git diff --check` 全部通过。
- 真实 iCloud：append-only session `a1b0ebff-e625-4d28-b1e0-4cbc243a9404` 的两个全新 round 在 37.446 秒内完成双 SQLite 收敛与目标重启幂等；每轮含 4 个 immutable publication object 与 1 个 canonical repository marker、0 mutable head，所有对象永久保留。本次 signed Keychain slice 使用 `--ephemeral`，没有读写 SQLite 或 iCloud，也没有为了重复验证而新增或清理 iCloud 对象。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行双向 mismatch、store CAS 与 ad-hoc entitlement fail-closed测试，由 `scripts/check` 强制调用。
- fast signing contract：`scripts/test-replication-watermark-keychain-contract` 固定 provisioning、精确 Keychain group、DER entitlement、三阶段 App automation 与 `--ephemeral`／无 iCloud 边界，由 recovery contract 强制调用并登记于 `gates.tsv`。
- symptom：`scripts/test-integration` 执行完整 Storage suite，覆盖真实临时 SQLite、文件 Endpoint、Runtime restart 与后续本机 mutation。
- signed gate：`scripts/test-replication-watermark-keychain-signed` 固定三次独立 `e2e` App 启动、`nil → 1 → 2`、stale CAS、security attributes、第三次重启与精确测试记录清理；精确 provisioning profile 到位后已连续两轮通过。修复 commit 已回填，案例标记为「已修复」。

## 发行与回滚

当前没有 production cutover。dual-watermark slice 的签名门禁与全量回归已经通过，但冲突持久化／用户决策、N-device convergence、lifecycle cancel+join、V1／App cutover、双实体 Mac 与 72 小时 soak 仍未完成；继续保留 V1 production authority。不得退回 legacy Keychain、把 `-34018` skip、猜测追平 watermark、复用旧 producer或删除远端资料。

## 教训与永久约束

防 rollback 必须有一个不随 SQLite snapshot 同步回退的 device-local witness。外部 witness 不是第二 authority：它与 SQLite 不等时唯一安全动作是退休 identity并从 authoritative facts 重建，而不是选择较大值。签名 entitlement 是真实 Keychain 行为的一部分，不能被源码常量或 ad-hoc 单测替代。

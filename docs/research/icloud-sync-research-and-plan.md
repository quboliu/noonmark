# iCloud 同步调研与实施方案

最新确认日期：2026-07-07

本文调研晷迹在 macOS 与未来 iOS / iPadOS 平台上实装 iCloud 同步的可行方案，并给出推荐架构、坑点、限制、落地步骤和验证策略。结论基于当前仓库源码、既有 ADR、Apple 官方文档和公开应用案例。

## 结论

晷迹推荐采用 **CloudKit private database + CKSyncEngine + 自有 SQLite / NoonmarkCore 合并层**。

不推荐：

- 不推荐把裸 SQLite 放进 iCloud Drive 同步。
- 不推荐把导出的 JSON 数据包当作自动双向同步载体。
- 不推荐为了 iCloud 同步迁移到 Core Data / SwiftData + `NSPersistentCloudKitContainer`。

理由：

- 晷迹当前是 SwiftUI + Swift Package 领域层 + 自有 SQLite repository。Apple 对“自带本地持久化”的推荐路径是 CKSyncEngine；Core Data / SwiftData CloudKit 更适合从 Core Data / SwiftData 模型出发的应用。
- 晷迹领域规则包含历史日轨迹不可改写、任务链单活跃轨迹、任务定义不可覆盖、子任务 lineage 等业务约束。CloudKit 是记录存储，不是关系数据库；自动 mirror 很难表达这些领域不变量。
- iCloud Drive 是文件同步，适合用户可管理文档，不适合同步正在被 App 高频读写的数据库。文件同步会引入文件协调、离线占位、版本冲突、iOS 延迟下载和整包一致性问题。
- CloudKit private database 使用用户自己的 iCloud 账户与配额，隐私和账号成本适合个人 Todo；同时不要求用户再注册晷迹账号。

第一版目标应是：

- 只同步同一 Apple Account 下的用户私有数据。
- 不做多人协作，不做共享数据库，不做 Web 端。
- 本地优先；iCloud 不可用时普通清单继续完整可用。
- 同步失败 fail-closed：不丢本地数据，不静默覆盖历史事实。
- 提供“立即同步”“同步状态”“冲突列表”“关闭同步但保留本机数据”。

## 当前仓库事实

当前仓库已有基础：

- `docs/adr/0002-local-first-manual-data-packages-before-sync.md` 明确：一期本地优先，只做手动数据包，不直接同步裸 SQLite。
- `docs/adr/0004-use-insert-only-relational-model-not-event-sourcing.md` 明确：事实表是事实来源，`change_journal` 只能作为未来同步和诊断辅助流水，不是事实来源。
- `NoonmarkCore` 已有稳定 ID、日期值对象、任务链、任务定义、日轨迹、子任务、每日复盘和偏好。
- `NoonmarkStorage` 已有 `SQLiteEngineRepository`、`NoonmarkDataPackage`、`sync_settings` 表和 `sync_endpoint_options_view` 占位。
- 设置页已展示“自定义同步端点”和“iCloud 云同步”，当前均标记为规划中。

当前缺口：

- 没有 CloudKit entitlement、container、schema、record mapping。
- 没有设备 ID、同步游标、server change token、本地待上传队列。
- 没有变更 journal 表。
- 没有冲突表、冲突 UI、同步状态 UI。
- 没有 iCloud account status / quota / throttle / retry 处理。
- 没有真实双设备同步测试。

## 外部方案调研

### Apple 平台能力

Apple 给出了三条主路径：

1. `NSPersistentCloudKitContainer`

   适合 Core Data 本地模型，能自动把 Core Data store mirror 到 CloudKit。Apple 的 WWDC 资料说明，若需要“包含本地持久化的全栈方案”，可以用 `NSPersistentCloudKitContainer`。但 Apple 也说明，Core Data with CloudKit 的模型必须符合 CloudKit 限制，例如不支持 unique constraints、undefined attributes、required relationships 等。

   对晷迹不合适。晷迹当前不是 Core Data 模型，并且业务强依赖关系约束和领域不变量。如果迁移，会把“为了同步而重写存储层”变成主风险。

2. SwiftData + CloudKit

   SwiftData 的 CloudKit 同步底层仍使用 `NSPersistentCloudKitContainer`。它适合新 SwiftData 模型，不适合当前自有 SQLite 事实模型的低风险接入。

3. CKSyncEngine

   Apple 在 WWDC23 中说明，如果应用自带本地持久化，应该使用 CKSyncEngine。CKSyncEngine 负责大量同步共性问题：调度、推送通知、账号变化、状态跟踪、错误处理和 CloudKit 操作编排；应用侧只需要把本地变化转成 records，并把远端 records 合并回本地。

   这正好匹配晷迹：保留 `NoonmarkCore` 与 SQLite 事实模型，只新增 CloudKit adapter 与同步协调器。

### CloudKit 优势

- 使用用户 Apple Account，不需要晷迹自建账号系统。
- private database 存在用户 iCloud 账户下，适合个人私有 Todo。
- Apple 平台原生支持 macOS、iOS、iPadOS、watchOS、visionOS。
- CKSyncEngine 可以减少自研同步引擎代码量，并利用系统调度和推送。
- CloudKit Console 提供 schema、日志、容器状态与测试数据管理。
- 对 Apple-only 产品，CloudKit 是隐私叙事清楚、运维成本较低的方案。

### CloudKit 限制与坑

- CloudKit 不是关系数据库。不能指望它替代 SQLite 的唯一约束、事务和复杂查询。
- private database 计入用户 iCloud 配额；用户空间满时会出现 quota 错误。
- 用户可能未登录 iCloud、关闭 App 的 iCloud 权限、使用受管 Apple Account、被 MDM / 家长控制限制、或 iCloud 临时不可用。
- CloudKit 会限流，`requestRateLimited`、`serviceUnavailable` 等错误必须按 `retryAfterSeconds` 或退避策略处理。
- 初次全量迁移和大批量上传可能很慢，必须分批、可恢复、可暂停。
- 推送不是实时一致性保证；UI 文案应表达“自动同步 / 最近同步”，不要承诺实时。
- Development 与 Production CloudKit schema 生命周期不同；发布前必须部署 schema。
- CKRecord field 数量、record zone 数量、操作批大小等有限制；数据模型要保守。
- 多设备离线编辑会产生领域冲突，CloudKit 不会替晷迹理解“历史不可改写”或“单活跃轨迹”。

### iCloud Drive / 文件同步的坑

Apple 的 iCloud Documents 文档指出，非文档对象访问 iCloud 文件时需要自己处理文件协调；iOS 上文件不一定自动下载，读取未下载文件可能阻塞；冲突要处理 `NSFileVersion`；用户还能在 Finder / Files 中移动、删除或外部编辑文件。

对晷迹来说，这意味着：

- 裸 SQLite 放进 iCloud Drive 可能被两个设备同时读写，风险不可接受。
- JSON 数据包适合手动导入 / 导出，不适合自动双向同步，因为每次合并都要处理整包版本冲突。
- Todo 数据不是用户可直接管理的单个文档，而是 App 内数据库记录。应使用 CloudKit records，而不是文件夹同步。

## 其他应用做法

### Things

Things 使用自家的 Things Cloud，同步 Todo 横跨 Mac、iPad、iPhone、Apple Watch 和 Vision Pro；官方明确不支持 iCloud、Dropbox 等第三方同步。这个路线优点是完全控制协议、后台、冲突与跨平台扩展；缺点是要自建账号、服务端、安全和运维。

对晷迹的启示：Todo 同步本质复杂，成熟 Todo 产品往往选择自控协议。但晷迹当前 Apple-first、无账号、早期产品，先用 CloudKit private database 更符合阶段目标。

### OmniFocus

OmniFocus 推荐 Omni Sync Server，也支持 WebDAV；官方明确提醒 Dropbox、OneDrive、Google Drive 等文件分享服务不能正确同步 OmniFocus 数据，可能导致损坏。它有同步日志、注册设备、手动同步、替换服务器数据、加密等诊断与恢复入口。

对晷迹的启示：需要把“同步可观测性”和“恢复路径”作为第一版能力，而不是只做一个开关。

### Bear

Bear 使用 Apple CloudKit 同步笔记，强调不需要额外注册账号、数据在用户 iCloud 中、团队不接触用户凭证和敏感数据；也说明选择 CloudKit 而不是 iCloud / Dropbox / Google Drive 这类文件方案，因为性能更好且更适合记录型数据。

对晷迹的启示：如果坚持 Apple 平台优先，CloudKit 的隐私叙事和用户心智都适合。

### Drafts

Drafts 社区说明其同步数据不是文件，而是数据库 records，自动双向同步依赖 CloudKit；同时提到 iOS 17 / macOS 14 之后第三方 CloudKit 不再要求 iCloud Drive 必须启用，但企业安全策略仍可能单独阻断 CloudKit。

对晷迹的启示：设置页不能只检测 iCloud Drive，应检测 CloudKit account status；错误文案要能区分“未登录、受限、临时不可用、网络不可用、配额不足、被限流”。

### Obsidian / 文件夹同步

Obsidian 官方提醒，文件服务若把文件 offload，App 可能无法访问而导致同步问题；必须让 vault 保持本地可用。社区也有大量关于 iCloud 文件夹延迟、路径、占位文件和索引问题的反馈。

对晷迹的启示：文件夹同步适合 Markdown vault 这种用户可见文件集合，但对数据库型 Todo 不应采用。

### Agenda

Agenda 对外强调支持 iCloud 和 Dropbox，且数据保存在用户个人云中。它说明“个人云存储”是用户信任点，但同时也意味着实现要处理各云平台差异。

对晷迹的启示：如果未来要支持自定义同步端点 / Dropbox / WebDAV，必须抽象出同步协议层；但第一版 iCloud 不应被多端点抽象拖慢。

## 推荐架构

### 总体结构

新增 `NoonmarkSync` target：

- 依赖：`NoonmarkCore`、`NoonmarkStorage`、`CloudKit`。
- 不让 `NoonmarkCore` 依赖 `NoonmarkSync`。
- App 层通过 `NoonmarkSyncCoordinator` 驱动同步状态、手动同步和设置页 UI。

建议模块：

- `SyncDeviceIdentity`
  - 本机稳定 device ID，存在 Keychain 或 Application Support。
  - 不使用硬件序列号，不上传用户隐私设备名；可上传用户可读的本地设备别名。

- `SyncJournal`
  - SQLite 辅助流水，记录本地变更的 entity type、entity id、operation、changedAt、deviceID、baseVersion。
  - 不是事实来源，只作为 CKSyncEngine 待上传队列和诊断材料。

- `CloudKitRecordMapper`
  - 在领域 entity / snapshot 与 `CKRecord` 之间转换。
  - 不直接写 SQLite。

- `CloudKitSyncAdapter`
  - 封装 CKSyncEngine、custom zone、record changes、account status、retry。

- `NoonmarkSyncMerger`
  - 把远端 records 合并进 `NoonmarkEngine` / SQLite。
  - 负责领域不变量、冲突检测和 fail-closed。

- `SyncConflictStore`
  - 保存未能自动合并的冲突。
  - UI 可展示、选择解决方式。

- `SyncStatusStore`
  - 最近同步时间、待上传数、待下载数、错误码、账号状态、是否正在初次导入。

### CloudKit 数据库选择

第一版使用：

- `CKContainer(identifier: "iCloud.<team>.noonmark")`
- `privateCloudDatabase`
- custom zone：`NoonmarkUserDataV1`

暂不使用：

- public database
- shared database
- CloudKit Sharing

原因：

- 晷迹第一版是个人 Todo，不需要跨用户共享。
- private database 计入用户 iCloud，隐私和成本模型合适。
- custom zone 方便按 zone 拉取 changes 和删除记录。

### Record 类型

建议第一版 record-per-entity，而不是只同步 operation log：

- `DayRecord`
  - recordName：`day:<YYYY-MM-DD>`，避免多设备同时创建同一天导致重复。
  - 字段：date、lockedAt、reviewSummary、reviewUnfinishedReason、reviewTomorrowNote、createdAt、updatedAt、modifiedDeviceID。

- `TaskChainRecord`
  - recordName：`chain:<uuid>`。
  - 字段：state、createdAt、updatedAt、modifiedDeviceID。

- `TaskDefinitionRecord`
  - recordName：`definition:<uuid>`。
  - 字段：chainID、sequence、title、descriptionText、note、createdAt、supersededAt、supersededByDefinitionID、modifiedDeviceID。

- `DayTraceRecord`
  - recordName：`trace:<uuid>`。
  - 字段：chainID、definitionID、date、status、priority、continuationSeq、continuedFromTraceID、changedToTraceID、manualProgressPercent、progressMode、descriptionText、note、createdAt、updatedAt、completedAt、settledAt、modifiedDeviceID。

- `SubtaskRecord`
  - recordName：`subtask:<uuid>`。
  - 字段：traceID、lineageID、title、status、difficulty、position、continuedFromSubtaskID、createdAt、updatedAt、completedAt、settledAt、modifiedDeviceID。

- `AppPreferencesRecord`
  - recordName：`preferences:default`。
  - 字段：theme、language、updatedAt、modifiedDeviceID。

暂不把 AI provider、API Key、同步端点配置、烛龙草稿进入 iCloud 同步第一版。

### 为什么不只同步 operation log

晷迹现有 ADR 明确事实表是事实来源，`change_journal` 是辅助流水。纯 operation log 会逼近 event sourcing，并要求所有历史版本永远可回放，风险大。

record-per-entity 更适合第一版：

- 初次同步可直接上传 / 下载当前事实。
- CloudKit record change 可幂等应用。
- 与当前 `NoonmarkSnapshot` 和 SQLite 表结构贴近。
- 后续仍可保留 journal 作为增量队列和诊断，不改变事实来源。

## 冲突策略

### 可自动合并

- 不同 UUID 的新增任务链、任务定义、日轨迹、子任务：直接合并。
- 同一 entity 的相同字段、相同值：幂等。
- `DayRecord` 复盘三字段：按字段级 LWW 合并，但必须保留冲突前值到 `sync_conflicts` 或 `sync_audit_log`，便于恢复。
- `AppPreferencesRecord`：LWW。
- 当前日 pending trace 的描述、附言、手动进度：LWW；若本地和远端都在离线期间修改同字段，生成轻量冲突记录。

### 必须 fail-closed 进入冲突队列

- 远端记录会导致历史日轨迹被删除或覆盖。
- 同一任务链出现多个 active pending trace。
- 远端试图修改已结算历史 trace 的 priority、status、definition 边界或子任务状态。
- 子任务 parent trace 不存在。
- TaskDefinition 指向缺失的 TaskChain。
- DayTrace 指向缺失的 TaskDefinition / TaskChain。
- 同一 chain 的 definition sequence 冲突且内容不同。

冲突 UI 第一版不需要复杂，但必须能显示：

- 冲突类型
- 本机版本
- iCloud 版本
- 建议操作：保留本机、接受 iCloud、复制为新任务、忽略远端并重试、导出诊断包

### 历史不可改写原则

CloudKit 只是传输层。所有 incoming merge 都必须经过 `NoonmarkCore` 的领域规则或等价校验，不允许直接 upsert SQLite 后破坏历史规则。

## 同步生命周期

### 开启 iCloud 同步

1. 检查 CloudKit account status。
2. 确认用户启用晷迹 iCloud 同步。
3. 创建 / 打开 custom zone。
4. 生成本机 device ID。
5. 拉取远端已有 records。
6. 与本地 SQLite snapshot 做 dry-run merge。
7. 若无阻断冲突，应用 merge。
8. 将本地剩余 records enqueue 到 CKSyncEngine 上传。
9. 设置状态为 enabled。

如果远端和本地都有数据，不能无提示直接覆盖。必须显示“合并本机与 iCloud 数据”的说明，并在发生冲突时停在冲突处理页。

### 日常同步

- 本地写入后：Repository 事务内写事实表，同时写 `change_journal`。
- Sync coordinator 读取 journal，向 CKSyncEngine 添加 pending changes。
- CKSyncEngine 根据系统条件自动发送；用户点击“立即同步”时可手动触发。
- 收到 push / foreground / periodic trigger 后 fetch changes。
- Incoming records 先进入 staging，拓扑排序后合并。
- 合并成功后更新 SQLite、sync metadata 和 UI 状态。

### 关闭同步

提供两种操作：

- 关闭本机 iCloud 同步，保留本机数据。
- 关闭并清除 iCloud 数据：危险操作，必须二次确认；第一版可以不提供。

关闭同步不应删除本地任务。

## 数据库变更建议

新增表：

```sql
CREATE TABLE sync_device_identity (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    device_id TEXT NOT NULL,
    display_name TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE sync_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value BLOB,
    updated_at TEXT NOT NULL
);

CREATE TABLE change_journal (
    id TEXT PRIMARY KEY NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    changed_at TEXT NOT NULL,
    device_id TEXT NOT NULL,
    sync_state TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

CREATE TABLE sync_conflicts (
    id TEXT PRIMARY KEY NOT NULL,
    conflict_type TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    local_payload TEXT,
    remote_payload TEXT,
    detected_at TEXT NOT NULL,
    resolved_at TEXT,
    resolution TEXT
);

CREATE TABLE sync_audit_log (
    id TEXT PRIMARY KEY NOT NULL,
    direction TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    action TEXT NOT NULL,
    created_at TEXT NOT NULL,
    message TEXT
);
```

`sync_metadata` 需要存：

- CKSyncEngine serialized state。
- server change token / zone token。
- last successful sync timestamp。
- CloudKit environment marker。

## UI 方案

设置页“同步”区从规划中升级为可配置：

- iCloud 云同步开关。
- 当前 iCloud 状态：
  - 未启用
  - 正在检查 iCloud
  - 已启用，最近同步时间
  - 正在同步
  - 离线等待
  - iCloud 未登录
  - iCloud 被限制
  - iCloud 空间不足
  - 被限流，稍后重试
  - 有冲突待处理
- “立即同步”按钮。
- “查看冲突”按钮。
- “导出同步诊断包”按钮。
- “关闭同步，保留本机数据”按钮。

不要在 UI 上承诺实时同步。建议文案：

- “使用 iCloud 在你的 Apple 设备之间同步晷迹数据。”
- “同步由系统调度；网络、电量、iCloud 状态可能影响到达时间。”
- “历史日轨迹仍受晷迹规则保护，不会被远端记录静默覆盖。”

## Entitlement 与发布准备

需要补：

- iCloud capability。
- CloudKit container。
- macOS App sandbox entitlements。
- 未来 iOS target entitlements。
- Development schema 初始化脚本 / 操作文档。
- Production schema deploy checklist。
- TestFlight / 本地双设备验证账号。

注意：CloudKit schema 进入 production 后迁移约束更高。第一版 record type 和字段命名要保守，新增字段优先 optional。

## 测试策略

### UT

- Record mapper round-trip。
- Local entity -> CKRecord -> local entity 幂等。
- Field-level merge。
- 历史不可改写冲突检测。
- 单活跃 trace 冲突检测。
- 缺父记录 fail-closed。
- account status 到 UI 状态映射。
- retry / backoff 策略。

### IT

- SQLite repository 写事实表时同步写 change_journal。
- Staging incoming records 后拓扑排序合并。
- `sync_conflicts` 写入、解决、审计。
- DataPackage 导入后能生成初次上传队列。

### ST

- 使用 mock CloudKit adapter 跑完整本地同步状态机。
- 双本地数据库模拟两个设备：
  - A 创建任务，B 拉取。
  - A / B 离线分别编辑复盘，恢复后字段合并。
  - A / B 同时排期同一任务链到不同日期，生成冲突。
  - 历史 trace 远端修改被拒绝。

### E2E

- 真实 App 设置页启用 / 关闭 iCloud 同步 UI。
- 无 iCloud account / mock unavailable 状态显示。
- 有冲突时右侧详情或设置页能打开冲突列表。
- 关闭同步不删除本地 SQLite 数据。

### Live CloudKit 手动测试

新增类似 `scripts/test-ai-provider-live` 的显式入口：

- `scripts/test-icloud-sync-live`
- 必须显式设置环境变量，例如 `NOONMARK_ICLOUD_LIVE=1`。
- 默认不进入 `make check`。
- 使用专门测试 container 或 development environment。
- 必须能清理测试 zone / records。
- 缺少 entitlement、iCloud account、container 或真实设备时 fail-closed，不得假装通过。

## 实施里程碑

### M0：方案与基础合同

- 落地本文。
- 新增 ADR：采用 CloudKit private database + CKSyncEngine，不同步裸 SQLite。
- 更新功能规格，把 iCloud 从“规划中”改成“下一阶段实施中”的边界。

### M1：本地同步骨架

- 新增 `NoonmarkSync` target。
- 新增 sync metadata / device identity / change_journal / conflicts schema。
- Repository 写入路径补 journal。
- 添加 mapper 和 mock sync adapter。
- 只跑本地 UT / IT / ST，不接 CloudKit。

### M2：CloudKit adapter

- 加 entitlement 与 container。
- 接 CKSyncEngine。
- 实现 custom zone、state serialization、pending changes、fetch changes。
- 加 account status 和错误映射。
- 加 `scripts/test-icloud-sync-live`。

### M3：UI 与用户路径

- 设置页开启 iCloud 同步。
- 同步状态、立即同步、冲突列表、关闭同步。
- E2E 覆盖设置页和 mock 状态。

### M4：双设备验证

- Mac + Mac。
- Mac + iOS 模拟器如果 CloudKit 支持不足，则用真机。
- Mac + iPhone 真机。
- 迁移已有本地数据到 iCloud。
- iCloud 空间不足、账号退出、网络断开、限流重试。

## 风险与回滚

高风险点：

- 初次合并误覆盖本地数据。
- 多设备离线编辑产生领域冲突。
- CloudKit schema 发布后难以回滚。
- iCloud account / MDM / quota 导致用户误以为数据丢失。
- CKSyncEngine 状态损坏或 zone 被用户删除。

回滚策略：

- 同步第一版必须保留本地 SQLite 为事实来源。
- 开启同步前自动导出本地 data package 到 Application Support 的备份目录。
- 每次 incoming merge 前写 merge audit。
- 关闭同步只停 CloudKit，不删本机数据。
- 提供“导出诊断包”和“从本机重新上传到 iCloud”的受控恢复入口；后者必须二次确认。

## 最终建议

晷迹应该按 CKSyncEngine 路线推进。第一版不要追求多人协作和跨平台泛化，也不要为了省事同步 SQLite 文件。正确的第一步是把本地事实模型和 CloudKit records 之间的映射、journal、冲突检测和测试体系打牢。

最小可交付定义：

- 单用户、同 Apple Account、Mac / iOS 私有数据同步。
- 本地优先，离线可用。
- 设置页可启用、关闭、立即同步、查看状态。
- 历史事实不可被远端静默改写。
- 冲突可见、可恢复。
- 双设备真实路径通过。

## 参考资料

- Apple CloudKit overview: https://developer.apple.com/icloud/cloudkit/
- Apple WWDC23: Sync to iCloud with CKSyncEngine: https://developer.apple.com/videos/play/wwdc2023/10188/
- Apple CKSyncEngine documentation: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5
- Apple Core Data with CloudKit setup: https://developer.apple.com/documentation/CoreData/setting-up-core-data-with-cloudkit
- Apple Core Data / CloudKit model limitations: https://developer.apple.com/documentation/CoreData/mirroring-a-core-data-store-with-cloudkit
- Apple CloudKit error handling: https://developer.apple.com/documentation/cloudkit/ckerror
- Apple privateCloudDatabase quota note: https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase
- Apple iCloud Documents design guide: https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html
- Things Cloud support: https://culturedcode.com/things/support/articles/2803586/
- OmniFocus sync documentation: https://support.omnigroup.com/documentation/omnifocus/universal/4.3.3/en/managing-your-data/
- Bear syncing and privacy: https://bear.app/faq/syncing-privacy/
- Drafts CloudKit discussion: https://forums.getdrafts.com/t/does-icloud-sync-using-cloudkit-or-store-data-in-icloud-drive/8182
- Obsidian sync documentation: https://obsidian.md/help/sync-notes
- Agenda iCloud / Dropbox sync description: https://agenda.com/

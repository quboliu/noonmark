# 先建设通用同步底座，再接 CloudKit adapter

**Status**: Accepted

晷迹需要 iCloud 同步，但同步底座不能做成 iCloud 专用。第一步采用通用同步基础设施：平台无关 `SyncRecord`、本地变更流水、冲突模型、record mapper、merge engine 和 mock transport；CloudKit 只是第一种远端 adapter。

**Context**

晷迹当前是 Apple-first，但产品长期仍保留自定义同步端点和未来非 Apple 客户端可能性。若把合并、冲突、历史保护和重试策略直接写进 CloudKit / CKSyncEngine 层，后续自建服务端、WebDAV / S3-like 端点或局域网同步都必须重复实现同一套危险逻辑。

同时，晷迹的核心风险不在“能否上传记录”，而在“远端记录回来后是否会破坏历史事实”。日轨迹不可删除、历史不可改写、同一任务链最多一个 active pending trace、任务定义不可被静默覆盖、子任务必须挂在合法父 trace 下，这些都属于领域同步规则，应在通用层 fail-closed。

**Decision**

- 新增 `NoonmarkSync` target，依赖 `NoonmarkCore`，不依赖 CloudKit。
- `NoonmarkCore` 不依赖 `NoonmarkSync`。
- 通用层定义：
  - `SyncDeviceID`
  - `SyncRecord`
  - `SyncJournalEntry`
  - `SyncConflict`
  - `SyncRecordMapper`
  - `SyncRecordMerger`
  - `SyncRecordTransport`
  - `InMemorySyncTransport`
- Storage schema 先补齐同步底座表：
  - `sync_device_identity`
  - `sync_metadata`
  - `change_journal`
  - `sync_conflicts`
  - `sync_audit_log`
- 第一阶段不把 App 设置页标记为可用同步，不接 CloudKit entitlement，不碰真实 iCloud。
- 后续 CloudKit adapter 只负责 CloudKit account status、CKSyncEngine、CKRecord 转换、CloudKit error mapping 和 schema lifecycle，不承载领域合并规则。

**Consequences**

- iCloud、自建服务端和其他同步端点可以复用同一套合并与冲突逻辑。
- 真实 CloudKit 接入前，可以用 mock transport 做双设备状态机测试。
- 同步开发会比直接接 CloudKit 慢一步，但能先把数据一致性风险压低。
- 通用 mapper 以 canonical current JSON envelope 表达平台无关 records；`formatVersion = 1` 必需且 bytes 必须由当前 encoder 产生，避免合成 `Decodable` 把未知旧字段静默吞掉。CloudKit adapter 后续可把 payload 拆成 CKRecord fields，也可以保留 payload 加必要索引字段。
- 分类提交与轨迹分类事件是 immutable records：提交使用统一 typed delta，完整覆盖 `setCurrent`、创建、改名、生命周期、合并与硬删除；事件使用唯一 UUID、typed revision 与 predecessor。普通 `DayTrace` 不夹带可被覆盖的历史流或全局分类 revision。
- 分类提交以真正建立相关 item／关系事实的 change record ID 表达因果前驱；不能用全局 revision 相等推断因果。record 排序使用显式依赖 DAG、传递因果闭包与稳定拓扑序；缺父项、前驱提交、前驱事件或 revision frontier 时持久等待，依赖环与不可交换分叉 fail-closed。terminal 拒绝必须沿因果边传播，不能让其后代永久等待一个已确定不会应用的前驱。
- 精确 rename no-op 是 immutable 审计事实，不建立新状态事实、不推进 revision，也不能成为后续事实的因果前驱。hard delete 释放规范名称后，复用任何历史别名的新建提交必须显式依赖对应 hard-delete commit，防止乱序重放造成所有权分叉。
- 同一任务链的后继提交不能只依赖审计数组中的“最后一条”记录。接收端从 immutable before／after audit 重放主分类与各标签的 present／absent provenance：顺序观察到的 heads 收束成后继，发送端未观察到的并发 heads 全部保留为 causal frontier。merge 对 source 与 target 都是 exact-item causal barrier；rename 只与按稳定 item ID 的 `setCurrent` 关系写可交换，不能跨过 merge、lifecycle 或 hard delete。
- immutable outbox journal 采用 insert-or-exact-match CAS；相同 ID 只在全部持久化事实逐字节一致时幂等，不同 payload 或 metadata 必须回滚整个本地保存事务。`changedAt` 的 canonical fact 使用 `Date.timeIntervalSinceReferenceDate.bitPattern` 精确保存和比较，人类可读日期列只作为可校验投影，不能参与 CAS 身份判断。
- SQLite 中 `record_sequence` 与 `history_sequence` 只是 canonical order 的可重建投影，immutable identity 与完整内容才是历史事实。新并发事实排到既有记录之前时，必须在同一事务内无删除地重排 sequence；旧 ID 缺失或同 ID 异内容一律拒绝。
- 一轮远端下载的 snapshot、冲突、durable pending、审计、同步 metadata 与 terminal pending 清理必须由单个 `BEGIN IMMEDIATE` 事务提交。任何一步失败都回滚整轮下载，不能以补偿写或后续重试掩盖半提交。
- 可审查冲突必须持久化产生冲突的完整 canonical remote record，并在读取时复核 record ID、entity type 与 entity ID；远端下一轮不再返回该 record 时，仍保留足以解释和处理冲突的 immutable 证据。
- 所有 transport 都必须保护 immutable record identity。Local Folder／iCloud 路径采用原子 exclusive create-or-exact-match，InMemory 仿真采用同一语义；同 ID 的 payload、metadata、entity type 或 canonical file bytes 不同必须报 collision 并保留先到原件，普通 current records 才允许覆盖。
- 删除操作第一版 fail-closed，不支持远端删除历史事实。

**Alternatives Considered**

直接实现 CKSyncEngine：能更快看到 iCloud 同步效果，但会把领域合并和 CloudKit 操作耦合，后续难以复用，也更容易绕过历史保护。

直接同步 SQLite 或 JSON 数据包：实现表面简单，但文件同步无法安全处理多设备并发写、离线冲突和局部合并；这与既有本地优先 ADR 冲突。

迁移到 Core Data / SwiftData CloudKit：能得到自动 mirror，但会重写当前 Swift Package 领域层和 SQLite storage，且难以表达晷迹的领域不变量。

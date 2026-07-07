# 先建设通用同步底座，再接 CloudKit adapter

**Status**: Accepted

晷迹需要 iCloud 同步，但同步底座不能做成 iCloud 专用。第一步采用通用同步基础设施：平台无关 `SyncRecord`、本地变更流水、冲突模型、record mapper、merge engine 和 mock transport；CloudKit 只是第一种远端 adapter。

**Context**

晷迹当前是 Apple-first，但产品长期仍保留自定义同步端点和未来非 Apple 客户端可能性。若把合并、冲突、历史保护和重试策略直接写进 CloudKit / CKSyncEngine 层，后续自建服务端、WebDAV / S3-like 端点或局域网同步都必须重复实现同一套危险逻辑。

同时，晷迹的核心风险不在“能否上传记录”，而在“远端记录回来后是否会破坏历史事实”。日轨迹不可删除、历史不可改写、同一任务链最多一个 active pending trace、任务定义不可被静默覆盖、子任务必须挂在合法父 trace 下，这些都属于领域同步规则，应在通用层 fail-closed。

**Decision**

- 新增 `SuntraceSync` target，依赖 `SuntraceCore`，不依赖 CloudKit。
- `SuntraceCore` 不依赖 `SuntraceSync`。
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
- 第一版通用 mapper 以 JSON payload 表达平台无关 records；CloudKit adapter 后续可把 payload 拆成 CKRecord fields，也可以保留 payload 加必要索引字段。
- 删除操作第一版 fail-closed，不支持远端删除历史事实。

**Alternatives Considered**

直接实现 CKSyncEngine：能更快看到 iCloud 同步效果，但会把领域合并和 CloudKit 操作耦合，后续难以复用，也更容易绕过历史保护。

直接同步 SQLite 或 JSON 数据包：实现表面简单，但文件同步无法安全处理多设备并发写、离线冲突和局部合并；这与既有本地优先 ADR 冲突。

迁移到 Core Data / SwiftData CloudKit：能得到自动 mirror，但会重写当前 Swift Package 领域层和 SQLite storage，且难以表达晷迹的领域不变量。

# CloudKit 前先提供显式启用的 iCloud Drive 记录仓库

**Status**: Accepted

晷迹在 CloudKit entitlement、container 与 `CKSyncEngine` adapter 完成前，先把既有平台无关 `SyncRecord` 仓库接到用户的 iCloud Drive。这个端点用于当前 Mac 开发版本的同 Apple Account 数据交换，不是最终原生 CloudKit 架构。

## Context

通用同步底座已经具备设备身份、变更 journal、record mapper、确定性 merge、等待队列、冲突、审计和 SQLite 原子提交。继续把 iCloud 只展示成占位会阻止真实传输验证；直接同步 SQLite 或整个 JSON 数据包则会破坏本地事实源与局部合并边界。

当前本地 `.app` 使用 ad-hoc 签名，没有可用的自有 ubiquity container entitlement，但已登录 Apple Account 的 macOS 会提供用户可见的 CloudDocs 文件镜像。iCloud Drive 可能生成同名冲突副本，且文件上传由系统异步完成，不能把“本机写入成功”描述为“另一台设备已经收到”。

## Decision

- iCloud Drive 只承载逐条 canonical `SyncRecord`、snapshot index 与 ref；不承载 SQLite、WAL、SHM 或 `NoonmarkDataPackage` 整包同步。
- 正式 ubiquity container 可用时优先使用其 `Documents` 目录；当前 ad-hoc 开发包在确认 `ubiquityIdentityToken` 与 CloudDocs 目录都可用后，使用 `iCloud Drive/Noonmark/SyncRepository`。
- 同步默认关闭。用户必须显式启用；手动模式只在点击后运行，自动模式启用后立即运行一次，再按持久化间隔运行。
- 数据包导入不得与同步并发，也不得继承外来包的同步启用状态；目标 Mac 必须重新显式启用，避免导入后自动上传到当前 Apple Account。恢复必须先写入并回读当前 schema 的隔离 SQLite staging，再通过 SQLite Online Backup API 原子替换目标数据库；旧任务事实和旧同步运行态清除，只保留目标 Mac 的设备身份，失败时原库不变。
- 导入成功时必须从恢复后的本地事实重新建立 `localFirst.sync.baselineManifest` 与 pending journal。普通任务事实仍按实体 record 进入端点；已经存在但无法从单次 mutation 重建的完整分类历史，使用不可变 `classificationBaseline` bootstrap，后续修改继续使用 `classificationCommit` 与 `traceClassificationEvent`。分类基线只可初始化空分类历史、与完全相同状态去重，或在接收端已严格包含其历史时作为祖先忽略。它不携带 typed delta，不得整块推进非空接收端；同一不可变历史但 current 投影不同、声称是非空接收端后继，或历史互不相容时都必须形成冲突。非空接收端只能通过可重放的 `classificationCommit`／`traceClassificationEvent` 前进。
- 每次同步前必须审计本机当前事实是否已经由本机待上传 journal 或端点中的合法 upsert、同身份、canonical payload 精确一致的 record 覆盖。仅有较新的时间戳不能证明远端包含本机事实；payload 不同时必须先上传本机版本，再交由确定性 merge 汇合。分类历史必须由一条与本机历史相容的 baseline 加其后继 commit／event 覆盖，并使用正式接收端 merger 从空接收端实际重放到与本机逐字段一致的分类状态；不能把多条互不相容 baseline 的 ID 并集，或一条 baseline 与不可重放的同源分叉 ID，冒充可重建历史。端点被清空、切换，或当前事实缺少可验证覆盖时，必须先原子重建同步基线；pending 基线曾经分批上传时，所有可重试 journal 都必须重新入队，不能把后来已上传到旧端点的事实遗漏，也不能把可重试状态误判成损坏。设备身份缺失、基线 manifest 真正损坏、record 无法物化或基线没有全部上传时必须 fail-closed。
- “同步成功”是可验证状态，不是一次函数调用返回：同步在 App 内属于互斥数据操作，执行期间任务 mutation 与同步配置 mutation 均须关闭；内部上传批次必须排空，所有基线 journal entry 必须确认进入 `uploaded`，随后下载与合并也必须完成。下载期间产生的本机变更必须再追赶上传；追赶后重新抓取当前端点并审计完整覆盖，若端点在首次上传后被清空或切换，则在同一轮同步内重新入队、重建、上传和复核，不能沿用首次抓取结果写成功。最后还须在同一个 SQLite `BEGIN IMMEDIATE` 事务内确认 journal 全部为 `uploaded`，才可写入成功状态、成功时间戳并把基线标记为 established。同步前保存、transport 建立、传输、合并、metadata 回读或外部快照安装的任一步失败均保留本机任务事实、持久化 typed failure，并在正式 UI 显示可行动的错误；应用重启后仍须恢复该警告。关闭同步、切换模式或切换端点只改变下一次运行策略，不得把 operation history 重置为 idle；直到成功重试才清除警告，不得显示“同步完成”。
- `AppPreferencesRecord` 只交换主题和语言；数据模式、同步开关、端点、间隔、备份策略与设置页诗文不得进入远端 payload，也不得被远端覆盖。
- 同步前必须先成功保存当前 SQLite snapshot。保存失败时不得上传旧数据库状态，也不得用远端回读替换内存状态。
- iCloud 冲突副本按 record ID 收敛：普通 current record 复用确定性 merge；immutable record 只允许对象与 canonical bytes 完全一致，否则 fail-closed。
- 设置页展示本机仓库写入、等待、失败与未解决冲突状态，并明确系统上传可能延迟。S3 与 WebDAV 继续显示为规划中。
- `scripts/test-icloud-sync-live` 不进入默认 `make check`；手动运行时必须覆盖双 SQLite 合并、真实 `.app`、同步 metadata、仓库 ref 和 CloudDocs 上传完成信号。

## Risk And Rollout

- 灰度策略：新用户默认关闭；没有 Apple Account 或 iCloud Drive 时不能启用；本地 Todo 始终可用。
- 监控：`localFirst.sync.lastStatus` 保留配置后尚未执行、最近成功或致命失败，`localFirst.sync.baselineManifest` 保留 pending／established 基线及其 journal 证据，pending upload、durable waiting、terminal rejection、unresolved conflict 与 sync audit 也保留在本机 SQLite；设置页不得只显示笼统“成功”。
- 回滚：晷迹尚未发布，当前 schema 直接把 `classificationBaseline` 纳入 immutable sync entity 与 SQLite 约束，不迁移旧开发库。回滚实现并清除固定开发仓库即可恢复为本地单机路径；关闭同步只停止传输，不删除本机任务事实。
- 已知发布门禁：尚未用两台物理设备验证跨设备到达，也尚未接入 CloudKit account status、quota、throttle、push 与 zone lifecycle。完成这些门禁前，不得把此端点宣传为最终原生 CloudKit 同步。

## Consequences

当前版本能用真实 iCloud 服务验证通用同步协议与 App 事务边界，同时保持 SQLite 为事实源。文件型端点的系统级冲突与延迟仍存在，因此长期方案仍是 CloudKit private database + `CKSyncEngine` adapter；本 ADR 不取代该目标。

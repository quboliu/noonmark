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
- `AppPreferencesRecord` 只交换主题和语言；数据模式、同步开关、端点、间隔、备份策略与设置页诗文不得进入远端 payload，也不得被远端覆盖。
- 同步前必须先成功保存当前 SQLite snapshot。保存失败时不得上传旧数据库状态，也不得用远端回读替换内存状态。
- iCloud 冲突副本按 record ID 收敛：普通 current record 复用确定性 merge；immutable record 只允许对象与 canonical bytes 完全一致，否则 fail-closed。
- 设置页展示本机仓库写入、等待、失败与未解决冲突状态，并明确系统上传可能延迟。S3 与 WebDAV 继续显示为规划中。
- `scripts/test-icloud-sync-live` 不进入默认 `make check`；手动运行时必须覆盖双 SQLite 合并、真实 `.app`、同步 metadata、仓库 ref 和 CloudDocs 上传完成信号。

## Risk And Rollout

- 灰度策略：新用户默认关闭；没有 Apple Account 或 iCloud Drive 时不能启用；本地 Todo 始终可用。
- 监控：`localFirst.sync.lastStatus` 保留配置后尚未执行、最近成功或致命失败，pending upload、durable waiting、terminal rejection、unresolved conflict 与 sync audit 也保留在本机 SQLite；设置页不得只显示笼统“成功”。
- 回滚：实现不改 schema，也不迁移旧数据；回滚此提交并清除固定开发仓库即可恢复为本地单机路径。关闭同步只停止传输，不删除本机任务事实。
- 已知发布门禁：尚未用两台物理设备验证跨设备到达，也尚未接入 CloudKit account status、quota、throttle、push 与 zone lifecycle。完成这些门禁前，不得把此端点宣传为最终原生 CloudKit 同步。

## Consequences

当前版本能用真实 iCloud 服务验证通用同步协议与 App 事务边界，同时保持 SQLite 为事实源。文件型端点的系统级冲突与延迟仍存在，因此长期方案仍是 CloudKit private database + `CKSyncEngine` adapter；本 ADR 不取代该目标。

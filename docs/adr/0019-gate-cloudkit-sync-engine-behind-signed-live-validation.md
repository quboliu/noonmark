# 在签名与 live 门禁后启用 CloudKit CKSyncEngine

**Status**: Accepted

晷迹实现 CloudKit private database + `CKSyncEngine` adapter，但在 Apple 签名、development container 与真实 App 双库 live 验证完成前，只允许通过显式启动参数启用。普通开发包与用户默认路径继续使用已经真实验证的 iCloud Drive 逐记录仓库。

## Context

通用同步层已经负责 canonical `SyncRecord`、journal、确定性 merge、等待队列、冲突、审计与 SQLite 原子提交。CloudKit adapter 的职责是把这些记录可靠地映射到 CloudKit，并处理 account、zone、push 与 `CKSyncEngine` 持久化状态；它不得绕过通用领域合并层直接写任务事实。

当前机器没有有效 Apple code-signing identity，也没有仓库可证明的 provisioning profile 或 CloudKit container 授权。Ad-hoc 进程直接构造未授权 `CKContainer` 会触发进程级失败，因此 entitlement 检查必须发生在创建 container 之前。没有真实签名条件时，只能验证 adapter 的本地契约与失败边界，不能宣称 CloudKit live 已通过。

## Decision

- 使用用户 private database 和 custom zone `NoonmarkUserDataV1`。每条 `SyncRecord` 映射为 `NoonmarkSyncRecordV1`，保留 canonical wire payload、格式版本、稳定 record name 与 SHA-256；type、zone、字段、digest、canonical bytes 或记录身份不匹配时整批拒绝。
- SQLite `sync_metadata` 以 `cloudkit.sync.persistence.v1` 保存 container／zone／Development 或 Production scope、`CKSyncEngine` opaque state、Apple account record name、zone 状态、阻断原因、远端镜像与每条 record 的 server system fields。持久化成功前不得发布内存状态；scope 变化或无 scope 的旧状态不得被当前环境接管。
- 本机与远端记录仍通过通用 merger 收敛。Immutable identity 碰撞、外部 record 删除、zone 删除、account switch、损坏 state 或损坏 system fields 全部 fail-closed；不把远端空结果解释为删除，不提供正式 zone hard delete。
- `CKSyncEngine` transport 由 App Store 生命周期持有，显式 CloudKit 模式注册 macOS remote notifications。普通启动不创建 `CKContainer`，只有同时提供 `--cloudkit-container-id`，并通过 entitlement preflight 后才访问 CloudKit；设置页在启用前另行查询 `CKAccountStatus`，未登录、受限、临时不可用或无法确定时保持关闭。`--cloudkit-zone-name` 只用于隔离 live 验证。
- `scripts/build-mac-app` 的 CloudKit 模式必须显式提供 container、Development／Production 环境、非 ad-hoc identity 与 provisioning profile。构建前检查 profile allowlist 和有效期，签名后反查 App ID、team、container、service、environment 与 APNs entitlement；任何缺失都停止构建。
- `scripts/test-cloudkit-sync-live` 只允许 Development 环境，不进入 `make check`。它用真实签名 App 和两个独立 SQLite 数据库完成上传与下载，再通过仅允许 `NoonmarkLiveValidation-` 前缀的受控入口销毁隔离 zone。
- 数据包导出／恢复边界不变：普通 Todo 数据包不包含 CloudKit engine state、server fields、account identity、同步开关或烛龙 sidecar；导出时先把同步开关归一化为关闭，导入前同步撤销旧 transport 的 SQLite persistence lease，并等待 engine operations 取消完成后才替换数据库，导入后同步保持关闭。

## Risk And Rollout

- 风险等级：P。主要风险是错误 account／environment、远端删除被误应用、state 损坏、并发上传覆盖和 production schema 不匹配。
- 灰度：默认关闭；无显式 CloudKit 参数时继续走 iCloud Drive。CloudKit 参数只用于签名开发包与 live 验证，未完成两台物理设备和 Production schema 验收前不得成为默认端点。
- 监控：设置页与 `localFirst.sync.lastStatus` 展示最近同步结果；`cloudkit.sync.persistence.v1` 保留 engine state、account、zone 与阻断原因；CloudKit 错误只记录 code 与 retry delay，不记录用户 payload 或 device token。
- 回滚：移除 CloudKit 启动参数即可回到 iCloud Drive transport；关闭同步只停止传输，不删除本机 SQLite 事实。遇到 account switch、zone 删除或外部 record 删除时保持阻断，必须由后续显式恢复流程处理，不自动清空或重建正式 zone。
- 当前门禁：本机 `security find-identity -v -p codesigning` 为 0 个有效 identity，因此只验证了 adapter、持久化、真实 ad-hoc App 的 entitlement preflight 与签名输入失败路径；CloudKit development／production 网络 live 尚未通过。

## Consequences

CloudKit adapter 已具备可审查、可持久化、可隔离验证和可回滚的接入边界，同时不会降低当前可用的 iCloud Drive 同步与数据包恢复能力。后续取得 Apple Developer 签名资产后，可以直接运行 live 门禁取得真实 CloudKit 证据；在此之前，产品与文档必须继续显示当前实际 transport，不得把 adapter 存在等同于云端已经可用。

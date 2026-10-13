# Web 采用互斥数据事实源与 Go 模块化后端

**Status**: Proposed

**Task-ID**: `noonmark-web-architecture`

## 背景

用户于 2026-10-12 要求为晷迹规划 Web 版本，后端使用 Go，同时支持本地优先与账号优先，并将构建测试状态外置到 `/share/broker/`。现有 ADR-0009 已规定本地优先／在线优先互斥，但仓库尚无账号服务和 Web 运行面。

## 提议

- 产品所说账号优先沿用领域枚举 `onlineFirst`；登录与选择数据模式分离。账号身份不能触发自动上传或模式切换。
- React／TypeScript PWA 在本地优先时以 IndexedDB 提交事实；Go 模块化单体在在线优先时以 PostgreSQL 提交事实。在线离线草稿不是已确认任务事实。
- 共用领域协议、黄金向量和 UI 应用接口，分别实现 TS／Go 领域引擎，与 Swift 对账。原生 format 7 通过无损 codec 互通，不直接解析丢精度的整数。
- 同一 dataset 只有一种 authority；模式切换使用新 dataset ID、冻结、staging、manifest 校验及幂等激活。旧设备离线事实在回归时对账，不能自动覆盖新数据集。
- 本地托管复制与在线命令是独立协议，relay 不裁决本地领域事实；不直接把现有 iCloud 目录接到 Web。
- 首期 API 与 worker 同 Go module，PostgreSQL 承载事务、outbox 和队列；大对象放私有对象存储。身份服务通过 OIDC 接入，API 使用 Bearer。
- 当前 checkout 保留源码和分支操作；本机 `.work` 软链接到 `/share/broker/noonmark-build`，工具 wrapper 必须使实际产物与测试数据留在外置根。

## 后果与边界

维护三种语言的领域实现会增加成本，必须以命令／快照差分门禁控制漂移。浏览器无法提供原生文件系统保留、系统快捷键或 ThisDeviceOnly 身份的同等保证，需要明确产品能力和恢复机制。

切换新 dataset 避免网络分区下的双主，但需要用户处理离线旧设备的迟到变更。服务端事务、RLS、设备授权、加密和恢复必须通过运行证据才能对外承诺商业可靠性。

本 ADR 不宣告 Web 已实现，也不修改现有原生 schema、发行管道或同步协议。目录配置按本次用户指示生效；其余架构取舍仍为提案，后续实现中经评审和证据补齐后再更新状态。

## 备选

- 纯在线 CRUD：不能满足无账号核心功能和历史轨迹。
- 所有写入都先本地再同步：改变在线优先的事实源契约，增加双重冲突裁决。
- 首期微服务或全字段 CRDT：增加运行与一致性成本，仍不能自动维护日锁和轨迹拓扑。
- SQLite WASM 默认复用：不能直接复用 Swift 领域层，也不能消除浏览器数据保留风险；保留为量测后的存储备选。

完整依据、协议、风险、灰度、回滚及验收见[设计方案](../tasks/noonmark-web-architecture/README.md)、[数据协议](../tasks/noonmark-web-architecture/data-protocol.md)、[交付计划](../tasks/noonmark-web-architecture/delivery-plan.md)和[工作目录契约](../engineering/web-build-workspace.md)。

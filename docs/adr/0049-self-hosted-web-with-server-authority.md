# Web 采用服务端事实源，先交付个人自部署实例

**Status**: Accepted（分阶段实施）

**Task-ID**: `noonmark-web-architecture`

## 已确认的产品决定

2026-10-12 用户取消 Web 本地优先，要求借鉴思源的自部署方式，并进一步确认：个人实例优先，官方托管以后复用同一内核。一套实例供一位 owner 使用，多台设备访问同一个服务。用户随后授权开工；该架构按阶段实施，未完成能力和技术差异见[实施记录](../tasks/noonmark-web-self-hosted/README.md)。接受决策不代表所有门禁已经完成。

本 ADR 取代 [ADR-0048](0048-propose-web-dual-authority-and-go-backend.md)。原生 Mac 的 ADR-0009、iCloud V2、数据模式和运行隔离继续有效；Web 不复制它们的模式切换入口。

## 提议

- React／TypeScript 负责在线界面，Go 服务执行唯一的 Web 领域规则。浏览器只保留缓存和非事实草稿；无 Go WASM、浏览器任务数据库、离线命令自动回放或本地复制 relay。
- 首期为一个应用容器和一个持久数据目录。Go 同源服务静态资源、API 与后台任务；SQLite 位于服务器本地文件系统，持有独占数据根锁，事务协调器串行写入。
- 不要求官方账号或外部服务即可完成个人实例安装、认证、核心使用、导出与恢复。首期只有 owner，不实现多用户、双数据库或托管计费。
- 事实、exact clock frontier、幂等 receipt、change batch 与 jobs 同事务提交；网络结果未知时查询原 command ID，不生成新 ID 盲目重发。
- Swift／Go 通过领域向量与无损 format 7 codec 对账。导入、备份、恢复与搬迁各有独立契约，不把文件复制称为分布式事务。
- 备份用一致 snapshot 并验证密钥可恢复；升级走维护窗口和兼容表。旧请求经 instance epoch fencing，不用清库或覆盖历史修复错误。
- 源码及分支继续在当前 checkout；构建测试状态继续位于 `.work` 对应的 `/share/broker/noonmark-build`，不得为打包前端而在源码生成 `dist`。

## 后果、风险与验证

取消浏览器领域和复制引擎后，事实规则只需在 Swift 与 Go 之间保持一致。Web 无法访问服务时不提交任务；局域网服务可达时，外网断开不影响核心功能。

SQLite 适合个人单实例的运行边界，但不提供多副本共享卷或单机无故障保证。数据根锁、可靠磁盘、异机备份、真实恢复和受控升级是发行条件。未来托管可先运行隔离个人实例；引入 PostgreSQL 必须由实际容量／运营证据驱动。

原方案基线保留在 Git 历史；首次设计提交只修订文档，后续 Web 实施在同一 checkout 的开发分支推进，不变更原生数据。风险、回滚、灰度和症状门禁见[架构方案](../tasks/noonmark-web-architecture/README.md)、[数据协议](../tasks/noonmark-web-architecture/data-protocol.md)、[自部署运维](../tasks/noonmark-web-architecture/self-hosting.md)和[实施计划](../tasks/noonmark-web-architecture/delivery-plan.md)。

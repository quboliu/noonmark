# Noonmark 正式版本机诊断证据

- Task-ID：`noonmark-cloud-sync-debug`
- 风险等级：P
- 状态：实现与自动化终审完成；真实候选 `.app`／`.ips` 人工发行门禁待执行

## 目标

为正式版补齐有证据能力且严格控盘的本机诊断系统：以强类型事件串起同步、任务修改、持久化与跨重启状态；应用管理的诊断文件实际占用始终不超过 4 MiB，最长保留 7 天；不记录任务正文、路径、iCloud 内容、AI 内容或凭证，也不自动上传。

## 约束与验收

- 宿主机正式数据库、iCloud 同步仓库与 Keychain 只读，本任务不得执行会清理这些资料的开发 reset。
- 用户可先查看 manifest，再主动导出或清除诊断资料；清除边界不得触及业务数据。
- MetricKit 只作非保证交付的补充；release 必须保留可与 Mach-O UUID、binary SHA 对账的 dSYM。
- 以隔离 SwiftPM scratch、隔离 App data root、真实 `.app` 和 DMG 路径完成容量、隐私、异常退出与导出验证。

详细设计、风险、灰度、回滚与门禁见 `docs/adr/0042-use-bounded-typed-local-diagnostic-evidence.md`。

## 已交付

- 候选版本提升为 `0.1.1 (2)`；“关于晷迹”与发行 manifest 可对账 Version、Build、Commit、UTC Build Date、OS 与架构，打包链另外保留 Mach-O UUID、binary SHA、dSYM 和 DMG identity。
- 同步、任务修改、持久化、启动与退出路径写入固定 schema 的强类型事件；operation ID、incident ID 与 active marker 可跨重启关联，长时间同步只记录安全进度变化与有界心跳。
- App 管理的证据按实际 allocated size 执行 4 MiB 硬上限与 7 天保留；critical drop、compaction、corrupt、oversized 与 Metric eviction 均进入 manifest，不把缺失伪装成完整证据。
- 诊断文件操作固定在初始化时持有的目录 descriptor 下；读取、轮替、删除和 MetricKit 采集均验证文件身份、owner、link count 与类型，并对序列耗尽 fail-open 关闭 file sink。
- 用户可在 App 内预览、导出和清除诊断资料；不会自动上传，也不会记录任务正文、路径、同步 payload、Provider 内容或凭证。操作与分析流程见 `docs/engineering/noonmark-diagnostic-reporting.md`。

## 当前证据与发行边界

- `NoonmarkDiagnosticsTests` 当前 57／57 通过；规格、工程规范与文件安全终审均为 0 blocker，诊断／发行静态 guard 已通过。
- 本任务刻意不把首次宿主机同步故障的未证实假设当成根因，也不宣称已经修复该故障；`0.1.1 (2)` 的目标是在下一次异常发生时保留足以重建现场的证据。
- 宿主机正式数据库、iCloud 同步目录与 Keychain 全程未触碰。因开发 reset 会清除这些资料，本工作树只使用隔离 SwiftPM scratch 进行自动化验证。
- 公开发版前仍须以精确候选构建完成真实 `.app`／DMG 用户路径验收，并使用 Developer ID 签名、notarization 后实际产生的 `.ips` 对 dSYM 做一次符号化演练；两项未完成时不得将候选描述为可公开发布。

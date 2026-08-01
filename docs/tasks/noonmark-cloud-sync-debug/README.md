# Noonmark 正式版本机诊断证据

- Task-ID：`noonmark-cloud-sync-debug`
- 风险等级：P
- 状态：实施中

## 目标

为正式版补齐有证据能力且严格控盘的本机诊断系统：以强类型事件串起同步、任务修改、持久化与跨重启状态；应用管理的诊断文件实际占用始终不超过 4 MiB，最长保留 7 天；不记录任务正文、路径、iCloud 内容、AI 内容或凭证，也不自动上传。

## 约束与验收

- 宿主机正式数据库、iCloud 同步仓库与 Keychain 只读，本任务不得执行会清理这些资料的开发 reset。
- 用户可先查看 manifest，再主动导出或清除诊断资料；清除边界不得触及业务数据。
- MetricKit 只作非保证交付的补充；release 必须保留可与 Mach-O UUID、binary SHA 对账的 dSYM。
- 以隔离 SwiftPM scratch、隔离 App data root、真实 `.app` 和 DMG 路径完成容量、隐私、异常退出与导出验证。

详细设计、风险、灰度、回滚与门禁见 `docs/adr/0042-use-bounded-typed-local-diagnostic-evidence.md`。

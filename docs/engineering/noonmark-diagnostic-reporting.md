# 晷迹诊断资料上报与分析

晷迹 `0.1.1 (2)` 起使用有界的本机诊断证据。App 不会自动上传诊断资料；用户必须先查看摘要，再自行选择保存位置。App 管理的诊断文件实际占用不超过 4 MiB，最长保留 7 天，因此问题发生后应尽快导出。

## 用户上报步骤

1. 问题出现时记下界面显示的“诊断编号”和大致时间；如界面允许，先不要清除诊断记录或同步目录。
2. 打开“设置 → 隐私 → 本机诊断记录”，先查看摘要。若 App 仍在“同步中”，此时导出可以保留 active operation；若必须重启，重启后再次导出可以保留 previous-session interruption 与持久化失败恢复证据。
3. 选择“导出诊断资料…”，保存 `.noonmarkdiagnostics` 文件。导出过程不自动发送，也不读取 Todo 正文、同步 payload、Provider 内容或 Keychain 凭证。
4. 打开“关于晷迹”，选择“复制版本信息”，把完整文字与诊断编号、复现时间、可见症状和诊断文件一起交给开发者。
5. 若发生 crash 或系统生成 hang report，再从 Console 的 Crash Reports 中由用户主动导出对应 `.ips`。不要以截图或手写堆栈替代原始 `.ips`；分享前仍应由用户检查系统报告内容。

导出成功后可以继续使用 App；在开发者确认收到资料前，不要点击“清除本机诊断记录”。清除只会删除晷迹管理的诊断根，不会触碰任务、烛龙资料、同步仓库或数据包。

## 开发者取证顺序

1. 先核对 manifest 的 schema、Version、Build、Commit、Date、Mach-O UUID、binary SHA scope、实际 Darwin 与架构；身份不完整或与发行 manifest 不一致时停止归因。
2. 检查 `collectionWasPartial` 以及 drop、critical drop、compaction、corrupt、oversized 和 Metric eviction 计数。缺失计数不为零时，只能说明证据不完整，不能把“未找到事件”解释为“事件没有发生”。
3. 按 sequence 重建 typed event 时间线，再以 operation ID 和 incident ID 对账 active operation、operation capsule、mutation rejection、operation terminal 与 persisted sync failure loaded。
4. 对停滞只接受最后一个已记录 stage／safe progress；active marker 证明导出当时仍未完成，previous-session interruption 只证明上次退出时未完成，不推断 crash、强退或断电。
5. 底层错误只按白名单 domain 与数字 code 分析。SQLite primary／extended code、POSIX code、CloudKit code和持久化 sync reason 必须分别保留；不得从 UI 文案反推底层根因。
6. 若有 `.ips`，以候选 DMG manifest 绑定的 Mach-O UUID、最终签名 binary SHA、dSYM UUID 与 inventory 完成对账后再符号化。MetricKit 未送达不代表没有 crash 或 hang。

## 隐私与边界

诊断包不应包含任务标题或描述、标签名称、文件路径、同步端点字符串、iCloud 内容、AI prompt／response、API Key、邮箱、IP、URL 或长 Base64。发现这些内容属于发布阻断；不得为了临时定位而扩大 schema、保存原始 `Error` 或启用自由文本日志。

本流程不宣称日志 tamper-proof，也不把日志系统失败传播到 Todo 或同步语义。诊断文件 sink 失效时 App 会 fail-open 回退到 macOS Unified Logging；manifest 必须显式标记 partial，不能制造完整证据的假象。

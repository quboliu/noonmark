# macOS 客户端证据级日志与诊断包研究

最新确认日期：2026-07-31

状态：一手资料调研与方案收敛完成；尚未实施产品代码，等待审批。

## 研究问题

晷迹需要一套随正式版交付的客户端可观测系统，同时满足两个看似冲突的目标：

1. 用户遇到任务修改失败、同步长期不结束、重启后提示同步未完成等问题时，客户端必须留下足以重建操作时序、验证假设和定位失败层级的证据；
2. 日志不能无界增长，不能记录任务正文、iCloud 内容、凭证或其他用户资料，也不能因为写日志失败而妨碍任务保存与同步。

本轮只研究公开一手资料与当前仓库，不读取宿主机用户数据，不采集真实 iCloud 内容，也不修改产品代码。

## 结论

晷迹不应在“只用 Apple Unified Logging”和“自己写一个传统文本日志文件”之间二选一。适合 macOS 14 正式版的根本方案是三层证据体系：

1. **Apple `Logger` 是系统主通道**：保留 release log point，利用 subsystem/category、等级、隐私插值和系统统一存储；它适合与 Console、`log`、Instruments 及系统事件关联。
2. **App 自有的结构化 evidence ring 是支持包主通道**：只双写低频、固定 schema 的操作开始、阶段转换、终态和失败；由 App 自己执行严格 byte cap，解决沙盒 App 无法导出前次进程 Unified Log 的边界。
3. **MetricKit 与完整系统 `.ips` 是异常补充证据**：MetricKit 补充 crash、hang、CPU 与异常磁盘写入，完整 `.ips` 用于权威崩溃分析；两者都不能替代业务 operation marker。

关键约束如下：

- Unified Log 是**系统级自动控盘**，Apple 只承诺持久等级写入到系统 storage limit，未提供 App 可配置的固定保留天数或 per-app byte quota；因此不能把它表述为“晷迹最多占用 2 MiB、保留 7 天”。[Apple 的等级与存储说明](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
- 自有 evidence ring 才承担**产品级硬上限**。建议首版以 `2 MiB / 7 天` 为稀疏 operation evidence 的起始预算，并把所有临时文件、轮转文件和 MetricKit 缓存纳入 `4 MiB` 绝对目录上限；这些是 Noonmark 的待压测设计值，不是 Apple 标准。
- 证据应由固定 event code 和字段白名单组成，不接受任意字符串日志。任务标题、描述、备注、AI prompt/response、完整路径、URL query、iCloud account、token、数据库内容和原始 payload 一律禁止进入日志。
- 支持包必须由用户主动生成，生成前可查看 manifest 和将包含的文件；首版只“存储/分享”，不自动上传，也不生成公开链接。

## 当前仓库事实与适用范围

- [`Package.swift`](../../Package.swift) 的 deployment target 是 macOS 14，因此 `Logger` 与旧版 `MXMetricManager`/`MXDiagnosticPayload` 可用；2026 年新增的 Swift-first `MetricManager` 要求 macOS 27，不适用于当前产品。[MetricKit 更新](https://developer.apple.com/documentation/updates/metrickit)
- 本轮对 `App/`、`Sources/`、`Package.swift` 的静态检索没有发现正式版 `Logger`、`OSLog`、SwiftLog 或 MetricKit 实现。现有 E2E 脚本会归档 Unified Log 与 DiagnosticReports，这是研发验证机制，不是用户可导出的正式版诊断机制。
- 当前产品是原生 Swift/SwiftUI macOS App；Electron、Rust、Gecko 的实现只能提供经过边界审查的设计参考，不能直接复制。

## Apple 平台事实

### Unified Logging 的保留语义

Apple 说明 Unified Logging 先把消息放入内存，再按等级决定是否持久化；持久消息会压缩写入系统 data store，超过预定义容量时淘汰旧消息。[Apple：Generating Log Messages from Your Code](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)

| Apple 等级 | 默认落盘 | 晷迹应承担的内容 |
| --- | --- | --- |
| `debug` | 否 | 可丢弃的开发细节；不进入自有 ring |
| `info` | 通常只在内存；可由 `log` 工具收集 | 稀疏的正常阶段细节；默认不依赖它做事后证据 |
| `notice` / default | 是，受系统 storage limit 约束 | 操作开始、终态、少数关键阶段；必须低频 |
| `error` | 是，受系统 storage limit 约束 | 可恢复或用户可见失败 |
| `fault` | 是，受系统 storage limit 约束 | 代码 invariant、数据完整性破坏；不能拿来表示普通失败 |

Apple DTS 进一步指出，记录越多，整个系统可回溯的时间窗越短；一个 subsystem 配少量 category 即可，持久日志量过高还可能触发 process quarantine，之后该进程的持久日志会被丢弃。[Apple DTS：Your Friend the System Log](https://developer.apple.com/forums/thread/705868) [Apple DTS：log quarantine](https://developer.apple.com/forums/thread/814022)

因此，晷迹不能把每次 SQLite row、CloudKit record、UI keystroke 或同步轮询都写成 `notice/error`。高频循环只应记录：进入阶段、离开阶段、失败、超过阈值后的低频 heartbeat，以及聚合后的 `occurrenceCount/firstSeen/lastSeen`。

### Unified Logging 的隐私语义

Apple 的 Swift `Logger` 会默认隐藏动态字符串和复杂对象，但整数、浮点数和 Boolean 默认不隐藏；敏感标量仍需显式标成 private。`mask.hash` 只保证当前进程内可比较，不能当成跨重启的稳定关联 ID。[Apple：日志隐私与 hash mask](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code) [Apple：`OSLogPrivacy.Mask.hash`](https://developer.apple.com/documentation/os/oslogprivacy/mask/hash)

这带来三条直接约束：

1. 所有动态字段默认按私密处理，只有经过字段白名单证明安全的 enum、计数、时长、错误 domain/code、版本号才能显式 public；
2. 不以“字符串默认 private”为借口先拼接包含用户内容的整段 message，因为自有文件 sink 不会自动获得 Apple 的隐私保护；
3. 跨重启关联使用 App 随机产生、与用户数据无关的 `sessionID` 和 `operationID`，不用任务标题或低熵用户内容的 hash。

Apple DTS 也明确提醒，先把任意内容拼成字符串再转发到 OSLog 的通用 wrapper 会破坏编译器提供的效率与隐私优势。[Apple DTS：system log wrapper 边界](https://developer.apple.com/forums/thread/705868) 因此可共享的是强类型 `EvidenceEvent`，不是 `log(String)`。

### `OSLogStore` 不是跨重启支持包来源

`OSLogStore` 能读取固定范围的 Unified Log entries；`.currentProcessIdentifier` 的作用域只包含当前进程。[Apple：`OSLogStore`](https://developer.apple.com/documentation/oslog/oslogstore) [Apple：Scope](https://developer.apple.com/documentation/oslog/oslogstore/scope) 对于“沙盒 Mac App 读取前次运行自己的日志”，Apple DTS 的答复是这组要求没有可用方案；完整 system scope 含有大量其他进程的敏感资料，不能授予普通沙盒 App。[Apple DTS：previous-run system logs](https://developer.apple.com/forums/thread/744806)

macOS 的 `OSLogStore.local()` 还要求 admin account 与 `com.apple.logging.local-store` entitlement，不适合作为普通发布版的一键导出路径。[Apple：`OSLogStore.local()`](https://developer.apple.com/documentation/oslog/oslogstore/local())

所以：

- 当前进程的 Unified Log 可用于开发者现场诊断或补充预览；
- 正式版不能依赖它导出前次 crash、前次启动或 extension/process 的完整历史；
- 跨重启证据必须由受控的 App-owned ring 保留。

### MetricKit 在 macOS 14 的位置

`MXDiagnosticPayload` 可包含 crash、hang、CPU exception、app launch 和 disk-write exception，并提供 JSON representation；macOS 12 以后诊断在 available 时会尽快交付。[Apple：`MXDiagnosticPayload`](https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload) [Apple：`MXMetricManager`](https://developer.apple.com/documentation/metrickit/mxmetricmanager)

但 Apple 没有为旧 API 承诺 exactly-once 或可由 App 查询的持久队列；`pastDiagnosticPayloads` 只反映当前 shared manager 初始化后的当前 session/lifetime，明确不含 previous app instances。[Apple：`pastDiagnosticPayloads`](https://developer.apple.com/documentation/metrickit/mxmetricmanager/pastdiagnosticpayloads) 所以“没有收到 MetricKit payload”不能证明没有发生问题，收到 payload 也未必包含业务阶段。MetricKit 必须被定义为系统异步、非保证交付的补充证据，不能替代 `sync.started`、`sync.stage.entered`、`sync.failed` 等 App operation marker。

当前 macOS 14 应使用 `MXMetricManagerSubscriber` 接收诊断并立即写入受限缓存；macOS 27 的新 `MetricManager` async sequence 只作为未来 migration seam。[Apple：MetricKit 2026 更新](https://developer.apple.com/documentation/updates/metrickit)

### 系统 crash report

Apple 要求优先分析完整、由操作系统生成且已 symbolicate 的 crash report；第三方或不完整报告可能遗漏必要信息。[Apple：Analyzing a crash report](https://developer.apple.com/documentation/xcode/analyzing-a-crash-report) macOS 用户可在 Console > Crash Reports 找到对应 binary 的报告并 Reveal in Finder；分享前还应检查和移除敏感资料。[Apple：Acquiring crash reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)

发行流程必须保留每一个公开 build 的 archive/dSYM；Apple 明确说明丢失 archive 可能使 crash report 无法诊断。[Apple：Building with debugging information](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information)

首版不应默认扫描整个 `~/Library/Logs/DiagnosticReports`，也不应自动收集 sysdiagnose。更安全的产品路径是：MetricKit 自动进入小型受限缓存；若支持人员确实需要完整 `.ips`，由用户在 Console 中选择或通过 `NSOpenPanel` 显式附加，且支持包 manifest 清楚显示该文件。

## SwiftLog 的边界

SwiftLog 定义统一 API 与 `LogHandler`，默认 stream handler 只是便利实现；官方源码明确建议 production App 自己实现 handler 或选择 backend。[SwiftLog `LoggingSystem`](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/LoggingSystem.swift#L15-L31)

若晷迹采用 SwiftLog：

- `LoggingSystem.bootstrap` 每个进程最多调用一次，重复调用是 undefined behavior，通常会 crash；应在 `@main` 最早期、任何 `Logger` 创建前完成。[SwiftLog bootstrap 契约](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/LoggingSystem.swift#L42-L76)
- 自定义 factory 必须继续传递 metadata provider，否则调用点 metadata 不会自动进入 handler。[SwiftLog metadata provider 契约](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/LoggingSystem.swift#L110-L118)
- file handle 等昂贵或会失败的资源应在可抛错的初始化阶段打开；`log(event:)` 本身不能 throw。handler 不应阻塞调用线程，也不应长期持有大量 messages。[SwiftLog handler 指南](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/Docs.docc/ImplementingALogHandler.md#L105-L117) [SwiftLog performance 指南](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/Docs.docc/ImplementingALogHandler.md#L356-L360)
- SwiftLog 的 level、metadata 和 multiplex 不等于磁盘轮转或隐私策略；这些仍须由 Noonmark handler 实现。metadata attribute 只有 handler 主动检查才有效，不能假设任意 backend 会自动脱敏。[SwiftLog metadata attributes](https://github.com/apple/swift-log/blob/7af2de138f5f0fddf0bd5c7e19face6944ed76af/Sources/Logging/Docs.docc/ImplementingALogHandler.md#L313-L354)

本项目只面向 Apple 平台，目前没有必须兼容其他 logging ecosystem 的约束。因此首版可优先用原生 `Logger` 加独立的 typed evidence recorder，减少一层依赖；若团队希望所有模块接受统一 `Logger`，SwiftLog 可作为 facade，但 OSLog sink 仍必须保留逐字段 privacy，而不能把整个拼接字符串标为 public。

## 开源 macOS 产品取证

所有源码链接固定到本轮审查的 commit，避免 `main` 漂移。

### 容量、轮转、导出与脱敏对照

| 产品与源码 | 明确常量/保留方式 | 导出入口与脱敏路径 | 可借鉴之处 | 不能照抄之处 |
| --- | --- | --- | --- | --- |
| NetNewsWire（原生 Swift/macOS） | ActivityLog 只在内存保留最近 `500` 个 completed activity；ErrorLog SQLite 在初始化时 prune 到 `200` 条。[ActivityLog](https://github.com/Ranchero-Software/NetNewsWire/blob/52030006b5a3a45d865bd03a455f85d3f1327077/Modules/ActivityLog/Sources/ActivityLog/ActivityLog.swift#L15-L34) [ErrorLog](https://github.com/Ranchero-Software/NetNewsWire/blob/52030006b5a3a45d865bd03a455f85d3f1327077/Modules/ErrorLog/Sources/ErrorLog/ErrorLogDatabase.swift#L13-L38) | async/sync wrapper 自动记录 pending → running → completed/failed 和 duration；crash window 让用户查看并决定不发送。[operation wrapper](https://github.com/Ranchero-Software/NetNewsWire/blob/52030006b5a3a45d865bd03a455f85d3f1327077/Modules/ActivityLog/Sources/ActivityLog/ActivityLog.swift#L72-L115) [crash UI](https://github.com/Ranchero-Software/NetNewsWire/blob/52030006b5a3a45d865bd03a455f85d3f1327077/Mac/CrashReporter/CrashReporter.swift#L14-L46) | operation lifecycle、自动终态、用户可见性很适合 Swift App。 | 500/200 都是 count cap，不是 byte cap；`errorMessage` 没有单条长度或字段隐私契约，ActivityLog 重启即失。 |
| Signal Desktop（支持 macOS，Electron） | 默认每天轮转，保留 `3` 个历史文件加当前文件；启动时只留最近 `3` 天。[轮转常量与 interval](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/util/rotatingPinoDest.node.ts#L10-L27) [轮转实现](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/util/rotatingPinoDest.node.ts#L45-L98) [三天清理](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/logging/main_process_logging.main.ts#L144-L169) | sink 设置前注入统一 `redactAll`；电话号码、UUID、银行卡、attachment key 和敏感路径都有集中脱敏；用户先看到日志窗口，再主动上传 gzip。[sink](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/logging/main_process_logging.main.ts#L58-L98) [redactor](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/util/privacy.node.ts#L16-L34) [组合脱敏](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/util/privacy.node.ts#L218-L234) [用户提交](https://github.com/signalapp/Signal-Desktop/blob/34fa4531bb74725ab2edb04a18a4e3542eea2694/ts/components/DebugLogWindow.dom.tsx#L55-L105) | 写盘前集中脱敏、导出时字段再筛选、脱敏测试都值得采用。 | 只有时间/文件数上限，没有当前文件 byte cap；高频故障仍可让单日文件膨胀。debuglogs.org 返回公开 URL 的上传模式不应成为晷迹默认。 |
| Mullvad VPN（支持 macOS，Electron/Rust） | problem report 每个来源只读文件尾 `128 KiB`；发送阶段最多读取 `5 × 128 KiB + 32 KiB = 672 KiB`，最多尝试 `3` 次。[常量](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/mullvad-problem-report/src/lib.rs#L17-L33) [尾部读取](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/mullvad-problem-report/src/lib.rs#L655-L669) | 本地日志从不自动发送；用户明确进入 Report a problem，可先 View app logs；report builder 脱敏 account、home、IP、MAC、UUID 与自订字符串。[公开政策](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/docs/logging-and-telemetry.md#L8-L42) [builder 脱敏](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/mullvad-problem-report/src/lib.rs#L431-L505) [View/Send UI](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/desktop/packages/mullvad-vpn/src/renderer/components/views/problem-report/ProblemReportView.tsx#L126-L203) | 每来源 cap、总发送 cap、只取最新尾部、用户预览和二次脱敏是最直接的支持包先例。 | desktop 原始 log 只轮成一个 `.old`，没有 runtime byte cap。[desktop rotation](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/desktop/packages/mullvad-vpn/src/main/logging.ts#L78-L105) 672 KiB 是发送读取预算，不代表生成中的原始日志文件一定不超过该值。 |
| Firefox（支持 macOS，Gecko） | `rotate:N` 保存最近 N MB，循环使用 `.0` 至 `.3` 四个文件；官方例子 `rotate:200` 是四个各 50 MB。[Gecko Logging](https://firefox-source-docs.mozilla.org/xpcom/logging.html) | `about:logging` 可在运行时只开启指定模块和复现时段；默认日志关闭。[Gecko Logging](https://firefox-source-docs.mozilla.org/xpcom/logging.html) | 明确总 byte budget、模块化临时提升和循环文件，而非无限 append。 | 它是开发/支持专项采集，不是隐私安全的常驻用户日志；HTTP log 可能含 URL 与 cookies。[Firefox HTTP Logging](https://firefox-source-docs.mozilla.org/networking/http/logging.html) `200 MB` 例子不适合晷迹常驻预算。 |

### 从源码得到的额外边界

Mullvad 的 iOS Swift 模块提供 `2_000_000 bytes + 7 days` 的启动时清理策略，并用 SwiftLog `MultiplexLogHandler` 同时写 file 与 OSLog。[Mullvad iOS `LogRotation`](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/ios/MullvadLogging/LogRotation.swift#L12-L30) [Mullvad iOS `LoggerBuilder`](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/ios/MullvadLogging/LoggerBuilder.swift#L37-L100) 这段 Foundation 算法可移植到 macOS，但它只在安装 file output 前扫描旧文件，不限制当前 session 持续写入，因此仍不是 writer-level hard cap。

同一项目的 `OSLogHandler` 会把 metadata 与 message 先拼接，再把整段标为 `%{public}s`，并将 trace/debug 映射到 info。[Mullvad iOS `OSLogHandler`](https://github.com/mullvad/mullvadvpn-app/blob/c516040c8eed6148009b193e1266d535af847b9a/ios/MullvadLogging/OSLogHandler.swift#L56-L89) 这是晷迹必须避免的反例：它绕过逐字段 privacy，且提高低级别日志的可见度。

Firefox 的实现把 N MiB 除以四作为单文件阈值，并在写入后发现 `ftell` 超限才切到下一个文件。[Firefox `Logging.cpp` 配额换算](https://searchfox.org/firefox-main/source/xpcom/base/Logging.cpp#1308-1314) [Firefox 写后轮转](https://searchfox.org/firefox-main/source/xpcom/base/Logging.cpp#2060-2108) 这说明若产品承诺“绝不超过 X bytes”，必须限制单事件大小并在 append **之前**轮转；否则仍可能超出一个 event。

## 晷迹建议方案（待审批）

### 1. 模块边界

建议建立一个独立 `NoonmarkDiagnostics` deep module，对其他模块只暴露：

- `record(_ event: EvidenceEvent)`：非阻塞、不可抛错；
- `withOperation(...)`：自动生成 operation ID，并保证 start 与 completed/failed 终态；
- `exportDiagnostics(...)`：用户主动生成可预览支持包；
- `diagnosticHealth`：只读返回容量、最早/最新时间、drop/rotation/write-failure 计数。

内部包含原生 `Logger` sink、bounded ring sink、MetricKit collector、privacy policy、bundle builder。业务模块不能拿到裸 file handle，也不能调用 `record(String)`。

### 2. Evidence event schema

每条记录使用 versioned、可机器解析的固定 schema。建议 v1 最小字段：

```text
schemaVersion, timestampUTC, monotonicUptimeNS, sequence,
sessionID, operationID, category, eventCode, stage, outcome,
elapsedMs, attempt, counts, bytes, errorDomain, errorCode,
truncated, coalescedCount
```

规则：

- `eventCode` 是稳定 enum，例如 `sync.started`、`sync.stage.entered`、`sync.heartbeat`、`sync.failed`、`mutation.rejected`、`storage.commit.failed`；本地化文案不作为唯一证据。
- 同一操作的 start、stage、heartbeat 与 terminal 共用随机 `operationID`。每次启动产生随机 `sessionID`；二者都不从用户资料派生。
- 同时记录 wall clock 与 monotonic uptime，wall clock 用于用户时间对齐，monotonic 用于在系统时间跳变时仍准确计算持续时间。
- start 后必须有一个 terminal；下次启动若发现前一 session 没有 clean-shutdown marker，记录 `previous_session.interrupted`，但不得伪造上次操作的失败原因。
- 长时间同步只在进入新阶段或超过阈值时写低频 heartbeat；heartbeat 包含当前 stage、elapsed 和安全计数，不逐 poll 写日志。
- 错误只允许经过审核的 domain/code/underlying-code chain；不直接保存任意 `localizedDescription`。

### 3. 类别与等级

首版只设五个 category，避免 category explosion：

| Category | 证据范围 |
| --- | --- |
| `lifecycle` | launch、clean shutdown、previous interruption、版本/schema |
| `mutation` | 用户操作受理/拒绝、领域验证 code、commit 终态 |
| `storage` | SQLite transaction、migration/schema、file coordination、磁盘错误 |
| `sync` | endpoint kind、operation/stage、iCloud coordination、重试与终态 |
| `diagnostics` | ring rotation、drop、redaction/export、MetricKit 接收失败 |

AI、UI、IME 等将来若确有独立诊断价值再加 category；不能因为源码模块多就一比一新增。

自有 ring 只接收 `notice/error/fault` 对应的 typed evidence，加少量明确获批的 `info` stage；`debug/trace` 永不常驻写盘。支持人员需要高细节时，可在 UI 启用有明确倒计时的 support session，但仍受同一 byte cap，过期自动恢复。

### 4. 磁盘预算与轮转合同

以下是建议首版合同，实施前需用一年演示负载和故障风暴压测确认：

| 组成 | 建议限制 | 约束 |
| --- | --- | --- |
| `evidence-ring` | 总 payload `2 MiB`；4 个 `512 KiB` segment；最长 7 天 | rotate-before-append；保留最新完整 event；单 event 编码后最多 `4 KiB` |
| MetricKit cache | 总 payload `1 MiB`、最多 4 个完整 payload、最长 7 天 | 先删最旧；不截断单个 JSON 成不可解析数据 |
| manifest/index | `128 KiB` | 双槽/原子替换；损坏时可由 segment 重建 |
| writer queue | 内存最多 256 events 或 `256 KiB`，先到者为准 | overflow 聚合为 drop counter，不能让业务线程等待 |
| 整个持久 diagnostics 目录 | **绝对不超过 `4 MiB`** | 计算 active、old、tmp、index、MetricKit 全部文件；任何时刻都适用 |
| App-owned 支持包 | 输入不超过 `4 MiB`，最终 archive 不超过 `8 MiB` | 超限 fail-closed 并在 preview 说明，不静默漏件 |

`2 MiB / 7 天` 参考了 Mullvad 可审查的移动端 retention 起点，但晷迹会比该实现更严格：大小检查发生在每次 append 前，并把临时/备份文件纳入目录总额。时间只是第二道清理规则，byte cap 才是磁盘合同。

单事件超过 `4 KiB` 时只保留 schema 必需字段，并设置 `truncated=true`；禁止为了保存任意错误文字而突破上限。重复 fingerprint 在时间窗内聚合为 count/first/last，避免错误循环冲走真正的起因。

### 5. 隐私合同

| 可记录（字段白名单） | 禁止记录 |
| --- | --- |
| App version/build、schema version、macOS major/minor、architecture | 任务标题、描述、备注、子任务正文 |
| 随机 session/operation ID | AI prompt、response、provider token、API key |
| event/stage/outcome enum | SQLite row、数据库副本、CloudKit/iCloud 原始 record |
| count、byte count、duration、attempt、queue depth | 完整文件路径、home directory、用户名 |
| NSError domain/code、SQLite primary/extended code | iCloud account、Apple ID、device name、raw entity/device ID |
| endpoint kind（`icloud`/`local`）、网络状态 enum | URL query/header、cookie、Bearer token、signed URL |
| 数据快照的高熵、不可逆整体 digest（仅确有对账需要时） | 对任务正文等低熵内容做 hash 后记录；hash 仍可被字典攻击 |

隐私采取两层防御：

1. **源头 allowlist**：`EvidenceEvent` 每一 case 只接受相应的安全 typed fields；unknown key 编译不通过或编码时 fail-closed。
2. **导出 redactor**：支持包生成时再次扫描 path、UUID、token pattern、email/IP 等意外内容；redaction version 写入 manifest。二次 redactor 是事故防线，不是允许调用点记录任意 String 的许可证。

诊断目录固定在 App 自有 Application Support 容器中，不进入 iCloud SyncRepository；文件权限只允许当前用户。诊断清理与业务数据库、同步仓库、Keychain 必须是不同的删除边界。

### 6. 支持包产品流程

设置页增加一个低视觉负担的“导出诊断资料…”入口：

1. 显示最早/最新证据时间、当前占用、rotation/drop/write-failure 数，以及将包含的文件清单；
2. 明确写出“不包含任务内容、数据库或凭证”；用户可打开预览；
3. 用户确认后生成 archive，并通过 `NSSavePanel` 保存或系统 Share Sheet 分享；不自动上传；
4. manifest 包含 app/build、binary UUID、macOS、schema/redaction version、时间窗、每来源 bytes、oldest/newest、event/rotation/drop/truncation 数、collection errors 和每文件 SHA-256；
5. 导出 staging 在成功、取消或失败后清理；用户自己保存的 archive 由用户管理；
6. 另提供“清除诊断日志”，只删除 diagnostics 目录，不触碰任务、同步资料或 Keychain。

默认包内容：manifest、结构化 ring、受限 MetricKit JSON、简短的人类可读 event code 对照表。完整 `.ips` 只在用户显式选择时附加；如果完整 `.ips` 会使包超过限制，不能截断 crash report，而应提示单独保存/分享。

### 7. 日志自身失败时的行为

- 单一串行 writer/actor 负责 segment、index 和 sequence；业务调用只入有界 queue，绝不等待磁盘 I/O。
- 满盘、只读目录、权限错误或 segment 损坏不能改变任务修改与同步结果；recorder 转为 degraded，增加内存 drop/write-failure counter，并尽力向系统 `Logger.error` 写一条固定模板，避免递归写回 file sink。
- 不为每条 event `fsync`；在 terminal/error、App lifecycle 边界和受控批次 flush。最终策略以 crash-during-rotation 和性能测试为准。
- 支持包必须显式报告 partial collection；“缺少一部分资料”不能伪装成完整成功。

## 直接适用与不适用

| 做法 | 判断 |
| --- | --- |
| Swift `Logger` 的 subsystem/category、等级、逐字段 privacy | 直接适用于 macOS 14 |
| `MXMetricManagerSubscriber` / `MXDiagnosticPayload` | 直接适用于 macOS 14，但只是补充证据 |
| 完整系统 `.ips` + 对应 archive/dSYM | 直接适用，崩溃分析必需 |
| NetNewsWire 的 operation lifecycle wrapper | 概念与 Swift 实现方式可直接借鉴；容量/隐私契约需重做 |
| Signal 的 sink redaction 与用户主动提交 | 架构可借鉴；Electron/Pino 与公开 URL 上传不适用 |
| Mullvad 的 per-source tail、总导出预算、View before Send | 可直接借鉴产品合同；Rust/Electron 实现不直接复用 |
| Firefox 的四段 byte rotation 与临时模块化采集 | 算法概念可借鉴；200 MB、HTTP 明文日志与 Gecko 多进程细节不适用 |
| `OSLogStore.currentProcessIdentifier` 作为跨重启导出 | 不适用 |
| `OSLogStore.local()` / 全系统日志自动收集 | 不适用普通发布版，权限与隐私边界不成立 |
| macOS 27 新 `MetricManager` | 当前不适用，只保留 migration seam |
| sysdiagnose 默认进入支持包 | 不适用；范围过广且可能含其他系统/用户资料 |
| 所有 SwiftLog message 先拼成一个 public OSLog string | 不适用，破坏逐字段 privacy |

## 验证门槛

这属于生产、数据与隐私相关的 P 级改动。实施后不能只以 build 或 unit test 通过作为完成证据。

### 单元与性质测试

- 每个 event case 的 schema golden test；unknown field fail-closed；旧 schema reader 行为明确。
- privacy canary：任务标题、API key、Bearer token、home path、URL-encoded path、UUID、email、IP、换行与 nested error chain 均不得出现在 ring 或 archive。
- 轮转性质测试：百万 events、并发 producers、单条超大 error、重复错误风暴；包含 `.tmp/.old/index` 的目录在任一 observation point 都不超过 4 MiB。
- rotate-before-append、segment partial write、index 损坏、crash 中断轮转后，重启只丢最多一个未完成 event，保留最新完整证据并报告 recovery。
- queue overload、drop coalescing、sequence 单调、operation start/terminal 配对。

### 集成与真实 `.app` 验证

- 用真实 release `.app` 走任务创建/修改、SQLite commit、iCloud sync start/stage/retry/failure、强制退出与重启路径，再由 UI 导出支持包。
- 在同步阶段挂起后验证 heartbeat 能说明“卡在哪一层、已持续多久”，而不是只留下“同步中”。
- 注入满盘、read-only、权限失败，证明日志失败不妨碍任务写入，并在导出/Unified Log 中留下 recorder degraded 证据。
- 在 Xcode debugger detached 状态制造受控 crash，取得完整 `.ips`，用相应 release archive/dSYM 完整 symbolicate；MetricKit 模拟 payload 只能验证接线，不能冒充真实交付证据。[Apple：debugger detach 后生成系统 crash report](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- 在一年演示 fixture 和 53 个输入面压力下测量 p50/p95/p99 record 调用延迟、writer I/O、CPU、内存、App 启动、IME 输入与同步耗时；不得以提高现有阈值吸收回归。
- 归档并检查支持包：总大小、manifest、hash、时间窗、drop/truncation、无 canary、无 SQLite/iCloud/Keychain/AI 内容。

### 发行门禁

- 每个 release build 保留 archive、dSYM、binary UUID 与 checksum 映射。
- 真实 DMG 安装路径验证“导出诊断资料…”可用，App 重启后仍能导出前一 session evidence。
- 诊断 schema、redaction rules、磁盘预算或 export 内容任何变化都需独立安全 review。

## 风险、灰度、回滚与本地监控

### 主要风险

1. **隐私泄漏**：任意 String、错误描述或路径绕过 allowlist；以编译期 typed event、导出二次 redactor 和 canary gate 控制。
2. **日志反向制造性能/磁盘问题**：错误风暴冲刷证据或触发 Unified Log quarantine；以低频 lifecycle、coalescing、有界 queue 和 writer hard cap 控制。
3. **证据看似完整实则丢失**：drop、truncation、rotation、partial collection 没有暴露；必须把这些 health counters 写进 manifest。
4. **诊断清理误删业务数据**：diagnostics root 与 data/sync root 使用不同类型和固定路径护栏，清除功能只能操作前者。

### 建议灰度顺序

1. 先启用 typed event + Unified Logger + ring，但不提供上传；以内部 release/真实 `.app` 验证容量、隐私与延迟。
2. 补上用户预览/导出与清除入口，验证真实支持流程。
3. 接入受限 MetricKit cache 和显式 `.ips` 附加。
4. 只有未来存在明确支持后端、retention policy、访问控制和删除流程时，才另行设计 opt-in upload；不把上传偷偷并入本次范围。

### 回滚

file ring 与 export 可由本地 release flag 整体关闭，原生 `Logger` 仍保留最低限度系统证据；回滚不能影响任务、SQLite 或同步资料。已生成的诊断 segment 继续按既有 4 MiB/7 天策略自然清理，不做跨目录扫描或业务数据删除。

### 不上传的本地监控指标

首版只在 diagnostic health/manifest 中记录：

- `eventsWritten`、`eventsCoalesced`、`eventsDropped`、`eventsTruncated`；
- `rotationCount`、`recoveryCount`、`writeFailureCount`、`exportFailureCount`；
- `currentBytes`、`maxObservedBytes`、`oldestEventAt`、`newestEventAt`；
- MetricKit received/retained/evicted count。

这些指标不自动离开设备。用户导出后，开发者才能判断“没有相关 event”究竟是代码未覆盖、被轮转、被丢弃、还是 collection 失败。

## 审批点

进入实施前，需要明确批准以下产品合同：

1. 双通道：原生 `Logger` + `2 MiB` typed evidence ring，而不是传统全文文本日志；
2. 整个持久 diagnostics 目录任何时刻不超过 `4 MiB`，默认只保留 7 天；
3. 首版不自动上传，用户可预览、保存、分享和清除；
4. 严格字段白名单与禁止内容清单；不记录任务正文、路径、iCloud 内容、AI 内容、凭证；
5. MetricKit 是非保证交付的补充证据，完整 `.ips` 只经用户显式选择；
6. 实施必须通过隐私 canary、硬容量、满盘/强退恢复和真实 DMG 支持流程门禁。

## 一手来源范围

- Apple Developer Documentation：Logging、OSLog/OSLogStore、MetricKit、Xcode crash reports 与 symbolication。
- Apple Developer Technical Support：Unified Log 容量/分类建议、沙盒 previous-run 读取限制、high-volume quarantine。
- Apple SwiftLog 固定 commit `7af2de138f5f0fddf0bd5c7e19face6944ed76af`。
- NetNewsWire 固定 commit `52030006b5a3a45d865bd03a455f85d3f1327077`。
- Signal Desktop 固定 commit `34fa4531bb74725ab2edb04a18a4e3542eea2694`。
- Mullvad VPN App 固定 commit `c516040c8eed6148009b193e1266d535af847b9a`。
- Mozilla Firefox Source Docs 与 Searchfox `firefox-main` 的 Gecko logging implementation。

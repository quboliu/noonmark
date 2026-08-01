# 使用有硬容量上限的强类型本机诊断证据

**Status**: Accepted

晷迹现有自由文本日志无法稳定关联同步停滞、任务修改被拒绝和重启后恢复的失败状态，也无法证明日志没有带出任务正文或凭证。系统 Unified Logging 的保留与容量由 macOS 管理，不能单独承担跨重启的一键导出；只保存应用自有文件又会失去 Console、Signpost 和系统诊断能力。因此，晷迹采用 Apple `Logger` 与应用自有结构化证据环组成的双通道，并以 MetricKit 和用户主动选择的 `.ips` 作为非保证性的补充证据。

## Decision

- 新建独立深模块 `NoonmarkDiagnostics`。业务模块只能提交强类型事件、枚举、计数、字节数、耗时和随机诊断身份；模块不提供 `log(String)`、任意 dictionary、原始 `Error`、`localizedDescription` 或 `userInfo` 入口。Apple `Logger` 只输出固定事件码和安全标量，应用自有证据环负责确定性的跨重启保存与用户导出。
- **本机诊断记录**与 Todo SQLite、烛龙 sidecar、同步仓库和数据包完全分离，不参与 iCloud 同步或自动上传。用户可以先预览 manifest，再主动导出或清除；清除操作只拥有诊断根目录，不能触碰任何业务事实。
- 应用自动管理的全部诊断文件以实际 allocated bytes 计量并始终不超过 4 MiB，且最长保留 7 天。结构化事件环使用四个不超过 512 KiB 的 segment，单条事件不超过 4 KiB；active-operation marker、最近事故胶囊、索引与摘要各自受固定配额约束。MetricKit JSON 必须在写盘前按带版本的固定 schema 白名单脱敏，只保留系统 binary 身份和安全数值；脱敏后缓存总计不超过 768 KiB、单份原始输入不超过 256 KiB。超限 payload 整份舍弃并只留下 typed summary，不得截断成无效 JSON，也不得把原始字符串、未知 key 或任意 UUID 写入磁盘。
- 写入必须在 append 前先轮换，并把 `.tmp` 与原子替换过程纳入 4 MiB 配额；受控文件的 allocated size 无法证明时 fail-closed 停止文件写入，只保留系统日志。诊断根与 Metric cache 目录的最终路径组件必须是不跟随符号链接、由进程持有的真实目录；遇到符号链接或非目录 entry 时不得读取、删除或改写其外部目标。用户主动导出的 staging 位于持久诊断根之外，输出包不超过 8 MiB，并在成功或失败后清理 staging。
- 每个长操作具有随机 operation ID、开始时间、当前 stage、最后进度和终态。active-operation marker 原子更新；下次启动若发现未完成 marker，只记录 `previousSessionInterrupted`，不得猜测崩溃、强退或断电。开始、错误和终态不得被高频事件合并或优先淘汰；有界队列以终态、开始、其他 critical、best-effort 的固定次序保留，终态自带 endpoint 与 duration，使开始事件已丢失时仍能重建固定配额的事故胶囊。heartbeat 只在持续时间越过阈值且安全进度发生变化时记录。
- 同步 evidence 覆盖本机载入、transport lock 等待／获得／释放、远端抓取与 decode、同步基线、上传、下载合并、追赶上传、最终抓取、coverage／stability 检查、最多八次 finalization、成功 metadata 提交和 typed failure。任务修改拒绝、持久化失败和重启读取旧同步失败必须关联当前 operation／incident，但不得记录任务身份或正文。
- 诊断写入由专用有界队列处理，不在 MainActor 执行文件 I/O，也不取得 Todo、同步或导入锁。队列最多容纳 256 条或 256 KiB；溢出、segment 轮换、active marker／事故胶囊压缩和 Metric cache 淘汰都必须留下 typed loss counter。loss counter 与 allocated-size 峰值使用最多八个 UTC 日桶，按当前七日覆盖窗口聚合，不得在旧窗口到期时整体清零而抹掉较新的 partial 证据；若 cutoff 落在某 UTC 日中间，则该边界日整桶丢弃，未来或畸形日桶也必须丢弃，确保绝不导出超过七日的证据。诊断系统任何权限、磁盘、编码或损坏错误都 fail-open，不得改变用户操作或同步的成功／失败语义。
- 导出器只从已知 schema 解码并重建允许字段，未知字段与损坏记录排除并计数，再执行第二层防御性脱敏。诊断身份不得复用设备、任务、会话或 Provider 身份。允许字段只包括 App／OS 非识别版本信息、operation／session／incident 随机身份、阶段枚举、次数、数量、字节、耗时、端点类型及白名单错误域和数字错误码。
- release 必须保留 `.app`、dSYM、Mach-O UUID 与 binary SHA 的对应关系，并用真实 `.ips` 完成符号化门禁；没有匹配 dSYM 的构建不得宣称具备可用崩溃诊断。MetricKit 是补充渠道，不得作为业务 operation 是否完成的唯一证据，也不得使用不安全的 signal handler 补写日志。
- 正式代码中的自由文本 `NSLog`、`print`、stderr、任意 `Logger` 和错误字符串输出必须迁移或由静态门禁拒绝；隔离 E2E harness 的人类可读控制台输出必须处在明确测试边界，不能进入 production evidence ring。

## Considered Options

- 只使用 Unified Logging：macOS 不向单个应用承诺固定保留期与磁盘容量，也不能提供稳定的应用内跨重启导出契约。
- 只使用应用自有滚动文件：会失去 Console、系统隐私标记、Signpost 和系统崩溃诊断的互补证据。
- 接入自动远程 crash／log 服务：当前没有后端或用户授权模型，自动上传会扩大隐私、安全和运营范围；本轮明确不实施。
- 保存数据库副本、同步 payload 或完整系统日志：证据更丰富但会复制用户内容，违反数据最小化和 4 MiB 磁盘契约。

## Consequences

- 支持人员可以从用户主动提供的小型诊断包重建跨重启 operation 时间线，并把界面 incident ID 对应到最后一个确切 stage，而不读取 Todo 内容。
- 类型化 schema 需要在新增诊断字段时显式评审，短期比自由文本日志更慢；这是隐私边界、容量证明和长期可查询性的必要成本。
- 4 MiB 是应用管理文件的硬上限，不包含用户主动保存到其他位置的导出包；导出包仍有独立 8 MiB 上限并由用户决定是否保留与发送。
- 诊断证据不能保证覆盖突然断电前尚未落盘的最后事件，也不宣称 tamper-proof；报告必须披露缺失、丢弃、损坏和 MetricKit 未送达的情况，不能制造完整性假象。

## Risk And Rollout

- 风险等级：P。主要风险是敏感正文泄漏、日志风暴突破配额、诊断 I/O 阻塞用户操作、半写 segment 破坏历史、跨重启错误归因，以及错误清除业务数据。
- 灰度：先在开发包启用 typed schema、内存 recorder 与 sync operation evidence；再在隔离 beta DMG 启用 bounded file sink、预览／导出／清除与 dSYM 门禁；最后才在正式包启用 MetricKit 缓存。任何阶段都不启用远程上传。
- 监控：本机 health 只报告逻辑／allocated bytes、最旧／最新事件、drop／corrupt／oversized 计数、当前 operation 与最近导出结果，不包含路径或用户身份。超过配额、未知 schema、主线程文件 I/O、开始或终态缺失、binary UUID 与 dSYM 不匹配均为发布阻断信号。
- 回滚：可以整体关闭 bounded file sink 与 MetricKit 缓存并保留最小 Apple `Logger`；诊断 schema 按版本读取，旧诊断文件可由诊断模块自身丢弃。回滚不得修改 Todo SQLite、烛龙 sidecar、同步策略或 iCloud 记录仓库，也不得通过放宽隐私 schema 或容量上限维持旧路径。

## Verification

- 公共 seam 测试覆盖一百万事件风暴、并发 producer、单条和 MetricKit 超限、append 前轮换、`.tmp` 配额、allocated-size 上限、队列过载、损坏／半写 segment 恢复、权限／磁盘失败 fail-open、schema 兼容与导出 digest。
- 隐私哨兵把任务标题、API key、路径、URL、邮箱、IP 和长 Base64 内容送过每一种错误路径，随后扫描 evidence ring、导出包与格式化 Unified Logger message，任何命中都失败。
- 真实 `.app` E2E 必须走“同步停滞 → 尝试修改 → 非正常终止 → 重启 → 导出”路径，并证明一个 operation／incident 串起最后 stage、mutation rejection、previous-session interruption 与持久化同步失败；证据包保持在容量内且不含哨兵。
- 真实 DMG 安装验收必须证明导出不依赖 Todo／sync lock，随后产生受控 `.ips`，使用 package manifest 绑定的 dSYM 成功符号化并对账 UUID／binary SHA。

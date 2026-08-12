# iOS 版本能力对齐方案

状态：进行中（2026-08-12；iOS 真实 Simulator 基线已转绿，完整 Mac parity 仍受未完成能力与外部运行条件约束）

## 需求与成功标准

晷迹 iOS 版本必须与现有 Mac 版本共享同一套 `NoonmarkCore` 领域规则，并以 iOS 原生交互提供 Mac 当前能力：日 Todo、任务池、未来计划、重复计划、未完成与已完成轨迹、日历与复盘、飞光、Sticky Note、烛龙、设置、数据导入导出、同步和诊断边界。Mac 版本必须保持可构建、可测试、可运行；iOS 只使用 `app.noonmark.ios.development` 隔离身份，禁止触碰 production 资料。

每个能力的完成定义是：核心状态由真实领域接口变更；本地持久化可重启回读；iOS Simulator 真实用户路径有症状级 UI 测试；涉及文件、同步、AI 或系统生命周期的功能另有对应运行证据。页面存在但显示占位文案不算完成。

## 现状证据

- 仓库原先只有 SwiftPM Mac App；没有 iOS target、iOS bundle 或 iOS UI 测试。
- `NoonmarkCore`、`NoonmarkStorage`、`NoonmarkSync`、`NoonmarkAI`、`NoonmarkZhulong` 和 `NoonmarkZhulongAI` 已能由 Xcode iOS Simulator SDK 编译。
- iOS 首个切片已接入真实 SQLite，并已验证创建今日任务、终止 App、重启后仍可见。
- 第一轮 UI 失败来自 iPhone compact 模式仍停在 `NavigationSplitView` sidebar；XCTest accessibility hierarchy 已确认 detail 没有渲染。修复为 compact `NavigationStack` 后，该路径转绿。

## 设计与边界

### 分层

1. `NoonmarkCore` 是唯一领域规则来源。iOS Store 只负责页面状态、事务提交和错误呈现。
2. `NoonmarkStorage` 负责 iOS development Application Support 下的 SQLite；每次用户变更先复制引擎、执行领域变更、保存 snapshot，保存成功后才替换正在展示的引擎。
3. `NoonmarkSync` 通过 iOS 明确的 iCloud entitlement、CloudKit account 和 iCloud Drive 可用性检查接入；缺少权限时 fail-closed，不显示“已同步”。
4. iOS 页面使用 `NavigationStack`（iPhone）与 `NavigationSplitView`（iPad）两种容器，但共享 `IOSStore` 和领域投影。

### 能力对齐顺序

| 能力组 | 当前状态 | 完成门禁 |
| --- | --- | --- |
| 今日任务、池、未来、未完成、已完成 | 领域投影、共享详情、子任务改名／难度／废弃／删除、札记编辑／删除、当日优先级调整和轨迹入口已接入；Simulator 已通过任务与任务池详情的真实编辑路径 | 完成、延续、详情与年度规模路径的症状级对账 |
| 飞光、Sticky Note | 飞光创建、原子编辑／分类、搜索、回收站恢复与删除、Sticky Note pin／移除／来源编辑已接入 | 固定 Simulator pin、恢复、删除与重启回读的独立症状 gate 已通过 |
| 日历与复盘 | 月视图、日期选择、日统计和复盘编辑已接入；日历使用长 ScrollView 避免 List 递归布局 | Simulator 月份切换、长滚动、复盘保存与重启回读 |
| 重复计划 | 创建、模板说明、计划子任务新增／改名／难度／删除、编辑、跳过、停止、轨迹和年度日历映射已接入；Simulator 已验证创建、模板回读与展开摘要 | 编辑、跳过、停止和重启回读的独立症状 gate |
| 设置与分类 | 外观、语言、诗句、备份、数据模式、同步端点／策略、分类目录创建／改名／归档／恢复和详情分类编辑已接入 | Simulator 偏好、同步策略与分类目录完整回读 |
| 数据包 | `NoonmarkDataPackage` JSON export/import、完整性校验、SQLite 替换、导入确认和原生 iOS 文件面板已接入；导出临时文件在 picker 完成后清理 | Simulator 文件面板导入／导出打开与取消、提供的 JSON 导入和重启回读 |
| 同步 | iOS 已接入 local-first coordinator 的真实 transport 选择；缺 entitlement／container 时 fail-closed；Simulator 不宣称同步成功 | 真实 iOS entitlement、CloudKit account、iCloud Drive 与双端冲突运行证据 |
| 烛龙 | provider 配置、Keychain API key、加密 session sidecar、七类任务选择、按任务 scope 授权和 streaming UI 已接入；task plan 会形成可审阅 Todo diff，daily review 会形成事实快照草稿，task-pool analysis 使用 typed evidence contract；写入仍需显式授权 | 明确 provider endpoint/key 后的 live AI smoke、失败恢复、planning delegated workflow 与 artifact 真实 Simulator gate，以及敏感信息门禁 |
| 诊断与生命周期 | iOS bounded diagnostic bootstrap、MetricKit subscriber、Help 导出文档和前后台 flush 已接入 | 真实故障闭环、隐私哨兵、4 MiB／8 MiB 容量及主动导出症状 gate |

## P 级风险、回滚、灰度和监控

- 风险：iOS 与 Mac 共用 SQLite schema 和 snapshot 语义，错误的迁移或导入会影响数据完整性。处置：不改 production schema；先在 development bundle 使用 `NoonmarkDataPackage` 验证，所有替换操作先校验完整 snapshot，失败时保留当前引擎。
- 风险：iOS capability / entitlement 与 simulator 可运行性不等于真机 CloudKit 可用。处置：没有 entitlement/account/transport 运行证据就保持不可用状态；禁止把 simulator 本地保存描述为跨设备同步。
- 风险：烛龙 provider 可能处理敏感正文。处置：复用现有 scope 与 provider boundary；未完成隐私过滤、凭证 Keychain 和 live smoke 前不开放发送入口。
- 回滚：iOS target 是新增 target；回滚只移除 iOS target、iOS app sources、iOS project generation 和 iOS-specific platform seams，保留 Mac 与 Core 的既有行为。任何 Core API 扩展必须有 Core 回归测试后才能保留。
- 灰度：只允许 `app.noonmark.ios.development` simulator 和明确的 development 真机 profile；不复用 `app.noonmark.mac`、不读取 production Application Support 或 production iCloud repository。
- 监控：iOS 运行日志只记录结构化阶段、计数和稳定 ID；不记录正文、prompt、response、路径、URL、API key。对同步/导入/AI 操作记录成功、失败原因码和重启恢复状态。

## 验证策略

- fast gate：`make build`、`make test`、Core/Storage/Sync 回归测试、iOS target unit tests。
- symptom gate：固定 iOS Simulator `Noonmark iPhone 17 Pro` 上执行 `scripts/test-ios-simulator`，包含真实页面交互、强制终止、重启和 SQLite 回读。
- release gate：iOS archive/signing/entitlement 出现前再添加；当前仓库没有 iOS release workflow，不提前宣称真机分发完成。
- 每次发现 UI 或持久化症状，先保存 XCTest result/accessibility hierarchy，再定位根因；不能以 build 成功代替用户路径验证。

## 已取得的运行证据

- `scripts/test-ios-simulator`：固定 `Noonmark iPhone 17 Pro`，真实 iOS UI test 9 项、0 failures；覆盖今日任务创建／强制终止／重启回读、重复计划创建／展开、飞光创建／搜索、Sticky Note 生命周期、分类目录创建／搜索／归档／恢复／硬删除、日历长滚动复盘保存／重启回读及详情编辑。
- 固定 Simulator focused UI gate：`testUserCanEditTaskSubtaskAndTraceNoteInSimulator` 通过，覆盖任务子任务改名、札记新增／编辑／删除。
- 固定 Simulator focused UI gate：`testUserCanEditPoolPlannedSubtaskAndNoteInSimulator` 通过，覆盖任务池计划子任务改名／删除、札记新增／删除。
- 固定 Simulator focused UI gate：`testUserCanClassifyAndPersistTaskInSimulator` 通过，覆盖分类目录创建、任务分类选择和强制终止／重启回读。
- 固定 Simulator focused UI gate：`testUserCanCreateRecurringPlanInSimulator` 通过，覆盖重复计划模板子任务创建、编辑表单回读和展开摘要。
- 固定 Simulator focused UI gate：`testUserCanSaveDailyReviewAndReadItAfterRestartInSimulator` 通过，覆盖日历长滚动、复盘保存和强制终止／重启回读；首次 List 递归布局故障登记为 `FAIL-2026-08-11-03`。
- 固定 Simulator focused UI gate：`testUserCanOpenAndCancelDataPackageFileFlowsInSimulator` 通过，覆盖真实 JSON 导入／导出系统文件面板的打开、取消和连续路径；SwiftUI exporter 不呈现故障登记为 `FAIL-2026-08-12-09`。
- 固定 Simulator focused UI gate：`testUserCanPinRestoreAndDeleteFlylightInSimulator` 通过，覆盖 Sticky Note pin／移除、飞光删除、回收站恢复、正文编辑、关闭回收站和强制终止／重启回读；目录切换故障登记为 `FAIL-2026-08-11-06`。
- `xcodebuild ... iphonesimulator build`：iOS app 及共享 Core/AI/Zhulong/Diagnostics/Storage/Sync targets 构建通过。
- `scripts/test-ios-target-contract`：compact root、日历长滚动、飞光生命周期和复盘症状入口的 fail-closed contract 通过。
- `scripts/test-failure-case-gates`：现有故障门禁登记与入口校验通过；本轮完整 `make check` 自然退出 0，DMG evidence contract、release gate aggregation 和所有既有 fast／symptom contract 均通过。此前一次中止来自人为停止 helper 后的错误现场，不作为产品失败证据。
- 用户提供的 `noonmark-backup-2026-08-11.json` 已在固定 development Simulator 完成事务性导入、重启回读和真实页面显示；SQLite 对账为 252 个 days、938 条 day traces、1035 条 task chains 和 31 条 idea entries，local-first sync 保持关闭。
- `make build-app`：`development` profile 的真实 Mac App 产物构建、签名和任务优先级交互类型检查通过。
- 首轮 compact 根容器故障已由 XCTest accessibility hierarchy 定位并修复，案例登记为 `FAIL-2026-08-11-02`。

## 尚未满足完整 parity 的外部条件

- 仓库没有 iOS CloudKit container identifier、signing entitlement 或可用于双设备验证的 Apple account 配置；当前代码按 fail-closed 处理，不能把本机 SQLite 或 iCloud Drive 初始化失败描述为同步完成。
- 烛龙 live provider 需要爹明确提供 endpoint、model 和 Keychain 中的开发凭证；没有这些运行输入时，只能验证配置边界与本地加密会话，不能宣称 live AI 已通过。当前 iOS 已有七类 task scope、Todo diff、daily review draft 和 task-pool analysis typed artifact；Mac 内部 delegated planning contract 尚没有 iOS 可操作的用户界面和真实 provider symptom gate。
- 因此本计划当前是“可运行的 iOS 实现 + 已验证的 Simulator 路径”，不是“Mac 全能力已完成”的最终结论。尚未完成的年度规模、设置／数据包完整 UI、同步双端、诊断故障闭环和 delegated planning 必须继续补齐后才能收口。

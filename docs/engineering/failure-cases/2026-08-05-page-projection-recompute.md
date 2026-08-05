# FAIL-2026-08-05-02：页面投影在每次 SwiftUI body 求值时重复全表扫描导致页面切换与滚动卡顿

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05（FAIL-2026-08-05-01 修复后的全局同类排查）
- 影响版本／构建：0.2.1 (6) 及之前全部包含 Day Todo／任务池／日历等页面投影的构建
- 引入提交：视图层投影调用随各页面逐步引入，无单一引入提交；逐行全扫模式自 TaskRow 初版即存在
- Git author／committer：多提交累积，非单一来源
- 实际修改者：未知
- 修复提交：`18690f19a87fc56bbc37fca7dc04864c6d66688e` fix(app): memoize page projections and rail statistics per engine revision

## 用户症状与影响

年度数据规模（460 条已完成任务链、1569 条 DayTrace、1083 条子任务）下，Mac App 在「日计划 ↔ 任务池」等页面切换与列表滚动时主线程出现可感知延迟；数据量越大越明显，与 FAIL-2026-08-05-01 同族但分布在全部页面。

## 时间线

- 2026-08-05：FAIL-2026-08-05-01（已完成池 O(n²)）修复后，对剩余页面做同模式排查，sample 采样确认 TaskRow 与侧边栏计数仍是主线程热点；同日完成根因定位与全局修复。

## 复现与证据

1. `make run-demo-app` 启动年度演示基线，在日计划与任务池之间反复切换，`sample` 采样主线程 12 秒。
2. 修复前证据（`/tmp` 采样，未入库）：12 秒采样中 516 个采样落在 `TaskRow.body.getter` 及其调用的 `store.subtasks(for:)`（全扫 `engine.subtasks.values`）、`engine.traceProgress(for:)`（扫 `traces.values`）、`store.changedSource(for:)`（`traces.values.first(where:)` 全扫）；另有可观采样落在 `navigationCount(for:) → taskPoolCount()` 等侧边栏计数路径，每个侧边栏项每次 body 求值都全量计算。
3. 源码确认（修复前）：`DayTodoPage.traces`（`App/NoonmarkMacApp/DayTodoPage.swift:34`）、`TaskPoolPage.tasks`（`TaskPoolPage.swift:73`）、`RecurringPlansPage.body`（`RecurringPlansPage.swift:20`）、`CalendarCell.summary/traces`（`CalendarPage.swift:196-199`）等页面投影都是 body 内计算属性直接调引擎；DateStrip 每个日期格一次 `getDayTodo`（14 格 × 每次求值），日历月视图逐格 `calendarSummary`/`calendarTraces`（约 35 格 × 每次求值）。
4. 分组对拍（2026-08-05 复测）：同一运行实例内，计划组（Day Todo ↔ 任务池）切换采样中 `TaskPoolHomeRail.body.getter → statisticsSection.getter` 命中 781 次，轨迹组（未完成 ↔ 已完成）同路径仅 193 次。轨迹组数据量（460 链）远大于计划组（22 日任务、32 池任务），延迟却更低——证明延迟与列表数据量无关，取决于页面右栏是否在每次 body 求值时全量重算：`TaskPoolHomeRailModel.make` 每条池任务调一次 `engine.taskTrail(chainID:)` 全表扫描，`ReviewRail` 每次求值调 `dailyReviewStats` 且近七天趋势再逐日调 7 次；轨迹组右栏 `SidebarAnalysisModel` 读取的是已备忘的池投影，因此便宜。

## 排除的假设

- 引擎单次查询本身过慢：微基准显示单次查询为毫秒级，问题是调用次数的乘法效应，排除引擎算法为唯一根因（引擎层平方项已由 FAIL-2026-08-05-01 修复）。
- SQLite 持久化读取慢：采样热点在内存投影而非存储层，排除。
- SwiftUI 布局／渲染成本：列表使用 LazyVStack 惰性渲染，热点在数据投影计算而非布局，排除。

## 根因与破坏机制

引擎单次投影查询是 O(记录数) 的全表扫描（毫秒级），但视图层在「每次 body 求值 × 每行 × 每个侧边栏项 × 每个页面」的路径上直接调用引擎：TaskRow 每行每次渲染触发 3-4 次全扫，侧边栏每个导航项每次求值触发 1-2 次全扫，页面级投影（日计划、任务池、未来计划、重复计划、日历月格）每次 body 求值整体重算。求值次数 × 行数 × 单次全扫成本形成乘法效应，全部发生在主线程。

## 根因修复

- 新增共享组件 `Sources/NoonmarkMacRuntime/RevisionMemo.swift`：`RevisionMemo`（单值按版本备忘）与 `KeyedRevisionMemo`（键值按版本整体失效、单键惰性备忘），纯泛型值类型，可单元测试。
- `App/NoonmarkMacApp/NoonmarkStore.swift` 建立统一投影备忘层（与 FAIL-2026-08-05-01 的 completedPoolMemo 同位置、同语义，并将其迁移到同一组件）：
  - `subtasks(for:)` → 备忘 `[DayTraceID: [Subtask]]`（一次分组排序，全页共享）。
  - `changedSource(for:)` → 备忘 `changedToTraceID → sourceTraceID` 反向索引（保留 first-encountered 语义）。
  - `traceProgress(for:)` → 按 (revision, traceID) 惰性备忘。
  - `currentClassification(for:)` → 按 (revision, chainID) 惰性备忘；`displayableClassification` 经此生效。
  - `navigationCount(for:)` → 备忘 `[Page: Int]`，key 含 (engineRevision, today, recurringVisibilityDays)，一次性算齐。
  - 页面投影：`dayTraces(for:)`（key 为 date，按 revision 失效）、`taskPool()`、`futurePlanItems(today:recurringVisibilityDays:)`（key 含 today 与可见性偏好）、`taskCycleTracks()`（key 含 today）、`calendarTraces/calendarSummary/calendarReviewStats`（key 为 date，按 revision 失效）。
- 全部页面 body 调用点改走备忘入口：DayTodoPage（traces、DateStrip、TaskRow.progress）、TaskDetail、CompletedRecordDetail、UnfinishedDetail、TaskPoolPage、WorkspaceSheets、WorkspaceDetailRails、RecurringPlansPage、CalendarPage（月格、洞察面板、趋势条、详情面板）、ReviewRail、以及 store 内部的选择与展示路径（PresentationUndo、SelectionProductivity、TaskCollectionProjection、ClassificationReview）。
- 失效语义：engineRevision 在 engine didSet 中 `&+= 1`，所有引擎变更经 mutation lane 赋值提交；today 与 recurringFuturePlanVisibility 不经引擎变更，故纳入对应 key。引擎公开行为零变化。
- 右栏（第二轮复测补齐）：`NoonmarkStore` 新增 `taskPoolStatistics()`（按 revision 备忘，内部一次算齐每条池任务的分类与 `taskTrail` 回池判定）与 `dailyReviewStats(for:)`（按 revision+date 惰性备忘）；`TaskPoolHomeRailModel.make` 的统计部分改读备忘（分析部分仍响应 Provider session 自身状态，不备忘），`ReviewRail` 的当日统计与近七天趋势改读备忘。

## 验证结果

- `swift build` 通过。
- `swift test --filter NoonmarkCoreTests` 全部通过（行为保持）。
- 新增 `Tests/NoonmarkMacRuntimeTests/RevisionMemoTests.swift`：同版本只算一次、版本变化重算、invalidate 强制重算、键值备忘逐键独立缓存、版本变化整体失效，全部通过；已登记进 `scripts/test-unit`。
- `scripts/test-failure-case-gates` 通过。
- SwiftLint／SwiftFormat 对改动文件无违规。
- 症状级验证（2026-08-05）：年度 demo fixture 的页面切换耗时门禁实测转绿——修复后十个一级页面「page 赋值 → 就绪锚点出现」耗时 79-205ms，TOTAL 1414ms（`scripts/test-page-switch-latency` 判绿）；修复前仅已完成页单页即 5-6 秒。分组对拍确认计划组与轨迹组切换耗时拉平。

## 永久门禁

- fast：`scripts/test-unit`（随 `make check` 执行）。引擎层缩放由 FAIL-2026-08-05-01 的 `testCompletedTaskHierarchiesStaysNearLinearAtAnnualScale` 继续承担；本层新增 `RevisionMemoTests` 固定备忘组件的同版本单次计算与版本失效语义。
- symptom：`scripts/test-page-switch-latency`（由 `scripts/test-interactive-demo-fixture` 在 fixture 验收通过后强制调用，随 `make test-demo-fixture` 与 `scripts/test-all` 执行）。年度 demo fixture 自动化收尾阶段对全部十个一级页面（day、pool、future、recurring、unfinished、completed、calendar、zhulong、stickyNotes、ideas）实测「`store.page` 赋值 → 该页就绪锚点首次出现」的墙钟耗时：25ms 轮询（读数含最多一个轮询间隔的量化误差），单页 10 秒未就绪即判 fixture 失败；结果写入 demo 根的 `page-switch-latency.tsv`（每页一行 + TOTAL，本轮运行全新生成）。门禁脚本 fail-closed 校验报告存在、覆盖全部 10 页 + TOTAL、数值可解析、TOTAL 与分页之和一致、每页 < 1500ms、TOTAL < 6000ms。年度规模采样对账仍由 `make run-demo-app` 交互验收承担。

## 发行与回滚

不涉及安装、签名、启动、退出或发行产物，无需 release 门禁。回滚即还原本案例对应修复提交；无数据格式变更，回滚安全。

## 教训与永久约束

- SwiftUI 页面 body／行视图内禁止直接调用引擎全量投影；跨多次读取的派生数据必须在 store 层按 engineRevision 备忘（FAIL-2026-08-05-01 已有此约束，本案将其落实为共享组件与全部调用点）。
- 备忘 key 必须包含所有不经引擎变更的输入（如 today、可见性偏好），否则跨天或偏好切换后读到陈旧投影。

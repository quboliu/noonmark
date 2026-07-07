# 一期功能规格

本文定义晷迹（Noonmark）第一期 Mac 端的功能、领域规则、数据边界和核心接口。第一期目标不是复刻 Todo清单的全部能力，而是验证晷迹自己的核心理念：每日任务必须留下不可删除的轨迹，跨日不能无痕移动，只能延续复制，每一天都可以被清晰复盘。

## 产品目标

- Mac 首发，SwiftUI 是不可变技术约束。
- 本地优先，无账号、无网络也能完整使用核心功能。
- 允许用户选择 **本地优先** 或 **在线优先** 作为主 **数据模式**；两者互斥，不能并行写入同一份任务事实。
- 在线优先模式可以配置 **定时备份**，把当前数据导出成可恢复数据包到 iCloud Drive、S3 或其他对象存储；备份不是双向同步，也不是第二事实源。
- 每个自然日都有可回看的 Day Todo。
- 当前日任务可以执行、完成、变更、回池、废弃或延续。
- 历史日轨迹不可删除、不可无痕改期、不可覆盖式编辑。
- 未来计划可以调整，因为它尚未形成当日承诺。
- 第一阶段只支持有限撤销，不能用撤销抹掉历史事实。
- 一期只做手动数据包导出 / 导入和同步端点入口占位。
- 烛龙是可选 sidecar；没有 AI provider 时普通清单功能必须完整可用。

## 数据模式与备份边界

晷迹的数据模式分为两类：

- **本地优先**：本机 SQLite 事实表是主要运行路径；同步底座只作为未来跨设备交换和诊断能力，不要求在线服务可用。
- **在线优先**：在线服务是主要运行路径；本机可以缓存和导出恢复包，但不再作为主同步事实源。

约束：

- 同一时间只能启用一种主数据模式。
- 模式切换必须是显式操作，并且必须关闭另一套主同步链路。
- 不允许本地优先同步和在线优先同步同时运行、同时写入、同时解决冲突。
- 定时备份是旁路能力：它只把当前事实导出成可恢复数据包，不接收远端变更，不参与冲突合并。
- 在线优先允许开启定时备份到 iCloud Drive、S3 或用户配置的对象存储；这不违反主数据模式互斥。

## 第一屏信息架构

第一期采用单主窗口。建议信息层级如下：

- 左侧导航：
  - Day Todo
  - 任务池
  - 未来计划
  - 未完成池
  - 已完成池
  - 烛龙
  - 设置
- 中央主区：
  - 当前选中视图的列表和主要操作。
- 右侧或下方详情区：
  - 任务详情、子任务、变更记录、延续明细、每日复盘。
- 烛龙：
  - provider 配置、复盘分析、任务拆解、排期建议、label 分类建议。

UI 具体设计由 Claude Design 负责；本规格只定义行为和接口。

## 核心对象

### Day

表示一个用户本地自然日。

关键字段：

- `date`
- `lockedAt`
- `reviewSummary`
- `reviewUnfinishedReason`
- `reviewTomorrowNote`
- `createdAt`
- `updatedAt`

规则：

- 每个日期最多一个 Day。
- 日期小于当前本地日期且未锁定时，启动或跨 00:00 后必须补结算。
- 锁定后，任务事实不可改写，但每日复盘文本可补写。

### TaskChain

表示同一件事在排期、延续、变更和完成过程中的连续身份。

关键字段：

- `id`
- `state`: `active | abandoned`
- `createdAt`
- `updatedAt`

规则：

- 同一任务链同一时间最多一个活跃日轨迹。
- 活跃日轨迹完成后，该任务链从未完成池移除。
- 废弃后，该任务链仍显示在未完成池并标注已废弃；它不能直接延续复制，但可以重新启用。

### TaskDefinition

表示用户对任务当前承诺的标题、描述和边界。

关键字段：

- `id`
- `chainId`
- `sequence`
- `title`
- `descriptionText`
- `note`
- `createdAt`
- `supersededAt`
- `supersededByDefinitionId`

规则：

- 已产生日轨迹的任务定义不允许覆盖式编辑。
- 需要改变任务定义时，必须走变更：旧任务标注已变更，新任务开启新的任务链并拥有新定义。
- 用户要补充任务边界时，优先添加子任务，而不是覆盖原定义。
- `descriptionText` 表达任务背景、目标或范围；进入 Day Todo 后成为日轨迹快照。
- `note` 表达临时想法、提醒或补充说明；进入 Day Todo 后成为日轨迹快照。

### DayTrace

表示任务进入某个 Day Todo 后留下的日轨迹。

关键字段：

- `id`
- `chainId`
- `definitionId`
- `date`
- `status`
- `priority`
- `continuationSeq`
- `descriptionText`
- `note`
- `manualProgressPercent`
- `continuedFromTraceId`
- `changedToTraceId`
- `createdAt`
- `completedAt`
- `settledAt`

状态：

- `pending`：待完成
- `completed`：已完成
- `unfinished`：未完成
- `continued`：已延续
- `changed`：已变更
- `returnedToPool`：已回池
- `abandoned`：已废弃

规则：

- DayTrace 不允许删除。
- 当前日期 DayTrace 可在待完成和已完成之间切换。
- 锁定 Day Todo 中的已完成状态不可撤销。
- 日结束时仍为待完成的 DayTrace 自动结算为未完成。
- 历史未完成只能延续复制或废弃，不能回池。
- 延续复制会让原 DayTrace 进入已延续，并在目标日期生成新 DayTrace。
- 变更会让旧 DayTrace 进入已变更，并在当天生成新 DayTrace。

### PlannedTrace

表示未来日期的计划草稿。实现上可与 DayTrace 共表或分表，但领域语义必须区分。

规则：

- 日期晚于当前本地日期时，它是计划草稿。
- 计划草稿可以在未来日期之间无痕调整。
- 计划草稿可以无痕回到任务池。
- 计划草稿不能标记完成，不能生成复盘结算。
- 到达其日期后，自动进入当天 Day Todo，状态为待完成。

### Subtask

表示某条日轨迹下的任务细化项。

关键字段：

- `id`
- `lineageId`
- `traceId`
- `title`
- `status`
- `difficulty`
- `position`
- `continuedFromSubtaskId`
- `createdAt`
- `completedAt`
- `settledAt`

规则：

- 子任务不独立形成任务链或日轨迹。
- 子任务用于补充任务定义，不用于覆盖任务定义。
- 子任务状态包括 `pending`、`completed`、`unfinished`、`continued`、`abandoned`。
- 子任务难度包括 `easy`、`medium`、`hard`，用于加权计算父任务完成进度。
- `lineageId` 用于串联同一个子任务跨日期延续后的多个子任务记录，但它不是独立任务链。
- 延续复制默认只复制未完成子任务到新日轨迹。
- 被复制的原日期子任务进入 `continued`，目标日期新子任务继承同一个 `lineageId`。
- 已完成子任务留在历史日轨迹中。
- 父级日轨迹仍存在 `pending` 或 `unfinished` 子任务时，父任务不能标记完成。
- 部分完成是根据子任务统计派生的展示标签，不是父任务正式状态。

## 视图定义

### Day Todo

显示某个日期的任务轨迹。

日期类型：

- 历史日：已锁定，事实不可改写。
- 当前日：可完成、撤销完成、变更、回池、废弃、延续。
- 未来日：可排期和调整优先级，但不能完成或结算。

必须展示：

- 日期切换。
- 当日任务列表。
- 任务状态。
- 延续次数。
- 当日优先级。
- 子任务进度。
- 每日复盘。

### 任务池

显示没有具体日期的待排期任务。

支持操作：

- 新建任务。
- 编辑尚未产生日轨迹的任务定义。
- 排期到今天、未来日期或指定日期。
- 删除尚未产生日轨迹的新任务。若实现更严格，也可只做归档；但不能影响已有日轨迹。

### 未来计划

汇总所有已排期到未来日期但尚未到期的计划草稿。

支持操作：

- 按日期查看。
- 调整到另一个未来日期。
- 调整未来日内优先级。
- 回到任务池。

不支持操作：

- 标记完成。
- 生成复盘。
- 延续复制。

### 未完成池

按任务链去重汇总存在未完成历史或已废弃历史的任务。未完成历史包括 `unfinished`、已经被继续处理的 `continued`，以及被用户明确废弃但仍需可见的 `abandoned`。

展示：

- 任务当前定义。
- 未完成次数和日期。
- 延续次数。
- 是否存在活跃日轨迹。
- 已延续待完成状态。
- 已废弃状态。

支持操作：

- 查看未完成明细。
- 延续复制到目标日期。
- 跳转到活跃日轨迹。
- 废弃任务链。
- 重新启用已废弃任务链。

规则：

- 如果任务链已经有活跃日轨迹，未完成池仍显示它，但标注已延续待完成。
- 已延续待完成时不能再次延续。
- 活跃日轨迹完成后，该任务链从未完成池移除。
- 废弃后，该任务链仍在未完成池可见，并标注已废弃。
- 重新启用只取消已废弃标记：当前日或未来日轨迹恢复为 `pending`，历史日轨迹恢复为 `unfinished`；该操作不创建今日任务、不复制子任务、不增加延续次数。

### 已完成池

按完成日轨迹逐条展示，不按任务链去重。

必须展示：

- 任务当前定义。
- 完成日轨迹。
- 任务链开始日期。
- 延续到的日期列表。
- 完成日期。
- 子任务轨迹摘要，包括每条子任务的开始日期、延续日期列表、完成日期或废弃记录。

规则：

- 开始日期、延续日期和完成日期从同一任务链的日轨迹派生，不允许用户手工编辑。
- 没有发生延续复制的任务，延续日期列表为空。
- 通过延续复制完成的任务，完成日期也应出现在延续日期列表中，用于表达“延续到了完成日”。
- 子任务轨迹摘要从 `lineageId` 和日轨迹日期派生，不允许用户手工编辑。

支持操作：

- 查看完成记录。
- 跳转到对应日期。
- 复制为新任务。

不支持操作：

- 撤销历史完成。
- 延续已完成任务链。

## 状态转换

当前日：

- `pending -> completed`
- `completed -> pending`
- `pending -> returnedToPool`
- `pending -> changed`
- `pending -> continued`
- `pending -> abandoned`

日结束：

- `pending -> unfinished`

历史日：

- `unfinished -> continued`
- `unfinished -> abandoned`
- `abandoned -> unfinished`，仅通过重新启用取消废弃标记。

已废弃当前日或未来计划：

- `abandoned -> pending`，仅通过重新启用取消废弃标记。

未来计划：

- `planned -> planned`，可换未来日期。
- `planned -> taskPool`，可无痕回池。
- `planned -> pending`，到达日期后自动进入当天 Day Todo。

禁止转换：

- 历史 `completed -> pending`
- 历史 `unfinished -> taskPool`
- 已废弃任务链直接延续；必须先重新启用，再按普通未完成规则操作。
- 有活跃日轨迹的任务链再次延续
- 已有日轨迹的任务定义覆盖式编辑

## 核心用例接口

以下接口是领域层语义，不是最终 Swift API 签名。

### DayTodoUseCase

```swift
func getDayTodo(date: LocalDate) -> DayTodoView
func settleDaysUpTo(today: LocalDate, now: Instant) throws
func setViewSort(date: LocalDate, sort: ViewSort)
func updatePriority(traceId: TraceID, newPriority: Int) throws
```

约束：

- `updatePriority` 只能用于当前日或未来日。
- 历史日只能使用查看排序，不能改当日优先级。

### TaskPoolUseCase

```swift
func createPoolTask(title: String, descriptionText: String?, note: String?) throws -> TaskChainID
func updatePoolTask(chainId: TaskChainID, title: String, descriptionText: String?, note: String?) throws
func scheduleFromPool(chainId: TaskChainID, date: LocalDate) throws -> TraceID
func deleteUnscheduledTask(chainId: TaskChainID) throws
```

约束：

- 只有尚未产生日轨迹的任务才能覆盖编辑。
- 排期到未来日期后进入未来计划。
- 排期到当前日期后进入 Day Todo 并生成日轨迹。

### TraceUseCase

```swift
func markCompleted(traceId: TraceID, now: Instant) throws
func undoCompleted(traceId: TraceID, now: Instant) throws
func returnToPool(traceId: TraceID, now: Instant) throws
func continueTrace(traceId: TraceID, targetDate: LocalDate, now: Instant) throws -> TraceID
func changeTrace(traceId: TraceID, newTitle: String, newDescriptionText: String?, newNote: String?, now: Instant) throws -> TraceID
func abandonChain(from traceId: TraceID, now: Instant) throws
func reactivateAbandonedChain(from traceId: TraceID, today: LocalDate, now: Instant) throws -> TraceID
func copyAsNewTask(from traceId: TraceID, target: NewTaskTarget) throws -> TaskChainID
func updateTraceText(traceId: TraceID, descriptionText: String?, note: String?) throws
func setManualProgress(traceId: TraceID, percent: Int) throws
func getTraceProgress(traceId: TraceID) -> TraceProgress
```

约束：

- `undoCompleted` 只允许当前日期。
- `returnToPool` 只允许当前日期的活跃日轨迹。
- `continueTrace` 只允许历史未完成或当前待完成，且任务链没有其他活跃日轨迹。
- `changeTrace` 会生成新任务链、新定义和同日新日轨迹，旧日轨迹保留并指向新日轨迹。
- `copyAsNewTask` 创建新任务链，不继承延续次数。
- `updateTraceText` 只允许当前日或未来日的待完成日轨迹，历史日只读。
- `setManualProgress` 只允许没有子任务的当前日待完成日轨迹，并且不能低于进度下限。
- 有子任务的日轨迹进度由子任务难度权重自动计算。

### AggregatePoolUseCase

```swift
func listUnfinishedPool() -> [UnfinishedPoolItem]
func listCompletedPool() -> [CompletedPoolItem]
func listCompletedSubtaskRecords() -> [CompletedSubtaskRecord]
```

约束：

- `UnfinishedPoolItem` 按任务链去重，并包含未完成或已延续明细。
- `CompletedPoolItem` 按完成日轨迹逐条返回，不按任务链去重。
- `CompletedPoolItem` 必须包含 `CompletedTaskTrajectory`，展示开始日期、延续日期列表和完成日期。
- `CompletedTaskTrajectory` 必须包含子任务轨迹摘要。
- `CompletedSubtaskRecord` 按完成日期展示已完成子任务，并标注父任务。

### SettingsUseCase

```swift
func getPreferences() -> AppPreferences
func updateTheme(theme: AppTheme)
func updateLanguage(language: AppLanguage)
func listSyncEndpointOptions() -> [SyncEndpointOption]
```

约束：

- 第一期外观主题为冷灰和微暖纸感。
- 第一期界面语言为中文和 English。
- 自定义同步端点和 iCloud 云同步是规划中入口，不能表现为已可用同步。

### SubtaskUseCase

```swift
func addSubtask(traceId: TraceID, title: String, difficulty: SubtaskDifficulty, now: Instant) throws -> SubtaskID
func completeSubtask(subtaskId: SubtaskID, now: Instant) throws
func abandonSubtask(subtaskId: SubtaskID, now: Instant) throws
func updateSubtaskDifficulty(subtaskId: SubtaskID, difficulty: SubtaskDifficulty) throws
func getSubtaskProgress(traceId: TraceID) -> SubtaskProgress
```

约束：

- 只能在当前日期的待完成日轨迹中完成或废弃子任务。
- 只能在当前日期的待完成日轨迹中修改子任务难度权重。
- 有未完成子任务时，父级日轨迹不能标记完成。
- 子任务延续由父任务延续复制触发，用户不能把子任务单独移动到另一天。

### FuturePlanUseCase

```swift
func listFuturePlans(range: DateRange?) -> [FuturePlanItem]
func rescheduleFuturePlan(traceId: TraceID, targetDate: LocalDate) throws
func returnFuturePlanToPool(traceId: TraceID) throws
func materializePlansForToday(today: LocalDate, now: Instant) throws
```

约束：

- 只能处理未来日期。
- 不能标记完成。
- 到达日期后必须转为当天 Day Todo 的待完成日轨迹。

### ReviewUseCase

```swift
func getDailyReview(date: LocalDate) -> DailyReviewView
func updateDailyReview(date: LocalDate, summary: String?, unfinishedReason: String?, tomorrowNote: String?) throws
```

约束：

- 自动统计从日轨迹派生。
- 手写复盘可补写。
- 复盘不能改写任务事实。

### ZhulongAIUseCase

```swift
func listAIProviders() -> [AIProvider]
func saveAIProvider(_ provider: AIProviderDraft) throws
func testAIProvider(providerId: AIProviderID) async throws -> AIProviderHealth
func analyzeDailyReview(date: LocalDate, scope: AIScope) async throws -> AISuggestionDraft
func analyzeHabits(range: DateRange, scope: AIScope) async throws -> HabitInsightDraft
func decomposeTask(traceId: TraceID, scope: AIScope) async throws -> AISuggestionDraft
func suggestSchedule(scope: AIScope) async throws -> AISuggestionDraft
func suggestLabels(scope: AIScope, mode: LabelSuggestionMode) async throws -> AISuggestionDraft
func applyAISuggestion(_ draftId: AISuggestionDraftID, selection: AIApplySelection) throws
func discardAISuggestion(_ draftId: AISuggestionDraftID) throws
```

约束：

- provider 必须支持自定义 endpoint、model 和安全凭证引用。
- AI provider 未配置、不可用或被用户关闭时，普通清单功能不降级。
- 烛龙只能生成建议草稿，不能直接写入历史事实。
- `applyAISuggestion` 必须把建议转成普通领域操作，例如创建任务、添加子任务、排期、延续、写入 label 或保存复盘文本。
- 每次发送到远程 provider 前，必须明确数据范围。
- 详细规格见 `docs/product/zhulong-ai-agent.md`。

### DataPackageUseCase

```swift
func exportDataPackage(destination: URL) throws
func importDataPackage(source: URL, mode: ImportMode) throws
func configureSyncEndpointPlaceholder(kind: SyncEndpointKind, location: String?) throws
```

约束：

- 第一期只做手动导出 / 导入。
- 第一期不做自动双向同步。
- 第一期不直接同步裸 SQLite 文件。

### UndoUseCase

```swift
func undoLastLocalAction() throws
func canUndoLastLocalAction() -> Bool
```

约束：

- 只支持撤销尚未固化为历史事实的当前日或计划草稿误操作。
- 可撤销范围包括当天完成切换、当日优先级调整、刚创建的未排期任务、刚添加的子任务。
- 不可撤销日结束结算、历史完成、历史延续、历史变更和废弃。
- 撤销不能删除或改写历史日轨迹。

## 数据层建议

采用 SwiftUI + Swift Package 领域层 + SQLite/GRDB。

核心表建议：

- `days`
- `task_chains`
- `task_definitions`
- `day_traces`
- `subtasks`
- `labels`
- `task_label_assignments`
- `ai_providers`
- `ai_suggestion_drafts`
- `app_preferences`
- `sync_settings`

数据库约束建议：

- `day_traces` 禁止删除。
- `task_definitions` 已被日轨迹引用后禁止覆盖关键字段。
- 同一任务链最多一个活跃日轨迹。
- 历史日优先级不可修改。
- 废弃任务链不可新增延续轨迹；重新启用只恢复原日轨迹状态，不新增轨迹。
- AI 建议草稿不是历史事实，可以丢弃。
- label assignment 不改变任务状态，也不能改写日轨迹。

查询视图建议：

- `task_pool_view`
- `future_plan_view`
- `unfinished_pool_view`
- `unfinished_detail_view`
- `completed_pool_view`
- `completed_subtask_record_view`
- `completed_trajectory_detail_view`
- `completed_subtask_trajectory_detail_view`
- `day_todo_view`
- `sync_endpoint_options_view`
- `label_task_summary_view`

可选：

- `change_journal` 作为未来同步和诊断辅助流水，但不是事实来源。
- `ai_request_diagnostics` 只记录 provider 健康、延迟和失败原因，不记录 API Key 或完整敏感 prompt。

## 验收标准

必须通过以下核心场景：

1. 新建任务到任务池，再排期到今天，任务池不再显示该任务。
2. 今天任务完成后可当天撤销；跨日后不可撤销。
3. 今天待完成任务跨 00:00 后自动变未完成，并出现在未完成池。
4. 未完成任务延续到明天后，原日期保留已延续轨迹，新日期生成待完成轨迹。
5. 同一任务链已有活跃日轨迹时，未完成池仍显示但不能再次延续。
6. 任务变更后，当天同时显示旧任务和新任务，旧任务标注已变更。
7. 历史日轨迹不可删除、不可覆盖、不可无痕改期。
8. 未来计划可换未来日期，可回任务池，但不能完成。
9. 未来计划到期后自动进入当天 Day Todo。
10. 未完成池按任务链去重，明细显示每个未完成、已延续或已废弃日期。
11. 已完成池按完成日轨迹逐条显示，并展示每条任务链的开始日期、延续日期列表和完成日期。
12. 父任务存在未完成子任务时不能完成，只能展示部分完成进度。
13. 未完成子任务随父任务延续复制到目标日期，并保留同一条子任务轨迹线。
14. 已完成池的任务轨迹可展开查看每条子任务的开始日期、延续日期和完成日期。
15. 每日复盘可补写，但不能改变统计事实。
16. 数据包可导出并在空库导入后恢复核心数据。
17. `Cmd+Z` 只能撤销当前日或计划草稿误操作，不能抹掉历史轨迹事实。
18. 未配置 AI provider 时，Day Todo、任务池、未来计划、未完成池、已完成池和每日复盘仍完整可用。
19. 烛龙 可以生成复盘、任务拆解、排期和 label 建议草稿，但不能未经确认写入任务事实。
20. 烛龙 发送远程请求前，必须展示本次使用的数据范围。
21. 烛龙的习惯画像必须带证据和置信度，且只表示时间窗口内的分析假设。
22. 废弃任务链仍在未完成池可见，带已废弃标记；重新启用后只取消废弃标记，不创建今日任务。
22. 烛龙页面可展示《苦昼短》/ 衔烛龙意象作为完整 slogan 元素。

## 明确不做

- 番茄钟
- 白噪音
- 图片附件
- 语音输入
- 自然语言日期解析
- 小组件
- Watch
- 账号系统
- 自动云同步
- 周报 / 热力图 / 高级统计
- 多人协作
- 重复任务
- 多窗口编辑
- 菜单栏快速添加

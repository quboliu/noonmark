# 任务生命周期状态机源码评审与升级重构建议

- 日期：2026-07-22
- 状态：Proposed
- 文档语言：新加坡中文
- 审查范围：`NoonmarkCore`、`NoonmarkStorage`、同步、Mac App、`NoonmarkAI`、`NoonmarkZhulong`、相关测试与领域文档
- 本轮分级：A（跨 module 架构评审，只落盘建议）
- 后续实施分级：P（涉及 SQLite schema、数据包、同步语义、隐藏取消事实与真实 App 用户路径）

> 本文是技术架构附录，不是任务行为政策。延期、延续、回池、变更、废弃、撤回及各页面显示的产品 ground truth，先以 `docs/product/task-lifecycle-behavior-policy.md` 的确认结果为准；本文中的目标模型必须随该政策更新。

## 1. 结论先行

不建议继续在现有 `TraceStatus`、`TaskChainState` 和散落的日期／锁定 guard 上增加 case 或补条件。当前实现不是一个单一 enum 状态机，而是以下隐式乘积状态机：

```text
任务状态 = TaskChain.state
         × DayTrace.status
         × Subtask.statusⁿ
         × past / today / future
         × Day.lockedAt
         × manual / weighted progress
         × continuation / change / cancellation relations
```

真正的问题不是“少了一个状态”，而是执行结果、位置、关系、可见性、持久化墓碑和用户动作被压进同一批 raw enum；规则随后分散到 Core mutation、snapshot validator、SQLite view、Sync merger、SwiftUI menu、AI scope 和烛龙每日收尾。`NoonmarkEngine` 因而暴露 5 张 dictionary、50 多个公开方法，却仍要求调用者自行组合状态、日期和锁定条件，module 不够深，规则 locality 很差。

建议升级为一个 in-process 深 module `TaskLifecycle`：

1. 外部只提供 `inspect`、`apply`、`project` 三类 interface。
2. `inspect` 返回 typed `TaskSituation` 和 `ActionOffer`；UI、烛龙和 AI 不再接触 persistence enum。
3. `apply` 采用 `candidate → 完整校验 → TaskChange`，失败前后状态必须全等。
4. `project` 统一生成 Day Todo、任务池、未来计划、未完成池、已完成池、任务轨迹、统计和 AI evidence。
5. 把未来**计划草稿**、已形成的**日轨迹**、用户可见执行结果、跨日／回池／变更关系、隐藏取消事实拆成正交类型。
6. 保存 typed、insert-only relational evidence，但不把 generic event log 变成唯一事实源；继续遵守 ADR 0004 的“关系事实，不做完整 event sourcing”。
7. SQLite、DataPackage 和 Sync 必须消费同一个 `ValidatedTaskState`／invariant module；repository interface 要明确区分 append-only commit 和 data-import replace。

本轮还确认了若干不是“审美问题”而是实际 correctness defect：合法公开操作可产生无法再次载入的 snapshot；结算失败会留下半次 mutation；隐藏的 `cancelledDraft` 会进入用户任务轨迹；烛龙每日收尾的 counts 与 evidence 使用不同集合；UI 会提供 Core 必然拒绝的动作。

### 1.1 精细行为边界对技术方案的修正

第二轮从跨午夜、时区回退、同步并发、A→B→C 变更链和子任务 lineage 反推后，目标 module 还必须包含四个不能留给调用者的内核：

1. `WorkdayAuthority`：以稳定工作时区产生唯一 effective workday 与 day-close fact，分开生效时刻和设备补处理时刻。
2. `LifecycleCommandLedger`：每项生命周期决定带稳定 `operationID`、actor／device、basis revision、目标身份和 receipt；同一命令重试返回同一结果。
3. `LifecycleRelationGraph`：在 chain 级保证单一执行前沿、变更单前驱／单后继、叶边撤回和 parent／child lineage 闭合，不能只校验单条 trace。
4. `SemanticConflictResolver`：等价并发命令可 canonicalize，互斥命令必须形成任务级冲突与新的前向解决事实；不能再由 record timestamp／device LWW 静默决定任务结果。

因此 SQLite generation CAS 应保留为防并发覆盖机制，但它只保护“没有用旧 snapshot 覆盖新 snapshot”，不能替代命令幂等、语义冲突或多端收敛。完整产品边界和运行反例见 `docs/product/task-lifecycle-behavior-policy.md` 的 P-29 至 P-45。

## 2. 需求、成功标准与非目标

### 2.1 用户目标

全面梳理当前任务状态机的真实流转和约束，基于源码评审不合常理之处，并给出可执行的升级重构建议，为后续实施建立共同底稿。

### 2.2 本文成功标准

- 以源码和运行产物还原实际状态乘积、动作 guard、投影与持久化语义。
- 区分“已证实缺陷”“validator 缺口”“领域决策矛盾”和“架构风险”。
- 同时覆盖 Core、SQLite、DataPackage、Sync、Mac UI、AI、烛龙和测试。
- 正面比较至少三种 interface 设计，再作选择。
- 给出目标 domain model、module seam、迁移次序、验证矩阵、风险、灰度、监控与回滚。
- 不用 build 成功或现有测试全绿代替症状级证据。

### 2.3 本轮非目标

- 不修改业务源码、schema、`CONTEXT.md` 或 ADR。
- 不替产品决定尚有矛盾的领域政策。
- 不承诺旧开发数据迁移；项目未发布，后续继续遵守 clean cut。
- 不把 archived HTML prototype 当视觉 oracle。

## 3. 证据方法与运行结果

本文使用以下证据标记：

| 标记 | 含义 |
|---|---|
| `[R]` | 本轮运行产物或专用探针已复现 |
| `[S]` | 源码存在确定、闭合的控制流证据 |
| `[V]` | validator／schema 没有 rejection path；须用后续 characterization test 固化 |
| `[D]` | 源码、`CONTEXT.md`、产品规格或 ADR 之间存在领域决策矛盾 |

本轮实际运行：

| 命令／探针 | 结果 | 能证明什么 | 不能证明什么 |
|---|---:|---|---|
| `make test-unit` | Core 190、AI 24、Mac UI Contract 26，0 failure | 当前已编码的 unit contract 稳定 | transition matrix 完整、真实 App 正确 |
| `make test-integration` | Storage 186，0 failure；1 项 live iCloud 测试因未启用 live flag 而跳过 | SQLite／DataPackage／本地 Sync 已声明路径通过 | 真实 iCloud live 收敛、未声明 invariant |
| `make test-deterministic-sim` | 1 test，默认 64 runs × 140 operations，0 failure | 当前 simulation 动作集在单调时钟下稳定 | 未纳入的 undo／reactivation／删除／非单调时钟 |
| Storage 定向重跑 | 55 tests，0 failure | topology、schema、DataPackage、undo persistence、Sync topology 当前 contract 通过 | 跨 aggregate 缺口不存在 |
| 专用 Core 探针 | 2 个问题均复现 | 公开操作可破坏 integrity；失败 mutation 非原子 | 其他所有动作均有同型问题 |

专用探针在先执行 `scripts/reset-dev-data` 后，使用当前构建产物调用真实 `NoonmarkCore` 公开 interface，得到：

```text
CANCEL_COMPOSITION: validation failed after successful public commands:
invalidInput("cancelled trace draft contains referenced history facts")
CANCEL_TRAIL: createdInPool,scheduled,returnedToPool

SETTLEMENT: failed=invalidInput("content mutation time cannot move backwards");
trace=unfinished; child=pending; dayLocked=false
```

结论：测试全绿只证明“已写进测试的约束”稳定，不能证明状态机完整。

本轮没有修改 Mac UI，因此没有把真实 `.app` E2E 当作文档改动的验收步骤；当前环境也没有 `frontend-verify` skill。后续实施一旦改变 UI action offer、投影或状态文案，必须按第 13 节补真实 `.app` E2E、console、SQLite 重启探针和 DMG 安装启动。仓库当前没有 backend deployed endpoint、Dockerfile、compose 或生产部署入口，本文不臆造容器／部署验证结论。

## 4. 当前真实状态机

### 4.1 持久状态维度

| 维度 | 当前类型／来源 | 实际语义 | 问题 |
|---|---|---|---|
| 任务链 | `TaskChainState.active/abandoned` | `active` 近似“没有被标记 abandoned” | 已完成或无执行前沿的链仍是 active；`abandoned` 同时承担用户废弃、任务池删除和 undo tombstone |
| 日轨迹 | `TraceStatus` 8 cases | 执行、移动、历史结果及隐藏取消 | 把正交维度压进一个 enum |
| 子任务 | `SubtaskStatus` 6 cases | 子任务执行结果及隐藏取消 | 父终态与子开放状态没有统一政策 |
| 日期角色 | `trace.date` 对调用者传入 `today` | past／today／future | `today` 由每个调用者重复提供，不是状态机单一权威 |
| 日锁定 | `Day.lockedAt` | 日结束后的不可编辑范围 | 延续和重新启用仍会原地改 locked Day 的 status |
| 当前执行前沿 | `pending` trace 扫描 | 一个任务链最多一个 pending | 只有部分 validator／调用路径理解它 |
| 进度 | manual 字段、subtask lineage、历史 floor | 手动或加权进度 | capability、denominator、展示 mode 不一致 |
| 隐藏身份 | `cancelledDraft` + witness fields | 防止 undo／sync 复活 | raw enum 可跨 presentation seam 泄漏 |

定义位置：

- `Sources/NoonmarkCore/Models.swift:3-71`
- `Sources/NoonmarkCore/Models.swift:400-452`
- `Sources/NoonmarkCore/Models.swift:633-879`
- `Sources/NoonmarkCore/Models.swift:918-1009`

### 4.2 `DayTrace` 主要流转

| 动作 | 来源 | 目标 | 关键 guard／副作用 |
|---|---|---|---|
| 排期 | 任务池草稿 | `pending` | `date >= today`、目标 Day 未锁定 |
| 完成 | today `pending` | `completed` | 未锁定；没有 `pending/unfinished` 子任务 |
| 撤回完成 | today `completed` | `pending` | 未锁定 |
| 日结束 | past `pending` | `unfinished` | 之后锁定 Day |
| 当前日回池 | today `pending` | `returnedToPool` | materialize 新任务池草稿，来源进入任务轨迹 |
| 未来回池 | future `pending` | `cancelledDraft` | 不得是 continuation target；保存取消 witness |
| 未来无痕改期 | future `pending` | 同一 `pending` 改 date | 来源与目标均未来、未锁定 |
| 延续 | `unfinished` 或 today `pending` | 来源 `continued` + 新 `pending` | 来源须是最新 frontier；目标严格晚于来源；复制开放子任务 |
| 变更 | today `pending` | 来源 `changed` + 新 chain/new `pending` | 复制开放子任务，建立 change pointer |
| 废弃 | `pending/unfinished` | `abandoned` + chain abandoned | 实际优先操作同链 active trace；没有统一 today／lock guard |
| 重新启用 | `abandoned` | 原地 `pending` 或 `unfinished` | 未锁且 `date >= today` 变 pending，否则 unfinished |

核心实现：`Sources/NoonmarkCore/NoonmarkEngine.swift:797-1116`、`:1558-1610`。

几个需要特别注意的组合：

- `continued + settledAt == nil` 表示当前日主动延续，不进入未完成池。
- `continued + settledAt != nil` 表示历史未完成后延续。
- `unfinishedPool()` 还用同链 `continuedCount > 1` 改变旧 trace 是否进入池。
- `cancelledDraft` 同时表达未来计划草稿取消与 snapshot undo 隐藏事实，靠日期／witness 形状区分。
- `abandonChain(from:)` 传入 historical trace 时，若同链已有 active trace，会改 active trace，而不是传入 trace。

这些不是清楚的状态名，而是调用者必须记忆的编码协议。

### 4.3 子任务主要流转

| 动作 | 来源 | 目标 | 父级限制 |
|---|---|---|---|
| 新增／复制 | 无 | `pending` | 父 trace pending、Day 未锁；直接新增没有 today 限制 |
| 完成／撤回 | pending／completed | completed／pending | 父 trace 必须 today pending、未锁 |
| 废弃 | pending | abandoned | 父 trace today pending、未锁 |
| 日结束 | pending | unfinished | 随父 trace settlement |
| 延续复制 | pending／unfinished | source continued + target pending | 保留 lineage |
| 变更复制 | pending／unfinished | 新 chain/new lineage pending | 来源 child 保持开放状态 |
| 回池 | pending／unfinished | planned subtask | 来源 child 保持开放状态 |
| 删除 | 任意 presentable | cancelledDraft | 父 trace pending、`date >= today`、未锁 |

实现：`Sources/NoonmarkCore/NoonmarkEngine.swift:1148-1304`、`:2528-2645`。

### 4.4 状态如何被投影

| 调用面 | 当前判定 | 漂移风险 |
|---|---|---|
| Day Todo／Calendar／Search | `isVisibleInDayTodo` | 排除 changed／returned 后又想统计它们 |
| 任务池 | active chain 且无 trace，或全部为 returned／cancelled | “位置”是全链扫描派生状态 |
| 未来计划 | future + pending | 无法区分普通计划草稿与 continuation target |
| 未完成池 | unfinished／continued／abandoned + nullable clocks／数量 | 以数据形状猜政策 |
| 已完成池 | completed trace | 相对直接 |
| 任务轨迹 | 遍历所有 trace，再按 status 映射 outcome | hidden cancelled fact 可泄漏；原地 undo/reactivate 会丢历史序列 |
| DailyReviewStats | 先取 Day Todo visible，再统计所有 outcome | changed／returned 字段恒为 0 |
| 烛龙每日收尾 | traces 取 `formsDayHistory`，counts 取 DailyReviewStats | 两个集合不同，持久化自校验失败 |
| AI | Day／pool projection 后又对 raw trace 重复过滤 | 新状态容易漏改；Provider 可接触过宽模型 |
| SQLite view | 独立 SQL status 条件 | 已与 Core unfinished projection 漂移 |

主要位置：

- `Sources/NoonmarkCore/NoonmarkEngine.swift:602-785`
- `Sources/NoonmarkCore/NoonmarkEngine.swift:1612-1762`
- `Sources/NoonmarkStorage/SQLiteSchema.swift:2429-2625`
- `Sources/NoonmarkAI/AIScope.swift:108`
- `Sources/NoonmarkAI/AIPromptBuilder.swift:65-161`
- `Sources/NoonmarkAI/LocalInsightAnalyzer.swift:40-89`
- `Sources/NoonmarkZhulong/ZhulongDailyClose.swift:90-145,438-485`

## 5. 当前设计值得保留的部分

重构不应抹掉以下已建立的能力：

1. **稳定 identity 与 insert-only relational model**：任务链、任务定义、日轨迹、子任务和关系不是可随意删除的 UI row。
2. **完整 snapshot gate**：repository save/load、DataPackage 和 Sync 都已尝试在发布前执行 integrity validation。
3. **validated sync base 与结构原子提交**：ADR 0024 的方向正确，Sync 不是逐 row 盲写。
4. **exact mutation frontier**：ADR 0022 已定义单一时钟 seam 和 fail-closed 规则。
5. **snapshot undo 的 candidate → validate → adopt**：这是普通 mutation 应复用的原子性样板。
6. **`DayTraceCompletionCapability`**：任务行、菜单和 bulk completion 已共享同一能力判断，是 typed action offer 的可行样板。
7. **烛龙 Todo diff 委托 Core mutation**：AI 没有直接改 raw dictionaries，方向正确。
8. **项目未发布的 clean cut**：允许一次完成 schema／DataPackage／Sync 语义升级，不需要背负旧开发数据兼容分支。

## 6. 已证实缺陷

### F-01：合法公开操作可生成无法通过自身 integrity validation 的 snapshot `[R]` — 阻断

公开动作序列：

```text
创建任务池任务
→ 排期到未来
→ 新增子任务
→ 删除该子任务（child = cancelledDraft）
→ 未来计划回池（parent trace = cancelledDraft）
→ NoonmarkEngine(snapshot:) 重新载入失败
```

原因：`deleteSubtask` 允许 future pending trace 下的 child 变 `cancelledDraft`，但 `validateCancelledDraftFacts` 要求 hidden parent 下所有 child 都是没有 terminal facts 的纯 `pending`。

- mutation：`NoonmarkEngine.swift:1281-1304`、`:825-846`
- rejection：`NoonmarkSnapshot.swift:300-390`，尤其 `:337-345`
- 运行结果：`cancelled trace draft contains referenced history facts`

这是 command postcondition 与 snapshot invariant 互相矛盾，不应靠放宽一个 guard 临时解决。目标模型必须定义嵌套取消的 canonical 表达，并保证任何成功 command 的输出都可持久化／同步。

### F-02：普通状态迁移不是 exception-safe `[R]` — 阻断

`settleDays` 先把 parent trace 写成 `unfinished`，再结算 child。若 child 的 `updatedAt` 晚于本次 `now`，child clock 检查抛错时 parent 已写入。

运行探针确认失败后状态为：

```text
trace=unfinished; child=pending; dayLocked=false
```

即一次失败留下“未完成父轨迹 + 开放子任务 + Day 未锁”的半次 transition。

- `NoonmarkEngine.swift:1558-1610`
- `NoonmarkEngine.swift:2638-2645`

`continueTrace` 也先写来源／目标 traces，再复制 children，存在同型风险：`NoonmarkEngine.swift:942-999`、`:2528-2555`。

根本解是所有 command 都在 candidate state 应用并完成全量 postcondition validation 后才 adopt；不能逐方法补预检。

### F-03：隐藏 `cancelledDraft` 泄漏进用户任务轨迹 `[R]` — 阻断

未来计划草稿回池后，`taskTrail` 输出：

```text
createdInPool, scheduled, returnedToPool
```

但 `CONTEXT.md:163-169` 和 ADR 0020 明确规定计划草稿取消事实不是用户可见日轨迹，不得进入任务轨迹。实现却遍历所有 trace，并把 `cancelledDraft` 映射成 `returnedToPool`：

- `NoonmarkEngine.swift:621-680`
- `NoonmarkEngine.swift:1739-1762`
- `Models.swift:18-39`

这证明 `isVisibleInDayTodo`、`formsDayHistory`、`isUserPresentable` 三个 Boolean 不是安全的 presentation seam。

### F-04：烛龙每日收尾 snapshot 使用两套不相等的事实集合 `[S]` — 阻断

`ZhulongDailyCloseSnapshot`：

- `traces` 取该日全部 `formsDayHistory`，包括 changed／returnedToPool。
- `counts` 取 `dailyReviewStats`；后者先过滤 Day Todo visible，因此 changed／returnedToPool 永远为 0。
- persistence validation 又要求 `counts.total == traces.count` 且逐状态相等。

所以某日发生“变更”或“当前日回池”后，每日收尾可建立内存对象，但持久化／恢复校验必然拒绝。

- `NoonmarkEngine.swift:1612-1624`
- `ZhulongDailyClose.swift:100-145,438-485`
- `ZhulongSessionPersistence.swift:405` 附近

根本解是区分 `DayWorkspaceSummary` 与 `DailyOutcomeSummary`，每日收尾只消费 canonical outcome evidence。

### F-05：UI 向未来 continuation target 提供 Core 必然拒绝的回池动作 `[S]` — 高

- `futurePlans()` 纳入所有 future pending：`NoonmarkEngine.swift:683-696`。
- context menu 和 bulk 只检查 future + pending：`NoonmarkStore+PresentationUndo.swift:295-297`、`NoonmarkStore+SelectionProductivity.swift:173-181`。
- Core 明确拒绝 `carriedFromTraceID != nil`：`NoonmarkEngine.swift:825-835`。

这是 capability 与 mutation 使用不同 rule 的直接后果。`inspect` 和 `apply` 必须共用同一个 evaluator。

### F-06：当前任务“延续”DatePicker 默认选择必然非法的今天 `[S]` — 高

`.continueTrace` 的 picker 初始日期和提示允许 today：

- `App/NoonmarkMacApp/DatePickerSheet.swift:15-23`
- `App/NoonmarkMacApp/NoonmarkStore.swift:485-515`

Core 要求 target date 严格晚于 source date：`NoonmarkEngine.swift:942-965`。对 today pending source，今天必然非法。日期 picker 不应猜规则；`ActionOffer` 应携带 `allowedDates.earliest`。

### F-07：`updateDailyReview` 可通过公开调用破坏 Day clock integrity `[S]` — 高

`updateDailyReview` 非 throwing，直接覆盖 `updatedAt`，没有 finite 或 monotonic 检查：`NoonmarkEngine.swift:1627-1639`。snapshot validator 却要求 Day clocks finite 且 `updatedAt >= createdAt/lockedAt`：`NoonmarkSnapshot.swift:410-429`。

所有持久事实 mutation 都必须经过同一 exact clock seam；每日复盘不是例外。

## 7. Validator、持久化与同步缺口

### F-08：缺少跨 aggregate 状态兼容 invariant `[V]` — 高

`TrajectoryTopologyValidator` 只接收 trace／subtask 图；`NoonmarkSnapshot.validateIntegrity()` 虽验证 parent references 和 Day clocks，却没有统一检查：

- `locked Day + pending trace`
- `abandoned chain + pending trace`
- `completed parent + pending/unfinished child`

这些组合通常被 command path 暗中避免，但 import、sync merge 或直接 snapshot 可构造。相关源码：

- `NoonmarkSnapshot.swift:66-155,225-429`
- `TrajectoryTopologyValidator.swift:30-395`

下一步应先加负例 characterization tests，确认产品期望，再把规则收进唯一 `TaskLifecycleInvariant`。

### F-09：父 trace 终止时没有统一 child resolution policy `[S][D]` — 高

变更与回池会复制开放 child，却让来源 child 保持 `pending/unfinished`；父 trace 已 changed／returned 后，这些 child 没有正常用户 interface 可继续操作。validator 也不检查 parent status × child status。

- `NoonmarkEngine.swift:2557-2622`
- `NoonmarkSnapshot.swift:556-588`

必须为 complete、continue、change、return、abandon、cancel 各自声明 child 的保留、结算、转移、复制或隐藏政策。

### F-10：completion capability 与加权进度使用不同 denominator `[S]` — 高

`SubtaskProgress.canCompleteParent` 只阻止 pending／unfinished；abandoned child 不阻止完成。加权进度却把 abandoned difficulty 放进 totalWeight 且永远不放进 completedWeight。父任务可在显示 0%／50% 时合法完成，然后进度直接跳到 100%，mode 还从 weighted 变 manual。

- `Models.swift:838-879`
- `NoonmarkEngine.swift:2206-2227,2363-2415`

建议默认政策：abandoned child 不进入 actionable denominator，也不阻止父任务完成；完成后仍保留 weighted 来源说明。最终政策须由产品确认。

### F-11：repository `save(snapshot)` 的名字隐藏 append/upsert contract `[S]` — 高

普通 save 验证后做 UPSERT，不删除 snapshot 未出现的旧事实。传入一个较小但自身 valid 的 snapshot 后，再 load 会保留／复活旧 row，结果与输入不同。只有 import path 使用明确 replacement staging。

- `SQLiteEngineRepository.swift:399-465,683-765,1258-1548`

应改为：

```swift
commit(_ change: ValidatedTaskChange, expectedGeneration: Generation)
replaceForDataImport(_ state: ValidatedTaskState)
```

普通 commit 验证 fact-set monotonicity；replace 只供显式 clean-cut import。

### F-12：inverse transition witness 没有贯穿 snapshot／DataPackage／Sync `[S]` — 高

chain reactivation 有显式 immutable witness；trace completion undo、draft restore 与 subtask undo 多以状态形状和 clock 推断。部分 witness 只在 sync outbox／journal，不在 `NoonmarkSnapshot` 与 DataPackage。export/import 会清 sync local state，之后再遇旧 remote abandoned record，可能缺少 reactivation 因果授权。

- `ChainReactivationEnvelope.swift:157-222`
- `CurrentSyncRecordMerger.swift:850-1129`
- `SyncRecordMerger.swift:2087-2614`
- `NoonmarkDataPackage.swift:15-67,200-375`

所有 inverse transition 的 typed witness 必须进入 canonical state、SQLite、DataPackage 和 Sync wire format。

### F-13：SQLite unfinished projection 已与 Core 漂移 `[S]` — 中

SQL `unfinished_pool_view` 包含所有 `.continued`；Core 只有在 `settledAt != nil` 或同链 continued 数量大于 1 时才纳入。当前 SQL view 只在测试使用，生产调用者主要读 Core projection，但双实现已经发生 drift。

- `SQLiteSchema.swift:2436-2500`
- `NoonmarkEngine.swift:698-737`

ADR 0004 所写“核心视图优先通过 SQL view/query 派生”已不符合当前运行架构。新 ADR 应明确唯一 projection source；未使用 SQL view 应删除，若保留只作数据库诊断，则必须做 Core parity tests。

### F-14：SQLite 只表达局部约束，raw corruption 要到 materialize 才暴露 `[S]` — 中

schema 有 CHECK、FK 和禁止删除 day trace 的 trigger，但没有完整表达 trace date、definition/trace chain 一致、visible priority uniqueness、topology edge/cycle、cross-table cancellation identity 和全部 clock ordering。Core load/save 的全量 gate 是主要防线。

这不是要求把所有 domain rule 重写成 SQL；建议明确分工：SQLite 负责局部结构和不可删除事实，`TaskLifecycleInvariant` 负责 aggregate／graph 规则，并用 raw SQL corruption probes 验证 load fail-closed。

## 8. 调用面与领域语义漂移

### F-15：DailyReviewStats 和 Calendar 暴露无法产生的字段 `[S]` — 中

DailyReviewStats 先排除 changed／returned，再统计 changed／returned，所以两个字段恒为 0；现有测试还固定了 0。Calendar 随后从同一 visible 集合计算 changed target，同样无法得到来源。

- `NoonmarkEngine.swift:1612-1624`
- `NoonmarkEngineTests.swift:773-821`
- `App/NoonmarkMacApp/CalendarPage.swift:353` 附近

### F-16：延续次数和未完成池资格由调用者猜测 `[S][D]` — 中

- 未完成页显示 `max(continuationSeq) - 1`，完成详情显示 `max(continuationSeq)`；第一次延续分别显示 0 和 1。
- 未完成池以 `settledAt != nil || continuedCount > 1` 判断 continued 是否算历史。第二次主动延续会让旧的未结算 continued 在没有自身 mutation 的情况下突然进入未完成池，并被当作“错过次数”。

位置：`UnfinishedPoolPage.swift:104,181`、`CompletedRecordDetail.swift:109`、`NoonmarkEngine.swift:698-737,973`。

“延续次数”“未完成原因”必须成为 canonical projection 字段，不应由 view 从 sequence／nullable clock 推断。

### F-17：AI／烛龙接收过宽 raw 模型，scope 还有实际断路 `[S]` — 高

- AI prompt 与 local analyzer 接收 raw trace 后各自过滤 status。
- analyzer 的“已产生结果”集合遗漏 changed／returned，完成率语义偏高。
- Future／Pool／Unfinished／Completed detail rail 虽声明 scopes，新建烛龙 session 时却调用固定 `.currentDayTodo` overload。
- `ZhulongDataScope` 没有 futurePlans；Future 页声明 taskPool + unfinishedPool 也拿不到普通计划草稿。

位置：

- `Sources/NoonmarkAI/AIPromptBuilder.swift:65-161`
- `Sources/NoonmarkAI/LocalInsightAnalyzer.swift:40-89`
- `App/NoonmarkMacApp/WorkspaceDetailRails.swift:146,281,445`
- `App/NoonmarkMacApp/NoonmarkStore+Zhulong.swift:89`
- `Sources/NoonmarkZhulong/ZhulongSession.swift:73`

AI 应只消费授权、去重、不可包含 cancellation witness 的 typed `TaskEvidenceBundle`。

## 9. 需要先由产品确认的领域决策

本轮不直接修改 `CONTEXT.md`，因为以下术语政策仍未闭合。实施前应确认并更新 glossary／ADR：

| 决策 | 当前矛盾 | 建议默认答案 |
|---|---|---|
| locked Day 是否真的 immutable | 文档说历史事实不可改写；continue／reactivate 会原地改 locked trace status | locked execution fact 不改；后续动作追加 relation／chain disposition evidence |
| future continuation 是计划草稿还是日轨迹 | 所有 future item 被称计划草稿；延续又被描述为立即产生新日轨迹 | 未来目标先是带 continuation relation 的计划草稿，到日才 materialize 日轨迹 |
| abandoned 属于 chain 还是 trace execution outcome | 当前两处都存，reactivate 又原地改 trace | abandonment 是 chain disposition evidence；日轨迹保留当日 execution outcome |
| 当前日主动延续的来源结果 | 当前靠 `continued + settledAt nil` 表达 | 显式 `deferred/continued` relation，是否计入未完成池由清楚政策决定 |
| abandoned child 是否计入进度 | capability 排除，weight 包含 | 从 actionable denominator 排除，历史仍显示 |
| 重新启用是否擦掉“曾废弃”轨迹 | 当前 row 原地改写，任务轨迹无法保留完整序列 | current disposition 恢复 active，但 abandonment/reactivation evidence 均保留 |
| 任务链何时算 closed | `active` 只表示非 abandoned | 从 current frontier 与 terminal relations 派生 disposition；不要用 active 表达所有非废弃状态 |

最重要的 domain seam 是：**日轨迹是不可删除的当日执行事实；计划草稿不是日轨迹；任务轨迹是由 typed relations 派生的用户生命周期。** 现有存储把三者压进 `day_traces.status`，与 `CONTEXT.md` 自己的术语已不一致。

## 10. Design It Twice：三种 interface 方案

### 10.1 方案 A：封闭事务信封，最少 interface／最大 leverage

```swift
public actor TaskLifecycle {
    func transact(_ request: TaskTransaction) async throws -> TaskTransactionReceipt
    func project(_ request: TaskProjectionRequest) async throws -> TaskProjectionEnvelope
}
```

`TaskTransaction` 带 opaque basis、一个或多个封闭 `TaskIntent` 和需要的 after-commit projections。module 内完成 natural day 协调、command ordering、exact clocks、candidate validation、repository CAS 和 sync journal。

优点：interface 极小；批量 Todo diff 原子；invariant leverage 和 locality 最强。缺点：actor 同时持有 repository，容易成为 god object；projection 看似 read 却可能 settlement；普通 UI 要包装 transaction／basis；把纯 domain decision 与 I/O transaction 绑得过紧。

### 10.2 方案 B：versioned feature pack + evidence kernel，灵活优先

```swift
perform<C: LifecycleCommand>(_ command: C, expecting: Revision?) async throws -> Commit<C.Output>
project<P: LifecycleProjection>(_ query: P, at: Revision?) async throws -> Projected<P.Output>
integrate(_ batch: EvidenceBatch) async throws -> IntegrationReceipt
checkpoint() async throws -> LifecycleDocument
```

command、evidence payload 和 projection 以 schema/version 注册 feature；expert SPI 可加入 reducer、projection 和 merge algebra。

优点：新命令、数据包和同步格式扩展弹性大；版本治理清楚。缺点：feature registry、type erasure、schema 和 merge laws 复杂；公开 rule extension 会削弱 canonical invariant locality；generic evidence kernel 很容易越过 ADR 0004，演变成事实源 event log。当前单产品、本地 first scope 不值得承担这套 public extensibility。

### 10.3 方案 C：surface-first workspace，调用者最简单

```swift
public actor TaskLifecycleWorkspace {
    func project(_ scope: WorkspaceScope) async throws -> WorkspaceProjection
    func evidence(_ grant: EvidenceGrant) async throws -> TaskEvidenceBundle
    func prepare(_ intents: [TaskIntent], basedOn: EvidenceRevision?) async throws -> TaskChangePlan
    func apply(_ action: OfferedAction, input: ActionInput?) async throws -> MutationReceipt
}
```

每个 row 带 `Capability<Offer>`；offer 自带 revision、目标 identity 和合法日期范围。UI 只渲染 offer，烛龙把 intents 预检成 plan，AI 只取得授权 evidence。raw persistence enum 降为 package-private。

优点：DatePicker、row、menu、bulk、烛龙、AI 都不再复制 guard；用户问题的 locality 最佳。缺点：typed projection 和 offer 类型较多；actor 仍把 I/O 与 domain 绑在一起；若所有页面 convenience 都堆进 workspace，interface 会逐步变浅。

### 10.4 比较

| 标准 | A 封闭事务 | B 可扩展 kernel | C surface-first |
|---|---|---|---|
| interface 面积 | 最小 | 中等，expert SPI 最大 | 小，但 projection 类型多 |
| module depth | 高 | 高，但 extension seam 易泄漏 | 高 |
| caller leverage | 中 | 中 | 最高 |
| rule locality | 最高 | 核心高、feature 分散风险高 | 高 |
| 原子 mutation | 强 | 强 | 强 |
| 与 ADR 0004 相容 | 相容 | 有 event-sourcing 漂移风险 | 相容 |
| 当前项目合适度 | 高 | 低至中 | 高 |

### 10.5 推荐：A 的封闭 command seam + C 的 typed caller surface，B 只作内部结构

采用纯 in-process module，不让它直接持有 SQLite，也不为了一个实现凭空增加 adapter：

```swift
public struct TaskLifecycle {
    public func inspect(
        _ subject: TaskSubject,
        in state: ValidatedTaskState,
        context: LifecycleContext
    ) -> TaskSituation

    public func apply(
        _ command: TaskCommand,
        to state: ValidatedTaskState,
        context: LifecycleContext
    ) throws -> TaskChange

    public func project(
        _ scope: WorkspaceScope,
        from state: ValidatedTaskState,
        context: LifecycleContext
    ) -> WorkspaceProjection
}
```

```swift
public struct LifecycleContext {
    public let today: LocalDate
    public let mutationMoment: StoreMutationMoment
}

public struct TaskChange {
    public let after: ValidatedTaskState
    public let receipt: TaskChangeReceipt
    public let relationalEvidence: TaskRelationalEvidence
    public let affectedSubjects: Set<TaskSubject>
}
```

关键 contract：

- `inspect` 提供的 action 与相同 state/context 下 `apply` 的 legality 完全一致。
- `ActionOffer` 带 blocker、allowed dates、revision/basis 和所需 input，不让 caller 猜 guard。
- `apply` 是 pure candidate reducer；任何 error 都不改变 input state。
- App Store／烛龙 transaction coordinator 负责 `persist TaskChange → append sync journal → publish after`，沿用 ADR 0022 已有的单一 `StoreMutationMoment`。
- SQLite、DataPackage、Sync 是 persistence／ingress seams，不是 `TaskLifecycle` 的远端依赖。
- feature registry、merge algebra、projection index 都可以是 private implementation；不公开可替换的状态规则。

## 11. 目标 domain model

### 11.1 拆开正交事实

| 目标概念 | 建议表达 | 说明 |
|---|---|---|
| 任务链 current disposition | `TaskChainDisposition` 或从 relation 派生 | 至少区分 active、user-abandoned、internal-retired；完成不等于 abandoned |
| 任务池草稿 | `TaskDraft`／当前 TaskDefinition version | 可编辑的下一次执行内容 |
| 计划草稿 | first-class `PlanDraft` | future 安排；不是用户历史日轨迹 |
| 日轨迹 execution | `DayTraceExecution` | 只表达到达 Day 后的 pending／completed／unfinished execution fact |
| movement relations | `ContinuationLink`、`ChangeLink`、`ReturnToPoolLink` | 不再把 continued／changed／returned 混进 execution enum |
| chain lifecycle relations | `AbandonmentFact`、`ReactivationWitness` | 保留曾废弃／已重新启用的因果序列 |
| record visibility | `presentable` 或 typed `CancellationFact` | hidden fact 无法构造成 PresentableTrace |
| inverse evidence | typed undo／restore witness | 贯穿 snapshot、SQLite、DataPackage、Sync |
| 用户 situation | `TaskSituation` | 由 facts + today + lock 派生，不持久化 raw UI state |

这不是完整 event sourcing：

- TaskChain、TaskDefinition、PlanDraft、DayTrace、Subtask 仍是 canonical relational entities。
- typed links／witness 是业务关系事实，不是要求 replay 的 generic event stream。
- projection 从当前 entities 与 typed relations 直接派生。
- change journal 仍只是同步／诊断辅助，不成为唯一事实源。

### 11.2 Presentation 类型必须排除内部状态

示意：

```swift
public enum PresentableTaskSituation {
    case inPool(PoolDraftSituation)
    case planned(PlanDraftSituation)
    case dueToday(OpenDayTraceSituation)
    case completed(CompletedTraceSituation)
    case unfinished(UnfinishedTraceSituation)
    case continued(ContinuationSituation)
    case changed(ChangeSituation)
    case returnedToPool(ReturnSituation)
    case abandoned(AbandonedChainSituation)
}
```

没有 `.cancelledDraft` case。隐藏事实如果越过 projection seam，应在 Core projection 处 fail-closed，而不是让 UI `preconditionFailure` 或伪装成“已回池”。

### 11.3 建议的 parent／child resolution policy

以下为待产品确认的默认设计，重点是每格必须有答案：

| 父动作 | 开放 child | 已完成 child | 已废弃 child | 隐藏 child |
|---|---|---|---|---|
| complete | 阻止父完成 | 保留 | 保留，不计 actionable denominator | 保留且不可 presentation |
| continue | source 以 continuation relation 关闭，并复制 target pending | 只留 source | 只留 source | 保留 hidden witness |
| change | source 以 transfer/change relation 关闭；复制到新 chain/new lineage | 只留 source | 只留 source | 保留 hidden witness |
| return to pool | 投影为 planned subtask，并以 return relation 关闭 source | 不回流 | 默认不回流 | 保留 hidden witness |
| abandon chain | 由 chain disposition 统一阻断操作；child execution fact不原地擦除 | 保留 | 保留 | 保留 |
| cancel plan draft | 整个 plan aggregate 进入 hidden cancellation；允许已有 child cancellation | 保留 relation facts但全部不可 presentation | 同左 | 合并／保留唯一 witness |

## 12. 核心 invariant 与 command ordering

### 12.1 必须由唯一 invariant module 保证

1. 任何成功 command 的 `after` 都能建立 `ValidatedTaskState`。
2. 任何失败 command 的前后 snapshot bit-for-bit 相同。
3. 同一任务链同一时刻最多一个 current execution frontier。
4. locked Day 的既有 execution facts、priority 和历史 snapshot 不原地覆盖。
5. PlanDraft 只能属于 future；到日 materialize 后不再同时 presentable 为 plan。
6. continuation 只从最新 frontier 发起；target 晚于 source；trace／subtask graph 无 fork、无 cycle。
7. change 建立新任务链及双向可投影关系。
8. terminal parent 不留没有合法 interface 的开放 child。
9. completion capability 与 progress 使用同一 child policy／denominator。
10. hidden cancellation identity 唯一、完整、不可 presentation，inverse 必须有 matching witness。
11. 同一 Day 可见 priority 唯一；锁定后不可改。
12. 所有 clocks finite、严格遵守 persisted mutation frontier。
13. Core、SQLite reload、DataPackage round-trip 和 Sync merge 对同一 state 得到相同 canonical projection。
14. UI／AI／烛龙 action offer 与 Core command legality parity。

### 12.2 固定 ordering

```text
validated basis/state
→ capture one LifecycleContext(today + exact mutation moment)
→ inspect same evaluator
→ apply command to isolated candidate
→ validate aggregate + Day ledger + graph + clocks + visibility
→ construct typed relational evidence and projections
→ repository generation CAS + sync journal transaction
→ publish candidate
```

Sync／DataPackage ingress 不执行 UI command，但必须：

```text
decode exact facts
→ validate identity/schema/digest
→ stage structural group
→ run same TaskLifecycleInvariant
→ atomic commit or deterministic waiting/conflict
```

## 13. 实施路线

### Phase 0：闭合领域决策与 ADR

- 对产品行为边界文档第 15 节的 18 项政策逐项作决定，优先闭合工作日权威、语义冲突、current location 和关系撤回四组架构阻断项。
- 更新 `CONTEXT.md`，特别是计划草稿／日轨迹、锁定事实、废弃／重新启用、延续次数。
- 新 ADR 说明：
  - `TaskLifecycle` 深 module 和 public seam；
  - first-class PlanDraft 与 typed relational facts；
  - supersede ADR 0004 中“核心投影优先 SQL view”的当前不实部分；
  - 延续／回池／变更／废弃的 child resolution；
  - schema、DataPackage、Sync clean-cut 版本策略。

### Phase 1：先建立 characterization 与不变量门禁

- 写完整 table-driven transition matrix。
- 把 F-01 至 F-07 变成会失败的回归测试／探针。
- 加 `chain × trace`、`locked Day × trace`、`parent × child` 负例。
- 加 property：success 后 valid；failure 后全等。
- 扩 simulation 到 undo、redo、delete、abandon、reactivate、priority、review、全部 child action、非单调／non-finite clock。

### Phase 2：建立 `ValidatedTaskState`、`TaskLifecycleInvariant` 和 pure reducer

- 先以现有 snapshot storage shape 为输入，避免立即双写两套事实模型。
- `NoonmarkEngine` 旧方法暂作 façade，全部委派给同一个 reducer。
- production mutation 走 candidate；旧逻辑只允许 shadow read 对账，不允许 dual-write。
- `completionCapability` 扩为统一 `inspect` evaluator。

### Phase 3：统一 projection 与 caller cutover

- 建 typed Day Todo、任务池、未来计划、未完成、已完成、任务轨迹、daily outcome 和 AI evidence projection。
- Mac row／menu／bulk／DatePicker 全部消费 `ActionOffer`。
- 烛龙每日收尾改用 `DailyOutcomeSummary`。
- AI／烛龙只消费授权 `TaskEvidenceBundle`；补 futurePlans scope。
- 删除 caller 对 raw `TraceStatus`／date／lock 的重复 guard。

### Phase 4：clean-cut 持久事实模型

- 当前 schema 为 v7、DataPackage 为 v2；实施时使用下一版本（若常量未变即 schema v8、DataPackage v3）。
- 增加 PlanDraft、typed relationship／witness 的 canonical encoding。
- Sync protocol／namespace 一并 bump，禁止新旧状态语义混流。
- repository 改为 append-only `commit` 与显式 `replaceForDataImport`。
- 删除未使用 SQL views，或建立 Core projection parity tests 后明确只作诊断。
- 依 AGENTS clean cut 重置固定本地数据、iCloud SyncRepository 和 sidecar 生成 key；不迁移／备份旧开发数据，不删除 Provider Keychain credential。

### Phase 5：删除旧浅 interface

- 所有调用点 parity 后删除旧 enum switch、旧 façade 和重复 helper。
- 删除只固定旧实现细节而不保护用户行为的测试。
- 更新产品规格、Mac UI contract、ADR 和本报告状态。

## 14. 验证矩阵

### 14.1 Core

- 全 command × source situation × date role × lock × chain disposition × child state matrix。
- F-01 嵌套取消组合可 valid／round-trip。
- settle、continue、change、return、abandon 的故障注入；失败后 snapshot 全等。
- progress denominator、mode、floor 在完成／延续前后连续。
- taskTrail 永不包含 PlanDraft cancellation／undo hidden fact。
- transition relation sequence 能同时保留 abandon 和 reactivate。

### 14.2 Storage／DataPackage／Sync

- Core → SQLite save → restart → DataPackage export/import → Sync merge 的 permutation 对账。
- raw SQL corruption：locked+pending、abandoned+pending、terminal parent+open child、duplicate priority、broken relation、bad clock 均 fail-closed。
- witness 经 edit、restart、export/import、resync 后仍可证明 inverse。
- concurrent terminal／inverse、CAS rollback、waiting/conflict fixed point、crash recovery。
- ordinary commit 对较小 snapshot fail-closed，不静默复活省略 facts。

### 14.3 真实 Mac App 用户路径

当前没有 `frontend-verify` skill，后续用项目已有真实 `.app` E2E 补齐：

1. today pending → 延续：今天在 picker 中不可选，明天成功；SQLite／重启保留 relation。
2. historical unfinished → future continuation：Future menu 和 bulk 不展示非法回池；未完成池仍提供正确 action。
3. 普通 future PlanDraft → 回池：raw cancellation 保留，但 Day／Calendar／Search／TaskTrail／AI 全不可见。
4. 当天分别 change、return 后启动每日收尾：counts、traces、加密 sidecar、重启恢复全部一致。
5. 第一次、第二次延续显示 1、2 次；未完成池资格符合已确认政策。
6. abandoned child 的显示进度与完成 capability 一致。
7. 从 Pool／Future／Unfinished／Completed detail rail 进入烛龙，授权 scope 和 provider payload 都包含正确、去重的 evidence。
8. console 无 integrity、internal presentation、clock、sync journal 警告。

最后运行：

```text
make check
scripts/test-e2e
scripts/package-dmg release
scripts/test-dmg-install dist/Noonmark.dmg
```

视觉 regression 只有在用户确认真实 App reference 后才运行，不拿归档 HTML 或抬高阈值吸收变化。

## 15. 风险、灰度、监控与回滚

### 15.1 风险评估

| 风险 | 等级 | 控制 |
|---|---|---|
| 新旧事实语义混流导致 sync 不收敛 | P | protocol/namespace clean cut；permutation tests；禁止 dual-write |
| hidden cancellation 泄漏或旧记录复活 | P | typed visibility；witness 全链路；raw/visible count probes |
| locked history 被改写 | P | immutable execution facts；relation-only 后续动作；negative tests |
| command partial mutation | P | pure candidate reducer；failure equality property |
| UI offer 与 apply 漂移 | A/P | 同一 evaluator；stale basis typed error；真实 App E2E |
| projection 统计变化影响烛龙／AI | A/P | canonical DailyOutcomeSummary／EvidenceBundle；payload tests |
| 一次大 schema cutover 扩大回归面 | P | 分阶段代码准备、单次数据 cutover、全链路 gate |

### 15.2 灰度

项目没有 deployed endpoint，不使用服务端流量灰度。采用本地开发分支门禁：

- 先做 shadow read 对账，只比较旧／新 situation 和 projection；不双写两套状态。
- mutation cutover 后只有新 reducer 能写；旧 façade 只委派。
- Storage／DataPackage／Sync 同一提交完成版本 cutover，不能先写新 facts 再让旧 merger 读取。
- 合并前必须通过 Core、Storage、Sync、真实 App E2E、持久化探针和 DMG 安装。

### 15.3 监控／取证信号

- 每次 command 的 offered action、accepted/rejected、blocker 与 basis revision。
- snapshot integrity issue 分类及受影响 aggregate identity。
- raw hidden fact 数与所有 presentable projection 数对账。
- Day Todo counts、DailyOutcome counts、烛龙 evidence counts 对账。
- mutation frontier、entity exact bits、journal changedAt 对账。
- Sync applied／waiting／conflict／terminal、generation CAS、fixed-point rounds。
- repository commit 前后 snapshot digest 和 restart digest。

### 15.4 回滚

- 只能整体 `git revert` lifecycle model、schema、DataPackage、Sync wire 和 caller cutover。
- 回滚后执行 `scripts/reset-dev-data`，按 clean cut 重建本地／iCloud 开发事实。
- 不做 schema downgrade，不恢复物理删除，不保留新旧 status 兼容分支，不靠放宽 validator 让旧数据混入。

## 16. 建议的第一批 tracer-bullet 工作

1. **领域决策与 ADR**：闭合产品行为边界文档第 15 节的 18 项政策，按工作日、同步冲突、位置／撤回、子任务与展示四组记录，不写代码。
2. **State machine characterization**：加入 F-01 至 F-07 和三组跨 aggregate 负例。
3. **ValidatedTaskState + failure atomicity**：让 settle／continue 先走 candidate，证明 interface 形状。
4. **TaskSituation + ActionOffer**：先替换 completion、continue、future return 三条真实用户路径。
5. **Canonical DailyOutcomeSummary**：同时修 DailyReview、Calendar 和烛龙每日收尾集合漂移。
6. **Typed visibility projection**：修 taskTrail hidden leak，并让 AI 不接 raw cancelled state。
7. **PlanDraft clean-cut**：最后进行 schema／DataPackage／Sync 模型升级和完整 caller cutover。

这些工作有依赖关系：1 → 2 → 3；3 后可并行准备 4／5／6；4／5／6 parity 后才能执行 7。不要把 4／5／6 当作零散 UI patch，它们必须消费同一新 evaluator／projection module。

## 17. 主要源码索引

### Core

- `Sources/NoonmarkCore/Models.swift:3-71,400-452,633-1009`
- `Sources/NoonmarkCore/NoonmarkEngine.swift:18-1680,1739-1762,2200-2645`
- `Sources/NoonmarkCore/NoonmarkSnapshot.swift:66-155,225-429,556-588`
- `Sources/NoonmarkCore/TrajectoryTopologyValidator.swift:30-395`
- `Sources/NoonmarkCore/TaskDefinitionValidator.swift`

### Storage／Sync

- `Sources/NoonmarkStorage/SQLiteSchema.swift:40-50,1691-1803,2130-2203,2429-2681`
- `Sources/NoonmarkStorage/SQLiteEngineRepository.swift:399-465,683-765,903-920,1258-1548`
- `Sources/NoonmarkStorage/NoonmarkDataPackage.swift:15-67,200-375`
- `Sources/NoonmarkSync/ValidatedSyncSnapshot.swift:3-14`
- `Sources/NoonmarkSync/CurrentSyncRecordMerger.swift:755-1129`
- `Sources/NoonmarkSync/SyncRecordMerger.swift:539-699,2087-2614`
- `Sources/NoonmarkSync/ChainReactivationEnvelope.swift:157-222`

### Mac App／AI／烛龙

- `App/NoonmarkMacApp/NoonmarkStore+PresentationUndo.swift:260-307`
- `App/NoonmarkMacApp/NoonmarkStore+SelectionProductivity.swift:155-195`
- `App/NoonmarkMacApp/DatePickerSheet.swift:15-35`
- `App/NoonmarkMacApp/TaskDetail.swift:22-27`
- `App/NoonmarkMacApp/UnfinishedPoolPage.swift:104,181`
- `App/NoonmarkMacApp/WorkspaceDetailRails.swift:146,281,445`
- `Sources/NoonmarkAI/AIScope.swift:108`
- `Sources/NoonmarkAI/AIPromptBuilder.swift:65-161`
- `Sources/NoonmarkAI/LocalInsightAnalyzer.swift:40-89`
- `Sources/NoonmarkZhulong/ZhulongDailyClose.swift:90-145,438-485`

### 领域与架构依据

- `CONTEXT.md:7-172,598-750`
- `docs/adr/0004-use-insert-only-relational-model-not-event-sourcing.md`
- `docs/adr/0020-preserve-cancelled-future-drafts-as-hidden-relational-facts.md`
- `docs/adr/0021-preserve-snapshot-undo-identities-as-hidden-cancellation-facts.md`
- `docs/adr/0022-use-one-persisted-mutation-frontier-with-exact-clocks.md`
- `docs/adr/0024-require-a-validated-sync-base-and-atomic-current-components.md`
- `docs/adr/0027-separate-editable-task-drafts-from-day-execution-facts.md`
- `docs/product/phase-1-functional-spec.md`
- `docs/design/mac-ui-design-contract.md`

## 18. 最终建议

把这次工作定义为“任务生命周期 domain model clean cut”，不是“重命名状态 enum”。先确认计划草稿／日轨迹和 locked history 的领域政策，再以 `ValidatedTaskState + TaskLifecycle.inspect/apply/project` 建立唯一深 module；所有 mutation 原子化、所有 caller 消费 typed situation、所有 persistence／sync ingress 复用同一 invariant。等能力与验证对等后，再一次切换 schema、DataPackage 和 Sync 语义并删除旧路径。

最不应做的三件事：

1. 在现有 `TraceStatus` 继续增加 case。
2. 分别修 UI menu、SQL view、AI filter 和 Sync merger 的局部条件。
3. 先 cutover 新状态，再把 child policy、witness、真实 App E2E 留作“已知 gap”。

晷迹当前已有 stable identity、exact clock、validated sync base、candidate undo 和 clean-cut 基础。把这些能力收进一个真正深的生命周期 module，才是这次重构能降低而不是转移复杂度的关键。

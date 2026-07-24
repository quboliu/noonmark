# 任务生命周期行为边界审查与产品政策

- 日期：2026-07-22
- 状态：持续确认中
- 审查性质：产品行为与领域语义，不是技术架构设计
- 源码基线：当前 `main` 工作树
- 已确认决策：当天主动把任务安排到未来称为**延期**；只有日结束后从真实**未完成**继续推进才称为**延续**
- 已确认决策：延期在来源日结束前可通过稳定情境动作撤回；Day Todo 的置顶待办、普通待办和结果任务形成不可被查看排序打破的展示层级
- 待确认范围：本文其余“推荐政策”需产品确认后，才能同步进入 `CONTEXT.md`、功能规格和实现

证据标记：`[S]` 为静态源码证据，`[R-Core]` 为仅绕过 App 保存边界的 Core 探针，`[R]` 为引擎／SQLite／同步合并器运行证据，`[E2E]` 为真实 `.app` 用户路径证据。未标记的问题同样以源码为底稿，但结论强度不高于结构推理。

## 1. 本文要回答什么

本文逐个回答任务在具体情境中的产品行为：

- 它此刻属于任务池、未来计划、当前 Day Todo，还是已经成为历史结果？
- 用户执行某个动作后，来源任务还显示吗，显示什么？
- 新目标出现在哪里，与来源是什么关系？
- 之后还能完成、延期、延续、回池、变更、废弃或删除吗？
- 动作能否撤回，撤回截止点是什么？
- 日结束后哪些事实锁定，哪些后来决定只能作为附加关系？
- 子任务、进度、任务轨迹、未完成池、统计、复盘、烛龙和 AI 应如何理解？

本文不讨论 Swift interface、SQLite schema 或 Sync record 结构。技术实现建议见 `docs/engineering/task-lifecycle-state-machine-review.md`；若二者冲突，应先以本文确认后的产品政策为准，再调整技术方案。

### 1.1 2026-07-23 新确认的 Day Todo 行为

- 当天 **已延期** 任务在日结束前提供“撤回延期”；撤回后来源恢复待完成，未来目标退出用户投影，重启后仍能判断动作是否合法。
- Day Todo 的展示硬顺序为：置顶待办队列、普通待办、完成／延期／废弃等结果任务。
- 置顶只属于待办；先置顶者在前，后置顶者依次排队。任务形成结果时自动退出置顶。
- 分组、不分组、按时间、按首字母和升降序只作用于各自层级，不能把普通或结果任务排到置顶队列之前。
- Day Todo 回池后停留在原页面和日期；行从 Day Todo 消失，不自动跳到任务池。
- Day Todo 不再提供行级上移、下移或拖拽调序；未来计划聚合页的排期调序不属于本次决定。
- 延期或延续形成的未来目标可以回池：目标计划退出，最新草稿进入任务池，来源日继续保持已延期或未完成；这不会被静默解释成撤回延期。
- 有未完成历史的任务回池后，未完成池继续展示历史，并明确提供“当前在任务池”的跳转与废弃动作，不能出现空动作 ghost。

## 2. 评判边界是否合理的十条原则

### 2.1 日期事实必须真实

某日显示的结果，只能描述该日实际发生的承诺与结果。今天作出的废弃、延续或重新启用决定，不能反向把上周的“未完成”覆盖成另一个结果，也不能提前在下周制造“已废弃”。

### 2.2 历史结果与后来处置分开

“周一未完成”是周一结果；“周三延续到周四”是后来处置。界面可以把两者一起展示，但不能用后者替换前者。

### 2.3 每条未终结任务链必须有唯一当前位置

当前位置只能是：

- 任务池；
- 某个未来计划；
- 今日待执行任务；
- 暂无执行位置，但明确等待用户从历史未完成作出处置。

已完成、已由新任务接替或已废弃属于明确终结／暂停处置。不能出现“任务仍在未完成池，但没有动作，也不在任务池或未来计划”的 ghost。

聚合页可以重叠展示同一任务链。例如任务已经回池，但未完成池仍可展示它的历史未完成；此时必须标明“当前在任务池”并提供跳转，不能假装它没有当前位置。

### 2.4 计划草稿不是未来日结果

未来安排在日期到达前只是计划草稿。它可以编辑、改期、回池或取消，但不能提前形成未来日的完成、未完成、已废弃或其他执行结果。

### 2.5 撤回是纠错，反向动作是新的决定

- **撤回／Cmd+Z**：纠正尚未固化、且没有后续依赖的误操作；不应形成用户可见任务轨迹。
- **回池、废弃、重新启用、再次变更**：新的业务决定；应保留用户可理解的任务轨迹。

不能只靠当前进程里的全局 undo stack 宣称某项产品能力“可撤回”。稳定撤回必须有情境入口、清楚截止点，并能在重启后继续判断是否合法。

### 2.6 来源与目标必须相互可解释

任何延期、延续或变更都必须：

- 从来源能跳到目标；
- 从目标能看见来源；
- 目标被取消、回池、完成、变更或废弃后，来源文案仍然真实。

### 2.7 父任务动作必须同时解释子任务

父任务延期、延续、回池、变更或废弃时，每个子任务必须明确属于以下之一：

- 留在来源历史；
- 带到目标继续处理；
- 转为任务池计划子任务；
- 由新任务接替；
- 随父任务停止；
- 作为内部纠错事实隐藏。

不允许父任务已终结，子任务仍显示成没有入口可处理的“待完成”。

### 2.8 所有投影必须说同一件事

Day Todo、未来计划、任务池、未完成池、已完成池、日历、搜索、任务轨迹、每日复盘、烛龙和 AI 可以展示不同切面，但不能对同一任务给出不同状态、动作或统计口径。

### 2.9 日结束必须有唯一权威边界

同一批同步数据不能在设备 A 已经进入次日、设备 B 仍处于当日时得到两个不同的任务结果。任务所属工作日必须由稳定、可同步的工作时区决定；设备当前显示时区可以变化，但不能单方面提前锁定所有设备的 Day。

### 2.10 动作语义以真正接受时的事实为准

打开菜单、sheet 或编辑器不等于动作已经发生。真正提交时必须重新核对工作日、来源状态、版本和下游关系；上下文已经变化时，旧确认界面必须失效并解释原因，不能把“延期”静默改成“延续”，也不能对另一个 active target 执行原动作。

## 3. 源码当前实际行为

### 3.1 当前时间轴

| 阶段 | 当前显示 | 当前动作 | 当前撤回 |
|---|---|---|---|
| 任务池 | 只在任务池 | 编辑、删除、排期到今天或未来 | 创建／排期可能进入内存 undo |
| 普通未来计划 | 未来计划及对应未来 Day Todo | 编辑、调整优先级、未来日期之间改期、回池 | 改期、回池可能进入内存 undo |
| 未来日期到达 | 同一条 pending 记录从未来计划消失，成为当天任务 | 获得完成、当前所谓延续、变更、回池、废弃 | 无独立转换提示 |
| 当天待完成 | 当天 Day Todo | 完成、主动“延续”、变更、回池、废弃；部分任务可删除 | 各动作政策不同 |
| 当天主动“延续” | 来源变 continued，仍显示当天；目标成为未来 pending | 来源没有稳定情境动作；目标按普通未来计划显示 | 仅在当前 undo 链仍完整时可能撤回 |
| 日结束 | pending 父任务及其 pending 子任务变 unfinished，Day 锁定 | 历史未完成可延续或废弃 | undo stack 清空 |
| 历史未完成延续 | 来源 unfinished 被覆盖为 continued；目标成为今天或未来 pending | 活跃目标完成前不能再次延续 | 不提供普通撤回 |
| 延续目标完成 | 进入已完成池，整条链从未完成池移除 | 查看、复制为新任务 | 历史完成不可撤回 |
| 延续目标再次未完成 | 目标在日结束后变成新的 unfinished | 从最新执行前沿再次延续 | 不可撤回结算 |
| 废弃 | 当前 active trace 或指定 unfinished 原地变 abandoned | 未完成池提供重新启用 | 当前可能 undo；历史只能重新启用 |
| 重新启用 | 同一 abandoned trace 原地改回 pending 或 unfinished | 恢复执行／再次延续 | 曾废弃结果从任务轨迹消失 |

主要证据：

- `Sources/NoonmarkCore/Models.swift:8-39`
- `Sources/NoonmarkCore/NoonmarkEngine.swift:602-737,797-1116,1558-1624`
- `App/NoonmarkMacApp/NoonmarkStore+PresentationUndo.swift:260-307`
- `App/NoonmarkMacApp/NoonmarkStore+TaskMutations.swift:369-568`

### 3.2 当前显示集合并不等于真实结果集合

Day Todo 只显示 `pending/completed/unfinished/continued/abandoned`，隐藏 `changed/returnedToPool/cancelledDraft`。Calendar、DailyReviewStats、搜索和部分 AI scope 又复用 Day Todo 可见集合，因此当前日发生变更或回池后，来源任务不只从工作台消失，也从统计和复盘证据消失。

相关位置：

- `Models.swift:18-39`
- `NoonmarkEngine.swift:602-607,1446-1459,1612-1624`
- `Sources/NoonmarkMacRuntime/WorkspaceSearchIndex.swift:56-90`

### 3.3 本轮运行证据

| 证据 | 实际结果 | 证明边界 |
|---|---|---|
| `NOONMARK_E2E_NATURAL_DAY_ONLY=1 scripts/test-e2e` | 真实 `.app` E2E 通过；SQLite probe 为 `1 0 1` | 唤醒后结算未完成、时区回退不重开锁日、重启结果一致 |
| 定向运行 Storage／Sync 自动测试 14 例 | 全部通过 | 本地 generation CAS、锁日 stale undo、同步取消／重做、批次 canonicalization 与 rollover 幂等按现有 contract 工作 |
| 对 `CurrentSyncRecordMerger` 的一次性双端／第三端探针 | `延续 × 完成` 可静默丢一方或回退为原 pending；双日期并发延续可令两个目标都消失；fresh 第三端可得到不同于两个原设备的结果 | record-level LWW 不能作为互斥生命周期决定的最终语义 |

证据限制：本轮没有把本地／内存端点结果伪装成 live iCloud 或双物理设备验证；后者仍是实施完成前的发布门禁。

## 4. 已确认的产品级问题

### P-01：当天延期与历史延续共用一个动作和状态

当前 `continueTrace` 同时接受：

- 当天尚未结束的 pending；
- 已经日结束的 unfinished。

两者都会把来源改为 continued、增加 continuation sequence，并复制开放子任务。结果是主动调整计划和真实未完成被统计成同一件事。

证据：`NoonmarkEngine.swift:942-999,2528-2555`。

### P-02：连续两次主动延期会凭空产生未完成历史 `[R]`

第一次当天主动延续时 `settledAt == nil`，暂时不进入未完成池；第二次主动延续后，`unfinishedPool()` 因同链 `continuedCount > 1`，把两条从未经过日结束的记录都当成未完成明细。

证据：`NoonmarkEngine.swift:698-710`、`NoonmarkEngineTests.swift:390-400`。

本轮真实 Core 探针确认，两次任务都没有经历日结束，未完成池却出现：

```text
2026-07-22:continued:settled=false
2026-07-23:continued:settled=false
```

这说明“延期／延续分开”不是文案调整，而是未完成池正确性的前提。

### P-03：历史未完成会被后来的延续抹掉

历史 trace 从 unfinished 原地变 continued，任务轨迹又只按当前 status 生成一个 outcome。真实过程“周一未完成，周三决定延续”最终只剩“周一已延续”；周一复盘统计也会反向变化。

开放子任务同样从 unfinished 原地改为 continued。

证据：`NoonmarkEngine.swift:987-993,1739-1762,2528-2555`。

### P-04：当前“撤回延期”不是稳定能力

Store 会为当天 continuation 保存 snapshot undo，但 undoStack 只存在内存：

- 重启后不存在；
- 跨自然日清空；
- Sync、烛龙写入或任何 `.invalidate` mutation 都可能清空。

证据：

- `NoonmarkStore.swift:149-153,651-652`
- `NoonmarkStore+TaskMutations.swift:369-385`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:74-102,816-855`

因此当前只能说“当前 session 的 undo 链仍完整时可能撤销”，不能说“日结束前始终可撤回”。

### P-05：延期日期选择器默认选择必然非法的今天

`.continueTrace` picker 默认 today，但 Core 要求 target 严格晚于 source。当来源就是今天时，默认确认必然失败。

证据：`DatePickerSheet.swift:15-25`、`NoonmarkEngine.swift:951-958`。

### P-06：第一次延续显示为 0 次

首个目标已经是 `continuationSeq == 1`，未完成页却显示 `max(sequence) - 1`；来源明细还可能显示“第 0 次延续”。

证据：

- `UnfinishedPoolPage.swift:100-109,254-281`
- `UnfinishedDetail.swift:100-105`
- `NoonmarkEngineTests.swift:371-380`

### P-07：普通未来计划不能直接提前到今天

未来改期要求来源和目标都严格晚于 today。用户要把明天的计划提前到今天，只能先回池再排期；延续目标因为不能回池，甚至没有这条路。

证据：`NoonmarkEngine.swift:923-939`、`NoonmarkStore.swift:498-523`。

计划草稿在日期到达前应能自由改到今天或其他未来日期，旧未来日期不形成 Day 结果。

### P-08：未来计划没有来源类型，动作因此错误

普通未来计划、当天延期目标和历史延续目标，在 `futurePlans()` 中都是 future pending。未来行不显示来源，菜单一律提供改期、回池；Core 却拒绝具有 continuation source 的未来目标回池，bulk 也会错误提供该动作。

证据：

- `NoonmarkEngine.swift:683-696,825-846`
- `FuturePlansPage.swift:72-139`
- `NoonmarkStore+PresentationUndo.swift:295-297`
- `NoonmarkStore+SelectionProductivity.swift:173-182,232-245`

### P-09：延续目标回池后进入无位置、无动作夹层 `[R]`

本轮真实 Core 探针复现：

```text
历史 unfinished
→ 延续到今天
→ 今天将目标回池
```

结果：

```text
pool=false
unfinished=true
actions=[]
source=continued
target=returnedToPool
```

原因是任务池要求同链所有 trace 都是 returned/cancelled；旧 continued history 阻止进入池。未完成池又找不到 unfinished source 或 active target，action plan 为空。

证据：`NoonmarkEngine.swift:698-737,825-863,2335-2344`、`Models.swift:981-1001`。

### P-10：延续目标执行变更后留下未完成池 ghost

序列：

```text
unfinished → continued → current pending → changed
```

旧链仍因 continued history 进入未完成池，但 activeTrace 为空、又没有 unfinished 可供 actionPlan 使用，因此永久显示为无动作项目。完成目标则能正常把整链从未完成池移除。

证据：`NoonmarkEngine.swift:698-737,1002-1057`、`Models.swift:981-1001`。

### P-11：变更目标被当作普通新任务删除，但真实提交必然失败 `[R-Core]`

本轮真实 Core 探针确认，动作 guard 错误地允许这条序列：

```text
当前任务变更为新任务
→ 新任务菜单允许“删除新任务”
→ 删除新任务
```

Core mutation 后的内存结果是：

```text
canDelete=true
visible=[]
old=changed
target=cancelledDraft
targetChain=abandoned
oldTrail=[createdInPool, scheduled, changed]
```

但是该结果违反变更关系 invariant：`changedToTraceID` 不允许指向 `cancelledDraft`。真实 App 会在持久化验证阶段拒绝整个 candidate，`commitEngineMutation` 不发布内存结果，因此用户实际得到的是一个菜单可见但必然失败的删除动作，而不是成功删除。这里同时暴露两层问题：

- 产品动作政策把变更目标误判成无来源 Quick Add；
- Core mutation 没有维护自己的 snapshot invariant，只能依赖外围持久化兜底。

证据：

- `NoonmarkEngine.swift:869-920,1002-1057,2327-2333`
- `Sources/NoonmarkCore/TrajectoryTopologyValidator.swift:249-286`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:752-812`

### P-12：变更与当天回池没有稳定撤回，且会清空整个 undo 历史

- 当天回池使用 `.invalidate`，未来回池才用 snapshot undo。
- 变更同样使用 `.invalidate`。

这不只让当前动作不可撤回，还会删除用户之前仍合法的 undo entries。

证据：`NoonmarkStore+TaskMutations.swift:395-413,545-568`。

### P-13：变更目标失去来源当日优先级

新 trace 使用 `nextPriority(on: today)`，即使来源原本排第一，变更后目标也会跳到列表末尾。变更表示替换承诺，不应悄悄改变执行优先级。

证据：`NoonmarkEngine.swift:1019-1035`。

### P-14：废弃和重新启用会改写锁定历史

历史 unfinished 可原地改成 abandoned，重新启用再原地改回 unfinished。任务轨迹、历史 Day Todo 和复盘统计会随今天的决定变化，曾废弃事件也会消失。

证据：`NoonmarkEngine.swift:1060-1116,1739-1762`。

这与 UI 的“历史事实只读”直接冲突：`AppCopy+TaskDetail.swift:103-107`。

### P-15：未来计划可提前产生未来日“已废弃”结果 `[R]`

Core 的 abandon 没有日期限制。未来 pending 被废弃后，未来日期可出现 abandoned 结果；如果日期过去后重新启用，同一 future trace 会被改成 unfinished。

本轮探针确认：

```text
未来 7 月 23 日计划
→ 7 月 22 日废弃
→ 7 月 24 日重新启用
→ 7 月 23 日被改成 unfinished
```

一个在到期前已经废弃的计划，因后来的重新启用而被追溯制造成“7 月 23 日未完成”。

证据：`NoonmarkEngine.swift:1060-1116`。

### P-16：从历史行执行废弃，可能静默废弃另一个 active target

`abandonChain(from:)` 优先选择同链 active trace，而不是调用方传入的 trace。若用户从旧未完成明细点击废弃，实际被废弃的可能是未来计划或今天活跃任务。现有 UI 没有充分披露目标。

证据：`NoonmarkEngine.swift:1060-1068`、`NoonmarkEngineTests.swift:1308-1335`。

### P-17：父动作会留下不可操作的开放子任务

- 回池只把 open children 投影成 planned subtasks，来源 child 仍保持 pending/unfinished。
- 变更复制 open children 到新 chain，来源 child 仍保持 pending/unfinished。
- 废弃父任务完全不处理 children。

父任务结果已终结或隐藏后，这些子任务没有正常用户入口。

证据：`NoonmarkEngine.swift:1002-1079,2557-2622`。

### P-18：子任务“删除”正在承担“废弃工作”的语义

领域文档说，不再需要的当前子任务应明确废弃，不能无痕删除后完成父任务；实际 UI 没有正常的子任务废弃动作，却允许在 pending parent 下删除任意 presentable child，包括 completed／abandoned child。删除后 hidden child 不再阻止父完成。

证据：

- `CONTEXT.md:681-689`
- `NoonmarkStore+TaskMutations.swift:206-360`
- `NoonmarkEngine.swift:1214-1304`

### P-19：进度与完成资格使用不同的 abandoned child 口径

完成资格排除 abandoned child，但加权进度仍把它的 difficulty 放进 totalWeight，导致父任务可合法完成时显示低于 100%；完成后 mode 又从 weighted 强制变 manual 100%。

证据：`Models.swift:838-879`、`NoonmarkEngine.swift:2206-2227,2363-2415`。

### P-20：UI 与 Core 对手动进度是否可编辑判断不同

UI 只检查当前 trace 没有可见子任务；Core 检查整条任务链历史上从未有过 presentable child。延续目标没有复制到 open child、但历史曾有 completed child 时，UI 会显示可编辑滑杆，保存却失败。

证据：`TaskDetail.swift:22-27`、`NoonmarkEngine.swift:1387-1409,2350-2360`。

### P-21：100% 进度不等于已完成

手动进度 100% 或全部子任务完成，只让父任务具备完成资格，不会自动完成。用户若忘记再确认父任务，午夜后仍会得到“未完成”。

证据：`NoonmarkEngine.swift:1387-1444`、`Models.swift:860-862`。

这项行为可以保留，但必须明确提示“进度已完成，请确认父任务完成”。

### P-22：未来计划详情缺少实际可管理的子任务与进度

未来 Day Todo 的通用详情允许管理子任务；Future Plan detail 只显示标题、描述、分类、任务轨迹和附言，不显示子任务／进度。用户必须切换到目标未来日期才能编辑同一计划的子任务。

证据：`FuturePlanDetail.swift:17-80`、`TaskDetail.swift:18-90`。

### P-23：复制为新任务丢失子任务结构

已完成池的“复制为新任务”复制标题、描述、附言和分类，但不复制子任务标题／难度。对具有 checklist 的重复工作，“复制”结果是不完整的。

证据：`NoonmarkEngine.swift:1120-1146`。

### P-24：统计、搜索、任务轨迹与烛龙使用不同事实集合

- `DailyReviewStats.changed/returnedToPool` 因先过滤 visible rows 而永远为 0。
- Calendar 试图从已经排除 changed 来源的集合生成 change summary。
- hidden cancelledDraft 在 taskTrail 被伪装成 returnedToPool。
- 烛龙每日收尾的 counts 取 visible stats，traces 取更宽的 formsDayHistory，变更／回池日会无法通过自身 persistence validation。
- AI 没有完整 future plan scope，raw status filtering 分散。

证据：

- `NoonmarkEngine.swift:621-680,1446-1459,1612-1624,1739-1762`
- `CalendarPage.swift:353-374`
- `ZhulongDailyClose.swift:100-145,438-485`
- `Sources/NoonmarkAI/AIScope.swift:4-150`

### P-25：已完成导航数字混合父任务与子任务

Completed page badge 把 completed parent count 与 completed subtask record count 相加。“已完成 8”可能表示 2 个任务 + 6 个子任务，用户无法理解它是任务数还是完成事项数。

证据：`NoonmarkStore+PresentationUndo.swift:220-235`。

### P-26：普通编辑与“变更为新任务”没有产品分界

today pending 既可直接编辑标题／描述，也可执行“变更”，但目前只在实现层区分：前者保留同一任务链，后者新开任务链。界面没有说明用户应在什么情况下选择哪一个，因此同样的范围改变可能留下完全不同的历史。

证据：

- `TaskDetail.swift:22-49`
- `NoonmarkEngine.swift:238-342,1002-1057,1306-1385`

推荐定义：

- **编辑**用于纠错、补充或细化，不改变任务的成功标准与连续身份。
- **变更**用于成功标准、交付物或承诺边界已经变成另一件事；它开启新任务链并保留接替关系。

系统无法自动判断语义，必须用动作说明、示例与确认文案让用户明确选择。

### P-27：任务池排到今天与当天 Quick Add 无法区分

Quick Add 和“从任务池排到今天”最终都调用 create + schedule；`isNewDayTrace` 只检查同链有没有其他可见历史。因此认真整理过的任务池草稿排到今天后，也会与“刚刚误加的当天任务”一样获得删除动作，同时还获得回池动作。

证据：

- `NoonmarkStore+TaskMutations.swift:31-66,137-155`
- `NoonmarkEngine.swift:869-920,2327-2333`

推荐只对真正无来源的当天 Quick Add 显示“删除误建”；从任务池排入今天应使用回池。

### P-28：有历史任务从任务池移除后失去所有普通入口 `[R]`

序列：

```text
today pending → 回池 → 从任务池删除
```

本轮真实 Core 探针得到：

```text
beforePool=true
outcome=removedKeepingHistory
afterPool=false
day=false
unfinished=false
completed=false
chain=abandoned
```

任务被称为“保留历史”，但返回的 source 是 returnedToPool，Day Todo 不显示；chain abandoned 后任务池不显示；unfinished／completed pool 也不显示。`reactivateAbandonedChain` 又要求存在 abandoned trace，无法从 returned source 恢复。除非调用方仍持有 identity 并直接打开 task trail，否则用户很难再找到它。

证据：`NoonmarkEngine.swift:509-536,602-619,698-756,1083-1116,2335-2344`。

推荐：有历史的任务池项目不得使用“删除”。终止它必须走链级废弃，并进入明确的已废弃入口；重新启用后回到任务池或让用户选日期。

### P-29：同步项目没有唯一的工作日权威 `[E2E + R]`

自然日按每台设备的 `TimeZone.autoupdatingCurrent` 计算，而同步后的 Day 只保存裸 `LocalDate` 和 `lockedAt`。任一设备已经锁日时，Day merge 保留最早 lock；pending 与 historical trace 合并时又优先 historical。

因此新加坡设备已经进入 7 月 6 日时，可以把纽约设备仍在执行的 7 月 5 日提前锁定。本轮真实 merge 探针进一步得到：同一个 pending base，锁定分支与完成分支的时间先后不同，会分别收敛为 `locked + completed` 或 `locked + unfinished`，都不产生 conflict；从两个既有本地分支互相下载时又可能各自保护本地 terminal、产生冲突而永久分歧。

证据：

- `App/NoonmarkMacApp/SystemNaturalDayEnvironment.swift:11-16`
- `Sources/NoonmarkCore/Models.swift:400-419`
- `Sources/NoonmarkSync/CurrentSyncRecordMerger.swift:715-752,968-995`
- `App/NoonmarkMacApp/NaturalDayRolloverE2EAutomation.swift:177-195`

推荐建立同步的**工作时区**作为任务工作日的唯一权威。设备时区只影响显示；若坚持每台设备各用本地日，Day identity 就不能继续只是裸日期，更不能让一端的 lock 成为全局结果。

### P-30：时区回退会同时产生“今天已锁定”和“未来已完成” `[E2E]`

纽约进入 7 月 6 日并锁定 7 月 5 日后，同一 instant 切到洛杉矶会让 store 的 `today` 回到 7 月 5 日，但历史不会解锁。真实 `.app` 自然日 E2E 已验证这条路径。

页面随后同时发生：

- 日期 badge 显示“今天”；
- 因 Day 已锁定又显示历史只读 notice，Quick Add 隐藏；
- date picker 仍把这个“今天”标为可选，提交后才由 Core 拒绝；
- 若 7 月 6 日已有 completed／abandoned 结果，它们在新 `today` 视角下又成为“未来结果”。

证据：

- `NoonmarkStore+PresentationUndo.swift:17-23`
- `App/NoonmarkMacApp/DayTodoPage.swift:33-47,79-88`
- `App/NoonmarkMacApp/DatePickerSheet.swift:270-276`
- `NoonmarkEngine.swift:2206-2227`
- `NaturalDayRolloverE2EAutomation.swift:177-195`

推荐区分设备的**观测本地日期**和单调不回退的**有效工作日**；有效工作日不得指向已锁定 Day。时区向后时保持原工作日并给轻量说明，所有 picker 同时检查日期与 lock。

### P-31：正常休眠与异常日期前跳会被同样批量结算

午夜、时区改变、系统时钟改变、唤醒和 app 激活都进入同一 reconciliation。只要 observed today 向前，所有 `date < today` 的 pending 都会立即变 unfinished 并永久锁定；系统日期误跳到三天后与 app 正常关闭三天没有区别。

后果是尚未真实经历的未来计划可能被批量记录为“未完成”，时钟调回也无法撤回，烛龙随后把它们解释成 missed。

证据：

- `Sources/NoonmarkDayContext/NaturalDayContext.swift:32-42,177-191`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:74-135`
- `NoonmarkEngine.swift:1558-1608`
- `Tests/NoonmarkCoreTests/NoonmarkEngineTests.swift:3022-3071`

推荐：在 canonical 工作时区下正常跨过的已确认排期，即使 app 未运行也应算未完成；一次异常跨越多日或系统日期大幅前跳则进入“日期异常待确认”，不得直接制造不可逆结果。

### P-32：日结束生效时刻与设备处理时刻混为一个 timestamp `[E2E]`

app 唤醒后才执行 settlement，并把同一 mutation instant 写进 `settledAt` 与 `lockedAt`。现有 E2E 在纽约午夜 `04:00Z` 后于 `04:30Z` 唤醒，明确断言两者均为 `04:30Z`。睡眠多天后，各日甚至可能拥有同一个锁定时间。

证据：

- `Sources/NoonmarkMacRuntime/DayRolloverCoordinator.swift:14-22`
- `NoonmarkEngine.swift:1587-1608`
- `NaturalDayRolloverE2EAutomation.swift:110-163`

推荐把**日关闭生效时刻**与**记录时刻**分开：前者是工作时区中该日的真实边界，后者是设备发现并持久化事实的时刻。任务轨迹、统计和 AI 不得把 recorded time 误称为用户在该时刻“未完成”。

### P-33：合成 mutation clock 被当成真实发生时间显示

设备时钟回退或同步进一个远未来 timestamp 后，`nextMutationDate` 会从全库最大时间执行 `nextUp`，保证排序单调。任务轨迹又直接把 `createdAt/contentUpdatedAt/settledAt` 当作 `occurredAt`，并显示精确日期时间。因此用于一致性排序的合成逻辑时钟可能被用户看成真实操作时间。

证据：

- `Sources/NoonmarkCore/MutationClock.swift:3-35`
- `NoonmarkEngine.swift:621-680,1739-1761`
- `App/NoonmarkMacApp/TaskDetail.swift:727-731,853-859`

推荐分开 user-reported wall time、canonical effective date 与 logical order。逻辑时钟只能排序，不得冒充精确发生时间；检测到明显 clock skew 时应标注，而不是制造“未来执行”的轨迹。

### P-34：跨午夜的在途动作会失效，甚至静默改变语义

`continue` picker 只持有 trace ID；自然日 reconciliation 会清 selection，却不会关闭 `showingPicker`。用户 23:59 为 today pending 打开 sheet，午夜后来源先变 unfinished，随后同一 sheet 可以被 Core 合法解释为历史延续。已确认的新模型下，这等于把“延期”静默换成另一项业务决定。

其他动作在 23:59:59 显示为可用、00:00 后真正提交时，会先结算再得到泛化 mutation failure；原子性正确，但用户不知道任务为何突然变成未完成。

证据：

- `App/NoonmarkMacApp/NoonmarkStore.swift:461-477,585`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:87-115,752-795`
- `NoonmarkEngine.swift:942-998`
- `NoonmarkStore+TaskMutations.swift:165-190`

推荐所有决策界面捕获 action kind、source ID、source version、source date 与有效工作日。任一改变即使界面失效；边界以提交接受时刻为准，并返回“来源日已关闭”的专门解释，不回填昨日结果。

### P-35：复盘编辑跨午夜可能写到新一天

`updateReview` 在 reconciliation 前读取旧日 review，但 mutation closure 内再次读取可能已经跟随 today 改变的 `selectedDate`。旧日编辑器的最后一次输入因此可能写到新日，并把旧日其他 review 字段一起带过去。Core 的 review update 又没有日期／lock guard。

证据：

- `App/NoonmarkMacApp/NoonmarkStore+ClassificationReview.swift:114-124`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:87-115`
- `NoonmarkEngine.swift:1627-1638`

推荐编辑开始时固定 Day identity，提交只写该 Day。锁定的是任务结果；复盘属于可以后来补写的 addendum，两种可变性不得继续共用“Day 已锁定”这一句模糊规则。

### P-36：多级变更合法，但“前往接替任务”会停在隐藏中间节点

`A → B → C` 在 Core 与 validator 中合法。A 的 direct target 仍是 B，但 B 已成为隐藏的 changed source；UI 从 A 调用 `selectTrace(B)` 时，B 不在 Day Todo selection set，结果只会清空选择，无法抵达当前的 C。

证据：

- `NoonmarkEngine.swift:1002-1057`
- `Sources/NoonmarkCore/TrajectoryTopologyValidator.swift:173-187,249-285,398-439`
- `NoonmarkStore+SelectionProductivity.swift:32-36,53-80,315-337`

推荐允许线性 A→B→C，但默认直接解析并跳到 terminal/current target C，同时可展开完整接替链。存在 B→C 时，A→B 已是非叶关系，不能单独撤回。

### P-37：变更图只有 trace 约束，没有 chain 级单前驱／单后继

validator 只禁止同一个 target trace 被复用，没有禁止：

- 同一 source chain 的不同 trace 分别变更成两个 target chains；
- 两个 source chains 分别指向同一 target chain 的不同 traces。

`taskTrail` 对一个 target chain 又用无序 `.first` 推断它“由谁变更而来”。导入或同步因此可以形成产品从未定义的 fork／merge，且显示来源不稳定。

证据：

- `TrajectoryTopologyValidator.swift:249-286`
- `NoonmarkEngine.swift:621-631`

推荐变更关系提升为带 operation identity、双向端点的一级事实；replacement chain 入度、出度都最多为 1。并发产生两个 replacement 时进入显式冲突，不得静默留下任意一个普通任务。

### P-38：变更目标回池后仍可被删除，留下可持久化的不可达关系

直接删除 changed target 会被 snapshot validation 拒绝；但下面这条更隐蔽的路径可以合法落盘：

```text
A 变更为 B → B 当天回池 → 从任务池移除 B
```

B 回池后符合 task-pool predicate；池删除不检查来自 A 的 incoming change relation。最终 A 仍指向 B 的 returned trace，但 B chain 已 abandoned，双方失去普通入口。

证据：

- `NoonmarkEngine.swift:509-535,2335-2344`
- `TrajectoryTopologyValidator.swift:274-281`

推荐 incoming relation 永久属于 target provenance。有 change／continuation 来源的池任务不得普通删除，只能撤回来源关系或执行可发现的废弃；来源跳转必须解析 target 的当前处置和位置。

### P-39：延续带来的子任务可以普通删除，造成可见 lineage 断裂

延续复制的 child 带 `carriedFromSubtaskID`，但当前 UI/Core 仍允许在 pending parent 下执行普通 delete。目标 child 变成 hidden `cancelledDraft`；validator 特意允许这个隐藏 target，所以 source 仍显示已延续，当前目标却没有可见 child，下一次延续也不会再复制它。

证据：

- `NoonmarkEngine.swift:1281-1303,2528-2553`
- `NoonmarkStore+TaskMutations.swift:249-267,345-361`
- `TrajectoryTopologyValidator.swift:355-374`

推荐有 lineage 来源的 child 不是新草稿，不得普通删除。移出范围必须形成可见的 stopped／abandoned 结果并保留 lineage；hidden cancellation 只适用于没有来源和下游依赖的真正误建 child。

### P-40：回池再排期会切断 continuation 的精确因果边

回池把 open child materialize 成 planned child；再次排期则生成 `continuationSeq = 0`、没有 `carriedFromTraceID` 的新 root trace。child 虽可能复用 lineage，也没有精确 continuation link。

若允许有未完成历史的任务回池，历史延续会停在 returned trace，新当前位置无法说明“从哪一个未完成前沿而来”，延续次数还可能回到 0。

证据：`NoonmarkEngine.swift:463-473,2581-2603,2624-2633`。

推荐 return → pool → schedule 建立 placement／transfer relation；它不增加、也不重置延续次数。trace placement 可以变化，但 chain 的 unresolved origin 与 child lineage 必须连续。

### P-41：chain disposition 与 trace closure 没有完整拓扑约束

trajectory validator 不接收 chains，只保证每条 chain 的 pending trace 不超过 1。snapshot 因而可能接受 abandoned chain + pending trace、同一 lifecycle generation 的多个断开 terminal branches，甚至两台设备从同一 pool chain 分别排期并完成后形成“两次完成”。SQLite 也只为 pending 建唯一索引；completed pool 会逐条展示所有 completed trace。

证据：

- `TrajectoryTopologyValidator.swift:89-155`
- `Sources/NoonmarkStorage/SQLiteSchema.swift:1797-1800`
- `NoonmarkEngine.swift:739-755`
- `Tests/NoonmarkSimulationTests/NoonmarkDeterministicSimulationTests.swift:183-223`

推荐：pending location 必须且只可属于 active disposition；同一 lifecycle generation 只能有一个 closure。并发竞争 placement／completion 必须成为冲突，不得投影成同一承诺完成两次。

### P-42：取消延续安排没有“只撤叶边”的依赖规则

当前没有独立 cancel-continuation command。validator 允许 continuation target 后来 completed、changed、returned 或 abandoned，却不能判断原安排是否仍可安全撤回。

推荐规则：

| target 当前事实 | 原延续安排能否取消 |
|---|---|
| untouched pending | 可以 |
| 只改过未来日期 | 可以，取消最新 placement |
| 内容／附言／child 已编辑 | 不直接取消；先选择保留到任务池或明确丢弃 |
| 已有进度或 child 完成 | 不可以 |
| 已延期、再次延续或变更 | 原边已非叶，不可以 |
| 已完成或已废弃 | 不可以 |
| 已回池 | 原安排已经结束，只操作当前池任务 |

历史 source 始终保持 unfinished；取消只处理当前叶安排，不反写历史结果。证据：`TrajectoryTopologyValidator.swift:209-245`。

### P-43：生命周期动作没有稳定 operation identity，重试不是幂等成功 `[R]`

Sync record 只保存 entity current value，没有“用户执行了哪一项生命周期命令”的稳定 identity、basis revision 或第一次 receipt。完成、延期／延续、回池和变更直接按当前 status guard；其中延续、变更等还会生成随机 target identity。

本轮真实探针确认，对同一完成意图重试会得到 `invalidTransition("only pending traces can be completed")`，而不是返回第一次完成 receipt。若失败发生在 SQLite commit 之后、UI 收到结果之前，调用方无法安全判断应该重试、视为成功，还是会建立第二个 target。

证据：

- `Sources/NoonmarkSync/SyncRecord.swift:118-180`
- `NoonmarkEngine.swift:797-1117`
- `NoonmarkStore+NaturalDayPersistenceImport.swift:752-812`
- `Sources/NoonmarkStorage/SQLiteSyncUploadCoordinator.swift:34-62`

推荐把 lifecycle command 升为一级持久事实：稳定 `operationID`、actor/device、basis evidence frontier、kind、目标日期、涉及 identities、提交时刻和 receipt。相同 operation ID 重试必须返回同一个结果；等价并发操作也应能规范化成同一个事实。

### P-44：互斥生命周期决定按 record 时钟合并，会静默覆盖或产生第三种结果 `[R]`

当前 trace merge 先用 content clock／device order 选 base winner，再让 historical 压过 pending；它不知道两个 value 分别来自“完成”“延期”“回池”还是“变更”。本轮直接调用现有 merger 的运行探针得到：

| 同一 pending base 的并发决定 | fresh merge 结果 |
|---|---|
| complete@100 vs continue@200 | continued + future target；完成静默丢失，0 conflict |
| complete@200 vs continue@100 | 整个 component 回滚成原 pending，并产生 6 个 invalid payload conflicts |
| complete vs return | 单纯由较后 content clock 选 completed 或 returned |
| complete@100 vs change@200 | old changed + target pending |
| complete@200 vs change@100 | old completed，但 change target 仍作为另一项 pending 可见 |
| 两个不同日期的 concurrent continuation | 原 pending + duplicate-active conflicts，两个目标都消失 |
| 两次 future reschedule | 较后 clock 的日期静默获胜 |

更严重的是，两台原始设备互相下载时会保护各自 terminal history；fresh 第三台从两组 records 又可能看到上表中的第三种结果。因此“所有端最终一致”并不成立，且 conflict 数量也不能代表是否发生了语义丢失。

证据：

- `Sources/NoonmarkSync/CurrentSyncRecordMerger.swift:842-899,968-995,1132-1141,1194-1212`
- `Sources/NoonmarkSync/SyncRecordMerger.swift:2087-2195,2250-2326`
- `TrajectoryTopologyValidator.swift:145-155,191-245`

推荐按 command basis 判断因果：看见前一决定的后继可以覆盖祖先；从同一 basis 真并发的完成、延期、延续、回池、变更和废弃必须成为同一个**语义冲突**，不能用 wall/content clock LWW。等价并发可以合并；不同目标日必须让用户选，败方目标以明确 resolution fact 退休。

### P-45：同步冲突只有数字，没有受影响任务和真正的解决动作

仓储已经保存 unresolved conflicts，resolution enum 也有 keep local、accept remote、copy as new 等 case；但 App 只查询数量并在 Settings 显示“未解决冲突 N 条”，没有任务级列表、双方动作证据、导航或 resolve 入口，也没有任何 App 调用 `resolveConflict`。

即使直接把 conflict row 标为 resolved，该 API 也只更新 resolution 字段，不会建立 canonical lifecycle result、退休败方 target 或修复页面投影。

证据：

- `Sources/NoonmarkSync/SyncConflict.swift:5-25`
- `Sources/NoonmarkStorage/SQLiteSyncRepository.swift:318-385`
- `App/NoonmarkMacApp/NoonmarkStore+Sync.swift:530-580`
- `App/NoonmarkMacApp/AppCopy.swift:373-386`

推荐提供任务上下文中的冲突入口，展示双方动作、日期、设备和相关内容，并允许选 A、选 B 或保留副本。解决必须追加新的 canonical forward fact、关闭败方关系并让所有设备收敛，不是只把 ledger row 改成 resolved。

## 5. 建议采用的领域语言

### 5.1 延期

**延期**：当天尚未结束时，用户主动决定把仍待完成的同一任务安排到更晚日期。当天形成“已延期”结果，目标成为未来计划；延期不是未完成，也不增加延续次数。

### 5.2 延续

**延续**：某日已经在日结束时成为未完成后，用户为同一任务建立新的当前／未来执行安排。来源日始终保留未完成结果，并附加“后来延续至某日”的关系。

### 5.3 撤回延期

**撤回延期**：在来源 Day 尚未锁定且目标没有不可逆后续结果时，取消本次延期并让来源恢复为当天待完成。它是纠错，不构成用户任务轨迹。

### 5.4 取消延续安排

**取消延续安排**：在目标尚未产生执行结果或依赖时，取消后来建立的当前／未来安排；锁定来源仍保持未完成，不被改写。它是对新安排的纠错，不是撤销历史未完成。

### 5.5 当前处置与当前位置

**当前处置**描述任务链是否仍可继续、已废弃或已由新任务接替；**当前位置**描述尚未终结的任务现在位于任务池、未来计划或今日执行。两者都不能覆盖某日已经锁定的结果。

### 5.6 工作时区、观测本地日期与有效工作日

**工作时区**是同步项目用来决定日结束边界的稳定时区；**观测本地日期**只是当前设备对时间的日历解释；**有效工作日**是晷迹用于任务归属和动作合法性的单调日期。设备旅行或时区变化不能让有效工作日回退到已锁定日期。

### 5.7 日关闭事实与记录时刻

**日关闭事实**表示某个有效工作日已经在其工作时区边界固化；**记录时刻**表示设备实际发现并保存该事实的时间。两者可以不同，任务轨迹不得把记录时刻伪装成用户产生结果的时刻。

### 5.8 生命周期命令与语义冲突

**生命周期命令**是用户对一个明确来源版本作出的完成、延期、延续、回池、变更或废弃决定；相同命令重试仍是同一决定。两个互斥命令从同一来源版本并发产生时形成**语义冲突**，必须显式解决，不能按设备时间静默覆盖。

以上术语通过本文确认后，应更新 `CONTEXT.md`。现有 `已延续` 定义明确写着 `_Avoid_: 已延期`，且功能规格允许 current pending → continued，与已经确认的新政策冲突，不能只补一个新名词而保留旧关系规则。

## 6. 推荐的时间轴政策

### 6.1 任务池草稿

显示：任务池。

允许：

- 编辑标题、描述、附言和计划子任务；
- 排期到今天或未来；
- 删除从未形成日轨迹、也没有来源关系的误建草稿。

规则：

- 排到今天后成为今天待完成；排到未来后成为计划草稿。
- 删除误建草稿可以撤回，但 hidden cancellation 不得进入任务轨迹、统计或 AI。
- 有历史日轨迹的任务回到池后，不再称“可删除新任务”；若要终止任务链，应使用废弃。

### 6.2 普通未来计划

显示：未来计划聚合页和对应未来 Day Todo。

允许：

- 编辑计划内容和计划子任务；
- 调整未来日优先级；
- 改到今天或其他未来日期；
- 回到任务池。

禁止：

- 完成；
- 生成未完成、废弃等未来日结果；
- 延期或延续。

改期到今天后，它立即成为当天待完成；旧未来日期无历史结果。

### 6.3 当前日待完成

显示：Day Todo 活跃任务区。

允许：

- 明确完成；
- 延期到未来；
- 变更为新任务；
- 回池；
- 废弃；
- 编辑当前承诺范围；
- 对真正当天 Quick Add 的无来源误建任务执行删除。

不再提供“延续”。

### 6.4 日结束

午夜自然日边界继续自动发生，不由烛龙每日收尾控制：

- 仍待完成的父任务变为未完成；
- 仍待完成的子任务变为未完成；
- 当日优先级和结果锁定；
- 触及该日的撤回能力到期。

已完成、已延期、已变更、已回池和已废弃是该日已经形成的其他结果，不再被结算为未完成。

### 6.5 历史未完成

显示：原 Day Todo 始终为“未完成”；未完成池按任务链聚合。

允许：

- 延续到今天或未来；
- 回到任务池，表示暂不承诺具体日期；
- 废弃任务链。

推荐允许“回到任务池”，因为任务池表达当前未排期位置，历史未完成仍完整保留。禁止这个正常动作只是掩盖当前实现无法同时表达“有历史、当前位置在池”的缺陷。

### 6.6 已有延续目标

来源：仍显示未完成，并注明“已延续至目标日期”。

目标：

- 若在未来，显示为“由某日未完成延续”的计划草稿；
- 若是今天，显示为“由某日未完成延续”的当前任务。

同链不能从另一历史日期再分叉。目标可以：

- 完成；
- 到达当天后再次延期；
- 变更；
- 回池；
- 废弃。

回池不应被禁止。正确行为是：任务当前位置变为任务池，来源未完成历史仍保留；未完成池显示“当前在任务池”并跳转，不再给空 action plan。

### 6.7 目标再次未完成

如果延续目标到日后仍未完成，目标日形成新的未完成；之后只能从最新未完成前沿再次延续。

计数：

- 第一次历史未完成 → 新目标：延续 1 次；
- 目标日再次未完成 → 再建目标：延续 2 次；
- 当前日主动延期只增加延期次数，不增加延续次数。

### 6.8 工作时区与有效工作日

推荐第一期政策：

- 首次启用时以设备时区建立工作时区，之后作为同步偏好保持稳定；
- 旅行时设备显示可以跟随本地时区，但任务日界不自动改变；
- 用户主动修改工作时区时，只影响尚未关闭的边界，永不重新打开历史；
- 有效工作日只向前，不因系统时区或时钟回退；
- picker 永远排除 locked Day，即使它等于观测本地日期；
- 两台设备必须从同一工作时区与 day-close identity 判断某日是否结束。

如果产品希望“旅行后立即按当地午夜工作”，应设计一次显式的工作时区切换，而不是跟随 `autoupdatingCurrent` 静默改变历史语义。

### 6.9 迟到结算与日期异常

- app 关闭或休眠不取消已经确认的承诺；重新打开后逐日补写日关闭事实。
- 每个补写结果使用各自真实 effective boundary，recorded time 另存。
- 系统日期／工作时区一次异常跨越多日时先暂停写入，向用户确认；确认前不制造 unfinished。
- 设备时钟回退只影响显示时刻，不回退有效工作日，也不清除稳定情境撤回。
- 用于 sync ordering 的 logical clock 不进入用户可见精确时间。

### 6.10 在途动作跨越边界

动作是否属于旧日，以系统真正接受 command 时重新采样的有效工作日为准：

- 来源已因日关闭改变时，旧界面失效；
- 延期 sheet 不能自动变成延续 sheet；
- 23:59 看见、00:00 后提交的完成不回填昨日，而是解释“来源日刚刚关闭”；
- 可提供直接建立今天延续安排的下一步，但必须由用户再次确认；
- Review editor、change dialog、AI diff 等长生命周期界面都固定目标 identity 与 basis version，不读取已经漂移的全局 selection。

## 7. 推荐的动作政策

### 7.1 延期

前提：来源是未锁定 today pending；目标必须晚于今天。

来源显示：同一 Day Todo 可发现，状态为“已延期至 X”。它不再可完成；提供跳转目标与撤回延期。

目标显示：Future Plan，标明“由今天延期”。

统计：

- 当天结果计“延期”；
- 不计未完成；
- 不增加延续次数；
- 独立增加延期次数。

子任务：completed 和用户主动 abandoned 留在来源；open children 带到目标并保持同一轨迹线，来源显示“已延期”。

撤回条件：

- 来源 Day 未锁定；
- 目标仍是唯一执行前沿；
- 目标没有完成、再次延期、变更、回池或废弃等下游结果。

如果目标只编辑了标题、描述、附言或 open children，推荐撤回时把最新可编辑内容带回今天，避免静默丢失；UI 必须提示这一点。

### 7.2 延续

前提：来源是锁定日的真实未完成、属于最新 unresolved frontier，且同链没有其他执行前沿。

来源显示：保持“未完成”；附加“后来于 X 延续至 Y”。

目标显示：today pending 或 Future Plan，带来源日期。

统计：原日期未完成数不变；延续是后来处置，不反向改变原日完成率。

取消延续安排采用“只撤叶边”：目标仍是 untouched pending，或只改过未来 placement 时才可直接取消；已有内容、附言或 child 编辑时，先让用户选择保留到任务池或明确丢弃；已有进度、完成、延期、再次延续、变更或废弃时不再可撤。来源历史始终是未完成。该能力不能依赖 volatile Cmd+Z，也不能删除来源事实。

### 7.3 完成与撤回完成

- 只允许 today pending 完成。
- open children 阻止父完成。
- completed 与用户明确移出范围的 children 不阻止。
- 完成后同日继续显示已完成并进入已完成池。
- 撤回完成是稳定的情境动作，直到 Day 锁定；不依赖全局 undo stack。
- 延续链最新前沿完成后，任务链从可处理未完成池移除，但过去未完成仍留在历史 Day Todo 与完成轨迹摘要。
- 100% 进度不自动完成；必须明显提示用户确认父任务完成。

### 7.4 回池

未来计划回池：

- 无未来日结果；
- 计划草稿退出未来计划；
- 任务当前位于任务池；
- hidden cancellation 不进入任务轨迹、搜索、统计、复盘或 AI。

当前任务回池：

- 来源在当天结果中为“已回池”，可从 Day Todo 的结果切面发现；
- 主工作行退出；
- 任务池显示最新草稿；
- open children 变为计划子任务，completed／abandoned children 留在来源历史；
- 当日复盘计入回池。

有未完成历史的任务回池：

- 历史结果不变；
- current location 为任务池；
- 未完成池可继续展示历史，但动作变为“前往任务池／废弃”，不能成为 ghost。
- 再次排期时建立 placement／transfer relation，不把延续次数和 origin 重置为 0。

撤回当前回池：来源 Day 未锁、任务池草稿未被编辑或重新排期时，提供“恢复到今天”；锁定后不再撤回。

### 7.5 变更

变更只用于 today pending 且用户确认“这已经是另一个承诺”，不是普通文字修正。

来源：

- 当天结果显示“已变更为 X”；
- 不占活跃执行行；
- 原任务链明确由新任务接替，不再留在可处理未完成池。

目标：

- 新任务链、today pending；
- 显示“由 X 变更而来”；
- 继承来源 priority slot，不跳到列表末尾；
- 继承描述、附言和 open child 内容；child 使用新任务身份。

来源 open children 显示“已由新任务接替”，不能保持没有入口的 pending。

撤回变更：只在同日未锁且目标没有编辑、进度、子任务变化、完成、再次变更等依赖时提供。变更目标不得显示普通“删除新任务”；用户只能撤回变更或继续处置目标。

连续变更 A→B→C 时，默认关系入口直接跳到当前 C，并可展开完整线性接替链。B→C 已存在后，A→B 不再是叶边，必须先处置最新关系；replacement chain 不允许 fork 或 merge。

### 7.6 废弃与重新启用

废弃是任务链级决定：“不再继续这件事”。决定发生在用户执行动作的今天，不覆盖历史日结果。

按来源情境：

- today pending：当天结果显示已废弃；open children 显示“随父任务停止”。
- historical unfinished：历史仍显示未完成；任务链另显示“后来已废弃”。
- active Future Plan：计划从未来日期消失；不得在未来日期制造已废弃结果。
- 有 active target 时：确认文案必须明确将停止哪个 today／future target，不能从历史行静默操作另一个 trace。

重新启用：

- 同日未锁的当前废弃可以恢复同一 today pending。
- 尚未到期的 future plan 若没有后续依赖，可以恢复同一计划。
- 历史／已过期废弃不能把旧日期改成 pending 或 unfinished；推荐回到任务池，或由用户明确选择今天／未来日期。
- 曾废弃和重新启用两次决定都保留在任务轨迹。
- 只恢复“随父任务停止”的 children，不恢复用户之前主动废弃的 child。

### 7.7 删除

删除只适用于没有历史、没有来源关系、没有下游依赖的误建草稿：

- 真正当天 Quick Add 的误捕获；
- 从未排期的全新任务池草稿。

以下不得显示普通删除：

- 从任务池排到今天的任务，应回池；
- 变更目标，应撤回变更；
- 延期／延续目标，应撤回／取消安排或作新的生命周期处置；
- 有历史的任务池项目，应废弃而非伪装成删除。

删除产生的内部取消事实不进入任务轨迹或任何用户投影。

### 7.8 复制为新任务

定义：“以此任务内容再建立一个独立承诺”。

推荐复制：

- 标题、描述、附言、分类；
- 子任务标题、顺序和难度结构。

不复制：

- 完成状态；
- 手动／加权进度；
- 日期；
- 延期／延续次数；
- 历史结果。

新任务进入任务池，属于新任务链。可显示只读“复制自 X”，但不得伪装成延续。

## 8. 建议的状态／动作矩阵

| 用户情境 | 完成 | 排期 | 延期 | 延续 | 改期 | 回池 | 变更 | 废弃 | 删除 | 主要纠错动作 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 全新任务池草稿 | — | 是 | — | — | — | — | — | — | 是 | 撤销创建／撤销排期 |
| 有历史的任务池任务 | — | 是 | — | — | — | — | — | 是 | — | 撤销排期／重新启用 |
| 普通未来计划 | — | — | — | — | 是，可到今天 | 是 | — | 通过链处置 | 仅误建草稿 | 撤销排期／改期 |
| today pending | 是 | — | 是 | — | — | 是 | 是 | 是 | 仅 Quick Add 误建 | 各情境撤回 |
| today completed | 撤回 | — | — | — | — | — | — | — | — | 撤回完成 |
| today 已延期来源 | — | — | — | — | — | — | — | — | — | 跳目标／撤回延期 |
| historical unfinished | — | — | — | 是 | — | 是 | — | 是 | — | 依后来安排撤回 |
| active continuation target（future） | — | — | — | — | 是，可到今天 | 是 | — | 是 | — | 取消延续安排 |
| active continuation target（today） | 是 | — | 是 | — | — | 是 | 是 | 是 | — | 依动作撤回 |
| changed source | — | — | — | — | — | — | — | — | — | 跳目标／撤回变更 |
| returned source | — | — | — | — | — | — | — | — | — | 跳任务池／恢复到今天 |
| abandoned chain | — | — | — | — | — | — | — | — | — | 重新启用 |
| locked completed | — | — | — | — | — | — | — | — | — | 复制为新任务 |
| superseded chain | — | — | — | — | — | — | — | — | — | 查看接替关系 |

“排期”把任务池项目放到 today／future；“改期”只作用于未到期计划草稿；“延期”只作用于 today pending；“延续”只作用于 historical unfinished。这些动作不得再共用同一用户术语或日期约束。

## 9. 父动作对子任务的统一政策

| 父动作 | completed child | 用户主动 abandoned child | open child | 来源展示 |
|---|---|---|---|---|
| 延期 | 留在今天 | 留在今天 | 带到目标；保持轨迹线 | 已延期 |
| 历史延续 | 留在原日 | 留在原日 | 带到目标；保持轨迹线 | 原日仍未完成，附延续关系 |
| 回池 | 保留完成事实 | 保留移出范围事实 | 转为 planned child | 已回池／历史不改 |
| 变更 | 留在旧任务 | 留在旧任务 | 新任务获得新 child identity；旧项显示已接替 | 已变更 |
| 废弃父任务 | 保留 | 保留 | 标记随父任务停止 | 当天已废弃或历史另附链决定 |
| 重新启用 | 保留 | 不恢复 | 恢复随父任务停止的项 | 不改历史结果 |
| 复制为新任务 | 重置为 planned | 是否复制由“结构”政策决定，推荐复制为 planned | 复制为 planned | 新任务无历史状态 |

### 9.1 子任务编辑政策

- pending：可编辑；只有无来源、无下游关系的未来新建 child 才可删除草稿；当前日或由延期／延续／回池带来的 child 若不再需要，应使用废弃／移出范围并保留 lineage。
- completed：只读；要修改必须先在同日撤回完成。
- abandoned：只读，提供明确恢复动作；不能用普通 checkbox 触发 Core error。
- continued／deferred／transferred：只读关系结果。
- hidden cancellation：不可 presentation。

### 9.2 进度政策

- 当前 trace 有有效 children 时使用加权进度；没有时使用手动进度。
- cancelled 和 abandoned 不进入 actionable denominator。
- 父完成后仍标明原进度来源，不从 weighted 突然变成 manual。
- 延期、延续和同链回池再排期保留进度下限；变更为新任务重新计算。
- UI、Day Todo、详情、AI、烛龙消费同一结果。
- 100% 只表示范围已处理完，仍需用户明确确认父任务完成。

## 10. 稳定撤回政策

### 10.1 总规则

稳定撤回必须同时满足：

1. 不改写锁定日结果；
2. 被撤回动作的目标没有产生无法安全折返的依赖；
3. 撤回结果不会静默丢失用户后来编辑的内容；
4. 能从当前任务情境直接发现，不依赖应用从未重启或 undo stack 未被清空。
5. 能以原 lifecycle operation identity 和当前 basis facts 重新计算，重启、同步和时区显示变化不能让合法性凭空消失。

Cmd+Z 可以调用同一撤回能力，但不是能力本身。

同步带来远端下游依赖后，界面应立即重新计算并解释“已不能撤回，因为目标已在另一设备继续处理”；不得继续展示一个必然失败的按钮。单纯 sync reload 或时区向后不应清除仍合法的情境撤回。

### 10.2 动作截止表

| 动作 | 稳定撤回截止 |
|---|---|
| 完成 | 来源 Day 锁定前 |
| 延期 | 来源 Day 锁定前，且目标无不可折返依赖 |
| 历史延续安排 | 目标产生执行结果／下游关系前；来源历史始终不改 |
| 当前回池 | 来源 Day 锁定前，且池草稿未编辑／再排期 |
| 未来计划回池 | 池草稿未编辑／再排期前 |
| 变更 | 来源 Day 锁定前，且目标未被编辑或执行 |
| 当前废弃 | 来源 Day 锁定前可作纠错撤回；之后使用重新启用 |
| 排期／改期 | 目标到期或产生依赖前 |
| 删除误建 | 后续没有依赖时；只恢复 hidden identity，不改历史 |

## 11. Day Todo、聚合池与结果展示

### 11.1 Day Todo

逻辑上分为两种内容，不要求一定增加卡片或分组标题：

- **仍可执行**：today pending。
- **当日结果**：completed、deferred、unfinished、abandoned，以及可发现的 changed／returned source。

changed source 可以不占与目标重复的主工作行，但必须在目标上下文、当日结果或任务轨迹中可发现；returned source 可以退出主工作行，但每日结果和详情必须可发现。任务不能“凭空消失”。

### 11.2 未来计划

每项必须显示来源类型：

- 普通排期；
- 由今天延期；
- 由某日未完成延续；
- 从任务池再次排期。

Future Plan detail 必须显示并管理计划子任务、进度来源和来源关系，不要求用户跳到未来 Day Todo 才能编辑。

### 11.3 未完成池

只由真实日结束产生的 unfinished history 驱动；延期永不进入。

每条任务链显示：

- 未完成日期和次数；
- 延续次数；
- 延期次数；
- 当前处置；
- 当前所在任务池／未来计划／today；
- 将被延续或回池的 children 摘要。

只要任务仍未完成，行必须有以下之一：合法动作、当前位置跳转、明确 completed／superseded／abandoned 说明。不能有空 action ghost。

### 11.4 已完成池

- 父任务完成记录和 completed child records 分开计数。
- 导航数字默认表示完成父任务数；子任务数作为另一个指标。
- 完成轨迹分别展示延期日期与延续日期，不能把两者都叫延续。
- 复制为新任务时保留结构但重置状态。

### 11.5 任务池

任务池表示 current location，不表示“从未有历史”。有未完成、回池或延期历史的 active chain 仍可位于任务池；详情显示来源和历史链接。

## 12. 统计、复盘、搜索、任务轨迹与 AI

### 12.1 分开工作台统计与每日结果

- `DayWorkspaceSummary`：当前页面有多少仍可执行／可见的 row。
- `DailyOutcomeSummary`：该日真实承诺最终如何处置。

不能再用 Day Todo visible rows 作为所有统计的唯一集合。

### 12.2 每日结果口径

建议结果类别：

- 已完成；
- 未完成；
- 已延期；
- 已回池；
- 已废弃；
- 变更活动。

变更不应让“当日任务总数”简单新旧双计。建议把来源与目标视为同一个当日承诺 slot，最终结果由目标决定，同时单独计“发生 1 次变更”。

延续是后来对历史未完成的处置，不反向改原日期未完成数。对“延期是否降低承诺兑现率”可以显示独立比例，不建议用一个不透明 completion rate 混合所有处置。

### 12.3 搜索

- 搜索结果可优先返回当前可操作任务。
- 历史 changed／returned／deferred source 至少能从任务详情和任务轨迹找到。
- hidden cancellation 永不成为搜索结果。

### 12.4 任务轨迹

任务轨迹记录用户能理解的业务决定：排期、延期、延续、回池、变更、完成、废弃、重新启用。

- 历史未完成和后来延续必须是两个事实。
- 重新启用不能擦掉曾废弃。
- ordinary future reschedule 是否进入轨迹可以保持轻量，但内部 cancelledDraft 绝不能伪装成回池。
- 成功纠错撤回不进入用户轨迹；系统仍可保留内部 witness。

### 12.5 每日复盘与烛龙

- 每日收尾消费 DailyOutcomeSummary，不消费 Day Todo visible row count。
- changed／returned／deferred 必须进入当日处置证据。
- PlanDraft cancellation、有限撤销 hidden facts 永不进入 Provider prompt。
- Future／Pool／Unfinished／Completed 入口必须传递实际授权 scope。
- AI 必须能区分“建议延期”和“延续历史未完成”，并使用与 UI 相同的动作合法性。

## 13. 重启、同步与冲突政策

### 13.1 本地提交

现有“clone candidate → SQLite transaction → 成功后发布内存”的原子边界应保留。任何生命周期 command 都必须得到 durable receipt 后才改变 UI；保存失败维持原任务、selection 和撤回资格。

### 13.2 命令重放与并发

| 情境 | 推荐合并结果 |
|---|---|
| 相同 operation ID 重放 | 返回第一次 receipt，不重复执行 |
| 同 basis 的等价 complete + complete | 合并为一次完成，保留双方 evidence |
| 同 basis、同目标日的等价延期／延续 | 规范化为同一个 target 与关系 |
| 同 basis、不同目标日的延期／延续 | 语义冲突，等待用户选日期 |
| complete vs 延期／回池／变更／废弃 | 语义冲突，不按 timestamp 静默选边 |
| 因果后继动作 | 在前一事实基础上执行；不得伪装成真并发 |
| 普通内容编辑 | 可按字段／CRDT 政策合并，但不能越过 lifecycle basis |
| future reschedule 真并发 | 推荐任务级冲突；若第一期选择确定性 winner，必须通知并提供稳定撤回 |

所有端最终只能有两种合法结果：收敛到同一 lifecycle projection，或共同显示同一个可解决冲突。不得让原设备各持一套 terminal、第三台又产生第三种结果。

### 13.3 冲突展示与解决

- 在受影响任务行／详情提供轻量但明确的“待解决”入口，不只在 Settings 显示总数。
- 展示双方动作、目标日期、设备、reported time、basis 与会受影响的 child／关系。
- 冲突期间保留双方 evidence，冻结会制造更多拓扑分叉的 lifecycle 动作；不相关的查看与安全编辑可以继续。
- 用户选 A、选 B 或保留副本后，写一项新的 resolution command；败方 target 明确退休。
- locked history 不能靠 resolution 原地改写；resolution 作为后来事实解释哪项并发 evidence 成为 canonical outcome。

### 13.4 重启、同步与撤回

- 全局 Cmd+Z 可以保持 session-only，并在 sync reload 后清空。
- 撤回延期、取消延续安排、撤回变更等产品能力必须从持久 command／relation facts 推导，跨重启、跨同步仍可判断。
- 若远端已经建立下游依赖，原撤回入口变为说明，而不是泛化失败。
- sync generation CAS 失败时重新读取、重新合并并有限重试；不得覆盖并发本地写入。

## 14. 组合压力测试：推荐结果

| 动作序列 | 当前结果 | 推荐结果 |
|---|---|---|
| today pending → 延期 | 被记为 continued | 今日已延期；未来有来源 plan；不进未完成池 |
| 连续两天主动延期 | 第二次后污染未完成池 | 延期 2 次，未完成 0 次 |
| historical unfinished → 延续 | 原未完成被覆盖 | 原日仍未完成，附延续关系 |
| 延续 future target → 回池 | UI 失败或到日后形成 ghost | current location=任务池；历史仍未完成；未完成池可跳池 |
| 延续 today target → 变更 | 原链形成无动作 ghost | 原链 superseded 并退出可处理未完成池；新链继续 |
| 延续 target → 完成 | 正常关闭整链 | 保留；历史未完成只在完成轨迹中展示 |
| 延续 target → 当天再往后推 | 被算第二次延续 | 今天形成延期；延续次数不变，延期次数 +1 |
| 变更 → 直接删除 target | 菜单允许，candidate 违反 invariant，真实保存失败 | 不提供普通删除；提供撤回变更 |
| 变更 → target 回池 → 池删除 | 可合法落盘但来源与目标都不可达 | 禁止删除有 incoming provenance 的池任务；只可废弃／撤回关系 |
| A → B → C 后从 A 跳目标 | 停在隐藏 B 并清空 selection | 直接跳当前 C，可展开完整线性关系 |
| 变更 priority=1 | target 跳到列表末尾 | target 继承同一 priority slot |
| future plan → 提前到 today | 必须回池再排期 | 直接改期到 today，无旧日期结果 |
| future plan → 今天废弃 → 过期重启 | 未来日被追溯成 unfinished | 废弃决定发生在今天；重启回池／选新日期，未来旧日无结果 |
| historical unfinished → 废弃 → 重新启用 | old status unfinished↔abandoned | old day 永远 unfinished；链级决定保留两次记录 |
| current return → 日结束前后悔 | 无上下文撤回 | 池草稿未动且 Day 未锁时恢复 today |
| parent change/return/abandon | 来源 child 留 pending | 每个 child 明确 transferred／returned／stopped |
| abandoned child + parent complete | 可完成但进度低于 100 | child 不进 denominator；完成显示 100% + 移出范围数 |
| 延续 child → 普通删除 → 再延续 | visible lineage 断裂，但 validator 通过 | 禁止普通删除；形成可见 stopped／abandoned child |
| historical → 延续 → 回池 → 再排期 | continuationSeq/origin 可能重置 | placement 改变，延续 identity 与次数连续 |
| completed task → copy new | 子任务结构丢失 | 复制结构，重置所有执行状态 |
| 纽约跨日后切洛杉矶 | “今天”同时是 locked history，旧今日结果变未来 | effective work day 不回退；设备日期仅用于显示 |
| 系统日期误跳三天 | 三天计划被不可逆批量结算 | 暂停结算并要求确认；正常休眠才逐日补关闭事实 |
| 23:59 打开延期 sheet，00:00 确认 | 静默变成历史延续 | 旧 sheet 失效，用户重新选择延续 |
| 旧日复盘编辑跨午夜 | 最后输入可能写到新日 | editor 固定 Day identity，只写原日 addendum |
| 同 command 因 receipt 丢失而重试 | invalidTransition 或生成新 identity | 相同 operation ID 返回第一次 receipt |
| 双端 complete vs 延期／回池／变更 | 静默 LWW、回滚 pending 或出现第三结果 | 所有端显示同一语义冲突，用户 resolution 后收敛 |
| 双端从同一 pool task 各自完成 | 可能形成两个 terminal roots | 同 generation 只允许一个 closure；并发 placement 冲突 |

## 15. 仍需产品确认的边界

本文给出默认推荐，但以下决定值得单独确认：

1. **当日结果怎样摆放**：与活跃任务混排，还是同页次级结果区？推荐逻辑分区、视觉保持轻量。
2. **撤回延期时如何处理目标编辑**：推荐把最新可编辑内容带回今天，并明确提示。
3. **历史未完成是否可直接回池**：推荐允许；历史聚合与 current location 可以重叠。
4. **历史延续目标是否可回池**：推荐允许；禁止正常动作只是掩盖 current-location 模型缺口。
5. **重新启用历史／过期任务放哪里**：推荐回任务池，或当场让用户选择 today／future；不自动改旧日状态。
6. **变更撤回允许哪些目标编辑**：第一期推荐目标一旦发生任何内容或执行变化便不再直接撤回，避免复杂合并。
7. **复制为新任务是否复制用户主动 abandoned child 结构**：推荐复制结构但全部重置为 planned，并在确认文案说明。
8. **普通未来改期是否进入任务轨迹**：推荐任务详情可见最近一次改期，日统计不计结果。
9. **已废弃任务的长期入口**：现有未完成池可保留历史链；无未完成历史的废弃草稿需要已废弃筛选或搜索入口。
10. **延期是否计入承诺兑现率**：推荐单列延期率，不把它伪装成完成或未完成。
11. **工作日按哪个时区关闭**：推荐建立同步、稳定的工作时区；旅行时不随设备自动切换。
12. **怎样修改工作时区**：推荐显式操作并展示下一次关闭边界；永不重新打开历史 Day。
13. **多大的日期前跳视为异常**：推荐非正常午夜信号且一次跨越多日时暂停并确认；正常多日休眠仍自动补结算。
14. **互斥多端动作怎样处理**：推荐任务级语义冲突，不使用 completed-wins 或 timestamp-wins 之类隐藏优先级。
15. **并发 future reschedule 是否需要冲突**：推荐需要；若第一期采用确定性 winner，必须通知并提供稳定撤回。
16. **A→B→C 是否允许整段撤回**：第一期推荐只撤叶边；整段撤回后续再作为显式原子能力。
17. **锁定日复盘能补写到何时**：推荐 task outcomes 永久锁定，review addendum 可补写并记录修订时间／来源。
18. **设备时间明显异常时怎样显示任务轨迹**：推荐显示 reported time 加“设备时间可能有偏差”，logical order 永不显示为真实时间。

## 16. 行为验收清单

后续重构只有满足以下用户路径才可 cutover：

1. today pending 只能延期，不能显示延续；日期默认明天。
2. 延期来源当天可发现，目标带来源；重启后仍能判断是否可撤回。
3. 连续延期不进入未完成池，延期次数准确。
4. 日结束 pending 才生成 unfinished；后来延续不改变原日状态／统计。
5. 首次延续显示 1 次；再次延续显示 2 次。
6. 普通 future plan、deferred target、continued target 都有正确来源和动作，不出现必失败菜单。
7. 所有 future plan 都能改到 today；旧未来日期不形成结果。
8. continued target 完成、延期、回池、变更、废弃后，旧链都有明确 closure/location，不产生 ghost。
9. 变更 target 不显示普通删除，priority slot 不改变。
10. 废弃 future plan 不在未来日制造 abandoned；过期后重新启用不制造 unfinished。
11. 锁定历史的 unfinished、completed、deferred 等结果永不因后来动作改变。
12. parent action 后没有不可操作的 pending child。
13. abandoned child 不进 progress denominator；父完成显示一致。
14. Future detail 与未来 Day Todo 对计划子任务能力一致。
15. copied task 保留结构、重置状态。
16. 普通编辑与变更有清楚说明；任务池来源与 Quick Add 使用不同删除政策。
17. 有历史的任务池任务执行废弃后仍可找到并重新启用。
18. DayWorkspace、DailyOutcome、Calendar、Search、TaskTrail、Zhulong、AI 对账一致。
19. hidden cancellation 在任何用户投影和 Provider payload 中均为 0。
20. 同一 instant 在纽约 → 洛杉矶 → 纽约往返时，有效工作日不回退，也不出现“今天已锁定”或“未来已完成”。
21. 两台设备处于不同时区时，一端不能提前锁死另一端仍在执行的 Day。
22. 系统日期异常前跳多日时暂停结算；正常休眠多日则逐日补写各自 effective boundary。
23. `effectiveBoundaryAt`、`recordedAt` 与 logical order 在轨迹、统计和 AI 中不混用。
24. 延期／延续 picker 跨午夜或 sync revision 后失效，不静默改变动作语义。
25. 午夜边界提交失败显示“来源日已关闭”和下一步，不只显示泛化 error。
26. Review editor 跨午夜、切日或同步后仍只写固定的原 Day。
27. 相同 lifecycle operation 重试返回相同 receipt 和 target identity。
28. complete 与延期、延续、回池、变更、废弃的所有双端排列都收敛，或在所有端显示同一个语义冲突。
29. 冲突解决会写 canonical forward fact、退休败方 target，并在重启和 fresh 第三端保持一致。
30. A→B→C 从任一节点都能跳到当前 C；非叶关系不能单独撤回。
31. change chain fork／merge、同 generation 双 closure 和 abandoned chain + pending trace 在所有写入边界 fail-closed。
32. changed／continued provenance target 回池后不获得普通删除，不产生不可达关系。
33. 由延期／延续带来的 child 不可普通删除；移出范围后 lineage 仍可解释。
34. historical → 延续 → 回池 → 再排期不重置延续次数、origin 或 child lineage。
35. 真实 `.app` E2E 覆盖以上路径，并用 SQLite 重启、双端同步与 fresh 第三端探针证明撤回、历史、当前位置和冲突结果不漂移；显式 live iCloud 验证不得用 mock 代替。

## 17. 源码证据索引

### Core 状态与投影

- `Sources/NoonmarkCore/Models.swift:3-71,838-1009`
- `Sources/NoonmarkCore/NoonmarkEngine.swift:602-785,797-1116,1148-1444,1558-1762,2206-2645`
- `Sources/NoonmarkCore/NoonmarkSnapshot.swift:66-429,556-588`
- `Sources/NoonmarkCore/TrajectoryTopologyValidator.swift:30-286,318-469`
- `Sources/NoonmarkCore/MutationClock.swift:3-157`

### Mac App 行为入口

- `App/NoonmarkMacApp/NoonmarkStore+TaskMutations.swift:31-568,780-875`
- `App/NoonmarkMacApp/NoonmarkStore+PresentationUndo.swift:130-180,220-307,384-490,794-795`
- `App/NoonmarkMacApp/NoonmarkStore+NaturalDayPersistenceImport.swift:74-102,740-855`
- `App/NoonmarkMacApp/SystemNaturalDayEnvironment.swift:11-107`
- `App/NoonmarkMacApp/NoonmarkStore+Sync.swift:303-424,530-580`
- `App/NoonmarkMacApp/NoonmarkStore+SelectionProductivity.swift:32-94,315-390`
- `App/NoonmarkMacApp/NoonmarkStore+ClassificationReview.swift:114-124`
- `App/NoonmarkMacApp/DatePickerSheet.swift:15-35,248-360`
- `App/NoonmarkMacApp/DayTodoPage.swift:17-88,640-695`
- `App/NoonmarkMacApp/TaskDetail.swift:18-90`
- `App/NoonmarkMacApp/FuturePlanDetail.swift:17-80`
- `App/NoonmarkMacApp/FuturePlansPage.swift:72-139`
- `App/NoonmarkMacApp/UnfinishedPoolPage.swift:90-130,254-281`

### 自然日、同步与持久化

- `Sources/NoonmarkDayContext/NaturalDayContext.swift:20-73,125-230`
- `Sources/NoonmarkMacRuntime/DayRolloverCoordinator.swift:5-27`
- `Sources/NoonmarkSync/CurrentSyncRecordMerger.swift:715-995,1132-1212`
- `Sources/NoonmarkSync/SyncRecordMerger.swift:2087-2326`
- `Sources/NoonmarkSync/SyncConflict.swift:5-25`
- `Sources/NoonmarkStorage/SQLiteSyncRepository.swift:245-296,318-385`
- `Sources/NoonmarkStorage/SQLiteSyncDownloadCoordinator.swift:57-143`
- `Sources/NoonmarkStorage/SQLiteSchema.swift:1797-1800`

### 运行证据入口

- `App/NoonmarkMacApp/NaturalDayRolloverE2EAutomation.swift:75-235`
- `Tests/NoonmarkMacRuntimeTests/DayRolloverCoordinatorTests.swift:11-98`
- `Tests/NoonmarkStorageTests/SQLiteSyncDownloadCoordinatorTests.swift:302-359`
- `Tests/NoonmarkStorageTests/SQLiteLocalFirstSyncCoordinatorTests.swift:154-210,414-514`
- `Tests/NoonmarkSyncTests/SyncRecordMergerTests.swift:2839-3060,3577-3605`

### 统计、搜索与 AI

- `Sources/NoonmarkMacRuntime/WorkspaceSearchIndex.swift:56-90`
- `App/NoonmarkMacApp/CalendarPage.swift:353-374`
- `Sources/NoonmarkAI/AIScope.swift:4-150`
- `Sources/NoonmarkAI/AIPromptBuilder.swift:65-161`
- `Sources/NoonmarkZhulong/ZhulongDailyClose.swift:100-145,438-485`

### 现有领域约束

- `CONTEXT.md:7-172,598-750`
- `docs/product/phase-1-functional-spec.md:3-15,160-205,240-382,442-499,583-658`
- `docs/design/mac-ui-design-contract.md:55-120,196-238,261-313`
- `docs/adr/0020-preserve-cancelled-future-drafts-as-hidden-relational-facts.md`
- `docs/adr/0021-preserve-snapshot-undo-identities-as-hidden-cancellation-facts.md`

## 18. 文档闭环建议

本文确认后按以下顺序更新领域文档：

1. `CONTEXT.md`：已同步本轮唯一确认的“延期／已延期／延续”分界，并取消用“已延续”覆盖历史未完成；撤回延期、当前处置／当前位置、工作时区、有效工作日、日关闭事实和语义冲突仍须确认后再写入。
2. `phase-1-functional-spec.md`：替换 current pending → continued；补完整行为矩阵、稳定撤回、child policy、在途动作版本和多端冲突政策。
3. `mac-ui-design-contract.md`：定义 Day Todo 当日结果可发现性、Future origin、日期异常、情境动作和任务级冲突入口。
4. 新 ADR：分别记录“历史结果与后来处置分离”和“同步工作时区 + command-based lifecycle merge”。两项都难逆、反直觉且存在真实取舍，不应埋在 enum 设计里。
5. 技术状态机报告：已补入工作日权威、operation identity、semantic conflict 和关系图约束；实施设计仍须以本文最终确认结果调整 interface、aggregate invariant、sync merge 和迁移建议。

在这些文档更新完成前，不应直接开始给现有 `TraceStatus` 加 `deferred` case；否则只会把新词塞进旧的混合模型。

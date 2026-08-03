# 晷迹想法记录（Idea Capture）产品规格

**状态**：已接受设计，第一阶段已实现
**日期**：2026-07-30；2026-08-03 补记置顶、回收站与标签点击过滤语义
**风险等级**：A 级——新增一等领域实体并跨 Core、Storage、Sync 与 Mac UI；项目尚未发布，无既有用户数据

## 目标与成功标准

晷迹新增对标 flomo／Memos／Thino 的原生想法记录能力，让用户把尚未决定是否或如何执行的零散灵感、记录或提醒立即写下来，不打断当前工作，也不强迫当场形成任务承诺。

成功标准：

- 想法由一等领域实体 **想法条目**（`IdeaEntry`）承载，不依附任务、不进入任务状态机、不投影到任何任务池化视图或统计。
- App 内「想法 / Ideas」页面与全局快捷键速记浮窗双入口共用同一领域命令与 `#标签`／`@分组` token 解析。
- 想法条目复用现有任务分组与标签目录，删除留墓碑，并纳入同步，与任务实体同待遇。
- 无 AI Provider 时想法记录全功能可用，不经过烛龙会话。
- 真实 `.app` E2E 截图、SQLite 探针、同步乱序／并发测试与 DMG 安装启动全部通过。

## 范围

### 第一阶段功能清单（本次实现）

- 领域：`IdeaEntry` 实体（含可选 `pinnedAt`）与 `appendIdea`／`editIdea`／`deleteIdea`／`restoreIdea`／`setIdeaClassification`／`pinIdea`／`unpinIdea` 命令；`pinnedIdeas(filter:)`／`ideaTimeline(filter:)`／`ideaTimelineByDay` 投影与 `ideaTrash()` 回收站投影（按 `deletedAt` 倒序）；`IdeaTimelineFilter` 为正文 substring、主分类与标签的 AND 组合。
- 存储：新表 `idea_entries`（schema version 15→16）与置顶列 `pinned_at`（schema version 16→17），clean-cut 无迁移。
- 同步：纳入 `change_journal`、`SyncSnapshotDiffer` 与上下行协调器，墓碑与 `pinnedAt` 随同步 payload 传播。
- UI：侧边栏新页面「想法 / Ideas」——顶部常驻多行速记框（MarkdownEditor，Cmd+Enter 保存），下方过滤框与倒序时间线按自然日分组；时间线上方有「已置顶」分组（复用日分组标题排版，无徽章图标）；卡片呈现正文、时间戳、可点击的分组／标签行与溢出菜单（置顶／取消置顶／编辑／删除），支持行内编辑，置顶操作支持 undo；页底为默认折叠的回收站分区，行内恢复需重新输入正文。
- 全局快捷键速记浮窗：默认 ⌃⇧I，可在设置改键；Enter 保存、Esc 关闭；沿用 ADR 0033 的非独占 Carbon hotkey 与冲突检查纪律。

### 明确不包含

- 不提供想法→todo／排期转换；该能力属第二阶段，仅完成设计（见下文）。
- 不提供 agent 自动整理归类；第二阶段设计，用户确认前不落库。
- 不建立第二套分类库，不为想法建立历史分类快照。
- 不提供想法硬删除；同步收敛依赖墓碑持续存在，删除只追加 `deletedAt`。
- 不把想法投影到 Day Todo、任务池、未来计划、未完成池、已完成池、日历、全局搜索或页面统计区。
- 不提供想法的 AI 摘要、向量化、链接双链、附件或图片；第一阶段正文为纯文本（速记框使用多行 MarkdownEditor，但语义即正文文本）。
- 不提供旧 schema 迁移、旧数据读取或兼容路径；开发数据按 clean cut 纪律作废。

## 领域模型

```swift
public struct IdeaEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: IdeaID
    public var body: String            // 归一化后非空
    public var categoryID: TaskCategoryID?
    public var labelIDs: [TaskLabelID]
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?        // 墓碑删除
    public var pinnedAt: Date?         // 置顶时间；墓碑时清除
}
```

- 正文归一化：去除首尾 Unicode whitespace 后必须非空，否则拒绝保存；与任务正文纪律一致。
- 分类复用现有任务分组与标签目录：`categoryID` 至多一个，`labelIDs` 零到多个、无主次顺序；active 分类项才能接受新关联，归档项保留既有关联。想法分类只是当前关系，不形成历史快照，不进入分类关系历史的任务语义。
- 删除只追加 `deletedAt` 墓碑，与 **任务附言条目** 同纪律；身份不能复用，不能被离线或旧同步副本复活。`ideaTimeline` 只投影未删除条目；已删除条目进入 `ideaTrash()` 回收站投影，按 `deletedAt` 倒序。
- 删除时正文归一化清空，墓碑不保留正文：回收站只承载身份、分类与时间戳，恢复必须经 `restoreIdea(id:body:now:)` 由用户重新输入非空正文。这一设计让已删除正文不再随同步 payload 与 **数据包** 继续流动，收敛已删除内容的暴露面。
- 不提供硬删除：跨设备同步收敛依赖墓碑在缺少完整设备确认前持续存在，硬删除会让旧副本在乱序到达时复活。
- 置顶是当前状态而非历史事实：`pinnedAt` 记录置顶时间，先置顶者排前；tombstone 时同步清除 `pinnedAt`，恢复不复活旧置顶。置顶只改变 `pinnedIdeas(filter:)` 与时间线投影呈现，不产生新的事实类型。
- 想法条目不依附任务、不形成 **日轨迹**、不参与任务状态机与任何池化视图；与 **任务附言**（依附任务）和 **快速捕获**（落点即任务）的边界以 `CONTEXT.md` 词汇为准。
- 第二阶段转换溯源字段 `convertedToChainID` 届时追加，不在第一阶段模型中预留。

## 交互

### App 内「想法 / Ideas」页面

- 侧边栏新增一级页面「想法 / Ideas」，与既有页面同级。
- 顶部常驻速记框：多行 MarkdownEditor，Cmd+Enter 保存；保存成功后清空并保留焦点，时间线顶部即时出现新卡片。
- 速记框支持 `#标签`／`@分组` token：复用与任务快速输入相同的解析器、词边界规则、候选排序与引号形式（`#"Deep Focus"`／`@"Client Work"`）；第二个 `@分组` 阻止提交并明确提示。
- 速记框下方为过滤框：substring 匹配正文，过滤只改变展示，不改变任何事实。
- 卡片上的 `@分组`／`#标签` 组件可点击：点击即把该分类设为过滤条件，与过滤框正文组成 `IdeaTimelineFilter` 的 AND 组合；过滤激活时，时间线上方显示单条可清除的过滤指示。
- 时间线按创建时间倒序、按自然日分组；置顶条目汇集在时间线上方的「已置顶」分组，复用日分组标题排版，不新增徽章或图标等视觉单位；卡片 = 正文 + 时间戳 + 可点击标签行 + 溢出菜单（置顶／取消置顶／编辑／删除），置顶操作支持 undo。
- 编辑为行内编辑：保存走 `editIdea`，清空保存等同删除并留墓碑（与附言编辑纪律一致）；取消恢复原正文。
- 删除走溢出菜单，留墓碑后卡片从时间线消失；tombstone 同时清除置顶。
- 页底为默认折叠的回收站分区，展示 `ideaTrash()` 投影；恢复为行内编辑态，用户重新输入正文后保存，走 `restoreIdea(id:body:now:)`。
- 视觉遵循 **Mac UI 设计契约**：不新增视觉单位堆砌，卡片层级以字号、字重、留白与单条分隔线建立；全局唯一 DOM id 纪律同样适用于 SwiftUI 标识。

### 全局快捷键速记浮窗

- 默认 ⌃⇧I 唤起，可在设置改键；改键沿用 ADR 0033 的事务性注册、物理 virtual key、主菜单与系统 symbolic hotkeys 冲突检查，第三方冲突只能明确披露。
- 浮窗 Enter 保存、Esc 关闭；保存或关闭后恢复此前前台 App，不打开已关闭的主窗口。
- 浮窗与页面速记框写入同一 `appendIdea` 命令，使用同一 token 解析器；重复触发保留草稿。
- 快捷键偏好只保存在本机 `UserDefaults`，不进入任务数据库、数据包或同步。

### 归类

- 第一阶段归类是手动操作：速记 token 或卡片溢出菜单／编辑态选择分组与标签，走 `setIdeaClassification`。
- 任何 agent 建议都不在第一阶段出现；第二阶段归类建议必须经用户确认才落库（见下文）。

## 持久化与同步行为

- SQLite 新增 `idea_entries` 表（schema version 15→16），随后追加 `pinned_at` 列（schema version 16→17）；只接受空白数据库或精确匹配当前版本的数据库，其余 fail-closed，不提供迁移。
- 写路径由同一 SQLite `BEGIN IMMEDIATE` 事务覆盖：实体写入与 sync outbox 原子提交，任何失败不得留下半成品条目。
- 想法条目是首类同步事实：纳入 `change_journal`、`SyncSnapshotDiffer` 与上下行协调器，与任务实体同待遇；payload 使用与既有实体一致的 canonical current envelope 纪律，`pinnedAt` 随 payload 传播。
- 乱序到达按既有 journal 纪律合并；编辑与删除竞争不产生复活，墓碑在缺少完整设备确认前不做 GC。
- 数据包与导入导出沿用当前契约：想法条目（含 `pinnedAt` 与墓碑状态）随任务事实一同进出 **数据包**；非当前 envelope 一律拒绝。
- 想法分类引用不阻断分类归档与合并的既有语义；被引用分类的 **分组删除**／合并按既有影响预览与原子迁移处理，想法条目作为引用方计入影响范围。

## 演示基线与 E2E 验收

- 交互演示沿用 `make run-demo-app` 十天中段用户状态；想法记录属于需要历史才能体验的功能，十天用户故事、机器可检查报告与 `docs/engineering/interactive-demo-fixture.md` 覆盖表由演示基线改动在同一轮补齐（本规格只定义覆盖契约，不改该文件）。
- 演示覆盖契约：时间线跨多个自然日、含带分组／标签与未归类的条目、含可验证的墓碑删除结果；速记框与过滤框可交互。
- 真实 `.app` E2E：页面速记 Cmd+Enter 保存、`#`／`@` token 候选与引号形式、第二个 `@分组` 阻断、过滤、行内编辑、删除后时间线消失；全局热键浮窗打开、Enter 保存、Esc 关闭、焦点恢复与主窗口不重开。
- SQLite 探针验证落库、编辑、`deletedAt` 墓碑与重启后回读；同步乱序／并发测试覆盖墓碑不复活。
- 完整 `scripts/test-e2e`、`make check` 与 DMG 安装启动继续作为发布门禁；无 frontend-verify skill 时，以真实 `.app` 截图、交互断言、console 与持久化探针补齐。

## 第二阶段 agent 能力设计（仅设计，不落代码）

### 想法 → todo／排期

- 用户在想法卡片手动触发转换；不存在后台或批量自动转换。
- 转换走烛龙 **对话产物** 通道（ADR 0028）：想法正文作为输入形成 taskPlan，产出 `ZhulongTodoDiffDraft`，用户可在会话内编辑。
- 用户一次性授权后由 `ZhulongTodoDiffApplier` 通过普通领域接口原子应用；部分成功不存在。
- 应用成功后想法记录 `convertedToChainID` 溯源字段（届时追加），时间线卡片展示已转换关系；原想法条目保留，不被删除或改写。
- 未确认前不产生任何任务事实；Provider 不可用时转换入口按烛龙本地模式纪律不可用并明示原因，想法记录其余功能不受影响。

### 想法整理归类

- agent 基于现有分组／标签目录为单条想法建议一个分组与一至三个标签，prompt 与解析复用 `AutomaticTaskClassificationPromptBuilder`／`Decoder` 的严格 JSON handle 契约。
- 手动触发；建议以可审查形式呈现（建议值 + 理由），用户确认前不落库；确认后走 `setIdeaClassification`，来源按分类来源纪律可追溯。
- 用户随后手动归类永远优先，任何用户分类变化使旧建议作废。

### 回顾与再发现

- 竞品调研结论：flomo／Memos／Thino 的回顾／再发现类能力——每日回顾、随机漫步、相关想法、想法洞察——本质依赖语义关联与个性化判断，统一归入烛龙第二阶段，与上述两条能力同样遵守用户确认与白盒纪律；第一阶段不提供。

### 硬边界

- AI 未经确认不写任何数据的边界不变：第二阶段两条能力都只产生产物或建议，写入必须经用户显式确认，并继续走普通领域接口与 **AI 应用批次** 纪律。

## 验收门槛

- 运行期源码、schema、fixture 与产品 UI 只存在当前一套想法模型；无 adapter、双写、兼容 decoder 或迁移路径。
- `make check`、`NoonmarkCoreTests`／`NoonmarkStorageTests` 想法用例、同步乱序／并发测试、真实 `.app` E2E、SQLite 探针与 DMG 安装启动全部通过。
- 无 Provider 环境下想法记录全功能路径由 E2E 实证；烛龙与 Provider 相关入口不出现於想法页面。
- `CONTEXT.md` 想法词汇、`docs/adr/0040` 与本规格一致；演示基线覆盖契约由对应改动同步落地。

## 风险与回滚

- 风险：想法与任务附言边界混淆。CONTEXT.md 已固化三方边界，UI 上想法不投影到任何任务列表；后续实现评审必须核对这一隔离。
- 风险：token 解析与任务快速输入漂移。两条入口强制共用同一解析器，E2E 对两侧做同一组 token 断言。
- 风险：同步乱序下编辑与墓碑竞争。由既有 journal 合并纪律与墓碑防复活覆盖，乱序／并发测试为门禁。
- 回滚：代码回滚以本改动前的 Git commit 为唯一边界，随后执行 `scripts/reset-dev-data`；不保留旧 schema 读路，不让旧二进制读取新开发数据。

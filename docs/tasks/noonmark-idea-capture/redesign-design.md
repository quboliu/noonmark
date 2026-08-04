# 晷迹想法记录重做设计

- Task-ID：`noonmark-idea-capture`
- 风险等级：P
- 状态：宽屏 B／窄屏 A 骨架切片已实现并通过真实 App 验收；单条 memo 视觉深化与后续领域切片待续
- 日期：2026-08-03

## 需求

晷迹的想法记录不是一张可 CRUD 的短文本表，也不是任务草稿或完整知识库。它是一条“写 → 看 → 找 → 回 → 做”的思考收件箱：用户先无负担记录，之后能顺畅阅读、找回和重新遇见旧内容，最后在明确决定行动时转成真正的晷迹任务。

已确认的硬需求：

1. 页面与全局浮窗共用多行 composer、草稿和提交语义：`Enter` 换行、`⌘Enter` 保存；关闭、失焦、重复唤起、保存失败与 App 重启不丢未提交草稿。
2. 捕获只要求非空正文；`#标签` 是可选行内增强，可复用或原子建立标签，不得因未知标签阻断记录；不在捕获时要求任务分组。
3. 默认视图是适合扫读的最近时间线；搜索结果、标签结果、回看、归档和回收站是清楚分开的内容集合，不再纵向堆在同一长页面。
4. 双击旧想法正文立即在原位置进入编辑。编辑保持卡片尺寸、滚动位置与当前浏览集合；`Enter` 换行、`⌘Enter` 立即保存、`Esc` 放弃修改，点击别处触发安全保存。三点菜单只保留辅助入口。
5. 编辑失败时保留正文和编辑状态，并显示当前条目内的可恢复错误；不得只发一个会消失的 toast。
6. “回看”是首版非 AI 能力：每次展示少量、可解释的旧想法，默认排除最近内容；用户可刷新、编辑、加标签或转任务。
7. “转为任务”首版离线可用：默认建立一条任务池任务，可在确认面改为今天或未来日期；创建任务和记录来源必须在同一原子 mutation 中完成，想法与任务可双向跳转。
8. 归档用于把不活跃内容移出最近时间线。删除先进入能恢复原正文的回收状态；用户永久删除时只清除正文和标签，内部同步墓碑继续保留，避免旧副本复活。
9. 首版不以置顶、任务主分组、附件、图片、知识图谱、多布局、热力图、AI 洞察、语义相关或自动归类作为成立条件。

## 本轮交付边界

用户已选择 B「时间线＋检视」作为 Mac 宽屏骨架，A「连续流」作为窄窗形态。本轮生产切片已经交付：

- 页面与全局浮窗共享多行 composer session；`Enter` 换行、`⌘Enter` 保存，关闭、重复唤起、保存失败与重启保留草稿；独立 `IdeaDraftParser` 保留正文换行，只共享分类 token scanner；
- 旧想法正文物理双击直接进入原位编辑；`⌘Enter` 保存、`Esc` 取消、失焦保存，错误留在当前条目；
- 「最近」与「回看」是分开的集合，回看默认排除最近七天并可刷新；搜索改为按需展开，匹配正文、分组名与标签名，收起时同步清除查询，不留下不可见过滤条件；
- 宽窗为可读宽度时间线＋右侧检视栏，窄窗为单列连续流；行呈现仍由独立 `IdeaCardView` 承载；
- 既有置顶、分组／标签过滤、删除／恢复能力保持，不因搭骨架而发生功能损失；
- 年度 Demo 机器报告确认存在可回看的旧想法，并在真实 Demo App 中对账宽屏布局、搜索、回看、检视与回收站；隔离 Idea E2E 另行在两条 memo 的连续流中对账窄窗布局，并覆盖多行正文、三种编辑退出语义、搜索收起和跨进程草稿恢复。

本轮刻意没有宣称完成归档、保留原文的软回收、永久删除或转任务。这些涉及 schema／sync 的目标设计继续留在后续 P 级切片，必须在 storage、sync 和真实症状门禁齐备后 cutover。单条 memo 当前只是一版干净可用的基线；下一轮将单独讨论信息层级、排版、元数据节奏、hover／选中反馈和详情联动，不改写本轮 session 与集合骨架。

## 现状证据

当前 `ff86af0` 实现的隔离想法 E2E 在单一 `e2e` profile 下可以通过，证明 CRUD、SQLite 和热键路径能运行，但不证明产品体验成立。

源码与真实 App 截图确认：

- 页面长期被大面积空 composer 和常驻 substring 过滤框占据，正文在超宽内容区中缺少稳定阅读宽度。
- 全局浮窗使用单行 `TextField` 和 `Enter` 提交，页面却使用多行编辑器和 `⌘Enter` 提交；两处语义漂移。
- 全局浮窗下一次显示会清除未提交草稿，并使用不建议继续采用的强制 App activation。
- 想法正文没有双击手势；进入编辑的唯一 UI 路径藏在溢出菜单。
- 规格声称既有想法可重新归类，但 App 没有调用 `setIdeaClassification` 的编辑入口。
- 未知 `#标签`／`@分组` 会阻断提交；分类认知负担被前置到捕获时。
- 时间线只有最近日期、substring 和单一分类过滤，没有独立单条查看、回看、关联或转任务路径。
- 删除会清空正文，所谓恢复要求用户重新写一遍已经删除的内容，不构成真实恢复。

竞品与平台证据见 `docs/research/idea-capture-redesign-20260803.md`。

## 设计

### 1. 深 module 与 seam（目标设计，分阶段实现）

#### `IdeaWorkspace` module

`NoonmarkCore` 内建立一个深 module，外部 interface 只暴露用户意图和可呈现投影：

```swift
func performIdeaAction(
    _ action: IdeaAction,
    today: LocalDate,
    now: Date
) throws -> IdeaActionReceipt

func ideaCollection(
    _ query: IdeaCollectionQuery,
    calendar: Calendar
) -> IdeaCollectionProjection
```

`IdeaAction` 表达捕获、修订、替换标签、归档／恢复、移入回收站／恢复、永久删除和转任务。module 的 implementation 隐藏正文归一化、行内标签解析与原子标签建立、生命周期不变量、回看抽样、任务落点、双向来源关系和重复转换检查。调用方与测试都只跨同一个 seam，不再让页面、浮窗和 `NoonmarkStore` 分别拼接规则。

`IdeaCollectionQuery` 表达 `.recent`、`.search(text:)`、`.label(id:)`、`.review(seed:count:excludingRecentDays:)`、`.archived` 和 `.trash`。回看是纯投影，不写事实；测试注入固定 seed，真实使用每次刷新产生新 seed。

#### `IdeaComposerSession` module

Mac runtime 建立一份由页面和全局浮窗共享的 composer session。interface 只接收 `updateText`、`submit`、`dismiss` 和 `clear` 意图，并投影正文、标签候选、提交状态与错误。草稿持久化 seam 由两个 adapter 证明其真实性：production 使用 profile 隔离的 `UserDefaults` adapter，测试使用 in-memory adapter。

草稿不进入任务数据库、数据包或同步。保存成功才清空；失败、关闭、失焦与重启都保留。诊断只记录强类型结果码和长度区间，不记录正文或标签名。

#### `IdeaInlineEditorSession` module

单一 editor session 负责当前编辑条目的原文、草稿、save generation 与错误。双击正文进入；`⌘Enter` 立即 flush，`Esc` 恢复原文，失焦触发同一保存路径。后到的旧 generation 不得覆盖新内容。保存失败时 session 不退出，用户正文留在内存与可恢复草稿中。

### 2. 领域模型

重做后的 `IdeaEntry`：

```swift
public struct IdeaEntry {
    public let id: IdeaID
    public private(set) var body: String
    public private(set) var labelIDs: [TaskLabelID]
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var archivedAt: Date?
    public private(set) var trashedAt: Date?
    public private(set) var deletedAt: Date?
}
```

不再保存 `categoryID` 或 `pinnedAt`。活动、归档、回收与内部墓碑互斥：

- 活动：三个时间均为空，出现在最近／搜索／标签／回看。
- 归档：`archivedAt` 非空，正文与标签完整，只出现在归档集合和明确包含归档的搜索。
- 回收：`trashedAt` 非空，正文与标签完整，只出现在独立回收站，可原样恢复。
- 墓碑：`deletedAt` 非空，正文与标签清空，不进入任何用户内容集合，但继续参与同步收敛。

新增 append-only `IdeaTaskLink`：稳定身份、`ideaID`、`taskChainID` 与 `createdAt`。默认转换只建立一个任务；用户明确再次转换可追加关系。关系进入 SQLite、snapshot、数据包和同步，不把 `convertedToChainID` 单值塞回 `IdeaEntry`。

### 3. 主窗口信息架构

稳定骨架只有五个动作：

1. 写：紧凑、可自然增高的 composer。
2. 看：正文优先的最近时间线。
3. 找：搜索或标签把当前集合替换为结果集合，并清楚显示条件。
4. 回：独立回看模式展示少量旧内容。
5. 做：从当前条目原位编辑、归档、删除或转任务，完成后回到原浏览位置。

页面不常驻回收站，不把全部功能并排做成 toolbar，也不为每条想法叠加描边卡片、徽章、图标、尾箭头与说明文字。正文列保持稳定可读宽度；超宽窗口把多余空间用于留白、检视或导航，而不是拉长文本行。

### 4. 转任务

确认面字段：任务标题、落点（任务池／今天／未来日期）和原想法只读来源摘要。默认标题取首个非空行，用户可改。确认时由 `IdeaWorkspace` 在同一个 `NoonmarkEngine` candidate 中：

1. 建立任务池任务；
2. 必要时排到今天或未来日期；
3. 建立 `IdeaTaskLink`；
4. 校验完整 snapshot；
5. 由现有 `commitEngineMutation` 原子写入 SQLite 与 sync outbox。

不经过烛龙或 Provider。后续 AI 拆解只能建立可审查草稿，不能替代本地基本转换。

## Throwaway UI prototype

### 要回答的问题

在真实晷迹侧边栏、年度中段数据密度和亮色视觉语言中，哪一种页面骨架最适合连续捕获、扫读、双击原位编辑、搜索／标签浏览、回看和转任务？

prototype 提供三个结构差异明显的 variant，并以 URL `?variant=A|B|C` 与底部浮动切换条比较：

- A／连续流：单一居中窄列，紧凑 composer、最近时间线与模式化搜索／回看，最接近 flomo。
- B／时间线＋检视：左侧可扫读时间线，右侧显示当前条目的完整内容、标签与任务来源，最适合 Mac 宽屏查看。
- C／内层导航工作台：想法区内以“最近／标签／回看／归档”轻量导航切换集合，composer 固定在内容区底部，强调 Thino 式连续处理。

三个 variant 必须都能在内存中演示：双击原位编辑、`⌘Enter` 保存、`Esc` 取消、搜索、标签切换、回看刷新和转任务确认；不得接真实 mutation 或持久化。

### 像素级 prompt

复刻当前真实晷迹 Mac App 的 2048×1280 亮色窗口壳：左侧 364 px 固定侧边栏、1 px `#E7E7E8` 分隔线、主体 `#FCFCFD`，侧边栏分组与图标位置沿真实 demo 截图；“想法”保持浅蓝 `#EEF4FF` 选中底。主体内容从 x=398 开始，标题区顶部 28 px，标题 26 px／semibold，辅助文字 14 px／regular、灰 `#747780`。禁止暗色首页、装饰性渐变和大面积彩色卡片。

想法正文使用 14–15 px、行高 1.55、颜色 `#202124`；时间与次要元数据 11–12 px、`#7A7D85`。日期分隔以文字、留白和最多一条 1 px 线建立层级。默认不显示卡片外框；hover 只出现低对比背景与必要动作。composer 初始高度约 76–96 px，获得焦点后随内容自然增高，圆角 10 px，只有一层 `#E4E6EA` 描边；搜索不与 composer 永久叠成两个大输入框。

双击正文后在完全相同的 x、宽度和近似高度上替换为无跳动 editor；不改变前后条目的 y 位置超过一行。编辑态显示低强调保存状态，`⌘Enter` 保存、`Esc` 取消；三点菜单保持辅助。底部 prototype switcher 使用高对比黑色 pill，左右箭头切换 variant，输入框聚焦时不拦截方向键，production 不存在该控件。

### Prototype 运行结果与建议

A／B／C 三个 variant 曾在 2048×1280 无头 Chrome 运行，并由 `?smoke=1` 自动触发真实 DOM 事件；它们只使用静态页面与内存状态，从未读取或写入任何 Noonmark profile。三个 variant 均通过以下路径：

- 双击正文进入原位编辑；
- `⌘Enter` 保存；
- `Esc` 放弃修改；
- editor 失焦后安全保存；
- 多行 composer 以 `⌘Enter` 捕获。

用户已确认以 B「时间线＋检视」作为 Mac 宽屏主骨架，以 A「连续流」作为窄窗折叠形态。B 同时保留扫读上下文和单条阅读／行动空间，最能补足原有“只能看一列 CRUD 卡片”的缺口。C 的集合导航只吸收为浏览模式入口，固定底部 composer 没有进入 production。选型结论已吸收进正式 SwiftUI 实现，一次性 prototype 与 variant switcher 已按 throwaway 纪律删除。

## 风险、灰度、回滚与监控

### 风险

- 数据与同步：新增软回收状态和多值任务关系，LWW 与墓碑竞争必须由乱序／并发运行证据覆盖。
- 标签：自动建立共享标签可能污染任务词汇；首版只在用户明确输入完整 `#标签` 时建立，并在 demo 年度故事中验证任务与想法共同使用。
- 编辑：失焦 autosave、手动提交和重启可能竞争；generation fence 与持久化失败门禁必须先红后绿。
- 性能：年度 1,000 条想法下，全部内存重算可能造成输入和滚动卡顿；查询投影需要稳定排序和可测预算。
- 转任务：重复点击、部分写入或同步晚到可能产生重复链；原子 relation 与重复转换确认是硬边界。

### 灰度

当前功能只在未 push 的 feature branch，尚无 production 资料迁移授权。灰度顺序固定为：throwaway prototype → 用户选定骨架 → `demo` profile 完整纵向切片 → `e2e` profile 症状门禁 → production package 静态门禁。任何阶段都不启动 production App，不做双写或隐藏旧 UI 的半切换。

### 回滚

生产实现以原子 commit 为回滚边界。若新 schema 或同步语义尚未全绿，回滚代码并对指定非生产 profile 执行 clean cut；不得让旧二进制读取新开发数据库。prototype 选型完成后删除全部 variant 和 switcher，只把结论吸收进正式实现。

### 监控

只增加有界强类型诊断：composer 草稿恢复结果、想法 mutation 结果码、inline edit save generation 结果、查询耗时桶和转任务 operation／relation 结果。不得记录正文、标签名、搜索词、任务标题或任何自由文本。

## 验证设计

- Fast gate：`IdeaWorkspace` interface 测试覆盖生命周期、标签原子建立、稳定排序、回看、转任务和墓碑；composer／editor session 测试覆盖草稿、提交键、失焦与 generation fence。
- Storage／Sync：schema round-trip、数据包、乱序／并发、软回收恢复原文、永久删除不复活、`IdeaTaskLink` 收敛。
- Symptom gate：真实 `.app` 物理双击正文原位编辑，`⌘Enter` 保存、`Esc` 取消、点击别处 autosave、失败保留正文和重启回读。
- Capture gate：Finder 中唤起全局 panel，多行腾讯拼音、草稿关闭／重启恢复、保存后焦点交还；页面与 panel 提交语义一致。
- Browse gate：一年 1,000 条以上想法下验证最近、搜索、标签、回看、归档与回收站，并对账 SQLite 与投影。
- Action gate：无 Provider 环境下把想法分别转到任务池、今天和未来；任务与想法双向跳转，重复转换明确提示，SQLite 与 sync relation 对账。
- Demo：更新年度用户故事、机器报告、真实截图和 `docs/engineering/interactive-demo-fixture.md` 覆盖表。
- Release：production DMG 只跑静态门禁；需要交互时只运行受控派生的 `dmg-validation` App。

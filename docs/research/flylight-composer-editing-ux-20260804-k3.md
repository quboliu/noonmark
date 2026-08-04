# 飞光 Composer、编辑与浏览体验重审（K3 独立稿）

- 调研日期：2026-08-04
- 调研范围：飞光的新建、旧条目编辑、有限 Markdown、分类、时间线、详情栏、Sticky Note 上下文及相关视觉反馈
- 工作边界：只做研究与设计，不修改产品代码，不把参考截图直接当成需要逐像素复刻的 ground truth
- 结论标记：**事实**来自用户材料、当前源码、当前真实 Demo 截图或一手产品资料；**建议**是本稿提出的设计取舍；**推断**是由多个事实推导、但仍需真实 App 交互验证的判断

## 结论摘要

当前飞光已经有合格的领域骨架：共享持久草稿、`⌘Return` 保存、双击原位编辑、Markdown 储存与渲染、分类 scanner、可收起详情栏、Sticky Note 精选投影都已经存在。问题不在于“少画了两个漂亮按钮”，而在于新建、全局速记、旧条目编辑仍是三套不同的产品表面；它们只复用了底层纯文本 `MarkdownEditor`，没有复用一个完整的 composer 工作流。

因此，用户感受到的是一个“有输入框、有保存函数”的工程实现，而不是成熟的记录产品：

1. 页面新建框没有可见主动作、格式入口或状态区；能力藏在 placeholder 和快捷键里。
2. 旧条目编辑把 11pt 无描边文字按钮放在编辑器外，动作区没有容器、层级和状态，确实像临时工程控件。
3. 新建可以用 `#`／`@` 选择分类，旧条目编辑只能改正文，两个阶段能力不对等。
4. `saving`、`empty`、`failed` 状态虽然已经进入 session，但大多没有被界面消费；成功状态也会立即回到 `idle`。
5. Markdown 是“纯源码输入 + 发布后渲染”，已有快捷键却没有发现入口、列表续写或格式菜单，用户很难理解实际支持边界。
6. Sticky Note 能跳回源飞光，但会清空当前过滤且没有返回上下文；它仍像另一个列表，不像对源内容的可追溯精选视图。

**建议的根本解**是建立一个共享的 `FlylightComposerSurface`：同一个有完整动作栏、格式入口、分类入口、验证与保存状态的 composer shell，以配置模式适配“页面新建／全局速记／原位编辑”。新建与编辑只改变主按钮文案、取消语义和尺寸，不改变控件位置与能力模型。动作区必须是本轮第一优先级，不应等到 Markdown 或卡片美化之后再补。

## 证据来源与限制

### 用户提供材料

用户提供的压缩包经先列内容、校验无绝对路径、`..` 路径或 symlink 后解压到隔离临时目录。归档 SHA-256 为 `6cb2fc316111805150b61bd6d5268050eba71c646e6577cc7d2a25cd309e4f9d`，包含一份 Markdown 和四张界面截图。本文只记录画面可见事实，不从截图反推未知产品、账号级别或隐藏行为。

四张截图（下称 A、B、C、D）显示：

- **A（空 composer）**：输入区与底部动作区属于同一个描边表面；caret／placeholder 在内容区顶部，左下是标签、附件等工具，右下是次动作与高强调主动作。
- **B（旧条目编辑）**：编辑态仍沿用与新建相同的 composer 几何；焦点以整体描边表达，底部明确出现取消编辑与主动作，正文、链接、工具栏和动作区没有被拆散。
- **C（空 composer 的另一种形式）**：底部工具包含 `#`、图片、`Aa`、无序列表、有序列表、`@`，主动作固定在右侧；输入区保持大块安静空间。
- **D（同一 composer 的编辑态）**：控件位置基本不变，只新增字数、取消与激活后的主动作。编辑模式是同一表面的状态变化，不是另一套表单。

这些截图共同支持一个结构性结论：成熟感主要来自“同一 surface 内稳定的内容区、工具区、状态区和主动作区”，不是来自更厚的阴影或更多卡片。

### 仓库与运行产物

- 当前产品规格：[idea-capture-spec.md](../product/idea-capture-spec.md)
- 当前领域语言：[CONTEXT.md](../../CONTEXT.md)
- 飞光页面实现：[IdeasPage.swift](../../App/NoonmarkMacApp/IdeasPage.swift)
- 编辑器实现：[MarkdownEditing.swift](../../App/NoonmarkMacApp/MarkdownEditing.swift)
- session 实现：[IdeaCaptureSessions.swift](../../Sources/NoonmarkMacRuntime/IdeaCaptureSessions.swift)
- 飞光 mutation：[NoonmarkStore+Ideas.swift](../../App/NoonmarkMacApp/NoonmarkStore+Ideas.swift)
- 全局速记：[NoonmarkIdeaCaptureWindowController.swift](../../App/NoonmarkMacApp/NoonmarkIdeaCaptureWindowController.swift)
- 共享详情栏：[WorkspaceDetailRails.swift](../../App/NoonmarkMacApp/WorkspaceDetailRails.swift)
- Sticky Note 页面：[StickyNotesPage.swift](../../App/NoonmarkMacApp/StickyNotesPage.swift)
- 当前真实 Demo 飞光截图：[task-collection-ideas.png](../../artifacts/interactive-demo/task-collection-ideas.png)

运行截图能证明当前成品的可见层级，但没有覆盖编辑中的瞬间状态；保存／取消竞态仍须真实 App 自动化验证，不能只凭静态读源码定性。

### 一手参考产品资料

- flomo 官方资料已经在仓库研究稿中核对：[flomo-memo-editor-20260803.md](./flomo-memo-editor-20260803.md)。flomo 明确不支持 Markdown，而是加粗、高亮、下划线、两类列表、标签和 MEMO 引用等有限富文本；电脑端支持双击旧 MEMO 编辑。因此“对标 flomo”不等于照搬 Markdown，但其低摩擦入口、直接编辑和小型格式集合值得借鉴。
- Thino 的产品文档说明其编辑器继承 Obsidian 所见即所得编辑器，选中文字可出现悬浮格式工具条，输入 `#` 可出现标签选择，并列出标题、列表、任务列表、加粗、斜体、下划线、高亮、链接、引用、代码块、callout 与表格等支持项。[Thino 编辑器文档](https://pkmer.cn/Pkmer-Docs/10-obsidian/obsidian%E7%A4%BE%E5%8C%BA%E6%8F%92%E4%BB%B6/thino/01_thino-%E5%9F%BA%E7%A1%80%E4%BD%BF%E7%94%A8%E6%95%99%E7%A8%8B/thino-%E7%BC%96%E8%BE%91%E5%99%A8/)
- Memos 官方仓库把产品定义为 Markdown-native、timeline-first 和 quick capture；其 0.30.0 发布说明明确称重建了 Markdown editor。它证明“快速记录”和“认真做编辑器”并不冲突，但不代表晷迹必须复制 Memos 的附件、语音、可见性或社交能力。[Memos 官方仓库](https://github.com/usememos/memos) [Memos 0.30.0 发布说明](https://github.com/usememos/memos/releases/tag/v0.30.0)

## 当前实现的事实审计

### 创建与发布

**事实：**页面 composer 只有 `MarkdownEditor`、分类建议和一个多分组错误提示，没有可见的“记录／发布”按钮、格式入口或保存状态区。用户只能从 placeholder 得知 `⌘Return`。[IdeasPage.swift:261](../../App/NoonmarkMacApp/IdeasPage.swift#L261)

**事实：**页面与全局速记共享 `IdeaComposerSession` 和本机持久草稿。只有保存成功才清空；关闭全局窗会再次保存当前草稿。这一可靠性骨架应该保留。[IdeaCaptureSessions.swift:69](../../Sources/NoonmarkMacRuntime/IdeaCaptureSessions.swift#L69)

**事实：**全局速记另有一套标题、说明、独立输入框和底部原生按钮；主按钮是 `.borderedProminent`，取消按钮在 composer surface 外。它比页面 composer 多一套动作，但与旧条目编辑仍不一致。[NoonmarkIdeaCaptureWindowController.swift:201](../../App/NoonmarkMacApp/NoonmarkIdeaCaptureWindowController.swift#L201)

**事实：**创建 session 有 `.idle／.saving／.empty／.failed`，但页面没有显示这些状态；成功后立即清空并回到 `.idle`。全局失败主要通过 beep 与全局错误处理表达。[IdeaCaptureSessions.swift:58](../../Sources/NoonmarkMacRuntime/IdeaCaptureSessions.swift#L58)

### 双击编辑、保存与取消

**事实：**旧条目正文已经支持双击原位编辑，三点菜单只是辅助入口，这一点与用户最初硬要求一致。[IdeasPage.swift:499](../../App/NoonmarkMacApp/IdeasPage.swift#L499)

**事实：**编辑态用同一个 Markdown 输入 primitive，也支持 `⌘Return` 保存、`Esc` 取消和失焦保存；失败时会保留 editor 并显示一行错误。[IdeasPage.swift:532](../../App/NoonmarkMacApp/IdeasPage.swift#L532)

**事实：**当前“保存／取消”是两个 11pt、无描边的 `NSButton` 文本动作，位于编辑器下方、左对齐。它们没有最小触控尺寸、容器背景、键盘提示、spinner、成功态或失败重试形态。[TaskNoteInteractionControls.swift:180](../../App/NoonmarkMacApp/TaskNoteInteractionControls.swift#L180)

**推断（必须验证）：**编辑器把任何 `textDidEndEditing` 都当成保存，而“取消”按钮位于 editor 外。点击取消通常会先引发焦点离开，再触发按钮 action；若 AppKit 事件顺序如此，显式取消可能先保存后取消。源码不足以证明真实顺序，但这个设计已经存在语义冲突，必须用真实鼠标点击和 SQLite 回读做红绿测试。[IdeasPage.swift:623](../../App/NoonmarkMacApp/IdeasPage.swift#L623)

### Markdown 与格式能力

**事实：**`MarkdownEditor` 实际是 `isRichText = false` 的原生 `NSTextView`。保存的是 Markdown 源码，不是 WYSIWYG 富文本。[MarkdownEditing.swift:96](../../App/NoonmarkMacApp/MarkdownEditing.swift#L96)

**事实：**已有键盘格式命令：`⌘B` 加粗、`⌘I` 斜体、`⌘E` 行内代码、`⌘K` 链接；`Shift+Return` 插入 Markdown hard break，`Option+Tab` 插入四个空格。这些能力完全没有可见发现入口。[MarkdownEditing.swift:759](../../App/NoonmarkMacApp/MarkdownEditing.swift#L759)

**事实：**显示 renderer 支持 H1–H6、普通段落、无序／有序／任务列表、引用和 fenced code；行内部分交给 Swift `AttributedString` 的完整 Markdown 解释。当前 block parser 没有嵌套列表、表格、图片、语言化代码块或 callout 的完整语义。[MarkdownEditing.swift:998](../../App/NoonmarkMacApp/MarkdownEditing.swift#L998)

**建议：**产品文案应从宽泛的“支持 Markdown”收窄为有测试矩阵的“有限 Markdown”。附件、语音、表格、callout、数学公式和任意 HTML 不应因参考产品有图标就被假装支持。

### 分类与标签

**事实：**新建时，`#标签` 与 `@分组` 会从正文中解析并移除，分别储存在独立分类字段；Markdown heading、代码、转义字面量、链接目标和 URL 有保护规则。当前只允许解析到既有分类目录，未知名称会阻止提交。[NewTaskDraftParser.swift:83](../../Sources/NoonmarkMacRuntime/NewTaskDraftParser.swift#L83)

**事实：**页面新建会在 active token 存在时显示最多六个建议，但建议清单是放在整个编辑器下方，不是锚定 caret 的 popover。[IdeasPage.swift:301](../../App/NoonmarkMacApp/IdeasPage.swift#L301)

**事实：**旧条目编辑 session 只加载 `idea.body`，保存也只调用 `editIdea(id:body:)`；现有分组／标签不会进入编辑器，也不能从这条路径更改。新建与编辑明显不对等。[NoonmarkStore+Ideas.swift:282](../../App/NoonmarkMacApp/NoonmarkStore+Ideas.swift#L282)

### 时间线、卡片与详情栏

**事实：**时间线已经按自然日分组、按创建时间倒序，以单条 divider 分隔；正文是 Markdown，元数据一行显示时间、可点击分类和常驻三点菜单。选中态只有浅背景。[IdeasPage.swift:455](../../App/NoonmarkMacApp/IdeasPage.swift#L455)

**事实：**真实 Demo 截图显示信息架构已清楚，但 composer 只有一个窄空框，所有能力都写进 placeholder；大量条目右侧重复出现三点，详情栏又完整重复正文，并用两条蓝色纯文字动作收尾。这正是“逻辑可用、产品完成度不足”的视觉来源。

**事实：**详情栏已经进入共享可收起 rail，并显示正文、记录时间、分类、编辑及 Sticky Note 动作。当前没有更新时间、编辑状态、来源上下文或动作反馈。[WorkspaceDetailRails.swift:970](../../App/NoonmarkMacApp/WorkspaceDetailRails.swift#L970)

### Sticky Note 上下文

**事实：**Sticky Note 的清单流／便签墙共用同一个内容组件；双击或菜单会调用 `openIdeaInFlylight`，移出也只改变精选关系。这符合“投影而不是副本”的领域定义。[StickyNotesPage.swift:178](../../App/NoonmarkMacApp/StickyNotesPage.swift#L178)

**事实：**跳回飞光时会清空搜索和分类过滤、切回最近并选择源条目。它能保证源条目可见，却没有保存“从 Sticky Note 来”的返回上下文，也没有“在飞光中编辑”这个直接意图。[NoonmarkStore+Ideas.swift:373](../../App/NoonmarkMacApp/NoonmarkStore+Ideas.swift#L373)

## 结构性差距

### 1. 复用了文本框，没有复用产品工作流

当前共享的是 `MarkdownEditor`，但三个入口分别自行决定 surface、按钮、错误、焦点和关闭行为。参考截图真正值得学习的是 mode-stable shell：同一个表面从空白、输入、编辑、保存中到错误，工具和动作的位置始终可预测。

### 2. 动作区既缺视觉层级，也缺状态语义

当前编辑按钮是无边界文字链接；页面新建甚至没有主按钮。用户不能一眼回答：

- 当前是在新建还是编辑？
- 这次修改有没有保存？
- 为什么现在不能发布？
- `⌘Return` 会做什么？
- 取消会关闭、保留草稿，还是丢弃修改？

这不是“换一个 ButtonStyle”能解决的问题，必须把动作区与 session state machine 一起设计。

### 3. 保存与取消存在冲突入口

显式按钮、快捷键、失焦、页面切换和条目消失都可能结束 editor。它们目前不是一个带原因的统一终止动作。只要 blur 与 cancel 竞争，就可能发生取消却保存、保存两次或失败后 editor 被移走。

### 4. Markdown 的支持边界不可见

源码模式本身没有错；问题是用户只看到“支持 Markdown”四个字。没有格式菜单、命令列表、列表续写、选区反馈和可验证子集时，现有能力等于隐藏能力，而不完整 parser 又会让“Markdown”承诺显得过度。

### 5. 分类是创建专属能力

新建会把 `#／@` 转成结构化分类，编辑却只改正文。用户编辑旧飞光时无法修正最常需要整理的分组和标签；这与“新建和编辑是同一 composer 的两种模式”直接冲突。

### 6. Sticky Note 的来源关系存在于数据层，没有成为导航体验

“在飞光中打开”能跳转，但会丢失原页面位置。用户完成修改后要自己寻找回去路径；从 Sticky Note 移出后条目立即消失，也没有就地撤销反馈。领域关系正确，交互闭环仍不完整。

## 建议方案：统一的 Flylight Composer Surface

### 组件边界

**建议：**建立一个共享产品组件，而不是继续给三处页面分别加按钮：

```text
FlylightComposerSurface
├── FlylightTextEditor             原生 NSTextView、IME、selection、Markdown command
├── FlylightClassificationDraft   当前分组、标签、active token、候选
├── FlylightComposerActionBar
│   ├── ClassificationActions     # 标签、@ 分组
│   ├── FormattingMenu            Aa：有限 Markdown 命令
│   ├── ComposerStatus             快捷键／验证／保存／失败
│   └── ModeActions                取消、记录／保存
└── FlylightComposerStateMachine  pristine、dirty、invalid、saving、saved、failed
```

页面新建、全局速记和原位编辑都使用这个组件，只通过 mode 配置高度、主动作与取消语义。底层创建／编辑 session 可以继续分开，但必须输出同一套可观察状态和 classification draft；不能让 View 自己拼保存逻辑。

### 三种模式的明确语义

| 模式 | 主动作 | 次动作 | 失焦 | `Esc` | 成功后 |
| --- | --- | --- | --- | --- | --- |
| 页面新建 | **记录**（`⌘↩`） | 不常驻取消；`…` 可明确清空草稿 | 草稿继续持久化，不发布 | 仅退出候选／格式菜单，不清空草稿 | 清空正文，原位短暂显示“已记录” |
| 全局速记 | **记录**（`⌘↩`） | **稍后继续**／关闭 | 窗口不因普通失焦丢草稿 | 关闭窗口并保留草稿 | 关闭窗口，回到先前 App |
| 旧条目编辑 | **保存**（`⌘↩`） | **取消** | 有效 dirty 草稿走安全保存；显式取消必须压制 blur save | 放弃本次修改并恢复原文 | 回到 Markdown 展示态，在卡片元数据处短暂显示“已保存” |

“记录”比“发布”更符合本地私有产品，不暗示公开可见；若产品最后坚持“发布”，只替换主动作文案，不改变状态模型和按钮层级。按钮不应写“记录飞光”，因为页面上下文已经说明对象，短动词更利落。

### 动作区的视觉与状态（核心要求）

**建议的视觉层级：**

- 动作区属于 editor 同一个圆角 surface，位于底部，不再漂在编辑器外。
- 左侧固定三个低强调入口：`# 标签`、`@ 分组`、`Aa 格式`。宽度不足时显示图标，但 tooltip 和 accessibility label 必须保留完整名称。
- `Aa` 菜单承载加粗、斜体、行内代码、链接、无序列表、有序列表、任务列表、引用和代码块。不要把九个按钮常驻铺开。
- 右侧为取消与主动作。主动作使用实色 accent、可读文字和 30–32pt 高度；取消用中性 tonal／plain surface，但仍有完整点击面积，不能退回 11pt 裸文字。
- `⌘↩` 提示位于主动作左侧或按钮 tooltip 中；编辑器聚焦时可见，不能只写在 placeholder。
- 错误、保存中与成功状态占用同一个状态槽，不推动整个时间线跳动。

状态必须至少有以下可见结果：

| 状态 | 主动作 | 状态槽 | 其他控件 |
| --- | --- | --- | --- |
| 空白 | disabled 的“记录／保存” | 不显示红色错误；tooltip 说明需先输入正文 | 分类与格式可用 |
| dirty、有效 | 激活的主动作 | `⌘↩ 记录／保存` | 全部可用 |
| invalid | disabled 或“修正后记录” | 就地显示具体问题，并提供跳到分组／标签的动作 | 问题相关入口高亮但不闪烁 |
| saving | spinner +“记录中／保存中” | “正在写入本机” | 防止重复提交；取消在原子 mutation 期间 disabled |
| saved | 回到展示态或清空；短暂 checkmark | “已记录／已保存”约 1 秒 | 不新增永久 badge |
| failed | 主动作变“重试” | “未保存，内容仍保留”+ 具体可行动原因 | editor 保持焦点和草稿，取消仍可用 |

不要用红色实心主按钮表示普通保存失败，也不要用全局 toast 代替 editor 内状态；toast 可以补充，但状态必须靠近发生动作的位置。

### 像素级实施 prompt

这是实现前可直接交给 UI 工程的第一版 prompt；尺寸应进入共享 contract token，不散落在 View 中：

> 在 760pt 最大可读宽度内，绘制亮色、无厚重卡片感的 Flylight composer。外层单一 8pt 圆角 surface，默认为 `controlFill`，1px `lineSubtle`；键盘或鼠标焦点时只把同一条描边换成 1.5px accent，不加第二层 glow。正文区左右各 12pt、顶部 11pt，caret 与 placeholder 共享原生 NSTextView 坐标；页面空态正文区最低 68pt、整体最低约 108pt，随内容增长至 176pt 后内部滚动。底部动作栏高 38pt，与正文区之间不画盒子，只用 1px 顶部分隔线或 8pt 留白二选一。左侧 `#`、`@`、`Aa` 每个最小 28×28pt，11.5pt medium，默认 text2、hover 使用 controlFillRaised；中间状态 11pt text3。右侧取消按钮至少 56×30pt、7pt 圆角、中性背景；主按钮至少 68×30pt、7pt 圆角、accent 实色、白色 12pt semibold，保存中保留宽度并以 12pt spinner 替换图标。原位编辑复用完全相同的动作栏与按钮位置，宽度跟随条目，背景只使用一个 selected/editing surface，不在条目外再套卡片。所有状态切换不得改变内容首行的 x/y 起点。

这份 prompt 吸收参考截图的稳定结构，但保留晷迹“减少视觉单位”的基调：只有一个 composer surface、一个动作栏和一个主动作，不复制附件、图片或社交可见性控件。

## 创建与旧条目编辑的统一细节

### 原位编辑

- 双击正文仍是首要入口，三点菜单保留给不熟悉双击和辅助技术用户。
- editor 在原条目宽度与滚动位置展开，正文切换为 Markdown 源码，底部动作栏原位出现；不要跳到右栏或模态表单。
- 单次只允许一个 inline editor。开始编辑新条目前，当前编辑必须明确保存成功、取消，或因失败留在原处；不得静默丢弃。
- 点击“取消”与按 `Esc` 必须走带 `.explicitCancel` 原因的统一终止动作，先标记 suppression，再结束第一响应者，确保 blur 不会抢先保存。
- blur 自动保存继续遵守现有规格，但只对 `.dirty + valid + notComposing` 生效。IME marked text、打开格式／分类 popover、点击 editor 自己的动作栏都不算离开 composer。
- 保存失败时 editor 不退出、原文不覆盖、按钮变为重试；详情栏的编辑入口切换为“返回正在编辑的条目”，避免启动第二会话。

### 分类／标签

- `# 标签` 与 `@ 分组` 是结构化入口，不只是往正文插字符。点击后在 caret 或按钮附近打开可搜索候选；键盘输入 `#／@` 仍是同一候选的 power-user 入口。
- editor state 同时携带 `bodyDraft`、`categoryDraft` 和 `labelDraft`。编辑旧条目时预载现有分类，保存正文与分类必须是一个 engine mutation／SQLite transaction。
- 正文中输入的分类 token 可以继续在保存时抽取，但当前选择要在动作栏以低强调文本摘要展示，例如 `@协作 · #交接`；不要堆叠实心 chip。
- 未知 token 不应等到用户按保存后才用 toast 拒绝。候选应明确显示“没有这个标签”；若要允许新建分类，必须另立显式“新建标签……”动作并复用分类领域命令，不能由自由文本静默建立。
- Markdown heading、代码、URL 和转义保护规则继续作为门禁，不能因新 UI 回退。

### 有限 Markdown

第一阶段建议正式承诺以下子集，并让编辑、显示、搜索纯文本和复制路径共用同一测试矩阵：

- 行内：加粗、斜体、行内代码、链接与裸 URL。
- 块级：H1–H3、普通段落、无序列表、有序列表、任务列表、引用、fenced code。
- 输入辅助：格式菜单、现有 `⌘B／⌘I／⌘E／⌘K`、列表自动续行、空列表项再次回车退出列表、选择多行后切换列表。
- 暂不承诺：表格、嵌套列表的完整 CommonMark 行为、图片内嵌、任意附件、callout、数学公式、HTML、脚注、语音。

选择源码模式而不是立即做 WYSIWYG，原因是现有数据已经是 Markdown，原生 NSTextView 与第三方中文 IME 已有成熟保护。后续可增加“选中文字才出现”的悬浮格式条或轻量语法弱化，但不得在 marked text 期间重写 attributed string。Thino 的所见即所得是方向参考，不是本轮必须复制的技术栈。

## 时间线与每条飞光的 UI

### 卡片信息层次

建议继续保持“无独立标题、正文优先、单 divider”的 note-first 结构，不把每条飞光包成描边卡片。提升完成度主要靠以下细节：

1. 正文使用统一 Markdown block rhythm；列表、引用、代码与段落之间有稳定间距，链接使用 accent 但不夺走正文权重。
2. 第二层元数据固定为“创建时间／必要时编辑时间 + 分组标签 + Sticky Note 状态”。更新时间只在确实编辑过时显示，不重复创建时间。
3. 已加入 Sticky Note 的条目用一个低强调、可访问的纸签符号或“Sticky Note”文字状态表示；不要再把它称为置顶，也不要新增彩色 badge。
4. 三点菜单默认在 hover、键盘焦点或 selected 时提高可见度；不 hover 时仍保留可访问命中区，避免当前整页重复黑点形成噪音。
5. selected 与 editing 使用同一背景体系：selected 是浅背景，editing 在此基础上用 composer focus border；不要叠加阴影、左色条和外卡片。
6. 卡片的 transient 保存／加入 Sticky Note 反馈放在元数据行，约一秒后消失；失败则保留到用户处理。

### 浏览与详情栏

- “最近／搜索／分类／回看”继续只显示一个主集合；当前集合要在 composer 下方用一行清楚表达，不新增多块卡片。
- 搜索应支持 `⌘F` 聚焦；`Esc` 先关闭候选／搜索，再处理页面级动作，避免与编辑取消冲突。
- 详情栏保留可收起共享 rail，但正文不是唯一价值。建议补充更新时间、结构化分类、Sticky Note 关系和当前编辑状态；动作使用一个主要“编辑”与一个次级 Sticky toggle，不再用两条等权蓝色链接。
- 选中长飞光时详情栏可完整展示，时间线仍保留全文而不强制截断。飞光是记录流，不应因右栏存在就把时间线降级成标题列表。
- 键盘支持：`↑／↓` 移动选中条目，`Return` 或 `Space` 打开详情，`⌘Return` 只在 editor 聚焦时保存，`Esc` 依层级退出；菜单动作都要有 accessibility label 与 help。

## Sticky Note 的转入、移除与跨页上下文

现有投影模型正确，不建议在 Sticky Note 内复制 editor。首版仍让飞光持有唯一编辑 session，但要补齐上下文：

- 飞光条目菜单和详情栏继续提供“加入／移出 Sticky Note”；selected／hover 时可以露出一个轻量快捷动作，提高发现性，但不能让每行常驻第二组按钮。
- Sticky Note 菜单改为三个清晰意图：“在飞光中查看”“在飞光中编辑”“移出 Sticky Note”。前两者共享源条目导航，编辑意图到达后直接进入唯一 inline editor。
- 导航时保存 transient `returnDestination = Sticky Note + presentationMode + scrollAnchor`。编辑完成或取消后，页头提供一次性“返回 Sticky Note”，不把它持久化进领域数据或同步。
- 当前过滤不应被永久销毁。为确保源条目可见，可以临时进入“单条来源”或最近集合；返回时恢复此前搜索／分类上下文。
- 移出 Sticky Note 后给就地“已移出 · 撤销”反馈。撤销复用现有有限 undo 能力；失败时条目不消失。
- 编辑源正文后，Sticky Note 两种视图必须立即读取同一对象；删除源条目后仍不可残留幽灵便签。

## 可访问性、输入法与反馈要求

- editor 必须有稳定 label（“飞光正文”）和 value；placeholder 只作 hint，不能同时冒充唯一 accessibility label。
- `#`、`@`、`Aa` 图标按钮必须有完整中文 accessibility label、tooltip 和选中状态；主动作保留文字，不做纯发送箭头。
- 保存中、成功、失败和分类错误要通过可访问状态区域宣布；不能只靠颜色、边框或短暂 toast。
- 最小操作尺寸 28×28pt，主／次动作 30–32pt 高；键盘焦点 ring 与鼠标 hover 都清晰。
- `Tab` 移到下一个控件，`Shift+Tab` 返回；缩进继续使用 `Option+Tab`，避免把普通 Tab 困在 editor。
- 中文 IME marked text 期间，`Return`、`⌘Return`、格式命令、候选 popover 与 reactive Markdown styling 都不得抢事件。页面新建、全局速记、旧条目编辑三处必须继续进入腾讯拼音真实输入矩阵。
- Reduce Motion 时，saved checkmark 直接淡入淡出，不做缩放、弹跳或位置移动。

## 分阶段实施方案

### Phase 0：冻结交互契约与红灯测试

先更新产品规格与代码化 UI contract，明确 shared surface、三种模式、动作状态、有限 Markdown 子集和分类编辑对等。建立真实 App 红灯：

- 点击“取消”绝不写入 SQLite。
- blur 保存失败后 editor 与草稿仍在。
- 页面新建当前没有可见主动作和格式入口。
- 编辑旧条目当前无法改变分类。

这一阶段不改 schema，也不启动 production。

### Phase 1：共享 composer 与动作区（最高优先级）

交付：

- `FlylightComposerSurface` 与共享 action bar。
- 页面、全局、inline 三种 mode adapter。
- 统一状态机与带原因的终止事件。
- 真正的主／次按钮、disabled／saving／saved／failed 视觉。
- `⌘Return`、`Esc`、blur 与按钮的确定性语义。

验收：同一条真实 Demo 飞光可双击进入、取消不变、再次进入保存成功、重启后 SQLite 正文正确；三个入口截图的内容首行和动作栏位置一致。

### Phase 2：有限 Markdown 与分类对等

交付：

- `Aa` 格式菜单与插入命令。
- 列表续写和退出列表。
- `#／@` caret 候选、旧条目 classification draft、正文＋分类原子保存。
- renderer／editor／copy／search 一致性矩阵。

验收：每项受支持 Markdown 在新建、编辑、时间线、详情栏、Sticky Note 中一致；未知分类在提交前可见；Tencent IME 全面通过。

### Phase 3：卡片、详情栏与 Sticky Note 闭环

交付：

- 卡片 hover／selected／editing／saved／failed 状态。
- 元数据层级与 Sticky Note 轻量状态。
- 详情栏新增更新时间、编辑状态与层级清楚的动作。
- Sticky Note 的查看／编辑源条目、返回上下文和移出撤销。

验收：从 Sticky Note 打开源条目、编辑、返回，原 presentation 与 scroll anchor 恢复；两种 Sticky Note 视图正文同步，移出／撤销无幽灵卡片。

### Phase 4：独立立项的高级能力

只有在领域、storage、sync、隐私和容量方案完成后，才考虑图片／附件、语音转写、引用飞光、版本历史、全屏／禅定模式或真正 WYSIWYG。不要先在 toolbar 画 disabled 图标，也不要把这些能力塞进本轮 UI 重构。

## 明确取舍

### 本轮应该做

- 同一 composer shell 覆盖新建、全局速记和旧条目编辑。
- 动作区视觉层级与完整状态反馈。
- 双击原位编辑、明确保存／取消、可靠 blur。
- 有限 Markdown 的可发现入口和一致渲染。
- 旧条目分类编辑，与新建能力对等。
- 卡片信息层次、详情栏动作和 Sticky Note 来源导航。

### 本轮不应该做

- 不复制参考截图里的附件、图片、提醒或语音图标。
- 不把 flomo 误写成支持 Markdown。
- 不为追求“高级感”给每条飞光加描边卡、色块图标、badge、尾箭头和多层阴影。
- 不在 Sticky Note 内建立第二套正文或 editor。
- 不在 reactive Markdown 装饰完成 IME 真实门禁前切换到 WYSIWYG。
- 不以全局 toast 冒充 editor 内保存状态。

## 验收标准清单

1. 页面空 composer 首行 caret 与 placeholder 同坐标，动作栏在同一 surface 底部，无无意义大空白或双层容器。
2. 新建与编辑的 `#／@／Aa`、状态槽和主动作位置一致；只有 mode 文案与取消语义变化。
3. 主按钮空白时 disabled、有效时激活、保存中防重入、失败时变重试；正文任何时候不因失败丢失。
4. 双击正文原位编辑；`⌘Return` 保存，`Esc` 与点击取消都恢复原文；点击取消的真实 App 路径 SQLite `updated_at` 与正文不变。
5. blur 只在有效 dirty、无 marked text、非显式取消时保存；失败保持 editor。
6. 新建与编辑都能增删分组／标签，并与正文在一个事务保存；Markdown heading、代码、链接和 URL 不被误分类。
7. 格式菜单每个命令都有快捷键／tooltip／accessibility label；受支持 Markdown 在时间线、详情栏和 Sticky Note 渲染一致。
8. 条目 hover、selected、editing、saved、failed 可区分，但不依赖颜色作为唯一信号；三点菜单不会整页形成高噪音。
9. 详情栏收起／展开不影响 inline editor 和未保存草稿；详情栏不会启动第二个编辑 session。
10. 从 Sticky Note 查看或编辑源条目后可返回原视图与滚动位置；移出可撤销，源飞光始终保留。
11. VoiceOver 能读出 editor、格式／分类动作、保存状态和错误；全键盘路径不需要鼠标。
12. 页面、全局速记和 inline editor 都通过真实腾讯拼音输入、候选、提交、立即退出与重启持久化门禁。
13. 最终以 `demo` profile 真实 `.app` 验收 empty／filled／editing／failed／saved／Sticky-return 六组状态；只有用户确认的真实 App 截图才能成为视觉 regression reference。

## 风险、回滚与监控建议

- **最大风险：**blur 与 explicit cancel 的竞态。先建立事件原因模型和症状级测试，再切换 UI。
- **输入风险：**格式与分类 popover 可能破坏 IME first responder。必须保持 AppKit marked-text 事件优先，不能用 SwiftUI 重建 text view 来刷新状态。
- **数据风险：**编辑分类需要新的原子 mutation seam，但不需要 schema 迁移；旧 `IdeaEntry` 字段已经具备正文、分类和标签。
- **切换风险：**旧三个表面不能在新 surface 尚未能力对等时提前删除。先让三种 adapter 全部通过同一 contract，再 cutover。
- **回滚：**本轮建议只重构 App UI／session seam，不变更 `idea_entries` 或 sync payload；若 UI cutover 失败，可回滚 adapter 并 clean-cut 非生产 profile。
- **监控：**只记录 bounded 的 composer mode、结束原因与结果枚举，以及保存耗时；不得记录正文、标签名、分组名、搜索词或 Markdown 片段。

## 最终判断

用户给出的参考材料应被理解为“稳定、完整、同构的 composer 体验”，不是“照着增加一排图标”。飞光下一轮最有价值的投入顺序应是：

1. 先重构共享 composer shell 和状态机；
2. 把发布／保存／取消做成真正的产品动作区；
3. 再补有限 Markdown 与分类编辑对等；
4. 最后统一卡片、详情栏和 Sticky Note 来源上下文。

只美化当前两个无描边文字按钮会很快再次返工。只有新建与编辑共用同一套内容、工具、状态和动作结构，飞光才会从“功能已经能用”跨到“每天愿意用”。

# 飞光 Composer、条目与浏览体验重做设计

- Task-ID：`noonmark-idea-capture`
- 等级：P
- 状态：用户已确认方案 A，正式实施中
- 日期：2026-08-04

## 用户确认

用户于 2026-08-04 确认浏览器原型中的 `A — 安静工作台` 作为正式实现方向。
确认范围包括顶部一体化 Composer、同一 surface 内的 Markdown 工具与主次动作、
双击旧飞光后的原位编辑、保存状态反馈、低噪音时间线和可收起详情栏。浏览器原型
只作为交互设计输入，真实验收仍以隔离 `demo` profile 的 SwiftUI `.app` 为准。

对应原型：`docs/design/prototypes/flylight-composer-2026-08-04/`

## 需求与成功标准

本轮不是替换两个按钮，而是重新设计一条飞光从捕捉到再次遇见的完整路径：

1. 用户在页面或全局速记中输入 Markdown，能够理解可用能力、当前状态与发布结果。
2. 用户双击旧飞光后，在原位置使用与新建对等的编辑能力；保存与取消清楚、可靠、好看。
3. 时间线条目适合连续扫读，同时保留时间、分类、Sticky Note 关系与低频操作。
4. 搜索、回看、详情栏和 Sticky Note 不再像几块临时拼接的功能，而是围绕同一条飞光形成连续导航。
5. 中文 IME、键盘、草稿、失败恢复、持久化与同步能力不得因视觉重做退步。

用户明确把「发布／取消像工程占位控件」视为阻断项。下一版不得使用裸文字、临时 `NSButton` 默认样式或与编辑器分离的动作行交付。

## 现状证据

### 用户参考材料

用户提供的四张参考图呈现了两类共同规律：

- 新建和修改都在一块完整 composer surface 内完成，而不是跳往独立表单。
- 编辑区上半部留给正文，下半部是稳定工具栏；标签、格式、列表、关联等工具在左，取消与发布在右。
- 主操作具有明确的填充色、尺寸与可用状态；取消是克制但完整的次操作，不是随手摆放的蓝色文字。
- 有内容时 composer 会增高，空态则不应制造与光标无关的假空白。

参考图只能证明交互形态，不证明晷迹必须照搬其中的附件、任务、日期或品牌颜色。

### 当前真实 App 与源码

当前实现已经具备正确的基础行为：持久草稿、Markdown 来源、双击原位编辑、`⌘Enter` 保存、`Esc` 取消、失焦保存、分类候选、失败保留和真实 App E2E。

完成度不足来自呈现与边界：

- 页面 composer 只是一个带浅色描边的 `MarkdownEditor`，没有可发现的格式工具、动作区或提交状态。
- 原位编辑直接把正文替换成通用 `MarkdownEditor`，再附上一行 `11pt` 无边框文字动作。
- `TaskNoteTextActionControl` 明确设置 `isBordered = false`，因此「保存／取消」天然只能呈现成两段工程化文字。
- 新建能从正文解析 `#标签`／`@分组`，旧条目编辑却只加载和保存正文，不能修正既有分类；两种场景能力并不对等。
- 原位编辑把 `textDidEndEditing` 作为保存入口，而取消按钮位于 text view 外；真实点击可能先触发 blur save 再触发取消。这是待真实 App 与 SQLite 验证的竞态假设，实施前必须先建立红灯。
- 全局速记使用另一套原生弹窗按钮；页面新建、全局新建和旧条目编辑没有共同的视觉语言。
- 三点菜单长期占据每行尾部；卡片、右侧详情栏和 Sticky Note 的动作呈现也不一致。
- 右侧详情栏再次展示正文，并用裸蓝色文字呈现编辑与 Sticky Note 动作，进一步放大临时拼装感。

### 一手产品证据

- flomo 的桌面列表支持双击编辑，`Enter` 换行，`⇧Enter`／`⌘Enter` 发布；它采用少量富文本能力，并明确不支持 Markdown。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html)
- flomo 会自动保留已发布内容的编辑版本；版本历史与未发布草稿不是同一能力。[flomo 历史版本](https://help.flomoapp.com/basic/history.html)
- Thino 2.1 起采用 Obsidian WYSIWYG editor，支持标题、列表、标签、链接、引用等 Markdown 能力；选择文字时可出现格式工具栏，保存使用 `Ctrl`／`Command + Enter`。[Thino Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/)
- Thino 明确把双击卡片定义为进入原位编辑，并以时间、正文、来源／置顶与菜单形成稳定信息顺序。[Thino Card](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card/)
- Memos 当前文档把 Markdown、inline edit、slash commands、标签建议、附件与本地草稿缓存列为同一 memo editor 的能力。[Memos](https://usememos.com/docs/usage/memos)

因此，晷迹继续采用 Markdown 是自身产品决策，不是对 flomo 的复刻；对标目标应是它的低摩擦与完成度，同时吸收 Thino／Memos 的 Markdown 原生编辑能力。

## 已收敛的产品决策

### 1. 建立一个共享 Flylight Composer Surface module

页面新建、全局速记和旧条目原位编辑共用同一个深 module，不再分别拼装。它的 interface 只暴露当前模式、可观察 presentation 与用户 intent，Markdown 命令、分类 draft、IME、保存状态和结束原因全部藏在 implementation 内：

```text
FlylightComposerSurface
├── Markdown editing canvas
├── classification / formatting affordances
├── inline issue or persistence status
└── action bar
    ├── contextual tools
    └── cancel + primary action
```

三种模式只改变文案、关闭行为和持久化 intent：

| 模式 | 主操作 | 次操作 | 成功后 |
| --- | --- | --- | --- |
| 页面新建 | 发布 | 收起；草稿保留，清除放入低频菜单 | 清空已发布草稿，时间线顶部出现新条目 |
| 全局速记 | 发布 | 稍后继续；关闭并保留草稿 | 关闭浮窗并把焦点还给原 App |
| 原位编辑 | 保存修改 | 取消 | 回到同一条目的阅读态和原滚动位置 |

不再使用 `TaskNoteTextActionControl` 作为飞光动作控件。底层 `NSTextView`、Markdown parser 与 IME 纪律可以复用，但 composer chrome、状态和动作必须由这个 module 统一拥有。

主动作采用用户已经建立的「发布」语言；它表示把草稿写入私有飞光时间线，不改变资料可见性。旧条目不用「发布」，明确写「保存修改」。

### 2. Markdown 原生，但不把语法门槛推给用户

正文继续以纯 Markdown 为唯一储存事实；编辑器同时服务两类用户：

- 熟悉 Markdown 的用户可以直接输入语法。
- 不熟悉语法的用户可以用工具栏和选择文字后的格式菜单完成常用操作。

下一实现阶段必须完整支持并对齐输入、显示、复制、搜索和编辑：

- 段落与换行；
- 加粗、斜体、行内代码与链接；
- 一至三级标题；
- 无序列表、有序列表与 checklist；
- 引用与 fenced code block；
- `#标签` 与 `@分组`，但 scanner 不得把 Markdown heading、链接目标、代码或 URL 误判成分类。

工具栏只暴露已经完整实现的能力。图片、通用附件、表格、LaTeX、脚注、录音与历史版本在有完整资料模型和验证前不得放置假入口。

首轮采用「Markdown 来源 + 选择感知格式命令 + 可靠渲染」；不以一个预览切换按钮冒充 live preview。类似 Obsidian 的真正 inline live preview 属于独立编辑器工程，需要在中文 IME、selection、undo 与粘贴行为都有实证后再 cutover。

### 3. Composer 的像素级结构

以下是实施的唯一设计 prompt；实际颜色从 `Theme` token 取得，不写死品牌截图色：

- 可读宽度继续与飞光时间线同轴，不额外套第二张卡片。
- 闲置空态总高 `64pt`；聚焦或有草稿时最少 `112pt`，随正文增长，`220pt` 后内部滚动。
- surface 使用 `12pt` 圆角、`Theme.panel`／`Theme.panel2` 底色和 `1pt Theme.lineSubtle`；聚焦时只把边界提升到 `1.5pt Theme.accent`，不得叠加外发光和第二层描边。
- 正文水平 inset `16pt`，顶部 inset `13pt`；placeholder 与 caret 必须共享 `NSTextView` 坐标，首行基线误差不超过 `1pt`。
- 动作栏高 `42pt`，与正文间只保留一条 `Theme.lineSubtle` 分隔线。动作栏不是另一张卡片。
- 左侧的第一层只保留 `#` 标签、`@` 分组和 `Aa` 格式三个入口，避免常驻图标堆砌；`Aa` 菜单提供加粗、斜体、链接、行内代码、标题、无序／有序／任务列表、引用与 code block。
- 每个工具命中区 `28 × 28pt`，默认无底色；hover 才使用 `Theme.controlFill`。不可用命令降低对比度并提供原因，不直接消失造成布局跳动。
- 右侧先放次操作，再放主操作；两者高 `32pt`，间距 `8pt`。
- 次操作使用 `Theme.controlFill`、`Theme.text2`、`8pt` 圆角和最多一条 subtle boundary；不得呈现成裸灰字或裸蓝字。
- 主操作使用 `Theme.accent` 填充、白色 `12.5pt semibold` 文字、`8pt` 圆角与 `14pt` 水平 padding；新建文案为「发布」，编辑文案为「保存修改」。允许使用一个 `paperplane.fill` 或 `arrow.up` 图标，但不得同时叠加图标、长文案和常驻快捷键徽章。
- 主操作 disabled 时使用 `Theme.controlFill` 与可读的 disabled 文本；saving 时原位显示小型 spinner 与「发布中／保存中」，宽度不得跳动；成功后显示短暂 checkmark，再自然收起或回到阅读态。
- failure 在动作栏上方显示一行明确错误和「重试」，草稿、selection 与焦点均保留；不能只发 toast。
- 动画遵守 Reduce Motion；Increase Contrast 时边界和文字必须达到既有 accessibility policy。

紧凑 wireframe：

```text
┌────────────────────────────────────────────────────────────┐
│ 现在在想什么？                                             │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ #  @  Aa                              [收起] [发布  ↑]     │
└────────────────────────────────────────────────────────────┘
```

原位编辑使用同一结构并保持条目宽度：

```text
┌────────────────────────────────────────────────────────────┐
│ 已有 Markdown 正文与当前 selection                         │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ #  @  Aa                         [取消] [保存修改  ↑]      │
└────────────────────────────────────────────────────────────┘
```

### 4. 输入与编辑状态语义

- `Enter` 始终换行；`⌘Enter` 发布或保存；`Esc` 取消编辑／关闭全局浮窗。IME 有 marked text 时快捷键先交给 AppKit 完成组合态。
- 新建草稿继续本机持久化，只有发布成功或用户明确清除才删除。
- 原位编辑维持单一 session。双击正文、辅助菜单或详情栏编辑都进入同一 session，不得出现两个编辑器。
- 所有结束路径必须带原因：`.submit`、`.explicitCancel`、`.blur`、`.navigation`。显式取消先压制 blur save，再结束 first responder；点击取消与 `Esc` 的真实 App 路径必须证明 SQLite 正文和 `updated_at` 均不改变。
- 失焦继续走同一安全保存路径，但只对 dirty、valid、非 marked-text、非 explicit-cancel 状态生效；若正文为空、分类无效或持久化失败，编辑器不得退出。
- 切换集合、搜索过滤或删除导致当前条目离开视图前，必须先完成同一安全保存判断；不能静默丢弃。
- 保存失败后主按钮恢复为可重试状态，错误留在当前 surface 内；成功后显示更新时间，但不改创建时间或时间线排序。
- editor draft 同时包含正文、分组与标签。编辑旧条目时预载现有分类，保存正文与分类必须进入同一个 engine mutation 与 SQLite transaction。

### 5. 飞光条目的信息层次

默认时间线继续减少视觉单位，不把每条内容装进重描边卡片：

1. 日期 header 是集合层次；条目本身不重复完整日期。
2. Markdown 正文使用 `14pt` 左右的主要文字、稳定行距和受控行长，是每条的第一视觉层。
3. footer 依次显示时间、分组、标签与可选 Sticky Note 状态；分类继续用文字关系，不改成一排彩色 pill。
4. 三点菜单只在 hover、selection 或 keyboard focus 时显现；其命中区始终存在并可被 VoiceOver 找到。
5. hover 只使用一层轻底色；selection 使用同一底色加明确但克制的 accent 边界，不再依靠多张卡片嵌套。
6. 长正文默认完整显示到合理上限，再提供「展开」；code block、列表和链接不能因截断破坏结构。
7. Sticky Note 关系可用 footer 中单个低噪音标记表达；加入或移出仍从菜单／详情 intent 执行，避免每行常驻多个按钮。

### 6. 详情栏与浏览连续性

- 详情栏保留全文阅读价值，但不得再次显示裸蓝色动作文字。顶部采用同一套 `32pt` 主次动作：编辑、加入／移出 Sticky Note；删除进入 overflow。
- 详情栏正文、创建时间、更新时间和分类形成连续阅读顺序；不存在的分类不生成空 section。
- 搜索和回看仍替换当前飞光集合，但页面必须清楚显示当前模式和一键返回「最近」。搜索展开不得把 composer 与时间线无缘由地大幅推移。
- 点击分类文字进入相应集合；清除条件回到进入前的稳定浏览位置。
- 从 Sticky Note 双击或选择「在飞光中打开」时，必须回到源条目、滚动定位并选中；不得新建副本或第二个编辑事实。

### 7. Sticky Note 同步打磨

本轮不重做 Sticky Note 的展示架构，但必须同步遵守条目内容和动作语言：

- 清单流和便签墙继续复用同一个 Markdown 内容组件。
- 菜单只承载「在飞光中打开／移出」，hover 与 focus 规则与飞光一致。
- wall 的纸张 surface 可以保留，但正文、metadata、menu 的内部节奏由共享 token 控制，不能成为第三套卡片。
- 后续新增纸张、堆叠或空间视图只替换 presentation adapter，不复制正文或 composer。

## 实施架构

建议以 deep module 方式重做，而不是继续在 `IdeasPage.swift` 内叠条件。它的 external seam 是一个小 interface：

```swift
@MainActor
final class FlylightComposerModel: ObservableObject {
    @Published private(set) var presentation: FlylightComposerPresentation
    func handle(_ intent: FlylightComposerIntent)
}

struct FlylightComposerSurface: View {
    @ObservedObject var model: FlylightComposerModel
}
```

三个调用者只需要建立对应 mode adapter，再把所有点击、键盘、blur 和 navigation 变成 intent；它们不需要理解 validation、submission ordering、cancel suppression 或 classification resolution。删除这个 module 时，这些复杂性会重新散落回三个调用点，因此这个 seam 能产生真实 leverage 与 locality。

implementation 内部结构：

```text
FlylightComposerSurface
├── FlylightComposerModel
│   ├── mode / draft / dirty state
│   ├── classification resolution
│   └── submission state machine
├── MarkdownCommandController
│   ├── selection-aware transforms
│   ├── list continuation / indentation
│   └── undo-preserving AppKit edits
├── FlylightComposerToolbar
└── FlylightComposerActionBar

FlylightEntryView
├── FlylightMarkdownContent
├── FlylightEntryMetadata
└── FlylightEntryIntentMenu
```

- 底层 `MarkdownEditor` module 只负责原生编辑、selection、IME 与尺寸，不拥有飞光产品动作。
- 页面、全局窗和原位编辑是真实存在的三个 adapter；它们适配现有 `IdeaComposerSession` 与 `IdeaInlineEditorSession`，保持 storage／sync 兼容。能力对等后才切换旧 view。
- Markdown command 是 implementation 的 internal seam，必须通过 AppKit responder／text storage 修改，形成正常 undo group；不得直接重写整段 binding 导致光标跳动。
- display、timeline、detail rail 与 Sticky Note 共享 `FlylightMarkdownContent`，避免支持语法漂移。
- 新的 composer button style 先属于飞光；若以后要推广到任务附言，必须单独验证，不能顺手改变全 App。

## 分阶段实施

### 阶段 A：完整 composer 与原位编辑

- 先以失败测试钉死三入口同一视觉状态机、主次动作、Markdown command、失败保留，以及「点击取消绝不写入 SQLite」。
- 完成 `FlylightComposerSurface`、selection-aware toolbar、发布／保存／取消状态。
- 让旧条目编辑加载并原子保存正文、分组和标签，与新建能力对等。
- 页面 composer、全局速记和旧条目编辑 cutover；新 module interface 测试取代旧调用点的浅层呈现测试，删除旧裸文字动作路径。
- 真实 App 验证中文 IME、快捷键、鼠标、失焦、失败和重启草稿。

### 阶段 B：条目、详情与浏览打磨

- 抽出共享条目内容和 metadata。
- 完成 hover／selection／menu 层次、长正文展开、详情栏动作和搜索／回看上下文。
- 同步校准 Sticky Note 两种视图。

### 阶段 C：独立增强项

以下不能塞进 A／B 后宣称顺带完成：

- 真正的 Markdown inline live preview／WYSIWYG；
- 图片和通用附件；
- 已发布版本历史与恢复；
- memo 引用／双链、link preview、语音与 Web clipper。

这些能力各自涉及资料模型、同步、导出、隐私和失败恢复，必须另立需求与验证契约。

## 验证门槛

### Fast gates

- 三种 composer 模式共用同一个 action bar 和 button style。
- 不再存在飞光对 `TaskNoteTextActionControl` 的调用。
- Markdown 支持矩阵在 editor command、renderer、copy/search 与 tests 中一致。
- 空、dirty、saving、failed、success 状态转换可确定性测试。
- 标签／分组 scanner 对 heading、code、link、URL 与 escape 的反例通过。

### 真实用户路径

- `make run-demo-app` 的一年资料中，以真实鼠标双击旧条目进入原位编辑，并点击可见「保存修改」和「取消」各一次。
- 页面新建与全局速记都点击可见「发布」，并验证 `⌘Enter`；marked text 期间不得误发。
- 使用工具栏完成加粗、链接、三类列表、引用与 code block，保存后时间线、详情栏和 Sticky Note 渲染一致。
- 模拟持久化失败，确认草稿、selection、焦点、错误和重试入口留在原处。
- `1200 × 768pt`、`960 × 720pt`、详情栏展开／收起和长滚动资料下均无碰撞、裁切或浮动控件漂移。
- 验证 keyboard focus、VoiceOver identifier、Increase Contrast、Reduce Motion 与 Reduce Transparency。

### 视觉验收

- 真实 Demo App 至少截取：空 composer、聚焦 composer、有内容／工具栏、inline edit、saving、failure、普通条目 hover、selected + detail rail、Sticky Note stream／wall。
- 用户提供的图片仅作设计输入，不直接成为 pixel golden；只有用户确认新的真实 App 截图后才可建立 visual regression reference。
- 当前环境没有 `frontend-verify` skill，实施时以真实 `.app` WindowServer 交互、CGWindow 几何、截图、accessibility tree 和 SQLite 回读补齐。

## 风险、灰度与回滚

- **IME 风险**：格式命令、selection 和 `⌘Enter` 可能打断 marked text。所有 command 必须经过真实腾讯拼音 matrix，不接受脱离窗口的 `NSTextView` probe 冒充。
- **资料风险**：原位编辑状态重做可能造成误保存或丢稿。旧 session 与 mutation 保留到新路径能力对等，cutover 前以同一资料做跨引擎对账。
- **视觉风险**：动作栏和 toolbar 容易变成图标堆砌。每个常驻元素必须对应直接编辑能力；低频项进入 `Aa` 菜单或 overflow。
- **回滚**：新 composer 和条目 view 通过 adapter 接现有领域／储存，不改 schema；回滚 view cutover 不删除或迁移飞光资料。
- **灰度**：只在 `demo`、`e2e` 与 `audit` profile 验证，用户确认 Demo 后再考虑发行；不得启动或探测 production。
- **诊断**：只记录 bounded 状态枚举、命令类型、耗时桶和持久化结果，不记录正文、selection、标签名或路径。

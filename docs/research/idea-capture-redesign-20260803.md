# 晷迹想法记录重做：竞品与 macOS 平台调研

- 调研日期：2026-08-03
- 调研目标：从头确认晷迹原生想法记录应解决的问题、完整生命周期与首版取舍
- 竞品边界：flomo、Obsidian 的 Thino 插件、Memos
- 平台边界：Apple macOS、SwiftUI、AppKit 与 HIG 官方资料
- 资料纪律：只以产品方官网、官方帮助、官方文档、官方源码仓库和 Apple 官方资料支撑事实；不以二手评测支撑关键结论

## 结论摘要

三款产品的共同核心不是卡片、瀑布流或标签数量，而是同一个循环：**让记录先发生，再用低维护成本找回它**。

- flomo 把捕获阻力压到最低：无标题、弱格式、全局快捷键、菜单栏与多端入口；再用搜索、标签、每日回顾、随机漫步和相关笔记让旧内容重新出现。它还明确拒绝把待办能力塞进笔记产品。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html) [flomo 产品定位](https://help.flomoapp.com/)
- Thino 是 Obsidian 知识库上的轻量捕获层，不是独立资料库。它把输入追加到 Daily Notes 或其他 Markdown 来源，再借 Obsidian 的标签、链接、任务语法与插件生态继续加工；每日／随机回顾补上重现环节。[Thino 官方仓库](https://github.com/Quorafind/Obsidian-Thino) [Thino Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/) [Thino Review](https://thino.pkmer.net/en/thino/01_thino-basic/thino-review/)
- Memos 采用首页编辑器加时间线的直接模型，正文内标签、搜索、归档、置顶和保存过滤器都围绕同一份 memo；它说明复杂组织能力可以在捕获之后提供，而不必成为保存前的表单。[Memos 官方仓库](https://github.com/usememos/memos) [Memos 使用文档](https://usememos.com/docs/usage/memos) [Memos 标签](https://usememos.com/docs/usage/tags)

对晷迹最重要的推论是：**不要重做一款缩小版 flomo，也不要把现有 Todo 分类表单套到想法上。** 晷迹的独有机会是完成“捕获 → 找回 → 明确转成行动”的闭环，同时保持“想法不是任务”的领域边界。

建议重做后的首版只聚焦四件事：

1. 主窗口与系统全局都能在几秒内可靠捕获，未提交草稿不会因关闭或切换而丢失。
2. 以时间线、全文搜索和可选行内标签找回内容；捕获时不要求选择任务分组。
3. 提供小而明确的非 AI“回看”入口，让旧想法会重新出现，而不是只进入仓库。
4. 用户手动把想法转为任务，转换前可检查，转换后保留来源关系；此路径不依赖 AI Provider。

置顶、主分类、常驻回收站、多布局、热力图、附件、知识图谱、语义相关和 AI 洞察都不应成为首版成立条件。它们有些在特定场景有用，但同时加入只会制造维护成本和视觉噪音。

## 研究方法与证据限制

本文把内容严格分为三类：

- **事实**：来源直接描述的现有产品或平台行为。
- **推论**：从多个事实归纳出的用户问题或设计原则，不代表来源方原话。
- **建议**：针对晷迹的产品决策，需要后续需求确认和真实 App 验证。

Thino 2.0 起不再开放完整源码，因此 Thino 2.x／3.x 的产品事实以产品方官方仓库 README 和官方 PKMer 文档为准；官方仓库仍可核对产品身份、数据来源和版本边界。[Thino 官方仓库说明](https://github.com/Quorafind/Obsidian-Thino)

Memos 是持续更新的开源产品；本文以调研日可见的官方文档和主仓库为准，不把当前文档没有列出的能力绝对化为“产品不存在”。

## 全生命周期横向比较

| 生命周期 | flomo | Obsidian Thino | Memos | 对晷迹的含义 |
| --- | --- | --- | --- | --- |
| 捕获 | 聊天式无标题输入；Mac 菜单栏入口；客户端系统全局 `⌘N`；`⇧Enter`／`⌘Enter` 发布。[官方说明](https://help.flomoapp.com/basic/quick-input.html) | 插件编辑器写入 Daily Notes／其他 Markdown 来源；`Ctrl/Meta+Enter` 保存；支持全局唤起与浏览器捕获。[仓库](https://github.com/Quorafind/Obsidian-Thino) [编辑器](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/) [全局唤起](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-global-wakeup/) | 首页编辑器直接创建 memo；本地缓存自动保存草稿；官方仓库把体验概括为 timeline-first、open/write/done。[使用文档](https://usememos.com/docs/usage/memos) [仓库](https://github.com/usememos/memos) | 保存前只应要求正文；主窗口与全局浮窗应采用同一提交键和草稿语义。 |
| 组织 | 正文内多级 `#标签/子标签`；输入时可插入标签。[标签文档](https://help.flomoapp.com/basic/tag.html) | 沿用 Obsidian 标签、链接、任务／列表语法；还可选保存来源。`#` 候选默认可限于 Thino 用过的标签。[编辑器](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/) | 从正文自动提取 `#tag`；标签可与搜索、属性过滤和保存的 shortcuts 组合。[标签](https://usememos.com/docs/usage/tags) [Shortcuts](https://usememos.com/docs/usage/shortcuts) | 行内标签是低摩擦的可选增强；任务主分类不是捕获必填项。 |
| 主动找回 | 正文／标签多关键词搜索，可叠加时间、包含／排除标签和媒体条件。[搜索文档](https://help.flomoapp.com/advance/search.html) | 纯文本搜索、常用类型入口；保存过滤器可组合标签、正文、日期、状态、来源、路径和 metadata。[搜索](https://thino.pkmer.net/en/thino/01_thino-basic/thino-search/) [过滤器](https://thino.pkmer.net/en/thino/01_thino-basic/thino-filters/) | 搜索正文、标签、可见性和时间；保存过滤器支持正文、标签、置顶、时间和内容属性等条件。[搜索与归档](https://usememos.com/docs/usage/search-archive) [Shortcuts](https://usememos.com/docs/usage/shortcuts) | 首版需要快速全文搜索与少量稳定过滤；不需要复制高级查询语言。 |
| 被动重现／回顾 | 每日回顾可设置标签范围、时间范围和每天数量；另有随机漫步、相关笔记与 AI 洞察。[每日回顾](https://help.flomoapp.com/advance/lucky.html) [相关笔记](https://help.flomoapp.com/ai/xgbj.html) [AI 洞察](https://help.flomoapp.com/ai/insight.html) | Daily Review 按日期查看；Random Review 每次抽取 10 条并可刷新。[回顾文档](https://thino.pkmer.net/en/thino/01_thino-basic/thino-review/) | 官方 Usage 导航重点是搜索、归档、标签和保存过滤器，未把每日／随机回顾列为基础工作流。[Usage](https://usememos.com/docs/usage) | 时间线只解决“最近写过什么”，不能解决“过去写过什么”；首版应有非 AI 回看。 |
| 关联 | 可手动引用／批注／复制 memo 链接，也会在浏览、搜索和回顾时推荐相关笔记。[引用批注](https://help.flomoapp.com/advance/thread.html) [相关笔记](https://help.flomoapp.com/ai/xgbj.html) | 可从卡片菜单或 `~` 选择既有 Thino 建立引用，关系继续存在于 Obsidian 知识库语境。[Reference](https://thino.pkmer.net/en/thino/01_thino-basic/thino-reference/) | API 的 memo 模型与 relation endpoints 支持 memo relations，但官方日常使用指南没有把关系图作为基础捕获步骤。[Create Memo API](https://usememos.com/docs/api/latest/memoservice/CreateMemo) [Relations API](https://usememos.com/docs/api/latest/memoservice/ListMemoRelations) | 数据模型能表达关系，不等于首版 UI 必须要求用户维护关系；来源关系应先服务任务转换。 |
| 转成行动 | 官方明确说不做 todo／待办提醒，并把待办清单列为不擅长的范围。[快速记录](https://help.flomoapp.com/basic/quick-input.html) [产品定位](https://help.flomoapp.com/) | 编辑器可把当前 Thino 保存为 task 或 list；因为资料仍是 Obsidian Markdown，后续由 Tasks／Dataview 等知识库工作流消费。[Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/) | memo 正文支持 checklist，并产生 `has_task_list`／`has_incomplete_tasks` 属性；它是 memo 内轻量任务，不是独立 Todo 生命周期。[Memos 使用文档](https://usememos.com/docs/usage/memos) | 晷迹本身拥有完整 Todo 领域，因此“用户确认后转成真正任务并保留来源”是最合理的差异化闭环。 |

## 交互、编辑、查看与浏览：产品骨架比较

功能清单不能解释为什么现有体验会显得简陋。真正决定连续使用感的是四个动作怎样接在一起：用户如何进入、怎样修改一条内容、眼前一次看见什么、又怎样从一条走到下一条或走回过去。

| 体验轴 | flomo | Obsidian Thino | Memos | 晷迹不能只抄表面的地方 |
| --- | --- | --- | --- | --- |
| 交互 | 输入像聊天，输入框不要求标题；菜单栏和系统全局快捷键把 composer 带到当前情境，提交后回到记录流。[快速记录](https://help.flomoapp.com/basic/quick-input.html) | composer 与卡片列处于同一插件工作面；可在页内用单键聚焦输入／搜索，也可全局唤起，保存后内容进入原有 Daily Notes 资料流。[Hotkey](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-hotkey/) [Global Wakeup](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-global-wakeup/) | 首页编辑器直接发布到时间线；草稿在本机自动保存，重载也不丢失。[Memos](https://usememos.com/docs/usage/memos) | “有输入框”不等于低摩擦；composer 必须是页面与全局入口共用的稳定起点，并且有草稿、焦点与错误状态。 |
| 编辑 | 已发布 memo 双击进入编辑，发布／换行快捷键与新增时一致。[快捷键](https://help.flomoapp.com/basic/quick-input.html) | 双击卡片原位进入编辑；卡片菜单也提供编辑，内容仍可跳回 Obsidian 原文继续深加工。[Thino Card](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card/) [Card Menu](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card-menu/) | 官方把 inline edit 列为 memo 核心动作，使用同一 Markdown editor 继续修改。[Memos](https://usememos.com/docs/usage/memos) | 编辑应让用户留在阅读位置、看得见保存／取消结果；不能把正文、分类、删除恢复拆成互不一致的临时状态。 |
| 查看 | 主体是短内容卡片的连续流，时间、标签与正文可扫读；单条的关联、洞察等能力从当前内容再展开，而不是全部常驻。[产品定位](https://help.flomoapp.com/) [相关笔记](https://help.flomoapp.com/ai/xgbj.html) | 卡片的固定信息顺序是 timestamp、正文、pin／source 与菜单；timestamp 是默认排序和回顾依据，窄于 800px 时强制回到 timeline，说明时间流是稳态骨架。[Thino Card](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card/) [Multi Layout](https://thino.pkmer.net/en/thino/01_thino-basic/thino-multi-layout/) | timeline-first；正文、时间、标签、置顶等围绕一条 memo 展示，归档后离开主时间线。[仓库](https://github.com/usememos/memos) [Search & Archive](https://usememos.com/docs/usage/search-archive) | 主视图首先要适合快速扫读。每条同时常驻卡片边框、分组、标签、状态、多个按钮和说明，会把正文降成配角。 |
| 浏览 | 用户可沿时间流下翻，也可从搜索、标签、每日回顾、随机漫步或当前 memo 的相关笔记进入另一组内容。[搜索](https://help.flomoapp.com/advance/search.html) [每日回顾](https://help.flomoapp.com/advance/lucky.html) [相关笔记](https://help.flomoapp.com/ai/xgbj.html) | 搜索、标签、保存过滤器、日期回顾和随机回顾都是“改变当前卡片列”的路径；从卡片还可跳回原文或引用关系。[Search](https://thino.pkmer.net/en/thino/01_thino-basic/thino-search/) [Review](https://thino.pkmer.net/en/thino/01_thino-basic/thino-review/) | 以时间线为默认，搜索／标签／保存过滤器缩小当前集合，归档把不活跃内容移出日常浏览。[Tags](https://usememos.com/docs/usage/tags) [Shortcuts](https://usememos.com/docs/usage/shortcuts) | 浏览不是在页底堆一个回收站，而是提供几种有明确意图的“换一组内容”：最近、搜索结果、某标签、旧想法回看。 |

### 三款产品的连续使用路径

**flomo 骨架**：当前情境快速输入 → 新 memo 回到连续流 → 之后以搜索／标签精确找回，或由每日回顾／相关笔记重新遇见 → 在旧 memo 上批注、关联或继续写。它的复杂能力围绕“当前看到的 memo”逐层出现，没有要求用户先进入一个整理后台。[flomo 产品定位](https://help.flomoapp.com/) [引用批注](https://help.flomoapp.com/advance/thread.html)

**Thino 骨架**：在 Obsidian 中快速输入 → 内容写进 Daily Notes／其他 Markdown 来源 → Thino 卡片列按时间投影并可原位编辑 → 搜索、过滤、回顾改变当前集合 → 需要深加工时跳回原文、建立引用或变成 Obsidian task。它之所以不只是“简陋卡片”，是因为后面接着完整知识库，而不是因为卡片菜单项目多。[Thino 官方仓库](https://github.com/Quorafind/Obsidian-Thino) [Thino Card](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card/)

**Memos 骨架**：首页直接写 → 发布到 timeline → 原位编辑或追加标签 → 搜索／保存过滤器切换到关心的集合 → stale 内容归档、需要时恢复。它把可见性、附件、checklist 等能力留在同一 memo 模型内，但默认入口仍是写与时间线。[Memos](https://usememos.com/docs/usage/memos) [Search & Archive](https://usememos.com/docs/usage/search-archive)

### 对晷迹骨架的推论

晷迹不应把 composer、全文过滤、分类过滤、置顶分组、日期分组、行内编辑和回收站纵向堆成一个长页面。那是一张“功能仓库”，用户每次进入都要重新理解整页结构，浏览也只能不断向下滚。

重做后的稳定骨架应是：

1. **写**：页面顶部或全局浮窗始终是同一个 composer。
2. **看**：默认只看可扫读的最近时间线，新增内容回到原处。
3. **找**：搜索或标签把时间线切成一个有清楚条件的结果集合。
4. **回**：独立“回看”模式把少量旧内容带回眼前，而不是混进正常时间线。
5. **做**：从当前条目进入编辑、转任务或删除；完成后回到原浏览位置。

这五步形成产品骨架后，卡片样式、置顶、统计或 AI 才有地方依附。反过来先堆这些功能，只会让交互显得更零散。

## 1. 捕获：低摩擦不是“输入框少”，而是没有前置决策

### 事实

flomo 把聊天式输入的作用写得很直接：不要求标题和排版、控制记录压力、让用户用自己的话快速捕捉；Mac 可从菜单栏唤起输入窗口，客户端还提供系统全局 `⌘N`。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html)

flomo 的 Enter 是换行，发布使用 `⇧Enter` 或 `⌘Enter`。Thino 同样以 `Ctrl/Meta+Enter` 保存。[flomo 快捷键](https://help.flomoapp.com/basic/quick-input.html) [Thino Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/)

Memos 首页可直接创建、行内编辑，并把未发布草稿缓存于本机，页面重载也不丢失；官方仓库把核心体验定义为“timeline-first”以及无需先导航文件夹。[Memos 使用文档](https://usememos.com/docs/usage/memos) [Memos 官方仓库](https://github.com/usememos/memos)

Thino 的基础模式不是另建数据库：它解析 Daily Notes 指定标题下的内容，输入后把内容追加到对应 Markdown；Pro 才扩展到多来源、全局捕获等能力。[Thino 官方仓库](https://github.com/Quorafind/Obsidian-Thino)

### 推论

低摩擦至少包含五项，而不是单纯把表单缩小：

1. 入口在当前上下文附近，不需要先找到页面。
2. 保存前不要求命名、归档或决定是否执行。
3. 多行输入与提交键不会互相打架。
4. 关闭、切换、重复唤起和保存失败不会丢草稿。
5. 保存后有即时、轻量且可信的反馈。

现有“正文 + `@分组` + `#标签`”若把分组变成隐性要求，会把任务分类的认知负担搬到灵感出现的时刻。三款产品都允许先写正文；标签或保存位置是可选增强，不是捕获成立条件。

### 对晷迹的建议

- 主窗口和全局浮窗使用同一 composer 状态机：`Enter` 换行，`⌘Enter` 提交，`Esc` 关闭；不要让全局浮窗用 Enter 提交、主窗口却用另一套规则。
- 全局浮窗关闭时保留未提交草稿；只有保存成功或用户明确清空才清掉。重复触发快捷键只带回同一个窗口与草稿。
- 捕获默认只显示正文与一个清楚的保存动作；`#标签` 是可选 autocomplete。不要在首屏要求 `@分组`、日期、任务落点或 AI 处理方式。
- 捕获成功后立即关闭全局浮窗并把焦点交还原应用；失败则保留正文并在窗口内说明，不用会自动消失的 toast 隐藏失败。
- 正文先以 plain text + 多行为核心。Markdown、附件、图片和排版工具不是首版捕获质量的替代品。

## 2. 组织与找回：捕获后再组织，搜索先于复杂分类

### 事实

flomo 的标签直接存在于正文，支持多级标签；搜索支持正文或标签、多关键词、日期，以及标签包含／排除。[flomo 标签](https://help.flomoapp.com/basic/tag.html) [flomo 搜索](https://help.flomoapp.com/advance/search.html)

Memos 同样从正文提取标签，并明确建议保持小而稳定的标签词汇；保存过滤器可组合标签、正文、时间、置顶和内容属性。[Memos 标签](https://usememos.com/docs/usage/tags) [Memos Shortcuts](https://usememos.com/docs/usage/shortcuts)

Thino 的组织能力明显更重：它继承 Obsidian 标签与链接，并允许过滤正文、日期、状态、来源、路径和 metadata。这些能力成立的前提是 Thino 是知识库插件，使用者已经处于 Obsidian 的资料结构中。[Thino Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/) [Thino Filters](https://thino.pkmer.net/en/thino/01_thino-basic/thino-filters/)

### 推论

- 标签在三款产品中都能延后、修改或通过正文自然出现，所以它是渐进组织工具。
- Thino 的路径、来源和 metadata 对 Obsidian 用户有价值，但不能直接证明独立 Todo App 也需要相同复杂度。
- 主分类适合已经承诺执行的任务；尚未决定用途的想法若被迫选择主分类，会产生分类债和放弃捕获。
- 用户找旧内容时，通常先记得其中某些字、时间或大概标签，而不是内部实体类型。全文搜索应比高级过滤更近。

### 对晷迹的建议

- 时间线顶部提供一个即时全文搜索入口；结果随输入更新，并清楚显示搜索范围与清除方式。
- 首版过滤只保留“全部／无标签／已转任务”及标签点击过滤等少量可解释条件，不复制 CEL、路径或 metadata 查询。
- 想法可以复用既有标签目录，但不应要求一个主任务分组。若未来要提供分组，应是捕获后的整理动作，并以用户真实使用证据决定。
- 编辑直接在原位或轻量详情中完成；时间线以日期分隔与排版层次呈现，不为每条内容叠加描边卡片、徽章、尾箭头和多个常驻按钮。
- “置顶”不是默认必需：在 Todo App 中，长期需要注意的内容更可能应转成任务；首版应先验证置顶的独立用户问题，再决定保留、改为星标或移除。

## 3. 重现与回顾：时间线不等于记得起来

### 事实

flomo 的每日回顾允许设置内容标签范围、时间范围和每天 4–24 条的数量，还可从桌面端侧边栏直接进入；相关笔记则在首页、搜索或回顾场景中从当前 memo 延伸。[flomo 每日回顾](https://help.flomoapp.com/advance/lucky.html) [flomo 相关笔记](https://help.flomoapp.com/ai/xgbj.html)

Thino 同时提供按日期前后浏览的 Daily Review 与每次抽取 10 条、可立即刷新的 Random Review。[Thino Review](https://thino.pkmer.net/en/thino/01_thino-basic/thino-review/)

flomo 的 AI 洞察允许用户从单条或一组笔记主动触发，输出带来源引用，并可用时间与标签限定原料。[flomo AI 洞察](https://help.flomoapp.com/ai/insight.html)

### 推论

搜索解决“我知道自己要找什么”，回顾解决“我已经忘了它存在”。这两个问题不能互相替代。

回顾本身不需要 AI。flomo 与 Thino 都有按时间或随机规则重现旧内容的非 AI 路径；AI 只有在需要跨内容归纳、语义相关或提出新视角时才增加价值。

相关与洞察的价值来自足够的历史语料、可解释的来源和用户当下意图。新用户空库时把这些入口常驻，只会产生无结果状态和视觉噪音。

### 对晷迹的建议

- 首版增加“回看”视图，每次呈现少量旧想法，例如 5 条；默认排除最近 7 天，并允许按标签限定。具体抽样规则需在需求确认时定案。
- 回看必须可解释，例如显示“来自 3 个月前”，而不是伪装成智能推荐；刷新不会修改任何资料。
- 用户从回看可以直接编辑、加标签或转成任务，这才形成“重现 → 处理”的闭环。
- 首版不做自动推送、热力图、连续打卡或“你记录了多少”的激励层；先验证用户是否真的回看和处理。
- 语义相关与 AI 洞察延后。未来若做，必须由用户主动触发、展示所用范围，并像 flomo 一样把每项结论锚定到来源想法；未经确认不能改标签或创建任务。

## 4. 转成行动：晷迹最值得做、也最需要守边界的环节

### 事实

flomo 明确拒绝 todo 与日程提醒，说明纯笔记产品可以有意停在“记录与思考”。[flomo 快速记录](https://help.flomoapp.com/basic/quick-input.html)

Thino 能把编辑器内容保存为 task 或 list，但本质仍是 Obsidian Markdown 语法，再由知识库工作流消费。[Thino Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/)

Memos 支持 memo 内 checklist，并让搜索过滤识别是否含任务、是否有未完成项；它没有因此把 memo 变成独立 Todo 领域实体。[Memos 使用文档](https://usememos.com/docs/usage/memos)

### 推论

三者都证明“记录”与“执行承诺”可以保持不同层级。晷迹已经拥有任务链、Day Todo 与任务池，因此不应把 checkbox 塞进想法正文来模拟任务，而应提供显式领域转换。

如果转换依赖 AI Provider，离线或未配置 Provider 的用户就无法完成最基本的想法闭环；这与想法记录的低摩擦、可靠性目标冲突。AI 可以帮助改写或拆解，但不应拥有基本转换能力。

### 对晷迹的建议

- 每条想法提供一个清楚但不常驻抢眼的“转为任务”动作。
- 点击后显示轻量确认面：以首个非空行建议任务标题，保留完整想法为来源上下文，默认落入任务池；用户可改标题，并可改为今天或未来日期。
- 应用必须原子完成“创建任务 + 记录来源关系”。成功后原想法保留且显示“已转为任务”；任务可返回原想法。
- 同一想法再次转换时先展示既有目标，避免无意创建重复任务；是否允许一对多应由需求确认，不应靠偶然重复点击形成。
- 基础转换完全本地、确定性执行。后续可选“请烛龙拆成任务”草稿，但只能在用户主动触发、审查并确认后应用。

## 5. macOS 全局速记、菜单栏与窗口行为边界

### 5.1 菜单栏入口

**事实**：SwiftUI `MenuBarExtra` 的用途是让用户在 App 不活跃时仍能访问常用能力；`.window` 样式可承载比普通菜单更复杂的标准控件。Apple 也说明菜单栏专用 App 可用 `LSUIElement` 隐藏 Dock 图标，但晷迹是完整窗口 App，不应因此改成菜单栏专用身份。[Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)

**建议**：菜单栏图标可以作为全局快捷键以外的可发现入口，点击直接打开同一速记 composer，并提供“打开晷迹”“设置”“退出”。它不应是唯一入口；允许用户在设置中关闭，以免长期占用菜单栏空间。

### 5.2 全局快捷键

**事实**：SwiftUI `keyboardShortcut` 服务于 App 的菜单命令；Apple 文档说明菜单项的有效状态来自 active scene 与焦点层级，因此不能把它当作 App 未激活时的系统全局热键方案。[Apple SwiftUI 菜单与快捷键](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)

**事实**：`NSEvent.addGlobalMonitorForEvents` 只能异步观察、不能修改或阻止事件；键盘事件还可能要求 Accessibility 信任，而且它不会收到发给自身 App 的事件。[Apple `addGlobalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)

**事实**：Apple Developer Forums 的 Frameworks Engineer 仍直接讨论 `RegisterEventHotKey` 的系统行为与版本变化，说明注册可能因系统规则或组合而失败，调用方必须处理失败而不能假定任意组合可用。[Apple Developer Forums](https://developer.apple.com/forums/thread/763878)

**事实**：Apple HIG 建议只为高频 App 专属命令设置自定义快捷键、尊重系统快捷键，并指出 Control 已被多项系统功能使用、Option 在不同键盘布局上可能参与字符输入。[Apple HIG：Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards/)

**事实**：macOS 的 virtual key code 是硬件无关的，同一物理键在受支持键盘上产生相同 virtual key code；字符则会随键盘布局与输入法变化。[Apple `CGKeyCode`](https://developer.apple.com/documentation/coregraphics/cgkeycode) [Apple `NSEvent.keyCode`](https://developer.apple.com/documentation/appkit/nsevent/keycode)

**建议**：

- 继续采用专用全局 hotkey 注册，而不是用全局事件监听换来 Accessibility 权限。
- 设置保存“virtual key + modifiers”，显示给用户时再按当前布局本地化；腾讯拼音等 IME 下必须验证组合键不会误提交或残留 composing text。
- 注册新组合必须先试注册，成功后再替换旧组合；冲突或系统拒绝时保留旧值并清楚说明。
- 不声称存在“永不冲突”的默认组合。默认键只是起点，必须可改，并同时提供菜单栏与 App 菜单入口。

### 5.3 浮窗与焦点

**事实**：`NSPanel` 可控制只在需要键盘输入时成为 key window；Apple 特别说明 non-activating panel 仍需由具体 view 表明是否要成为 key，才能处理键盘输入和导航。[Apple `NSPanel.becomesKeyOnlyIfNeeded`](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded) [Apple `NSView.needsPanelToBecomeKey`](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey)

**推论**：一个可立即打字的速记浮窗不可能同时承诺“永不取得键盘焦点”。合理目标是：只因用户明确触发而临时取得焦点，不把主窗口带到前台，不展开其他窗口，结束后把控制权还给原 App。

**事实**：Apple 的 cooperative activation 指南说明 App 应请求而不是强夺焦点；把控制权交给另一 App 时应先 yield，再让目标 App activate。Apple 还明确警告 `activateIgnoringOtherApps` 可能偷走焦点，已不建议使用。[Apple cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation) [Apple deprecated activation option](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions/activateignoringotherapps)

**事实**：SwiftUI `Window` 能保证同一 scene 只存在一个窗口，重复 `openWindow` 会把已有窗口带到前方；但它是普通辅助窗口语义。精确控制 non-activating、key window 与浮动行为仍属于 AppKit panel 范围。[Apple SwiftUI `Window`](https://developer.apple.com/documentation/swiftui/window)

**建议**：

- 全局速记使用单例 AppKit panel 承载 SwiftUI composer；每次触发记录当前 frontmost App，显示在当前焦点所在屏幕中央，立即聚焦正文。
- 保存成功或 `Esc` 关闭后，先关闭 panel，再以 cooperative activation 把控制权交回仍在运行的原 App；不要调用已废弃的强制抢焦点选项。
- panel 只在显示期间浮动，不常驻所有 Space；不打开已关闭的晷迹主窗口，也不修改主窗口导航状态。
- 外部点击是否关闭需与草稿安全一起决定。若自动关闭，必须保留草稿；首版不应因失焦静默丢弃。
- 多显示器默认放在当前焦点显示器而非固定主显示器。Apple 的窗口 placement 文档也把 default display 描述为通常是当前有焦点的显示器。[Apple `defaultDisplay`](https://developer.apple.com/documentation/swiftui/windowplacementcontext/defaultdisplay)

## 6. 哪些能力解决真实问题，哪些更像功能堆砌

| 能力 | 解决的独立问题 | 首版判断 | 理由 |
| --- | --- | --- | --- |
| 全局速记 + 菜单栏入口 | 灵感出现时不想切换上下文 | 必须 | flomo 与 Thino 都把外部入口当成捕获能力，不是页面装饰。 |
| 草稿恢复与失败保留 | 意外关闭、同步／持久化失败导致内容丢失 | 必须 | 没有可靠性，再短的捕获路径也不可信；Memos 已把本地草稿缓存列为编辑器基础能力。 |
| 时间线 | 最近记录的连续上下文 | 必须 | 三款产品都以 memo/thino 的时间序列为基础浏览方式。 |
| 全文搜索 | 用户知道自己大概想找什么 | 必须 | 三款都有；这是长期可用的最低门槛。 |
| 行内标签 | 低成本聚类与过滤 | 应有，但可选 | 三款共同采用；不应成为保存门槛。 |
| 非 AI 回看 | 用户忘记旧想法存在 | 必须 | flomo 与 Thino 均单独解决此问题；时间线和搜索不能替代。 |
| 手动转为任务 + 来源 | 从未承诺想法跨到可执行 Todo | 必须 | 这是晷迹相对三款笔记产品最自然的独特闭环。 |
| 置顶 | 让少数内容长期固定可见 | 待证 | Memos 支持，但在 Todo App 里可能与任务承诺、回看重复。 |
| 主任务分组 | 把想法纳入现有分类树 | 延后 | 会把任务结构前置到捕获；目前没有竞品事实证明它是低摩擦捕获必需。 |
| 回收站常驻分区 | 从误删中恢复 | 需要恢复能力，不需要常驻 UI | 恢复若不保留正文就不是真正恢复；可先用删除 Undo 与独立管理面，不要占据主时间线。 |
| 多布局／瀑布流／卡片皮肤 | 改变同一批资料的视觉排列 | 延后 | Thino 的多布局服务 Obsidian 重度工作流，不能替代捕获、找回与行动闭环。 |
| 热力图／统计／连续记录 | 展示数量与习惯 | 延后 | 容易把“记录更多”误当成“想法产生价值”；先验证回看与转化。 |
| Markdown／附件／图片 | 丰富单条内容表达 | 延后 | flomo 甚至主动拒绝 Markdown；Memos/Thino 支持也不代表晷迹首版需要变成文档编辑器。 |
| 手动双链／知识图谱 | 用户主动维护知识关系 | 延后 | 对 Obsidian/知识库合理，对 Todo App 的首要问题证据不足。 |
| 语义相关 | 忘记关键词时找近义或跨标签内容 | 后续 | 需要足够语料、相关性评估和可解释来源。 |
| AI 洞察／自动归类 | 跨多条归纳主题、提出新视角 | 后续 | flomo 将其放在独立主动入口并引用来源；不应混进基础捕获。 |

## 7. 建议的晷迹重做首版

### 7.1 用户承诺

> 在任何 Mac 工作情境中，我都能立即记下一段尚未决定如何处理的想法；以后能按文字、标签或回看重新找到它，并在我决定行动时，把它明确转成有来源的晷迹任务。

这句承诺同时排除了两种漂移：想法保存时不会偷偷变成任务，想法保存后也不会只是永远沉底的文本。

### 7.2 必须实现的用户路径

1. **全局捕获**：快捷键或菜单栏 → 浮窗已聚焦 → 输入多行正文 → `⌘Enter` 保存 → 明确成功 → 回到原 App。
2. **中断恢复**：输入未保存正文 → `Esc`／失焦／重复唤起／App 重启 → 草稿仍在；用户明确保存或清空后才消失。
3. **主窗口捕获**：进入“想法” → 同一 composer 与同一提交键 → 新想法立即出现在时间线顶部。
4. **主动找回**：输入关键词或点击标签 → 结果即时缩小 → 清除条件回到原时间线。
5. **被动回看**：进入“回看” → 看见少量有日期背景的旧想法 → 刷新、编辑、加标签或转任务。
6. **转成行动**：想法菜单“转为任务” → 检查标题与落点 → 确认 → 原子创建 → 双向来源可打开 → 重复转换有明确提示。
7. **纠错**：编辑、删除后即时 Undo；若提供回收站，必须能恢复原正文，否则不要把它称作恢复。

### 7.3 首版信息架构

- 侧边栏只有一个“想法”一级入口。
- 页面标题行提供搜索与“回看”；输入 composer 在内容流顶部，不再叠加独立说明卡。
- 时间线是主内容，使用日期分隔、正文、低对比时间、可点击标签；行操作在 hover／context menu 暴露。
- “已转任务”是来源状态，不是任务完成状态；只在相关条目上轻量显示并可跳转。
- 设置只放全局快捷键、菜单栏图标开关和必要的回看范围；不先暴露大量布局与自动化选项。

### 7.4 首版之外

- AI 自动标签、摘要、洞察、语义搜索与相关想法。
- 自动或批量转任务、后台替用户作出执行承诺。
- 附件、图片、语音、扫描、Web clipper 与跨应用 API。
- 手动双链、关系图、认知地图、多种卡片布局。
- 热力图、连续记录天数、复杂统计与通知促活。
- 第二套想法分类系统，或把任务主分类强制复用于想法。

## 8. 需求确认时必须由用户决定的事项

研究证据可以缩小方案，但不能替用户作出以下产品决定：

1. **想法边界**：只收“尚未决定是否行动”的灵感，还是也承载日记、资料摘录、会议笔记？边界不同会直接改变编辑器、附件与搜索需求。
2. **转换默认落点**：默认任务池最少制造过度承诺；是否允许在同一确认面选择今天／未来日期，需要用户确认。
3. **一对多转换**：首版是一条想法只转一条任务链，还是允许多次产生任务？建议默认一对一并允许显式“再建一项”。
4. **回看规则**：每天固定一组、每次随机、还是按“去年今日／近似日期”？建议先用可解释的少量随机旧想法，不自动通知。
5. **标签词汇**：复用任务标签目录是否会污染任务分类习惯？建议复用标签实体但不复用主分组，并在实际用户故事中验证。
6. **菜单栏默认**：默认显示可提高发现性，但占用有限空间；建议首次启用并允许一键关闭。
7. **删除恢复**：需要完整回收站，还是短时 Undo 已足够？若叫“恢复”，必须恢复正文；不能要求用户重写已经删除的内容。

## 9. 首版成功标准

这些是建议的症状级标准，不以 build 通过替代真实体验：

- 从在其他 App 工作到浮窗可输入，用户只做一次快捷键；主窗口不会被带出。
- 中文 IME 正在组词、换行与 `⌘Enter` 提交不会互相误触；保存后无 composing text 遗留。
- 浮窗关闭、失焦、重复触发、持久化失败与 App 重启均不丢未提交草稿。
- 1,000 条以上一年历史下，时间线滚动、全文搜索、标签过滤和回看仍保持可交互。
- 搜索可以找回正文与标签；回看不会只抽到最近内容，也不会修改任何事实。
- 转任务在无 AI Provider、离线情况下完成；任务与原想法双向可追溯，部分成功不存在。
- 删除 Undo 能恢复原正文；任何名为回收站的路径也必须恢复原正文。
- 所有 UI 验证使用隔离 profile 的真实 `.app`、真实腾讯拼音输入、真实 SQLite 回读与截图，不启动或读取 production 身份。

## 一手来源索引

### flomo

- [产品定位与功能边界](https://help.flomoapp.com/)
- [快速记录、菜单栏与快捷键](https://help.flomoapp.com/basic/quick-input.html)
- [多级标签](https://help.flomoapp.com/basic/tag.html)
- [快捷搜索](https://help.flomoapp.com/advance/search.html)
- [每日回顾](https://help.flomoapp.com/advance/lucky.html)
- [引用批注](https://help.flomoapp.com/advance/thread.html)
- [相关笔记](https://help.flomoapp.com/ai/xgbj.html)
- [AI 洞察](https://help.flomoapp.com/ai/insight.html)

### Obsidian Thino

- [官方仓库与基础数据流](https://github.com/Quorafind/Obsidian-Thino)
- [官方用户指南目录](https://thino.pkmer.net/en/thino)
- [Editor](https://thino.pkmer.net/en/thino/01_thino-basic/thino-editor/)
- [Card](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card/)
- [Card Menu](https://thino.pkmer.net/en/thino/01_thino-basic/thino-card-menu/)
- [Multi Layout](https://thino.pkmer.net/en/thino/01_thino-basic/thino-multi-layout/)
- [Search](https://thino.pkmer.net/en/thino/01_thino-basic/thino-search/)
- [Filters](https://thino.pkmer.net/en/thino/01_thino-basic/thino-filters/)
- [Tag](https://thino.pkmer.net/en/thino/01_thino-basic/thino-tag/)
- [Reference](https://thino.pkmer.net/en/thino/01_thino-basic/thino-reference/)
- [Review](https://thino.pkmer.net/en/thino/01_thino-basic/thino-review/)
- [Global Wakeup](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-global-wakeup/)
- [Hotkey](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-hotkey/)
- [Browser Capture](https://thino.pkmer.net/en/thino/02_thino-advanced/thino-capture/)

### Memos

- [官方仓库](https://github.com/usememos/memos)
- [Memos 日常使用](https://usememos.com/docs/usage/memos)
- [Tags](https://usememos.com/docs/usage/tags)
- [Shortcuts](https://usememos.com/docs/usage/shortcuts)
- [Search & Archive](https://usememos.com/docs/usage/search-archive)
- [Create Memo API](https://usememos.com/docs/api/latest/memoservice/CreateMemo)
- [List Memo Relations API](https://usememos.com/docs/api/latest/memoservice/ListMemoRelations)

### Apple macOS／SwiftUI／AppKit

- [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)
- [SwiftUI menu commands 与 keyboard shortcuts](https://developer.apple.com/documentation/swiftui/building-and-customizing-the-menu-bar-with-swiftui)
- [`NSEvent.addGlobalMonitorForEvents`](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)
- [HIG：Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards/)
- [`CGKeyCode`](https://developer.apple.com/documentation/coregraphics/cgkeycode)
- [`NSEvent.keyCode`](https://developer.apple.com/documentation/appkit/nsevent/keycode)
- [`NSPanel.becomesKeyOnlyIfNeeded`](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded)
- [`NSView.needsPanelToBecomeKey`](https://developer.apple.com/documentation/appkit/nsview/needspaneltobecomekey)
- [Cooperative activation](https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation)
- [SwiftUI `Window`](https://developer.apple.com/documentation/swiftui/window)
- [`defaultDisplay`](https://developer.apple.com/documentation/swiftui/windowplacementcontext/defaultdisplay)

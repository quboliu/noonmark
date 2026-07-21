# Codex 与 Claude 对话工作空间 UI 调研

- 调研日期：2026-07-20
- 调研目标：为晷迹「烛龙」重构建立当前一手资料基线
- 资料边界：OpenAI 官方产品页、官方 Codex／ChatGPT 文档与 changelog；Anthropic 官方产品页与 Help Center
- 结论性质：产品能力与导航结构来自官方文字；视觉密度结论若来自官方产品截图观察，会明确标成设计推论

## 先说结论

烛龙应改成「一条对话主轴 + 一个常驻 composer + 按需展开的专业结果」，而不是继续用一组并列卡片表达工作流。用户提出问题、烛龙追问、计划、执行进度、权限请求、失败、产物摘要与应用结果，都应按发生次序进入同一会话流。只有需要长时间检视或编辑的内容，例如 Todo diff、计划草稿、证据详情与事件历史，才进入可收起的右侧检视面。

这不是把烛龙做成无限通用聊天页。晷迹现有领域模型要求每场烛龙会话围绕一个主要意图，权限、Todo 写入、规划委托与记忆仍分别确认；UI 应把这些边界放进对话，而不是删除边界。

当前竞品也不是「所有东西永远塞在消息气泡里」：OpenAI 将 diff、文件和 Git review 放进 thread side panel；Claude 将可独立编辑或复用的 Artifact 放在对话右侧。可借鉴的是对话负责叙事顺序，专业表面负责高密度检视。

## 当前性说明

### OpenAI

2026 年 2 月发布的独立 Codex app 已演进为当前 ChatGPT desktop app 内的 Codex 工作空间。当前官方桌面文档把它称为复杂工作的 command center，强调在一个桌面工作空间中并行项目、文件、电脑操作和长期任务；旧 Codex app 的发布页仍可用于理解 thread、project、worktree 和 review 的设计来源，但不能当作 2026-07-20 唯一当前界面。[ChatGPT desktop app](https://learn.chatgpt.com/docs/app) [Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/)

### Anthropic

Anthropic 在 2026-07-07 明确说明 Chat 与 Cowork 现在共享一个 home，项目与 Artifacts 也集中到同一处。当前 Cowork 从与普通对话相同的 message box 开始，用户在 message box 选择 `Chat` 或 `Cowork`；Claude Desktop 也可通过 deep link 直接进入 Chat、Cowork 或 Code session。[Claude release notes](https://support.claude.com/en/articles/12138966-release-notes) [Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork) [Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)

## 一手资料发现

### 1. 会话流是工作的时间主轴

OpenAI 将 agent 工作放在 thread 内：不同 agent 在 project 下的独立 thread 中运行，用户可在 thread 中查看改动、评论 diff，并跳转到编辑器继续处理。当前桌面文档也把 chat 当成项目内可恢复的工作单元；项目的 `Chats` 汇集会话，`Sources` 汇集共享文件和上下文。[Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/) [Projects and chats](https://learn.chatgpt.com/docs/projects)

Claude Cowork 同样从会话开始。官方流程是：描述任务、查看 approach、让任务运行；运行期间以 progress indicators 展示步骤，用户可中途 steering、回答问题或重定向，完成产物回到同一 session。[Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)

对烛龙的含义：基础能力不应各自拥有一块常驻 dashboard 卡片。追问、规划、自动分类说明、标签建议、复盘协助等能力，默认都用消息轮次与用户交互；能力名称可成为消息来源或轻量状态，而不是新的页面层级。

### 2. Composer 是模式、上下文与后续指令的共同入口

OpenAI changelog 反复把 model selector、skills、plugins、`@` mentions、附件、slash command、queued prompt 与 steering 放在 composer 周边；工作进行时仍允许追加或排队后续指令。这说明 composer 不只是「发送文本」，也是当前会话模式与上下文的紧凑控制点。[Codex changelog](https://learn.chatgpt.com/docs/changelog)

Claude 当前把 Chat／Cowork 选择放在同一个 message box。Cowork 启动后，用户仍在同一 session 中查看计划、进度并 steering。[Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)

对烛龙的含义：烛龙的视图／工作方式切换必须重新成为可发现的一等入口，优先放在 composer 左侧或其正上方，而不是埋入设置。若恢复既有三种烛龙视图，应使用明确中文名称与当前选中态；但三种名称、语义和切换后的数据边界必须从晷迹现有规格与代码确认，不能用竞品模式名称代替。

### 3. Plan、tool、status 应嵌入流，但按信息密度折叠

Codex changelog 显示：plan mode 问题会产生通知；tool activity、queued prompt、side chat、subagent progress 和 task progress 都是 thread UI 的组成部分；review comment 可折叠，diff 可以 inline 或 detached，Git summary 与 Sources 则进入 thread side panel。[Codex changelog](https://learn.chatgpt.com/docs/changelog)

Claude Cowork 会先建立计划，再分解子任务、运行工具、并行工作，且用进度指示器持续展示正在做什么；用户可在同一 session 中介入。涉及永久删除时，产品会在流程中显示明确 permission prompt。[Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)

Claude Code 官方把每次 tool call 作为 transcript 的可见记录，同时默认隐藏扩展推理；用户可按 `Ctrl+O` 展开 verbose full transcript。官方证据支持「默认摘要、按需展开完整过程」，不支持凭空宣称存在三档 transcript 视图。[Claude Code user FAQ](https://support.claude.com/en/articles/14554922-claude-code-user-faq) [Claude Code cheatsheet](https://support.claude.com/en/articles/14553413-claude-code-cheatsheet)

对烛龙的含义：

- 正常运行只显示一行可读状态，例如「正在核对 8 项任务」；结束后折叠成「已核对 8 项」。
- 用户决定点必须是对话流中的完整轮次，例如数据范围、远程发送、规划委托、Todo 应用与危险操作确认。
- 展开后才显示步骤、证据引用、Provider、失败原因与重试细节。
- 不用一张外围卡片包一张计划卡、再包步骤行和 badge；层级优先用文字、留白、缩进和一条分隔线建立。

### 4. 会话／任务导航与主对话分工明确

OpenAI 的 project 用来聚合相关 chats、files、instructions 与 sources；自包含工作可不建 project。独立 thread 让长期任务与并行 agent 不互相丢失上下文，thread 还保留各自 scroll position 与 unread state。[Projects and chats](https://learn.chatgpt.com/docs/projects) [Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/) [Codex changelog](https://learn.chatgpt.com/docs/changelog)

Claude project 是包含自身 chat history、knowledge 与 instructions 的工作空间；左侧面板提供项目与聊天入口，并允许 star 常用项目。Chat 和 Cowork 当前共用 home 与项目入口。[What are projects?](https://support.claude.com/en/articles/9517075-what-are-projects) [How can I create and manage projects?](https://support.claude.com/en/articles/9519177-how-can-i-create-and-manage-projects) [Claude release notes](https://support.claude.com/en/articles/12138966-release-notes)

对烛龙的含义：左侧只承担会话导航与轻量状态，不把每个基础能力做成永久导航项。建议分为「新会话」「进行中」「最近」「已归档」，每项只显示标题、更新时间和一个必要状态；能力类型可作为次要文字，不再叠加图标、badge、描边与尾箭头。

### 5. 专业产物可以离开流，但不能脱离会话

OpenAI 把文件预览、diff、Git summary、Sources 与 PR review 放到 thread side panel，且支持 inline／detached review。这些是需要持续浏览、比较或编辑的专业结果，不适合压缩成普通消息文字。[Codex changelog](https://learn.chatgpt.com/docs/changelog)

Claude 将显著、可独立编辑或复用的内容作为 Artifact，在主对话右侧的 dedicated window 显示；项目知识也在项目页右侧管理。Artifact 仍由对话产生，并可继续在对话中要求修改。[What are artifacts and how do I use them?](https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them) [Collaborate with Claude on Projects](https://www.anthropic.com/news/projects)

对烛龙的含义：右侧详情栏只在用户打开 Todo diff、计划草稿、证据、记忆范围或事件历史时出现。对话消息中保留摘要、状态和「查看／编辑」入口；关闭详情栏后仍能从原消息恢复，不另造 dashboard。

## 可直接用于烛龙重构的设计准则

1. 默认页面只有会话导航、对话流和 composer 三个主要视觉区；右侧检视面按需出现。
2. 每个用户输入、烛龙回复、用户决定、权限请求、进度、错误和应用结果按时间进入一条流；不再按能力拆成并排卡片。
3. 普通文字消息不用全宽描边容器。用户消息可用轻量底色或较窄气泡；烛龙消息优先用无边框正文、头像／名称和留白区分。
4. Tool 与步骤默认折叠为一行状态，只有运行中、失败、等待用户或用户主动展开时提高视觉权重。
5. `Plan` 是会话中的可版本化内容：先显示简洁摘要与待决定事项，完整阶段与证据进入展开区或右侧检视面。
6. Composer 常驻底部，并承载附件、上下文范围、工作方式切换和发送／停止；低频控制进入单一溢出菜单。
7. 恢复三种烛龙视图的切换入口时，让入口靠近 composer，并同步提供 `View` 菜单和快捷键；设置只决定默认值，不承担日常切换。
8. 左侧会话行最多一个主标题、一项次要信息和一个必要状态。不要组合「分组标题 + 卡片 + 彩色图标 + badge + 尾箭头」。
9. 右侧检视面只承载需要逐项审查或编辑的结构化结果；它必须和对话中的来源消息双向定位。
10. Provider、数据范围、自动分类／标签与烛龙页面是否启用是不同能力边界；UI 不能用一个总开关假装它们拥有相同权限。
11. 新会话的空态以一个明确问题和少量示例 prompt 开始，不展示能力 dashboard。
12. 所有异步状态都要保留可读历史，但成功后的低价值步骤应自动收拢，避免会话越长视觉噪音越高。

## 不可盲目复刻的差异

- Codex 面向代码仓库、Git、terminal、worktree 与 PR review；烛龙不能复制 branch、diff stat 或 agent 并行语法。烛龙的专业结果是 Todo diff、任务轨迹、分类建议、复盘和规划授权。
- Claude Chat 可承载开放式长期对话；烛龙会话按 `CONTEXT.md` 是围绕一个主要意图的有界单元，不能因为采用聊天外观就取消会话目标、版本与归档边界。
- Codex／Cowork 可以持续执行广泛工具；烛龙是闭域规划，未知外部事实必须成为追问、假设或调查任务，Todo 写入继续要求当前版本确认。
- Claude Artifact 与 Codex review 允许复杂专用表面；因此「全部信息在对话流中」应解释为全部事件都有对话位置，而不是禁止右侧可编辑结果。
- 竞品的模式名称不能直接替代烛龙既有三种视图。仓库目前只证明用户记得曾有三种形式；具体语义必须从历史实现、规格或用户确认恢复。
- 官方文字资料没有为「无边框」给出像素规范。少卡片、少描边是结合官方截图结构与晷迹既有 UI 基调得出的设计推论，最终仍需以真实 `.app` 原型和用户确认截图建立视觉 oracle。

## 建议的烛龙信息架构

```text
左侧会话导航        中央会话流                       右侧按需检视
新会话              会话标题／轻量状态               Todo diff
进行中              用户消息                         计划草稿
最近                烛龙回复                         证据与数据范围
已归档              折叠的计划／工具／进度           事件历史
                    对话内授权与确认
                    常驻 composer + 视图切换
```

这套结构保留晷迹需要的审查、授权与可追溯性，但把它们从「条条框框」改成有时间顺序的对话事件；只有真正需要比较和编辑的结果才占用独立表面。

## 来源清单

### OpenAI

- [ChatGPT desktop app](https://learn.chatgpt.com/docs/app)
- [Projects and chats](https://learn.chatgpt.com/docs/projects)
- [Codex changelog](https://learn.chatgpt.com/docs/changelog)
- [Introducing the Codex app](https://openai.com/index/introducing-the-codex-app/)
- [Codex product page](https://openai.com/codex/)

### Anthropic

- [Claude release notes](https://support.claude.com/en/articles/12138966-release-notes)
- [Get started with Claude Cowork](https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork)
- [Open Claude Desktop with a link](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link)
- [What are projects?](https://support.anthropic.com/en/articles/9517075-what-are-projects)
- [How can I create and manage projects?](https://support.anthropic.com/en/articles/9519177-how-can-i-create-and-manage-projects)
- [What are artifacts and how do I use them?](https://support.anthropic.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them)
- [Collaborate with Claude on Projects](https://www.anthropic.com/news/projects)
- [Claude Code user FAQ](https://support.claude.com/en/articles/14554922-claude-code-user-faq)
- [Claude Code cheatsheet](https://support.claude.com/en/articles/14553413-claude-code-cheatsheet)

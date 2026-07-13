# 烛龙统一工作空间交互原型

> THROWAWAY PROTOTYPE — 本目录只用于验证烛龙 clean-sheet 交互。它不连接真实 Provider、SQLite、Keychain 或 Todo 写入；结论确认后应吸收设计并删除原型代码。

## 当前走查：单一纵向工作流

用户已选择“固定 Noonmark 外框 + 单一纵向追加流”作为当前方向。中央工作区不再按业务步骤切换页面；用户回答、烛龙运行、决策门、草稿、授权与回执全部按时间追加并保留在同一条流中。

当前入口为 `stream-prototype.html?variant=A|B|C`。连续卷宗、章节手风琴与左右双轨是同一份 append-only 日志的三种正式用户视图，不再以淘汰其中两案为目标；C 默认采用“左侧烛龙工作、右侧用户决定”，重大检查点、历史边界与回执横跨全宽。用户可从 PageHeader 切换视图，选择会保存在本机，且不会改变业务 head、授权、输入或查看位置。业务 head 与查看游标分离；“回看上一检查点”只定位旧检查点，修改必须在流末端追加更正和失效回执。交互式规划采用逐条 durable commit：授权、开始、运行产物、停机条件与 checkpoint 分别形成；用户上滑后只累计新记录数，不抢回 viewport。完整规则、像素级 prompt 与验收矩阵见 [单一纵向工作流设计](STREAM-PROTOTYPE.md)。

原 `noonmark-mac-prototype.dc.html` 保留为多页面 R3 的冻结对照，不再是当前设计方向；待流式方案收敛后删除。

## 本轮问题

一套统一的 Noonmark Mac 工作空间，能否在不退化为聊天页、AI Dashboard 或黑盒自动驾驶的前提下，完整承载：

1. 模糊任务的任务成形闭环；
2. 从确认今日计划到形成下一次可信承诺的每日收尾闭环；
3. 分层白盒披露、明确授权、可审查草稿、原子 Todo 应用和结果回执。

R3 已验证的领域边界继续保留：委托前以“活简报”为共同工作对象，只对阻塞字段展开一轮内联 grill；用户确认简报后进入“有界委托运行”，并在证据不足或必须由用户取舍时停在决策门。结构化计划成立后才派生 Todo 变更 diff。新的流式原型改变呈现与状态投影，不降低这些能力。

R2.1 的固定审批向导与 R2.2 的 A／B／C 候选实现均已退出运行时。其比较过程和组合理由只保留在 [历史交互决策记录](INTERACTION-VARIANTS.md)；R3 的完整状态与传播规则见 [R3-DESIGN.md](R3-DESIGN.md)。

## 成功标准

- 用户从三个情境入口都能理解烛龙为何出现：烛龙首页、Day Todo 收尾、任务行“交给烛龙梳理”。
- 会话在任何时刻只有一个主要意图，并能暂停、恢复、追加更正或整体删除。
- 远程调用前必须展示具体数据、记忆、Provider 配置身份和权限；扩大范围时重新确认。
- 每个关键问题都能查看“为什么问”、回答影响和可用证据，并允许“不知道”或更正。
- 用户回答必须更新活简报的具体字段、来源、版本和下一步；“先比较”只能补充比较，不能伪装成已经作出取舍。
- 规划简报审查与规划委托是两个明确动作；规划委托不包含 Todo 写入。
- 规划运行必须显示已完成步骤、真实产物、所用依据、下一步和停机条件；证据不足时不得生成具体日期、点数或正式兑现概率。
- 决策门确认、规划委托和 Todo 原子应用是三个独立授权；简报实质变化必须使旧委托失效并重新确认。
- Todo 变更 diff 是唯一执行依据。部分采用必须先拆分批次，确认后原子应用。
- 每日收尾把承诺兑现、实际产出、原因假设、复盘草稿和明日 Todo 分开处理。
- 主界面不常驻展示全量权限、记忆和 Provider 运维信息；白盒说明采用情境提示、按需检视器和 append-only 事件历史三层披露。
- 在真实逻辑窗口 `1320 × 820` 下保持正文可读、主动作可见和长内容可滚动。

## 像素级设计 prompt

### 唯一视觉基线

- UI 必须以本轮真实 `.app` 运行产物 `artifacts/e2e/day.png`、`artifacts/e2e/settings.png` 和 `artifacts/e2e/zhulong.png` 为准；旧烛龙的产品结构不复用，但 Noonmark 全局壳层与现有 SwiftUI 组件语言必须复用。
- 代码基线来自 `App/NoonmarkMacApp/NoonmarkMacApp.swift` 中的 `Theme`、`Sidebar`、`PageHeader`、`SettingsCard`、`SmallActionButton`、`StatusPill`、列表行 surface 和 `DetailRail`。
- 首要验收尺寸为真实启动尺寸 `1320 × 820` CSS px；最小尺寸压测为 App 实际下限 `1180 × 760`，不再使用产品不支持的 `1100 × 700`。
- 禁止新增独立 Web toolbar、紫色主操作体系、Web Dashboard 卡片语言、浮动输入 dock 或遮罩式抽屉。新功能必须看起来像当前 App 中原本就存在的页面。

### 精确 token

- 根窗口圆角 `12px`；外边界 `1.35px #B0B4BB`，内侧 `0.7px rgba(255,255,255,.78)`；窗口内容不添加 Web drop shadow。
- 冷灰主题：桌面 `#ECEDEF`，窗口背景 `#FDFDFC`，主 panel `#FFFFFF`，次 panel `#FBFBFC`，sidebar `#FAFAF9`，control fill `#FEFEFE`。
- 线条：普通 `#E6E6E9`，强调 `#CCCCD5`；正文 `#1C1C1F`，次文 `#6B6B75`，弱文 `#A1A1AB`，chip `#F2F2F4`。
- 全局 accent 使用当前 App 的 `#2961C7`，soft accent `#EDF4FF`；成功 `#148C61`／`#E8FAF2`；警告 `#B44D34`／`#FFEFEA`。
- `#7C5CFF` 只用于烛龙导航图标及其极淡 active tint，不得作为主按钮或正文交互色。
- 字体只用系统 `-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC"`。Page title `21px/700`，页面 subtitle `12px`，卡片标题 `14px/600`，行标题 `13px/500–600`，正文 `11.5–12.5px`，弱标签 `10.5–11px`。
- 常规圆角 `7–9px`；设置卡片和主区块 `8px`，输入框 `7–8px`。避免 R2 原型中的 12–16px 大圆角。

### 当前 App 壳层

- Sidebar 固定 `240px`。顶部 padding `16px`；红黄绿交通灯直径 `14px`、间距 `9px`、水平起点 `18px`，交通灯下方 `24px`。
- 品牌水平 padding `20px`：24px 蓝色时钟 logo、9px 间距、17px bold“晷迹”；下方留 `18px`。
- 导航分组标题 `11.5px semibold`，水平 padding `20px`；导航行外层水平 `9px`、垂直 `1.5px`，内容高 `36px`，圆角 `8px`。
- 导航图标使用与当前 App 相同的 SF Symbol 轮廓语义；浏览器用单色 inline SVG 近似，不使用带方框的中文字形或 emoji。
- 主表面不设置独立全局顶部栏。每个页面直接使用 `PageHeader`：水平 padding `24px`、垂直 `16px`，标题 `21px bold`、subtitle `12px`。
- 需要上下文时使用当前 App 的固定 `300px Detail Rail`，左侧 `1px` 分隔线；事件历史、依据、会话控制和记忆范围都在 rail 内切换，不使用遮罩或模糊背景。
- 主滚动内容沿用当前页面密度：padding `20px`，一级区块间距 `16px`；设置页沿用水平 padding `28px`、垂直 `20px`。

### 统一会话框架

- 会话仍是单一工作空间，但必须嵌在当前 `ZhulongPage + DetailRail` 结构中。
- `PageHeader` 显示会话标题与单一意图 subtitle；右侧使用现有 `HeaderButton` 风格放“暂停”“事件历史”和省略号，不新增 72px 会话 toolbar。
- PageHeader 下使用 30px 高的紧凑状态带，只表达当前真实工作态：共同定义、简报待审、规划运行、决策门、草稿待审、写入确认或完成；不显示固定题数、伪进度或可切换方案。
- 中央主区只显示当前工作对象：活简报、运行线、规划草稿或 Todo 批次；右侧 rail 检视当前字段、当前步骤或当前批次。点击事件历史后 rail 内容原位切换，关闭后回到当前上下文。
- 用户输入沿用现有 TextField／TextEditor：control fill、7–8px 圆角、1px line。操作按钮使用 `SmallActionButton` 的 24px 高描边样式；关键动作可使用 accent text 与 accent-soft 背景，但不使用大面积实心蓝按钮。
- 页面可以滚动，操作区作为普通卡片或行出现在内容流中；不再固定于窗口底部。

### 入口与发现

- 烛龙首页用真实 `PageHeader("烛龙", subtitle)`；主区以一张 `SettingsCard` 风格的“建立有界会话”卡片为核心，下方是当前 App 列表行风格的可恢复会话。
- Day Todo 必须复用真实页面：240px sidebar、日期 header、date strip、quick add、任务列表和 300px Review Rail。只新增“确认今日计划”“开始收尾”和任务菜单中的“交给烛龙梳理”，不得重画整页。
- “承诺快照”只在 rail 的历史／解释层出现；主路径动作使用“确认今日计划”。

### 范围回执

- 会话第一次远程调用前出现一张当前 App 卡片样式的正式回执，而不是 Web 权限弹窗：目标、6 项任务、2 条相关任务链、3 条已确认记忆、Provider 配置身份逐行展示。
- 每行有来源、使用原因和“排除”动作；排除后计数和摘要同步更新。
- 行高、分隔线与 `ZhulongScopeChip`／`SettingsInfoRow` 一致；“排除”使用 SmallActionButton，不做右对齐 Web text link。
- 底部两个 SmallActionButton：“仅在本次会话使用”和“继续并记住此范围”。两者都不能突破设置中的权限上限。
- 若范围后来扩大，使用琥珀色差异回执，只列新增项并要求再次确认。

### 活简报与内联 grill

- 主区始终展示同一份纵向活简报：目标、用户取舍、完成标准、硬约束、可自主事项、烛龙假设、未决问题和数据范围。
- 只有阻塞简报成立的当前字段才在原位置展开一轮 grill；最多展示 4 个互斥建议和一个自然语言输入，不预告固定题数。
- 第一条路径选择与最低完成标准分别在 `focus` 和 `criteria` 阶段处理；空回答 fail-closed，“不知道”保留缺口，“先比较”只生成比较材料。
- “为什么问”使用右侧 `DetailSection` 展示用户原话、本地事实、烛龙假设、主要备选和回答影响；不得暴露原始 chain-of-thought。
- 每次确认都生成新简报版本并标明刚改变字段的来源；旧版本和更正保留在 append-only 事件历史。

### 规划简报与委托

- 规划简报使用当前 App 的纵向卡片与 `SettingsInfoRow` 组合，而不是两列 Web 文档网格：目标、完成标准、硬约束、用户决定、烛龙假设、未决事项、数据范围。
- 用户决定、AI 假设、事实使用文字 `StatusPill` 加轻量色点区分，不增加粗左边线设计语言。
- 顶部显示版本与“较上一版 3 处变化”；用户可以追加更正，不覆盖旧决定。
- “确认简报并委托规划”使用 accent SmallActionButton；旁边以 `11.5px Theme.text3` 明确这是一次性规划委托，不包含 Todo 写入、长期记忆、承诺快照或未来托管。
- 委托后的 `run` 显示运行契约和可见步骤；遇到证据不足先停在 `gate`。若用户的决定实质改变简报，先形成 `amendment`，旧委托失效；重新确认后才进入 `run-resumed`。

### 规划草稿、diff 与应用

- 草稿顶部使用三个当前 App 卡片／metric tile 表示完整阶段地图；只有近期阶段展开 Todo 细节，远期只保留目标和触发条件。
- “为什么这样安排”把右侧 rail 切换为 AI 决策说明，依次展示证据、约束、主要备选、取舍、不确定性和预期影响。
- Todo diff 使用当前任务列表行语法：左侧小型操作 glyph，中间任务标题与来源，右侧目标位置与 SmallActionButton；不得使用 Web 表格或会暗示直接部分应用的复选框。
- 用户要部分采用时点击“拆分批次”，生成新版本并保留 AI 原版。
- 确认页面用 `SettingsMetricPill` 与 `Notice` 重复显示操作总数、影响范围、原子语义和当前授权；主要动作写作“原子应用 3 项变更”。
- 应用回执复用列表行、成功状态 chip 与 SmallActionButton，列出结果实体、AI 应用批次、事件历史链接和有限撤销资格。

### 每日收尾

- 阶段为“事实 → 原因 → 复盘 → 明日计划 → 完成”。
- 事实阶段在主区用两个当前 App summary card 对照承诺兑现与实际产出，不产生“忙碌分数”或互相抵销；右 rail 解释来源。
- 未完成原因以单题形式逐条确认；“不知道”是合法结果，未经确认的原因不进入复盘或记忆。
- AI 复盘草稿与明日 Todo diff 使用独立审查步骤和独立保存／应用动作。
- 形成明日计划后只生成待确认计划；用户在相应 Day Todo 中执行“确认今日计划”才生成新的承诺快照。

### 白盒、记忆、权限与异常

- 事件历史入口位于烛龙 `PageHeader` 右侧；点击后只替换 300px Detail Rail 内容，不打开 sheet。事件不可编辑、重排或逐条删除。
- 清理控件只提供最近 `1 小时`、`1 天`、`7 天` 等连续范围，并说明会留下无正文清理标记。
- 记忆管理位于设置页：已确认记忆可修改、停用、删除；候选可修改、确认或拒绝；冲突默认不参与规划。
- YOLO 只在设置的权限 profile 中作为便利选项出现；会话主界面只披露本次具体授权。
- 本地模式明确列出仍可使用与等待 Provider 的能力，并提供“继续本地准备”“配置 Provider”。
- Provider 失败保留输入与草稿，提供“重试”“选择其他 Provider”“继续本地工作”，禁止静默 failover。
- 过期规划草稿仍可审计，但应用按钮必须禁用，并要求生成新版本。
- 设置页面必须复用真实 `SettingsPage`：PageHeader、水平 30px pane toolbar、最大 740px SettingsCard；权限、记忆、Provider 和透明度作为烛龙相关 pane／card，而不是新增垂直设置导航。

## 交互状态契约

原型使用 URL 参数保持可分享状态，所有业务数据只在内存中：

- `surface=zhulong|day|settings`
- `flow=shape|close`
- `step=home|scope|focus|criteria|brief|run|gate|amendment|run-resumed|draft|apply|receipt|facts|cause|review|tomorrow`
- `panel=context|events|memory|session`
- `provider=online|local|failed`
- `condition=normal|scope-expanded|stale|long`
- `scroll=top|bottom`：截图验收时固定长内容的滚动位置。

任务成形的唯一顺序为：`focus → criteria → brief → run → gate → amendment → run-resumed → draft → apply → receipt`。点击主要动作会更新 URL 和完整界面状态；用户选择、自然语言改写、简报版本、比较结果和决策门选择只保存在内存中，reload 可以清空。

## 运行

当前单一纵向流原型：

```bash
scripts/serve-zhulong-stream-prototype
```

浏览器打开 `http://127.0.0.1:4175/stream-prototype.html?variant=C&scenario=focus`。首次未指定视图时默认 C；PageHeader 的“视图”菜单可在 A／B／C 间切换。`scenario=focus|run|gate|draft|receipt|corrected|long` 提供确定性走查入口。

直接体验逐条追加、自动跟随和暂停／继续：打开 `?variant=C&scenario=run`，点击“运行到下一决策门”；运行中用滚轮上滑，可以观察“`N 条新运行记录`”入口，记录不会把 viewport 拉回尾端。

专门体验回看／返回当前的连续滚动轨迹时，使用 `?variant=C&scenario=long&demo=motion`。这个 fixture 会生成 36 条中间记录并默认锚定当前检查点，只用于观察多屏滚动，不改变正式长流的聚合规则。

截图验收若要固定打开视图菜单，可追加 `fixture=layout-menu`；这只设置原型首次绘制状态，不进入产品状态或领域日志。

生成流式原型截图矩阵并运行 Chrome/CDP 交互回归：

```bash
scripts/render-zhulong-stream-prototype
scripts/test-zhulong-stream-prototype
```

冻结的多页面 R3 对照：

```bash
scripts/serve-zhulong-r3-prototype
```

浏览器打开 `http://127.0.0.1:4174/noonmark-mac-prototype.dc.html?surface=zhulong&flow=shape&step=focus`。验收场景通过业务动作或明确 URL 状态进入。

生成 R3 完整截图矩阵：

```bash
scripts/render-zhulong-r3-prototype
```

运行真实 Chrome/CDP 的 prototype-only 交互回归：

```bash
scripts/test-zhulong-r3-prototype
```

该脚本验证浏览器原型状态机，不冒充真实 `.app` E2E 验收。

## 验证矩阵

- 任务成形完整路径：`focus → criteria → brief → run → gate → amendment → run-resumed → draft → apply → receipt`。
- 活简报：空回答 fail-closed；“先比较”生成比较但不关闭缺口；路径和完成标准分别确认后才出现完整简报。
- 授权边界：简报确认前不能运行；决策门未选择不能继续；修订后旧委托失效；Todo 写入必须再次确认当前具体批次。
- 追加更正：空更正 fail-closed；更正以新事件追加；委托后的更正会停用旧运行、草稿与 diff，浏览器历史或旧 URL 不能恢复应用能力。
- 有界运行：只推进界面可见步骤；每步展示实际输入、证据、产物、下一步和停机条件；运行完成后才出现规划草稿。
- 计划与执行：草稿先显示完整阶段地图、依赖、滚动触发条件和“证据不足”，再单独派生 Todo diff；不得出现无依据日期、点数或正式概率。
- 回执：列出原子批次、结果实体、来源计划节点和事件入口，并明确没有形成承诺快照、长期记忆或未来授权。
- 每日收尾：Day Todo 入口、事实、原因、复盘、明日计划、完成。
- 配套：事件历史、权限设置、记忆设置。
- 异常：本地模式、Provider 失败、范围扩大、草稿过期。
- 尺寸：1320×820 主矩阵、1180×760 最小窗口压测。
- 长内容：长规划草稿和长事件历史必须滚动，固定 UI 不遮挡末项与主动作。

## 当前结论

领域流程继续采用 R3 已验证的活简报、内联 grill、有界运行、决策门和独立 Todo diff；界面与状态组织已经转向单一 append-only 纵向流。A／B／C 均保留为用户可选视图，C 为默认。下一阶段不再评选唯一胜出布局，而是验证三种投影能否零语义损失切换，并继续打磨 C 在长记录、长用户决定和最小窗口下的辨识度。

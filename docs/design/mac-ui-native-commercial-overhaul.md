# 晷迹 Mac UI 原生化与商业化升级

## 文档状态

- 日期：2026-07-16
- Task-ID：`mac-ui-native-commercial-overhaul`
- 分支：`codex/ui-native-commercial-overhaul`
- 任务等级：P
- 状态：仓库内实施收口中；发布门禁待 UI-018 人工验收及 UI-019 外部发行资产
- 范围：本轮 UI 精细度、商业化美观、原生 macOS UI／UX、无障碍、本地化与发布体验审查的仓库内闭环与剩余发布边界

本文是本轮审查的持久记忆和实施契约。结论以源码与真实 `.app` 运行产物为依据；归档 HTML 原型不是视觉 oracle。实现不得以删功能、提高视觉回归阈值或保留能力不对等的旧／新路径来换取通过。

## 需求与成功标准

用户目标是把当前高质量 beta 提升为可商业发布的原生 Mac 产品，并解决本轮审查提出的全部问题。完成必须同时满足：

1. 生产环境的“今天”来自用户当前 Calendar／时区，启动、跨午夜、时区变化、睡眠唤醒与重新激活都能正确更新；旧 Day Todo 必须先完成原子日结束处理和持久化，再发布新的自然日。
2. 中文与 English 界面没有混杂；所有用户可见字符串、日期、时间、星期、状态、错误与菜单都跟随应用语言，系统格式跟随对应 locale。
3. 主窗口采用完整 macOS 菜单、可恢复窗口、原生 Settings 入口、可调整分栏、键盘焦点与选择语义；文本编辑不劫持 Tab 焦点移动。
4. 列表、控制、toast、弹窗、颜色、字体与动效满足 VoiceOver、键盘、Increase Contrast、Differentiate Without Color、Reduce Motion、Reduce Transparency 和最小命中区域要求。
5. 导入数据在任何替换发生前明确展示影响并二次确认；取消和校验失败不得改变当前数据或撤销历史。
6. 指定日期支持任意有效日期；补齐全局搜索、Quick Entry、多选批量操作和拖放调整当日优先级等桌面生产力路径。
7. 视觉单位减少，设置、日历、任务行和空状态形成更清晰的扫描层级；品牌时间／日晷语言保持克制；小尺寸 App icon 有独立 optical size。
8. 不损失现有 Day Todo、任务链、日轨迹、子任务、分类、同步、烛龙、复盘、持久化和菜单动作能力。
9. `make check`、真实 `.app` E2E、关键截图、console、持久化探针、DMG 打包与安装启动全部通过；新增行为有可失败的自动化断言。

## 现状与证据

### 基线

2026-07-15 在本分支改动前运行 `make check`：

- Swift build 通过；
- 521 项测试通过，0 失败，1 项既有 live iCloud 条件跳过；
- 确定性仿真通过；
- SwiftLint 与 SwiftFormat lint 通过；
- 当前仓库没有 Dockerfile、compose、生产 endpoint 或容器化部署入口，因此不虚构 deployed／container 验证。

### 审查评分

| 维度 | 分数 | 结论 |
| --- | ---: | --- |
| UI 精细度 | 7.3／10 | 核心工作台完整，但小尺寸、信息密度和状态反馈仍不一致 |
| 商业化美观 | 6.7／10 | Day／详情与烛龙首页较成熟，设置、日历和品牌系统仍像工程面板 |
| 信息扫描 | 6.2／10 | 行内信号过多，宽窗口下身份和动作分离过远 |
| 品牌一致性 | 6.3／10 | 暖色日晷图标与蓝色／多色工作台尚未形成共同语言 |
| 原生视觉 | 5.5／10 | 已有真实 AppKit chrome，但主体仍大量模拟 Web dashboard |
| 原生 UX | 4.2／10 | 菜单、Settings、键盘选择、分栏、窗口恢复和桌面生产力路径不足 |
| 无障碍与本地化 | 3.5／10 | English 混排、微小字体、低对比和辅助功能分支缺失 |
| 发布就绪度 | 4.0／10 | 生产日期错误、破坏性导入、E2E 失败与无确认视觉基线阻止发布 |

### 必须修复的问题

#### P0：正确性、数据安全与门禁

1. `NoonmarkStore.today`、`selectedDate` 和 `selectedCalendarDate` 固定为 `2026-07-05`。2026-07-15 的生产截图 `artifacts/runtime-ui-audit/production-today-2026-07-15.png` 仍把 7 月 5 日标为今天。
2. 生产 `init`、`loadOrSeed` 与 `applicationDidBecomeActive` 没有日结束处理。只替换固定日期仍会让跨日后的旧 Day Todo 保持未锁定。
3. `artifacts/runtime-ui-audit/english-day-detail.png` 与 `artifacts/runtime-ui-audit/english-zhulong.png` 显示 English 导航与中文日期、状态、详情和 placeholder 混排。日期函数固定中文与 `zh_CN`，源码仍有大量直接中文字符串。
4. 数据导入在选择文件后直接 `replaceForDataImport` 并清空撤销历史，没有在替换前说明不可撤销影响并要求确认。
5. 全新 `scripts/test-e2e` 在窗口 resize 检查失败：actual content `960×730`，预期 `960×720`；证据在 `artifacts/e2e-window-resize/result.txt`。失败后的探针没有继续执行。
6. `scripts/test-visual-regression` 正确拒绝无用户确认 reference 的运行；当前没有默认 reference，不得自行把新截图声明为视觉 ground truth。

#### 原生 Mac 外壳与交互

1. 主菜单只有 App／Edit／View，App 菜单只有退出；缺少 About、Settings `⌘,`、Services、Hide、File、Window、Help 等标准结构。
2. Settings 被建模为侧栏普通页面，不是 App 菜单和独立 Settings scene／window。
3. Markdown `NSTextView` 捕获 Tab／Shift-Tab 并插入四个空格，破坏原生 full keyboard access；Quick Add 也受影响。
4. 多数行依赖 `.onTapGesture`，没有稳定的键盘选择、焦点环、selected trait、多选与 responder-chain 命令。
5. 左栏、中栏和详情栏用固定 `HStack` 宽度，不可由用户拖动 divider；detail rail 只在 248／280pt 间硬编码。
6. `NSWindow.isRestorable = false` 且每次居中，窗口位置、尺寸、栏宽和折叠状态不能恢复。
7. 领域撤销栈只有 20 项且无 redo；菜单标题不反映具体可撤销／重做动作。
8. 缺少拖放调整当日优先级、全局搜索、多选批量操作和独立 Quick Entry 命令／窗口。
9. 当日优先级按钮约 `14×11pt`，低于 macOS 小控件与可点击目标要求。
10. 日期弹窗只给今天前 7 天到后 21 天，无法满足“指定任意日期”。
11. 自绘 note popover、分类 overlay 和部分 sheet 缺少完整的焦点圈闭、Escape、初始焦点与 VoiceOver modal 语义。

#### 无障碍、本地化与适应性

1. 全局字体 scale `0.92` 把 10.5pt 压至 9.5pt、12pt 压至 11pt，测试反而锁定了不可读 microcopy。
2. 固定 RGB 的 `text3` 在冷灰／暖纸背景约为 2.53:1／2.91:1，小文本不满足 4.5:1。
3. 固定浅色是产品基调，可以保留；但颜色与材料必须使用系统语义、Increase Contrast 和 Reduce Transparency 分支，不能把“浅色”误作固定 RGB 的理由。
4. 缺少 Reduce Motion、Increase Contrast、Differentiate Without Color 与 Reduce Transparency 行为。
5. toast 2.2 秒后消失，没有 live-region／announcement，也没有让重要结果保持可查询。
6. 部分图标按钮无可读 label，导航选中项没有 selected trait。
7. VoiceOver 真实运行审查曾因系统 assistive access 未授权而无法完成；这必须作为发布前人工门禁，而不是假定通过。

#### 商业化视觉与品牌

1. Day／详情关系和烛龙首页最成熟，应保留；任务行同时堆叠状态圆点、chip、轨迹、进度和动作，产生重复视觉单位。
2. 日历一次呈现 30 多个圆角卡片，形成“卡片墙”；右栏窄宽下摘要截断。
3. 设置页像 Web dashboard：六个 pill tab、大卡片、恒常诗文并存；“组织”过空，“同步”过密。诗文应移到 About／onboarding 或可折叠次要区域。
4. 所有空状态复用同一个淡时钟，缺乏页面语义和直接下一步。
5. App icon 大尺寸概念成立，但 16px 几乎为空、32px 辨识度很弱；需要独立小尺寸构图。
6. 暖色 icon 与冷蓝、多色导航缺乏连接；只允许以克制的太阳高度／刻度／时间线语言连接，不增加装饰卡片。
7. 部分旧截图的黑色区域来自 alpha／capture viewer，不能当作已证实的运行时暗色 bug；应修复截图稳定性并以真实窗口取证。

#### 架构与契约

1. `App/NoonmarkMacApp/NoonmarkMacApp.swift` 约 15,400 行，app composition、store、格式化、菜单、窗口、页面和组件集中在一个文件，修改局部 UI 会牵动整个应用。
2. `NoonmarkMacUIContractTests` 多为 enum／常数自证，能证明“列出了元素”，不能证明真实行为、焦点、尺寸、菜单、跨日或本地化成立。
3. 旧设计契约把侧栏“背景＋左条＋彩色图标＋计数”、任务行多重状态信号等视觉冗余写成强制项。根本修复必须先修订契约，再改实现和测试，不能在实现层逐点抵消。

### 必须保留的优势

- 真正的 `NSWindow`、full-size content titlebar、traffic lights、关闭不退出与 Dock reopen；
- 统一浅色连续工作台、低边界与语义状态色；
- Day／详情关系、任务链／轨迹／延续领域逻辑与烛龙首页；
- 系统 context menu、真实 `.app` E2E、SQLite 持久化探针；
- 中文 IME Return 处理、进度 slider 的 accessibility adjustable action；
- macOS 14 最低目标。不得伪造只属于新系统的 Liquid Glass；采用标准组件让新系统自然适配。

## 设计原则与模块边界

### 深模块词汇

- **Module**：对调用方隐藏决策的实现单元。
- **Interface**：调用方真正需要知道的少量入口。
- **Seam**：允许替换 system／fixed、窗口／命令和持久化策略的明确边界。
- **Adapter**：把 AppKit、系统通知、文件面板或测试 fixture 接入领域边界。
- **Depth**：小接口隐藏多项复杂性；不把通知、时区、locale、timer 和 persistence 顺序泄漏给视图。
- **Leverage**：日期、copy、selection、command 和 presentation 模块应服务多个页面与测试。
- **Locality**：修改一个政策只改一个模块与其测试，不在十几个 View 中同步打补丁。

### 目标模块

| Module | 小接口 | 隐藏的复杂性 | 主要调用方 |
| --- | --- | --- | --- |
| Natural Day Context | 当前 `LocalDate`、刷新／事件流、system／fixed adapter | Calendar、时区、午夜 timer、wake、active、通知去重 | app composition、store、E2E |
| Day Rollover Coordinator | `reconcile()` | settle candidate → save → swap → publish，失败保持旧状态 | store／lifecycle |
| App Presentation | typed copy、date／time formatter、semantic theme | 中文／English、locale、plural、错误文案、辅助功能环境 | 所有 View、menu、toast |
| Mac Command Router | commands、validation、undo／redo labels | responder chain、selection、菜单、快捷键 | main menu、toolbar、Quick Entry |
| Workspace Selection | 单选／多选、focus、range、clear | 页面投影、selected trait、批量命令、selection restoration | sidebar、各列表、detail |
| Import Transaction | inspect → confirmation model → commit | 文件读取、schema 验证、摘要、原子替换、错误恢复 | Settings／File menu |
| Split Workspace | sidebar／content／inspector 状态 | divider 宽度、autosave、collapse、窗口恢复 | root shell |
| Task Presentation | row model + action set | 去重的状态／轨迹文案、菜单过滤、批量能力 | Day／Pool／Future／History／Calendar |

### Natural Day Context：Design It Twice 决策

接口必须满足以下不变量：

1. 同一时刻由一个 app-session 级 Context 解释自然日；不得由各页面各建 Calendar。
2. Context 发布的日期只表示系统观察值，不直接修改领域引擎。
3. Rollover Coordinator 对新日期执行 candidate `settleDays`、持久化和 engine swap；全部成功后才更新 store 的 `today`。
4. 日结束处理或保存失败时保留旧 engine／today，记录可见错误，并在下次 active／wake／timer 重试；不得形成内存已跨日但数据库未跨日的半提交。
5. 用户正在查看历史／未来时，跨日不强制跳回今天；只有“跟随今天”的选择才随 today 移动。
6. E2E 使用 fixed adapter 保持确定性；生产使用 system adapter。测试不得读取 `CommandLine` 或真实墙钟。
7. 格式化属于 App Presentation，不塞进 Natural Day Context。

#### Design A：三个行为入口的最小 Context

`start / withCurrent / presentation` 把每次领域操作包进 Context，Depth 与 fail-closed 最强；但 presentation 混入日期事实模块，且首轮必须一次改写所有 mutation caller，cutover 面过大。

#### Design B：可扩展 frame／capture／observe Context

独立 target 公开 frame、capture、observe、日期算术、格式、多窗口与 fixed timezone policy。它的长期 Leverage 和测试 rig 最完整；但 public Interface 偏宽，提前引入当前没有的多窗口与用户时区偏好，也再次把 locale presentation 耦合进自然日。

#### Design C：Store 作为唯一 observation 面

独立 target 只负责 moment、event 和严格日期算术，Store 负责日结束处理与 SQLite 事务。它的 Locality 最好，View 不认识 clock／Calendar／Adapter；但原方案示例在保存日结束结果前发布新的 natural day，会产生 UI 已跨日而 engine／SQLite 尚未跨日的半提交。

#### 选择：A／B／C 的收敛混合

- 新建 `NoonmarkDayContext` library target，依赖 `NoonmarkCore`；AppKit system Adapter 留在 Mac App target。
- public Interface 只保留 `moment()`、`observe(_:)` 与严格 Gregorian `offset(_:byDays:)`。多窗口、固定时区设置和 formatting 不进入首轮 public API。
- package seam 是 `NaturalDayEnvironment.sample/start`；production 与 fixed test／E2E 是两个真实 Adapter。
- Store 是唯一 SwiftUI observation 面，并拥有 `DayRolloverCoordinator`。Context 只发 candidate moment，绝不直接发布业务已应用状态。
- 启动以及每次领域 mutation 前都走同一 reconcile：sample → block mutation → clone engine → `settleDays` → SQLite save → swap engine → 清有限撤销 → 更新 `today` 与 follow-today selection → unblock。
- 日结束处理／保存失败时旧 engine、旧 committed today、SQLite 和 selection 全部不变；显示持久错误并在下次 signal／active／wake／Retry 重试。
- 日期与时间显示进入独立 App Presentation Module；locale 改变只重绘文案，不触发日结束处理。
- `@MainActor` 串行 Context、Adapter token、Store 与 Coordinator；跨边界的 moment／event／failure 都是 `Sendable` 值。

这个选择保留 A 的操作前刷新与 fail-closed、B 的独立 target／system-fixed seam、C 的 Store observation 与领域事务 Locality，同时删除三者不必要的 Interface 面。

## 实施阶段与无损 cutover

1. **契约与基础模块**：修订设计契约；建立 Natural Day Context、Rollover Coordinator、App Presentation 和行为测试 target。
2. **正确性与数据安全**：生产自然日／日结束处理、本地化、破坏性导入确认、任意日期；先清 P0。
3. **原生 App shell**：标准菜单、Settings window、window restoration、split view、command router、Undo／Redo。
4. **桌面交互**：键盘选择、焦点、多选、搜索、Quick Entry、拖放、context／overflow action 共用。
5. **无障碍与视觉系统**：语义字体／颜色、系统环境分支、控制尺寸、toast announcement、modal 焦点；精简任务行、日历和设置视觉单位。
6. **品牌与资产**：页面语义空状态、克制的时间刻度语言、小尺寸 App icon optical variants。
7. **架构收束**：按 app composition、store modules、presentation、shell、pages、components 分拆 15k 行文件；每次移动先保证行为对等再 cutover。
8. **发布验证**：全量 check、真实 `.app` E2E／截图／console／持久化、DMG 安装启动、人工 VoiceOver；最后执行独立 Standards／Spec code review。

每个阶段采用小步可回退 commit。旧路径只在新模块达到能力对等之前保留；一旦 cutover 就删除旧分支，禁止长期双写、双日期源或双 action 定义。

## P 级风险控制

### 风险

| 风险 | 影响 | 控制 |
| --- | --- | --- |
| 日结束处理时间或顺序错误 | 锁错日期、历史可改、数据分叉 | fixed clock／timezone 测试；candidate 原子保存；启动、午夜、wake、active E2E |
| 导入替换误操作 | 用户数据丢失 | inspect 与 commit 分离；摘要＋明确二次确认；取消／失败不变测试 |
| 大文件拆分引入行为损失 | 页面、自动化或同步回归 | tracer commit；先移动后改变；真实路径 E2E；禁止删能力换结构 |
| 本地化遗漏 | English 混排或格式错误 | typed copy；静态 hardcoded-string 守卫；中英双跑截图／E2E |
| 原生控件 cutover 改变布局 | 视觉回归、窗口门禁失败 | 固定窗口尺寸断言＋多尺寸截图；无 reference 时人工审查，不伪造 baseline |
| Selection／Undo 跨页状态错误 | 命令作用到错误任务 | typed selection；menu validation；单选／多选／文本 responder 行为测试 |
| 无障碍优化造成品牌漂移 | UI 失去统一性 | 语义 token 同时定义默认与系统增强分支；真机环境截图和 Accessibility Inspector |

### 回滚

- 工作只发生在 `codex/ui-native-commercial-overhaul`；`main` 不受影响。
- 每阶段独立 commit，可通过普通 `git revert` 回退；禁止 `reset --hard` 和裸 force push。
- 数据 schema 原则上不变；若后续确需新 schema，晷迹未发布，仍遵守 clean cut，不迁移、不备份、不兼容旧开发数据。
- 自然日 cutover 前保留 fixed E2E adapter；不保留生产固定日期 fallback。生产 Context 无法取得有效日期时 fail closed 并展示错误，不回落到 2026-07-05。
- 导入、同步和跨日都在候选引擎／事务中完成，失败不 swap，因而无需数据层“补偿回滚”。

### 灰度策略

当前没有 production deployment 或用户流量，灰度以分支内能力对等门禁执行：

1. 新模块先由 fixed adapter 和行为测试覆盖，不接生产 composition；
2. 真实 `.app` audit bundle 验证后才切 system adapter；
3. 每个 View／command 只有在新路径覆盖旧 action set 后才删除旧路径；
4. Settings、split 和 selection 先在 E2E 专用启动参数下覆盖异常路径，再成为默认；
5. 视觉 reference 只有用户明确确认真实 App 截图后才建立，不把本分支截图自动升级为门禁。

### 监控与可观察性

- lifecycle 日志记录 natural-day 事件来源、旧／新日期、rollover 是否执行及失败分类，不记录任务正文；
- E2E anchor／probe 验证 today、锁定状态、selected date、菜单、窗口 frame／divider、焦点、语言、导入确认和持久化重启；
- console 中不得出现 crash、SwiftUI runtime warning、constraint conflict、persistence failure 或 accessibility action failure；
- SQLite probe 验证日结束处理、导入和重启后的 snapshot；
- DMG 安装后从 `/Applications` 等价路径启动并验证菜单、Settings、Quick Entry 和数据目录；
- 发布前人工跑 VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Motion、Reduce Transparency 和 Differentiate Without Color。

## 验证矩阵

| 范围 | 自动化 | 真实运行证据 |
| --- | --- | --- |
| 自然日 | system／fixed、DST、timezone、midnight、wake、失败重试单元／集成测试 | 真实 `.app` 启动日期、跨日或注入事件、SQLite 锁定探针 |
| 本地化 | typed copy 完整性、无硬编码 UI 字符串、formatter 测试 | 中文／English 全页面截图和菜单检查 |
| 导入 | inspect／cancel／invalid／confirm／atomic replace 测试 | NSOpenPanel → confirmation → restart probe |
| Shell | menu tree、command validation、window autosave、split state 测试 | close／reopen、resize、divider drag、Settings／Quick Entry |
| 列表交互 | selection、range、多选、drag reorder、undo／redo 测试 | mouse＋keyboard＋context menu 用户路径 |
| 无障碍 | labels、traits、hit target、environment policy 测试 | VoiceOver／Full Keyboard Access／系统辅助设置 |
| 视觉 | token／layout contract 与多尺寸 snapshot 产物 | 960×720、1200×768、宽窗口真实截图；用户确认后才建 reference |
| 发布 | `make check`、`scripts/test-e2e` | DMG 打包、安装、启动、console、持久化 |

## 实施与验证记录

### 已实施

- 以 `NoonmarkDayContext`、system／fixed adapter 和 Store 原子 reconcile 取代生产固定日期；启动、午夜、wake、active、时区改变和 mutation 前检查共用同一事务边界。
- 建立 typed bilingual copy 与 formatter，拆出 Mac command／Store message presentation；静态 localization literal guard 当前为 0 个已知遗漏。
- 建立标准 App／File／Edit／View／Window／Help 菜单、独立 Settings／Quick Entry／Search／Help 窗口、可恢复主窗口与可调整三栏 split view。
- 建立 typed workspace selection、多选／range selection、键盘移动、批量完成／排期／回池、原生拖放调整当日优先级、具体 Undo／Redo 标题与持久化失败原子回退。
- 数据导入改为 inspect → summary → confirmation → atomic commit；取消、无效包和保存失败均不得修改 engine、SQLite、selection 或 undo history。
- 修订字体、对比、系统辅助设置分支、命中区域、空状态、任务行、日历、设置和烛龙视觉层级；小尺寸 App icon 使用独立 optical variants。
- 原有约 15,400 行的 composition 文件已按 app composition、Store、shell、page、detail、presentation 和 E2E automation 分拆；生产 bundle 的 internal launch arguments 默认 fail closed。
- 原有 1,143 行、同时承载命令、工作区、设置、烛龙与详情文案的 extension 已按 Mac Commands、Workspace、Task Detail、Settings／Provider 与 Zhulong Context 五个 surface 分拆。
- 左侧导航使用克制的页面语义色，只给 glyph 着色，文字、计数与 selection surface 保持中性。Day、任务池、未来、未完成、已完成、日历与烛龙分别使用 blue、teal、purple、orange、green、pink 与 purple 家族。
- 当日优先级现在只允许待完成日轨迹参与。领域层重排只交换 pending 投影占用的既有 priority 槽位，终态日轨迹的 priority 与 `contentUpdatedAt` 不变；Store 邻接计算与 SwiftUI drag／drop availability 使用同一边界。
- `changeTrace` 产生的新承诺改为追加到当日末尾，避免覆盖既有 priority；`updatePriority` 从裸整数 setter 收束为 pending 槽位重排语义，并为 rank 冲突增加稳定 tie-break。
- 真实 File → Import → `NSOpenPanel` → 取消／确认 → SQLite → 重启路径已进入默认 E2E，不再由环境变量选择性跳过。
- 未来计划回池不再覆盖或删除关系事实：Core 使用 append-only `cancelledDraft` 保存取消身份，所有用户 projection、搜索、烛龙、AI 与同步路径显式排除内部事实；恢复只追加带 witness 的前向版本。
- Core 建立唯一 `DayTraceCompletionCapability`，完成 glyph、context menu、bulk 与 `markCompleted`／`undoCompleted` 共用 evaluator；已处理完子任务的父任务可完成／撤销，只有当前 trace 的开放子任务阻止完成。
- Settings、Search 与 Help 共用 `installNoonmarkResizableHostingContent`，SwiftUI minimum frame、hosting `.minSize` 和 AppKit content minimum 成为同一尺寸契约。
- 父任务和子任务完成控件补齐稳定 AX identifier、button trait 与 capability label；E2E 只用 AX 读取状态，所有 mutation 均通过真实 WindowServer 输入。
- `WindowServerInputDriver` 对 pointer settle、left-button down／up 和异常释放 fail-closed；Help 的 `⌘?` 归还 `NSApp.helpMenu` 标准语义，并由物理 `Shift-Command-/` 验证 menu tracking。
- Natural Day rollover 失败重试覆盖 completion mutation；跨日持久化失败时 snapshot、旧日 trace status 与已应用日期保持不变，重试成功后才发布新自然日。
- Storage 使用共享 UInt64 bit-pattern 日期 codec；SQLite 保存可读投影与 exact bits 并对账，planned subtask、note 和数据包 nested JSON 复用同一 codec，非有限日期一律拒绝。
- 数据包失败导入 E2E 会先证明可重试 preview 保留，再撤下确认 sheet、等待没有 attached sheet 后经共享终止器退出；脚本对“已写结果但进程未退出”限时 fail-closed。

### 已取得的证据

- 最终 `make check` exit 0：build、UT／IT／ST、896 项测试、确定性仿真、UI localization literal guard、Natural Day public boundary、runtime evidence、三套 validation evidence contract、code-signing policy、DMG observer lifecycle、SwiftLint 与 SwiftFormat 均通过；仅 1 项明确 opt-in 的 live iCloud 测试按设计跳过，0 失败、0 lint violation、0 format drift。manifest 绑定最终 source start／end tree、日志 SHA 与 fresh inventory；真实 App 与 DMG 同源链以 issue ledger 的最终 run 为准。
- 最新稳定签名完整真实 `.app` E2E exit 0，生成中／英文全页面与 presentation 截图，并通过 OCR、菜单、窗口、Help、completion control、workspace productivity、task note、导入、SQLite、restart、Natural Day 和原子失败探针；所有新增运行日志与 Diagnostic Reports 门禁干净。
- 侧栏语义色以真实截图中每个 glyph crop 的 hue pixel probe 验证；`day.png` 的 Day／任务池／未来／未完成／已完成／日历有效像素数分别为 206／316／366／198／175／284，`zhulong.png` 的烛龙有效像素数为 153。默认 E2E 同时要求两张截图通过。
- 拖放分段诊断显示四个真实 SwiftUI destination 均已挂载，但旧路径一次也未进入 `isTargeted`；数据层和 SQLite 均未发生变更。运行证据确认 `CGWarpMouseCursorPosition` 只移动光标，而 `window.postEvent` 只进入 AppKit 本地队列，无法建立 WindowServer 左键状态或原生 drag session。
- E2E 输入已收束为共享 `WindowServerInputDriver`：登录 session 使用单一 retained `.combinedSessionState` source，把 AppKit window point 显式转换为 Quartz global point 并 round-trip 对账，所有 down／drag／up 都发布到 `.cghidEventTap`。拖放状态机等待 source cursor、系统 button state、精确 destination targeted、精确 payload accepted 和 button release；异常路径只要曾投递 down 就无条件以同一 source／gesture 补发 up，确认释放后才恢复光标。选择点击和 `NSOpenPanel` 键盘路径复用同一权限与 source policy。
- 解锁后的真实授权探针已经证明用户为两个精确 ad-hoc bundle 配置的 Accessibility 权限有效；直接执行 helper 时 TCC 把 Terminal 识别为 responsible process，经 LaunchServices 启动同一 helper 时 `AXIsProcessTrusted` 与 event-posting preflight 均为真。DMG helper 因此改为 LaunchServices 启动，并用 launch token、bundle／path／command identity、`EVFILT_PROC` 与 kernel exit status 对账真实进程。
- workspace 原生拖放已进入 WindowServer 左键状态并建立 native drag session；unified log 随后揭露 `app.noonmark.task-priority` 未在 App `Info.plist` 导出的根因。当前 build 已声明该 exported UTI，App build、DMG 验证与安装验收均新增 metadata fail-closed 门禁。
- E2E seed fixture 已从固定 2026-07-01 至 2026-07-07 改为相对当前自然日的 `today-4...today+2`。`seed()` 现在传播领域错误而不是以 assertion 终止；2030-07-01 的真实 `.app` probe 同时验证未来计划仍为 pending，覆盖“测试日期过期后启动崩溃”的回归。
- split workspace 现在区分页面自动详情宽度与用户自定义宽度：Day 等标准页默认 280pt，日历默认 248pt；用户真实拖动第二条 divider 后切换为全局自定义宽度，并由原生 autosave 跨页面、折叠与重启恢复。第一条 divider 的 sidebar 宽度独立保存，不受详情栏自动模式重置。恢复 E2E 使用真实 WindowServer divider drag，并覆盖 calendar → Day 自动宽度纠正、sidebar 264pt 与 detail 336pt 的跨重启保持。
- Settings sidebar 与六个 pane 同时保留 SwiftUI Accessibility identifier 和无视觉、非 AX、hit-test 穿透的 AppKit E2E anchor。真实窗口探针验证独立 key/main window、原生 sidebar、自动生成的 Settings toolbar 不携带主工作区栏位按钮，以及关闭后主窗口 frame 和栏位状态不变。
- 交互 E2E 与 DMG 安装入口现在自行强制稳定签名：显式 identity 优先，否则只自动选择 Keychain 中唯一有效的 `Apple Development` identity；零个或多个候选均拒绝继续。解析、脱敏和真实零身份失败路径已进入 `make check`。
- Xcode Apple Account／Team 登录态、开发证书、匹配私钥、有效期与 Code Signing 用途均已由命令行确认。首次实际 `codesign` 的 unified log 揭露 `leaf MissingIntermediate`；叶子证书要求 WWDR G3，但 Keychain 只有旧 WWDR。经 Apple PKI 取得、校验并导入 `Worldwide Developer Relations - G3` 后，`security` 已报告一个有效 identity，真实临时签名、严格验证、稳定 designated requirement 与项目自动解析器均通过。
- `scripts/package-dmg release` 已生成 `dist/Noonmark.dmg`；`scripts/verify-dmg` 已通过 checksum、挂载内容、严格 code signature、canonical icon、optical variant 与 exported drag UTI 校验。App 使用稳定 `Apple Development` identity，TeamIdentifier 为 `7436PPJ79X`。
- `scripts/test-dmg-install dist/Noonmark.dmg` exit 0：从镜像复制出的生产 App 忽略内部 E2E 参数，通过真实 WindowServer 输入打开 Settings／Quick Entry、创建任务、退出并重启；同一任务经 AX 可见，SQLite joined row 逐字节保持，App／helper unified log 与 Diagnostic Reports 均干净。`spctl` 因非 Developer ID 且未公证而拒绝，符合公开发行 fail-closed 边界。

### 可回退实施节点

- `6ecc809`：App icon 小尺寸 optical variants、生成与像素探针。
- `88b89e2`：Natural Day Context、Mac Runtime 深模块、锁定日不变量与 pending-only 当日优先级领域边界。
- `b5b735a`：原生 Mac shell、工作区生产力、商业化视觉、可访问性、本地化及 App 模块拆分。
- `17a3b09`：真实 App E2E、本地化、持久化与 DMG 安装发行门禁。

这些节点均位于专用分支，可用普通 `git revert` 独立回退；每次提交后均已执行 `scripts/reset-dev-data`。

### 最终门禁状态

- 两个固定稳定签名 bundle 的 Accessibility 授权已经由 LaunchServices 真实启动探针验证；问题不在重复授权，而在旧 ad-hoc 重编译会改变 `cdhash` identity，以及 App bundle 曾漏报拖放 UTI。稳定 `Apple Development` identity、固定 bundle identifier、UTI 元数据和自动解析器已经共同消除这两个根因。
- 所有仓库内可自动执行的正向门禁均已通过；脚本在锁屏时仍 fail-closed，并以 `caffeinate` 保持显示器和交互 session，不得用 Terminal 权限、本地 `NSEvent` 注入或模拟结果替代。
- VoiceOver、Full Keyboard Access 与系统辅助设置组合仍是发布前人工门禁；当前自动化只覆盖 label、trait、keyboard action、environment policy 与可见 presentation。
- 原 release workflow 会把 Apple Development 签名产物直接写入 GitHub Release，现已降级为只读、仅限 `main` 手动触发的开发签名发行验收，并明确输出 `development-signed-not-for-distribution` artifact。公开发行在取得 Developer ID Application 证书，并补齐 Hardened Runtime、secure timestamp、notarization、staple 与 Gatekeeper 验收前保持 fail-closed；开发签名 DMG 不得冒充商业发行产物。
- 当前没有用户确认的真实 App reference，视觉回归仍不设默认 baseline；当前没有 Docker／deployed endpoint，不虚构容器或线上验证。
- 本轮没有剩余的仓库内重大 blocker；剩余发布边界只有 UI-018 的人工辅助功能组合验收，以及 UI-019 的 Developer ID／公证外部资产。

## 完成定义

仓库内完成要求成功标准中可自动执行的门禁、独立 Standards／Spec review 与分支提交全部完成；UI-018／UI-019 不得在仓库内伪造通过。只有人工辅助功能组合验收及 Developer ID／公证／Gatekeeper 门禁另行完成后，才可把产品状态描述为可公开商业发布。单独的 build、单测、截图或文档都不能代表仓库内闭环。

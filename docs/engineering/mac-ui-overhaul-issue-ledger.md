# Mac UI 原生化与商业化升级问题台账

## 文档职责

- 日期：2026-07-18
- Task-ID：`mac-ui-native-commercial-overhaul`
- 分支：`codex/ui-native-commercial-overhaul`
- 范围：记录本轮实施和验证过程中出现的重大产品、代码、数据、运行时、签名与发行问题。

原始审查结论和完整问题清单仍以
`docs/design/mac-ui-native-commercial-overhaul.md` 为准；本台账补充实施过程中实际复现的问题、根因、根修和验证证据。

以下情况必须登记：

- 真实 App 崩溃、数据错误、持久化错误或用户路径失败；
- 同一测试路径稳定出现的 SwiftUI／AppKit／Accessibility 运行时告警；
- 设计契约、领域规则与多个 UI 入口之间的行为漂移；
- 签名、TCC、发行或供应链门禁会造成重复授权、误发布或错误安全结论；
- 为根修而新增跨模块领域事实或架构决策。

一次性工具输出、无行为影响的编译提示和已由重跑证明为环境瞬态的噪声保留在运行日志，不单独登记为产品问题。若它们再次出现、影响门禁或揭露错误假设，必须升级为本台账条目。

状态：

- `已验证`：根修已由对应真实路径或测试门禁证明；
- `待全量回归`：专项路径通过，仍等待本轮最终完整门禁；
- `处理中`：根因已确定，正在实施；
- `人工门禁`：自动化不能替代人工辅助功能验收；
- `外部阻断`：缺少当前仓库不能自行产生的 Apple 发行资产。

## 问题记录

### UI-001：生产自然日固定在 2026-07-05

- 状态：已验证。
- 症状：系统日期已经变化，生产 App 仍把 2026-07-05 当作今天。
- 根因：Store 使用固定日期，启动、跨午夜、时区变化、睡眠唤醒和重新激活没有统一自然日协调。
- 根修：建立 Natural Day Context 与原子 rollover；先结算和持久化旧日，再发布新的 `today`。
- 证据：Natural-day Core／Storage 测试，以及 `artifacts/e2e-natural-day/` 的 wake、失败重试、时区往返与重启 SQLite 对账。

### UI-002：English 界面混入中文日期、状态和文案

- 状态：已验证。
- 症状：English 导航下仍显示中文日期、状态、详情和 placeholder。
- 根因：用户可见文案与 formatter 分散在 View 和 Store，部分路径固定 `zh_CN` 或直接写中文。
- 根修：集中 App copy 与 locale-aware formatter，presentation boundary 拒绝内部状态泄漏；SwiftUI 系统控件使用 App language 对应的 `zh-Hans-SG`／`en-SG` locale，Search 空结果使用 typed copy，不调用随 macOS 语言变化的 `ContentUnavailableView.search` 文案。
- 证据：`AppPresentationTests.testApplicationLanguageOwnsTheSwiftUISystemControlLocale`、`artifacts/e2e/english-*-ocr.log` 与对应真实 App 截图；最新系统控件改动仍随本轮最终 full E2E 复核。

### UI-003：数据导入在确认前替换当前数据

- 状态：已验证。
- 症状：选择文件后直接替换数据库并清空撤销历史。
- 根因：导入接口把 inspect、confirmation 和 commit 合并成一次副作用。
- 根修：拆成 inspect → confirmation model → atomic commit；取消、校验失败和写库失败均保持原状态。
- 证据：`artifacts/e2e-data-import-ui/`、`artifacts/e2e-data-package-import-failure/` 和完整 SQLite 对账。

### UI-004：最小窗口 E2E 得到 960×730，而非 960×720

- 状态：已验证。
- 症状：窗口 resize 门禁失败，后续探针被阻断。
- 根因：窗口 frame／content 尺寸契约混用，原生 chrome 高度未在正确层处理。
- 根修：明确 frame 与 content contract，并由真实窗口路径断言最小、默认和宽窗口尺寸。
- 证据：`artifacts/e2e-window-resize/` 与 960×720、1200×768、1440×900 真实截图。

### UI-005：主窗口缺少原生 Mac 命令、Settings 与恢复语义

- 状态：已验证。
- 症状：菜单不完整，Settings 是工作区普通页面，窗口位置、栏宽和折叠状态不能恢复。
- 根因：App shell、页面导航和命令职责集中，未使用标准 AppKit 窗口与 responder-chain seam。
- 根修：补齐标准菜单、独立 Settings／Search／Quick Entry／Help 窗口、原生 toolbar、可恢复主窗口与命令路由。
- 证据：`artifacts/e2e-native-command-surface/`、`artifacts/e2e-window-close/` 和
  `artifacts/e2e-workspace-restoration/`；最新完整 E2E 覆盖标准菜单、四个独立窗口、窗口最小尺寸、关闭恢复和 divider 跨重启。

### UI-006：Markdown Tab／Shift-Tab 破坏原生键盘焦点

- 状态：已验证。
- 症状：Tab／Shift-Tab 被编辑器当作缩进，或 Shift-Tab 在 LaunchServices 启动路径不能移向上一个控件。
- 根因：编辑命令未区分修饰键语义；多个窗口没有启用动态 key-view loop，AppKit 首次 forward traversal 前也未建立完整 loop。
- 根修：仅 Option-Tab 插入四空格；Tab／Shift-Tab 分别执行 next／previous key view；所有原生窗口启用动态 key-view loop，并以真实 first responder 关系断言。
- 证据：`artifacts/e2e-markdown-editor/`；`NOONMARK_E2E_MARKDOWN_ONLY=1 scripts/test-e2e debug` 已通过。

### UI-007：详情栏宽度在布局中持续收缩或覆盖用户选择

- 状态：已验证。
- 症状：详情栏出现 1128 → 1016 等尺寸反馈，页面切换或重启后自动宽度和用户自定义宽度互相覆盖。
- 根因：SwiftUI `PlatformViewHost` fitting 与 `NSSplitViewController` 布局形成反馈；详情栏曾使用 inspector 语义；恢复时没有区分自动和用户自定义宽度。
- 根修：详情改为普通 split item；`sizeThatFits` 接受明确尺寸；布局恢复移出同步递归；自动宽度与用户拖动宽度采用独立状态。
- 证据：`artifacts/e2e-workspace-restoration/`，覆盖 calendar 248pt、标准页 280pt，以及 sidebar 264pt／detail 336pt 跨重启保持。

### UI-008：Xcode 已创建证书，但 `security find-identity` 显示 0

- 状态：已验证。
- 症状：Keychain 中可见 Apple Development 叶子证书和私钥，codesigning identity 仍为零。
- 根因：叶子证书要求 WWDR G3 issuer，本机只有旧 WWDR intermediate。
- 根修：从 Apple PKI 取得并校验 `Worldwide Developer Relations - G3`，导入登录 Keychain；解析器对零／多身份 fail-closed。
- 证据：当前 `security find-identity -v -p codesigning` 返回唯一有效身份；真实 `codesign --verify --deep --strict` 与稳定 designated requirement 通过。

### UI-009：重编译后 Accessibility 需要反复授权

- 状态：已验证。
- 症状：ad-hoc 构建的 `cdhash` 改变，TCC 把新构建视为不同身份；直接执行 helper 与 LaunchServices 启动的 responsible process 也不同。
- 根因：测试 bundle 没有稳定 designated requirement，且部分输入探针绕过真实 App 启动语义。
- 根修：E2E App 与 DMG helper 固定 bundle identifier 并使用稳定 Apple Development 签名；统一由 LaunchServices 启动真实输入路径。
- 证据：两个固定 bundle 的 TCC 正向探针、WindowServer 输入、`codesign` requirement 和完整 E2E。

### UI-010：工作区原生拖放已启动，但目标不接受 payload

- 状态：已验证。
- 症状：真实鼠标进入 drag session，目标仍不接受任务优先级 payload。
- 根因：App `Info.plist` 没有导出 `app.noonmark.task-priority` UTI。
- 根修：构建产物声明 exported UTI，并在 App build、DMG 验证和安装验收中 fail-closed 检查。
- 证据：workspace productivity 真实 WindowServer drag E2E 与 bundle metadata 检查。

### UI-011：E2E App 在 `NoonmarkStore.seed()` 启动崩溃

- 状态：已验证。
- 症状：`EXC_BREAKPOINT`，栈顶为 `NoonmarkStore+Seed.swift:481`。
- 根因：绝对日期 fixture 随墙钟过期，未来计划变成历史后触发领域 assertion；`seed()` 把可诊断领域错误升级成进程终止。
- 根修：fixture 改为相对当前自然日的 `today-4...today+2`；`seed()` 传播领域错误；增加 2030-07-01 真实 App probe。
- 证据：`artifacts/e2e-seed-clock/`；专项 seed clock E2E 通过。

### UI-012：lifecycle E2E 报告 content mutation time 倒退

- 状态：已验证。
- 症状：完整 E2E 末段在 lifecycle setup 失败，错误为 `content mutation time cannot move backwards`。
- 根因：fixture 创建使用真实 `Date()`，随后 mutation 使用固定 Natural Day instant；同一事实的内容时钟因此倒退。
- 根修：lifecycle automation 的 create／schedule／change／return／abandon 全部使用同一个 `dayContext.moment().instant`。
- 证据：`NOONMARK_E2E_LIFECYCLE_ONLY=1 scripts/test-e2e debug`、最新完整真实 App E2E 和 SQLite 重启对账均通过。

### UI-013：烛龙设置路径出现两条 SwiftUI publishing warning

- 状态：已验证。
- 症状：每次点击 Settings 的烛龙侧栏都稳定出现 `Publishing changes from within view updates is not allowed`。
- 根因：`NSOutlineView` selection callback 在 SwiftUI update transaction 内写入 `NoonmarkSettingsWindowModel.@Published selectedPane`。
- 根修：Settings pane selection 成为 `NoonmarkSettingsWindowRoot` 的局部 `@State`，删除双向 ObservableObject publisher。
- 证据：LLDB 两次调用栈均指向 `OutlineListCoordinator.outlineViewSelectionDidChange`；同一真实 `.app` 路径修复前 2 条、修复后 0 条。

### UI-014：Settings 首次布局触发 AppKit layout recursion warning

- 状态：已验证。
- 症状：烛龙设置路径稳定出现一次 `layoutSubtreeIfNeeded ... already being laid out`。
- 根因：`NavigationSplitView` 在 `NSHostingView.layout` 内首次向窗口安装 toolbar，`setToolbar:` 立即重塑 content／toolbar view，形成布局重入。
- 根修：Settings controller 在设置 hosting content view 前预装稳定标识的原生 `NSToolbar`，让 SwiftUI bridge 复用既有 toolbar。
- 证据：LLDB 栈从 `NSHostingViewRootDelegate.updateToolbarBridge` 到 `NSWindow.setToolbar:`；运行时 A/B 与正式 `NOONMARK_E2E_ZHULONG_NAVIGATION_ONLY=1 scripts/test-e2e debug` 均证明 warning 从 1 降为 0，SwiftUI warning 维持 0。

### UI-015：开发签名 DMG 会被误发布为正式 GitHub Release

- 状态：已验证。
- 症状：原 workflow 使用 Apple Development 签名、未公证产物直接执行 `gh release create/edit/upload`。
- 根因：稳定 UI 签名与对外 distribution signing 被建模成同一个 release 概念。
- 根修：workflow 降级为只读、仅限 `main` 手动触发的开发签名发行验收；移除 tag 与 GitHub Release 写入；artifact 标记 `development-signed-not-for-distribution`。
- 证据：`.github/workflows/release.yml` 已无 `contents: write` 和 `gh release` 路径；最终 `make check`、release DMG 打包、strict code signature 和真实安装验收均通过。

### UI-016：未来计划回池会丢失不可覆盖关系事实

- 状态：已验证。
- 症状：未来计划回池若删除或覆盖 trace，会破坏 Undo、同步合并与子任务关系的可证明性。
- 根因：`returnedToPool` 同时承担历史状态和“取消未来草稿”两种不同语义。
- 根修：新增内部 append-only `cancelledDraft` 事实，所有用户 projection 显式排除；恢复使用带取消身份的前向新版本。
- 证据：`docs/adr/0020-preserve-cancelled-future-drafts-as-hidden-relational-facts.md`；
  Core／Storage／Sync／AI／Zhulong／Simulation 测试；`artifacts/e2e-workspace-productivity/` 的三条
  `cancelledDraft` SQLite 事实、用户 projection 排除和重启对账；最终 `make check` 896 项测试与同源真实 App／DMG 运行链共同复核通过。

### UI-017：父任务完成能力在 glyph、菜单与批量操作之间漂移

- 状态：已验证。
- 症状：任务行只按 status 判断，未来／历史 trace 可能仍呈现完成按钮；菜单按整条任务链是否曾有子任务过滤，会隐藏“子任务均已处理”父任务的完成，以及带子任务已完成父任务的撤销；bulk 又复制第三套规则。
- 根因：UI 层各自推断领域 capability，设计契约也错误写成“仅无子任务可完成／撤销”。
- 根修：在 Core 建立唯一 `DayTraceCompletionCapability` seam；查询与 `markCompleted`／`undoCompleted` 共用 evaluator，TaskRow、菜单与 bulk 只消费 capability。仅当前 trace 的 `pending`／`unfinished` 子任务阻止完成。
- 证据：Core completion capability 全矩阵；菜单与 bulk 共用 evaluator；`artifacts/e2e-completion-control/` 以真实 WindowServer 点击覆盖阻塞提示、最后一个子任务完成、父任务完成、重启及撤销；`artifacts/e2e-workspace-productivity/` 覆盖批量能力和 SQLite 对账。

### UI-018：辅助功能组合需要人工真实验收

- 状态：人工门禁。
- 范围：VoiceOver、Full Keyboard Access、Increase Contrast、Reduce Motion、Reduce Transparency 和 Differentiate Without Color。
- 当前证据：自动化已覆盖 Accessibility label／trait、keyboard action、announcement、environment policy 与真实可见 presentation，但不能把这些结果描述成完整人工体验通过。
- 未完成边界：当前未取得 VoiceOver 与上述系统辅助设置组合的人工逐项签收；稳定签名和 TCC 授权通过不等于这些人工体验已经通过。

### UI-019：公开商业发行缺少 Apple distribution 资产

- 状态：外部阻断。
- 范围：Developer ID Application、Hardened Runtime、secure timestamp、notarization、staple 和 Gatekeeper 验收。
- 当前边界：Apple Development 签名 DMG 只能证明开发安装、真实交互和持久化路径，不得作为公开下载产物。
- 当前证据：Apple Development 签名、TeamIdentifier `7436PPJ79X`、strict `codesign`、DMG 打包及安装 E2E 已通过；`spctl` 因非 Developer ID 且未公证而拒绝，符合预期并证明公开发行门禁仍有效。

### UI-020：Settings／Search／Help 窗口最小尺寸不是稳定单一事实源

- 状态：已验证。
- 症状：SwiftUI 首轮布局后可能覆盖 AppKit 的窗口最小尺寸，使辅助窗口可缩到声明尺寸以下。
- 根因：`NSHostingView` intrinsic sizing 与手工 `contentMinSize` 分属两个约束来源。
- 根修：共享 `installNoonmarkResizableHostingContent`，由 SwiftUI minimum frame、`.minSize` sizing option 和 AppKit `contentMinSize` 共同发布一个契约；三个窗口使用具名尺寸常量。
- 证据：`artifacts/e2e-native-command-surface/`；E2E 强制请求 100×100，并验证 Settings 680×500、Search 520×360、Help 520×420 仍受约束。

### UI-021：完成 glyph 缺少可证明的辅助功能与真实点击路径

- 状态：已验证。
- 症状：旧自动化无法证明父任务完成控件的 AX label、button trait、阻塞提示和真实用户点击行为。
- 根因：完成 glyph 没有稳定 AX identifier，领域调用与用户输入验证没有闭环。
- 根修：父任务和子任务完成控件增加稳定 identifier、button trait 和 capability 驱动 label；查询只读 AX，mutation 只经 WindowServer 输入。
- 证据：`artifacts/e2e-completion-control/` 覆盖开放子任务阻塞且零 mutation、子任务完成、父任务完成、重启、父任务撤销及 SQLite 精确对账。

### UI-022：WindowServer click 未严格证明按键状态和异常释放

- 状态：已验证。
- 症状：旧 click helper 投递 down／up 后不确认 combined-session button state，异常清理吞错，可能留下全局左键按下并污染后续测试。
- 根因：事件已发布被错误等同于 WindowServer 已接受；释放失败没有成为一等错误。
- 根修：等待 pointer settle、mouse-down、mouse-up；down 一旦投递，异常路径必须重试同一 gesture 的 up，并同时报告原错误与 cleanup 错误。
- 证据：native commands、completion control、workspace productivity、workspace restoration 均使用共享 driver；完整 E2E 通过且没有残留 left-button state。

### UI-023：Help 快捷键重复实现 AppKit 标准语义

- 状态：已验证。
- 症状：自定义 Help item 同时声明 `⌘?`，与 AppKit Help menu 的标准快捷键重复；旧测试只调用菜单等价路径，不能证明物理快捷键语义。
- 根因：App 命令项与 `NSApp.helpMenu` 的系统职责混合。
- 根修：Help item 不再声明 key equivalent，由 AppKit 独占 `⌘?`；真实 `Shift-Command-/` 打开原生 Help menu，再以方向键和 Return 打开独立 Help window。
- 证据：`artifacts/e2e-native-command-surface/` 验证物理键到达、menu tracking、独立可恢复窗口、最小尺寸及 `⌘W` 关闭。

### UI-024：完成操作没有覆盖 Natural Day mutation 前置协调

- 状态：已验证。
- 症状：原 natural-day 失败重试只用 priority mutation，不能证明新 completion capability 路径在跨日持久化失败时不会修改旧日事实。
- 根因：高风险 mutation seam 的症状级覆盖不完整。
- 根修：rollover E2E 在 wake 推进自然日并注入持久化失败后调用 `toggleComplete`；断言 day boundary 保持 blocked、snapshot 和 trace status 不变，重试后才结算旧日。
- 证据：`artifacts/e2e-natural-day/` 的 exercise、restart、SQLite 与 lifecycle log 对账。

### UI-025：核心日期持久化丢失 bit 精度，失败导入 E2E 又被 modal sheet 阻止退出

- 状态：已验证。
- 症状：SQLite 文本日期、planned-subtask ISO8601 和默认 note JSON 会损失亚毫秒精度；失败导入已写 `ok` 且数据库正确，但 App 不退出。
- 根因：人类可读时间投影曾被当作 canonical 时间；失败导入故意保留可重试 preview，确认 sheet 仍附着，AppKit 因 modal sheet 拒绝 `NSApp.terminate`。
- 根修：共享 UInt64 bit-pattern 日期 codec；SQLite 同存可读文本与 exact bits，并在读取时校验投影一致；nested JSON 使用相同 codec，拒绝非有限时间；失败导入先验证 preview 保留，再取消 preview、等待 sheet 完全撤下，最后走共享终止器；脚本对“结果已写但未退出”限时 fail-closed。
- 证据：Storage exact-date／projection mismatch／nonfinite tests；`artifacts/e2e-data-package/`、`artifacts/e2e-data-package-import-failure/`；专项 LaunchServices 连跑和完整 E2E 均通过，SQLite round-trip 保持 bit pattern。

### UI-026：池化页面默认摘要错误依赖烛龙开关

- 状态：已验证。
- 症状：任务池、未来计划、未完成池和已完成池在没有选中任务且烛龙关闭时没有详情栏内容；既有 summary E2E 强制开启烛龙，只证明烛龙 context rail 可用，未覆盖产品默认路径。
- 根因：`hasDetailRailContent` 把页面本地摘要能力错误等同于 `usesZhulongContextRail`；`DetailRail` 已有 `PoolSummaryRail` 与 `SidebarAnalysisRail`，却没有把它们接入未选中页面分支。
- 根修：建立不依赖 Provider 的 page-summary rail seam；任务池复用专用本地摘要，另外三页复用本地分析模型，烛龙只保留轻量能力提示，不再决定详情栏是否存在。
- 像素契约：沿用现有通用 `280pt` detail rail、既有 detail padding 与线性滚动面，不新增第二层外框或页面级空状态。
- 验证：烛龙关闭时逐页等待真实可见、全局唯一的 summary anchor；开启烛龙后同一 anchor 仍存在；选中任务后详情覆盖摘要，清除选择后摘要恢复。`NOONMARK_E2E_SUMMARY_SIDEBAR_ONLY=1 scripts/test-e2e debug` 已通过。

### UI-027：日历热度与状态标识偏离设计契约

- 状态：已验证。
- 症状：月历格子以完成比例文字替代完成热度块，并以状态 glyph 替代任务状态色点。
- 根因：局部信息密度重排绕过了日历页面既有视觉契约，把完成比例和完整 glyph 重复引入紧凑月历格。
- 根修：恢复共享 `CalendarDaySummary.heatLevel` 驱动的热度块，以及 `TraceStatus.uiStyle.dotColor` 驱动的状态色点；完成比例只保留为 accessibility value。
- 像素契约：热度块 `10×10pt`、圆角 `2.5pt`；任务状态点 `4×4pt`；任务标题继续使用共享 title color 与终态删除线。
- 验证：真实 App view tree 同时出现当日热度 anchor 与状态点 anchor，anchor verification 对账 heat level／status；专项 summary／calendar／timeline 真实 App E2E 已通过。

### UI-028：已延续待完成缺少共享废弃入口

- 状态：已验证。
- 症状：未完成任务已有活跃轨迹时，列表右键菜单为空，详情三点菜单被隐藏；用户只能跳转活跃轨迹，不能执行契约要求的废弃。
- 根因：菜单把“不能再次延续”错误实现成“没有任何动作”，没有把 active trace 作为废弃动作的目标。
- 根修：抽出未完成条目的共享 action projection；已延续待完成只提供废弃，普通未完成提供延续／废弃，已废弃提供重新启用，列表与详情消费同一投影。
- 像素契约：详情继续使用现有 `22pt` 纯图标菜单触发器，不新增正文操作区；列表继续使用原生 context menu。
- 验证：运行态 fixture 先形成历史 unfinished 再延续到当前日，断言共享 projection 只有废弃；真实列表 context menu 与详情 menu 执行后，两条活跃轨迹及任务链均进入废弃事实；SQLite／LaunchServices 重启探针为 `2 2 2 0`。

### UI-029：任务轨迹时间线重复定义状态样式

- 状态：已验证。
- 症状：时间线把 `.continued` 映射成 `.unfinished` 文案与 warn 样式，并为 pending／completed／unfinished 重复定义颜色。
- 根因：`TimelineNodeStyle` 没有把 `TraceStatus.uiStyle` 当作唯一 presentation source，导致状态语义在详情时间线漂移。
- 根修：除当前 pending 节点的边框强调外，glyph、label、前景、背景与边框全部直接从共享 `TraceStatus.uiStyle` 派生；文案直接使用实际状态。
- 像素契约：保持现有 `14×14pt` 圆形节点和当前节点背景，不新增 chip；`.continued` 使用共享 arrow／chip／t2 映射。
- 验证：自动化 fixture 包含 continued 历史节点，真实 view-tree anchor 对账实际 status、glyph 与 label；专项 summary／calendar／timeline 真实 App E2E 已通过。

### UI-030：未完成操作 E2E 的 fixture 时钟晚于真实交互时钟

- 状态：已验证。
- 症状：原生 context menu 已执行废弃菜单项，但 Store 报告 `content mutation time cannot move backwards`，随后自动化误报为菜单没有执行。
- 根因：E2E bundle 使用固定 Natural Day instant，新增 fixture 却以墙钟 `Date()` 建立任务，并继续写入未来六秒；真实菜单 mutation 使用固定 day-context instant，必然早于 fixture 的内容时间前沿。
- 根修：建立共享 `E2EFixtureTimeline` seam，由它取得已协调 Natural Day、生成严格递增且全部早于用户 mutation 的 fixture 时间，并对多取、少取和跨时钟域 fail-closed；未完成操作、摘要、完成控件、工作区生产力、lifecycle 与重新启用原子性路径均改用该 seam，脚本显式传入固定 instant／time zone。领域层的内容时间单调校验保持原样。
- 验证：专项真实 `.app` E2E 已证明 AppKit 菜单执行、两条 active trace 精确进入废弃、SQLite 保存与 LaunchServices 重启后 action projection 保持；同一 seam 下的 summary、completion、workspace productivity 和 lifecycle 专项均通过，日志不再出现该内容时钟错误。

### UI-031：异步 WindowServer 输入可能落到已经变化的窗口

- 状态：已验证。
- 症状：自动化在取得控件坐标后，sheet、key window 或 modal state 变化时仍可能向旧坐标投递 pointer down／up；完成控件与导入确认路径因此出现“视觉上点过、真实动作没有发生”或退出被残留 sheet 阻塞。
- 根因：共享输入驱动只校验全局 App 激活和坐标，没有把一次 gesture 绑定到最初解析出的 `NSWindow` identity，也没有在 repost、down 与异常清理边界重新确认 expected window、key window、sheet 和 modal state。
- 根修：所有 WindowServer click／drag 都显式携带 expected window；pointer settle repost 与 button down 前重新验证 App、窗口可见性、miniaturization、key window、sheet／modal 和 button state。取消只允许在 down 前传播；一旦投递 down，清理路径忽略任务取消并在有界时间内用同一 event source 补发 up、确认释放后才返回。原始 AX 调用点必须重新解析目标并把窗口 identity 传入。
- 验证：完成控件与数据导入专项真实 `.app` E2E 已通过，并由最终完整 E2E、`make check` 和最新 DMG 安装再次复核。

### UI-032：Store mutation、分类事实与 sync journal 使用不同事务时钟

- 状态：已验证。
- 症状：墙钟回拨、固定 E2E 时钟或已存在未来事实时，Store mutation 可能因时间倒退失败；即使领域 mutation 成功，分类路径还会自行增加 `0.001s`，导致实体事实时间晚于同一 SQLite change journal 的 `changedAt`。
- 根因：应用层把 Natural Day instant 直接当作内容时钟；rollover、undo／redo、外部同步和普通 mutation 各自分配时间，分类模块又维护第二套局部时钟，事务没有唯一 canonical instant。
- 根修：`NoonmarkEngine.nextMutationDate(reference:)` 作为唯一 Hybrid Logical Clock，以所有持久事实为 frontier 并用下一 representable instant 前进；Store 先分配 `StoreMutationMoment`，同一事务内的领域事实、持久化与 journal 共用 `moment.instant`。rollover、undo／redo、同步和导入显式传递该 instant；分类专用 `+0.001s` 时钟删除并纳入统一 frontier。所有输入与持久 frontier 必须逐个验证为 finite，无法前进时 fail-closed。
- 专项证据：`MutationClockBoundaryTests`、分类 frontier、Runtime rollover 与 SQLite journal／exact-date 测试已经覆盖 future fact、墙钟回拨、non-finite 和持久化失败原子回滚；最终完整真实 App E2E、`make check` 和 DMG 已复核通过。

### UI-033：Subtask 状态撤回与难度修改没有可同步的内容时钟

- 状态：已验证。
- 症状：子任务完成后撤回会清除 `completedAt`，难度修改也不改变任何 timestamp；同步 mapper 只能退回 `createdAt` 或 terminal 时间，较新的 pending／difficulty 事实可能在 LWW 合并中输给较旧远端状态。
- 根因：`Subtask` 没有独立 `updatedAt`；完成、撤回、废弃、跨日结算／延续、难度修改与 snapshot undo 没有统一推进子任务内容 frontier。
- 根修：为 `Subtask` 增加 exact-persisted `updatedAt`，所有真实内容变化经同一 monotonic mutation seam 推进；Store 显式传入事务 instant，snapshot undo 对发生变化的子任务重新计时，Sync mapper 只使用 `updatedAt` 作为 LWW clock，SQLite 同存可读投影与 exact bits。
- 专项证据：Core 状态排列、Sync current-record merge／permutation、SQLite bit round-trip 已覆盖，`artifacts/e2e-subtask-mutation/subtask-mutation-result.txt` 为 `ok`；最终完整 E2E、`make check` 和 DMG 已复核通过。

### UI-034：Snapshot 完整性验证不足，重复 identity 可触发进程 trap

- 状态：已验证。
- 症状：畸形 snapshot 中重复 Day／definition／subtask identity、悬空 parent、非法状态时间矩阵或 planned-subtask 冲突没有在边界被拒绝；随后 `Dictionary(uniqueKeysWithValues:)` 可能以 precondition trap 终止进程。
- 根因：`NoonmarkSnapshot.validateIntegrity()` 只覆盖部分 chain／trace／classification 约束，没有在建 dictionary 前完整验证所有 identity、父子引用、日期投影、有限时间和状态矩阵。
- 根修：在恢复 Engine 前 fail-closed 验证 Day date／identity、chain／definition／trace／subtask 唯一性、所有 parent 引用、Day 与 Subtask clock、Subtask terminal 状态矩阵，以及 planned-subtask identity／position／finite time；任何不一致只抛领域错误，不进入 trapping collection initializer。
- 专项证据：`NoonmarkSnapshotDefinitionTopologyTests`、`NoonmarkSnapshotTrajectoryTopologyTests`、Data Package malformed snapshot 与 `ValidatedSyncSnapshotTests` 已覆盖领域错误边界；最终全模块、完整真实 App E2E 和 DMG 也已通过，不再以专项结果代替进程级门禁。

### UI-035：烛龙授权、应用、sidecar 与 SQLite journal 没有联合时钟

- 状态：已验证。
- 症状：固定 Natural Day、未来 sidecar session 或待恢复 application 存在时，烛龙授权可能使用墙钟，apply 又使用另一时间；Engine、receipt、session event、pending journal 和 SQLite change journal 因此可能倒退或彼此不一致。恢复 `beforeSnapshot` 时还会重新分配 journal 时间，已经是 `afterSnapshot` 时也会重复保存。
- 根因：Store、`ZhulongWorkspaceStore`、Session 和 application journal 各自拥有默认 `Date()`；跨两个存储边界的原子协议没有显式 joint frontier 和 recovery plan。
- 根修：由 NoonmarkZhulong 深模块从 Natural Day reference、Engine frontier、selected session 及 pending application 的 Engine／session／`createdAt` 计算联合 timeline；首次授权与 apply 分配严格递增 instant，apply instant 同时写入 Engine、authorization／receipt／event、pending application 和 SQLite journal。恢复明确区分 before→以原 `pending.createdAt` 保存 after、after→不重复保存、其他→冲突 fail-closed；application journal 使用带代际版本的 exact-date 编码。
- 专项证据：Todo／Daily Review／中断恢复、Session CAS 与三个 commit failure stage 测试通过；`artifacts/e2e-zhulong-recovery/` 和 `artifacts/e2e-zhulong-exact-recovery/` 已取得固定时钟、Engine-after、mutation blocked 与重启证据，并由本轮最终完整 E2E、`make check` 和 DMG 复核。

### UI-036：主题／语言的同步时钟在 SQLite 与 merge 后丢失

- 状态：已验证。
- 症状：主题或语言经同步合并后，SQLite 把 preference `updated_at` 固定写成 epoch，Engine snapshot 又不保留该时钟；重启后较旧远端 preference 可能覆盖较新的本机选择。本机 data mode、备份、poem 或 endpoint 等 local-only 设置还可能误触发 preference 同步。
- 根因：`AppPreferences` 没有拥有 theme／language 的持久 LWW clock；mapper 依赖调用者临时传时间，materializer 借用 journal `changedAt`，merger 在 snapshot 回写时把 clock 丢回 epoch。
- 根修：由 `AppPreferences.themeLanguageUpdatedAt` 与 theme／language 组成一个一致性边界；只有真实 theme／language 变化才严格推进该时钟，本机专属 preference 永不推进。Snapshot、MutationClock、SQLite exact-date schema、Data Package、Sync mapper／materializer／merger 全程搬运并校验同一值；remote apply 只覆盖 theme／language／clock，保留本机专属设置。
- 专项证据：Engine、SQLite、Data Package、Sync mapper／materializer／differ／merge 已覆盖 LWW、exact bit、重启和 local-only no-op；真实 Settings 路径、最终完整 E2E、`make check` 与 DMG 均已通过。

### UI-037：Snapshot undo 抛错时可能留下半恢复 Engine

- 状态：已验证。
- 症状：snapshot undo 依次隐藏 current-only facts、恢复 chain／definition／trace／subtask；若中途遇到 non-finite 或无法前进的 clock，调用方会收到错误，但 receiver 可能已经被前半段修改。
- 根因：`prepareSnapshotUndo` 直接在 live Engine 上执行多步 throwing mutation，没有 strong exception safety 边界。
- 根修：从 receiver snapshot 建立 staging Engine，在 candidate 上完成全部 undo、隐藏取消事实与完整性验证，成功后才一次 adopt 全部 state；任何错误保持原 receiver snapshot 完全不变。
- 专项证据：`SnapshotUndoExceptionSafetyTests` 用非法 clock 触发后段错误，并对账调用前后 snapshot 完全相同；隐藏身份、SQLite 重启和 Sync undo 另有专项覆盖，最终全量门禁已复核通过。

### UI-038：公开 Sync merge 可以从未经验证的 base snapshot 建 index

- 状态：已验证。
- 症状：调用方可以把重复 Day／definition／trace identity 的 raw snapshot 直接交给 merger；在完整性错误成为领域冲突前，`Dictionary(uniqueKeysWithValues:)` 可能先 trap。
- 根因：`SyncRecordMerger` 的公开类型签名没有表达“base snapshot 已通过完整领域校验”，验证只是调用惯例。
- 根修：新增 `ValidatedSyncSnapshot` capability wrapper，公开 merge 只接受该 wrapper；raw overload 降为模块内 throwing seam。Storage 首轮和每次 fixed-point 重试都重新验证 wrapper，再进入 index 与 component merge。
- 专项证据：`ValidatedSyncSnapshotTests` 证明 malformed base 在 index 前抛领域错误、合法 merge 行为保持；NoonmarkSync 全套 257 项与 Storage download coordinator 21 项专项均通过，并由仓库最终 `make check`、真实 App 和 DMG 复核。

### UI-039：相关 current sync records 逐条应用会产生部分提交与输入顺序差异

- 状态：已验证。
- 症状：同一任务链的 definition transition、trace continuation、subtask lineage 或同 ID 多 variant 若逐条应用，合法成组更新可能因中间 snapshot 非法而被错误拒绝；相反，失败 component 也可能留下部分 applied／waiting 状态。
- 根因：旧 merger 把 LWW current record 当成相互独立的行，没有把 parent、successor、continuation、priority、lineage 与 cancellation identity 建模为原子结构组件。
- 根修：same-ID exact evidence 先 canonicalize；相关 current records 通过结构 token 连成 component，在复制的 merge context 中整体 stage、重试 waiting 并做全 snapshot validation。成功才 commit；失败整组 rollback，再按 missing dependency 或 irreparable topology 输出 deterministic waiting／conflict。
- 专项证据：`SyncRecordMergerAtomicityRegressionTests`、`SyncRecordMergerCanonicalizationBoundaryTests` 与 component property／permutation tests 覆盖 valid+invalid same-ID、双 current definition、rollback、等待与输入排列；NoonmarkSync 全套 257 项与最终仓库门禁均已通过。

### UI-040：任务定义与轨迹拓扑在 Core、恢复和 Sync 各自推断

- 状态：已验证。
- 症状：多 current definition、successor cycle、双 active trace、重复 visible priority、复用 continuation source、subtask position／lineage 冲突及 cancellation identity 复用，可能在不同边界得到不同结论。
- 根因：snapshot validation 与 Sync projection 没有共享完整 definition／trajectory topology vocabulary，部分路径只查直接 parent 或单条 record。
- 根修：建立 `TaskDefinitionValidator` 与 `TrajectoryTopologyValidator`；Core snapshot、Engine restore、数据包和 Sync component 共用 self-contained 与 collection topology 规则。只有确实缺少 successor／parent／continuation 的记录可以等待，已经形成 cycle、复用或重复 current 的 component 直接 fail-closed。
- 专项证据：Core definition／trajectory 表驱动测试，Sync `TaskDefinitionTopologySyncTests` 与 `TraceSubtaskTopologySyncTests`，以及 257 项 NoonmarkSync 全套均通过；旧 Core full 日志包含并行改动期间的失败而继续保留为历史，最终结论来自本轮串行全量重跑。

### UI-041：Sync waiting 缺少 exact origin 与并发 CAS，缺 Day 还会被随机补造

- 状态：已验证。
- 症状：只按 record ID 保存或删除 waiting，会让同 ID 的新 exact variant 被旧 merge 结果误删；pending row 删除后以相同内容重建会产生 ABA。缺 Day 的 trace 若即时生成 placeholder，还会让不同设备得到不同 Day identity。
- 根因：waiting 曾被视为瞬时重试列表，没有 durable generation、完整 observed token、exact record／witness 与具体 dependency；缺失领域事实又被错误当成可本地合成的默认值。
- 根修：缺 Day 保存 `.day(LocalDate)` dependency，不生成随机 Day；pending row 完整保存 `generationID`、exact record、reactivation witnesses、dependencies、first／last attempt bits 与 attempt count。snapshot、conflict、terminal、waiting、audit 和 metadata 在一个 SQLite transaction 中提交，更新／保留／终止都对完整 observed token 做 CAS。
- 专项证据：`SQLiteSyncRepositoryTests` 覆盖 full-token CAS、ABA、exact dates／NUL／witness、dependency replacement；`SQLiteSyncDownloadCoordinatorTests` 覆盖 exact-origin audit、retained pending 和 missing Day fixed-point，最终全量门禁也已复核通过。

### UI-042：Immutable sync identity 碰撞会被到达顺序静默决定

- 状态：已验证。
- 症状：相同 immutable record ID 若出现不同 payload／entity evidence，transport、merge 或 SQLite 若以先写／后写决定赢家，会让设备永久分叉；后续下载还可能反复把同一坏记录放回 waiting。
- 根因：immutable identity 的“同 ID 必须 exact 相等”没有贯穿 local folder、CloudKit mirror、merger、terminal ledger 与 Storage transaction。
- 根修：不同 exact evidence 一律产生 canonical terminal collision；既有 terminal identity 成为持久 anchor，同 exact record 可重放幂等，不同 evidence 继续冲突。Storage 同步保存 conflict 与 terminal rejection，不能覆盖文件或任意挑选 winner。
- 专项证据：`ImmutableIdentityCollisionTests`、`SQLiteImmutableIdentityCollisionTests`、LocalFolder 与 CloudKit mirror collision tests 已覆盖双输入顺序、重启与 terminal anchor，最终完整回归已通过。

### UI-043：烛龙跨 Engine／Session 存储提交没有可证明的恢复状态机

- 状态：已验证。
- 症状：Engine 已持久但 Session 保存失败时，旧路径可能显示成功、重复保存或在恢复时覆盖第三版本 Session；journal clear 失败也没有和原始失败分别保留。
- 根因：SQLite Engine、加密 Session 与 pending journal 不共享事务，却只用成功／失败布尔值描述整个应用，没有 durable progress、before／after Session CAS 和全局 pending write gate。
- 根修：按 ADR 0023 保存 v3 before／after Engine 与 Session journal，提交顺序固定为 journal → Engine → Session CAS → clear，并以 `beforeEngine`／`enginePersisted`／`sessionPersisted`／`completed` 返回 typed outcome。恢复只接受 exact before／after，第三状态冲突；Engine durable after 后安装 after 但不显示成功，所有其他写入口保持阻断。
- 专项证据：commit coordinator、mutation timeline、Session repository CAS／lock、recovery identity 测试通过；`artifacts/e2e-zhulong-recovery/` 明确记录 pending 时普通 mutation blocked，exact-after 与 preference-conflict 重启路径也有真实 App 结果；最终完整 E2E、`make check` 和 DMG 已复核通过。

### UI-044：最新视觉审查仍有信息堆叠、行操作失衡与非标准 Mac 菜单

- 状态：已验证。
- 症状：Day 行的完成控件与 accessory 顺序削弱扫读；Calendar 详情重复状态和截断长标题；未来详情重复 summary card；分类 patch 用装饰性边框制造额外视觉单位；Edit／Window 菜单缺少标准 Find、Spelling and Grammar 与 Full Screen responder-chain 语义，English 仍有美式拼写和生硬空状态。
- 根因：局部页面在新增能力时各自叠加 chip、卡片和自定义命令，没有持续回到共享像素 token、低视觉单位原则与 AppKit 标准菜单职责。
- 根修：Day 行先 identity 后 accessory、末端 28pt completion；Calendar 详情收敛为单一 status、两行标题与紧凑 metadata；未来详情删除重复 summary card；分类 patch 使用共享 1px 线与低强度填色。主菜单新增原生 Find／Find Next／Find Previous、Spelling and Grammar 和 `Control-Command-F` Full Screen，全文 Search Noonmark 保留独立 `Shift-Command-F`；English 统一 `Organisation`／`Organise` 与自然空状态文案。
- 当前证据边界：最终独立 Spec review 发现实际 `TaskRow` 仍把 completion 放在 identity 前，与文字契约相反；现已按 identity → accessories → flexible space → 28pt completion 修正，并由 `MacUITaskRowLayout` 的顺序契约与测试固化。menu structure 自动化已编码 responder-chain 规则；最终串行 E2E、截图检查、`make check` 和 DMG 已共同关闭本项。

### UI-045：English 截图只覆盖空库，无法证明商业化 populated 状态

- 状态：已验证。
- 症状：既有 English OCR 截图多数来自空数据库，无法证明长标题、分类、状态、详情层级和各池真实数据同时出现时没有截断、中文泄漏或视觉堆叠。
- 根因：截图流程依赖空库后切换语言，缺少只供 E2E bundle 使用、通过真实领域 mutation 建立的确定性 English fixture，也没有 view-tree／AX 与 SQLite manifest 对账。
- 根修：新增严格限定 `app.noonmark.mac.e2e`、显式 data／result URL、固定 `en_SG` Natural Day 的 `EnglishScreenshotFixtureE2EAutomation`；通过真实 Store mutation 建立 Day、Task Pool、Upcoming、Unfinished、Completed、Calendar、分类／标签与长标题数据。每个 classification commit 各自在合法 Store／SQLite transaction 中持久化，SQLite reload 后才输出 identity／count manifest。截图 verifier 选择真实首项，对账 detail rail、classification view-tree、长标题完整 AX value、两行布局与 OCR 语言。Day detail 的 remove-tag 控件另外由既有稳定签名 DMG helper 以只读 `e2e-inspect` 模式验证；helper 用公开 CGWindow API 锁定 PID／CGWindowID／frame，再要求唯一 AXWindow 的 title／frame 对应，不新增第三项 TCC 授权。
- 调试记录：程序内 AX 查询在真实 App 运行时得到 `AXIsProcessTrusted=false`，且 SwiftUI hosting view 的程序内 accessibility children 为空，不能作为跨进程辅助功能 oracle。外部 helper 首次读取到的真实 identifier 为 `classification.editor.remove-label.<chain>.existing:<label>`，证明 `EditorLabel.id` 的 SwiftUI diff identity 泄漏到 production AX identifier；现已把 ForEach identity 与 canonical UUID AX component 分离，existing／new 都不再发布 presentation prefix。格式合法但不存在的 UUID 在 `/tmp/noonmark-e2e-ax-green-final/red-evidence/ledger.tsv` 精确 RED 为 `matched 0 controls`，App 自己输出的两个 UUID 则在同一 PID／CGWindowNumber 上 GREEN，见同目录 `green-evidence/ledger.tsv`。另一次 8 场景运行暴露 shell 把 `280pt` target 写成 exact string，而 App 契约是 target ±2；shell 现改为唯一有限十进制记录及 `abs(actual-target) <= 2`，缺失、重复、非数值或超界继续 fail-closed。
- 当前证据边界：源码现有 10 个 populated English 场景；Day 的 960×720 专项曾取得 App window、English OCR、长标题、分类、详情 AXButton 与 exact CG／AX window correlation 证据。旧的跨轮 PNG 已由 fresh-run seam 清除；最终 full-suite manifest 把 10 个场景绑定到同一 source tree、binary SHA 与 exact scenario set 后关闭本项。

### UI-046：同一 data root 可被两个 App 进程并发写入

- 状态：已验证。
- 症状：开发 App、E2E App 或安装副本若同时打开同一 SQLite／sidecar root，SQLite、同步仓库与烛龙 journal 可以分别取得局部锁，却没有覆盖整个数据根的单一 writer 身份。
- 根因：进程级排他只存在于个别存储操作，没有在 App 启动到退出的生命周期建立 data-root lease。
- 根修：新增 owner-only regular lock file 与 advisory process lease；symlink、非 regular、group／world writable root 和底层 POSIX 错误全部 fail-closed。同 root 第二进程以专用 exit 75 拒绝，不同 root 可并行；正常退出、`SIGKILL` 与 `_exit` 后均可重新取得。
- 专项证据：Storage lease 8 项测试与 `scripts/test-data-root-process-lease-e2e` 已覆盖同 root、不同 root、数据不变、正常退出、`SIGKILL`、`_exit` 和不安全目录；最终运行已由 UI-049 的 manifest、签名 binary、unified log 与 DiagnosticReports 绑定。

### UI-047：烛龙 journal 的不确定 durability 与 orphan sweep 证据不足

- 状态：已验证。
- 症状：rename／unlink 报错后仅观察 destination exact／absent 会把 namespace 状态误当作耐久提交；进程内 alias 还可能绕过 unresolved fence；批量 orphan sweep 若前一删除成功、后一删除失败，会在同步 parent directory 前传播错误。
- 根因：文件提交、目录同步、final observation、recovery fence 与 orphan retention 原先分散在异常分支，没有形成 typed protocol。
- 根修：按 ADR-0023 建立 committed／recovered committed／not committed／unresolved 判定、fresh directory sync、path+inode fence identity、精确 UUID orphan guard；批量 sweep 先同步已完成的删除，再传播后续 removal，并保留 primary／durability／retry 三层错误。
- 专项证据：`NoonmarkZhulongTests` 213／213 与真实 App 烛龙恢复专项通过；Journal 新增两个回归先稳定 RED，再于同一公共 `load()` seam GREEN，最终 `make check`、full E2E 与 DMG 安装也已复核通过。

### UI-048：Sync／SQLite hostile evidence 可触发 trap 或部分提交

- 状态：已验证。
- 症状：重复 identity、空 ID／device／key／action、伪造 immutable clock、同 ID valid+malformed sibling、缺 Day structural component、pending ABA 和 CloudKit mirror 失败可能触发 Swift precondition、错误归因、部分 mutation 或丢失 waiting。
- 根因：wire decoding、in-memory transport、mirror、current provenance reduction、component retry、SQLite reader 与 full observed-token CAS 没有共享 fail-closed 不变量。
- 根修：自定义 validated Codable、throwing seeded transport、staged mirror、exact immutable clock、same-ID sibling 原子冲突、structural component 整组重试、generic live-provenance reduction，以及 generation／firstSeen 保持的完整 pending CAS。
- 专项证据：最新 stdout 证据为 `NoonmarkSyncTests` 272／272、`NoonmarkStorageTests` 145／145；Storage 另有 1 项明确 opt-in 的 live iCloud 外部能力 skip。最终仓库门禁和真实 App 路径已完成闭环。

### UI-049：旧 artifacts 与无来源 manifest 可制造错误最终绿灯

- 状态：已验证。
- 症状：targeted E2E 成功会保留旧截图并写 status 0；现有 manifest 不记录 source tree、configuration、scenario filter、binary SHA、签名 identity／Team 或 fresh artifact inventory。writer lease、package 与 DMG install 也无法证明取证来自同一源码和签名产物。
- 根因：每个脚本自行写少量日志，缺少共享的 validation evidence seam；DiagnosticReports 在 clean 时还会删除 final／diff，无法复核零新增。
- 根修：新增 `scripts/evidence-common` 深模块，原子绑定 run ID、HEAD／worktree tree、配置、稳定签名 bundle、binary SHA、scenario set、diagnostic baseline／final／diff 与 fresh inventory；E2E、lease、package、verify 和 install 只消费该 interface，cross-manifest validator 对账同一运行链。
- 验证证据：纯 shell fixture 已覆盖 dirty／untracked tree、真实 index 不变、binary 中途替换、ad-hoc 拒绝、stale artifact 排除、exact SIGKILL allowlist 和 manifest 缺字段；最终以同一 run ID 依次运行带 source manifest 的 `make check`、writer lease、full E2E、稳定签名 package／verify／install，10 个 English ledger 只包含一个 binary SHA。

### UI-050：同一进程连续验证 Help 快捷键与菜单会留下 AppKit tracking 竞态

- 状态：已验证。
- 症状：自动化先以物理 `Shift-Command-/` 打开 Help menu，再立即点击菜单栏 Help 时，前一次 AppKit menu tracking 偶尔尚未完全退出；原专项连续五轮只通过两轮。
- 根因：两条各自合法的原生用户路径被压进同一 AppKit tracking session 生命周期，测试把“窗口已关闭”误当成“系统菜单 tracking 已完全退场”。
- 根修：把 Help 快捷键交给独立、干净的 App 进程验证；主 native-command 进程只通过真实菜单栏点击打开自定义 Help item。两条路径仍然使用 WindowServer 物理输入、menu tracking、Help window、最小尺寸与关闭断言，不用延时吸收竞态。
- 专项证据：`NOONMARK_E2E_NATIVE_COMMANDS_ONLY=1 scripts/test-e2e debug` 连续五轮全部通过；`scripts/test-e2e-evidence-contract` 固化 Help shortcut probe 必须先于 native command surface，最终同源完整 E2E 与 DMG 安装已复核通过。

### UI-051：Snapshot undo 在 SQLite 中转移 pending trace 时触发瞬时唯一约束

- 状态：已验证。
- 症状：撤销 continuation 后，内存中合法的 source pending 与隐藏 target cancelled draft 在保存时触发 `UNIQUE constraint failed: day_traces.chain_id`。
- 根因：数据库已有 source continued 与 target pending；旧 upsert 按 snapshot 顺序先把 source 改成 pending，再把 target 降为 cancelled draft，违反只允许一条 pending trace 的 partial unique index。最终状态合法，但中间写入顺序非法。
- 根修：在同一事务内先查询既有 pending trace，并优先持久化所有离开 pending 的记录，再按原 snapshot 顺序写入其余记录；保留首次保存所需的父子引用顺序，不放宽 schema 约束。
- 回归证据：`SnapshotUndoPersistenceTests.testContinuationUndoAtomicallyTransfersPendingTraceAcrossSQLiteRestart` 先稳定 RED、根修后 GREEN；Core snapshot undo 时钟矩阵与真实 `.app` copy／undo／redo／journal／SQLite 重启探针同时覆盖最终身份、状态和 exact clock，最终全量门禁已复核通过。

### UI-052：Journal 以毫秒文字投影排序会颠倒同毫秒 exact mutation

- 状态：已验证。
- 症状：多个 `Date.nextUp` mutation 落在同一毫秒时，事实表保留了全部 exact bits，但 `journalEntries(limit:)` 会按随机 UUID 次序返回，甚至把错误事件选为最早的 limit 结果。
- 根因：查询使用毫秒精度的 `changed_at` 文本排序；该列只是可读投影，却被误当成 canonical 时间。并列后 SQLite 退回 entity／journal ID，破坏真实 mutation 顺序。
- 根修：SQLite 只负责筛选 state；repository 解码并校验 exact date 后，按完整 `Date`、依赖顺序、entity ID 与 journal ID 确定性排序，最后才应用 `limit`。
- 回归证据：`SQLiteSyncRepositoryTests.testJournalEntriesUseExactClockOrderBeforeApplyingLimit` 以 UUID 顺序故意对抗时钟顺序，先稳定 RED、根修后 GREEN；真实 `.app` subtask mutation 专项覆盖五次 Store mutation、undo／redo、六条 exact journal、mapper 与重启，最终全量门禁已复核通过。

### UI-053：辅助窗口会把 Edit 命令错误路由到后台主窗口编辑器

- 状态：已验证。
- 症状：Settings、Search 或 Help 成为 key window 时，若主窗口仍保留 `NSTextView` first responder，Undo／Redo／Select All 仍会启用，并可能修改用户看不见的后台输入。
- 根因：App command validation 在当前 key window 没有文本 responder 时，会回退到主窗口的 first responder；领域 undo／redo 也没有要求主窗口必须为 key window。
- 根修：文本命令只读取 `NSApp.keyWindow?.firstResponder`；领域 undo／redo 的 validation 与 action 同时要求主窗口为 key window。真实原生命令 E2E 聚焦 Quick Add 编辑器、建立领域 undo history、以物理 `Command-,` 打开 Settings，再验证三个 Edit 命令禁用，物理 `Command-A`／`Command-Z` 不改变后台文字、selection 或领域 history。
- 回归证据：新增路径先稳定 RED 为 `Edit commands remained enabled through a background main-window text responder`，根修后 `NOONMARK_E2E_NATIVE_COMMANDS_ONLY=1 scripts/test-e2e debug` 通过；最终同源 full E2E 与 DMG 已复核通过。

### UI-054：Toast rise transition 没有 animation transaction

- 状态：已验证。
- 症状：Toast 声明了 move／opacity transition，但状态变化没有进入 animation transaction，正常 motion 设置下仍会瞬间出现或消失。
- 根因：视图只定义 transition，没有把 `store.toast` value 与具体 animation 绑定；日期 strip 的 spring 参数也散落在页面内，设计契约无法审计。
- 根修：新增共享 `MacUIAnimationMetrics`，Root View 以 Toast value 驱动 0.20 秒 ease-out；日期选择使用共享 spring response／damping。Reduce Motion 为真时两者均关闭动画，不以延长时间掩盖。
- 回归证据：`MacUIDesignContractTests.testGlobalMotionContractIncludesToastRiseAndDateStripSelection` 固化 Toast、日期与 Reduce Motion 契约，专项、SwiftFormat lint 与最终真实 App 全量回归均通过。

### UI-055：安装与跨 workflow 证据校验信任自报布尔值并重复实现

- 状态：已验证。
- 症状：DMG install manifest 即使缺少 source／installed App／helper 的结束态或把稳定性字段删除，旧 cross-validator 仍可能返回成功；English ledger 可以写入任意合法格式的截图 SHA 与 oracle，安装截图、阶段 ledger 和重启前后任务快照也只要存在便可通过；源码在取证后变化时，旧证据仍可能被当成当前结果。CI 与 release 又各自复制一段较弱的 manifest 解析，字段演进时会漂移。
- 根因：总校验器只对账安装起态和 package digest，未独立比较 run 内结束态、exact SIGKILL allowlist、诊断结果与 fresh artifact inventory，也没有在验证当下重算 Git worktree、解码 PNG、重算逐图 digest 或检查阶段证据语义；workflow 没有可选的 runtime／full scope，只能复制内部逻辑。
- 根修：共享校验器提供显式 `--scope runtime|full` 且不得按文件存在自动降级；逐项对账 source、bundle 八项签名／binary evidence、E2E before／after digest、package／mounted／installed App、SIGKILL report／ledger、DiagnosticReports、DMG／checksum 与 artifact inventory。验证时重新捕获 HEAD／tree／dirty worktree 并与 E2E source 精确对账；十个 English 场景逐一验证固定 oracle、PNG magic／解码／exact pixel dimensions 和真实文件 SHA，再由独立 Vision 进程重跑场景唯一内容 marker、无 Han 与 Settings 完整标题，不信任 ledger 自报。安装证据验证三张 PNG、preflight／exercise／restart 的完整有序 PASS 阶段，并逐项对账 helper identity、exit observer、真实 App target、窗口、菜单、WindowServer input、可见标题和原生退出 detail；ledger 的 PID／App 路径必须与 producer 在 helper 运行前归档的窗口 metadata 及固定安装路径一致，再与 macOS unified log 中 LaunchServices 记录的唯一一条 App identity 对账 PID、bundle ID、bundle path 与 executable path。identity 中的 64 位十六进制 `LSAuditToken` 必须按 Darwin audit token 的 little-endian PID 字段反解并等于可见 PID，避免整组文本 PID 自洽伪造；同 PID 的全部 App process 行必须只有同一个 natural day。capture、首条 App process 与安装 manifest 的开始／结束时间形成有序且不超过 120 秒的时间窗。metadata 的 natural day、标题、截图路径和像素尺寸必须互相吻合；Settings window／sidebar／content 必须是有效数值矩形、位于窗口内且互不重叠。重启前后完整 SQLite joined-row 除逐字节相等外，还要解析 JSON，并与独立 `task-identity.tsv`、两次窗口 natural day、严格 uppercase UUID schema、状态／sequence／title 交叉对账。`evidence-common` 新增后验 inventory verifier；E2E helper 复制进本轮自有 immutable evidence root。CI／release runtime 阶段只调用共享 runtime scope，发行安装后调用 full scope。
- 回归证据：纯 shell fixture 先证明旧 validator 接受缺失 install 结束态、缺失 E2E helper digest、错误 SIGKILL phase、篡改 inventory、package source end、陈旧 worktree、任意 English screenshot digest／oracle、文本伪 PNG、同尺寸错场景 PNG、字段齐全但伪造的安装 target、内部自洽伪造的 PID／App 路径、可见 PID 与 kernel audit token 不一致、同 PID 矛盾 identity、同 PID 跨自然日、capture 超出安装窗口、整组系统日期自洽伪造、空 Settings 几何、缺失安装阶段、内部矛盾的 joined-row、内部自洽伪造的非 UUID identity／自然日及重启后任务行变化；根修后全部反例 fail-closed，`scripts/test-evidence-common`、`scripts/test-dmg-evidence-contract` 与 `scripts/test-e2e-evidence-contract` 通过。上一轮真实 DMG 产物的 exercise／restart ledger、窗口 metadata、唯一 LaunchServices identity、`LSAuditToken` PID、unified log 日期、独立 task identity 与两份 SQLite snapshot 也通过新 parser，证明 fixture 与 producer schema 一致；该旧 run 因源码后来变化，不冒充最终证据。lease 与 E2E 各自独立重签，跨 suite 不比较包含 CMS 签署时间的整个 executable SHA，只要求各 suite 内 digest 稳定、source tree／证书／Team／authority 一致；最终同一 run ID 的真实 lease／full E2E／package／install 链已通过总校验器。

### UI-056：相同 executable 被重新签名与前置失败会保留错误成功证据

- 状态：已验证。
- 症状：独立 Standards review 发现 suite 结束只比较 executable SHA；若运行中对同一 bytes 重新签名，证书、Team 或 designated requirement 已变化仍可写成功 manifest。E2E 的工具／锁屏／参数门禁及 DMG install 的工具／旧 package 门禁又发生在 evidence root 清理前，前置失败会留下上一轮 status 0 manifest。
- 根因：bundle 八项证据比较在 package、E2E 和 install 各自实现，公共 `evidence_finish_manifest` 只认识 binary digest；fresh-run ownership 又晚于部分 fail-closed preflight。
- 根修：`evidence-common` 新增唯一 `evidence_require_bundle_snapshots_equal`，原子比较 binary、bundle identifier、签名类别、leaf SHA-1／SHA-256、Team、authority 与 designated requirement；manifest finish 自动对账 App、installed App 与 helper 的 start／end snapshot，package／E2E／install 复用同一 seam。E2E runtime 与 DMG install evidence root 在工具、锁屏、参数和旧 manifest 检查前先清空。
- 回归证据：`scripts/test-evidence-common` 先稳定 RED 为 `manifest accepted a signature replacement with an unchanged binary`，根修后 GREEN；`scripts/test-e2e-evidence-contract` 固化清理必须早于前置门禁，DMG evidence contract 与 ShellCheck 通过，最终同源真实运行链也已复核通过。

### UI-057：菜单栏物理点击进入 NSMenu 模态 tracking 后异步驱动停止推进

- 状态：已验证。
- 症状：最终完整 E2E 在 English native command 场景失败为 `physical Help menu-bar click did not open the menu`；独立 fresh database／fresh App 进程复现中，第 1 轮通过而第 2 轮稳定失败，证明不是旧数据库、同进程 Help shortcut tracking 或锁屏造成。后续运行又分别捕获 `opens=2,closes=2` 的递归 AX 读副作用、真实 `opens=1,closes=1` 但 destination closure 只在菜单关闭后恢复，以及后台 worker 因同进程 AX 必须等待 App 主线程而挂起并被监督器终止的现场。
- 根因：最初“固定 10ms release 太早”只解释表象。真正边界是 WindowServer `mouseDown` 一旦由 App 主线程处理，`NSMenu` 立即接管模态 tracking；原 async continuation 在 tracking 结束前不会恢复，实测连注册为 `.eventTracking` 的主运行循环 Timer 也没有执行。把 AX 与输入移到后台同样不可行，因为读取本进程菜单 AX 必须由已被 `NSMenu` 占用的 App 主线程应答。另一方面，旧 `uniqueMenuBarItem` 从 App root 递归进入 submenu，单纯读取 geometry 也会短暂打开／关闭菜单并命中 cached `NSPopupMenuWindow`，使 tracking oracle 失真。
- 根修：顶层菜单栏 AX geometry 只从 `kAXMenuBarAttribute` 的 direct children 读取并做两次稳定校验，不再递归 submenu。`WindowServerInputDriver.postMenuBarKeyboardSelection` 在 pointer 已稳定、App active、button up 且源 geometry 未移动后，先构造完整 mouse-down／mouse-up／Down Arrow／Return 事件，再于同一个 MainActor turn 内按序全部投递到 WindowServer，之后才让出执行权；因此 `NSMenu` 自己的模态 loop 能消费已经排队的完整原生用户序列，不依赖 tracking 期间的 continuation、Timer、AX callback 或私有 API。调用方先证明 exact Help action 是菜单首个 keyboard-selectable item，再以 `menuWillOpen/menuDidClose`、独立 Help window、尺寸／关闭和最终 button-up 验证结果。另设仅限稳定签名 E2E App 的 input cleanup automation，用于外部监督器强制终止手势后恢复全局 button；它不参与正常成功路径。
- 回归证据：保留 fresh process 重复 RED 与逐层反证记录；恢复稳定签名辅助功能授权后，首轮专项以及随后 5 个 fresh process／fresh database 轮次连续通过 `NOONMARK_E2E_NATIVE_COMMANDS_ONLY=1 scripts/test-e2e debug`，每轮均覆盖 Help shortcut、物理菜单栏序列、exact Help command、独立 Help window、Settings、Quick Entry、Search、Undo／Redo restart、关闭最后窗口／Dock 重开与 SQLite `1 1 1` 对账，且无遗留 left-button down；最新源码冻结后的完整 E2E、`make check` 与同一 run ID 最终证据链亦已通过。

### UI-058：Calendar English 分析标签被中文固定宽度逐字折行

- 状态：已验证。
- 症状：最终 English 截图人工复核发现 Calendar 右侧栏的 `Continuations` 与 `Changes` 被压进极窄列并逐字折行；既有 OCR 只证明文字存在，没有证明其商业化可读布局。
- 根因：`CalendarInsightRow` 把标签列固定为 `28pt`；该宽度只适合中文“延续／变更／风险”，没有把本地化后的 intrinsic content size 作为布局事实。
- 根修：三行改用共享 intrinsic-width `Grid`；最宽的本地化标签决定共同标签列，标签固定单行，说明列消费剩余宽度并正常多行。真实截图 verifier 读取三个被动 view-tree anchor，以 AppKit 字体测量逐项证明 label frame 足以容纳完整文字且高度不超过单行，不再信任 OCR 自报。
- 回归证据：旧实现先稳定 RED 为 `continuation frame=(..., 28.0, 39.0) requiredWidth=73.1769...`；根修后 `NOONMARK_E2E_SCREENSHOTS_ONLY=1 NOONMARK_E2E_SCENARIOS=english-calendar scripts/test-e2e debug` 通过，manifest 记录 `continuation=74x13,change=46x13,risk=23x13`，最新真实截图人工复核无逐字折行；最终 full E2E、`make check` 与同源 DMG 安装亦已复核通过。

### UI-059：E2E 外部监督器未调用已实现的 WindowServer 输入清理

- 状态：已验证。
- 症状：最终 Standards review 发现稳定签名 App 已有 left-button cleanup automation，但 `scripts/test-e2e` 的 EXIT trap 只终止被测 App；若 supervisor 恰在 mouse-down 后强制结束进程，全局左键状态可能继续污染桌面与后续场景。
- 根因：应用内 gesture 异常释放与 shell supervisor 生命周期分属两个边界；清理 automation 被注册为普通 Store launch action，却没有任何脚本调用，也错误依赖 SQLite data root、schema 和 fixture seed 才能启动。
- 根修：cleanup 改为 Store 构造前的专用稳定签名 App 启动路径，不接触用户／fixture 数据；E2E EXIT trap 在结束被测进程后必定运行该路径，精确读取 `ok` 结果、进程退出和残留进程。结果、日志与 SHA 进入 manifest／fresh inventory，清理不可用或失败会把原本成功的 suite 改为失败，原始失败也不会被覆盖。
- 回归证据：静态合约先稳定 RED 为 `E2E supervisor never invokes signed-App WindowServer cleanup` 与 `scripts/test-e2e is missing evidence contract: run_windowserver_input_cleanup`，根修后 `scripts/test-e2e-evidence-contract` 通过；先前真实 stuck-left-button 现场由稳定签名 App 恢复并写出 `/tmp/noonmark-input-cleanup/result.txt=ok`，最终 full E2E 每轮退出还会生成受总校验器验证的 `windowserver-input-cleanup-result.txt=ok`。

### UI-060：直接从 shell 启动签名 App 会让输入清理权限归因给 Terminal

- 状态：已验证。
- 症状：41 个 full E2E 功能场景全部完成后，最终清理仍写出 `failed: WindowServer event-posting access is unavailable`，suite 因而正确失败；同一稳定签名 App 在早前真实手动清理中却可以返回 `ok`。
- 根因：监督器直接执行 `.app/Contents/MacOS/NoonmarkMacAppE2E`。macOS TCC 运行日志把该进程的 responsible subject 记为 `com.apple.Terminal`，并对 `kTCCServiceListenEvent`／`kTCCServicePostEvent` 返回 `authValue=0, authReason=4`；因此 App 自身的稳定 designated requirement 与辅助功能授权没有成为这次请求的责任主体。
- 根修：监督器改用 `/usr/bin/open -W -n` 经 LaunchServices 启动同一 bundle，并由 `open` 的等待进程继续承担有界终止、exact result、无残留进程和 fail-closed 检查。不得退回直接 binary launch，也不授予 Terminal 额外辅助功能权限。
- 回归证据：新增证据契约先稳定 RED 为 `WindowServer cleanup does not launch through LaunchServices`，根修后 GREEN，并明确拒绝 cleanup function 再出现 `"$app_executable_path"`；真实稳定签名探针随后取得 `launcher_status=0`、`result=ok` 且无 `NoonmarkMacAppE2E` 残留。最终 full E2E manifest 还必须记录并由总校验器复算同一 `windowserver-input-cleanup-result.txt=ok`。

### UI-061：复用 CGEventSource 的 flags 与逆序时间戳会破坏 Help 菜单选择

- 状态：已验证。
- 症状：41 个 full E2E 截图、独立 `Shift-Command-/` Help shortcut 与最终 WindowServer 清理均通过，但后续 native command 综合进程打开并关闭 Help popup 后没有 Help window。首轮 fresh App／fresh database 直接 exercise 连续三轮均为 `opens=1,closes=1,highlightRequests=1,highlights=0,confirmations=0`；清除继承 modifier 后专项曾连续通过，但 full English 路径仍偶发 `trackingBegins=1,sentActions=0`。同一 English fixture 的八个 fresh process 在第八轮复现，证明尚有独立的事件时间线边界。
- 根因：综合进程先以同一个 `CGEventSource` 发送 `Command-,` 打开 Settings；随后预构造的 Down Arrow／Return 没有移除 event source 继承的 device-independent modifiers，现场 raw flags 分别为 `0x20b00000`／`0x20100000`，实际输入成了 Command-Down／Command-Return。modifier 根修后，键盘事件仍先于异步指针定位创建，鼠标事件稍后创建，却按 mouse-down／mouse-up／Down／Return 投递；CGEvent 自带时间戳因此与投递顺序相反，负载下 modal menu tracking 可在没有消费选择键时结束。诊断期间另证明 `NSMenu.didBeginTrackingNotification` 属于顶层 `NSApp.mainMenu` 且先于 Help submenu 的 `menuWillOpen`；AppKit 在快速选择路径也不保证调用 `willHighlight`，旧 probe 错把可选 delegate callback 当成 action 前提。
- 根修：`prepareMenuKeyboardSelection()` 只剥离继承的 Command／Shift／Control／Option，保留 CoreGraphics 为 Arrow 建立的原生 navigation flags；`postMenuBarKeyboardSelection` 在让出 MainActor 前组装 mouse-down／mouse-up／Down／Return 的完整序列，并在实际投递前按该顺序重标同一单调时间线。调用方以 Help menu 唯一可选 action、顶层 tracking begin、`didSendAction`、menu close、独立 Help window、最小尺寸、`Command-W` 关闭和最终 button-up 联合证明结果，不使用 polling、Timer、重试或固定延时。
- 回归证据：`scripts/test-e2e-evidence-contract` 先后因缺少继承 modifier 清理、完整队列协议与单调投递时间线稳定 RED，根修后 GREEN；真实 `NOONMARK_E2E_NATIVE_COMMANDS_ONLY=1 scripts/test-e2e debug` 覆盖 shortcut、Settings 后 Help、Quick Entry、Search、Undo／Redo restart、SQLite `1 1 1`、关闭最后窗口／Dock 重开并以 exit 0 通过。逆序时间戳 binary 在相同 English fixture 的八个 fresh process 中第八轮复现 `sentActions=0`；仅加入投递时单调时间戳后，同一序列十六个 fresh process 全部取得 `ok`，无 DEBUG instrumentation 或同步 release polling 残留。

### UI-062：附言 E2E 把系统文字输入辅助窗口误判为产品浮窗

- 状态：已验证。
- 症状：full E2E 在附言真实删除后等待“附言行消失”或 English `Note deleted` toast 超时。SQLite 已保存墓碑，失败 view-tree 也只剩未删除附言，却同时记录主窗口的 `children=[TUINSWindow]`；英文 toast 在等待期间正常到期，因此最终 dump 看不到 toast。
- 根因：附言 driver 以 `hasNoAttachedPresentationWindows()` 要求主窗口完全没有 child window，错误地把 macOS 的 `TUINSWindow`／`NSRemoteView` 文字输入辅助窗口当成尚未关闭的 Noonmark popover。该 oracle 同时混合了产品浮窗生命周期与无关系统窗口，不能证明本次操作打开的精确 presentation 是否已关闭。
- 根修：打开附言操作 popover 时读取其可见菜单项所属、已映射到 WindowServer 的 `PresentationWindowIdentity`；编辑或删除后只验证该精确 window number 不再可见／映射，同时继续验证编辑器、删除后的行、toast 与 SQLite。系统辅助 child window 不再影响产品 popover 的关闭结论。
- 回归证据：旧实现以 fresh App 稳定 RED 为 `等待真实 UI 超时：删除后的附言行消失`，dump 与 SQLite 同时证明删除已成功；根修后 `NOONMARK_E2E_TASK_NOTE_ONLY=1 scripts/test-e2e debug` 通过真实编辑／删除、重启截图、English copy 与 SQLite `2 2 1 1 0 2 1 1` 对账。

### UI-063：真实点击叠加系统 focus effect，使任务行选中框比截图 E2E 粗重

- 状态：已验证。
- 症状：用户在 release App 中真实点击 Day 任务行后，浅蓝选中面外出现高饱和粗蓝框；同尺寸 `artifacts/e2e/day-detail.png` 只有克制的浅蓝底与细边界。像素反馈环测得用户截图与新增真实点击场景均为上下各连续 7 px 高饱和全宽蓝线，旧截图场景为 0 px。
- 根因：共享 `WorkspaceSelectableRow` 以 `.focusable(true)` 提供键盘事件，却没有关闭 SwiftUI／AppKit 默认 focus effect；真实点击把行设为 focus target 后，系统粗 focus ring 与 `listRowSurface` 已有的 accent-soft 底色和 1 px 边界叠加。原 `day-detail` 截图通过 `--select first` 直接修改 Store selection，没有真实点击；既有 workspace productivity 虽使用 WindowServer 点击，却只断言选择与键盘行为，没有截图像素 oracle。
- 根修：保留 `.focusable(true)`、Return／Space、方向键、多选和 selected accessibility trait，在同一共享 modifier 上关闭系统默认 focus effect，让既有 `listRowSurface` 成为唯一选中视觉。新增 `day-pointer-selection` 场景，由稳定签名 E2E App 通过 `WindowServerInputDriver` 真点击第一条 Day 任务，外部截取真实窗口，并拒绝连续 2 px 以上的高饱和全宽蓝框；不建立未经确认的整图 reference。
- 回归证据：测试先在未修改生产样式时稳定 RED 为 `selection focus visual is too heavy: found 7 consecutive saturated-blue rows`；根修后同一命令 `NOONMARK_E2E_SCREENSHOTS_ONLY=1 NOONMARK_E2E_SCENARIOS=day-pointer-selection scripts/test-e2e debug` 转为 `selection_focus_max_consecutive_blue_rows=0`。随后 `NOONMARK_E2E_WORKSPACE_PRODUCTIVITY_ONLY=1 scripts/test-e2e debug` 通过真实鼠标单选、Command／Shift 多选、上下键、拖放、批量动作、保存失败原子性与重启 SQLite 对账。未过滤 `scripts/test-e2e debug` 进一步以 42／42 截图、10／10 English 场景、Help／附言／WindowServer 综合交互、`windowserver_input_cleanup_result=ok` 和 exit 0 通过；最终 `make check` 亦已复核通过。

### UI-064：复盘首行被内部 viewport 居中推低，详情栏重复标题阻碍直接编辑

- 状态：已验证。
- 症状：用户在 release App 的每日复盘输入“大发大”后，placeholder 所在首行变空，正文落到下一行；SQLite 取证确认 `review_summary='大发大'`、首字节即“大”，没有前导换行。与此同时，可编辑附言只能经三点菜单进入编辑，详情栏又以“完成进度／分组与标签／子任务／附言”重复解释已经自说明的控件。
- 根因：`ReviewEditor` 的可见 surface 被外层扩到 `92pt`，但 `MarkdownTextViewRepresentable.sizeThatFits` 忽略父级明确的高度 proposal，仍以 `.body` 内容高度返回 `54pt`，SwiftUI 因而把实际可点击／输入 viewport 垂直居中；placeholder 与可见 surface 顶部对齐，真实文字却以内部 viewport 顶部为原点。附言条目只有 overflow menu 连接现有 `onStartEditing`，正文没有双击入口；共享详情 section 默认无条件渲染标题。
- 根修：共享 Markdown editor 只让显式固定高度实例按 style 上下限采用该高度，三项复盘编辑器把原生 viewport 明确设为 `92pt`，placeholder 继续作为不参与布局的 overlay；其他自适应 editor 的尺寸语义不变。附言正文双击复用既有原位编辑 session 与权限判断，编辑器出现即取得输入焦点，历史／已完成只读边界不变。共享 `DetailSection` 新增隐藏可见标题但保留 accessibility label 的语义模式，进度、分类、子任务与附言在所有通用任务详情中使用该模式。
- 回归证据：复盘真实指针首行 probe 在旧实现稳定 RED 为 `surface=92pt, scroll=54pt, topGap=25pt, allowed=14pt`，根修后同一 `NOONMARK_E2E_REVIEW_DETAIL_UX_ONLY=1 scripts/test-e2e debug` 以 WindowServer 点击／键入逐一覆盖三个字段，并断言输入后 placeholder 消失、清空后恢复；同一物理双击还证明已完成附言不出现编辑器。附言专项旧实现稳定 RED 为 `等待真实 UI 超时：附言编辑器`，根修后 WindowServer 双击／输入、编辑、保存、删除、重启截图、English copy 与 SQLite `2 2 1 1 0 2 1 1` 对账通过。Day／任务池／未来／未完成／已完成五张真实详情截图人工复核通过，OCR 右栏 fail-closed 约束同时拒绝四个冗余标题并要求对应功能事实仍可见。未过滤 `scripts/test-e2e debug` 最终以 42／42 截图、10／10 English 场景、Help／附言／复盘／WindowServer 综合交互、`windowserver_input_cleanup_result=ok` 和 exit 0 通过；`make check` 以 896 项测试、1 项显式 live iCloud skip、0 failures 及全部 lint／evidence contract 通过。

## 本轮新增 P 级收口策略

- 风险：mutation clock、sync topology／waiting 和烛龙跨存储恢复均可能造成持久数据分叉或不可恢复覆盖，必须以 P 级处理；视觉与菜单改动虽然可回退，也不能以静态代码代替真实 App 用户路径。
- 灰度：专用分支只接受专项测试 → 串行全模块 → 最新完整真实 App E2E／截图／SQLite／console → `make check` → release DMG 安装的顺序。没有用户确认的真实截图不得建立视觉 regression baseline；CloudKit、辅助功能和公开发行继续保留各自人工／外部门禁。
- 监控：最终证据必须同时关注 snapshot identity、exact clock、journal、waiting／terminal 数量、pending Zhulong application、WindowServer button state、AX／view-tree、OCR、unified log、Diagnostic Reports 与安装后 SQLite；单一 build 绿灯不能替代症状级验证。
- 回滚：数据协议改动只能按 ADR 0022－0024 的完整边界整体 revert，并按 clean cut 重建开发数据；UI 可用普通 `git revert` 回退对应组件和契约，但不得留下测试接受旧行为或把失败路径改成 skip／timeout。生产尚未发布，不设计旧 schema 兼容或数据迁移分支。

## 最终同源验证

- Evidence run ID：`85EB07A9-C3B1-4511-88E6-C718EB00F793`。
- 源码门禁：`make check` 已在最终 worktree tree 上完整通过，覆盖 build、UT、IT、ST、确定性仿真、证据契约、SwiftLint 与 SwiftFormat；`artifacts/audit-final/make-check/manifest.txt` 绑定同一 run ID、source start／end tree、完整日志 SHA、fresh inventory 与 exit 0。
- 真实运行链：同一 run ID 依次执行 data-root process lease、未过滤 full E2E、release DMG package／verify 与真实安装／重启；四份 manifest 必须由 `scripts/verify-development-validation-evidence --scope full` 对账 source tree、稳定签名、binary、artifact inventory、Diagnostic Reports 与安装后 SQLite。
- 视觉证据：full E2E 必须重新生成 10 个 English populated 场景，由截图 OCR／Vision、view-tree／AX、响应式契约和人工逐图复核共同验收；其中 Calendar insight label 的单行 geometry 是强制 oracle。
- 真实边界：UI-018 的人工辅助功能组合与 UI-019 的 Developer ID／notarization 仍分别保持人工门禁和外部阻断，不因开发签名自动化绿灯而被篡改为已完成。

## 最终闭环规则

完成本轮前必须：

1. 把所有 `处理中` 条目根修并验证；
2. 把所有 `待全量回归` 条目经完整真实 App E2E、`make check` 和最新 DMG 安装验收提升为 `已验证`；
3. 保留 `人工门禁` 和 `外部阻断` 的真实边界，不以自动化或开发签名伪造完成；
4. 最终提交前确认源码和脚本没有临时 DEBUG 前缀输出，并让本台账与最终运行产物一致。

# FAIL-2026-08-03-01：想法卡片置顶后溢出菜单项陈旧无法取消置顶

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-03（已知最小时间范围），IdeaCapture 真实 `.app` E2E 实跑
- 影响版本／构建：`feature/idea-capture` 分支想法记录功能开发态工作树（0.2.0 之后、尚未提交），固定 `e2e` profile 的隔离 E2E App
- 引入提交：待回填；引入故障的想法置顶功能与修复同处一份已 staged、尚未 commit 的工作树，精确 SHA 在提交确定后回填
- Git author／committer：待回填；随引入提交一并确定
- 实际修改者：未知；现有仓库与 session 证据不足以确认实际操作者
- 修复提交：待回填

## 用户症状与影响

用户在「想法 / Ideas」页面对想法卡片执行置顶后，再次打开同一张卡片的溢出菜单，菜单仍显示「置顶想法」而非「取消置顶」；选择该无效项不能取消置顶，用户没有任何界面路径撤销置顶操作。

故障只影响想法卡片的溢出菜单呈现；领域层 `unpinIdea` 命令、SQLite `pinned_at` 持久化与同步 payload 均正确，症状纯为 macOS 平台菜单项陈旧。本轮只运行 `app.noonmark.mac.e2e`，没有启动、读取、定位或 reset production 身份与资料。

## 时间线

- 想法置顶功能在 `feature/idea-capture` 工作树实现：`IdeaCardView` 溢出菜单按 `pinnedAt == nil` 静态选择「置顶想法／取消置顶」文案，卡片身份只绑定想法 ID。
- 2026-08-03：IdeaCapture E2E 的 pin→unpin 菜单场景首次实跑即响亮失败——置顶后重开溢出菜单仍是「置顶想法」，自动化无法完成取消置顶。
- 多轮取证：对连续运行中第二次弹出做菜单对象 trace，证明平台复用同一 `NSMenu` 对象；尝试把 `.id()` 加在 `Menu` 上，确认对 `NSMenu` 缓存无效。
- 同日：把置顶状态折进卡片身份（`IdeaCardView(idea:).id("<id>-pinned:<bool>")`），症状级场景转绿；同次修复把溢出菜单改为「隐藏 disabled 项＋置顶／编辑／删除」的键盘导航序（pin=1、edit=2、delete=3）。

## 复现与证据

症状级命令：

```bash
NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e
```

关键证据：

- `App/NoonmarkMacApp/IdeaCaptureE2EAutomation.swift` 的 `exercisePinLifecycle` 场景：置顶卡片后以「菜单锚点视图实例更换」作为确定性等待条件，再打开溢出菜单断言「取消置顶」可用并完成取消置顶。修复前该场景在「重开菜单仍显示置顶想法」处判红。
- 菜单对象 trace：同一次连续运行中第二次弹出复用同一 `NSMenu` 对象，菜单项文案停留在首次弹出时的快照。
- 反证：`.id()` 修饰符直接加在 SwiftUI `Menu` 上不触发 `NSMenu` 重建，菜单项依旧陈旧。

## 排除的假设

- 排除领域层未清除置顶：`unpinIdea` 命令、NoonmarkCoreTests 的 pin／unpin 用例与 SQLite `pinned_at` 探针均正确，菜单选择无效时领域状态机本身没有缺陷。
- 排除自动化等待不足：失败不是时序竞态，菜单项在任何等待时长后都保持首次弹出的快照；确定性等待条件（锚点视图实例更换）转绿后场景即稳定通过。
- 排除 `.id()` 加在 `Menu` 上即可解决：实测 `NSMenu` 缓存不受 `Menu` 级 `.id()` 影响，必须把状态折进承载菜单的卡片视图身份。
- 排除 production 资料影响：每轮只 reset 并运行固定 `e2e` profile。

## 根因与破坏机制

SwiftUI `Menu` 在 macOS 上首次弹出后由平台缓存菜单项（`NSMenu`）。置顶会让卡片在「已置顶区 ⇄ 日分组时间线」之间移动，但卡片身份只绑定想法 ID，SwiftUI 视图与底层平台视图不被重建，`NSMenu` 因此保留首次弹出时的菜单项快照： pinned 状态下仍呈现「置顶想法」，选择它没有对应动作，等于取消置顶路径在 UI 层消失。

## 根因修复

`App/NoonmarkMacApp/IdeasPage.swift` 的 `IdeaCardList` 把置顶状态折进卡片身份：`IdeaCardView(idea:).id("<id>-pinned:<bool>")`。置顶状态翻转即重建整张卡片及其 `Menu`，`NSMenu` 随平台视图一并重建，菜单项始终反映当前置顶状态。

同次修复把溢出菜单改为「隐藏 disabled 项＋置顶／编辑／删除」的键盘导航序（pin=1、edit=2、delete=3），取消置顶与置顶始终是同一位置的真实可选动作。

## 验证结果

- 症状红：修复前 `exercisePinLifecycle` 场景稳定判红，重开溢出菜单仍显示「置顶想法」，取消置顶不可达。
- 运行取证：菜单对象 trace 证明连续运行中第二次弹出复用同一 `NSMenu`；`Menu` 级 `.id()` 无效的反证排除了错误修法。
- Fast 绿：`scripts/test-unit` 中 `NoonmarkCoreTests` 的 pin／unpin、tombstone 清除 `pinnedAt` 与恢复不复活置顶用例通过，固定菜单必须反映的领域状态迁移。
- 症状绿：`NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e` 的 `run_idea_capture_probe` 完成 pin→unpin 菜单场景、SQLite `pinned_at` 探针与截图对账。
- 修复 commit：待回填（修复与功能同处 staged 工作树，提交确定后回填并转「已修复」）。

## 永久门禁

- Fast：`scripts/test-unit` 由 `scripts/check` 强制执行，`NoonmarkCoreTests/IdeaEntryTests.swift` 覆盖 `pinIdea`／`unpinIdea`、tombstone 同步清除 `pinnedAt`、恢复不复活旧置顶的领域语义，固定溢出菜单状态机的真值来源。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行，`run_idea_capture_probe` 中 `App/NoonmarkMacApp/IdeaCaptureE2EAutomation.swift` 的 `exercisePinLifecycle` 场景以「菜单锚点视图实例更换」为确定性等待条件，真实走完置顶→重开菜单→取消置顶，菜单项陈旧即判红。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：修复只改变 `App/NoonmarkMacApp/IdeasPage.swift` 的卡片身份与菜单项集合，不改领域模型、SQLite schema、同步 payload 或 production runtime；卡片重建的代价是置顶状态翻转时重挂一张卡片的视图，范围可控。
- 回滚：若卡片身份方案引入新的视图状态丢失（如行内编辑态被重建打断），回滚本修复并继续阻断发行，直到找到同等强度的菜单新鲜度方案；不得用延长等待、强制关闭重开菜单或隐藏取消置顶动作掩盖陈旧。
- 本案为纯 UI 层故障，不影响安装、启动、退出或发行产物，不绑定 release 层门禁。

## 教训与永久约束

- SwiftUI `Menu` 在 macOS 的菜单项是平台缓存快照，不是每次弹出重新求值；菜单项依赖的状态必须进入承载视图的身份，不能假设文案会随状态自动刷新。
- `.id()` 的作用域是它所修饰的视图子树；加在 `Menu` 上不等于让平台 `NSMenu` 重建，平台对象生命周期必须以运行产物取证为准。
- 卡片跨 section 移动（已置顶区 ⇄ 日分组）不改变身份时，平台视图复用会静默保留旧菜单；涉及状态驱动的菜单文案，E2E 必须覆盖「改变状态后重开菜单」的第二轮断言。
- 菜单自动化断言需要确定性等待条件（锚点视图实例更换），不能用固定 sleep 冒充状态转换证据。

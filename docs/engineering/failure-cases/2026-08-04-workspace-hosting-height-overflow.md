# FAIL-2026-08-04-06：飞光错误说明把工作区推离窗口

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 08:14 -04:00
- 影响版本／构建：`f3886fca472bfc86a6050ca6db52e492f41384ff` 之后、尚未提交的飞光 Composer 重构工作树
- 引入提交：尚未进入 Git commit；故障由本轮未提交的可扩展 Composer 首次触发并在提交前拦截
- Git author／committer：不适用；故障变更尚未提交
- 实际修改者：当前 Codex agent；由工作树 diff、用户现场观察、真实 App 视图树与会话记录确认
- 修复提交：待回填

## 用户症状与影响

飞光发布失败、错误说明展开后，左侧栏只剩「Sticky Note」和「飞光」，计划与轨迹模块全部消失。主内容和 Composer 的上部操作也被推到窗口范围之外，造成导航能力大面积丢失。用户在 E2E App 运行现场首先指出该症状。

## 时间线

- 2026-08-04：用户观察到 E2E 运行期间左栏仅显示札记两个模块，并询问是否属于设计。
- 2026-08-04：初始空态与聚焦态截图显示三组完整；失败态视图树显示窗口内容区 `1200×768`，但 `NSSplitView` 高度膨胀为 `1079`。
- 2026-08-04：计划导航被排到 `y=978`，超出窗口；Sticky Note 与飞光位于 `y=620/583`，恰好仍在可见范围，精确解释用户症状。
- 2026-08-04：三个嵌套 `NSHostingController` 的 sizing authority 收回给外层 representable；同一 E2E 越过失败态、完整侧栏与重试，继续完成全部飞光路径。

## 复现与证据

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`，输入不存在的分类并以 `⌘Return` 发布。修复前失败现场证据为：

- `NSHostingView` 与窗口内容区：`1200×768`；
- `PlatformViewHost<NativeWorkspaceSplitView>`：`1200×768`；
- 内部 `NSSplitView`：`1200×1079`；
- `sidebar.nav.day`：`y=978`；
- `sidebar.nav.stickyNotes`／`sidebar.nav.ideas`：`y=620/583`。

这不是静态源码推断：截图、视图树与用户现场观察三者一致。修复后 E2E 在每个主窗口截图节点强制所有十个导航项同时位于 sidebar 与 window content frame 内。

## 排除的假设

- 不是 E2E 最小 fixture 有意隐藏模块：计划页由固定数组提供，空态截图也曾完整显示三组。
- 不是回收站隐藏需求：消失的是计划与轨迹，不是已经明确隐藏的墓碑入口。
- 不是侧栏数据过滤：计划导航无条件存在，故障时 NSView 仍挂载，只是 frame 被推到窗口外。
- 不是普通窗口缩窄：故障发生在 `1200×768`，且内部 split view 高度大于宿主 `311pt`。
- 不是 Composer 按钮锚点自身问题：锚点零可见区域与左栏消失共享同一个超高 `NSSplitView` 根因；恢复 workspace 高度后两者同时转绿。

## 根因与破坏机制

外层 `NSHostingView` 已关闭 sizing options，并把窗口 proposal 交给 `NativeWorkspaceSplitView`；但 split view 内部的 sidebar、content 与 detail 三个 `NSHostingController` 仍使用默认 sizing options。Composer 插入多行错误说明后，content controller 把 SwiftUI 理想高度发布给 `NSSplitViewController`，内部 split view 接受 `1079pt`，突破外层 `768pt` 容器。其子项保持底部坐标系排列，所以上方计划与轨迹整体离窗，而下方札记仍可见。

## 根因修复

- 明确设置三个嵌套 `NSHostingController.sizingOptions = []`；外层 representable/window proposal 成为工作区唯一尺寸权威。
- Composer、错误说明与详情内容可以在各自表面内部增长或滚动，但不得反推主 split view 的窗口高度。
- 真实 App E2E 在截图前检查十个导航项的 frame 同时落在 sidebar 与 window content 内，不能再以“NSView 已挂载”冒充用户可见。

## 验证结果

- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：失败态、`960×720` 右栏、全部导航截图节点、完整重启与 SQLite 探针通过。
- `scripts/test-notes-ui-contract`：通过。
- `make check`：通过；完整工作树的 build、UT、IT、ST、确定性仿真、契约、SwiftLint 与 SwiftFormat 门禁均为绿。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用；三个嵌套 Hosting Controller 必须关闭理想尺寸反推，E2E 必须保留 window content containment 断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用；真实 App 展开失败说明及窄窗口右栏时，任一计划／轨迹／札记导航离开窗口即判红。

## 发行与回滚

本轮只运行固定 `e2e` profile，不启动或读取 production。修复提交与完整门禁确定前保持处理中；若回归，停止交付并回退整个飞光 Composer cutover，不得通过放大窗口、缩短错误文案或隐藏导航掩盖尺寸所有权故障。

## 教训与永久约束

嵌套 SwiftUI/AppKit 容器必须只有一个尺寸权威。可扩展子内容不得改变工作区根 frame；UI 可见性验收必须把控件 frame 与真实 window content 对账，不能只检查视图树中是否存在。

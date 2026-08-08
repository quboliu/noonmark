# FAIL-2026-08-05-01：已完成池投影 O(n²) 全表扫描叠加视图重复计算导致页面切换卡顿

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05（用户在年度演示基线交互验收中报告）
- 影响版本／构建：0.2.1 (6) 及之前全部包含已完成池轨迹投影的构建
- 引入提交：`30fb2adee836909f71cfce7b6afd6b28bb9592f6` feat(core): Complete task trajectories in the completed pool（2026-07-05）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（历史已统一改写为该身份）
- 实际修改者：未知
- 修复提交：`874980047b45da44e0f3e5b9910cf71ff91b8824` fix(core): make the completed pool projection near-linear；本轮门禁收口提交待创建后回填

## 用户症状与影响

年度数据规模（460 条已完成任务链、1569 条 DayTrace、1083 条子任务）下，在 Mac App 中从「未完成」切换到「已完成」页面主线程卡顿 5-6 秒，界面完全无响应。数据量越大卡顿越严重，属于随使用时长必然恶化的缺陷。

## 时间线

- 2026-07-05：`30fb2ade` 引入按链轨迹投影，`completedTrajectory(for:)` 对单条完成 trace 全表扫描 `traces.values` 并全扫 `subtasks.values`。
- 2026-08-05：用户在 `make run-demo-app` 年度基线上复现 5-6 秒卡顿并报告；同日完成 sample 取证、根因定位、修复与 fast gate 红绿验证。
- 2026-08-08：发布前 `make check` 再次在同一 1200→2400 链 fast gate 判红（两次运行耗时比分别为 3.04、2.88），确认不是单次机器抖动。

## 复现与证据

1. `make run-demo-app` 启动年度演示基线（365 天故事，460 条已完成链）。
2. 以 `--page completed` 直接打开已完成页，`sample` 采样主线程 10-15 秒。
3. 修复前证据（`/tmp` 采样，未入库）：主线程 12219 个采样中 1857 个落在 `CompletedPoolPage.body.getter → hierarchiesByID.getter → NoonmarkEngine.completedTaskHierarchies() → completedPool() → completedTrajectory(for:)`，其中大量 `initializeWithCopy for DayTrace` 值拷贝。
4. 微基准（debug，本机）：旧实现 `completedTaskHierarchies()` 在 1200→2400 链合成规模下耗时 0.401s→1.303s（耗时比 3.25，平方特征）；新实现同规模耗时比约 2.1（近线性）。

## 排除的假设

- SQLite 持久化读取慢：采样显示热点在内存投影而非存储层，排除。
- SwiftUI 行渲染过多：行使用 LazyVStack 惰性渲染，热点在数据投影计算而非布局，排除。
- `carryoverKind(for:)` 查询慢：该函数为 O(1) 字典查询，排除。
- Keychain 阻塞：修复后验证时出现的 `SecItemCopyMatching` 阻塞是重签名后 ACL 不匹配的启动期现象，与本案卡顿无关，排除。

## 根因与破坏机制

两层叠加：

1. 引擎层 O(n²)：`NoonmarkEngine.completedPool()` 对每条完成 trace 调用 `completedTrajectory(for:)`，后者每次都 `traces.values.filter { $0.chainID == ... }` 全表扫描并排序，`completedSubtaskTrajectories(for:)` 每次全扫 `subtasks.values`。460 条链 × 数千条记录形成平方级工作量，并伴随大量 DayTrace 值类型拷贝。
2. 视图层重复计算：`CompletedPoolPage.hierarchies` 是计算属性，每次 body 求值都同步重算引擎投影，且单次求值内经 `presentationSections`、`hierarchiesByID`、`isEmpty` 多处重复触发，全部发生在主线程。

## 根因修复

- 引擎（`Sources/NoonmarkCore/NoonmarkEngine.swift`）：`completedPool()` 一次性预分组历史 trace（按 chainID、按 traceChronology 排序）与可展示子任务（按 traceID），`completedTrajectory`／`completedSubtaskTrajectories` 改为消费预分组数据。公开行为零变化。
- 本轮补齐：`completedTaskHierarchies()` 原本又先调用两个面向 UI 的已排序公开投影，再立即按 chain 重组；1200／2400 个独立链时这两次无用全局排序使规模倍率越过门禁。现以仅供层级投影使用的未排序内部集合分组，再只执行最终 hierarchy 的用户可见排序；`completedPool()` 与 `completedSubtaskRecords()` 的公开排序行为保持不变。
- 视图层（`App/NoonmarkMacApp/NoonmarkStore.swift` 等 7 个文件）：store 新增按 `engineRevision` 备忘的 `completedPool()`／`completedTaskHierarchies()`／`unfinishedPool()` 共享入口，同一数据版本只计算一次；CompletedPoolPage、UnfinishedPoolPage、WorkspaceDetailRails、选择与会话撤销等全部调用点改走共享入口。引擎为 class 但所有变更经 mutation lane 赋值提交（didSet 递增 engineRevision），失效语义完整。

## 验证结果

- `swift build` 通过。
- `swift test --filter NoonmarkCoreTests`：285 个测试全部通过（行为保持）。
- fast gate 红绿验证：旧引擎下新性能测试判红（耗时比 3.25 > 阈值 2.7），修复后判绿（约 2.1），单次运行约 1.9 秒。
- 发布前复验：原始 1200→2400 层级测试在优化后连续两次通过（单次约 2.58 秒及 2.40 秒），保留原倍率与绝对上限，不放宽阈值。
- 症状级验证（2026-08-05）：修复后重建 demo App，以 `--page completed` 直开已完成页，页面完整渲染 460 条链与右栏汇总（截图核验），8 秒主线程采样中投影栈（CompletedPoolPage／completedTaskHierarchies／completedPool／completedTrajectory）命中 0 次；修复前同路径 1857/12219 次。卡顿症状消除。

## 永久门禁

- fast：`swift test --filter testCompletedTaskHierarchiesStaysNearLinearAtAnnualScale`（随 `make check` 的 NoonmarkCoreTests 执行），1200→2400 链耗时比阈值 2.7 + 绝对上限，捕获复杂度回退。
- symptom：真实年度 demo 基线已完成页 sample 对比（修复前 1857/12219 采样在投影栈内，修复后为 0），由 `make run-demo-app` 交互验收承担。

## 发行与回滚

不涉及安装、签名、启动、退出或发行产物，无需 release 门禁。回滚即还原本案例对应修复提交；旧实现无数据格式变更，回滚安全。

## 教训与永久约束

- 池化／轨迹类投影禁止在单条记录处理闭包内全表扫描引擎集合；需要先构建一次分组上下文。
- SwiftUI 页面 body 内禁止直接调用引擎全量投影；跨多次读取的派生数据必须在 store 层按 engineRevision 备忘。
- 性能门禁用「规模翻倍耗时比」比绝对阈值更抗机器差异，但规模点必须大到二次项主导，否则旧实现可能漏判（本案 400→800 链时旧实现耗时比仅 3.0，几乎漏过）。

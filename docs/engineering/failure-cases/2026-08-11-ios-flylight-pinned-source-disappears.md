# FAIL-2026-08-11-07：飞光加入 Sticky Note 后来源条目消失

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11，真实 iPhone Simulator 生命周期回归
- 影响版本／构建：当前工作树，iOS development Simulator build
- 引入提交：未知（当前工作树改动未提交）
- Git author／committer：未知（当前工作树改动未提交）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

用户在飞光中把条目加入 Sticky Note 后，飞光时间线显示“还没有飞光”；SQLite 中条目仍存在且已置顶。Sticky Note 来源浏览因此无法从飞光正常继续，属于 iOS 与 Mac 共享领域投影不一致。

## 时间线

1. iOS Simulator 真实创建飞光并点击“加入 Sticky Note”。
2. UI 层级进入飞光空状态，症状门禁在点击后回读失败。
3. SQLite 探针确认同一条目仍存在，`pinned_at` 已写入，排除删除或持久化丢失。
4. Core 源码确认 `ideaTimeline()` 有意排除 pinned 条目；Mac 页面使用 `ideaCollection` 合并来源投影。

## 复现与证据

- 症状命令：`xcodebuild test ... -only-testing:NoonmarkIOSUITests/NoonmarkIOSUITests/testUserCanPinRestoreAndDeleteFlylightInSimulator`。
- 失败 UI 层级：点击后出现 StaticText“还没有飞光”。
- SQLite 运行产物：`idea_entries` 中测试条目仍为 active，`pinned_at` 非空，`deleted_at` 为空。
- 对照源码：`NoonmarkEngine.ideaTimeline()` 传入 `pinned: false`；Mac 的 `ideaCollection(.recent/.search)` 将 `pinnedIdeas` 与时间线重新合并。

## 排除的假设

- 不是 Sticky Note Button hit-test 失败：按钮已被真实 XCTest 点击。
- 不是页面导航竞态：创建内容在点击前已存在，失败发生在点击后的投影更新。
- 不是 SQLite 写入失败或条目删除：运行后数据库仍保留 active pinned 条目。

## 根因与破坏机制

`IOSFlylightPage` 直接调用 `engine.ideaTimeline()`。该 API 是排除 pinned 条目的兼容时间线投影；加入 Sticky Note 后条目被正确置顶，却被 iOS 页面误当作从飞光移除。Mac 使用 `ideaCollection`，因此没有这个破坏机制。

## 根因修复

让 iOS 飞光页面按搜索状态调用 `ideaCollection(.recent/.search, today:)`，由 Core 的统一集合投影合并飞光来源与 Sticky Note 状态。

## 验证结果

修复后的 focused Simulator symptom gate 已通过：固定 `Noonmark iPhone 17 Pro` 上 1 项、0 failures；随后完整 `scripts/test-ios-simulator` 通过 8 项、0 failures，覆盖来源仍在飞光、Sticky Note 浏览、移除、删除、恢复、正文编辑和重启回读。修复提交待回填；当前工作树尚未提交，因此案例继续保持“处理中”。

## 永久门禁

- fast：`scripts/test-ios-target-contract` 检查 iOS 飞光生命周期路径仍被编译进 contract。
- symptom：`scripts/test-ios-simulator` 真实验证加入 Sticky Note 后来源仍在飞光、Sticky Note 浏览、移除、删除、恢复与重启回读。

## 发行与回滚

当前没有 iOS 发行入口。若需要回滚，必须恢复到同一共享集合投影边界并保留症状门禁；不得把 pinned 条目从来源时间线静默移除来绕过 UI 问题。

## 教训与永久约束

页面不得自行拼接领域投影规则。Sticky Note 是飞光的投影，不是删除来源的第二集合；iOS 与 Mac 必须使用同一个 Core collection API。

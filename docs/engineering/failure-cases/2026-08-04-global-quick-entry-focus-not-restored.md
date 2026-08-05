# FAIL-2026-08-04-25：全局 Quick Entry 未恢复原前台应用

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04T17:37:51Z
- 影响版本／构建：0.2.1 (build 6)，`a3f7d06`
- 引入提交：待确认；两个全局面板控制器均使用普通 activation
- Git author／committer：未知
- 实际修改者：未知
- 修复提交：`f979cd8fbd2c183a30ddbe27789bf6d090d485fd`（`fix(shortcut): 恢复全局录入后的前台应用`）

## 用户症状与影响

用户从 Finder 等其他应用唤起全局 Quick Entry、提交后，面板虽关闭并创建任务，但焦点仍停留在晷迹，打断原应用的连续输入。飞光全局捕捉使用相同复原路径，也有相同风险。

## 复现与证据

完整隔离真实 App E2E 于 `2026-08-04T17:37:51Z` 在 `artifacts/e2e-global-quick-entry/result.txt` 失败为「Quick Entry did not restore Finder focus」。此前同一流程已确认 Finder 可成为前台应用，且任务已经由 Quick Entry 创建；因此不是 Finder 不可激活或提交失败。

## 排除的假设

- 排除 Finder 无法成为前台应用：打开全局面板前的 Finder 前台等待已通过。
- 排除 Quick Entry 未提交：同一真实路径已对账任务创建与面板关闭。
- 排除只修 E2E 时序：应用实际使用普通 activation，未要求当前晷迹进程让出前台。

## 根因与破坏机制

`NoonmarkQuickEntryWindowController` 与 `NoonmarkIdeaCaptureWindowController` 都在关闭时调用 `previousApplication.activate(options: [])`。该普通请求不保证在当前应用仍为活动状态时取得前台；结果是用户所处应用不会可靠地重获焦点。

## 根因修复

两个全局面板先对已捕获的先前应用调用 `NSApp.yieldActivation(to:)`，待面板关闭后的下一个主运行循环，再通过 macOS 14 的 `activate(from: .current, options: [])` 进行协调激活。该操作只作用于已捕获的 `NSRunningApplication`，不记录应用名称、路径或其他用户资料。

## 验证结果

专项真实 E2E、完整 `scripts/test-e2e` 与 `make check` 均通过；完整 E2E 审计清单为 `suite_exit_status=0`。修复提交如上。

## 永久门禁

- fast：`scripts/test-global-panel-focus-restoration-contract`
- symptom：`scripts/test-e2e`

## 发行与回滚

完整真实 E2E 未转绿前不推送；可回退修复提交。

## 教训与永久约束

全局临时面板必须把前台复原视为用户可见行为，不能将普通 activation 当成跨应用焦点转移保证。

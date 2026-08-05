# FAIL-2026-08-04-24：已完成页父任务选择命中 disclosure

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04T17:24:48Z
- 影响版本／构建：0.2.1 (build 6)，`06464d75e50c8e6d31db5b681405cedf06e2b77e`
- 引入提交：待确认；当前紧凑布局可稳定复现
- Git author／committer：未知
- 实际修改者：未知
- 修复提交：`a3f7d06da1fe735dfc63abf54c0567d3c7a667b1`（`fix(e2e): 避免完成页父任务选择命中展开按钮`）

## 用户症状与影响

完成页进行中父任务的中心点击可落到相邻子任务 disclosure，未选中预期任务。

## 复现与证据

隔离命令 `NOONMARK_E2E_TASK_CYCLE_MUTATION_ONLY=1 scripts/test-e2e` 稳定失败为「进行中父任务分类编辑器」。失败 view tree 表明整行锚点中心与 disclosure 重叠。

## 根因与破坏机制

整行 layout 锚点被错误地用作物理点击目标，中心坐标并不属于父任务内容区。

## 根因修复

标题区提供不覆盖 disclosure 的 `parent-select` 命中锚点，task-cycle 驱动只使用该锚点。

## 验证结果

专项 task-cycle E2E、完整 `scripts/test-e2e` 与 `make check` 均通过；完整 E2E 审计清单为 `suite_exit_status=0`。修复提交如上。

## 永久门禁

- fast：`scripts/test-completed-hierarchy-parent-selection-contract`
- symptom：`scripts/test-e2e`

## 发行与回滚

完整真实 E2E 未转绿前不推送；可回退修复提交。

## 教训与永久约束

布局锚点不可同时充当会与子控件重叠的物理点击目标。

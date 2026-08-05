# FAIL-2026-08-04-30：全局飞光候选容器不是物理点击目标

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05T03:34:00Z
- 影响版本／构建：`fda6a7a` 后的隔离 macOS E2E 构建
- 引入提交：待以修复后的 Git 历史比对回填；当前运行产物只能证明 E2E target drift，不能证明精确引入提交
- Git author／committer：待回填
- 实际修改者：未知
- 修复提交：`bf4cc5f13a8cf582539bfff8f261e99519d1f1c8`（`fix(e2e): 命中飞光具体候选按钮`）

## 用户症状与影响

全局飞光速记浮窗输入 `@工` 并显示分类建议后，真实 WindowServer E2E 有时无法物理点击建议。用户界面与领域查询已产生候选；受影响的是自动化把候选列表容器当作单一点击目标，而用户实际点击的是其中一条候选按钮。

## 复现与定位证据

- 红色真实路径：`scripts/test-e2e` 中 `IdeaCaptureE2EAutomation` 的全局飞光面板，报出 `idea-capture.field.suggestions` 没有可点击可见面积。
- 同一运行已确认前台 App、隔离 e2e profile 与候选出现条件；失败发生在 WindowServer mouseDown 前的命中解析。
- 源码与视图边界：`NewTaskClassificationSuggestionList` 将多个 `Button` 包在 `idea-capture.field.suggestions` 容器中；容器没有单一用户点击语义。

## 排除的假设

- 分类建议业务逻辑未产生候选：等待条件已观察到候选容器，且专项路径会完成 `@工` 到 `@工程 ` 的补全。
- 用户资料、SQLite 或同步损坏：失败在提交前；专项路径以隔离新资料运行。
- 前一个回看刷新失败：该症状与 `ideas.review.refresh` 无关，目标、窗口与失败阶段均不同。

## 根因与修复

E2E 将整个候选列表容器当作可点击控件。该容器会随面板根据候选数调整高度而重排，不能代表任何一个实际点击项。共享候选列表现在为每条原生 `Button` 提供由稳定分类身份组成的被动 E2E anchor；全局飞光 E2E 由当前候选查询得出同一身份，只点击那条真实按钮，并在 mouseDown 前重新解析。

## 验证结果

飞光专项真实 E2E、fast contract、完整 `scripts/test-e2e`、`make check` 与 Demo fixture 均通过；完整 E2E 审计清单为 `suite_exit_status=0`。最终 DMG 仍须以该提交之后的受控验证为准。

## 永久门禁

- fast：`scripts/test-idea-capture-interaction-target-contract`，由 `scripts/check` 调用，要求候选项拥有稳定 item-level anchor，禁止全局飞光点击列表容器。
- symptom：`scripts/test-e2e`，真实全局面板必须完成候选显示、物理选择、发布、重启与 SQLite 分类回读。

## 发行与回滚

在完整 E2E、`make check` 与 DMG 验收通过前不得推送或清理分支。若回归，回滚关联 E2E 交互修复；不变更飞光、分类、同步或升级资料。

## 教训与永久约束

一组按钮的布局容器不能成为单一点击 target。E2E 必须命中与用户操作同构的具体控件，并以稳定领域身份关联该控件。

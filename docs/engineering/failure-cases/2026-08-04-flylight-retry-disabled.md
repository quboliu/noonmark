# FAIL-2026-08-04-05：飞光失败态重试按钮不可操作

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 08:08 -04:00
- 影响版本／构建：`f3886fca472bfc86a6050ca6db52e492f41384ff` 之后、尚未提交的飞光 Composer 重构工作树
- 引入提交：尚未进入 Git commit；故障由本轮未提交的 Composer 状态机首次引入并在提交前拦截
- Git author／committer：不适用；故障变更尚未提交
- 实际修改者：当前 Codex agent；由工作树 diff、真实 App E2E 与会话记录确认
- 修复提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9`

## 用户症状与影响

飞光发布失败后，界面会显示错误说明和「重试」，但按钮实际上处于 disabled。用户看到明确恢复入口却无法点击，草稿虽然仍在，失败流程无法按界面承诺继续。

## 时间线

- 2026-08-04：K3 复审要求 Composer 具备 dirty／invalid／saving／success／failed 确定状态，并在 failed 状态提供可见重试。
- 2026-08-04：真实 App E2E 以不存在的分类触发失败；状态、草稿、零写入与「重试」文案均出现，但真实按钮命中探针返回不可操作。
- 2026-08-04：定位 `canSubmit` 同时要求 `issueMessage == nil`；失败原因本身写入 `issueMessage`，因此 failed 状态必然禁用重试。
- 2026-08-04：failed 且非空草稿改为允许提交；确定性的 invalid 状态继续禁用。WindowServer 物理点击重试后仍原位失败、草稿不丢且 SQLite 零写入。

## 复现与证据

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。修复前视图树同时显示 `ideas.composer.surface=failed`、错误说明与 `ideas.composer.primary=重试`，但 `buttonInteractionTarget` 无法解析真实点击区域，门禁返回 `failed publish did not expose an actionable retry`。

修复后同一 E2E 以 WindowServer 点击「重试」，session 再次进入 failed，原草稿逐字保留，活动飞光仍为零；随后清除草稿并继续完整创建、编辑、重启与 SQLite 对账流程。

## 排除的假设

- 不是按钮文案未刷新：失败现场视图树已经显示「重试」。
- 不是草稿被清空：session 与原生编辑器均保留完整失败草稿。
- 不是失败提交产生部分写入：引擎时间线与 SQLite 探针均保持零新增。
- 不是 WindowServer 权限或前台身份问题：同一运行中的其他 Composer 按钮可被物理点击，根因只出现在 failed 的 enablement 条件。

## 根因与破坏机制

共享 Composer 用 `issueMessage == nil && (state == .dirty || state == .failed)` 计算可提交状态。分类解析失败会把恢复说明保存为 `issueMessage`，因此 `.failed` 虽然改变标题为「重试」，却永远无法满足 enablement。视觉状态与真实操作状态由两套相互矛盾的条件驱动。

## 根因修复

- 非空 `.failed` 草稿始终允许重试；失败说明只解释失败，不再反向禁用恢复入口。
- `.invalid` 仍要求修正确定性输入错误后才允许提交，避免把语法校验与可重试运行失败混为一谈。
- 真实 App E2E 不只读标题，而是解析真实命中区、WindowServer 物理点击并验证重试后的 session 与资料不变量。

## 验证结果

- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：失败态物理重试、草稿保留及零误写通过。
- `scripts/test-notes-ui-contract`：通过。
- `make check`：通过；完整工作树的 build、UT、IT、ST、确定性仿真、契约、SwiftLint 与 SwiftFormat 门禁均为绿。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用；约束 failed 非空草稿可重试，并保留本地重试文案与物理点击路径。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用；真实 App 触发失败、显示说明、物理点击重试并对账草稿与零写入。

## 发行与回滚

本轮只运行固定 `e2e` profile，不启动或读取 production。修复已随 `1e2f45ad68a821e24d76a0d6442418f3d338aed9` 进入版本历史；若后续验证回归，停止交付本轮 Composer cutover，不得以隐藏错误说明或移除重试入口规避。

## 教训与永久约束

按钮标题、状态样式与 enablement 必须来自同一个状态机。任何写着「重试」的控件都必须通过真实指针操作证明可点击，静态文案与截图不能代替交互证据。

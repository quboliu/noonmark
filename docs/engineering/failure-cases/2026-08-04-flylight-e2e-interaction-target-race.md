# FAIL-2026-08-04-28：飞光 E2E 点击命中被动锚点或重挂载目标

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05T01:36:52Z
- 影响版本／构建：0.2.1 (build 6)，`b895c8620b10a209db0c7815d2be6150f1aa550c`
- 引入提交：`ff86af0a`（飞光 E2E 共享点击辅助函数首次按被动锚点中心取点）；后续 SwiftUI 重挂载可使该假设不成立
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（以完整 Git 记录为准）
- 实际修改者：未知；Git identity 不能证明实际操作者。
- 修复提交：`d819ef02c2e9199a327cbbeedbe5da520e992468`（`fix(e2e): 命中飞光真实交互控件`）

## 用户症状与影响

真实飞光 E2E 会在筛选框已经可见时报告未获得焦点，或在点击回看刷新动作前报告目标已变化。该失败阻断发行验证，也会降低真实 WindowServer 自动化对用户交互的证明强度。

## 复现与证据

- 2026-08-05 的完整 `scripts/test-e2e` 在飞光场景失败为“筛选字段未获得焦点”；失败 view tree 同时证明被动 `ideas.filter` 锚点与内部 `AppKitTextField` 都可见。
- 紧接着的聚焦飞光 E2E 再现为“`ideas.review.refresh` 在 mouseDown 前目标已变化”，前台应用与 E2E bundle 身份均正确。
- 两次失败分别发生在文字输入和按钮点击，排除单一业务动作或诊断 recorder 导致的失败。

## 排除的假设

- 排除飞光领域逻辑失败：筛选框与回看动作均已渲染，错误发生于输入驱动尚未发送 mouseDown 的目标重新解析阶段。
- 排除前台丢失：第二次失败中的前台 bundle 与当前 E2E 进程一致。
- 排除已修复的分类诊断问题：该断言已经通过，失败发生在后续独立筛选／回看路径。

## 根因与破坏机制

共享 `click` helper 只按被动 `AppE2EViewAnchor` 的几何中心点击，未优先命中其 hit-test 得到的真实控件；仅凭几何重叠查找 `NSTextField` 也会把隐藏或无关输入面误当成格式按钮。并且 `WindowServerInputDriver` 在 mouseDown 前重新解析目标时，helper 将 SwiftUI 合法重挂载的一帧视为不可恢复的最终失败。

## 根因修复

共享 helper 对原生文本编辑器直接验证 hit-test；其他被动锚点统一用 `buttonInteractionTarget` 的真实 hit-test 命中区，不再按几何重叠猜测输入控件。只对“目标在 mouseDown 前重挂载”的精确错误重新激活并解析，其他 WindowServer 或行为失败保持 fail-closed。

## 验证结果

fast contract、连续聚焦飞光 E2E、完整 `scripts/test-e2e` 与 `make check` 均通过；完整 E2E 审计清单为 `suite_exit_status=0`。修复提交如上。

## 永久门禁

- fast：`scripts/test-idea-capture-interaction-target-contract`
- symptom：`scripts/test-e2e`

## 发行与回滚

完整真实 E2E 未转绿前不推送。若回滚，回退修复提交；不触碰业务 SQLite、同步资料或 production runtime。

## 教训与永久约束

被动 E2E 锚点只负责证明几何和状态，不能替代真实控件命中目标；WindowServer 驱动的最终 target reconciliation 必须容忍 SwiftUI 合法重挂载，但不能吞没前台、可见性或行为断言失败。

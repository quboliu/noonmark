# FAIL-2026-08-04-19：飞光回看刷新按钮目标漂移

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 10:56 -04:00
- 影响版本／构建：2026-08-04 当前工作树构建的隔离 E2E App
- 引入提交：`7a639ee4deac5969a103796076e9147c7fb54a3b feat(ideas): 重做想法捕捉与浏览骨架`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

飞光进入回看后，「换一组」按钮可见，但真实 WindowServer 点击在 `mouseDown` 前发现目标身份已经改变并拒绝操作。用户可能遇到点击反馈不稳定；自动化也无法证明刷新后的 review seed 能经 Sticky Note 来源跳转精确恢复。

## 时间线

- 2026-08-03：`7a639ee4` 加入回看刷新按钮，只设置 SwiftUI accessibility identifier，没有应用拥有的稳定命中锚点。
- 2026-08-04 10:56：本轮扩展真实来源恢复 E2E，首次物理点击「换一组」，稳定返回 `target changed before mouseDown`。
- 2026-08-04：源码和失败日志对账确认按钮动作、回看模式与前台 App 身份均正确；缺失的是 mouseDown 前可复核的稳定目标。
- 2026-08-04：锚点移动到 Button 触发器背景，等待同一路径转绿。

## 复现与证据

运行：

```text
NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e
```

exercise 进程在真实 E2E App 返回：

```text
idea capture WindowServer click failed for ideas.review.refresh:
target changed before mouseDown: ideas.review.refresh,target={unavailable}
```

同一行证据确认前台 PID 与 `app.noonmark.mac.e2e` 完全匹配，因此不是点击投递给其他 App。

## 排除的假设

- 不是回看模式未打开：目标在等待阶段已经出现，失败发生在同一次点击的 mouseDown 前复核。
- 不是 App 失去前台：失败报告中的 current PID、frontmost PID 与 bundle identifier 一致。
- 不是 review seed 业务逻辑拒绝：`refreshIdeaReview()` 尚未收到动作，失败发生在 UI 命中边界。
- 不是 production 身份或资料：复现只运行固定 `e2e` profile。

## 根因与破坏机制

刷新按钮只有 SwiftUI accessibility identifier，没有 `AppE2EViewAnchor`。SwiftUI 可以在布局或状态更新间重建桥接视图，严格物理输入驱动解析到的瞬态对象因此在 mouseDown 前消失。驱动正确 fail-closed，但产品触发器缺少应用自有的稳定身份边界。

## 根因修复

- 在「换一组」Button 触发器背景放置 `ideas.review.refresh` 的稳定 `AppE2EViewAnchor`。
- 保持原按钮动作、视觉和 accessibility identifier 不变，不给原生内部子视图绑定长期身份。
- 真实 E2E 从回看物理刷新 seed，再经 Sticky Note 打开来源并恢复原模式与精确 seed。

## 验证结果

- 待重跑 `scripts/test-notes-ui-contract`。
- 待重跑 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。
- 待重跑 `make test-demo-fixture` 与 `make check`。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求刷新按钮触发器拥有稳定锚点。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，以 WindowServer 点击刷新、对账 seed，并验证 Sticky Note 来源恢复。

## 发行与回滚

故障在隔离 E2E 中发现，未启动 production App，也未读取 production 资料。若稳定触发器仍不能通过物理点击，应停止本阶段交付并回退刷新按钮相关修改；不得放宽 exact-target 校验或改用合成状态调用。

## 教训与永久约束

所有要进入真实物理交互门禁的 SwiftUI Button，都必须把稳定身份放在应用拥有的触发器边界。accessibility identifier 负责语义识别，不等于 mouseDown 前可复核的视图身份。

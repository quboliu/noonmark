# FAIL-2026-08-04-13：飞光 saving 状态无法被真实 UI 观察

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:32 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至修复前工作树
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话、源码状态机与 K3 review 确认
- 修复提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec`

## 用户症状与影响

新建与原位编辑虽然定义了 `saving`，但持久化与 `success` 在同一 MainActor turn 内完成，SwiftUI 没有机会绘制 spinner 与「保存中」。用户点击后只看到内容突然消失或成功提示，设计规格中的保存反馈实际上不存在。

## 时间线

- Composer 视觉重构加入五态枚举与 saving 文案。
- K3 对照设计规格后指出状态在同一 turn 内穿越。
- Session 红测确认成功返回时已是 `succeeded`，真实 E2E 也没有 saving artifact。
- 修复后 durable mutation 仍同步完成，设备草稿立即清除；内存编辑值保留一个短过渡供 UI 绘制，再进入成功态。

## 复现与证据

旧实现调用 `submit`／`save` 后立即检查 session，状态已经是 `succeeded`。真实 App 无法等待到 `surface == saving`。修复后单测在 durable mutation 返回后先看到 `saving`，真实 App 物理提交时取得 `ideas-composer-saving.png` 与 `ideas-inline-saving.png`。

## 排除的假设

- 不是 SwiftUI spinner 本身损坏：view 对 `.saving` 的映射存在，问题是状态没有跨渲染机会。
- 不需要把 SQLite 或 Engine 事务改成后台异步：数据可靠性边界应维持同步、原子提交。
- 不能先延迟数据写入来制造动画：那会扩大点击保存后异常退出的数据风险窗口。

## 根因与破坏机制

Session 把业务提交与视觉过渡压在单一同步方法内；发布 `saving` 后不让出可渲染时间便立即发布 `succeeded`，使表面状态机与运行行为不一致。

## 根因修复

持久化成功后立即清除 device-local 草稿，保留内存正文与 `saving` 240 ms，再以 generation guard 清空内存并进入成功态。行内显式保存采用相同过渡；blur／navigation 继续同步结束，避免上下文切换竞态。

## 验证结果

- `IdeaCaptureSessionTests` 对新建与行内保存均断言 durable commit 后仍处于 `saving`，过渡后才成功。
- 定向真实 `.app` E2E 已取得新建与行内 saving frame，并通过最终正文、重启与 SQLite 对账。
- `make test-demo-fixture` 与完整 `make check` 均通过；全量报告为 1500 项测试、0 失败。

## 永久门禁

- fast：`scripts/test-unit`，由 `scripts/check` 强制调用，固定两种 session 的可观察状态顺序。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，物理保存并要求真实 surface 出现 saving 且能截取证据。

## 发行与回滚

只使用 `e2e` 与 `demo` profile。若过渡导致上下文竞态，停止交付并回退视觉过渡；不得延迟 durable mutation 或用假截图取代真实状态。

## 教训与永久约束

枚举中存在状态不等于用户能看见状态。视觉状态机必须同时有确定性单测与真实 App frame 证据。

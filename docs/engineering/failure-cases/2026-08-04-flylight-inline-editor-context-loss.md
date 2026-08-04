# FAIL-2026-08-04-04：飞光行内编辑上下文切换丢失草稿

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 04:55 -04:00
- 影响版本／构建：`f3886fca472bfc86a6050ca6db52e492f41384ff` 之后、尚未提交的飞光编辑器重构工作树
- 引入提交：尚未进入 Git commit；故障由本轮未提交的 `IdeaInlineEditorSession.begin` 重构首次引入并在提交前拦截
- Git author／committer：不适用；故障变更尚未提交
- 实际修改者：当前 Codex agent；由本轮工作树 diff、红测及会话记录确认
- 修复提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9`

## 用户症状与影响

用户编辑飞光 A 后直接双击飞光 B，A 的未保存草稿会被 B 的 session 无条件覆盖；若无效草稿在编辑时切换到 Sticky Note、搜索、回看或分类过滤，页面也可能先离开当前上下文，再发现保存失败。前一种路径会静默丢失输入，后一种路径会把仍在内存中的失败 editor 藏起来，使用户误以为内容已保存或已取消。

## 时间线

- 2026-08-04：K3 首轮 review 静态指出 A → B 会话覆盖风险。
- 2026-08-04：新增两个 `IdeaCaptureSessionTests`；重复进入同一 ID 与异 ID 切换共 4 个断言稳定判红。
- 2026-08-04：真实 `e2e` App 以无效空白草稿点击 Sticky Note，原实现实际离开飞光页，症状门禁判红。
- 2026-08-04：会话、Store preflight、失败焦点恢复与调用层本地状态提交顺序完成修复；同一红测及真实 App 路径转绿。
- 2026-08-04：K3 第二轮复审确认 A → B 与导航事务核心修复成立，并撤回缺乏运行证据的内部工具 blur blocker。

## 复现与证据

运行 `swift test --filter IdeaCaptureSessionTests`。修复前 `testInlineEditorBeginningTheSameIdeaDoesNotOverwriteDirtyDraft` 与 `testInlineEditorRefusesToReplaceAnActiveIdeaWithoutEndingIt` 共出现 4 个失败：脏草稿被原文重置，active ID、原文及草稿均被第二条替换。

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。修复前真实 App 返回 `invalid inline draft did not block navigation`；修复后物理双击 A → B 会先保存 A，空白草稿会阻止离页并把 first responder 送回 editor，合法草稿则保存后进入 Sticky Note。取消证明另以固定 fixture ID 与 `updated_at_bits` 在 App 退出后由 SQLite 精确对账。

## 排除的假设

- 不是 SwiftUI 卡片重绘偶发：纯 runtime session 单元测试不涉及 View，同样稳定覆盖草稿。
- 不是 blur 自动保存已经足够：导航 action 可以先改变页面，本地 `searchIsPresented` 也能独立于 Store mutation 改变。
- 不是所有工具栏点击都会误保存：真实 WindowServer 点击行内 `#` 和取消后，session 保持或明确取消，正文与更新时间不变；该首轮静态推断已被运行证据反驳。
- 不是只需在卡片 View 补 guard：页面、搜索、回看、分类与双击均可改变 editor 上下文，必须在共享 session／Store 边界统一约束。

## 根因与破坏机制

`IdeaInlineEditorSession.begin` 把“开始编辑”当作无条件赋值，没有表达当前 session 的所有权；调用者也没有在上下文 mutation 前先结束旧 session。异 ID begin 因而直接覆盖 A，随后 A 的延迟 blur 又会因为 active ID 已变而退出。页面导航及过滤另把本地 UI 状态和 Store mutation 分开提交，导致持久化失败后仍能隐藏当前 editor。

## 根因修复

- `begin` 对同 ID 幂等，对异 ID 在旧 session 未明确结束时 fail-closed。
- `NoonmarkStore.beginIdeaEdit` 在打开 B 前以 `.navigation` 保存 A；失败则保留 A 并拒绝切换。
- 页面、搜索、回看、分类与跨页统一经过 `prepareForIdeaContextChange`；调用层只在返回成功后更新本地显示状态。
- 无效或持久化失败保留 draft、错误与当前页面，并重新请求 editor focus。
- 显式取消压制随后到达的 blur；真实 App 与 SQLite 同时证明正文及 `updated_at_bits` 不变。

## 验证结果

- `swift test --filter IdeaCaptureSessionTests`：10／10 通过。
- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：A → B、物理取消、无效／有效导航、重启与 SQLite 对账通过。
- `scripts/test-failure-case-gates`：通过，22 个案例的 fast／symptom 映射完整。
- `make check`：通过；完整工作树的 build、UT、IT、ST、确定性仿真、契约、SwiftLint 与 SwiftFormat 门禁均为绿。

## 永久门禁

- fast：`scripts/test-unit`，由 `scripts/check` 强制调用；`IdeaCaptureSessionTests` 钉死同 ID 幂等、异 ID 拒绝、失败草稿保留、取消压制 blur 与成功状态。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用；真实 App 物理双击、工具、取消、失败导航、成功导航、重启及 SQLite `body + updated_at_bits` 任一漂移即判红。

## 发行与回滚

本轮仅使用固定 `e2e` profile，不启动或读取 production。修复已随 `1e2f45ad68a821e24d76a0d6442418f3d338aed9` 进入版本历史。若后续门禁回归，停止交付并回退整组飞光编辑器 cutover；不得恢复无 guard 的 session begin 或先 mutation 后保存的导航顺序。

## 教训与永久约束

单一行内 editor 是有所有权的资料事务，不是一个可随时覆盖的 View 状态。任何会改变条目、集合或页面可见性的 intent，都必须先在同一边界完成保存或明确取消；失败时连本地 UI 状态也不得越过该边界。

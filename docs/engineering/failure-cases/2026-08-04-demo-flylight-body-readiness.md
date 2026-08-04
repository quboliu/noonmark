# FAIL-2026-08-04-21：Demo 在飞光正文重新挂载前继续物理编辑

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 12:30 -04:00
- 影响版本／构建：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec` 至修复前工作树
- 引入提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec` `fix(flylight): 补齐编辑恢复与真实交互门禁`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由 Git blame、运行视图树与本次工作会话确认
- 修复提交：`798ae5a46d95cc8bbbc6c6a87e3374c29f53b7f8`

## 用户症状与影响

运行 `make run-demo-app` 时，年度 Demo fixture 在飞光原位保存后失败，无法启动可体验的 Demo。失败时目标条目仍显示「保存中」编辑面，因此用于下一步双击的正文锚点不存在。

## 时间线

- 飞光保存态改为可见的异步视觉过渡后，Demo 自动化只对账了领域正文已写入。
- 本次启动 Demo 时，fixture manifest 记录正文锚点不存在；运行视图树同时显示同一条目仍在 saving 编辑态。
- 修复为将 UI 正文重新挂载作为下一步物理双击的前置条件。

## 复现与证据

在隔离 `demo` profile 运行 `make run-demo-app`。失败 manifest 报告飞光正文目标不存在；同轮 view-tree 显示对应 `ideas.card.edit-field` 的 surface 文本为 `saving`，且没有对应的 `ideas.card.body`。这证明不是条目丢失或定位错误，而是领域状态完成早于 SwiftUI 替换编辑视图。

## 排除的假设

- 不是条目未投影或滚动卸载：同一条卡片和编辑字段仍在运行视图树内。
- 不是持久化失败：领域引擎已包含保存后的正文，错误发生在下一次物理双击解析 UI 目标时。
- 不使用任意 sleep：固定延时无法表达不同机器上的真实 SwiftUI 重绘边界。

## 根因与破坏机制

Demo 的保存验证只等待 `editingIdeaID == nil` 与 Engine 正文更新。可观察 saving 过渡使这些领域条件能先于正文 NSTextView/Markdown surface 重新挂载成立；随后目标解析立即失败，导致验收安装被中断。

## 根因修复

将保存后正文恢复封装为 `waitForFlylightCardBody`：它同时要求对应正文锚点存在、可见且其文本与已保存正文一致。首次保存后重新编辑与最后恢复 fixture 正文后继续流程都经过该边界。

## 验证结果

- `make build` 通过。
- `scripts/test-notes-ui-contract` 通过，固定要求 Demo 含正文重新挂载断言。
- `scripts/test-interactive-demo-fixture` 在真实 Demo App、WindowServer 物理交互和隔离资料上通过。
- `make run-demo-app` 已重新生成 ready manifest 并启动纯展示 Demo。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求 Demo 在继续物理编辑前保留飞光正文重新挂载断言。
- symptom：`scripts/test-interactive-demo-fixture`，由 `scripts/test-all` 强制调用，真实 Demo 必须完成保存、正文恢复及后续 WindowServer 交互并产出 ready manifest。

## 发行与回滚

仅使用隔离 `demo` profile。若正文未在规定时间内重挂载，fixture 必须 fail-closed，不得把缺失锚点替换为坐标点击或人为延时。回滚只可回滚本次自动化边界，不能移除可观察 saving 状态。

## 教训与永久约束

领域完成不等于用户界面已可操作。任何真实物理输入的下一步都必须等待其实际目标完成挂载并对账内容，而不是只检查 store。

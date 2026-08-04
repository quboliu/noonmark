# FAIL-2026-08-04-15：飞光脏草稿无法明确收起

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 10:03 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至修复前工作树
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话与源码状态机确认
- 修复提交：待回填

## 用户症状与影响

页面 Composer 中只要存在未发布正文，点击「收起」或按 Esc 都只会失焦，编辑面高度不会收回。草稿越长，用户越无法暂时让出阅读空间，按钮文案与实际行为相反。

## 时间线

- Composer 重构以「聚焦、明确展开或正文非空」三者任一为真决定展开。
- 正式 Spec review 对照「收起并保留草稿」要求发现正文非空会永久覆盖明确收起动作。
- 真实 App 物理输入脏草稿后复现旧行为；修复后同一路径稳定收成紧凑态并可重新展开。

## 复现与证据

在 `e2e` profile 打开飞光，输入未发布正文，物理点击「收起」。旧实现中 surface 仍保持工作态高度。修复后的 `ideas-composer-dirty-collapsed.png` 显示紧凑表面，Engine 未新增条目，设备草稿与原生编辑器 value 均保持原值。

## 排除的假设

- 不是草稿持久化失败：正文始终留在 session 与 device-local repository。
- 不是失焦事件没有到达：first responder 已释放，只有展开派生逻辑重新撑开表面。
- 不能通过清空草稿实现收起：这会直接损坏用户尚未发布的内容。

## 根因与破坏机制

`isExpanded` 把「正文非空」当成不可覆盖的展开条件，没有建模用户明确收起的意图。次操作虽然把 `isExpandedByIntent` 设为 false，但非空正文随即让结果继续为 true。

## 根因修复

加入独立的明确收起状态。页面新建模式优先尊重该状态；聚焦、格式命令、正文再次变化或明确展开才解除。收起只释放焦点并持久保存草稿，不发布、不清空。

## 验证结果

- `swift build` 通过。
- 定向真实 `.app` E2E 物理输入、收起、AX 对账、重新展开与清理均通过。
- Demo 与完整 `make check` 待最终回填。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求明确收起状态、Demo 覆盖与真实截图断言存在。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，在真实 App 物理点击「收起」，检查紧凑几何、草稿、AX value 与重新展开。

## 发行与回滚

只使用 `e2e` 与 `demo` profile。若明确收起造成草稿丢失或发布，停止交付并回退本次状态边界；不得回退为假收起或清空草稿。

## 教训与永久约束

派生 UI 状态不能吞掉同名用户 intent。凡动作写明「收起并保留」，真实 App 门禁必须同时证明几何收起与内容原值保留。

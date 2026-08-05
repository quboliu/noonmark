# FAIL-2026-08-04-27：飞光未解析分类诊断未持久化

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05T01:20:00Z
- 影响版本／构建：0.2.1 (build 6)，`3224159`
- 引入提交：`0341bccd6e54ac071aa095693b98bf16fa4b9833`（收窄修改拒绝的 failure 记录）；`06464d75e50c8e6d31db5b681405cedf06e2b77e`（新增飞光领域校验诊断但未扩大共享边界）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（两项提交）
- 实际修改者：未知；Git identity 不能证明实际操作者。
- 修复提交：`b895c8620b10a209db0c7815d2be6150f1aa550c`（`fix(diagnostics): 保留飞光分类拒绝错误码`）

## 用户症状与影响

飞光 composer 输入不存在的分类后，页面会正确保留草稿和给出修正提示，但本机诊断只留下“领域规则拒绝”，未留下稳定的安全错误域及错误码。用户主动导出的诊断包因此无法区分该校验失败与其他领域规则拒绝。

## 时间线

- `0341bccd` 为避免自由文本泄漏，只为持久化失败保留 mutation rejection 的 typed failure。
- `06464d7` 为飞光未解析分类增加 `domainValidation/821`，并在真实 E2E 中要求该码可持久化。
- 2026-08-05 完整隔离 E2E 在飞光场景判红。

## 复现与证据

完整 `scripts/test-e2e` 的飞光场景在隔离 `e2e` profile 失败，结果为“未解析分类未被持久记录”。失败后的结构化证据环包含 `mutationRejected`、`idea` 与 `domainRule`，但缺少 `failure` 字段；这证明 UI 校验、录制器落盘及事件筛选均已运行，只有安全错误码在共享入口被舍弃。

## 排除的假设

- 排除 `IdeaDraftClassificationError` 类型擦除：共享入口收到的 `Error` 可由现有 mapper 转换为白名单 `DiagnosticFailure`。
- 排除 recorder 编码或 snapshot 过滤：原始 NDJSON 已含同一 mutation rejection 事件，只缺共享入口未提供的字段。
- 排除 UI 未触发校验：真实页面保持草稿并显示本地校验失败态。

## 根因与破坏机制

`recordOperationFailureEvidence` 只在 `EnginePersistenceCommitError` 时把 `diagnosticFailure(for:)` 传给 `mutationRejected`。该限制错误地把“安全 typed failure”与“持久化 failure”视为同义，丢弃了飞光领域校验已提供的 `domainValidation/821`。

## 根因修复

共享 mutation rejection 边界现让每个错误都经既有白名单 mapper 生成并保存 `DiagnosticFailure`；不传递原始 Error、描述、userInfo 或业务文本。

## 验证结果

fast contract、聚焦真实飞光 E2E、完整 `scripts/test-e2e` 与 `make check` 均通过；真实路径验证 `domainValidation/821` 已持久化，完整 E2E 审计清单为 `suite_exit_status=0`。修复提交如上。

## 永久门禁

- fast：`scripts/test-mutation-rejection-diagnostic-failure-contract`
- symptom：`scripts/test-e2e`

## 发行与回滚

完整真实 E2E 未转绿前不推送。若需回滚，回退修复提交即可恢复旧记录形状；业务资料、同步资料与诊断根均不迁移。

## 教训与永久约束

诊断事件的 failure 字段只能承载白名单化的 `DiagnosticFailure`；是否记录应由 mapper 的隐私边界决定，不能按某一个业务错误类别临时裁剪。

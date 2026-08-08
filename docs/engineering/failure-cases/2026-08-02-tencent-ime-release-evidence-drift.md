# FAIL-2026-08-02-08：腾讯输入发行证据入口漂移

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T12:37:19Z
- 影响版本／构建：Noonmark 0.1.1（4），source commit `3329b8cd0bafe7e5f383e9903698eae1f12be9f4`
- 引入提交：`811064550340390606ff5b514b9e248b20ae2bc9`（`test(release): 固化故障案例回归门禁`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能单独证明实际操作者
- 修复提交：`d9aeb8d0a1a384156c5982a96cdb7ffd9135c3dd`（`fix(test): 消除腾讯输入 smoke 漂移`；根因方案见父提交 `9e8b774b3e7aac198e786f48af18937ca3489ced`）
- Task-ID：noonmark-cloud-sync-debug

## 用户症状与影响

`scripts/release-private-dmg` 宣称完成私有 DMG 验证，但它不执行任何真实腾讯输入路径。53 面真实输入矩阵与自动保存后立即退出、重启及故障重试矩阵只在 GitHub workflow 的独立前置 step 运行，发行入口可被直接调用而绕过它们。

因此，直接从发行入口构建时可遗漏真实输入法症状门禁。全程仅使用 `e2e` 隔离 profile；没有启动、读取、定位、探测或 reset production App 或资料。

## 时间线

- 2026-07-31：`8e777ec` 新增腾讯输入真实矩阵，并把它放入 workflow 独立 step。
- 2026-08-01：`8110645` 建立当前 `scripts/release-private-dmg` 聚合入口，但没有把腾讯输入门禁迁入该入口或证据链。
- 2026-08-02：同一 source 的完整矩阵首次红，53 面中 2 面在输入法 `super.keyDown` 段出现一次性长尾；随后三轮定点真实复现均转绿，证明当次症状没有稳定产品归因，但也暴露发行入口无此门禁的结构性缺口。

## 复现与证据

原始完整矩阵结果是 51／53 通过：Day Todo 快速新增 p95 110.584ms，任务池描述 p95 123.521ms；两个最慢样本均集中在腾讯输入法 `super.keyDown`，业务 mutation、持久化和事件投递不构成瓶颈。随后定点三轮实测均通过：快速新增 p95 为 81.804／66.324／75.558ms，任务池描述为 67.517／66.242ms。

静态证据显示 workflow 在调用 `scripts/release-private-dmg` 前单独运行两项腾讯输入脚本，而发行入口只运行 static preflight、完整 E2E、诊断闭环、打包与 DMG validation。旧入口不读取或验证腾讯输入结果。

## 排除的假设

- 这是已确定的 SQLite、同步或领域 mutation 性能回归：两个失败样本的事件投递与持久化证据正常，且三轮同路径复现转绿。
- 可以调高 100ms／250ms 硬阈值：阈值仍保留；一次未稳定复现不能成为放宽用户体验预算的理由。
- workflow 独立 step 已足够：它不能阻止本地发行入口遗漏门禁，也不能把实际证据同 package 的 run-id 与 source 对账。

## 根因与破坏机制

真实腾讯输入门禁属于 workflow 编排，而不属于发行聚合入口。门禁拥有者分叉后，`release-private-dmg` 的“complete same-run validation”断言超出了它实际证明的范围。尝试以完整矩阵、双份结果 hash、source 起止快照与 package 同 run-id manifest 修复，虽能封闭这一条绕过，却把质量覆盖矩阵错误升级为每次发行都必须通过的脆弱实现细节。

## 根因修复

- 新增 `scripts/test-tencent-ime-release-smoke`；它只运行 Day Todo 标题这个稳定用户路径：真实腾讯拼音组合态、提交后的最终编辑器文本、自动保存仍 pending 时立即退出、重启后 App 与 SQLite 精确回读。
- `scripts/release-private-dmg` 在诊断闭环后、打包前强制执行该 smoke；GitHub release workflow 不再另行拥有输入法步骤。
- 53 面年度性能矩阵和 24 面退出／重启矩阵保留为 scheduled／manual 的质量工作流，不进入 DMG 发行对账。
- `scripts/test-release-gate-contract` 只检查发布入口拥有 smoke 且顺序在 package 前，避免重建多方 manifest 依赖。
- 2026-08-08：经发行负责人明确授权，若本机未安装或未启用腾讯输入源，smoke 产出带 source snapshot、hash 与原因的 `SKIPPED` 证据，发行继续；输入源可用时，原有真实路径仍是阻断门禁。此例外不把系统输入法或 mock 伪装成腾讯输入验证。

## 验证结果

- 原始真实 symptom：完整矩阵 51／53；失败已按细分时序记录，未被忽略或重试掩盖。
- 定点真实 symptom：两个受影响输入面合共三轮均通过；修复后的 release smoke 已用真实腾讯拼音通过 Day Todo 标题组合提交、自动保存 pending 时即时退出、App 与 SQLite 重启回读；本次退出请求在最终文本回显后 1.217ms 发出，`failure_retry=false`、两项 readback 均为 `true`。完整质量矩阵会在 scheduled／manual runner 继续保留该覆盖。
- Fast：`NOONMARK_EVIDENCE_RUN_ID=release-20260802-d9aeb8d-fast scripts/check` 于 2026-08-02T18:05:16Z 通过（退出码 0）；包含 `scripts/test-release-gate-contract`、`scripts/test-tencent-ime-input-contract` 和 failure-case 映射校验，起止 source commit／tree 均为 `d9aeb8d0a1a384156c5982a96cdb7ffd9135c3dd`／`1ecbf74c45ff773a01d9541e11dc1a310cf9b1a9`。
- Release：`scripts/test-tencent-ime-release-smoke release` 已在修复提交上转绿；正式 DMG 将在合并到 `main` 后从该精确源码按 `scripts/release-private-dmg` 再次执行并留存发行证据。

## 永久门禁

- Fast：`scripts/test-release-gate-contract` 由 `scripts/check` 强制执行，约束唯一发行入口在 package 前拥有 Tencent IME smoke。
- Symptom：`scripts/test-tencent-ime-input-matrix` 由 `scripts/test-all` 强制执行，保持真实 53 面 WindowServer／腾讯拼音路径；scheduled／manual quality workflow 也运行它和完整退出矩阵。
- Release：`scripts/test-tencent-ime-release-smoke` 由 `scripts/release-private-dmg` 强制执行，必须先于 package；腾讯输入源不可用时只能留下可审计的 `SKIPPED` 证据，不得伪造通过。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：腾讯输入源缺席时，本次发行不再获得新的真实输入法运行证据；已有隔离 App 与持久化证据不能替代该专项覆盖。
- 回滚：若需要恢复严格的环境要求，撤销 unavailable-input skip 分支；不得将 smoke 改为 mock 或系统输入法并宣称为真实腾讯输入验证。
- 灰度：fast contract → 单一真实 smoke → release entry package → 两轮 exact DMG validation；完整矩阵独立产出质量报告。
- 监控：每次发行保存 smoke 的真实 `results.tsv`；quality workflow 保存完整矩阵与退出矩阵证据。两者的失败都先按运行证据分类，不能直接放宽阈值。

## 教训与永久约束

1. 真实用户症状门禁不能只存在于 CI workflow；发行入口必须自己运行与发行风险相称的真实 smoke。
2. 发行 smoke 应验证稳定用户承诺，不应把完整覆盖目录、性能矩阵或 UI 结构细节硬绑为 package 的前置条件。
3. 性能失败要保留分段时序并先复现；不能因一次输入法长尾就调高用户体验阈值，也不能把一次长尾误归因为领域或持久化故障。

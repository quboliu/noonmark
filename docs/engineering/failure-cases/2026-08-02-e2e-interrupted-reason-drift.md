# FAIL-2026-08-02-01：E2E 重启恢复原因判定漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T05:40:03Z 前；同一任务中的第一轮失败产物已被第二轮确定性复现覆盖
- 影响版本／构建：0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 的隔离 `e2e` 诊断故障闭环
- 引入提交：`d1b3c9a835633e381d7d5d0410820db041cbf640`（`feat(diagnostics): 闭合真实故障证据导出链路`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：待回填

## 用户症状与影响

隔离 E2E 已完成同步失败、repository lock wait、任务修改拒绝与异常终止；重新启动后，诊断 capsule、`previousSessionInterrupted`、`mutationRejected` 和 `persistedSyncFailureLoaded` 均已持久化，但自动化在十秒内始终报告 `restart evidence did not converge`，因此无法继续通过真实 Help 菜单导出诊断包，发行闭环被阻断。

故障位于 `e2e` 专用判定器，不是 production runtime 的同步恢复回归。验证没有启动、读取、定位或 reset production identity 与资料。

## 时间线

- `d1b3c9a` 首次加入三进程诊断故障闭环，并把所有失败状态硬编码为 `transportOrStorage`。
- 2026-08-02：在补齐 diagnostic scope 唯一 producer 后，运行真实隔离闭环首次暴露重启超时。
- 同一任务再次从 reset 后完整运行，得到完全相同的重启失败；排除偶发时序。
- SQLite、typed diagnostics 与源码对账证明恢复状态正确为 `operationInterrupted`，而判定器仍要求 `transportOrStorage`。

## 复现与证据

连续两次运行：

```bash
NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 scripts/test-e2e debug
```

两轮均在 restart 阶段以非零状态退出。第二轮的最小证据：

- `artifacts/e2e-diagnostic-closure/restart-result.txt`：`failed: restart evidence did not converge`。
- `artifacts/e2e-diagnostic-closure/Noonmark.sqlite` 的 `localFirst.sync.lastStatus`：失败原因 `operationInterrupted`，operation／incident 与被中断操作及修改拒绝事件完全一致。
- typed diagnostics 同时包含原失败 capsule、`transportLockWait` 阶段的 interrupted capsule、修改拒绝、previous-session interruption 与精确关联的 persisted-failure-loaded 事件。
- `diagnostic-export-scope.stderr` 为空，scope manifest 中的 database 与 repository lock 均为隔离 E2E canonical path。

## 排除的假设

- 排除恢复证据尚未 flush：重启后的 typed snapshot 已包含全部五类必需证据及精确 operation／incident 关联。
- 排除 notice 未恢复：源码按持久化 correlation 恢复 notice；待原因判定修正后由同一真实路径继续验证。
- 排除 scope path 漂移：同一签名 helper 产生的严格九行 manifest 与实际 SQLite／repository 路径一致，stderr 为空。
- 排除偶发 polling 时序：两次 reset 后真实闭环均在相同阶段、相同十秒边界失败。

## 根因与破坏机制

`persistedFailureCorrelation` 无条件要求 `.transportOrStorage`。seed 阶段的无效同步目录确实产生该原因；但异常终止后的恢复逻辑会有意调用 `persistInterruptedSyncFailureIfNewer`，把最新失败持久化为 `.operationInterrupted`。判定器复用了 seed 的原因假设，所以即使所有重启证据与 correlation 已经正确落盘，也永远返回 `nil` 并等待至超时。

既有 Storage 测试正确覆盖 `operationInterrupted`，但 E2E fast contract 没有约束每个阶段期待的失败原因，真实症状路径也未在发行入口中单独强制执行，因此错误假设未被提前拦截。

## 根因修复

持久化 correlation reader 现在显式接收 expected reason：seed 的两次读取固定 `.transportOrStorage`，restart 固定 `.operationInterrupted`。两个原因没有被全局视为等价，因此错误阶段或错误恢复状态仍会 fail-closed。

## 验证结果

- 症状红：隔离真实 E2E 从 reset 后连续两次在 restart convergence 判红。
- Fast 红：阶段特定原因 contract 在实现修改前判红。
- Fast 绿：`scripts/test-e2e-evidence-contract` 已验证 seed 两次读取、restart 一次读取及 reader 的 exact reason equality。
- 症状绿：修复后 `NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 scripts/test-e2e debug` 连续三轮完成失败、锁等待、修改拒绝、SIGKILL、重启、Help 菜单导出与持久化对账。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 从 fresh `e2e` reset 后完成未过滤的 `scripts/test-e2e`；诊断闭环在完整套件中再次走完失败、锁等待、修改拒绝、SIGKILL、重启、Help 菜单导出与持久化对账，suite exit status 为 0。
- Release 配置绿：同一 targeted closure 以 `scripts/test-e2e release` 完成一次；随后 pre-commit review 证明不得在主工作树直接重跑，否则会把 full E2E manifest 改成 only mode。
- Release：待 clean repair commit 的正式发行门禁回填。
- 修复 commit：待回填。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，分别约束 seed 与 restart 的 exact expected reason，并拒绝无阶段参数的读取。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行真实失败、锁等待、修改拒绝、SIGKILL、重启、Help 菜单导出和持久化对账。
- Release：`scripts/test-release-diagnostic-closure` 从 clean HEAD 建立仓库父目录内的临时 detached worktree，运行 targeted closure 并归档独立证据；`scripts/release-private-dmg` 强制调用该入口，不覆盖主工作树的 full E2E evidence。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

在 targeted E2E、fast contract 与同一 DMG 的两轮真实门禁全部转绿前不得发行。修复只改变 E2E 判定器与门禁，不改 production runtime 或资料 schema；若出现新回归，回滚该修复提交并保留发行阻断，不得放宽 expected reason 或跳过重启证据。

## 教训与永久约束

- 同一个状态 reader 服务不同生命周期阶段时，阶段语义必须成为显式输入，不能藏在 helper 内部。
- “有失败 correlation”不等于“失败原因正确”；诊断闭环要同时对账原因、operation、incident、阶段与 outcome。
- 真实症状门禁应覆盖重启后的语义转换，单测各自通过不能证明跨进程状态机闭合。

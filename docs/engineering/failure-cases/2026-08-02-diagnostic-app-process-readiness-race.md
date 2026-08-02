# FAIL-2026-08-02-06：诊断闭环 App 进程身份缺少就绪握手

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02（本轮 targeted diagnostic closure）
- 影响版本／构建：Noonmark 0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 已包含引入提交
- 引入提交：`d1b3c9a835633e381d7d5d0410820db041cbf640`（`feat(diagnostics): 闭合真实故障证据导出链路`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`（`fix(e2e): 收紧原生交互与发行证据协议`）

## 用户症状与影响

`NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1` 在建立 seed failure 前立即报告 `diagnostic seed App identity did not match its exact launch`。App log、result、SQLite 与 state 尚未建立，发行诊断闭环被前置门禁阻断。

这不是 production App、同步算法或用户资料故障。失败位于 `scripts/test-e2e` 对直接启动的 `app.noonmark.mac.e2e` 子进程做身份确认的时点；没有启动、读取、定位或 reset production identity 与资料。

## 时间线

- 2026-08-01 06:41 -04:00：`d1b3c9a` 建立 seed／stall／restart 三次直接 App 启动，并在每次 `$!` 返回后立即单次读取 `ps command`。
- 2026-08-02：targeted closure 在 seed 的第一次单次 identity snapshot 判红，未建立任何业务 result。
- 2026-08-02：同一 targeted closure 加 shell trace 后三次 exact PID／argv 均匹配并完整通过；trace 只改变调度时序，证明单轮失败不能归因于固定 argv 错误。
- 2026-08-02：1,000 次普通 `/bin/sleep` 受控 `$!`／`ps` 探针均匹配，因此没有把一般 fork／exec 必然竞态当作已证实事实；结论只限于诊断闭环缺少显式 ready handshake。
- 2026-08-02：静态枚举显示 repository lock holder 先发布 owner-only ready、外部 Helper 先发布 ledger process record；只有 seed／stall／restart 三个 App launch 仍用单次 snapshot。
- 2026-08-02：新增 exact process identity wait，连续三轮 targeted closure 全部通过三次启动及后续真实导出。

## 复现与证据

症状命令：

```bash
NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 \
NOONMARK_EVIDENCE_RUN_ID=local-20260802-diagnostic-closure-red-1 \
scripts/test-e2e
```

- 失败发生在 seed `$!` 后的第一条 identity assertion；`seed-app.log` 为空，result／state 均未建立。
- trace 复跑取得三次实际 command line，均最终绑定 exact executable、mode、launch token、database 与 sync root，并完成整个闭环。
- 同一脚本的 lock holder 与 Helper 已有可观察 ready artifact，进一步证明 App launch 的单次 snapshot 是孤立协议缺口。

## 排除的假设

- 固定 argv 拼写错误：trace 复跑的 seed／stall／restart exact argv 全部匹配。
- App 业务 bootstrap 稳定失败：失败轮尚未建立 result；后续同一源码连续完成 seed、stall、restart 与导出。
- 一般 macOS `$!` 后必然无法读取 executable：1,000 次受控短进程没有复现；本案不作超出运行证据的系统性归因。
- lock holder／Helper 同类缺口：两者分别有 owner-only ready 与 ledger process record，静态调用审计没有发现 launch 后立即单次判死。

## 根因与破坏机制

安全身份断言本身正确：PID 必须绑定 exact executable、mode、launch token、database 与 sync root。错误在于 consumer 把 `$!` 返回与“所有 exact argv 已成为可观察进程身份”压成同一时点，只采一帧；任一暂时不可读或尚未满足的 snapshot 都直接终止闭环，没有显式 readiness 协议，也没有记录最后观察到的 command。

删除 identity 断言会放宽安全边界；固定 sleep 只会隐藏调度差异。正确边界是：在同一子 PID 仍存活时等待原有 exact predicate 成立，参数非法立即失败，进程退出或预算结束时输出 process state 与最后 observed command 后 fail-closed。

## 根因修复

- 新增 `wait_for_diagnostic_closure_app_process_identity`，复用原 exact predicate，不改变 executable、mode、token、database 或 sync root 的任何比较。
- seed／stall／restart 三个直接 launch 都必须通过该 readiness helper；result 建立后的 stall identity 仍再次即时对账，防止运行中身份漂移。
- helper 只在同一 PID 存活时等待；无效参数立即返回 2，进程退出或 identity 始终不匹配时记录 mode、PID、process state 与 observed command 并判红。
- fast contract 要求 runner 中恰好三个 wait 调用、只保留一个 result 后的直接 identity assertion，并约束 liveness 与失败证据。

## 验证结果

- 症状红：targeted closure 在 seed result 之前判红。
- Fast 红转绿：`scripts/test-e2e-evidence-contract` 在 helper 不存在时判红；实现后通过三次调用、单次 post-result assertion、liveness 与 observed-command 契约。
- Symptom 绿：run `local-20260802-diagnostic-focused-sheet-green-1`、`-2`、`-3` 连续三轮完成 seed／stall／restart 三次 exact process identity、完整故障闭环与 UI 导出，suite exit status 均为 0。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 的未过滤完整 E2E 再次通过 seed／stall／restart 三次 exact process identity readiness、post-result identity 对账及完整 UI 导出，suite exit status 为 0。
- Release：待 clean repair commit 的 clean release diagnostic closure 后回填。
- 修复 commit：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制要求 exact process identity readiness helper 覆盖三次 App launch，并拒绝 launch 后立即单帧 assertion。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行真实 seed failure、lock wait、SIGKILL、restart 与 Help 菜单导出。
- Release：`scripts/test-release-diagnostic-closure` 由 `scripts/release-private-dmg` 在 clean detached worktree 重跑同一 targeted closure，任何进程身份未 ready 都阻断发行。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：只改变 E2E shell 对隔离 App 子进程的 readiness 协议，不改变 production runtime、产品功能、schema 或 payload；主要风险是等待条件意外放宽，因此继续复用原 exact predicate。
- 回滚：若 helper 接受错误 PID／argv，回滚该 helper 并继续阻断发行；不得删除 identity 检查或改成固定 sleep。
- 灰度：fast contract → targeted closure 连续三轮 → 完整 E2E → clean release diagnostic closure → 私有 DMG 动态门禁。
- 监控：对账 PID、mode、launch token、database、sync root、process state、observed command、run ID 与 `production_app_executed=false`。

## 教训与永久约束

1. `$!` 证明子进程身份来源，不证明 exact executable／argv 已达到 consumer 可观察的 ready 状态。
2. 安全 predicate 与 readiness protocol 是两层：不能因时序问题删除 predicate，也不能用单次 snapshot 冒充 handshake。
3. 所有异步 launch consumer 必须静态枚举；已有 ready artifact 的路径与单帧路径要分开审计。

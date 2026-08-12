# FAIL-2026-08-11-14：Replication V2 压力门禁固定时钟落入锁定历史

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:00:00-04:00 至 2026-08-11T15:59:59-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 压力门禁
- 引入提交：未提交；签名 App stress 最初没有覆盖 e2e profile 的默认 fixed-clock
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

真实资料包的本机预检通过，但签名 `e2e` App 在跨领域压力阶段的任务排期被 `immutableHistory` 拒绝。若只看阶段结果，容易误判为资料导入后领域状态损坏或 V2 同步再次拒绝修改；实际同步诊断保持零失败，问题来自门禁使用了已锁定的历史自然日。

## 时间线

- 扩大真实 App 压力范围后，第一轮先揭露测试错误地在复制出的计划子任务未完成时完成父任务；按领域顺序先完成子任务后，该假设被关闭。
- 第二轮把失败收窄至 `mixed-scheduling-failed`，但当时结果没有保留安全的底层错误类别。
- 增加有界 `underlyingErrorKind` 后，第三轮稳定报告 `noonmark-immutable-history`；同步失败与 mutation rejection 仍均为 0。
- 对账运行参数发现 `e2e` profile 在未显式传参时默认固定于 `2026-07-05`，而导入资料已把该日锁定；系统当前日期与本机预检日期并不是签名 App 实际使用的自然日。
- 脚本改为从资料包只提取最大领域日期，取下一天作为本轮 fixed-clock，并让本机预检、exercise 与 restart 共用同一日期；第四轮全绿。

## 复现与证据

旧脚本以系统 `date +%F` 运行本机预检，却没有向签名 App 传入 `--e2e-fixed-instant`。因此预检以当前日期成功，App 则按 `NaturalDayEnvironmentFactory` 的 e2e 默认值运行；同一份 mutation sequence 在排期阶段抛出 `NoonmarkError.immutableHistory`。

失败 session `3b860064-413c-4cf3-8dd0-8e29ab870bdd` 的 round `a2c1f780-d462-4244-9f4c-e8c14a3a0166` 保留了 `mixed-scheduling-failed / noonmark-immutable-history` 证据。修复后 session `4e2626e3-d8cb-4400-9ef7-5b9549d4db0e` 的 round `a7575dc2-61f8-465c-966b-19614462ac08` 完成 71 次跨领域 mutation；exercise 542／542、restart 652／652 outbox confirmed，最近同步与最近有效同步均存在，诊断同步失败和修改拒绝均为 0。所有 round 永久保留。

## 排除的假设

- 不是资料包损坏：同一资料包经领域 import 与 SQLite／V2 preflight 完整通过。
- 不是 iCloud confirmation 失败：失败轮的 typed sync diagnostic 为 0，故障发生在排期 mutation 内。
- 不是系统当前日期已锁定：签名 App 使用的是 e2e fixed-clock，不是 shell 的系统日期。
- 不能跳过排期／完成覆盖：用户要求观察广泛真实领域写入，删掉失败操作会降低症状门禁强度。
- 不能解锁或改写导入历史：那会改变用户 domain facts，也会掩盖真实领域 invariant。

## 根因与破坏机制

门禁让预检与真实 App 使用两个不同的自然日 authority。脚本误以为 e2e App 会沿用系统日期，却没有把该假设变成运行参数；`NaturalDayEnvironmentFactory` 对授权 e2e profile 正确采用固定测试时钟，而默认日期恰好属于资料包中的 locked history。领域引擎因此正确拒绝排期，但门禁错误地把合法拒绝呈现为同步测试失败。

## 根因修复

压力脚本在任何 iCloud session 建立前，从资料包只提取最大 `snapshot.days[].date`，严格解析后取下一日为 `stress_natural_day`。它把同一值传给领域 preflight，并以 `--e2e-fixed-instant`、`--e2e-fixed-time-zone` 与 `--e2e-fixed-locale` 显式注入签名 App 的 exercise／restart。目标日晚于资料中的全部日记录，不需要解锁、覆盖、迁移或修改任何导入事实。

## 验证结果

- `scripts/test-replication-v2-app-stress-contract` 固定检查 preflight 与签名 App 共用 derived natural day，旧脚本稳定判红，修复后转绿。
- 相同资料包在 derived day 的独立 SQLite／V2 preflight 全绿，包含排期与完成。
- 签名 `e2e` App 真实 iCloud 压力 exercise／restart 全绿；所有 pending outbox 清零，成功时间存在，诊断失败与写入拒绝为 0。
- 没有启动、读取或修改 production；没有删除、覆盖、替换、移动、改名或清理任何 iCloud 对象。

## 永久门禁

- fast：`scripts/test-replication-v2-app-stress-contract` 固定检查测试自然日从资料边界导出，并由 `scripts/test-replication-v2-recovery-contract`、`scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 必须以同一 derived fixed-clock 运行真实资料 preflight、签名 `e2e` App、真实 append-only iCloud 与重启对账；`scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

V2 尚未发行。若回归，只撤回未发行的压力门禁 slice并保留全部已建立的 iCloud round；不得修改资料包、解锁历史、读取 production 或增加跳过排期的降级路径。案例须在修复提交回填后才可标记「已修复」。

## 教训与永久约束

测试时钟是领域 authority，不是便利参数。预检、首轮运行与重启若不共享同一显式自然日，便不是同一症状路径；凡导入含历史锁定资料的门禁，都必须先证明目标日可写，而不能拿 shell 当前日期代替 App 实际时钟。

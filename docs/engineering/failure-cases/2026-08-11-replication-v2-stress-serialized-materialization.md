# FAIL-2026-08-11-26：真实 iCloud 压力门禁串行等待 materialization

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T20:13:04-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；签名 App stress automation 初版在每个 mutation batch 后等待完整 iCloud materialization
- Git author／committer：不适用；错误改动仍在未提交工作树
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

使用调用者明确提供的当前资料包运行真实签名隔离 App 压力门禁时，App 持续占用 CPU 并执行同步，但六分钟内没有生成 exercise 结果。门禁因此报 `replication V2 stress phase did not produce its bounded result`，无法继续验证重启与第二 SQLite 收敛。它也没有真实模拟用户在同步期间连续大量修改的路径。

## 时间线

- 2026-08-11T20:06:33-04:00：签名 `e2e` App 在全新 append-only iCloud round 开始真实同步。
- 2026-08-11T20:13:04-04:00：最后一条完整 Runtime 证据仍为成功同步、一个 pending publication。
- 2026-08-11T20:13:49-04:00：外层六分钟门禁判红并按既有隔离清理规则终止本机测试 App；没有删除、覆盖或移动任何 iCloud 对象。
- 同轮取证确认 583 次 operation start／success 成对完成，14 次进入 `pending=0`，569 次保持 `pending=1`，同步失败为零。

## 复现与证据

- 复现入口：以调用者选择的当前格式资料包及有效签名 profile 运行 `scripts/test-replication-v2-real-validation`。
- `scripts/test-icloud-append-only-guard` 在访问前两次通过；测试只建立全新 session／round。
- Unified Logging 的 `app.noonmark.mac.e2e:sync` 运行产物显示 583 次 `operationStarted` 与 583 次 `operationSucceeded`，没有未返回的命令。
- 14 个批次最终各确认一条 record；下一批在确认前持续返回 `records=0 pending=1`。最后一批在外层门禁结束时仍等待 iCloud materialization。
- 源码证据显示 `exercise` 在 overlap 后及 create、edit、delete 每个 20 项 batch 后调用 `runSync`；该函数要求 pending 与 waiting 都归零才允许下一批用户修改。

## 排除的假设

- 不是资料导入死锁：导入后已进入并持续完成真实 sync operation。
- 不是同步命令挂死：583 次 start 与 success 精确成对。
- 不是 Runtime incident：所有已记录 operation 均成功，且没有 failure capsule。
- 不是用增大 timeout 就能修复的机器波动：错误调度明确把本应连续的本机 mutation 工作负载转换成多轮顺序网络确认。
- 不是 iCloud destructive 测试：append-only guard 已通过，隔离命名空间没有删除、覆盖、移动或改名能力。

## 根因与破坏机制

压力自动化混淆了“执行一次真实同步 pass”和“等待 iCloud materialization 后达到最终收敛”两个不同边界。每个 mutation batch 都调用最终收敛等待，使后续本机修改必须等上一条对象被 iCloud materialize。结果既放大网络确认总时长，也回避了产品最需要证明的场景：前一 publication 尚待确认时，用户继续大量写入、修改与删除。

## 根因修复

- 抽出 `runSyncPass`：执行真实 App 手动同步命令并等待该命令完成，但允许健康的 pending／waiting 状态继续存在。
- 每个中间 mutation batch 改用单次 pass；每次 pass 后立即检查 durable incident，失败不得被后续 workload 掩盖。
- 仅在 exercise 最终边界继续使用 `runSync`，要求 outbox 清零、waiting 清零、双水位存在且 convergence 为 `converged`。
- 保留原六分钟外层上限，不以延长 timeout 代替修复。

## 验证结果

- 修复前真实 symptom 已稳定判红；运行产物和源码共同确认串行 materialization 调度。
- fast contract 已转绿，并由 102 个案例的 failure-case mapping 校验确认进入聚合入口。
- 修正调度后的下一轮真实签名 App 不再耗尽六分钟，而是在多个 publication 同时 pending 后立即暴露 `FAIL-2026-08-11-27` 的祖先精确重试误判；本案例的最终 exercise／restart、第二 SQLite 收敛与完整回归结果仍待下轮回填。
- 修复祖先重试后，第三轮在原六分钟上限内通过：exercise 导入 1,013 项资料，完成 120 次创建、80 次修改、40 次删除与 71 次跨领域 mutation；最终 outbox 为零、双水位存在、convergence 为 `converged`、同步失败与 mutation rejection 均为零。
- 同一 round 的 restart 再完成 30 次创建、20 次修改与 10 次删除，仍为零失败、零拒绝并收敛；第二 SQLite 首次应用 14 个 publication，restart apply count 为零。
- 第二 SQLite 对账确认原有 168 个 iCloud 文件逐一保持不变，最终 inventory 只追加至 176；后续独立 live gate 的两个新 round 各有 18 个文件，mutable head count 为零。
- `scripts/test-replication-v2-real-validation` 全绿；案例仍保持「处理中」，等待修复 commit 与最终完整回归回填。

## 永久门禁

- fast：`scripts/test-replication-v2-app-stress-contract` 必须证明中间批次使用独立 sync pass、每次 pass 检查 durable incident，且完整 convergence 等待只保留在最终验证边界；由 `scripts/test-replication-v2-recovery-contract` 与 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 必须在原六分钟上限内完成当前资料导入、同步中修改、高密度增删改、真实 append-only iCloud 最终收敛、重启与第二 SQLite 精确对账；由 `scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

当前未发行，不进入 production 或公开发版。若新调度暴露 Runtime incident 或最终不能收敛，回滚整个未发行调度切片并停止发版；不得恢复逐批 materialization 串行等待，也不得延长 timeout、降低 workload 或跳过第二 SQLite 对账。灰度仅使用每轮新建且永久保留的隔离 iCloud round。

## 教训与永久约束

压力门禁必须保留用户实际并发形态。同步命令成功、publication 已 materialize、最终全局收敛是三个不同事实；中间采样只能要求前两个边界中当前需要的最小事实，最终闭环才要求完整收敛。任何把高密度用户操作变成网络确认串行队列的测试都属于失真门禁。

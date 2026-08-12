# FAIL-2026-08-11-19：批次 provenance 重算放大合并时间

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T16:05:00-04:00 至 2026-08-11T16:50:00-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；批次 provenance 初版为每个候选重建完整合并 context
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

真实签名 App 已经完成高密度导入、增删改、同步及重启，但第二份独立 SQLite 从同一个隔离 iCloud round 重建资料时，首轮 reconcile 超过两分钟，使表面状态停在「同步中」。若发行，资料量增大后新设备 bootstrap 或长期离线设备追赶会出现近似卡死；延长 timeout 只能掩盖症状，不能解决计算量随批次和候选版本相乘的问题。

## 时间线

- 真实签名 App exercise 与 restart 阶段均收敛，pending 为零，最近同步与最近有效同步均有值。
- 同一 round 的第二份独立 SQLite 在 120 秒症状预算内失败。
- 加入每轮 reconcile 的有界指标后重放保留现场：单轮耗时 `224067 ms`，已 apply 全部 19 份远端 publication，waiting 为零、incident 为 none，仅本机 baseline 因 observe 发生在漫长 merge 前而仍 pending。
- 十秒 CPU sample 的 7020／7020 个 worker samples 全部落在 `minimalLiveProvenance → prepareContext → validate／decode` 路径。
- deterministic fast fixture 在修复前耗时 `9.359 s`，超过三秒门禁；完成重构后降至 `0.065 s`，并保持相同 canonical records 与 provenance 数量。

## 复现与证据

- 真实隔离 round 含 4,015 条来源 record、19 份 announcement。第二 SQLite 一轮正确读取及 apply 19 份 publication，但 merge 本身耗时 224 秒。
- 真实 record 分布包含约 200 个有多个版本的 identity；旧实现对每个候选都过滤整个 incoming batch，再重新 validation、JSON decode、witness 汇总和 context canonicalization。
- fast fixture 固定建立 80 个任务及 40 个后续修改。修复前可稳定越过三秒并判红；修复后输出 record 数量与 provenance 数量精确相等，并在远低于预算的时间完成。
- 定位过程只读取并新增隔离测试资料；没有删除、覆盖、移动或改名任何 iCloud 项目，也没有触碰 production identity 或资料。

## 排除的假设

- 不是 iCloud materialization 等待：waiting record 为零。
- 不是 fork 或领域冲突：incident 为 none，19 份 publication 全部成功 apply。
- 不是 SQLite 锁：sample 持续执行 merger 的 provenance 与 context 构建，没有停在 lock wait。
- 不是上传确认缺失：来源 App 的 pending 已归零；第二 SQLite 留下的一份 pending 是本机 baseline 尚未来得及进入下一轮 observe。
- 不能通过增加 reconcile deadline 处理：CPU 时间来自确定性的重复全批扫描，资料增长后仍会再次越过任何固定 timeout。

## 根因与破坏机制

`minimalLiveProvenance` 为每个 multi-variant identity 逐个尝试移除候选。旧路径每次尝试都从全部 existing 与 incoming records 重建 `CurrentSyncRecordMergeContext`，重复执行 validation、JSON decode、reactivation evidence 汇总，以及 day／taskChain context canonicalization。复杂度由一次批次准备退化为完整批次大小乘以候选数；真实 4,015-record batch 因约 200 个多版本 identity 产生超过 224 秒的纯 CPU 放大。

## 根因修复

- transport batch 入口一次性 validation 及 decode 每份 exact evidence，并建立 prepared context input。
- 完整 merge context 只建立一次；不消费 reactivation context 的 fold 直接复用。
- 只有状态转换可能改变授权判断的 taskChain／dayTrace 候选才从已验证、已解码 facts 重建 reduced context，不再重复 JSON decode 或 validation。
- synthetic canonical record 复用既有 prepared domain；只有真正新合成的 record 解码一次。
- 保留输入顺序、header consistency、identity collision、reactivation witness 与 provenance 的既有 fail-closed 语义。

## 验证结果

- `CurrentSyncRecordMergerTests`：23／23 通过；其中 deterministic batch 性能门禁由 `9.359 s` 红转为 `0.059–0.067 s` 绿，并已由 recovery aggregate 强制执行。
- divergence identity、三版本 synthetic provenance、reactivation witness self-authorization 等行为回归均通过。
- 新建隔离 iCloud round 的签名 App 全量 stress 通过。第二 SQLite 首轮由 `224067 ms` 降至 `43462 ms` 并应用 18 份远端 publication，下一轮 `204 ms` 收敛且 pending 为 0；重启轮 `188 ms`、remote apply 为 0。
- 领域 snapshot 与共享 preferences 精确相等，target device-local preferences 原样保留，waiting 为 0、incident 为 none。fast 与真实 symptom 均已转绿；案例仍因修复提交尚未确定而保持「处理中」。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行大型增量 canonicalization，精确核对 canonical records／provenance 数量并以三秒预算捕获全批重算；由 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 以真实签名 App 建立高密度资料，再让第二份独立 SQLite 从同一个新建 append-only iCloud round 收敛、对账 snapshot 并重启确认零重复 apply；由 `scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

当前未发行；真实 symptom 转绿前停止发版。若新算法出现语义回归，回滚整个未发行 V2 工作树，不允许以延长 timeout、跳过 provenance 或降低对账强度代替。灰度只使用全新隔离 round；监控每轮 reconcile 耗时、applied publication、waiting record、pending outbox、incident、snapshot 对账及 restart apply count。

## 教训与永久约束

同步状态机的正确性包括有界完成时间。候选 provenance 最小化不得在内层循环重做与候选无关的整批 validation、decode 或 context canonicalization；性能门禁必须同时对账结果，不能用牺牲 provenance 或授权语义换取速度。

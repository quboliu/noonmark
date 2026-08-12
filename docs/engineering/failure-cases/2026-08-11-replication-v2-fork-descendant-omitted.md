# FAIL-2026-08-11-07：Replication V2 fork evidence 遗漏分叉后的 descendant

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T10:16:46-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；最初的 deterministic fork evidence 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

问题尚未进入发行或 production。若在当前 evidence 结构上直接实现 resolved cursor，首次分叉后旧 producer 新增的 descendant 不会改变 resolution ID；Runtime 会把已经增长的远端 branch graph 错当成原来已处理的分叉，从而永久跳过晚到同步事实。

## 时间线

- 既有门禁只覆盖同一 producer／sequence 的两个不同 digest，并证明两条首分支均被保留。
- 2026-08-11T10:16:46-04:00：新增“首分支后续追加 sequence 2”症状测试；实际 evidence 仍只有 sequence 1 两条分支，新增 descendant 缺失。
- 2026-08-11T10:17:01-04:00：修正测试中“禁用 mutable head 后第二条 publish 仍应立即抛错”的错误前提；真正症状稳定判红。
- 2026-08-11T10:17:44-04:00：完整 branch graph evidence 实施后 Endpoint 测试转绿。
- 2026-08-11T10:18:28-04:00：公开 Runtime／SQLite 症状测试证明 descendant 形成第二个 durable actionable resolution。

## 复现与证据

测试在真实临时 content-addressed repository 内 exclusive-create producer A 的两个 sequence 1 publication，随后直接补入以其中一条 seal 为 predecessor 的 sequence 2 immutable publication。修复前 `read` 返回的 evidence 只有两个 sequence 1 reference；补入另一分支 descendant 后 resolution ID 仍完全相同。Runtime 因此只会重复记录旧 resolution。

## 排除的假设

- 不是 mutable head 漂移：测试明确使用 `mutableIndexPolicy.disabled`，truth 完全来自 immutable announcement。
- 不是对象缺失或损坏：descendant 的 chunk、root、seal 与 announcement 均由 production builder 生成并通过 digest 校验。
- 不是领域 merge 冲突：问题发生在任何 records apply 之前的 protocol evidence 边界。
- 不是第二条 publication 必须在 publish 时失败：禁用 mutable index 时 immutable fork artifact 可先完整落盘，read/discovery 才负责形成统一 actionable incident。

## 根因与破坏机制

`readForkEvidence` 只枚举首次发生冲突的单个 sequence 目录；`ReplicationForkEvidence` 又强制全部 branch 位于同一 sequence，并只以首层 seal digest 计算 identity。该模型能证明“发生过分叉”，却不能代表冻结时的完整 branch closure，因此没有足够事实支撑 resolved cursor 或 late-writer detection。

## 根因修复

Endpoint 从首次分叉 sequence 起枚举该 producer 的全部后续 announcement，逐个打开并验证 announcement、seal、root、chunk 与 exact predecessor。`ReplicationForkEvidence` 现在接受完整有向 branch graph：首层至少两条 publication 且共享 common prefix；后续每条 publication 必须精确引用前一 sequence 中已验证的 seal。evidence 按 sequence 与 seal digest 排序，resolution ID 覆盖全部 immutable publication references。

Runtime 继续在公开 incident 前把 exact evidence 写入 SQLite；新增 descendant 因 identity 改变而建立新的 resolution，旧 resolution 仍保留作审计事实。无领域冲突时新 resolution 随后可由独立原子 repair 流程关闭；这不改变“必须先形成新 durable identity”的门禁。

## 验证结果

- Endpoint 原始症状红测已转绿：第一条 descendant 被纳入 evidence；另一分支再增长后 resolution ID 再次改变。
- Runtime／SQLite 症状测试通过：首次 resolution 与扩展 graph resolution 同时 durable 保留；两轮各自出现 actionable incident，随后在无冲突条件下关闭并发布 exact baseline。
- 原有双分支正反发现顺序、ledger 重启恢复和 fork incident 门禁继续通过。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 graph closure 与 resolution identity 测试，由 `scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`；真实临时 SQLite 与 file endpoint 必须把 descendant 形成新的 durable incident，由 `scripts/check` 强制调用。

## 发行与回滚

当前没有 production cutover。若 graph closure 门禁失败，停止 resolved cursor、repair baseline、V1 cutover 与发行工作；回滚未发行 V2 Interface 变更，不得删除 descendant、沿用旧 resolution ID、任选较长 branch 或把晚到写入降格为普通 waiting。

## 教训与永久约束

“已检测分叉”不等于“已冻结完整证据”。任何允许跳过旧 producer 的 cursor 都必须绑定完整、可重读且对 descendant 敏感的 immutable branch graph；若 graph 改变，必须重新建立 actionable resolution。

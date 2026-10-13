# FAIL-2026-10-12-05：延期复制子任务时保留旧 position 导致新增项插队

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-10-12，Go 领域实现与原生 Swift 行为复核。
- 影响版本／构建：尚未提交、尚未发行的 Web 初始实现，开发基线 `83e9aedd6003632b26b26b80808e132e1187ebc5`。
- 引入提交：不存在；错误产生于本轮未提交工作区，基线尚无该 Go 实现。
- Git author／committer：引入故障时尚无对应 Git identity。
- 实际修改者：Codex `domain_store` agent 编写复制子任务路径时保留旧 position，可由当前会话和源码创建记录确认；人类操作者身份未知。
- 修复提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`

## 用户症状与影响

任务有三项子任务，完成前两项后延期第三项。继承到新日轨迹的子任务仍为 position 3，而随后新建的子任务使用当前数量加一，得到 position 2。因此新增项被排在继承项之前，破坏普通追加操作的预期顺序。

## 时间线

1. Go 通过复制原子任务结构建立继承项，保留了旧 position。
2. 对照 Swift `copyOpenSubtasks`，发现原生按过滤后的顺序重新从 1 编号。
3. 真实 SQLite 回归重放三项子任务、完成前两项、延期、再新增；报告 `carryover subtask position=3 want=1`。
4. 对被复制的活动项重新连续编号，原始回归转绿。

## 复现与证据

`TestCarryoverReindexesRemainingSubtasksBeforeNewOnes` 全部使用普通 `Execute`，最终从真实 SQLite snapshot 读取目标子任务。原生参考为 `Sources/NoonmarkCore/NoonmarkEngine.swift` 的 `copyOpenSubtasks`：过滤未完成项后使用 `enumerated()` 的 `index + 1`。

## 排除的假设

- 原始子任务顺序正确，错误出现在跨日复制阶段。
- 不是浏览器排序规则差异：持久化结果本身已是继承项 3、新增项 2。
- 稳定 lineage ID 仍被保留；故障不涉及丢失子任务内容或删除历史完成项。

## 根因与破坏机制

完成项被过滤后，剩余项的位置空间没有重新压缩。后续追加按目标集合大小分配 position，因而可能与旧空洞发生冲突或排到继承项之前。

## 根因修复

复制时只对实际继承的未完成项递增目标 position，保持原有相对顺序、lineage 与来源关系。延期和延续共享该实现，原日期事实不改写。

## 验证结果

原始继承项 position 从错误的 3 改为 1，随后新建项为 2；延期、延续、历史、进度及完整 race 回归通过，一年故事使用同一真实命令路径。

上述修复已进入首个实现提交；完整运行证据见[预览验证记录](../../tasks/noonmark-web-self-hosted/verification.md)。

## 永久门禁

`scripts/web/test-domain-boundary` 运行真实 SQLite 复制与追加顺序测试，纳入 `scripts/web/check` 与顶层 `make check`。该集成运行同时满足 fast 和 symptom，登记如实指向同一实际证据。

## 发行与回滚

错误实现未发行；fixture 在新外置 run 重建。不得通过前端特别排序掩盖错误 position；根因修复保留在共享领域复制路径。

## 教训与永久约束

过滤后复制的有序子集合必须明确目标序号规则。保留身份和来源不等于沿用原列表位置；后续追加动作必须纳入同一回归故事。

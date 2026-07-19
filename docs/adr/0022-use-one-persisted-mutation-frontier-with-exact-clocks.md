# 使用单一持久 mutation frontier 与 exact clocks

**Status**: Accepted

晷迹的 Natural Day instant 只表达用户墙钟意图，不能单独证明一次写入晚于数据库、同步、分类或偏好中的既有事实。所有会改变持久任务事实的路径改为先从完整 Engine snapshot 计算一个单一 mutation frontier，再分配严格晚于该 frontier 的 exact `Date`；同一事务的领域事实、SQLite snapshot 与 sync journal 共用这个 instant，避免墙钟回拨、固定 E2E 时钟和模块私有时钟造成因果倒退。

## Decision

- `NoonmarkEngine.nextMutationDate(reference:)` 是任务事实的唯一 mutation clock 分配 seam。frontier 覆盖 Day、任务链及附言、任务定义及 planned subtask、日轨迹及附言、子任务、分类 identity／关系／历史／commit，以及 theme／language preference version。所有输入必须是 finite；若 reference 不晚于 frontier，使用 `frontier.nextUp`，无法再前进时 fail-closed。
- Store 每次写操作只分配一个 `StoreMutationMoment`。mutation 在 snapshot 建立的候选 Engine 中完成，持久化成功后才发布内存状态；该 moment 同时进入领域字段和 SQLite change journal，不允许分类、undo／redo、rollover、同步或导入另行使用 `Date()`、固定毫秒增量或第二套局部 clock。
- 子任务所有内容变化以 `updatedAt` 为 canonical LWW clock；theme／language 以 `themeLanguageUpdatedAt` 加 writer identity 形成一致性边界。本机专属 preference 不得推进可同步 preference clock。
- canonical 时间以 `timeIntervalSinceReferenceDate` 的 finite `Double.bitPattern` 保存与交换。ISO-8601 或 SQLite 可读文本只作人类投影，读取时必须与 exact bits 对账，不能参与 LWW、CAS 或恢复身份判断。
- snapshot undo 仍是前向 mutation。它先在 staging Engine 完成隐藏取消事实、恢复与完整性验证，全部成功后才 adopt；任何 clock 或完整性错误必须让 receiver bit-for-bit 保持不变。

## Considered Options

- 直接使用墙钟：无法处理时钟回拨、固定测试时钟或已同步的未来事实。
- 每个模块自行增加固定毫秒：精度与顺序不可靠，也会让同一事务的 journal 早于实体事实。
- 只扫描常见实体：遗漏分类、附言或 preference frontier 后仍会产生合法代码写出因果倒退事实。

## Consequences

- 同一次用户操作在 Core、Storage 与 Sync 只有一个可审计时间身份；wall-clock intent 仍保留，但不会破坏持久因果顺序。
- 新增持久事实类型时，必须明确加入 frontier 或证明它不可变；静默遗漏属于完整性缺陷。
- `nextUp` 只保证严格顺序，不宣称物理耗时或跨设备全局时间。跨设备并发仍由 canonical record、writer identity、拓扑约束和冲突证据处理。

## Risk And Rollout

- 风险等级：P。错误 frontier 会让较新事实被旧副本覆盖，或让正常写入永久阻断；exact-date schema 若只升级一半，会造成内存、SQLite 与 wire payload 不一致。
- 灰度：本轮仅在专用分支启用；先通过 Core clock／undo exception-safety、Storage exact bit round-trip、Sync permutation 与真实固定时钟 App 路径，再进入完整 E2E、`make check` 和最新 DMG 安装验收。项目尚未发布，继续按 clean cut 重建开发数据，不增加旧 schema 迁移。
- 监控：测试与 E2E 对账实体 clock、journal `changedAt`、SQLite exact bits 和重启结果；console 中任何 `content mutation time cannot move backwards`、non-finite frontier、journal clock mismatch 或 snapshot integrity failure 都是阻断信号。
- 回滚：只能整体 revert mutation allocator、调用点、exact persistence 与相关 schema，并执行 `scripts/reset-dev-data`。不得恢复模块私有 clock、只移除 finite 检查，或让新旧 date 编码并存。

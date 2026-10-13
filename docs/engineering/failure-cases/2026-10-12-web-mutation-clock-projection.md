# FAIL-2026-10-12-03：Web 将原始墙钟写入领域 mutation 时间

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-10-12，Web 首次实现的独立源码复核及真实 SQLite 回归测试。
- 影响版本／构建：尚未提交、尚未发行的 Web 初始实现；开发基线为 `83e9aedd6003632b26b26b80808e132e1187ebc5`。
- 引入提交：不存在。错误代码产生于本次未提交工作区；上述基线尚不含 Go 领域引擎，不能将故障归因给该基线提交。
- Git author／committer：故障改动尚无 Git author／committer 记录；基线身份不等于实际修改者。
- 实际修改者：本次协作的 Codex `domain_store` agent，依据当前 agent 会话及 `engine.go` 创建记录确认；操作者的人类身份未知。
- 修复提交：待回填。

## 用户症状与影响

服务时钟回拨后，任务的完成时间可能早于其创建时间；飞光的编辑、精选和删除时间也可能倒退。`mutation_bits` 仍递增，因此只检查 exact frontier 的旧测试会错误判绿。年度演示在恢复真实时钟后也可能触发相同显示异常。

影响范围为 Web 的共享领域时间 stamp 及其派生的完成、结算、精选和删除字段；原生 Mac 代码没有修改。未发现正式用户实例受影响。

## 时间线

1. 初始 Go 实现调用 `NextMutation` 得到 exact bits，同时仍用原始 `now` 构造 `CreatedAt` 与 `UpdatedAt`。
2. 独立复核对照原生 `StoreMutationMoment` 与 ADR-0022，发现领域字段没有使用已分配 instant。
3. 新增真实 SQLite 测试，创建任务后回拨一小时，再经普通 `Execute` 完成任务；测试报错 `allocated completion timestamp precedes task creation after wall-clock rollback`。
4. 将共享 stamp 改为由 exact bits 投影，补充恢复读取与投影一致性检查，相关回归转绿。

## 复现与证据

- `services/noonmark/internal/store/store_test.go` 的 `TestFactTimestampsFollowAllocatedClockAfterRollback` 使用真实 SQLite，按创建任务／飞光、回拨一小时、完成、编辑、精选、删除、关闭、重新打开的顺序验证持久事实。
- 修复前上述测试失败，原因是完成时刻早于创建时刻；不是前端格式化差异。
- 原生 `App/NoonmarkMacApp/NoonmarkStore+NaturalDayPersistenceImport.swift` 从 `candidate.nextMutationDate(reference:)` 构造 `StoreMutationMoment.instant`；领域 mutation 接收这个 instant。
- 原生 `Sources/NoonmarkMacRuntime/DayRolloverCoordinator.swift` 同样将分配的 mutation instant 传给日结及持久化。

## 排除的假设

- 不是 SQLite 事务或重启丢写：错误值已经由 Go 核心计算，并由同一事务正常保存。
- 不是 exact frontier 未推进：旧测试证明 bits 递增，但遗漏了领域可读时间字段。
- 不是浏览器时区转换：回归直接解析服务端持久的 UTC RFC 3339 值，即可观察倒退。

## 根因与破坏机制

同一 mutation 同时持有两套时间：exact bits 来自 `NextMutation`，而 `Stamp.CreatedAt`／`UpdatedAt` 来自原始墙钟。完成、结算、精选与删除时间复用后者，使领域可读时间脱离 canonical identity。原来的校验只确认可解析，没有对账文本投影与 exact bits。

## 根因修复

- 增加 `MutationTime(bits)`，将有限 reference-date Double 投影为有范围检查的 RFC 3339 时间；UInt64 bits 始终保留为精确身份。
- 核心共享 stamp 完全采用分配后的 instant，全部 mutation 时间字段沿用同一 stamp。
- 自然日仍从 owner 时区下的原始墙钟计算，不因 monotone instant 向前推进而改变日结所属日期。
- 校验要求 `UpdatedAt` 与 exact bits 投影一致，创建时间不得晚于更新时间；损坏投影在 Doctor／Open 时 fail-closed。
- 演示通过内部初始化 seam 为尚无领域事实的空实例设置历史起点，不修改已有业务事实；最后一天使用真实捕获的 anchor，避免虚构未来的正午创建时间。

## 验证结果

共享 allocator、projection round-trip、时间范围、真实 SQLite 回拨及关闭重开测试已通过；原始症状由红转绿。提交身份及最终全集结果尚待本次任务闭环回填，因此维持「处理中」。

## 永久门禁

- fast：`scripts/web/test-clock`，执行 exact allocator、共享 stamp、投影 round-trip 及范围检查。
- symptom：`scripts/web/test-clock-storage`，执行普通领域命令、真实 SQLite 回拨、关闭重开及损坏投影拒绝读取。
- 两项入口均须由 `scripts/web/check` 强制调用，并登记于 `gates.tsv`；fast 同时进入顶层 `make check` 的 Web 路径。

## 发行与回滚

尚未发行，不对外发布错误构建。开发／测试通过新外置 run 重建 fixture，不改写或清理用户正式实例。需要回滚时应整体撤销 allocator 投影、校验与对应 fixture 初始化变更，不能只关闭校验以接受两套时间。

## 教训与永久约束

精确时钟门禁必须同时验证 canonical bits、领域时间字段及持久读取。只证明序列递增不能证明领域记录的时间正确；自然日意图与 mutation instant 必须分开建模，再明确每个字段属于哪一种。

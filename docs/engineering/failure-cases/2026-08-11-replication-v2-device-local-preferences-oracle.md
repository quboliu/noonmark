# FAIL-2026-08-11-20：跨设备对账误把本机设置当同步资料

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T16:58:00-04:00 至 2026-08-11T17:08:00-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 症状门禁
- 引入提交：未提交；第二 SQLite stress 初版直接比较完整 `NoonmarkSnapshot`
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

真实签名 App 的高密度增删改、同步与重启均成功，第二份 SQLite 也在真实 iCloud round 收敛并做到 restart zero replay，但症状门禁仍报告 snapshot 不一致。若把这个错误 oracle 当成产品根因去修改同步协议，会错误地把一台设备的资料模式、备份位置、同步开关／端点和界面本机设置传播至另一台设备，造成真实功能损失。

## 时间线

- 修复 batch provenance 性能后，第二 SQLite 从 224 秒降至约 42–44 秒，并在下一轮约 200–251 毫秒收敛。
- 旧 `XCTAssertEqual` 把两份完整 snapshot 打印到失败输出，既无法行动又暴露业务正文。
- 替换为脱敏逐实体 digest／UUID 对账后，两次独立真实 round 都证明所有领域实体与分类图完全一致，唯一差异为 `preferences`。
- 源码与既有运行测试确认 preferences envelope 只承载主题、语言、版本时钟与 writer；其他字段固定保留目标设备本机值。

## 复现与证据

- 两个全新真实 append-only iCloud round 均在首次 apply 后和 restart 后得到同一个结果：days、周期、chains、definitions、traces、subtasks、分类状态与飞光零差异，只有 preferences digest 不同。
- `SyncRecordMapper` 的 `AppPreferencesEnvelope` 只编码 theme、language、updatedAt 与 writerDeviceID。
- `SyncRecordMergerTests.testPreferenceRecordPreservesDeviceLocalConfiguration` 真实运行证明远端 preferences 应用后，目标的 dataMode、backupPolicy、localFirstSyncPolicy、settingsPoemDisplayPolicy 与 syncEndpointOptions 保持不变。
- 失败现场永久保留；没有删除、覆盖、移动或改名任何 iCloud 项目。

## 排除的假设

- 不是领域资料遗漏：八类领域实体与完整分类状态逐 ID、逐内容一致。
- 不是 merge 未完成：pending 最终为零、waiting 为零、incident 为 none，重启 remote apply 为零。
- 不是 preferences publication 缺失：目标 preferences digest 稳定跨重启，差异符合 device-local 字段边界。
- 不应扩大同步范围使 oracle 转绿：这会跨设备覆盖本机资料保护、备份和同步配置。

## 根因与破坏机制

症状测试把来源 App 的完整 `NoonmarkSnapshot` 当作第二设备的 ground truth。但 `NoonmarkSnapshot.preferences` 同时包含跨设备共享主题／语言和只属于当前设备的运行配置。整值比较错误地要求第二设备复制来源设备的本机字段，与合并器既有明确契约相冲突；同时 XCTest 默认失败输出会展开完整 snapshot，形成不必要的私隐暴露。

## 根因修复

- 第二 SQLite 的期望 snapshot 以来源领域资料为基线，只把 preferences 的 device-local 字段替换为目标同步前的原值。
- 继续精确比较主题、语言、版本时钟及 writer，任何共享 preferences 丢失仍会判红。
- 继续精确比较全部领域实体与分类状态，不能以局部比较掩盖资料差异。
- snapshot 失败改为只输出实体计数、UUID、变更类别与 SHA-256 digest，不再展开用户正文。

## 验证结果

- `SyncRecordMergerTests.testPreferenceRecordPreservesDeviceLocalConfiguration` 通过，并已由 recovery aggregate 强制执行；共享主题／语言更新后，五组 device-local 字段保持原值。
- 修正后的全量签名 App stress 在全新真实 iCloud round 通过。第二 SQLite 精确取得所有领域资料与共享 preferences，同时保留同步前的 target device-local preferences；首次 apply 后与 restart 后对账均通过。
- 第二 SQLite 下一轮 `204 ms` pending 归零，重启轮 `188 ms`、remote apply 为 0；fast 与真实 symptom 均已转绿。修复提交已回填，案例标记为「已修复」。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行 preferences merge，证明共享主题／语言更新且所有 device-local 字段保留；由 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 以真实签名 App 与第二 SQLite 在新建 iCloud round 对账共享资料、目标本机 preferences 和 restart zero replay；由 `scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

当前未发行；修正后的真实 symptom 转绿前停止发版。若 oracle 仍无法表达产品边界，回滚症状测试改动并保持 V2 未发行，不得通过扩大 preferences 同步范围或删除断言放行。灰度固定使用全新隔离 round；监控共享 preferences digest、device-local preservation、pending、waiting、incident、完整领域对账及 restart apply count。

## 教训与永久约束

跨设备一致不等于整份本机 snapshot 字节相等。ground truth 必须先区分 replicated state 与 device-local state；对账既要证明共享资料精确一致，也要证明本机配置没有被远端覆盖。

# FAIL-2026-08-11-18：上传确认重试放大永久 staging 证据

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T00:00:00-04:00 至 2026-08-11T16:50:00-04:00（精确起点未保留）
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；append-only publisher 初版在幂等判断前建立永久 staging
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

真实 iCloud 双资料库同步与重启都已收敛，但每个全新 round 的来源证据从协议预期的 10 份增长至 70 份。若直接发行，等待 Apple 上传确认期间的正常幂等 retry 会持续制造不可删除的完整 staging 文件；同步正确性短期不受影响，但 iCloud 空间与枚举成本会随重试次数无界增长。

## 时间线

- append-only stage／hard-link 架构通过本机中断测试及真实 iCloud hard-link capability probe。
- 新的真实 iCloud 双 round symptom gate 同时证明两份 SQLite 收敛、重启零重复 apply、零 mutable head，但以 `sourceEvidence=70` 对预期 `10` 判红。
- inventory 显示最终对象正确且未被覆盖；超额项目全部是完整、唯一、永久保留的 staging 文件。
- 检查 Runtime 时序后确认，Apple `isUploaded` 尚未成立期间会重试同一 sealed publication；publisher 每次先建立 stage，之后才从最终键的 `EEXIST` 得知这是幂等 retry。

## 复现与证据

- 真实 iCloud symptom：连续两个全新隔离 round 都稳定复现来源证据 `70`、预期 `10`；两轮最终 repository evidence 都为 `114`，领域资料仍精确收敛。
- 本机最小复现：同一个 sealed publication 连续调用 `publish` 两次。修复前第二次调用会为每个已存在的最终对象再建立一个永久 stage；修复后 staging inventory 完全不变。
- 所有失败现场永久保留；复现与定位过程没有删除、覆盖、移动或改名任何 iCloud 项目。

## 排除的假设

- 不是 Apple 重复生成下载 placeholder：增加的是本端 publisher 命名的 UUID staging regular file。
- 不是双资料库互相回声导致资料重复：第二 SQLite 与来源 snapshot 精确相等，restart apply 为 0。
- 不是最终键碰撞或 fork：相同 sequence／digest 的最终 bytes exact，读取状态稳定。
- 不能通过清理 staging 处理：任何 iCloud 项目均不得删除，且清理不能消除未来 retry 的放大机制。

## 根因与破坏机制

初版 `AppendOnlyFilePublisher.publish` 总是先创建并持久化唯一 stage，再尝试 `linkat` 最终键。最终键已经存在且 bytes exact 的正常 retry 因此仍会留下一个新的永久 stage。append-only 约束让每个 stage 都必须保留，所以本来应为纯读取判断的幂等路径变成了永久空间放大器。

## 根因修复

- 打开经过 descriptor 验证的最终目录后，先以 `openat(O_NOFOLLOW)` 读取最终键；存在且 bytes exact 时立即返回 `alreadyPresent`，不建立 staging。
- 最终键存在但 bytes 不同、不是 regular file 或读取失败时继续 fail-closed，绝不覆盖。
- 只有最终键不存在时才创建唯一 stage。并发首发仍允许各自建立 stage，最终只由一个不覆盖 `linkat` 建立最终键；失败方只接受 exact bytes。
- 新增精确重试门禁，直接对账第一次与第二次 publish 前后的 staging URL 集合。

## 验证结果

- 本机精确 retry 测试通过；第二次 publish 前后的永久 staging URL 集合完全相同。`scripts/test-replication-v2-recovery-contract` 已包含并通过该门禁。
- 修正后的真实 iCloud session 以两个全新 round 通过：每轮 repository file count 均为 18、零 mutable head，双 SQLite 收敛、重启 remote apply 为 0，后轮没有改变前轮 inventory 或 digest。
- 全量签名 App stress 也已通过；来源 App 两阶段共完成 417 次真实 reconcile、652 份 confirmed outbox，pending 均为 0。第二 SQLite 精确收敛并重启零 replay，进入第二消费者前的 198 个文件全部保持原 digest。
- fast 与真实 symptom 均已转绿；案例仍因修复提交尚未确定而保持「处理中」。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定运行精确 publication retry，并要求第二次 publish 不新增任何永久 stage；由 `scripts/check` 强制调用。
- symptom：`scripts/test-icloud-append-only-symptom` 在两个全新真实 iCloud round 精确限制来源证据为协议所需数量，并同时验证双 SQLite 收敛与旧 round inventory／digest 不变；由显式 `scripts/test-icloud-sync-live` 强制调用。

## 发行与回滚

当前未发行。真实 symptom 转绿前停止发版。回滚只能回到未启用 Replication V2 的未发行基线，不能恢复 direct-final write、删除 staging 或 mutable head。灰度固定使用全新隔离 round；监控 source evidence count、final evidence count、pending outbox、confirmed publication 与 restart apply count。

## 教训与永久约束

append-only 系统的重试成本本身是正确性约束。幂等不能只保证最终结果相同，还必须保证已完成请求的 retry 不新增永久证据；否则没有删除能力的设计会把普通网络等待转化为无界空间增长。

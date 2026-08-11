# FAIL-2026-08-11-01：已确认本机基线未推进 frontier，导致同步反复回读

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:27:44+08:00
- 影响版本／构建：v0.2.6，build 28，source commit `12ed27bf5d43077744a65c932703f2051f6d4ca4`
- 引入提交：`1f264ff9c38047c8ac959e9d0cd624c70d495116`（`fix(sync): replace full-history replication`）
- Git author／committer：`mxt <mxt@local.com>`／`mxt <mxt@local.com>`
- 实际修改者：未知；现有 Git 证据只能确认提交 identity
- 修复提交：待回填

## 用户症状与影响

用户在 v0.2.6 看见「最近同步」和「最近有效同步」持续显示「暂无」。同步先等待 iCloud 上传，之后长时间停留在「同步中…」。本机资料仍保留，诊断没有显示这段时间新增的 mutation rejection 或 persistence failure，但同步无法到达完整成功收口，用户也无法从时间戳判断资料是否已经有效同步。

## 时间线

- 2026-08-08：`1f264ff9c38047c8ac959e9d0cd624c70d495116` 引入 durable incremental transport，把上传确认和下载 apply frontier 分成两条持久化路径。
- 2026-08-11T01:22:51Z 至 2026-08-11T01:25:17Z：诊断记录七轮等待上传确认的中间同步结果；因为尚未完成端到端收口，成功时间戳按既有语义保持空值。
- 2026-08-11T01:25:25Z 至 2026-08-11T01:27:23Z：最后一轮同步在 transport fetch／download merge 之间持续前进，约 118 秒后由用户取消；不是 mutex deadlock。
- 2026-08-10T22:00:00-04:00 后：以隔离 SQLite 与真实 Local Folder incremental transport 把 self-echo 和 v0.2.6 恢复路径先判红，再实施 Repository 原子提交边界。

## 复现与证据

用户主动导出的 v0.2.6 诊断包通过 owner-only regular-file、容量、schema 与隐私检查。保留窗口中的新增记录没有 operation failure、mutation rejection、persistence failure 或 previous-session interruption。最后一轮在取消前读取 24 个 remote batch、2,417 条 record、约 8.1 MiB；单次 fetch 只需 3–41 ms，主要时间消耗在本机重复 merge／audit。

源码与 SQLite 状态共同证明：上传协调器收到 confirmed receipt 后只调用 `markJournalEntriesUploaded`；下载协调器则独立维护 `generic.download.frontier.<namespace>`。因此同一个持久化 snapshot 可以同时声称「本机 journal 已上传」和「本机 producer 从未 apply」。下一次 pull 从 origin 开始，把刚由同一 snapshot 物化并上传的完整基线重新下载。

修复前症状测试的直接运行产物为：本机首轮确认上传后 `download.fetchedCount` 实际为 `2`，预期为 `0`；v0.2.6 durable-shape 恢复测试同样回读 `2` 条 record，且有效同步时间保持空值。

## 排除的假设

- 不是新增资料保存失败：新增窗口没有 persistence failure 或 mutation rejection，本机资料仍在。
- 不是 iCloud fetch 本身卡死：诊断持续记录 fetch／merge 进展，单次 transport fetch 处于毫秒级。
- 不是诊断包多出的 1,267 条记录代表新增错误：该差值与容量分段淘汰的旧记录数量一致。
- 不是只需修改 UI 时间戳：时间戳为空是同步没有完整结束的结果；提前写时间会制造虚假成功。
- 不是可以跳过所有本机 producer 资料：只有精确匹配现有 durable producer epoch、连续 sequence 与 content hash 的 confirmed immutable batch 才能授权推进；foreign producer 与空 receipt 必须保留给普通 pull。

## 根因与破坏机制

`1f264ff9c38047c8ac959e9d0cd624c70d495116` 正确引入了 immutable batch 和 durable apply frontier，但把同一个业务事实拆成两个互不原子的提交：上传确认只把 journal 迁移到 `uploaded`，本机 batch 的 apply frontier 只能在稍后的 download merge 事务推进。

对本机刚发布的 batch 来说，当前 SQLite snapshot 已经包含这些领域事实；transport confirmed receipt 又证明精确 immutable batch 已经发布。若此时不同时推进本机 producer frontier，协调器必然从旧 frontier 回读自身历史。随着本机基线增长，重复 merge／audit 的耗时按历史量放大；操作被取消前无法写入最近同步和最近有效同步时间。

## 根因修复

在 `SQLiteSyncRepository` 建立唯一 confirmed-upload commit seam：同一个 `BEGIN IMMEDIATE` transaction 内，以 journal 当前 state 和精确 durable receipt 做 CAS，把对应 journal 行迁移到 `uploaded`，并只将现有 durable local producer epoch 的连续 batch sequence 写入同一个 download frontier。任何 journal mismatch、receipt mismatch、sequence gap、hash 冲突、非法 durable producer 或损坏 frontier 都整体 rollback；foreign producer 和空 batch receipt 不推进本机 frontier。

针对 v0.2.6 已经持久化的状态，pending baseline 只在同一 SQLite snapshot 中同时满足 exact namespace、manifest digest／journal IDs、全部 journal 已 uploaded、每一项保留 canonical awaiting-confirmation receipt、现有 local producer epoch 及连续 sequence／hash 时恢复 frontier。若旧版本没有保留完整 receipt，则不猜测、不跳过远端资料，继续使用普通 pull 证明状态。

没有修改 UI 成功语义。self-echo 被消除后，协调器自然完成 final fetch 与 stability closure，并通过既有成功 metadata 写入最近同步和最近有效同步时间。

## 验证结果

- 红转绿：128 项完整本机基线使用真实 `LocalFolderSyncTransport` 分 16 项上传；本机 `download.fetchedCount == 0`，第二个独立 producer 仍读取全部资料并对账 128 个标题。
- 红转绿：精确构造 v0.2.6 pending baseline、uploaded journal、retained receipt 与 origin frontier；升级恢复在 pull 前完成，`download.fetchedCount == 0`，最近同步与最近有效同步同时写入恢复时刻。
- 红转绿：延迟确认路径跨多轮重试，只有确认后才在 Repository transaction 推进 frontier，最终零 self-echo 并写入两个时间戳。
- 原子性：gap、损坏 frontier 与 receipt CAS mismatch 均证明 journal transition rollback；foreign／empty receipt 只迁移 journal，不推进本机 frontier。
- 完整 Storage 套件：270 项执行，2 项既有显式 live-iCloud 用例未在普通套件启用，0 失败。
- `make check`：完整通过；其中完整测试执行 1,522 项、2 项既有 live-only skip、0 失败，年度 demo 14 项与确定性仿真通过。
- 首轮真实非生产 App E2E 抓到旧 oracle 仍要求本机上传后 `download.fetchedCount == 2`，而运行产物已经是 `pendingCount == 2`、`uploadedCount == 2`、`fetchedCount == 0`、两个 journal 均为 `uploaded` 且两个同步时间戳已写入。这证明产品根因修复生效，同时证明旧夹具把 self-echo 当成成功。旧 oracle 的 exercise audit count `5`、restart ignored count `3` 与最终 SQLite 总账 `6／3` 也都来自两条 self-echo；门禁已改为 exercise 总账 `3／0`、restart 后总账 `4／1`，并要求 foreign stale batch 在重启路径仍 fetched／ignored 一次。
- 更新 oracle 后，`NOONMARK_E2E_PREFERENCES_CLOCK_ONLY=1 scripts/test-e2e` 以真实签名 `e2e` App 完整通过 exercise、restart 与 SQLite 对账；最终 probe 为 `1 1 2 2 0 1 1 4 2 1 1`，证明两个本机 preference journal 已上传、零 self-echo download、foreign stale batch 在重启后仍被读取并忽略一次。
- 更新 oracle 后的未过滤 `scripts/test-e2e` 在到达本同步路径前，被既有烛龙 Provider 设置物理点击不稳定阻断。两轮失败分别落在第一和第二个 segmented control；失败轮次只有成功点击产生 AppKit action，设置 setter 不经过 SQLite 或同步模块。本次不以重跑、延时或绕过掩盖该独立故障，因此未把未过滤 E2E 或 `scripts/release-private-dmg` 记录为通过，也未进入发行。

## 永久门禁

- fast：`scripts/test-incremental-sync-contract` 拒绝上传协调器绕过 `commitConfirmedUpload`、重新直接调用 `markJournalEntriesUploaded`、缺少 exact receipt CAS，或 download 与 confirmed-upload 使用不同 frontier key owner。
- symptom：`scripts/test-incremental-sync-symptom` 同时执行 128 项双 SQLite／真实 Local Folder self-echo 对账、v0.2.6 durable-shape 恢复、延迟确认时间戳和既有稳态增量 I/O 门禁；`scripts/test-all` 继续强制执行完整真实 App E2E。

## 发行与回滚

风险评估：改动涉及同步资料一致性，主要风险是错误地跳过尚未 apply 的 foreign／不连续 batch，或 transaction 失败后留下 journal／frontier 半提交。实现以 durable local producer exact match、连续 sequence／hash、receipt CAS 和 SQLite rollback fail-closed；第二设备完整拉取测试保护 foreign producer 路径。

灰度策略：先在固定 `audit`／`e2e` 非生产 profile 完成双资料库、重启、真实签名 App 与本地发行前全集，再生成新的私有 Apple Development 签名版本，只交给当前指定用户验证。不得启动或探测 production App／资料，也不以 hosted CI 代替本地验证。

回滚方案：若非生产 symptom gate 发现资料缺失，立即停止发行并回退本修复提交；transaction 设计保证失败时旧 journal／frontier 不变。若新版本已经交付且出现异常，用户先停止同步并保留本机资料及主动导出的诊断包，再发布回退构建；不得清理 production SQLite 或 iCloud repository。

监控方案：新版本诊断应显示上传确认后本机首轮 fetch 的 record／batch／byte 数归零或仅包含 foreign producer 变化，同步操作完整 success，`lastSyncedAt` 与 `lastEffectiveSyncedAt` 不再为空。任何新的 operation failure、persistence failure、mutation rejection、重复读取本机 baseline 或长时间 merge 必须阻断扩大灰度。

## 教训与永久约束

- 对本机 immutable publication 来说，journal upload confirmation 与 local apply frontier 是同一个 durable fact，必须由 Repository 单事务拥有。
- receipt 不是提示信息；只有 exact durable producer、sequence 与 hash 证据才能授权 frontier 前进。
- 上传成功、transport acceptance、ubiquitous confirmation、apply frontier 和端到端有效同步是不同状态；UI 只能展示真实完成的层级。
- 性能故障必须用 transport 批次／bytes 与本机 merge 运行产物定位，不能把长时间「同步中」直接归因成网络卡死。

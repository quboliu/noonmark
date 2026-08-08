# FAIL-2026-08-07-15：同步稳态反复扫描并重写全部历史

- 状态：处理中
- 首次发现：2026-08-07T00:00:00-04:00
- 影响版本／构建：`main` at `0fe81cc6fb7528ae6173424d44641fb349704ddf` 及此前使用全量 mirror transport 的版本
- 引入提交：`d42bfbc4b43a78a3b05a1334d974dc7f36078d93`（`feat(app): improve local-first sync and UI experience`）；`28f261d969a70b58661a48dc07f7bd11eece3c55` 增加全 commit／mirror 修复，`e9d007f248b43dfe4b164ecdeac93e173a427912` 增加一轮内重复全量覆盖复核
- Git author／committer：上述提交均为 `quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 证据只能确认提交 identity
- 修复提交：待本次完整回归门禁通过并提交后回填

## 用户症状与影响

随着同步历史和 current records 增长，即使本轮只有一条变化或完全没有变化，用户触发同步仍会长时间占用 CPU、磁盘与 iCloud Drive 文件访问；协调器一次操作最多执行 17 次全量远端读取，Local Folder／iCloud Drive 上传还会重放全部 commit、重写完整 record mirror 与全部 snapshot。CloudKit 已收到增量 change 后也再次返回完整 mirror。性能因此按总历史放大，并增加同步期间任务修改被互斥锁拒绝的时间。

## 时间线

- 2026-07-08：首个 Local Folder transport 与协调器以 `fetchAll()` 建立全量模型。
- 2026-07-26：commit DAG、record mirror 与 snapshot repair 把上传成本进一步绑定到全部历史。
- 2026-07-28：完整基线与稳定性闭环在最多八轮 finalization 内重复抓取完整端点。
- 2026-08-07：源码计数门禁稳定复现 3 个协调器全量抓取点和 3 个 Local Folder 全仓重放入口，开始直接重写增量协议。

## 错误改动及破坏机制

`fetchAll()` 把“取得未见变化”和“证明完整远端状态”合并成同一个操作；Local Folder commit 又保存完整 current set，而不是只保存本次 immutable batch。为了覆盖并发和端点清空，协调器只能反复比较完整 evidence set。三个设计互相放大，使稳态复杂度至少为 `O(total remote records + total commits)`，finalization 重试再乘以常数上限。

## 复现与定位证据

在 source commit `0fe81cc6fb7528ae6173424d44641fb349704ddf` 执行结构取证：

```text
coordinator_full_fetch_calls=3
local_folder_repository_replays=3
FAIL: steady-state sync is coupled to total remote history
```

Linux 执行环境运行 `scripts/test-incremental-sync-symptom` 时，`scripts/reset-dev-data audit` 以 `refusing to reset Noonmark development data without a canonical account home` fail-closed；未绕过 reset。`make build` 也因缺少 macOS `sips` 停止，直接执行纯构建 `swift build --target NoonmarkSync` 则在既有 `NoonmarkDiagnostics/AppleDiagnosticLogger.swift` 的 `import OSLog` 停止。动态基准、完整 type-check、真实 `.app`、ubiquitous metadata 与双设备证据必须在 Mac 门禁补齐。

## 排除过的假设

- 不是单一 JSON encoder 热点：即使编码器为常数时间，调用集合仍覆盖全部 records／commits。
- 不是 iCloud 网络延迟单独造成：Local Folder 源码路径已经确定性执行相同全量工作。
- 不是只有 CloudKit 慢：iCloud Drive 直接委托同一个 Local Folder 全量实现。
- SQLite 本地 snapshot 校验可能是后续热点，但不能解释 transport 的全 commit 枚举和最多 17 次完整抓取。

## 根因修复

处理中。按 ADR-0046 直接改为 durable Outbox／Inbox／frontier、per-producer immutable batch chain、分页 pull 与分离上传确认；移除稳态 `fetchAll()`、全 current-set commit、mirror repair、完整 evidence-set 稳定性循环和成功收口时的全历史 journal 解码。outbox 状态查询与 unfinished count 使用 `(sync_state, changed_at)` index；established baseline 只校验 manifest 结构和 transport namespace，不再回读全部旧 journal。v18 迁移保留全部领域事实和设备身份，但清空只对旧仓库有意义的 journal／sync metadata，让新协调器从本机 snapshot 建立完整 baseline；baseline 禁止跨端点复用旧 receipt。

本次复核也移除了 transport protocol 及测试夹具中的 `fetchAll()`／全量 push 兼容路；协调器只能消费 frontier 后的 page。Local Folder 在 page 刚好落在非 tip batch 时额外读取一个后继 batch，验证 hash 链边界，避免损坏的非 tip batch 因分页截断而被接受；实际读取的 bytes／batches 同步计入 metrics，不能以未返回 records 掩盖 I/O。

真实 App 的烛龙 pending-recovery 夹具曾把 `localFirst.sync.baselineManifest` 当作空 Engine／应用恢复写围栏的前置条件。v18 clean cut 会在导入替换时清除旧同步运行态 metadata；该 metadata 与待恢复 journal、Engine、Session 的不变性无关。夹具现只断言这些真正受保护的资料事实，再在跨进程 SQLite writer lock 下验证启动、拒绝写入及所有受保护字节不变。

偏好时钟真实 App 夹具随后揭露了增量批次证据读取的一个相邻错误：`fetchSnapshots()` 逐批把上次的 current winner 放入 `existingRecords`，却把 `prepareTransportBatch()` 的仅-incoming canonical 输出当作下一次 current state。若后遍历的 producer 提供较旧事实，快照证据会错误地显示该旧事实；生产 bootstrap 虽一次性折叠全部 immutable evidence，未走这条错误路径。现改为每轮以截至该批的完整 immutable evidence 重新 canonicalize，确保快照与 bootstrap 的 current winner 一致；新增双 producer、后遍历批次较旧的单测，并保留真实偏好 UI／SQLite／repository E2E 作为症状门禁。

同一真实夹具在重启阶段还遗留了错误的审计计数 `4`：exercise 已明确要求一条 download merge、两条 replay ignore 和两条 upload，真实 SQLite 也如实记录 `5` 条，却在重启前被夹具自相矛盾地拒绝。现将重启状态契约与 exercise 的五条可解释审计事实对齐，避免以降低覆盖或跳过重启来掩盖问题。

最后，旧全量仓库夹具以替换整个受 guard 的临时 repository 制造“只剩一条过时远端事实”的重启场景；在 durable frontier 协议下，替换同一 endpoint 的历史会让本机 frontier 指向不存在的批次，运行产物正确 fail-closed 为 transport/storage failure，不能作为 ignored-only 的真实场景。夹具改为保留同一 endpoint，只以固定 remote producer 追加一个此前未见、字节保持一致的旧事实。

该重启路径同时揭露了实际的稳态放大根因：baseline coverage auditor 错误排除了所有 `uploaded` journal，即使其 canonical payload 已能完整重建当前事实。首次同步把 pending journal 标为 uploaded 后未建立 baseline manifest；下次启动便把已确认的当前事实错判为缺失，额外生成、上传同一 appPreferences baseline。现允许 confirmed uploaded evidence 参与 current-fact coverage，同时保留 pending／published／blocked evidence 的原有处理；新增 uploaded preference journal 覆盖单测，并由真实重启 E2E 断言没有额外 upload。这样才真实证明重启后的增量 frontier、过时事实忽略、审计计数及本地胜者均正确。

无 baseline manifest 本身是合法状态，不能为了测试损坏 manifest 而先制造多余 baseline。夹具现会保存原 metadata（若存在），写入损坏值验证 fail-closed，然后精确还原原值或删除仅由夹具写入的 key；因此重启仍验证已持久化的 baseline-invalid 警告，而用户主动重试可回到原本的合法无 manifest 状态。

当前 CloudKit transport 已不再向协调器返回完整 mirror，但显式 live-only 的 SQLite CloudKit persistence 仍会在 session commit 编码当前 mirror snapshot；这不是默认 iCloud Drive 路径的性能阻塞，却仍是 CloudKit 成为默认端点前必须消除的 `O(current records)` 残余。

## 回归测试

- fast：`scripts/test-incremental-sync-contract` 静态拒绝协调器 `fetchAll()`、稳态全 journal 物化、破坏 outbox state index 的 optional-state SQL、旧 `records/`／`indexes/`／`refs/latest` 仓库和 CloudKit `session.records()` 全镜像返回，并要求增量协议与新 layout 存在。
- symptom：`scripts/test-incremental-sync-symptom` 在两套 SQLite、128／256 条历史、零变化和单变化场景对账领域结果及实际 transport head／batch／bytes 访问量；零变化只读一个 head、零 batch、零 bytes，单变化只打开一个 batch 且 bytes 为正，证明稳态成本与旧历史无关。`scripts/test-all` 同时强制调用完整真实 App E2E，包括 Local Folder 同步及诊断锁等待闭环。
- 真实服务：`scripts/test-icloud-sync-live` 继续在 `e2e` profile 验证真实 App、batch/head ubiquitous upload confirmation 与双 SQLite；CloudKit 继续走 ADR-0019 的显式 live 门禁。

## 发行／回滚处置

这是未公开同步格式的 clean cut。production 默认 transport 本次不切到 CloudKit；用户自行清空现有 iCloud repository 后由新版本重建。回滚代码后也必须清空对应 repository 再重建，不能混读两种格式。agent 不执行 production 清理。

## 可执行教训

- 同步 transport 的默认读取 API 必须是 cursor／frontier 后的增量 page，不得以全量 mirror 作为正确性基础。
- 复杂度门禁必须计量打开的 heads／batches／bytes，并用固定 unseen 量对比不同历史规模。
- receipt cursor、apply frontier 和上传 confirmation 是三个不同事实，必须分别持久化和展示。

## 永久门禁

- 必需门禁：fast,symptom

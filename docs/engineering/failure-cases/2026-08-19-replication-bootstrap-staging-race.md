# FAIL-2026-08-19-03：Replication bootstrap 把活跃 staging 误判成旧仓库

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-19T10:56:53-04:00
- 影响版本／构建：未发行 `0.3.1 (37)` candidate，source commit `05e543f725b5de1b1977edf711dede1e4cd52dac`
- 引入提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：`2bd4734e5af061fe3709fa7ffdfee199808c1b5d`（`fix(sync): serialize replication repository bootstrap`）

## 用户症状与影响

私有出包前的完整 `make check` 在 `NoonmarkSyncTests` 运行中失败：`ReplicationRepositoryBootstrapTests.testConcurrentInitializationAdoptsTheSingleWinningMarker` 抛出 `ReplicationRepositoryBootstrapError`，319 项同步测试中有 1 项失败，候选因此未 push、未打包。

同一竞态若在 App 首次打开空 Replication V2 repository 时发生，一个初始化者会把另一个初始化者尚未发布 marker 的合法 staging 中间态误报为 `legacyRepositoryRequiresManualReset`。它不会删除、覆盖或迁移资料，但会错误阻断同步初始化并要求用户处理实际上并非旧格式的仓库。

## 时间线

- 2026-08-12：commit `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73` 引入 Replication V2 bootstrap、append-only marker publisher 与并发初始化测试。
- 2026-08-19T10:56:53-04:00：`0.3.1 (37)` 的推送前 `make check` 首次在完整 Sync 测试组捕获并发初始化失败。
- 单独复跑原用例 50 次、直接 XCTest 2,000 次及完整 Sync 测试组 20 次没有再次失败，证明原始窗口概率低，不能靠简单重跑构成放行证据。
- 受控 filesystem tracer 持有根目录 advisory lock，建立 `v2/staging/markers` 活跃中间态，延迟发布 canonical marker；旧实现稳定抛出 `legacyRepositoryRequiresManualReset`。
- bootstrap 在检查目录与发布／接管 marker 的整个临界区持有根目录文件描述符的 exclusive advisory lock 后，受控 tracer 与完整 bootstrap 测试组转绿。

## 复现与证据

原始症状来自 `make check` 保存的运行日志：`ReplicationRepositoryBootstrapTests.testConcurrentInitializationAdoptsTheSingleWinningMarker` 抛出未预期的 bootstrap typed error；同一组其余测试通过。

确定性 tracer 为 `ReplicationRepositoryBootstrapTests.testBootstrapWaitsForActiveMarkerPublicationBeforeInspectingTree`。它先锁住真实临时 repository 根目录并建立只有 `v2/staging/markers` 的活跃写入状态，100 ms 后从持锁写入者发布 canonical marker 并释放锁；与此同时，第二个 public bootstrap 尝试打开同一根目录。旧实现不参与这把锁，立即把 `v2` 误判成 legacy 并稳定判红；修复后等待写入者完成，再读取并接管精确 winner generation。

## 排除的假设

- 不是根目录创建竞态：原测试与受控 tracer 都在并发调用前预先建立真实目录。
- 不是共享临时路径碰撞：每轮使用新的 UUID 目录；2,000 次隔离复跑没有路径复用。
- 不是 marker 编码或 UUID 并发损坏：受控 writer 发布 canonical bytes，修复后两个 opener 精确采用同一 generation。
- 不是可以用重跑放行的 XCTest 抖动：原始失败由确定性 staging 窗口复现，错误分支与源码判断一一对应。
- 不能把只有 staging、没有 marker 的状态普遍视为可恢复空库：既有中断写测试要求进程崩溃后保留证据并 fail-closed，禁止自动清理、覆盖或猜测修复。

## 根因与破坏机制

旧 bootstrap 先列举根目录；若没有 marker，便要求目录完全为空。append-only publisher 为避免暴露半写 final marker，会先建立 `v2/staging/markers/<UUID>.stage`，完成写入与 `fsync` 后才以 `linkat` exclusive-create final marker。两个调用并发时，写入者建立 `v2` 与发布 marker 之间存在合法窗口；另一个调用若在此时列举目录，会看见非空根但看不见 marker，于是把活跃 V2 初始化错误归类为 legacy repository。

原并发测试只让两个任务自然竞争，没有固定这个短窗口，所以能够捕获故障但不能稳定重现。仅在 `destinationContainsDifferentBytes` 后接管 winner 也太晚，因为误判发生在第二个调用进入 publisher 之前。

## 根因修复

`FileReplicationRepositoryBootstrap` 在根目录完成边界验证后，以 `O_DIRECTORY | O_NOFOLLOW` 打开目录文件描述符，并在读取 children、验证 marker、建立 staging、发布 marker与接管 winner 的整个 bootstrap 临界区持有 `flock(LOCK_EX)`：

- 同一台 Mac 上的并发 task／process 只能依次观察完整 bootstrap 状态；
- 锁不建立 repository 对象，不改变 exact V2 grammar，也不触碰任何既有 iCloud 对象；
- 进程终止时内核释放 advisory lock，残留 staging 继续由原有中断写规则 fail-closed，不自动删除或覆盖；
- `EINTR` 只重试锁系统调用，其他 open／lock 失败映射到既有 `invalidBoundary`，不引入兼容层或超时路径。

## 验证结果

- Red：受控 tracer 在旧实现上稳定返回 `legacyRepositoryRequiresManualReset`。
- Green（聚焦）：同一 tracer 修复后通过，约 108 ms；完整 `ReplicationRepositoryBootstrapTests` 9 项、0 失败，包括并发 winner、中断写 fail-closed、symlink 与未知 subtree 边界。
- Green（原受害组）：`swift test --filter NoonmarkSyncTests` 运行 320 项、0 失败。
- Green（门禁）：`scripts/test-failure-case-gates` 已登记并校验 110 个案例；release version contract、SwiftFormat、SwiftLint 与 ShellCheck 均退出 0。最终候选仍须重新运行完整 `make check`、真实签名 App E2E、writer lease 与 DMG release chain，不能用聚焦结果替代发行门禁。

## 永久门禁

- fast：`scripts/test-replication-bootstrap-concurrency` 在真实临时 filesystem 运行完整 bootstrap 测试组，固定 active staging wait、single winner、中断写与边界语义；由 `scripts/test-replication-v2-recovery-contract` 纳入 `scripts/check`。
- symptom：`scripts/test-unit` 在完整 `NoonmarkSyncTests` 进程重跑并发 bootstrap 与所有同步消费者，捕获原始全组失败；由 `scripts/check` 强制调用。

## 发行与回滚

风险等级为 P：这是同步 repository 首次建立的数据边界。build 37 在推送与出包前退役；build 38 绑定根因修复 commit 后，又因案例闭环与发行身份文件改变 tracked source 而退役。两者都不覆盖、不重签、不分发；营销版本保持用户指定的 `0.3.1`，最终闭环候选使用 build 39。若 advisory lock 在本机或签名 App 路径失败，立即停止候选并 revert 独立修复 commit；不得取消锁、增加等待超时、自动清理 staging、读取 production 或修改任何既有 iCloud 对象。

灰度顺序保持完整本机门禁、指定用户第一台 Mac、第二台实体 Mac 与连续 72 小时 soak。监控只使用 typed bootstrap／sync state、耗时与用户主动导出的有界诊断，不记录 repository 路径、对象名、正文、payload、账号或原始 Error。

## 教训与永久约束

append-only final publication 不等于整个初始化过程具备原子可观察性。只要 protocol 在 final authority 出现前会建立可见 staging，同一 repository 的 bootstrap observer 就必须与活跃 writer 共享明确的临界区；同时仍须把崩溃后无 owner 的残留 staging 当成不可猜测状态。低概率并发测试失败不能以重复转绿降级处理，必须把短窗口变成受控、确定性的症状门禁。

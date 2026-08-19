# FAIL-2026-08-19-03：Replication bootstrap 活跃 staging 误判与跨 Mac authority 分歧

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-19T10:56:53-04:00
- 影响版本／构建：未发行 `0.3.1 (37)`、`(38)` 与 `(39)` candidate；三者都没有 push、打包或分发
- 引入提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 首轮修复提交：`2bd4734e5af061fe3709fa7ffdfee199808c1b5d`（`fix(sync): serialize replication repository bootstrap`，只修复同机并发）
- 修复提交：`ab9bf607334be0f76ccb924777fa91c16188f3e1`（`fix(sync): converge iCloud repository bootstrap authority`）

## 用户症状与影响

私有出包前的完整 `make check` 在 `NoonmarkSyncTests` 运行中失败：`ReplicationRepositoryBootstrapTests.testConcurrentInitializationAdoptsTheSingleWinningMarker` 抛出 `ReplicationRepositoryBootstrapError`。同一竞态若在 App 首次打开空 Replication V2 repository 时发生，一个初始化者会把另一个初始化者尚未发布 marker 的合法 staging 中间态误报为旧仓库，错误阻断同步。

首轮修复以 repository directory 的 `flock` 串行化 marker 检查与发布，但最终 Standards review 证明这只覆盖同一台 Mac 的同一 inode。两台 Mac 的 CloudDocs mirror 各有本机 inode，不能共享这把锁；若双方在远端 marker 尚未物化前各自生成随机 generation，两份 canonical marker bytes 会分歧。原确定性 tracer 又以未协调的 100 ms sleep 猜测 opener 已经进入锁等待，存在调度较慢时的假绿风险。因此 `0.3.1 (39)` 不能发行。

本故障不会授权 App 删除、覆盖、改名、移动或自动解决任何 iCloud 对象。分歧、非 canonical 或不可读 marker version 必须在 publication、observation 与 read 前阻断；已经存在的版本全部保留作证据。

## 时间线

- 2026-08-12：commit `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73` 引入 Replication V2 bootstrap、append-only marker publisher 与并发初始化测试。
- 2026-08-19T10:56:53-04:00：`0.3.1 (37)` 的推送前 `make check` 首次在完整 Sync 测试组捕获并发初始化失败。
- 单独复跑原用例 50 次、直接 XCTest 2,000 次及完整 Sync 测试组 20 次没有再次失败，证明原始窗口概率低，不能靠简单重跑构成放行证据。
- 受控 filesystem tracer 持有根目录 advisory lock，建立 `v2/staging/markers` 活跃中间态，延迟发布 canonical marker；旧实现稳定抛出 `legacyRepositoryRequiresManualReset`。
- commit `2bd4734e5af061fe3709fa7ffdfee199808c1b5d` 把同机 bootstrap 临界区纳入 `flock`，聚焦与完整 Sync 测试转绿；build 37、38 依次退役，build 39 绑定案例闭环。
- build 39 双轴 review 随后证明 `flock` 不具备跨 Mac authority，且 100 ms sleep 不能证明 opener 已尝试获取锁；案例重新转为处理中，build 39 退役。
- 本机 Xcode SDK 的 `Foundation/NSFileVersion.h` 进一步证明 `otherVersionsOfItem` 不包含尚未下载的版本；全量观测还必须调用 `getNonlocalVersionsOfItem`，并对 non-local version 做 coordinated read。原首轮修复没有这层证据。
- 新 tracer 先以显式 semaphore 证明 opener 已到达 `flock` 前，再发布 winner；另以两个独立 mirror、远端完整／部分／分歧 stage，以及 injected non-local marker version 固定跨设备边界。

## 复现与定位证据

原始症状来自 `make check` 的真实测试进程：并发 bootstrap 用例抛出未预期 typed error，同一组其余测试通过。源码与 filesystem tracer 对账后，确定误判发生在 marker final key 尚未出现、`v2/staging/markers` 已经可见的窗口。

Standards review 的跨设备反例不依赖真实用户资料：两个独立临时 mirror 使用相同 repository scope，但旧实现分别调用随机 UUID generator，必然得到不同 marker bytes；本机 `flock` 不可能让两个目录的 inode 形成同一临界区。Apple SDK header 又把本机 other versions 与 non-local versions 明确分成两个 API，否定了“检查本机 conflict list 就等于检查全部已知云端版本”的默认假设。

新增 Red 证据包括：

- 两个独立 mirror 必须从同一稳定 scope 推导完全相同的 generation 与 canonical marker；
- 即使已有本机 authority，空或含 NUL 的 repository scope 也必须拒绝；
- injected non-local marker 与 current marker 不同必须返回 `divergentMarkerVersion`；
- 只有完整 exact marker stage 可以继续 append-only publication，部分 exact prefix 只能返回 `markerPublicationInProgress` 且零写入，分歧 stage 继续按 corruption／legacy 边界 fail-closed；
- endpoint 的 publish、非空 observe 与 read 都必须在任何 object I/O 前消费同一 authority validator。

## 排除的假设

- 不是根目录创建竞态：原测试与受控 tracer 都在并发调用前预先建立真实目录。
- 不是共享临时路径碰撞：每轮使用新的 UUID 目录，没有路径复用。
- 不是 marker JSON 编码不稳定：canonical encoder 对同一 descriptor 产生相同 bytes；跨 mirror 分歧来自随机 generation authority，而不是 encoder。
- 不是 `flock` 实现错误：它能够可靠串行化同一台 Mac 的 opener，但 CloudDocs 在不同 Mac 上不是同一 inode，这项能力边界不能扩大解释。
- 不是可以用重跑或延长 sleep 放行的 XCTest 抖动：显式 handshake 才能证明 opener 已到达锁尝试点。
- 不能把所有 staging 都当成可恢复空库：部分或分歧 bytes 可能来自仍在同步的远端 writer，也可能是 crash evidence；在缺乏完整 exact bytes 时不得猜测、覆盖或清理。
- 不能只检查 `otherVersionsOfItem`：Apple SDK 明确把未下载版本放在 `getNonlocalVersionsOfItem`，任一 non-local version 不可读或不一致都必须阻断。
- iCloud Drive 没有 server-side CAS；本地测试不能冒充两台实体 Mac 或 72 小时 soak 已完成。

## 根因与破坏机制

原 bootstrap 把“marker 不存在且 root 非空”直接等同旧仓库，但 append-only publisher 在 final marker 前必然先暴露永久 staging。这个判断遗漏了合法中间态。

首轮根因修复又暗含两个错误前提：第一，假设 repository directory 的 advisory lock 能协调不同 Mac；第二，假设未协调 sleep 足以证明并发 opener 已经等待。实际上 `flock` 只提供本机 inode 协调，而随机 generation 令两个尚未看见对方 marker 的 Mac 生成不同 authority。即使稍后 CloudDocs 把两份 marker 变成 conflict versions，只检查本机已下载版本仍可能暂时漏掉 non-local 分支。

## 根因修复设计

- 保留 directory `flock`，但只把它声明为同机 task／process 的临界区；测试用显式 semaphore 在 `flock` 调用前握手，不再依赖时间猜测。
- 对没有既有本机 clean-cut authority 的 iCloud repository，以 domain-separated SHA-256 对稳定 repository scope 取 128 bit，并设置 RFC variant 与 UUIDv8 version。两台当前版本 Mac 即使完全离线初始化，也会生成相同 canonical marker bytes。
- 若 SQLite 已有 clean-cut authority，继续优先使用该 generation；若本机 marker 已可见，bootstrap 仍读取并采用 exact 既有 marker，避免静默替换已经存在的随机 V2 authority。
- 没有 final marker但只有 marker staging 时，完整 exact canonical bytes 可以由 append-only publisher补齐同一 final key；部分 exact prefix 返回 typed in-progress 且零写入；超长、分歧、非 canonical 名称或未知 subtree 全部 fail-closed。
- iCloud endpoint 初始化时校验 current 与本机可用 versions；每次 publish、非空 observe 与 read 前，再用 coordinated read 对账 current、操作前后本机 versions，以及 `getNonlocalVersionsOfItem` 返回的全部 non-local versions。完全相同版本可共存；非 canonical、不可读、current 变化或任一 bytes 分歧都 fail-closed，不 resolve、不删除。
- 这套设计以确定性 authority 消除当前版本 fresh bootstrap 的 split-brain 来源，并以 version validator 阻断已出现的分歧；它不宣称 iCloud Drive 获得 server CAS，也不以本机门禁替代双实体 Mac 灰度。

## 当前验证结果

- Red（同机）：受控 active staging tracer 在旧实现稳定返回 `legacyRepositoryRequiresManualReset`。
- Red（review）：两个独立 mirror 的旧随机 generator 产生不同 marker；100 ms sleep 无法证明 opener 到达锁点；只调用 `otherVersionsOfItem` 漏掉 SDK 定义的 non-local versions。
- Green（聚焦）：确定性 generation、既有 authority、scope validation、本机 exact／divergent versions、injected non-local divergence、完整／部分／分歧 staging、显式 lock handshake 与 endpoint preflight 均已转绿。
- Green（原受害组）：加入 non-local validator 后，`swift test --filter NoonmarkSyncTests` 运行 330 项、0 失败。
- Green（闭环）：完整修复已由 commit `ab9bf607334be0f76ccb924777fa91c16188f3e1` 独立承载，案例与 fast／symptom 门禁映射已经回填。完整 `make check`、双轴 review、真实签名 App E2E、writer lease 与 DMG release chain 仍是 build 40 发行门禁，不能用案例已修复替代发行就绪。

## 永久门禁

- fast：`scripts/test-replication-bootstrap-concurrency` 在真实临时 filesystem 运行 bootstrap、iCloud authority 与 endpoint preflight 测试，固定同机 lock handshake、独立 mirror deterministic marker、远端 staging 三态、本机／non-local version 分歧与零写入 fail-closed；由 `scripts/test-replication-v2-recovery-contract` 纳入 `scripts/check`。
- symptom：`scripts/test-unit` 在完整 `NoonmarkSyncTests` 进程重跑所有同步消费者，捕获原始全组失败；由 `scripts/check` 强制调用。
- 真实双 Mac：只有 append-only 静态门禁与本机症状门禁先通过后，才可按专用 session／round 在两台实体 Mac 执行；对象永久保留，不清理，不把本机 mirror 测试冒充跨设备结论。

## 发行、风险、回滚、灰度与监控

风险等级为 P：这是同步 repository 首次建立与跨设备 generation authority。build 37、38 与 39 全部在 push／出包前退役，不覆盖、不重签、不分发；营销版本保持用户指定的 `0.3.1`，当前闭环候选为全新的 build 40。

回滚为整体 revert 独立 sync 修复 commit 并退休受影响 candidate；不得取消 authority validation、恢复随机 fresh iCloud generation、增加 sleep／timeout、自动清理 staging、resolve file versions、读取 production 或修改任何既有 iCloud 对象。由于所有新增远端动作仍是 append-only exact publication，回滚不需要也不允许远端删除。

灰度顺序为聚焦 filesystem／完整 Sync → `make check` → 签名 `e2e` App → 私有 DMG 第一台 Mac → 第二台实体 Mac → 连续 72 小时 soak。监控只使用 typed marker unavailable／in-progress／divergent、同步 state、有限计数与用户主动导出的诊断；不得记录 repository 路径、版本 URL、对象名、正文、payload、账号或原始 Error。

## 教训与永久约束

append-only final publication 不等于初始化 protocol 具备跨设备原子 authority。本机 inode lock、文件服务的 conflict version 和服务端 CAS 是三个不同层级；文档与测试必须逐一写清。低概率并发失败不能靠重跑或 sleep 放行，跨设备结论也不能只靠同机 mirror。没有 server CAS 时，fresh authority 必须由所有合法 writer 独立推导到相同 bytes；任何观察到的非 canonical、不可读或分歧版本都只能保留并 fail-closed。

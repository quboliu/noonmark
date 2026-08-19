# FAIL-2026-08-19-03：Replication bootstrap 活跃 staging 误判与跨 Mac authority 分歧

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-19T10:56:53-04:00
- 影响版本／构建：未发行 `0.3.1 (37)`、`(38)`、`(39)` 与 `(40)` candidate；四者都没有 push、打包或分发
- 引入提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 首轮修复提交：`2bd4734e5af061fe3709fa7ffdfee199808c1b5d`（`fix(sync): serialize replication repository bootstrap`，只修复同机并发）
- 第二轮修复提交：`ab9bf607334be0f76ccb924777fa91c16188f3e1`（`fix(sync): converge iCloud repository bootstrap authority`，终审后证实仍不完整）
- 第三轮修复提交：`973ff77b3e7e08d223e7418c0478af9139ec5950`（`fix(sync): close iCloud authority observation gaps`）
- 第四轮修复提交：`5cd07d248e2c1a5e067d0645334b362fce561e18`（`fix(sync): finish authority validation on every path`）
- 第五轮补漏提交：`ce87b5117a2cc7bf3e84649dd1b31d74f902f670`（`fix(sync): reject authority changes before operation`）与 `0ce661fa4e70edbf55a1365b5fd15141b101b646`（`fix(sync): harden authority release evidence`）
- 第六轮补漏提交：`6c596cf`（`fix(sync): enforce live iCloud release evidence`）与 `6308032`（`test(sync): isolate authority diagnostic roots`）
- 第七轮 readiness 修复提交：`124cb0037c22cc7e03c659c97db2d8a725f0caca`（`fix(sync): wait for iCloud authority readiness`）

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
- build 40 双轴终审再发现四项反例：semaphore 在真正调用 `flock` 前已经放行，不能证明发生锁竞争；marker 可在首次 root scan 与 staging scan 之间出现并被误报 legacy；SQLite 中旧随机 authority 可在空 iCloud mirror 发布与新客户端确定性 authority 不同的 marker；部分可读 stage 被改成 `markerPublicationInProgress`，破坏 `FAIL-2026-08-11-17` 已固定的人工重置契约。
- 同一终审根据本机 Xcode SDK 的 `NSFileVersion.h` 确认，全量版本观察必须在单次 coordinated read 内注册实现 gain／lose 回调的 `NSFilePresenter`、枚举 local versions 并调用 non-local API，而且 presenter 必须跨越实际 remote operation。只做操作前后两个独立 snapshot 仍有漏报窗口。
- 用户批准兼容边界：旧随机 authority 只有在原 final marker 确实可见且 bytes 一致时才可采用；若 marker 缺失或不可用，必须零写入 fail-closed，等待原 marker 可见。不得自动改写、迁移、fallback 或以 stage 代替 final marker。
- `973ff77` 后的双轴终审继续判红四个边界：SQLite authority 为 nil 时仍会静默采用可见的旧随机 marker；operation 抛错时跳过 post snapshot；异步 non-local callback 等待期间 current bytes 改变没有触发 authority flag；初始化时既有的 locally available version preflight 被删除，令 clean-cut 本机副作用可能先于分歧阻断。
- `5cd07d2` 后的双轴终审再发现三项缺口：初始 snapshot 读出 current 后、首次 non-local callback 返回前发生 marker 改变时，operation 仍会先执行；登记的真实 App symptom gate 只覆盖成功路径，旧错误实现同样会通过；公开 initializer 的外部标签从 `preferredGenerationID:` 改成 `existingGenerationID:`，造成未经批准的源码兼容破坏。
- `ce87b51` 后的双轴终审继续发现四项证据缺口：non-local API 已被移出 coordinated read accessor；真实 iCloud runner 间接调用会执行 `reset-dev-data audit` 的 fast gate；诊断 recorder 不可用时以全零计数放行；App 只断言 authority error 类型，瞬时 unavailable 也会假绿为旧随机 authority 已正确拒绝。
- `0ce661f` 后的双轴终审否定最后两个门禁假设：Store 正确拒绝 authority 时会建立并失败一条 `.localFirstSync` diagnostic capsule，要求零失败会把正确实现判红；依赖 `sed` 解析 shell 调用图无法覆盖 `bash scripts/...`、`./scripts/...` 或 `env ... scripts/...`，不能证明任一间接 reset 都被阻断。
- `6c596cf` 后的双轴终审再证明测试的三个 SQLite 文件虽然名称不同，却共用同一父目录与 `Diagnostics`；先运行的 Local Folder 成功 capsule 会污染 authority snapshot，使正确实现无法满足零成功／一失败。文件名隔离不等于 App data-root 隔离。
- 完整 `make check`、签名 `e2e` App 与 writer lease 转绿后，首次获准执行真实 append-only iCloud 验证。旧随机 authority round `2d823503-68d9-4bd9-82b2-c07fe6788285/78b9ce7c-04bd-4e4d-8fa9-46932d27d195` 只建立 1 个 exclusive-create marker，并以 `authority-rejected-zero-write`、`syncProtocol/443` 转绿。随后 fresh deterministic round `e59813c1-ab2b-406a-85ec-3a7ec5f846ab/5ab70329-4d78-447f-9c96-f7d8feef372a` 在 exercise 阶段回报 `unavailableMarkerVersion`、`syncProtocol/444`；因此 restart 与第二份 SQLite 收敛没有运行，发行继续阻断。
- 对上述失败 round 的精确只读 probe 只检查本轮新路径：marker 已是 ubiquitous、uploading false、uploaded true、无 upload error、current version 可见、无 other／conflict version，non-local inventory 随后也成功返回零版本；结构计数为 21 个 descendants。没有读取 payload，也没有删除、覆盖、移动、改名或清理对象。这项运行证据把“永久 marker corruption”排除，并证明 Apple metadata publication 存在短暂 readiness window。

## 复现与定位证据

原始症状来自 `make check` 的真实测试进程：并发 bootstrap 用例抛出未预期 typed error，同一组其余测试通过。源码与 filesystem tracer 对账后，确定误判发生在 marker final key 尚未出现、`v2/staging/markers` 已经可见的窗口。

Standards review 的跨设备反例不依赖真实用户资料：两个独立临时 mirror 使用相同 repository scope，但旧实现分别调用随机 UUID generator，必然得到不同 marker bytes；本机 `flock` 不可能让两个目录的 inode 形成同一临界区。Apple SDK header 又把本机 other versions 与 non-local versions 明确分成两个 API，否定了“检查本机 conflict list 就等于检查全部已知云端版本”的默认假设。

新增 Red 证据包括：

- 两个独立 mirror 必须从同一稳定 scope 推导完全相同的 generation 与 canonical marker；
- 即使已有本机 authority，空或含 NUL 的 repository scope 也必须拒绝；
- injected non-local marker 与 current marker 不同必须返回 `divergentMarkerVersion`；
- 只有完整 exact marker stage 可以继续 append-only publication；任何可读的部分、空、超长或分歧 stage 都必须按 `legacyRepositoryRequiresManualReset` 零写入 fail-closed，以保持 `FAIL-2026-08-11-17` 契约；只有 stage bytes 本身暂时不可读时才可回报 `markerPublicationInProgress`；
- endpoint 的 publish、非空 observe 与 read 都必须在任何 object I/O 前消费同一 authority validator。
- 真实 `flock(LOCK_EX | LOCK_NB)` 必须先返回 `EWOULDBLOCK`／`EAGAIN`，测试握手才可放行 publisher；marker 若在首次 absence 与 staging scan 之间出现，fresh scan 必须采用已经发布的 winner。
- presenter 必须在 operation 期间真实出现在 `NSFileCoordinator.filePresenters`，结束与任何错误路径后都必须平衡注销；non-local inventory API 不可用时 operation 不得执行。
- SQLite authority 为 nil 且 mirror 已有旧随机 final marker 时必须按 deterministic authority 分歧阻断，且 mirror inventory 与 marker bytes 保持不变。
- operation 自身失败也必须执行最终 snapshot；若最终 authority 同时分歧，authority error 优先，不能只回报原 operation error。
- native presenter 必须以 `presentedItemDidChange` 捕获最终 snapshot 读出 current 后、non-local callback 返回前发生的 bytes 改变；仅监听 version gain／lose 不完整。
- endpoint 初始化必须在 clean-cut 本机持久化前保留 locally available version preflight；该 preflight 与完整 remote-operation authority window 是两层互补门禁。
- 初始 snapshot 的 non-local loader 在第一次调用期间以不经过 coordinator 的方式改写 current；旧实现继续执行 operation，并在第二次 snapshot 才发现分歧。运行断言明确记录 `operationDidRun == true` 与 loader 调用 2 次，否定了“注册 presenter 后初始异步窗口已经闭合”的假设。
- symptom contract 在真实 App 没有旧 authority fault mode 时稳定判红；它要求在全新 append-only round 只以 `O_CREAT | O_EXCL | O_NOFOLLOW` 建立一份旧随机 final marker，然后走 Store 的真实 iCloud 配置路径，核对 runtime、SQLite clean-cut、outbox、同步时间与 round inventory 全部保持零副作用。
- 最新终审门禁在修复前分别稳定判红：exact authority verdict 没有可用的 privacy-safe raw code；App stress 仍直接调用 resetting fast gate；append-only guard 沿调用图发现 `scripts/test-replication-bootstrap-concurrency -> scripts/reset-dev-data`；bootstrap contract 证明 non-local loader 只在 coordinated accessor 返回后才启动。
- 诊断／reset 第二轮 Red 进一步固定两项事实：authority error 没有 stable `DiagnosticFailureProviding` code，App contract 找不到“一条失败 capsule”的断言；`reset-dev-data` 不认识 inherited live sentinel，append-only guard 与 direct／bash／relative／env-wrapper mutation gate 全部稳定判红，且测试只传入不可 reset 的 production profile，没有触碰任何资料。
- data-root isolation contract 在旧 runner 上稳定判红：local、authority 与 iCloud database 都直接位于同一个 `$gate_root`，无法各自拥有独立 `Diagnostics`。
- fresh deterministic round 的运行红证据否定“本机 marker 可读就代表完整 version inventory 已经可供 remote operation 使用”的假设；初始化时 local preflight 成功，首轮 reconcile 仍可在 non-local inventory 暂不可用时抛出 `unavailableMarkerVersion`。现有 runtime 把所有 endpoint throw 一律写成 `.blocked/.runtimeFailure`，错误地把可重试的操作前 readiness 当成永久事故。

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

- 保留 directory `flock`，但只把它声明为同机 task／process 的临界区；测试先用 non-blocking `flock` 取得真实 `EWOULDBLOCK`／`EAGAIN` 证据，再通过 semaphore 放行，不再依赖时间或“即将尝试”的假握手。
- 对没有既有本机 clean-cut authority 的 iCloud repository，以 domain-separated SHA-256 对稳定 repository scope 取 128 bit，并设置 RFC variant 与 UUIDv8 version。两台当前版本 Mac 即使完全离线初始化，也会生成相同 canonical marker bytes。
- 若 SQLite 没有 authority，或既有 authority 等于当前 scope 推导值，才允许以确定性 generation 打开／建立 repository；若 SQLite authority 是历史随机值，只允许只读打开可见 final marker并核对 generation。final marker 缺失或不可用时保持 mirror inventory 不变，回报 typed unavailable，不以 stage 补发。
- 没有 final marker但只有 marker staging时，只有没有历史随机 authority 的 fresh deterministic bootstrap 可以用完整 exact canonical bytes 补齐同一 final key；可读的部分、空、超长、分歧、非 canonical 名称或未知 subtree 全部按 corruption／legacy 边界 fail-closed。
- 初始化完成 bootstrap 后，在同一次 coordinated read 内复核 current 与所有 locally available versions，确保 App 尚未进入 clean-cut 本机持久化前即可阻断已可见分歧；这层 preflight 不冒充 non-local 全量观察。
- 每次 publish、非空 observe 与 read 前，在 coordinated read 内注册 marker `NSFilePresenter`、读取 current 与 local versions 并调用 `getNonlocalVersionsOfItem`；presenter 监听 bytes change 与 version gain／lose，持续覆盖实际 operation，即使 operation 失败也再做 post snapshot，并在 coordinated read 内注销后排空回调。current、版本 inventory 或任一 bytes 变化、非 canonical、不可读都 fail-closed，不 resolve、不删除。完整 authority window 固定由每次 remote operation 承担。
- `ReplicationEndpoint` 以显式 readiness 结果表达 operation 前的 materialization 状态。`LocalFirstReplication` 必须在 recovery、journal sealing 与任何 endpoint operation 前读取 readiness；`.awaitingMaterialization` 只落盘为无 incident 的 `.waitingForEndpoint`，由既有同步调度再次尝试，不新增 sleep、timeout 或旁路。
- readiness 与实际 operation 之间仍可能发生状态变化，因此 iCloud adapter 在每次 operation 的 authority lease 建立阶段，把 `unavailableMarkerVersion` 精确转换为 `ReplicationEndpointReadinessError.awaitingMaterialization`；runtime 同样回到 waiting。只有 lease 尚未取得、operation 尚未开始的 unavailable 可以这样转换。operation 已经开始后的 final snapshot／presenter 注销 unavailable、marker bytes 或 inventory 分歧仍保留原 authority error，并由 App 记为终止性 incident。
- 每次 snapshot 在第一次 coordinated read accessor 内登记 presenter、读取 current／local versions并启动 non-local loader；accessor 返回后等待异步 callback，再执行第二次 coordinated current／local-version 读取并对账。presenter 在放行 coordinated writer 前同步记录 authority change。初始 snapshot 任一 bytes 变化都会在 operation 前失败，不能拖到 post validation 才发现；coordinated URL 不得带出 accessor 后再调用 Foundation version API。
- 所有真实 iCloud entrypoint 在任何下游命令前 export `NOONMARK_LIVE_ICLOUD_SYNC=1`；`reset-dev-data` 自身必须在载入 profile helper 前检查 inherited sentinel 并 fail-closed。独立 fast mutation gate 以 direct、bash、relative 与 env-wrapper 四种形式证明间接调用同样在任何副作用前拒绝，不再把不完整的 shell 语法解析冒充完整调用图。
- 真实签名 App symptom gate 先运行不会 reset 的 append-only 静态门禁与完整 Local Folder App 前置门禁，再在独立全新 iCloud session／round 以 exclusive-create 写入一份 canonical 旧随机 final marker；Store 必须回报 exact `divergentMarkerVersion`，并取得恰好一条 `.localFirstSync` failed capsule，其 privacy-safe failure 固定为 `syncProtocol/443`；不得建立 runtime、clean-cut authority、outbox、同步时间或新增远端对象。随后才运行正常 deterministic authority 的 iCloud 收敛路径。
- Local Folder、authority fault 与正常 iCloud 三组真实 App phase 必须各自使用独立 App data-root；SQLite、Diagnostics、sidecar 与 process lease 都从对应父目录派生。只有同一 endpoint 的 exercise／restart 可以复用自己的 data-root，跨 endpoint 不共享诊断历史。
- `ICloudDriveReplicationEndpoint` 保留原公开外部标签 `preferredGenerationID:`，只把内部参数名更新为 `existingGenerationID`，避免新增 overload 或兼容分支。
- 这套设计以确定性 authority 消除当前版本 fresh bootstrap 的 split-brain 来源，并以 version validator 阻断已出现的分歧；它不宣称 iCloud Drive 获得 server CAS，也不以本机门禁替代双实体 Mac 灰度。

## 当前验证结果

- Red（同机）：受控 active staging tracer 在旧实现稳定返回 `legacyRepositoryRequiresManualReset`。
- Red（review）：两个独立 mirror 的旧随机 generator 产生不同 marker；100 ms sleep 无法证明 opener 到达锁点；只调用 `otherVersionsOfItem` 漏掉 SDK 定义的 non-local versions。
- Red（build 40 终审）：旧随机 authority 在 marker 缺失时仍可发布新 marker；marker 在两次 scan 之间出现会被误判；partial stage 返回错误的 in-progress；lock hook 在真实 contention 前触发；presenter 没有跨越 operation。
- Green（第三轮聚焦）：旧随机 authority 的 absent／empty／stage-only mirror 全部零写入，只有可见且 matching final marker 可采用；derived authority 可重建空 mirror但拒绝不同 marker；marker scan race、partial-stage 人工重置、真实 `EWOULDBLOCK` 握手均已转绿。
- Red（`973ff77` 终审）：新增 7 个确定性用例在旧实现稳定失败，直接证明 nil authority 静默采用随机 marker、失败 operation 的 post snapshot 次数为 0、最终 snapshot 异步窗口内 bytes 改变仍返回成功，以及 marker directory 被误报暂时不可用。
- Green（authority window）：fake session 固定 pre／post marker 与 inventory 变化，并证明失败 operation 仍执行 post validation 且 authority failure 优先；真实 Foundation runtime 证明 presenter 在 operation 内注册、捕获最终 snapshot 异步窗口内的 bytes 改变，并在成功／non-local unavailable 错误后平衡注销；endpoint publish、非空 observe 与 read 都执行 post validation。聚焦共 38 项、0 失败。
- Red（`5cd07d2` 终审）：原生初始 snapshot 竞态稳定证明 operation 已执行、loader 被调用 2 次；真实 App stress contract 因没有旧 authority fault mode 稳定判红。
- Green（终审补漏）：初始 snapshot 以未协调改写复跑后在 operation 前返回 `divergentMarkerVersion`，operation 没有执行且 loader 只调用 1 次；旧 authority fault mode、append-only 静态门禁与脚本合同均返回 0。
- Red（`ce87b51` 终审）：新增 exact verdict unit、App stress contract、append-only dependency guard 与 coordinated non-local source contract 分别因没有 raw verdict、仍间接 reset、诊断／typed case 假绿及 loader 位于 accessor 外而稳定失败。
- Green（最新终审补漏）：non-local 请求在 coordinated accessor 内启动，callback 与第二次 snapshot 在 accessor 外完成；live dependency guard 已拒绝所有可达 reset；authority App 结果只接受 exact `divergentMarkerVersion` 且缺少诊断 snapshot 立即失败。fast 聚合共 40 项、0 失败，完整 `NoonmarkSyncTests` 共 351 项、0 失败；append-only guard、App stress contract、failure-case gate、`make format-check` 与 `make lint` 均返回 0。真实签名 App／iCloud symptom 尚待执行。
- Red（`0ce661f` 终审）：源码路径证明正确 authority rejection 会记录失败诊断，但 App／shell 错误要求 `diagnosticSyncFailedCount == 0`；mutation gate 同时证明旧 reset 边界不会识别 live sentinel，四种调用方式均未得到预期的 early refusal。
- Green（诊断／reset 补漏）：authority errors 已映射到固定 `syncProtocol/441...445`，divergent 为 `443`；App／shell 共同要求零成功、恰好一条 `syncProtocol/443` 失败 capsule。真实 iCloud 四个入口在开头 export live sentinel，reset 自身在 bootstrap 前拒绝；direct、bash、relative 与 env-wrapper mutation gate、append-only guard、App stress contract 及 failure-case gate 全部返回 0。fast authority 聚合共 41 项、0 失败，完整 `NoonmarkSyncTests` 共 352 项、0 失败；`make format-check` 与 `make lint` 返回 0。`make check` 与真实签名 App／iCloud symptom 尚待执行。
- Red（`6c596cf` 终审）：三个 database URL 的父目录相同，源码对账证明 authority snapshot 必然包含 Local Folder 成功 capsule；新增 data-root isolation contract 在旧 runner 稳定判红。
- Green（data-root 隔离补漏）：runner 现在建立 `local`、`authority`、`icloud` 三个 mode 级 0700 data-root，各自承载 SQLite、Diagnostics、sidecar 与 lease；App stress contract、append-only guard 与 shell syntax 返回 0。完整回归与真实签名 App／iCloud symptom 尚待执行。
- Green（首轮发行前验证）：完整 `make check` 共 1,627 项、0 失败；签名 App 的飞光 Markdown 用户路径与 writer lease 全部通过。旧随机 authority 的真实 append-only round 以 1 个对象和 `authority-rejected-zero-write` 转绿。
- Red（fresh iCloud readiness）：fresh deterministic round 回报 `unavailableMarkerVersion`／`syncProtocol/444`；精确只读 probe 随后证明同一 marker 已上传且没有分歧版本，旧 runtime 把短暂 metadata readiness 错判为 `.runtimeFailure`。
- Green（readiness 聚焦）：5 项新增测试固定 readiness 首次不可用时零 endpoint operation、pre-operation race 零远端 mutation、injected 与 native iCloud pre-operation unavailable 都映射 typed waiting，以及 post-validation unavailable 保持原终止性 authority error；5 项、0 失败。完整聚合与真实 iCloud symptom 尚待复跑。
- Green（readiness 完整复验）：commit `124cb0037c22cc7e03c659c97db2d8a725f0caca` 的完整 `make check`、签名 App E2E 与 writer lease 均返回 0；旧随机 authority session `265276a5-891c-467e-a15b-8ee0ca1147c1`／round `bfe506d7-1a84-46b0-8f4a-bae1b91571fc` 以 1 个对象、`authority-rejected-zero-write` 转绿；fresh deterministic App stress session `cb07caee-44be-4de0-a17c-2580ec8000e5`／round `fafb50fb-7518-4340-b5ac-e91037d8ab04` 完成 exercise、重启与第二 SQLite 对账。
- 后续 multi-round 门禁暴露的是 `973ff77` 引入的 presenter writer-intent 假分歧，已独立归档为 `FAIL-2026-08-19-04`；它不推翻本案例的 readiness 根因与上述真实症状绿证据。由于该独立修复仍会修改共享 authority 组件，本案例等待最终精确 source 的回归复验后再改为「已修复」。

## 永久门禁

- fast：`scripts/test-replication-bootstrap-concurrency` 在真实临时 filesystem 运行 bootstrap、iCloud authority、stable diagnostic code、endpoint preflight 与 runtime readiness 测试，固定同机 lock handshake、独立 mirror deterministic marker、远端 staging 三态、本机／non-local version 分歧与零写入 fail-closed；同时固定 pre-operation unavailable 只能进入无 incident waiting、post-validation unavailable 必须保持终止，并静态固定 non-local API 在 coordinated accessor 内启动；由 `scripts/test-replication-v2-recovery-contract` 纳入 `scripts/check`。`scripts/test-live-icloud-reset-sentinel` 独立执行 direct／indirect reset refusal，并由 `scripts/check` 直接调用。
- symptom：`scripts/test-replication-v2-app-stress` 以 mode 级独立 App data-root 运行真实签名隔离 App，先在全新 append-only iCloud round 建立一份旧随机 final marker，并证明 Store exact `divergentMarkerVersion` rejection 前后只有该 marker、恰好一条 `syncProtocol/443` 失败诊断、runtime／clean-cut／outbox／同步时间均未建立；随后在另一全新 round 完成 deterministic bootstrap、remote operations、重启及第二份 SQLite 收敛。所有真实 iCloud 入口继承 live sentinel，reset 自身负责 fail-closed；该入口由 `scripts/test-replication-v2-real-validation` 强制调用，普通 unit process 只作为受害组回归，不再冒充 symptom gate。
- 真实双 Mac：只有 append-only 静态门禁与本机症状门禁先通过后，才可按专用 session／round 在两台实体 Mac 执行；对象永久保留，不清理，不把本机 mirror 测试冒充跨设备结论。

## 发行、风险、回滚、灰度与监控

风险等级为 P：这是同步 repository 首次建立与跨设备 generation authority。build 37、38、39 与 40 全部在 push／出包前退役，不覆盖、不重签、不分发；营销版本保持用户指定的 `0.3.1`。新 build 只可在第三轮修复 commit 确定并通过终审后分配。

回滚为整体 revert 独立 sync 修复 commit 并退休受影响 candidate；不得取消 authority validation、恢复随机 fresh iCloud generation、增加 sleep／timeout、自动清理 staging、resolve file versions、读取 production 或修改任何既有 iCloud 对象。由于所有新增远端动作仍是 append-only exact publication，回滚不需要也不允许远端删除。

灰度顺序为聚焦 filesystem／完整 Sync → `make check` → 签名 `e2e` App → 私有 DMG 第一台 Mac → 第二台实体 Mac → 连续 72 小时 soak。监控只使用 typed marker unavailable／in-progress／divergent、同步 state、有限计数与用户主动导出的诊断；不得记录 repository 路径、版本 URL、对象名、正文、payload、账号或原始 Error。

## 教训与永久约束

append-only final publication 不等于初始化 protocol 具备跨设备原子 authority。本机 inode lock、文件服务的 conflict version 和服务端 CAS 是三个不同层级；文档与测试必须逐一写清。低概率并发失败不能靠重跑或 sleep 放行，跨设备结论也不能只靠同机 mirror。没有 server CAS 时，fresh authority 必须由所有合法 writer 独立推导到相同 bytes；任何观察到的非 canonical、不可读或分歧版本都只能保留并 fail-closed。

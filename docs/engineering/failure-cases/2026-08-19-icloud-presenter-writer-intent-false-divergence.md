# FAIL-2026-08-19-04：iCloud presenter 写入意图误报 authority 分歧

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-19T00:00:00-04:00/2026-08-19T23:59:59-04:00
- 影响版本／构建：未发行 `0.3.1 (40)` candidate；没有 push、打包或分发
- 引入提交：`973ff77d1b223140f4a22fc3593f6dbd98772a7e`（`fix(sync): close iCloud authority observation gaps`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

发行前第二组真实 append-only iCloud 门禁在首个 fresh round 的 source reconcile 连续三次等待 marker materialization 后，第四次回报 `divergentMarkerVersion`。第二个 fresh round 因第一轮失败而没有启动，故 `0.3.1 (40)` 不能 push 或出包。

该错误不是远端 marker bytes 真正分歧。它把 `NSFilePresenter` 的正常协调事件当成 authority 改变，令一份 canonical、已上传且与当前 deterministic repository scope 一致的 marker 被错误阻断。App 没有删除、覆盖、改名、移动或解决任何 iCloud 对象，失败 round 永久保留。

## 时间线

- `973ff77` 为关闭 operation 中的 marker 变化窗口加入 `NSFilePresenter`，但把 `presentedItemDidChange`、version gain／lose 和 `relinquishPresentedItem(toWriter:)` 全部无条件折算成分歧。
- readiness 修复 `124cb0037c22cc7e03c659c97db2d8a725f0caca` 后，完整 `make check`、签名 App E2E、旧随机 authority 零写入拒绝与一组 fresh deterministic App stress 均通过。
- 第二组真实 multi-round symptom gate 建立 session `84fed39d-2a74-4abb-94ce-527657412215`；首轮 `00d76ffc-1657-4bd2-b4e5-6f9a2915566e` 回报 `divergentMarkerVersion`，第二轮 `86158ea3-15cf-4389-a614-43436b7ac202` 未启动。
- 只读 probe 严格限制在失败 round：marker 为 canonical regular file，73 bytes，ubiquitous／uploaded 为 true，uploading／unresolved 为 false，无 upload error；current 与唯一 other version bytes 完全相同，non-local 与 unresolved version 数量均为零，marker generation 精确等于当前 repository scope 的 deterministic generation。
- 本机 Xcode 26.2 SDK header 证明 `presentedItemDidChange` 可以只表示 attributes 改变，`relinquishPresentedItem(toWriter:)` 只表示某个 writer 正在请求协调，并不证明 bytes 已改变。
- 新增原生 Foundation 红用例在 marker bytes 前后完全相同时只触发 writer intent；旧实现稳定回报 `divergentMarkerVersion`。
- 第一版修复尝试在 presenter reacquirer 内再次建立普通 `NSFileCoordinator` read，聚焦测试发生死锁。测试进程被终止且没有接触 production 或 iCloud；该方案被删除。
- 当前实现改为在 presenter 回调中收集实际 marker／version bytes，并在同一个最终 coordinated read 内取得最后 snapshot 后注销 presenter、排空回调。相同 canonical bytes 只记为 revalidated equivalent；不同 bytes 或不可读仍 fail-closed。

## 复现与证据

真实症状入口为：

```text
scripts/test-icloud-append-only-symptom
```

失败 round 的 marker 运行产物同时满足：

- current marker generation 与 deterministic scope 完全一致；
- current 与 other version bytes 完全一致；
- 没有 unresolved 或 non-local version；
- Apple metadata 已完成上传，且没有上传错误；
- 应用仍回报 `divergentMarkerVersion`。

最小 deterministic 红用例为 `ICloudReplicationRepositoryAuthorityTests.testNativePresenterDoesNotTreatWriterIntentAsDivergence`。它在真实临时文件上登记原生 presenter，以 `NSFileCoordinator` 发出不改 bytes 的 writer intent；旧实现因 `relinquishPresentedItem(toWriter:)` 无条件设置 `authorityChanged = true` 而判红。该用例直接固定用户门禁中的错误类型，不以 mock callback 或 build 成功代替症状。

## 排除的假设

- 不是 deterministic generation 推导错误：只读 probe 的 marker generation 精确匹配同一 scope 推导值。
- 不是两份不同 marker bytes：current 与唯一 other version bytes 相同，且没有 unresolved／non-local version。
- 不是 marker 尚未上传：失败后只读 metadata 已是 uploaded、非 uploading、无 upload error。
- 不是上一轮 iCloud 对象污染：每轮都使用全新 session／round UUID，第二轮尚未启动。
- 不能用 sleep、重试次数或忽略 callback 放行：这些做法会重新打开真实 marker 改变的漏报窗口。
- 不能在 presenter reacquirer 内嵌套普通 coordinator：聚焦运行已经证明该调用图会死锁。

## 根因与破坏机制

`ICloudMarkerVersionPresenter` 把 Foundation 的“发生了需要重新观察的事件”错误建模成“authority bytes 已经改变”。旧实现对 `presentedItemDidChange`、`presentedItemDidGain`、`presentedItemDidLose` 和 writer relinquish 一律设置单一 Boolean；结束时只要该 Boolean 为 true 就抛出 `divergentMarkerVersion`。

这个模型违背 Foundation 回调语义：attribute change、同 bytes version inventory 变化和 writer intent 都是合法事件。它们应触发重新验证，而不是直接成为分歧结论。真实 iCloud 的协调活动触发了该 Boolean，即使最终所有可见 marker bytes 完全相同，post-validation 仍被假阳性覆盖。

## 根因修复

- 用 typed observation verdict 取代无信息量的 `authorityChanged` Boolean：`stable`、`revalidatedEquivalent`、`unavailable`、`divergent`。
- presenter 回调读取实际 current／version bytes；只有与 expected canonical marker 不同的 bytes 才形成 `divergent`，读取失败形成 `unavailable`，相同 bytes 形成 `revalidatedEquivalent`。
- writer relinquish 先按 Foundation 契约放行 writer，只在写入完成后的 reacquirer 采样 current marker；单纯 writer intent 不再直接判定分歧。
- finish 在同一个 coordinated read 内取得最终 local snapshot并注销 presenter，随后排空 presenter queue；这关闭了“最后 snapshot 已读、presenter 尚未移除”的竞态窗口。
- operation 前后的完整 snapshot 继续校验 current、local versions 与 non-local versions。任何不同、非 canonical 或不可读 evidence 仍保持 terminal fail-closed；没有引入 sleep、timeout、fallback、兼容层或远端 rewrite。

## 当前验证结果

- Red（真实症状）：session `84fed39d-2a74-4abb-94ce-527657412215` 首轮回报 `divergentMarkerVersion`，只读 bytes／metadata probe 排除真实分歧。
- Red（fast）：`testNativePresenterDoesNotTreatWriterIntentAsDivergence` 在旧实现稳定失败，且 marker bytes 前后相同。
- Green（聚焦）：`ICloudReplicationRepositoryAuthorityTests` 共 27 项、0 失败；原生 no-op writer intent、真实 bytes 变化、相同 version evidence、不同 version evidence与 unavailable evidence 均已覆盖。
- Green（扩大）：`NoonmarkSyncTests` 共 358 项、0 失败；`LocalFirstReplicationTests` 共 31 项、0 失败。
- Green（fast 聚合）：`scripts/test-replication-bootstrap-concurrency` 共 51 项、0 失败；live reset sentinel、failure-case gate、lint 与 format 均返回 0。
- 待完成：双轴 review、完整 `make check`、签名 App E2E、全新真实 append-only iCloud multi-round symptom、最终 build 绑定、push、hosted CI 与私有 DMG。真实 multi-round 未转绿前，本案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-replication-bootstrap-concurrency` 运行真实 Foundation presenter 的 no-op writer intent 红转绿用例，并继续覆盖 bytes 真正改变、version 分歧、unavailable 与注册／注销平衡；由 `scripts/test-replication-v2-recovery-contract` 纳入 `scripts/check`。
- symptom：`scripts/test-icloud-append-only-symptom` 每次建立一个全新 session 与两个全新 round，要求两轮均通过真实 iCloud 收敛、重启零重复 apply，且后轮不得改变前轮 inventory／digest；由 `scripts/test-icloud-sync-live` 强制调用。旧失败对象永久保留，不清理。

## 发行、风险、回滚、灰度与监控

风险等级为 P：误报会阻断合法同步；若修复过度放宽，又可能漏过真实 marker 分歧。build 40 退役且不得 push、覆盖、重签或分发；营销版本仍为用户指定的 `0.3.1`，只有最终 source 稳定后才分配更高 build。

回滚只允许 revert 独立 observer 修复并继续阻断发行；不得恢复“所有 callback 都等于分歧”的错误模型后强行出包，也不得关闭 authority validation、忽略不同 bytes、增加 sleep／timeout、修改或清理既有 iCloud 对象。

灰度顺序为聚焦 Foundation presenter → 完整 Sync／Storage → `make check` → 签名 `e2e` App → 全新真实 append-only iCloud 双 round → 私有 DMG 第一台 Mac → 第二台实体 Mac → 连续 72 小时 soak。监控只使用 typed verdict、有限 callback／version 数量、同步 state 与用户主动导出的隐私过滤诊断；不得记录路径、version URL、marker bytes、payload、账号或用户正文。

## 教训与永久约束

文件协调 callback 是“需要重新观察”的信号，不是 bytes 已改变的事实。并发安全不能把所有事件无条件升级成 corruption，也不能为了消除假阳性而忽略事件；正确边界是采集实际 evidence、在关闭观察窗口内再做 authoritative snapshot，并让相同 bytes 与不同 bytes 进入不同 typed verdict。

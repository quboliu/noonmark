# FAIL-2026-08-11-24：V2 transport hardlink 混入诊断证据根

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-11T17:52:00-04:00 至 2026-08-11T18:04:00-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 诊断 E2E
- 引入提交：未提交；诊断闭环接入 V2 content-addressed Endpoint 时复用了被归档的 helper repository-lock 父目录
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

诊断真实 App 路径已经完整完成 V2 failure、endpoint wait、mutation、SIGKILL、restart 与 Help 导出，但套件最后仍以非零状态退出，报证据输入不是 owned single-link regular file。若放宽证据 helper，会破坏防 hardlink 边界逃逸；若修改 V2 publisher 不再使用 hardlink，则会破坏零覆盖、零删除约束下的 crash-safe final publication。

## 时间线

- 诊断三进程症状路径第一次转绿后，最终 artifact inventory 失败。
- 对归档树逐文件检查 link count，唯一异常为 V2 repository marker，link count 为 2。
- 源码与运行目录对账确认，这是 append-only publisher 保留 permanent stage 并以 hardlink 原子发布 final key 的预期结果，不是意外重复或资料损坏。
- 首轮目录分离后，真实 App 走到 Help 导出时暴露 helper 的 `.repository.lock` 父目录此前依赖 transport 顺带创建；显式建立该锁目录后完整闭环转绿。

## 复现与证据

- 真实 App 的 seed、stall 与 restart result 均成功，导出包容量和私隐哨兵也通过；失败只发生在 `evidence_inventory`。
- 归档树中 `.noonmark-replication-v2.json` 的 link count 为 2；其他证据文件均为 1。
- `AppendOnlyFilePublisher` 的协议要求 staging 永久保留，并用 exclusive hardlink 使完整 bytes 一次可见；因此同 inode 双链接符合 V2 设计。
- 修复后 `artifacts/e2e-diagnostic-closure` 内所有 regular file link count 均为 1，transport 临时根在 suite 退出后消失，最终 manifest 为 `suite_exit_status=0`。

## 排除的假设

- 不是证据 helper 误报：拒绝 multi-link file 是防归档边界逃逸的必要安全规则，独立反向 fixture 能稳定判红。
- 不是应该删除 permanent stage：用户铁命禁止 iCloud 删除，V2 也依赖永久 stage 完成 crash-safe publication；测试不得发明另一套协议。
- 不是只从 inventory 排除单个 marker 即可：后续任何 announcement／object 都可能是 hardlink；transport 状态整体不属于诊断证据根。

## 根因与破坏机制

诊断 scope 的 `repository_lock` 是外部 helper 用来证明导出时锁边界的证据协调文件；它不是 App 的 V2 replication endpoint。旧脚本以 `${repository_lock%/*}` 同时作为 `--sync-folder-url`，把两个生命周期和安全模型不同的目录错误合并。V2 接入后，正常 transport inode topology 因而进入只接受 single-link regular file 的证据归档器。

## 根因修复

- 诊断 App 的 V2 Local Folder endpoint 改用本轮 shell PID 专属、严格 grammar、fresh、mode 700 的 `/private/tmp` transport 根。
- helper 的 canonical `SyncRepository/.repository.lock` 继续位于诊断证据 scope，但显式创建父目录，且不承载 marker、announcement 或 payload。
- suite exit 对 exact temporary path 做 grammar 与 symlink 检查后回收；拒绝模糊 glob 或宽目录删除。
- evidence helper 保持严格；fast fixture 新建一对真实 hardlink 并要求 inventory 拒绝，防止以后为“修好测试”而放宽安全门禁。

## 验证结果

- `scripts/test-e2e-evidence-contract` 已证明普通单链接 artifact 可归档、真实 multi-link fixture 必须拒绝，并固定诊断 transport 与 evidence scope 分离。
- 真实签名诊断闭环完成 V2 failed-sync → endpoint-wait → mutation-committed → SIGKILL → restart → locked UI export。
- 导出结果为 `ok: restarted evidence exported through UI`；runtime diagnostic result 为零新增 crash；artifact inventory SHA 已写入 manifest，`suite_exit_status=0`。
- 没有遗留 `NoonmarkMacAppE2E`／helper 进程或本轮 transport 临时目录。完整签名 App E2E 运行 `20260812T035748Z-64356` 与 `make check` 运行 `20260812T041033Z-39844` 均以 `suite_exit_status=0` 完成，且运行前后 worktree tree OID 一致。修复提交已回填；实际私有 DMG release gate 尚待本任务后续完成，因此案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-e2e-evidence-contract` 同时固定 multi-link 拒绝与 transport／evidence 分层；由 `scripts/check` 强制调用。
- symptom：`scripts/test-e2e` 运行真实签名诊断三进程、Help 导出及最终 artifact inventory；由 `scripts/test-all` 强制调用。
- release：`scripts/verify-development-validation-evidence` 必须消费带完整 inventory SHA、同 source／run 且 suite 成功的 E2E manifest；由 `scripts/release-private-dmg` 强制调用。

## 发行与回滚

风险等级为 P：涉及诊断私隐、证据完整性、文件 inode 安全及退出清理。完整 inventory 转绿前停止发行。若分层回归，回滚本轮未发行 E2E 改动并保留发行阻断；不得放宽 single-link 规则，也不得删除 V2 permanent stage。灰度只在 Local Folder `e2e` 目录进行；不运行 production 或 iCloud。监控 artifact link-count verdict、inventory SHA、helper lock proof、cleanup result 与 suite status。

## 教训与永久约束

逻辑上都叫 repository 的目录不一定属于同一个安全域。transport 状态可以合法使用 hardlink，证据归档却必须拒绝 hardlink；正确解法是分离所有权与生命周期，而不是削弱任一方的不变量。

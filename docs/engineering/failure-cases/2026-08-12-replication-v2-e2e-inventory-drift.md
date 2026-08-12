# FAIL-2026-08-12-02：Replication V2 E2E 与发行 inventory 漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-12T06:48:00Z
- 影响版本／构建：`0.3.0 (30)` pre-tag candidate；source commit `a428e3f7fa67f2013e84232922e8f8ebd04c3198`；build 30 已退役，修复候选为 `0.3.0 (31)`
- 引入提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 与当前 session 证据不能证明先前提交的实际操作者
- 修复提交：`81e58442a5aa990d59adcf89338b66cafa924eb4`（共享 V2 inventory authority、producer fail-closed 与 build 31 身份）

## 用户症状与影响

用户要求生成 build 30 的本机签名 trial DMG。完整签名 E2E、writer-lease 与 `make check` 均报告成功后，trial 在 runtime evidence verifier 报 `required artifact path is missing` 并在任何构建与最终输出前退出。下载目录没有生成半成品，production App、用户资料与 iCloud repository 均未被读取或修改。

## 时间线

- 2026-08-02：commit `4ad0e1fd` 建立当时 V1 PreferencesClock 的共享发行 inventory。
- 2026-08-12T04:50:04Z：commit `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73` 把真实 PreferencesClock E2E 切到 Replication V2 lifecycle，但没有同步更新共享 inventory，也没有让 E2E producer 在成功前消费它。
- 2026-08-12T05:52:12Z：完整 E2E run `20260812T055211Z-20233` 成功，实际 inventory 包含 V2 lifecycle 产物，没有旧 V1 文件。
- 2026-08-12T06:48:00Z：pre-tag trial runtime verifier 首次消费共享 inventory，因旧文件缺失而 fail-closed。

## 复现与证据

在 clean source commit `a428e3f7fa67f2013e84232922e8f8ebd04c3198` 上执行 `scripts/verify-development-validation-evidence --scope runtime`，稳定在 `artifacts/e2e-preferences-clock/failure-restart-result.txt` 缺失处退出 1。

源码与运行产物对账显示：`scripts/test-e2e` 的当前 `run_preferences_clock_probe` 只生成三阶段 result／log、`input-trace.txt`、`sync-v2-status.png`、`sync-v2-lifecycle.png` 与 SQLite／state／probe；输入轨迹已同时证明 V2 成功、typed failure、join、禁用及重启抑制。`scripts/development-validation-e2e-inventory` 却仍要求独立 failure-restart、旧 `sync-task-summary.png` 与多份 V1 remote-preferences JSON。E2E artifact inventory 如实不含这些未生成文件，但 `finish_e2e_evidence` 只哈希现有目录，没有针对共享发行 inventory 判定缺项。

## 排除的假设

- 不是后续 `make check` 删除证据：缺失文件从未进入该 E2E run 的 artifact inventory，当前 V2 producer 也没有对应输出路径。
- 不是同步功能或真实 App 症状失败：V2 lifecycle SQLite、WindowServer trace、截图、异常状态与重启断言均在真实 E2E 中通过。
- 不是 provisioning、签名或 DMG 构建失败：trial 在 runtime evidence preflight、package 前退出。
- 不是 iCloud materialization：该 PreferencesClock 症状门禁使用隔离 Local Folder endpoint；本轮没有真实 iCloud 写入。

## 根因与破坏机制

E2E producer 与发行 consumer 虽然名义上共享 inventory 函数，producer 实际只把当前存在的整个 artifact 目录写入哈希清单，并不验证共享函数声明的必需集合。V2 cutover 更新了 producer 行为，却遗漏了独立的旧 inventory 名称；静态 contract 又只证明旧名称仍存在，没有证明 producer 会生成或消费它们。因此 E2E 可以签发成功 manifest，错误被推迟到 trial 的发行 verifier。

## 根因修复

共享 inventory 改为 V2 实际的三阶段结果、输入轨迹、SQLite／state／probe 和两张 lifecycle 截图，删除已被 clean cut 淘汰的 V1 artifact 名称。完整 E2E 直接 source 同一 inventory authority，并在 artifact inventory 建立后、成功 manifest 完成前逐项执行 `evidence_require_inventory_paths`；缺项或未被哈希绑定时 E2E 本身立即判红。partial E2E 不声明完整发行证据。

## 验证结果

- Red：旧 source 的 runtime verifier 稳定因 V1 `failure-restart-result.txt` 缺失退出 1，而完整 E2E manifest 错误保持成功。
- Green（fast）：`scripts/test-e2e-evidence-contract`、`scripts/test-release-version-contract`、`scripts/test-release-trial-contract`、`scripts/test-release-trial-output-contract` 与 `scripts/test-failure-case-gates` 已通过；案例登记共 106 个。
- Green（symptom）：待在修复 commit 上重跑完整真实 App E2E。
- Green（release）：待同 run writer-lease、`make check` 与 pre-tag trial runtime／full verifier 通过。

## 永久门禁

- fast：`scripts/test-e2e-evidence-contract`，由 `scripts/check` 强制调用；拒绝旧 V1 inventory 名称并要求完整 E2E producer 消费共享 authority。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用；真实完整 App E2E 在成功 manifest 前逐项验证 V2 release inventory。
- release：`scripts/verify-development-validation-evidence`，由 `scripts/release-private-dmg` 强制调用；对相同 run、source、artifact inventory SHA 与 V2 必需路径独立复核。

## 发行与回滚

build 30 已永久退役，修复候选使用 build 31。修复前不交付新候选，不创建 tag、不 push、不触发 hosted CI、不发布 Release。回滚只撤销 inventory 门禁修复并继续阻断 trial，不恢复 V1 artifact 或兼容路径。灰度顺序保持本机完整门禁、第一台 Mac、第二台 Mac、72 小时 soak；监控 inventory verdict、run ID、source tree、manifest SHA 与 typed release stage，不记录用户正文、路径、账号或 payload。

## 教训与永久约束

共享清单只有在 producer 与 consumer 都在各自成功边界真实消费时才是 authority。静态检查“名称存在”不能证明运行时产物存在；clean cut 移除旧路径时，必须同步删除旧 evidence contract，并让原始症状最早在 producer 处判红。

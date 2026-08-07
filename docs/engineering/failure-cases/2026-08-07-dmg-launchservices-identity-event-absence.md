# FAIL-2026-08-07-01：DMG 运行身份验证器依赖非保证的 LaunchServices 事件

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T05:44:22Z（0.2.4 (10) 候选发行链最终证据对账判红）
- 影响版本／构建：0.2.4 (10) 候选，source commit `aef55124f5d3e3ee2f03af6b1de521731db54101`；不影响已交付版本
- 引入提交：`3d5cc9e80915cd9c8f37a907e84cd3248692e9ae` feat(app): Complete the native experience and consistency acceptance upgrade
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

0.2.4 (10) 候选在 `scripts/release-private-dmg` 的最终跨清单对账阶段被阻断，报告 `DMG install exercise system runtime log has duplicate or contradictory App identity`。真实 `dmg-validation` App 已完成安装、窗口、物理输入、退出、重启、SQLite 回读与诊断导出；阻断发生在证据消费侧，远端 tag 尚未推送。

## 时间线

- 2026-07-18：`3d5cc9e` 新增运行身份对账，要求每个阶段的 unified log 恰好包含一条 `CoreServicesUIAgent ... appInfo=` 事件。
- 2026-08-07：0.2.4 (10) 候选完整发行链中，initial 与 restart 启动取得该事件，exercise 启动没有取得；同一 PID 的 App 自身 LaunchServices cached-info、窗口与 helper ledger 均存在并一致。
- 2026-08-07：fast contract 新增「`appInfo` 缺席但 PID-bound cached-info 一致」和「混入矛盾 cached-info」两向变体，修正证据消费边界。

## 复现与证据

1. 运行同一 evidence run 的 `scripts/release-private-dmg`；DMG 打包、静态验证和 `scripts/test-dmg-install` 全部先通过，最终 `scripts/verify-development-validation-evidence --scope full` 判红。
2. `artifacts/dmg-install/exercise-console.log` 对 exercise PID 的 `appInfo=` 计数为 0；同一日志包含多条由该 PID 输出的 `[com.apple.launchservices:cas] ... cached info`，其中 executable path、bundle identifier 与 bundle path 全部一致。
3. `exercise-ledger.tsv`、窗口 metadata 与 unified log 的进程前缀使用同一 PID；WindowServer 已验证窗口 owner PID，helper 已验证 `NSRunningApplication` bundle identity 与精确路径。
4. fixture 删除 `appInfo` 且不提供 PID-bound cached-info 时，修复后的验证器继续 fail-closed；提供一致 cached-info 时通过；再追加伪造 cached-info 时因身份矛盾判红。

## 排除的假设

- DMG 版本或签名错误：package、mounted App 与派生 validation App 的版本、build、UUID、签名和 source-linked SHA 门禁均已通过。
- App 启动成错误 bundle：WindowServer owner PID、helper activation、App 自身 LaunchServices cached-info 与安装路径一致。
- 飞光 UI 改动引发：完整真实 App E2E 的飞光输入、编辑、删除、筛选、Sticky Note、快捷键、重启和 SQLite 对账已通过；失败发生在其后的 DMG 证据汇总。
- `appInfo` 重复或内容矛盾：原始失败阶段计数为 0，不是重复；旧错误文字合并了缺席、重复与矛盾三种情形。

## 根因与破坏机制

验证器把 `CoreServicesUIAgent` 的单次 LaunchServices 通知当成每次启动都保证出现的协议，并要求计数严格等于 1。同一个已注册 App 的后续启动可以直接采用 LaunchServices shared-memory cached-info，目标进程和窗口均真实存在，但系统不再发出该通知。旧验证器因而把可选事件缺席误判为身份冲突。

## 根因修复

- 保留 `appInfo` 事件的首选强验证：事件存在时仍要求恰好一条、路径与 bundle 全匹配，并从 kernel audit token 反解 PID 对账。
- 仅在 `appInfo` 缺席时，接受目标进程统一日志前缀绑定的 LaunchServices cached-info；要求至少一条，且每一条的 executable path、bundle identifier 与 bundle path 都完全一致。
- 没有任何 PID-bound 身份行、存在多条 `appInfo`、audit token 不匹配或任一 cached-info 矛盾时继续 fail-closed。

## 验证结果

- `scripts/test-dmg-evidence-contract`：通过；覆盖缺席事件的红转绿复现，以及混入伪造 cached-info 的拒绝。
- 完整真实 DMG symptom／release gate：待修复 commit 后以新 evidence run 重跑并回填。

## 永久门禁

- fast：`scripts/test-dmg-evidence-contract`（随 `scripts/check`）覆盖两种严格身份来源、事件全缺失、重复 `appInfo`、伪造 cached-info 与 audit-token/PID 不一致。
- symptom：`scripts/test-dmg-install`（随 `scripts/release-private-dmg`）真实启动同一受控派生 App 的 initial、exercise、restart 与 diagnostic-export 阶段并归档统一日志。
- release：`scripts/test-dmg-install` 与最终 `scripts/verify-development-validation-evidence --scope full` 必须在同一 release evidence run 内通过；production App 不得执行。

## 发行与回滚

0.2.4 tag 在故障发现时仅存在于本机且尚未推送；修复后会重建候选、重跑全部发行证据，再让 tag 指向新的候选 commit。若新分支误接受矛盾身份，回滚验证器与 contract commit，保留 tag 不推送并使用新 build 重新发行。改动只作用于发行证据消费，不改变用户资料、App 运行逻辑或 production 身份。

## 教训与永久约束

- 系统日志中的某一种事件形状不是操作系统承诺的每次启动协议；门禁必须验证稳定语义，不得依赖恰好一次的非保证事件。
- 替代证据不能只是「有日志」：必须绑定目标 PID，并对所有可见身份行做全集一致性检查，任何矛盾都 fail-closed。
- 发行链最后一跳的错误文字必须区分缺席、重复与矛盾，避免把证据采集缺口误诊为 artifact 身份污染。

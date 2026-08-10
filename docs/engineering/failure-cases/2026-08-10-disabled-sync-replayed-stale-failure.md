# FAIL-2026-08-10-03：关闭同步后重放历史全局失败

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-09T02:33:36Z
- 影响版本／构建：0.2.5 build 24，source commit `4d7c2ca52d13dbea8dcf160c1c5d606dc23f6880`
- 引入提交：`e9d007f248b43dfe4b164ecdeac93e173a427912` `fix(sync): Rebuild the complete baseline and eliminate silent false reports`
- Git author／committer：quboliu <38942505+quboliu@users.noreply.github.com>／quboliu <38942505+quboliu@users.noreply.github.com>
- 实际修改者：未知
- 修复提交：`b6cca0b70140fec507384508b90381eacc98b897` `fix(sync): make active runs safely stoppable`

## 用户症状与影响

用户每次退出并重新打开 App 都看到「同步未完成」全局错误及同一个诊断编号，即使同步 policy 已经关闭。本机资料仍保留，但历史 failure 被错误呈现成当前仍需立即处理的 operation failure，造成重复告警并误导用户判断关闭状态。

## 时间线

- 2026-08-09T02:33:36Z：首次从持久化 status 加载同步失败。
- 2026-08-09 至 2026-08-10：持久化 failure 共被加载九次；其中诊断编号 `0D9DD90B` 对应的 correlation 在后续四次 load 中反复出现。这些 load event 不是九次新同步失败。
- 2026-08-10：隔离 App 的 disabled restart 路径在修复前恢复全局 warning，修复后只保留设置页历史详情。

## 复现与证据

Preferences Clock E2E 先持久化 baseline-invalid failure，再关闭同步并正常退出。第二个真实 App process 读取相同 SQLite。修复前 `operationFailureNotice` 与 `settings.operation-failure` 重新出现；修复后 `localFirstSyncMessage` 仍显示历史状态，但全局 notice 不存在。显式重新启用同步后，同一 actionable warning 恢复，成功 retry 后 status 与 warning 一并清除。

## 排除的假设

- 排除每次启动都创建新失败：诊断事件复用相同 operation／incident correlation。
- 排除 status metadata 丢失或损坏：SQLite 能稳定解码同一 failed reason、timestamp 与 correlation。
- 排除应该删除历史失败：设置页仍需让用户查看最近同步状态，只有全局 actionable presentation 应依 policy 抑制。

## 根因与破坏机制

`restoreLocalFirstSyncStatus` 对任何 `.failed` metadata 都无条件调用 `restorePersistedLocalFirstSyncFailure`。该流程没有检查 `localFirstSyncPolicy.enabled`，把「历史状态」与「当前需要用户处理的全局失败」合并。每个 App process 因此在启动时再次发布同一全局 notice。

## 根因修复

status restore 继续保留 `localFirstSyncMessage` 与 typed diagnostic correlation；若 policy 已关闭，则明确 resolve `.sync` 全局 failure 并停止恢复 actionable notice。重新启用时再次依据同一 status 恢复 warning；成功 retry 后清除 stale failure。没有删除或改写历史 metadata。

## 验证结果

修复提交上的 Preferences Clock 与完整真实 App E2E 已完成「失败 → 关闭 → 正常退出 → 重启 suppressed → 重新启用 restored → retry cleared」闭环。`scripts/test-preferences-checkbox-interaction-target-contract`、`make check`、writer-lease E2E、完整 `scripts/test-e2e` 与隔离 worktree 的 `scripts/test-release-diagnostic-closure` 全部转绿。

`scripts/release-private-dmg` 在启动任何 App 或 DMG 动态验证前正确拒绝旧 tag：`v0.2.5` 仍指向原故障 commit `4d7c2ca52d13dbea8dcf160c1c5d606dc23f6880`，不是本修复 commit。最终 DMG gate 必须等待新 release candidate，不能移动既有 tag 或绕过版本门禁，因此案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-preferences-checkbox-interaction-target-contract` 固定 disabled restart suppression 与重新启用路径必须存在于真实 App automation。
- symptom：`scripts/test-e2e` 以两个真实 App process、同一隔离 SQLite 和原生设置页验证 warning 生命周期。
- release：`scripts/verify-development-validation-evidence --scope full` 在私有 DMG 发行前消费同 source/run 的 Preferences Clock 退出与重启证据。

## 发行与回滚

风险等级为 P：涉及启动、退出及用户可见故障状态。回滚只回滚本案例修复提交，不删除 SQLite status 或诊断资料。灰度顺序为 `audit` fast contract、`e2e` 双 process、`dmg-validation`／private DMG。监控 `persistedSyncFailureLoaded` correlation、policy enabled、global sync notice 数量和成功 retry 后 stale status 清理。

## 教训与永久约束

持久化 failure 是历史事实，不等于当前 actionable presentation。恢复全局错误必须同时验证 operation 仍启用；关闭功能时保留历史可见性，但不得把同一个 incident 在每次启动重新包装成新问题。

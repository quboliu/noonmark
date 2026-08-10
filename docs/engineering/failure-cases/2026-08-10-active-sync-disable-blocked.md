# FAIL-2026-08-10-01：活跃同步阻断关闭同步

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-08T02:14:25Z
- 影响版本／构建：0.2.5 build 24，source commit `4d7c2ca52d13dbea8dcf160c1c5d606dc23f6880`
- 引入提交：`e9d007f248b43dfe4b164ecdeac93e173a427912` `fix(sync): Rebuild the complete baseline and eliminate silent false reports`
- Git author／committer：quboliu <38942505+quboliu@users.noreply.github.com>／quboliu <38942505+quboliu@users.noreply.github.com>
- 实际修改者：未知
- 修复提交：`b6cca0b70140fec507384508b90381eacc98b897` `fix(sync): make active runs safely stoppable`

## 用户症状与影响

同步运行期间，任务与飞光修改先后被拒绝三次。用户已经尝试关闭 iCloud 同步，但设置页的「启用同步」复选框没有形成持久化关闭事实；退出与重启后同步仍可继续占有 mutation gate。影响范围包括同步开关、同步期间的普通本机写入、退出握手与下次启动状态。

## 时间线

- 2026-08-08T02:14:25Z：诊断记录首个 task mutation rejection。
- 2026-08-08T02:39:05Z 至 2026-08-08T02:39:12Z：同一同步 operation 下出现两个 idea mutation rejection。
- 2026-08-10：真实签名 App 的最小 WindowServer 路径稳定复现；点击落在原生 checkbox，但状态保持 `syncing=true`、`stopping=false`、`enabled=true`。
- 2026-08-10：收窄 UI disable boundary 后，同一路径转绿。

## 复现与证据

运行 `NOONMARK_E2E_PREFERENCES_CLOCK_ONLY=1 scripts/test-e2e`。隔离 App 先建立待上传记录，再由真实 `flock` 持有 repository lock；同步进入等待后，WindowServer 点击设置页同步复选框。修复前点击没有触发关闭，最终因 policy 未持久化判红。Store API 路径、run controller 单元测试及 transport lock cancellation 测试分别用于区分 UI、生命周期与 transport 层。

## 排除的假设

- 排除用户没有点击正确位置：trace 保存了点击前重新解析的 native checkbox 中心坐标。
- 排除 policy repository 无法保存：相同状态下直接调用 Store API 能取消、保存并在重启后读回。
- 排除 `flock` 无法响应取消：独立 transport 测试持有真实外部锁，取消后不会进入 critical section 或发布 batch。
- 排除普通 task mutation 被错误放行：活跃同步时 task mutation 仍按设计 fail-closed，只有关闭同步是受控生命周期操作。

## 根因与破坏机制

`LocalFirstCloudSyncCard` 在最外层使用 `.disabled(store.isLocalFirstSyncing)`。SwiftUI disabled environment 因此同时禁用了 endpoint、mode、立即同步按钮和唯一能停止同步的复选框；控件自己的条件无法覆盖父层 disabled。Store 又只拥有无句柄 `Task`，transport 使用阻塞式 `flock(LOCK_EX)`，所以即使绕过 UI 调用 policy mutation，也会被同一 exclusive engine gate 拒绝，无法先停止再保存关闭状态。

## 根因修复

同步执行改由单一 `LocalFirstSyncRunController` 持有，提供拒绝重入、取消并等待完成的生命周期。repository lock 改为可取消的非阻塞等待。关闭同步成为「取消 automation／confirmation retry → 停止并等待 active run → 持久化 disabled policy」的顺序协议；App 退出握手也会等待该协议。UI 只禁用活跃同步期间不可改变的 endpoint、mode 与立即同步按钮，停止复选框保持可操作。

## 验证结果

修复提交上的 Preferences Clock 与完整 E2E 均已证明 `task-mutation=blocked → lock-wait=observed → checkbox-disable=cancelled-and-persisted → gate=released`，并从诊断快照对账该 operation 只有一个 `.cancelled` 非失败终态；随后退出／重启保持 disabled。`scripts/test-unit`、`scripts/test-integration`、`make check`、writer-lease E2E、完整 `scripts/test-e2e` 与隔离 worktree 的 `scripts/test-release-diagnostic-closure` 全部转绿。

v0.2.6 build 27 候选在精确 commit `764f781076f72a80ccdefb976617ebb54b66bcda` 和同一 evidence run `release-v0.2.6-b27-20260810T151224Z` 上完成 `make check`、writer-lease E2E、完整 `scripts/test-e2e`、release diagnostic closure 与 `scripts/release-private-dmg`。受控 `dmg-validation` 安装、真实交互、SQLite 持久化、退出和重启全部通过，production App 未执行；fast、symptom 与 release 三类门禁已闭环。

## 永久门禁

- fast：`scripts/test-unit` 固定 run controller 的取消等待与拒绝重入；`scripts/test-preferences-checkbox-interaction-target-contract` 拒绝恢复整卡 active-sync disabled，并固定 sync checkbox 的物理输入锚点。
- symptom：`scripts/test-e2e` 用真实签名 App、WindowServer checkbox、SQLite、repository lock、退出和重启复现用户路径。
- release：`scripts/verify-development-validation-evidence --scope full` 要求同一 source/run 的完整 Preferences Clock 证据进入私有 DMG 发行闭环。

## 发行与回滚

风险等级为 P：涉及并发、数据写入、退出和同步 policy。回滚只回滚本案例修复提交，不操作或删除任何用户 repository；旧格式 repository 保持原状。灰度顺序为 `audit` fast gate、`e2e` 真实 App、`dmg-validation`／private DMG，production 不作为测试入口。监控 typed `operationCancelled`、`mutationRejected`、active operation、policy enabled 状态与重启读回。

## 教训与永久约束

停止控制不得继承被停止 operation 的 disabled environment，也不得作为同一 exclusive mutation 的普通调用者。任何可长期等待的 App operation 必须有单一 task owner、可取消依赖与 termination join；「按钮可见」不等于「用户控制可执行」。

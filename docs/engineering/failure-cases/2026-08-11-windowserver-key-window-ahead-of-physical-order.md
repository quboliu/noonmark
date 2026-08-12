# FAIL-2026-08-11-29：AppKit key window 领先于 WindowServer 物理窗口顺序

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T21:44:00-04:00
- 影响版本／构建：未发行的 schema 19 Replication V2 工作树；共享 Mac E2E 输入驱动
- 引入提交：`3d5cc9e80915cd9c8f37a907e84cd3248692e9ae` `feat(app): Complete the native experience and consistency acceptance upgrade`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同值
- 实际修改者：既有提交的实际修改者未知；本次诊断与共享输入边界修正可由当前 Codex session 和工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

完整签名 App E2E 两次在 native-command Search 真实点击失败。搜索窗口可见且 AppKit 报告为 key window，但 `search.field` mouseDown 后主窗重新成为 key，导致 exercise 或 restart 进程退出 1，阻断完整 E2E 与最终发行前证据。

## 时间线

- 2026-07-18：共享 `WindowServerInputDriver` 建立坐标、AppKit key window、指针 settlement 与 mouse button 状态门禁，但没有验证物理最前窗口。
- 2026-08-11：第一次完整 E2E 在 native-command exercise 第二次 Search 判红；同一 focused 场景随后通过。
- 2026-08-11：再次完整 E2E 在 native-command restart 第二次 Search 以完全相同的 key-window drift 判红；按“同一问题两次失败”纪律停止重跑。
- 2026-08-11：临时 pre-mouseDown 物理命中探针在 focused 第一轮稳定判红，确认目标 search window number 与该点实际 WindowServer hit window number 不同。

## 复现与证据

原症状由 `scripts/test-e2e` 的真实签名 App 路径捕获。两次失败均发生于第二次打开 Search，搜索字段保留第一次查询文字；search 与 main window frame 重叠，目标点位于重叠区域。AppKit 在点击前报告 search 为 key；mouseDown 后实际 key 变为 main。

临时探针使用 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` 在任何 mouseDown 前读取物理命中。focused stress 第一轮立即报告：expected search window 与 actual main window 不同，目标 AppKit 坐标固定落在 search 字段中央。探针因此在 mouseDown 前安全判红，没有产生第二次错误点击。

## 排除的假设

- 不是外部 App 抢焦点：失败后的 key window 属于同一 Noonmark 进程的主窗。
- 不是 Search 结果或同步业务回调：一次发生于 exercise、一次发生于 restart，但都只发生在复用 Search 后的物理点击边界。
- 不是目标 view 消失或坐标漂移：字段可见、尺寸非零、指针坐标 round-trip 和 settled samples 均通过。
- 不是可用 timeout 不足：缺失条件是“物理最前窗口 exact match”，延长只验证 AppKit key 或盲目 sleep 都无法证明 mouseDown 会送给正确窗口。

## 根因与破坏机制

AppKit 的 `isKeyWindow` 可以先于 WindowServer 的物理 z-order 更新。共享输入驱动把“AppKit key + 指针坐标稳定”当作可点击的充分条件；当 search 与 main 重叠时，极短窗口内的 mouseDown 仍会命中下面的 main。原门禁只能在 mouseDown 后观察 key window 已改变，而 post-mouseDown 安全协议又正确禁止重试，因此整轮失败。

## 根因修复

- `WindowServerInputContextContract` 增加 exact physical-target readiness：expected window number 必须有效，指针已稳定，命中 window number 必须完全一致。
- `WindowServerInputDriver.positionPointer` 在原有 30 个采样预算内同时等待坐标与物理目标连续稳定，不增加 sleep、attempt 或 timeout。
- click 在发布 mouseDown 前再次校验 exact physical target；scroll 每个 sample 前同样校验，避免共享边界在其他手势重现。
- 物理目标不符使用 typed before-mouseDown failure；绝不在 mouseDown 后补发第二次点击。
- 临时 `[DEBUG-window-route-3f71]` 探针已经删除，并由 fast gate 禁止回流。

## 验证结果

- regression test 先因 `physicalTargetIsReady` 不存在而稳定编译判红，实施后 1 项、0 失败。
- 修复前临时物理命中门禁在 focused 第一轮立即判红；修复后同一签名 App native-command stress 连续 8／8 轮通过。每轮均覆盖 exercise、restart、两次 Search、真实 WindowServer 点击与 SQLite `1 1 1 1 1` 对账。
- 完整签名 App E2E 运行 `20260812T021133Z-72054` 已通过：48 个场景、英文 10／10、native-command exercise／restart 两次 Search、App／helper binary 与 source start／end 均一致，`suite_exit_status=0`。最终 `make check` 运行 `20260812T022243Z-83938` 也以 `suite_exit_status=0` 结束，104 个故障案例映射通过。修复 commit 已回填，案例标记为「已修复」。

## 永久门禁

- fast：`scripts/test-windowserver-physical-target-contract` 由 `scripts/check` 强制运行，执行 focused unit test，并静态要求真实 hit-test、pre-mouseDown typed gate 与临时 probe 清理。
- symptom：`scripts/test-e2e` 由 `scripts/test-all` 运行完整签名 App，覆盖 native-command exercise／restart 两次 Search 和持久化对账。

## 发行与回滚

- 风险：严格物理 hit-test 可能暴露其他过去被错误窗口截获的手势；这属于门禁纠错，不能以放宽或 post-mouseDown retry 隐藏。
- 回滚：若 AppKit API 在目标 macOS 版本返回不可靠，只回滚未发行的共享输入边界切片并重新设计可观测 hit-test；不得恢复盲点、增加 sleep 或重试已发布的 mouseDown。
- 灰度：focused unit → 8 轮签名 native-command stress → 完整签名 App E2E → `make check`。production 不进入 Agent 验证。
- 监控：仅记录 typed window number、坐标和 verdict，不记录窗口内容、用户资料、账号、路径或凭证。

## 教训与永久约束

1. `isKeyWindow` 是 AppKit 状态，不等于此屏幕点在 WindowServer 的真实 mouseDown 路由。
2. 真实输入门禁必须在副作用前验证物理目标；副作用后发现错误时只能 fail-closed，不能重试。
3. 多窗口重叠场景是 WindowServer 自动化的必要压力条件，不能只在不重叠窗口中验收。

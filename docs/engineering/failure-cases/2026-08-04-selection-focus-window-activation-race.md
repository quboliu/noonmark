# FAIL-2026-08-04-26：Day Todo 指针选择在窗口激活瞬态后发出

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04T20:11:39-04:00
- 影响版本／构建：0.2.1 (build 6)，`f979cd8`
- 引入提交：待确认；UI-entry harness 以后台 `open -W` 启动后未恢复 e2e App 前台身份
- Git author／committer：未知
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

真实 Day Todo 指针选择门禁可在应用窗口仍可见但已不再前台时发出鼠标事件，随后 fail-closed，阻断完整 E2E 发行验证。该问题影响自动化验证的可信度，不改变用户任务资料。

## 复现与证据

隔离命令 `NOONMARK_E2E_SCREENSHOTS_ONLY=1 NOONMARK_E2E_SCENARIOS=day-pointer-selection scripts/test-e2e` 连续两次失败。结果记录为 `appActive=false`、`expectedWindowIsKey=false`、窗口仍 visible，且 `violation=appInactive`。补齐前台握手后，WindowServer 点击可完成但仍报「pointer click did not select the Day row」；view tree 显示原行 anchor 中心不是实际 hit-test 可点击点。`capture_app_screenshot` 对带 UI-entry 结果的场景使用后台 `open -W`，但没有在 automation 于启动后 0.2 秒运行前恢复 e2e App 焦点。

## 根因与破坏机制

UI-entry screenshot harness 使用后台 launch 以等待结果，却遗漏了将固定 e2e bundle 激活为前台；其旧 `activate(ignoringOtherApps:)` 调用在当前 macOS 上只能得到瞬时状态。输入驱动正确拒绝非前台窗口，因此暴露了 harness 的启动前置条件不足；前台修复后，自动化仍错误地将被动几何 anchor 的中心当作行点击点，未先验证真实 hit-test 目标。

## 根因修复

Harness 在发现精确 e2e PID 后只激活 `app.noonmark.mac.e2e`；选择自动化同时以受验证的 FIFO start gate 等待 shell 确认本次 PID 与主窗口号，随后以 macOS 14 `activate(from:options:)` 协调当前前台应用。若系统仍拒绝后台 API 抢占，自动化会在该 App 标题栏发出一次真实 WindowServer 单击以取得前台，确认按键已释放后才开始行点击。它另要求主窗口连续四次（每次 50 ms）保持 active、main 与 key，并通过 `buttonInteractionTarget` 解析真实 hit-test 点击点；点击仍由原有 WindowServer 驱动和实际选中断言验证。

## 验证结果

待回填 isolated symptom E2E、完整 E2E、`make check` 与修复提交。

## 永久门禁

- fast：`scripts/test-selection-focus-activation-contract`
- symptom：`scripts/test-e2e`

## 发行与回滚

完整真实 E2E 未转绿前不推送；可回退修复提交。

## 教训与永久约束

WindowServer 物理输入前的 active/key/main 条件必须是连续稳定状态，不能用一次读取替代。

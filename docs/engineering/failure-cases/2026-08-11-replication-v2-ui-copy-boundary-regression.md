# FAIL-2026-08-11-21：同步恢复文案绕过 typed presentation boundary

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T17:23:41-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 restart 状态恢复初版在 Store 内直接选择中英文文案
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

`make check` 在 UI localization literal guard 判红：上次同步被中断的恢复提示直接写在 `NoonmarkStore+Sync`，绕过 `AppCopy`。当前中英文内容都有提供，因此尚未形成用户可见错语；但继续保留会让 Store 同时承担状态与 presentation 责任，使文案审核、语言覆盖和后续改动无法由统一门禁约束。

## 时间线

- V2 全量真实 iCloud symptom 转绿后执行最终 `make check`。
- unit、integration、system、演示与 simulation 均通过；literal guard 在 production Store 发现新增中文 literal，并拒绝更新审核 baseline。
- 读取 `AppCopy` 与 `NoonmarkStore` 现状后确认，同步设置文案已有统一 typed boundary，只有这条 restart message 旁路。

## 复现与证据

- `scripts/check-ui-localization` 生成 inventory 时新增一条 `NoonmarkStore+Sync.swift` 中文 literal，并以 “Direct production UI copy changed outside AppPresentation/AppCopy” 失败。
- 同一命令在迁移前稳定判红；无需启动 production App，也没有读取任何 production 资料。

## 排除的假设

- 不是审核 baseline 陈旧：新增 literal 的确位于 Store 状态编排层，直接更新 baseline 会固化错误边界。
- 不是缺少英文翻译：原分支同时有英文；问题是 presentation ownership，而不是单一语言内容。
- 不应删除恢复提示：该信息是跨重启用户状态的一部分，修复必须保留功能与双语语义。

## 根因与破坏机制

restart 状态恢复实现直接根据 engine language 选择字符串，没有复用 Store 已有的 `copy: AppCopy` typed seam。状态层因此拥有 production UI literal，破坏 localization inventory 的单一审核入口。

## 根因修复

- 在 `AppCopy` 增加 typed `localFirstSyncInterruptedRecoveryMessage`，集中持有中文与英文。
- `NoonmarkStore+Sync` 只请求该 presentation value，不再判断语言或持有 literal。
- 不更新 literal baseline 来掩盖旁路；让既有 scanner 直接证明 Store 恢复为零新增 UI copy。

## 验证结果

- `scripts/check-ui-localization` 与 `scripts/test-ui-localization-han-contract` 已通过，证明 Store 不再持有新增 production UI literal，中文／英文 scalar 与 scanner 自测试均保持全绿。
- 完整 `make check` 已于本轮通过，审计运行 `20260811T223945Z-98349` 的 `suite_exit_status=0`，且运行前后 worktree tree OID 一致。案例仍因修复提交尚未确定而保持「处理中」。

## 永久门禁

- fast：`scripts/test-ui-localization-han-contract` 验证中文／英文 UI scalar 与 scanner 自测试；由 `scripts/check` 强制调用。
- symptom：`scripts/check-ui-localization` 对 production source inventory fail-closed，任何绕过 `AppCopy`／typed presentation boundary 的新增文案都判红；由 `scripts/check` 强制调用。

## 发行与回滚

当前未发行；完整 `make check` 转绿前停止发版。若 typed copy 迁移改变显示语义，回滚本条未提交改动并重新设计 presentation seam，不得删除提示或更新 baseline 放行。灰度与监控沿用真实 `e2e` restart 路径，只记录 typed stage 与是否显示恢复提示，不记录正文、路径、identity 或 payload。

## 教训与永久约束

状态机可以决定何时显示信息，但不能拥有如何措辞。新增 recovery／incident 状态时，presentation copy 必须与状态字段同时经过统一 typed boundary，不能把双语 ternary 留在 Store 或 Runtime。

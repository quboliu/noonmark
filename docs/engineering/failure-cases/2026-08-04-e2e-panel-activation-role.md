# FAIL-2026-08-04-11：飞光 E2E 把 key panel 错当成 main window

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:16 -04:00
- 影响版本／构建：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` 至 `0d62105`
- 引入提交：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` `feat(ideas): 原生想法记录与置顶、回收站、标签过滤`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

为全局飞光补上分类建议的物理点击后，E2E 在面板已可见且可输入时仍失败为 `idea capture main window did not become active`。门禁无法继续验证真实面板交互，容易被误判为产品窗口未激活。

## 时间线

- 新的全局建议 E2E 首次让共享 click helper 激活 `NSPanel`。
- 运行视图树显示 Noonmark 主窗口 `main=true,key=false`，另有可见 `NSPanel`；面板已经取得 key 身份。
- 激活契约改为普通窗口要求 main+key，`NSPanel` 要求 key，不放宽 App 前台与可见窗口条件。

## 复现与证据

运行飞光专项 E2E。修复前面板建议已经渲染，通用 click 在 mouseDown 前调用 `activate(panel)`，却永远等待 `panel.isMainWindow`。AppKit 的浮动 panel 可以成为 key window，但 main window 仍是文档主窗口，因此条件不可能成立。

## 排除的假设

- 不是产品面板没有打开：`NSPanel visible=true` 且编辑器已接收真实输入。
- 不是 App 没在前台：`NSApp.isActive` 为 true。
- 不是应取消真实激活检查：物理输入仍必须验证 App active 与目标 key window，只需尊重窗口角色。

## 根因与破坏机制

E2E helper 把 `isMainWindow && isKeyWindow` 当成所有 `NSWindow` 子类的统一激活定义。这个前提只适用于主工作窗口，不适用于 utility `NSPanel`，使合法状态被测试基础设施拒绝。

## 根因修复

共享激活 helper 先判断窗口角色：`NSPanel` 只需成为 key，其他窗口仍需 main+key；两者都继续要求 App active。随后以真实 WindowServer 点击面板建议并完成发布。

## 验证结果

- 原始激活错误消失。
- 全局面板建议物理点击、发布、主窗口回归及 SQLite 对账通过。
- 完整 `make check` 尚待最终执行。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，保留明确的 `NSPanel`／main-window 角色条件。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，从真实全局面板物理点击建议；激活、mouseDown 或目标窗口身份漂移即判红。

## 发行与回滚

只影响 `e2e` automation，不改变 production window 逻辑。若回归，停止接受面板交互证据，不得删除前台／key-window 校验来求绿。

## 教训与永久约束

窗口激活是角色化状态，不是单一布尔公式。E2E 必须表达 AppKit 的 main 与 key 语义，同时保持物理输入前置身份严格。

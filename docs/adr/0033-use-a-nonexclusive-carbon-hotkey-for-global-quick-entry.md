# ADR 0033：使用非独占 Carbon hotkey 提供全局快速记录

## 状态

已接受。

## 情境

应用内 `⌘N` 由 `NSMenuItem` 和 responder chain 处理，只有晷迹位于前台时才会收到。用户需要在其他 App 工作时直接打开快速记录，但不希望为一个快捷键授予 Accessibility 或 Input Monitoring 权限，也不希望晷迹覆盖其他 App 的设置。

macOS 能列出 Keyboard Settings 中已经启用的系统 symbolic hotkeys，却没有公开接口枚举所有第三方 App 的自定义快捷键。因此“保存前保证绝无冲突”不是可兑现的产品承诺。

## 决策

- 保留应用内 `⌘N`，另外提供默认启用的全局 `⌃⇧N`。
- 使用 `RegisterEventHotKey` 和 `kEventHotKeyNoOptions` 注册非独占 hotkey；不使用 exclusive 选项、`NSEvent` global key monitor、event tap 或 Accessibility 权限。
- 全局组合至少包含两个修饰键，并包含 Control 或 Command；按键范围为字母、数字和 Space。
- 从已安装的真实主菜单生成晷迹自身命令目录，并在保存前拦截这些命令和 `CopySymbolicHotKeys` 返回的已启用系统组合；读取系统组合失败时 fail-closed，不把未知状态显示为无冲突。第三方 App 冲突只能明确说明并由用户在常用 App 中试按。
- 改键采用事务性切换：先成功注册候选组合，再注销旧组合并持久化；注册或校验失败时，旧组合继续有效。
- Carbon event handler 无法安装时不得终止 App；注册入口返回失败，由设置页显示真实状态。
- 快捷键偏好只保存在本机 `UserDefaults`，不进入任务数据库、数据包或同步。
- 全局触发只打开 Quick Entry panel。重复触发保留草稿；提交或取消后恢复此前前台 App；不打开已经关闭的主窗口。
- hotkey 只在晷迹进程运行时有效；完全退出后失效。

## 影响

- 优点：不新增敏感权限，不独占系统输入，窗口关闭后仍可快速记录。
- 限制：若其他 App 使用同一非独占组合，两个 App 可能同时响应；若对方使用独占注册，晷迹可能收不到事件。设置页必须持续展示这个边界。
- 键盘布局改变后，组合仍绑定用户录制时的物理 virtual key；设置页以晷迹支持的稳定按键集合展示。

## 验证

- `NoonmarkMacRuntimeTests` 覆盖默认值、物理 virtual key 映射、显示文本、损坏偏好 fail-closed、系统检查不可用、硬冲突、禁用和注册失败保留旧组合。
- 真实 `.app` E2E 先对账实际主菜单生成的冲突目录，再通过设置页录制新组合，证明旧注册已移除；随后关闭主窗口、激活 Finder、由 WindowServer 发送新组合、连续触发、输入和 Return，并验证任务唯一落库、主窗口不重开及 Finder 焦点恢复。
- 完整 `scripts/test-e2e`、`make check` 和 DMG 安装测试继续作为发布门禁。

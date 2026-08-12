# FAIL-2026-08-11-05：飞光行内操作被测试误判为滑动操作

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:52:25-04:00
- 影响版本／构建：iOS 初版开发构建；source commit `012aa8595db51d42d60f6c59515a6939acf98a32` 之后的未提交工作树
- 引入提交：待回溯；故障由当前未提交的 Simulator UI gate 暴露
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（基线提交记录）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

飞光生命周期 Simulator gate 在创建成功后无法找到“加入 Sticky Note”按钮。App 仍在运行，飞光内容已经存在；没有证据表明用户路径本身不可用。

## 时间线

1. 修复页面切换等待后，focused gate 进入飞光操作阶段。
2. 测试对飞光正文执行 `swipeLeft()`，随后查找“加入 Sticky Note”失败。
3. 源码证实飞光行使用普通 HStack inline Button，没有声明 `.swipeActions`。
4. 测试改为直接等待并点击实际渲染的 inline button。

## 复现与证据

- 固定设备：`Noonmark iPhone 17 Pro`，iOS Simulator 26.3.1，bundle `app.noonmark.ios.development`。
- focused `xcodebuild test` 结果：创建飞光通过；失败位于 `NoonmarkIOSUITests.swift:98` 的“加入 Sticky Note”存在性断言。
- `IOSFlylightPage.swift` 运行对应源码：飞光行的置顶、移除和删除均为普通 `Button`，没有 `swipeActions` 修饰符。

## 排除的假设

- 不是飞光创建事务失败：正文已在 hierarchy 中出现。
- 不是 Sticky Note 领域接口失败：失败发生在点击置顶之前。
- 不是应用退出或生产身份串线：XCTest 仍能读取 development bundle 的页面 hierarchy。

## 根因与破坏机制

测试动作模型与真实 UI contract 不一致：`swipeLeft()` 会改变行的可见位置，但不会为没有 `.swipeActions` 的普通行创建操作按钮，因此后续的按钮查询不代表用户实际看到的操作入口。

## 根因修复

测试直接等待并点击飞光行已经渲染的 inline Button，删除置顶、Sticky Note 移除和回收站路径也使用同一真实入口；不向 App 添加重复 swipe action 或隐藏兼容层。

## 验证结果

补丁后的 focused symptom gate 已通过；完整 `scripts/test-ios-simulator` 亦以 8 项、0 failures 通过，确认真实 inline Button 完成置顶／移除、删除、恢复、编辑和重启回读。修复提交待回填，案例继续保持“处理中”。

## 永久门禁

- `scripts/test-ios-target-contract`：保持飞光 lifecycle 测试入口存在并纳入聚合门禁。
- `scripts/test-ios-simulator`：固定 iPhone Simulator 必须通过真实 inline 操作完成飞光创建、置顶／移除、删除、恢复、编辑和重启回读。

## 发行与回滚

当前没有 iOS 发行入口。若回滚测试修复，必须继续按 `IOSFlylightPage` 的真实 inline Button contract 验收；不得以不存在的 swipe action 冒充用户路径。

## 教训与永久约束

UI 测试动作必须来自实际 accessibility hierarchy 和源码渲染 contract。元素支持滑动并不代表滑动后会产生操作按钮；新增交互前必须先确认控件的真实修饰符和命中区域。

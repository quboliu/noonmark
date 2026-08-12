# FAIL-2026-08-11-04：飞光页面切换后的创建入口竞态

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:49:25-04:00
- 影响版本／构建：iOS 初版开发构建；source commit `012aa8595db51d42d60f6c59515a6939acf98a32` 之后的未提交工作树
- 引入提交：待回溯；故障由当前未提交的 Simulator UI gate 暴露
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（基线提交记录）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

飞光生命周期 UI gate 在目录切换刚完成时立即寻找“新建飞光”，未等待飞光页面内容进入 accessibility hierarchy，导致测试无法点击创建入口；该次运行没有发现 App 进程崩溃或数据损坏。

## 时间线

1. 全量 iPhone Simulator 测试执行到飞光置顶／恢复／删除场景时失败。
2. XCTest 的 failure message 证明页面仍暴露目录 sheet 的按钮，尚未暴露“新建飞光”。
3. 对照相邻的飞光创建／搜索场景，确认它在同一切换后先等待“新建飞光”存在。
4. 为生命周期场景补充同一真实元素等待，保留症状门禁继续验证。

## 复现与证据

- 固定设备：`Noonmark iPhone 17 Pro`，iOS Simulator 26.3.1，bundle `app.noonmark.ios.development`。
- 原始运行产物：`Test-NoonmarkIOSApp-2026.08.11_15-46-01--0400.xcresult` 显示 8 项 UI 测试中 1 项失败。
- 失败点：`NoonmarkIOSUITests.swift:86`，`Failed to tap "新建飞光" Button`；hierarchy 中仍只有目录和页面按钮。
- 对照证据：同文件飞光创建／搜索场景在点击前执行 `waitForExistence(timeout: 10)`，该场景通过。

## 排除的假设

- 不是 SQLite 或飞光领域事务失败：失败发生在创建动作之前。
- 不是 App 进程退出：XCTest hierarchy 仍能取得 `app.noonmark.ios.development` 的活跃页面元素。
- 不是生产资料串线：runner 只启动 iOS development bundle，并使用固定 Simulator profile。

## 根因与破坏机制

UI 测试把异步页面切换当成同步操作。目录 sheet 的 dismissal 与飞光页面渲染之间存在真实状态边界；没有等待用户可见的创建按钮时，下一次 tap 可能仍在旧的目录 hierarchy 中查找。

## 根因修复

在生命周期测试中等待真实的“新建飞光”按钮存在后再点击。该修复同步了测试的操作顺序与用户实际可操作状态，不改变 App 业务逻辑，也不引入固定 sleep 或重试阈值。

## 验证结果

补丁后的 symptom gate 已在固定 `Noonmark iPhone 17 Pro` 的完整 `scripts/test-ios-simulator` 中转绿；8 项、0 failures，包含飞光页面等待、创建、Sticky Note 置顶／移除、恢复、删除和重启回读。修复提交待回填，案例继续保持“处理中”。

## 永久门禁

- `scripts/test-ios-target-contract`：保持真实飞光 lifecycle 测试与 iOS target contract 登记。
- `scripts/test-ios-simulator`：固定 iPhone Simulator 必须等待飞光页面真实出现，并完成创建、Sticky Note 置顶／移除、恢复、删除和重启回读。

## 发行与回滚

当前没有 iOS 发行入口。若回滚测试修复，必须恢复对真实创建按钮的存在性等待；不得用固定 sleep 或跳过该生命周期路径代替同步。

## 教训与永久约束

SwiftUI 页面切换必须以真实 accessibility 元素作为下一步操作的前置条件。新增 Simulator UI 场景不得在导航动作后直接 tap 下一个页面的控件。

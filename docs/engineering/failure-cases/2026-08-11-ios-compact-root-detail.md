# FAIL-2026-08-11-02：iPhone compact 根容器只显示目录不显示内容

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T14:00:00-04:00（最小已知时间）
- 影响版本／构建：iOS 初版开发构建；source commit `012aa8595db51d42d60f6c59515a6939acf98a32` 之后的未提交工作树
- 引入提交：待回溯；故障首次在 iOS target 初次运行时由当前工作树引入
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（基线提交记录）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

iPhone compact width 启动后只显示侧边目录；今日 Todo 的 composer 与任务内容没有进入可用的 detail 树，因此用户无法创建任务。

## 时间线

1. 首次 iOS UI 测试在真实 Simulator 启动后，composer accessibility 查询超时。
2. XCTest accessibility hierarchy 证明 `NavigationSplitView` 只挂载 sidebar，detail 没有渲染。
3. 将 compact 根容器改为 `NavigationStack`，目录改为 sheet，保留 iPad regular 的 `NavigationSplitView`。
4. 三个真实 Simulator UI 场景全部转绿。

## 复现与证据

- 原始症状：`testUserCanCreateAndPersistTodayTask` 找不到 `ios.composer.记录今天要推进的任务`。
- 运行证据：第一次 `xcodebuild test` 的 XCTest accessibility hierarchy 只有目录元素，没有 composer。
- 修复后证据：`make test-ios-simulator` 在固定 `Noonmark iPhone 17 Pro` 上执行今日任务创建、强制终止、重启回读并通过；同一套件的重复计划与飞光路径也通过。

## 排除的假设

- 不是 SQLite 保存失败：任务创建路径在容器修复后可写入并跨重启回读。
- 不是 bundle identity 串线：UI 测试只启动 `app.noonmark.ios.development`。
- 不是 XCTest 等待时间不足：增加等待不能改变缺失的 detail accessibility subtree。

## 根因与破坏机制

iPhone compact width 仍使用双栏 `NavigationSplitView`。在没有可见 detail column 的初始状态下，SwiftUI 只将 sidebar 作为根内容暴露给 XCTest，导致首页真实内容没有进入用户路径。

## 根因修复

compact width 使用 `NavigationStack` 直接承载 detail，并通过 toolbar 打开目录 sheet；regular width 继续使用双栏 split view。测试 helper 使用稳定 page identifier，并在中等高度目录 sheet 中执行真实滚动。

## 验证结果

修复后的真实 Simulator 运行报告：iOS smoke test 1 项通过，UI test 3 项通过，0 failures；产物包括 XCTest result、运行日志和 `artifacts/ios-simulator-final.png`。

## 永久门禁

- `scripts/test-ios-target-contract`：静态约束 compact root 与症状测试存在。
- `scripts/test-ios-simulator`：真实 iPhone Simulator 创建任务、强制终止、重启回读及页面交互。

## 发行与回滚

当前没有 iOS 发行入口。若修复回滚，必须保留 Mac target，并恢复 iPhone compact 的可用单栏 detail 入口；不得把 `NavigationSplitView` 重新用于 compact 根路径。

## 教训与永久约束

iPad 的多栏架构不能直接移植为 iPhone 根容器。任何 iOS 首屏容器调整都必须同时覆盖 compact/regular 分支，并由真实 Simulator symptom gate 验证可见内容和持久化路径。

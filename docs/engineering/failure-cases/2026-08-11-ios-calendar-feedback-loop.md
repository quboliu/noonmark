# FAIL-2026-08-11-03：iPhone 日历长滚动触发递归布局并退出

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:38:26-04:00
- 影响版本／构建：iOS 初版开发构建；source commit `012aa8595db51d42d60f6c59515a6939acf98a32` 之后的未提交工作树
- 引入提交：待回溯；故障首次在当前未提交 iOS 日历页面运行时出现
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（基线提交记录）
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

iPhone Simulator 打开日历后向上滚动到日复盘区域时，应用因 UIKit collection view 自适应高度递归布局而退出，用户无法打开日复盘或完成保存回读。

## 时间线

1. 日复盘真实 UI gate 首次在日历页寻找“编辑日复盘”时，应用在滚动操作期间退出。
2. XCTest 记录“application is not running”，随后 Simulator system log 给出 `UICollectionViewFeedbackLoopDebugger` recursive layout loop 的 fatal error。
3. 源码确认日历页以 `List` 承载 LazyVGrid、统计和动态轨迹；改为长 `ScrollView` 与稳定的 VStack/LazyVGrid 结构。
4. 待固定 Simulator symptom gate 重新通过后回填修复提交并改为“已修复”。

## 复现与证据

- 原始症状：`testUserCanSaveDailyReviewAndReadItAfterRestartInSimulator` 在 `app.swipeUp()` 期间收到“Failed to application app.noonmark.ios.development is not running”。
- 运行产物：Simulator system log 在 `Noonmark` 进程中记录 `UICollectionViewFeedbackLoopDebugger`，并以 `Fatal error` 报告 stuck recursive layout loop。
- 证据环境：固定 `Noonmark iPhone 17 Pro`，iOS Simulator 26.3.1，bundle `app.noonmark.ios.development`。

## 排除的假设

- 不是复盘保存事务失败：进程在进入复盘前、测试滚动期间已退出。
- 不是 XCTest 等待不足：失败伴随应用进程退出和 UIKit fatal log，不是元素查询超时。
- 不是生产资料或 bundle 串线：runner 只启动 iOS development bundle。

## 根因与破坏机制

日历页的 SwiftUI `List` 通过 UICollectionView 承载估算高度 cell；页面同时包含网格、动态统计内容和动态轨迹行，向上滚动时 cell preferred size 反复在不同值之间失效，触发 UIKit 递归布局保护并终止进程。

## 根因修复

将日历页面改为长 `ScrollView`，内部使用固定结构的 VStack、LazyVGrid 和内容区块，继续提供月切换、日期选择、统计、日复盘和当天轨迹；不增加等待、阈值或跳过逻辑。

## 验证结果

修复后的 App 编译已通过；固定 `Noonmark iPhone 17 Pro` 的日历长滚动、复盘保存和强制终止／重启回读路径已在完整 `scripts/test-ios-simulator` 中通过，8 项、0 failures。修复提交待回填；当前状态保持“处理中”。

## 永久门禁

- `scripts/test-ios-target-contract`：检查日历页长滚动结构和复盘重启症状测试存在。
- `scripts/test-ios-simulator`：固定 iPhone Simulator 真实滚动到日复盘、保存、强制终止、重启和回读。

## 发行与回滚

当前没有 iOS 发行入口。若修复回滚，必须保留可滚动的日历复盘入口并恢复等价的稳定布局；不得恢复已证明会触发递归布局的 List 结构。

## 教训与永久约束

iOS 长页面的 SwiftUI List 不是无条件安全的布局容器。包含网格与动态高度内容的页面必须走真实长滚动 Simulator gate，不能只验证首屏元素存在。

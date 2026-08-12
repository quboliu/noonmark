# FAIL-2026-08-12-09：iOS 数据包导出文件面板不呈现

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-12T05:08:30-04:00
- 影响版本／构建：`app.noonmark.ios.development`，固定 iPhone Simulator，source `232f7c2`
- 引入提交：`00c17fa8b1d48e1c6b3dc1af8f89dc3c63fbdb6a`（`feat(ios): add iOS parity target and import flow`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：`5985376468baee43052cedfcbf1cd83e26122f4a`

## 用户症状与影响

在 iOS 设置页点击「导出 Noonmark 数据包」后，真实 Simulator 没有出现系统文件保存面板，用户无法把本地 JSON 数据包导出到文件位置。故障只影响 iOS 本地数据包导出入口；不涉及 Mac 同步、iOS 本地 SQLite 数据读取或数据包完整性校验。

## 时间线

1. iOS 首个数据包入口使用 SwiftUI `fileExporter` 与 `FileDocument`。
2. 固定 Simulator 的独立导出症状测试判红；随后用同一运行时重复验证，排除了“先打开导入面板再打开导出面板”的状态串扰。
3. 访问性层级显示设置页仍在前台，未出现文件面板。
4. 改为 UIKit `UIDocumentPickerViewController` 后，真实层级出现 `Browse View (Picker)`、`File View` 与系统取消入口；导入／导出连续打开和取消路径转绿。

## 复现与证据

复现命令：

```text
xcodebuild test -project NoonmarkIOS.xcodeproj -scheme NoonmarkIOSApp -destination 'id=6C6FA7CE-F5B5-4881-9B3D-2CE9A7177F3D' -only-testing:NoonmarkIOSUITests/NoonmarkIOSUITests/testUserCanOpenAndCancelDataPackageExportInSimulator
```

原始失败证据是测试点击导出后未找到文件面板；失败时 hierarchy 仍只有晷迹设置页。补充运行中观察到原生 picker 的 hierarchy 含 `CollectionView`（`File View`）、`On My iPhone is Empty` 和系统 `Cancel` 节点，证明修复路径进入了真实文件面板而非静态占位。

## 排除的假设

- 不是导入取消后残留状态：独立只执行导出的测试同样判红。
- 不是编译失败或测试假绿：原实现能 build，但真实用户路径没有文件面板；修复后由真实 Simulator UI test 观察面板并完成取消。
- 不是同步状态或生产资料：测试固定使用 development bundle，数据包路径只访问本地缓存与系统文件面板。

## 根因与破坏机制

当前 iOS 运行时下，数据包的 SwiftUI `fileExporter`／`FileDocument` presentation seam 没有把导出请求呈现为可交互的系统文件保存面板。由于这个 seam 只暴露了绑定状态而没有可观测的 presenter 失败原因，应用表面上没有错误，但用户路径实际被静默截断。

## 根因修复

数据包路径改为显式的 UIKit `UIDocumentPickerViewController`：导出先写入 application caches 下的规范 JSON 临时文件，再通过系统 export picker 交给用户选择保存位置；导入通过 opening picker 选择 JSON，先显示确认 alert，再进入既有完整性校验和事务性 SQLite 替换。picker 结束时清理导出临时文件，取消动作不显示错误。

## 验证结果

修复提交 `5985376468baee43052cedfcbf1cd83e26122f4a` 已完成，原始症状已转绿。已取得的症状证据：

- `testUserCanOpenAndCancelDataPackageExportInSimulator`：真实文件保存面板打开并取消，0 failures。
- `testUserCanOpenAndCancelDataPackageFileFlowsInSimulator`：真实导入面板打开／取消后再打开导出面板并取消，0 failures。
- iOS app generic Simulator build：通过。

## 永久门禁

- `fast`：`scripts/test-ios-target-contract`，由 `scripts/check` 强制调用，检查原生 picker、状态请求和稳定 UI test 入口存在。
- `symptom`：`scripts/test-ios-simulator`，由 `scripts/test-all` 强制调用，真实 Simulator 打开并取消数据包导入／导出文件面板。

## 发行与回滚

- 风险：导出临时文件位于 development app caches，picker 成功或取消后都会清理；导入仍在确认后才替换本地数据，校验失败保留当前数据。
- 灰度：只在 `app.noonmark.ios.development` Simulator／development 真机 profile 验证，不触碰 production bundle 或同步资料。
- 监控：只呈现导出成功、导入摘要和用户可读错误；不记录数据包正文、文件路径或同步 payload。
- 回滚：回滚包含原生 picker、Store 请求状态、设置页入口与对应症状门禁的同一提交；回滚后不得宣称 iOS 数据包导出可用。

## 教训与永久约束

SwiftUI presentation modifier build 成功并不代表系统文件 UI 已经呈现。涉及系统文件面板的能力必须在固定 Simulator 走真实 tap、观察系统 hierarchy、完成取消或选择，并把症状 gate 纳入聚合门禁。

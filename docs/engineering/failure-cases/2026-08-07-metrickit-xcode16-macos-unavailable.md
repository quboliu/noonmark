# FAIL-2026-08-07-05：MetricKit metric callback 在 Xcode 16 macOS SDK 不可编译

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T15:24:00Z
- 影响版本／构建：v0.2.4 build 12，source commit `895caff49b7f1ecc975d5eb6cdba8303dca9e117`
- 引入提交：`545c743ab67254d623ca9df5260508518d1fcd05`（`feat(diagnostics): Integrate bounded MetricKit diagnostics`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`84b6127983f3a07bf28d153aec0be3752e542bc2`（`fix(release): validate hosted publication boundaries`）

## 用户症状与影响

普通 GitHub CI 在全新 Xcode 16.4／Swift 6.1.2 环境编译 `NoonmarkDiagnostics` 时失败，因而没有进入测试和 E2E。错误阻断 build 12 发行，但没有启动 App、修改 SQLite、读取 production 资料或改变已经构建的本机 DMG。

## 时间线

- 2026-07-31：`545c743a` 同时加入 metric 与 diagnostic 两个 subscriber callback。
- 2026-08-07T15:24:00Z：GitHub CI job `92911860424` 在干净构建中首次暴露 SDK 差异。
- 同一 source 在本机 Xcode 26.2／Swift 6.2.3 的全新隔离 scratch build 通过，确认问题不是陈旧 `.build` 缓存，而是两个 SDK 的真实可用性差异。

## 复现与证据

GitHub run `31192298891` 显示 Xcode 16.4、Swift 6.1.2；编译器对 `MetricKitDiagnosticSubscriber.swift:105` 报告：`MXMetricPayload is unavailable in macOS`，并进一步报告对应 `didReceive` 无法 override。错误在多项目标编译中稳定重复。

本机以新的 `--scratch-path` 只构建 `NoonmarkDiagnostics`，在 Xcode 26.2 成功，证明 Xcode 26 SDK 已提供该 macOS callback。两份运行产物共同把根因限定为 SDK availability 边界。

## 排除的假设

- 不是业务测试失败：编译器在测试启动前退出。
- 不是偶发缓存损坏：GitHub 是全新 checkout，本机全新 scratch build 也稳定通过自身 SDK。
- 不是整个 MetricKit 在 macOS 不可用：Xcode 16.4 只拒绝 `MXMetricPayload` callback；`MXDiagnosticPayload` callback 仍是 macOS 支持路径。
- 不是需要删掉诊断资料格式：typed summary、缓存、隐私过滤与导出格式不依赖该回调的编译可用性。

## 根因与破坏机制

macOS 14 Swift Package 同时需要在 canonical hosted Xcode 16.4 与本机 Xcode 26.2 构建，但 subscriber 无条件引用了只在较新 SDK 对 macOS 开放的 `MXMetricPayload` protocol method。现有 selector 测试也无条件要求两个 callback，错误地把 Xcode 26 的能力当成所有受支持编译器共有的能力。

## 根因修复

以 `#if compiler(>=6.2)` 包围 metric callback：Xcode 26 保留 metric 与 diagnostic 两条真实回调，Xcode 16.4 编译 macOS 实际支持的 diagnostic callback。typed `.metric` 数据结构、缓存与导出兼容继续保留，不引入迁移或降级格式。selector 测试按同一编译器边界验证真实 runtime selector；新增静态 contract 防止 callback 再次越过边界。

## 验证结果

- Red：Xcode 16.4 hosted clean build 对旧实现稳定报出 unavailable 与 cannot override。
- Green（本机新 SDK）：修复前的 Xcode 26.2 隔离 target build 已通过，作为保留新 SDK 能力的基线；修复后 8 个 `MetricKitDiagnosticSubscriberTests` 全绿，确认新 SDK 的 metric 与 diagnostic selector 都继续存在。
- 待 Green（受害路径）：build 13 的 Xcode 16.4 hosted `scripts/check` 必须完成编译与测试；tag workflow 必须用同一 hosted toolchain 打出 canonical DMG。

## 永久门禁

- fast：`scripts/test-metrickit-sdk-compatibility-contract`，由 `scripts/check` 强制调用，固定 callback 与 selector test 的编译器边界。
- symptom：`scripts/test-unit`，由 `scripts/check` 强制调用；在 hosted Xcode 16.4 对所有相关 target 与 SDK-aware selector 行为进行真实编译和测试。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用，只有 hosted check、打包及两个公开资产全部成功才通过。

## 发行与回滚

build 12 已因本故障与独立 workflow 故障退役。build 13 先经过 Xcode 16.4 普通 CI，再建立 tag。若条件编译在新 SDK 丢失 metric selector，回滚该修复并继续阻断发行；不得用删除全部 MetricKit、跳过 hosted build 或放宽 CI 代替根因修复。

## 教训与永久约束

`Package.swift` 的最低平台不等于所有 Xcode SDK 暴露相同 framework surface。跨 Xcode 的系统 framework callback 必须显式表达可用性边界，并同时验证旧 SDK 能编译、新 SDK 不损失能力；本机构建缓存或单一 SDK 绿色不能代替 canonical hosted toolchain 证据。

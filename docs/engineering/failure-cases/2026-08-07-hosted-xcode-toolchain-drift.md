# FAIL-2026-08-07-05：hosted workflow 未绑定项目 Xcode 26.2 基线

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T15:24:00Z
- 影响版本／构建：v0.2.4 build 12，source commit `895caff49b7f1ecc975d5eb6cdba8303dca9e117`
- 引入提交：`545c743ab67254d623ca9df5260508518d1fcd05` 引入需要当前项目 SDK surface 的 MetricKit callback；`57423085d5ab1f0c739dc96db9d5e78ec10d582d` 与 `b1f609c1e5d7403a3bc44c4fe735430e94dc406c` 分别让普通 CI 与 Release 使用 `macos-15` 默认 Xcode 而没有绑定项目工具链
- Git author／committer：三项提交均为 `quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

普通 GitHub CI 在全新 hosted 环境编译 `NoonmarkDiagnostics` 时失败，因而没有进入测试和 E2E。错误阻断 build 12 发行，但没有启动 App、修改 SQLite、读取 production 资料或改变已经验证的产品源码。

## 时间线

- 2026-07-05：普通 CI 固定 `macos-15`，但只打印默认 Xcode，没有选择项目工具链。
- 2026-07-31：`545c743a` 加入 Xcode 26 macOS SDK 已支持的 metric 与 diagnostic subscriber callback。
- 2026-08-06：hosted Release 同样使用 `macos-15` 默认 Xcode。
- 2026-08-07T15:24:00Z：GitHub CI job `92911860424` 实际选择 Xcode 16.4／Swift 6.1.2，在干净构建中暴露工具链漂移。
- 最初把 Xcode 16.4 当成兼容目标并加入条件编译；在推送前对账项目基线与 GitHub 官方 runner image 清单后推翻该假设：`macos-15` 已安装 `/Applications/Xcode_26.2.app`，无需修改产品源码，只需精确选择既有工具链。临时条件编译随即撤销，没有进入远端。

## 复现与证据

GitHub run `31192298891` 的 Toolchain step 明确输出 Xcode 16.4、Swift 6.1.2；随后编译器对 `MetricKitDiagnosticSubscriber.swift:105` 报告 `MXMetricPayload is unavailable in macOS` 与对应 override 不可用。

同一 source 在本机 Xcode 26.2／Swift 6.2.3 的全新隔离 scratch build 成功，8 个 MetricKit subscriber test 全绿并证明两个 callback selector 都存在。GitHub 官方 `actions/runner-images` 的 `macos-15` 与 `macos-26` image 清单都列出 Xcode 26.2 路径；因此受害路径可以在同一 hosted runner 上选择与项目完全一致的工具链。

## 排除的假设

- 不是产品功能或资料模型故障：编译器在 App 和测试启动前退出，production 资料没有接触。
- 不是需要删除 MetricKit metric callback：Xcode 26.2 的全新构建与 runtime selector test 都证明该能力有效。
- 不是 `macos-15` runner 缺少所需 Xcode：官方 image 清单明确提供 Xcode 26.2。
- 不是偶发缓存损坏：GitHub 是全新 checkout，本机全新 scratch build 也稳定复现自身工具链结果。

## 根因与破坏机制

项目运行基线、开发机和本地发行证据都使用 Xcode 26.2，但两个 hosted job 只指定 OS image，依赖 image 的可变默认 Xcode。默认值当时是 Xcode 16.4，导致 canonical hosted path 与本地实际产品工具链不是同一个编译边界。既有门禁只打印版本，没有对版本 fail-closed，也没有把普通 CI 与真实 App E2E evidence 绑定到同一个 run ID。

## 根因修复

普通 CI check job 与 canonical Release job 都以 job 级 `DEVELOPER_DIR` 精确选择 `/Applications/Xcode_26.2.app/Contents/Developer`，Toolchain step 继续打印版本并明确断言第一行为 `Xcode 26.2`。普通 hosted check 与后续真实 App E2E 使用同一个 source-bound evidence run ID。新增静态 contract 同时约束两份 workflow；MetricKit 产品源码和原有双 selector 测试恢复原状。

## 验证结果

- Red：旧 hosted job 实际输出 Xcode 16.4，并在真实 clean build 对 MetricKit callback 稳定判红。
- Green（既有基线）：本机 Xcode 26.2 隔离 target build 与 8 个 MetricKit subscriber test 全绿。
- 待 Green（受害路径）：build 13 的 hosted job 必须实际输出 Xcode 26.2，完成 `scripts/check`，随后真实 App E2E 以相同 run ID 通过；tag workflow 必须用同一 Xcode 26.2 打出 canonical DMG。

## 永久门禁

- fast：`scripts/test-hosted-xcode-toolchain-contract`，由 `scripts/check` 强制调用，固定普通 CI 与 canonical Release 的 Xcode 26.2 路径、版本断言和 evidence run identity。
- symptom：`scripts/test-unit`，由 `scripts/check` 强制调用；hosted Xcode 26.2 必须真实编译 `NoonmarkDiagnostics` 并验证两个 subscriber selector。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用，只有 hosted check、打包及两个公开资产全部成功才通过。

## 发行与回滚

build 12 已因本故障与独立 workflow 故障退役。build 13 先经过 Xcode 26.2 普通 CI，再建立 tag。若 GitHub image 不再提供固定路径，workflow 必须 fail-closed 并退役该 build，再由人工评估新的项目工具链；不得静默回到 image 默认值、删除产品能力或跳过 hosted build。

## 教训与永久约束

runner OS label 不是完整工具链身份；只打印版本不能阻止漂移。canonical build 必须精确选择项目声明的 Xcode，并对实际版本 fail-closed。遇到 framework availability 差异时，先确认两个环境是否本来就应该使用同一 SDK，再决定是否承担额外兼容面。

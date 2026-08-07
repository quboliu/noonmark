# FAIL-2026-08-07-06：hosted check 未声明 ripgrep 依赖

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T15:50:32Z
- 影响版本／构建：v0.2.4 build 13，source commit `8af18a2ccfb75d4854d17cc8d1d381e57100643d`
- 引入提交：`3d5cc9e80915cd9c8f37a907e84cd3248692e9ae`（`feat(app): Complete the native experience and consistency acceptance upgrade`）把 `scripts/check-ui-localization` 纳入 hosted check，但必需工具清单与 workflow 安装清单没有加入 `rg`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`091928fdc23fb691112e3986db7149456c4f72d4`（`fix(ci): declare the hosted ripgrep dependency`）

## 用户症状与影响

build 13 的 hosted check 已经以 Xcode 26.2 完成干净 build、1527 个测试与确定性仿真，但进入 UI 文案静态门禁时报告 `rg: command not found`，随后把空扫描结果误呈现成 7 条 baseline 差异并退出。真实 App E2E 因上游 check 失败没有启动；产品资料、production App 与签名路径均未触碰。

## 时间线

- 2026-07-18：`scripts/check` 开始聚合 UI localization guard，必需工具数组没有覆盖该 guard 的 `rg` 依赖。
- 2026-08-07：为 workflow 新增 `actionlint` 时更新同一数组，仍没有把既有 `rg` 依赖补齐。
- 2026-08-07T15:50:32Z：run `31194101256`／job `92917951954` 在约 6 分钟后首次到达该路径并判红。
- 同一 run 的 Toolchain step、Swift build、全部 1527 个 XCTest、14 个 demo story test 与确定性仿真都已通过，错误精确停在 `scripts/check-ui-localization: line 122`。

## 复现与证据

hosted log 的原始错误为：

```text
scripts/check-ui-localization: line 122: rg: command not found
```

紧接着的 baseline diff 把原有 7 条审核文案显示为全部删除，这是命令缺失造成的空输出，不是产品文案变化。新增 fast contract 先在旧 workflow 上判红，精确报告 `.github/workflows/ci.yml does not install the complete hosted check toolset`。

## 排除的假设

- 不是 MetricKit 或 Xcode 问题：同一 run 已明确选择 Xcode 26.2，并完成干净编译。
- 不是产品文案被删除：source commit 相对上一轮完整产品验证的 `Sources/` 与 `App/` 零差异；diff 是扫描命令未执行产生的空结果。
- 不是 XCTest 回归：1527 个测试以 0 failure 完成。
- 不是真实 App 交互失败：E2E job 因上游依赖失败未启动。

## 根因与破坏机制

`scripts/check` 是 hosted 门禁的聚合入口，却没有完整声明间接脚本使用的必需二进制。开发机预装 ripgrep，使本地完整链长期掩盖缺口；hosted image 没有 `rg` 时，检查不会在开头 fail-fast，而是在耗时约 6 分钟后把“工具不存在”混淆成“产品文案漂移”。两条 canonical hosted workflow 也只安装 Swift lint 工具，没有安装 ripgrep。

## 根因修复

把 `rg` 纳入 `scripts/check` 的启动前 `required_tools`，缺失时在任何 build 或测试前直接报告 `missing required tool: rg`。普通 CI 与 canonical Release 的 Toolchain step 都明确通过 Homebrew 安装 `ripgrep`。既有 hosted toolchain contract 同时约束两份 workflow 的完整工具集合和 check 的 fail-fast 声明。

## 验证结果

- Red（原始受害路径）：run `31194101256` 的 clean build与全部测试通过后，UI localization guard 因 `rg` 缺失判红。
- Red（fast）：更新后的 hosted toolchain contract 在旧 workflow 上立即判红，精确识别缺少 `ripgrep`。
- Green（fast）：hosted toolchain contract、5 份 workflow 的 `actionlint`、failure-case registry、release readiness／aggregation 与 build 14 version contract 全绿。
- 待 Green（受害路径）：build 14 hosted check 必须越过 UI localization guard 并完成全部后续门禁。

## 永久门禁

- fast：`scripts/test-hosted-xcode-toolchain-contract`，由 `scripts/check` 强制调用，要求两条 hosted workflow 安装完整工具集，并要求 check 在套件开始前验证 `rg`。
- symptom：`scripts/check-ui-localization`，由 `scripts/check` 强制调用，真实使用 ripgrep 扫描 production UI 文案并与审核 baseline 对账。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；canonical hosted check、打包与两个公开资产都必须成功。

## 发行与回滚

build 13 的 hosted CI 已判红，永久标记 `retired`，不得复用或 tag。build 14 只改变 hosted 工具依赖、门禁与发行元资料。若 Homebrew 无法提供 ripgrep，workflow 必须在 Toolchain step fail-closed 并退役该 build；不得忽略 `rg` 错误、伪造 baseline 输出或从 check 删除 localization guard。

## 教训与永久约束

聚合测试入口必须拥有完整、可执行的依赖清单；不能把开发机预装工具当作 runner 契约。工具缺失必须在昂贵测试开始前失败，并与产品断言失败使用不同的错误信息，避免把环境问题误诊成业务回归。

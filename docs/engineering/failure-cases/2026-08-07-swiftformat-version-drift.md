# FAIL-2026-08-07-11：SwiftFormat 浮动版本令本机与 hosted 结果分裂

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T18:12:43Z
- 影响版本／构建：v0.2.4 build 18，source commit `fd10cc95bdeae0cdeb6cd1db6719dd001e1f1ab6`
- 引入提交：`57423085d5ab1f0c739dc96db9d5e78ec10d582d`（`test(ci): Add layered testing and release automation`）首次让 hosted CI 直接安装 Homebrew 浮动 SwiftFormat
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`440484c23c0d75f0c5235ac35e56081817cb65de`（`fix(ci): pin the SwiftFormat toolchain`）

## 用户症状与影响

用户要求 GitHub 对精确 candidate 只运行一次 hosted 子集并成功后发行。build 18 的唯一 hosted job 完成 build 与测试后，在最终 SwiftFormat lint 对 72 个既有文件判红；同一 source 在 push 前的本机门禁已通过。tag 尚未建立，Release、DMG、production App 与用户资料均未触碰。

## 时间线

- 2026-07-05：初始 CI 以 `brew install swiftformat` 获取当时最新版本，没有仓库版本身份或 checksum。
- 2026-08-07：本机完整自测使用 SwiftFormat `0.61.1` 通过；GitHub `macos-15` runner 取得 `0.62.1`。
- 2026-08-07T18:12:43Z：run `31203389558` 在 32 分 17 秒处报告 `72/472 files require formatting` 并退出 1；唯一 job ID 为 `92948513731`。
- 失败 run 保留且不 rerun；build 18 永久退役，build 19 承接根修。

## 复现与证据

对 source commit 中同一个 `DataImportTransaction.swift`、同一仓库 `.swiftformat` 做差分：本机 `0.61.1` 报告 `0/1 files require formatting`；官方 `0.62.1` 报告四个 `wrapIfStatementBodies` 并退出 1。GitHub 日志明确显示 Toolchain 使用 `swiftformat 0.62.1`，并在读取仓库配置后报告完全相同的规则错误。完整仓库经固定版本入口可稳定复现 `72/472` 红灯。

## 排除的假设

- 不是产品 build 或 XCTest 回归：run 在 SwiftFormat 前已完成对应阶段，错误全部来自 formatter。
- 不是 runner 没有读取配置：日志明确显示读取 checkout 内的 `.swiftformat`。
- 不是 checkout 或换行差异：本机对同一 commit 使用官方 `0.62.1` 可原样复现。
- 不是 Homebrew `aws/tap` 信任警告：Toolchain step 已成功，真正失败发生在 32 分钟后的 Check。

## 根因与破坏机制

仓库把 SwiftFormat 当成质量门禁，却只声明“命令存在”，没有声明工具版本、下载来源或 checksum。本机保留 `0.61.1`，全新 runner 自动升级至 `0.62.1`；新版本启用额外规则后，同一源码产生相反结论。CI 因 formatter 位于长链末端，直到全部 build 与测试完成后才暴露漂移。

## 根因修复

新增 `scripts/install-pinned-swiftformat`，只下载官方 `0.62.1` universal binary，并以 GitHub Release 提供的 SHA-256 fail-closed 校验后放入被 Git 忽略的仓库工具缓存。`scripts/format` 不再解析全局命令，永远调用该固定二进制；CI 不再以 Homebrew 安装 SwiftFormat。`scripts/check` 在昂贵阶段前安装并打印固定版本。源码一次性按该版本格式化；明确禁用会重写 SwiftUI `Group` 结构的 `redundantSwiftUIGroup`，保留现有 UI builder 语义。

## 验证结果

- Red（真实 hosted）：run `31203389558` 使用 SwiftFormat `0.62.1` 报告 `72/472` 并失败。
- Red（最小差分）：同一文件在 `0.61.1` 为绿、`0.62.1` 为四个同规则错误。
- Green（fast）：固定工具链 contract、首次下载 checksum 校验、缓存后二次版本校验均通过。
- Green（本机 symptom）：固定 `0.62.1` 的 `scripts/format --lint` 报告 `0/472`；72 个 Swift 文件的无空白 token 序列没有增删。
- Green（hosted 工具身份与 build）：build 19 run `31206472761` 的 Toolchain 真实输出 `0.62.1`，随后 Swift build 完整成功；该 run 之后因独立 Notes UI 静态扫描器与合法换行耦合而判红。
- Green（hosted symptom／release）：build 21 CI run `31210493224` 的唯一 job 完整成功；tag run `31213156156` 只打包并建立唯一 DMG 与 checksum。

## 永久门禁

- fast：`scripts/test-swiftformat-toolchain-contract`，由 `scripts/check` 强制调用；拒绝浮动 Homebrew SwiftFormat，固定版本、官方 URL、checksum、共享入口及 CI 单次安装。
- symptom：`scripts/format --lint`，由 `scripts/check` 强制调用；真实 production、test 与 App Swift source 必须由固定 formatter 全量判定。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；精确 hosted check 未成功或 tag package 未建立唯一 DMG／checksum 时不得发布。

## 发行与回滚

build 18 与 build 19 永久退役，不 rerun、不 tag。build 20 只在 targeted contract 全绿后 push，以唯一 main hosted run 灰度固定工具链及格式无关扫描器；成功才建立 `v0.2.4` tag。未发布前可普通 revert 工具链与格式 commit，但不得恢复浮动 formatter；若官方资产不可取得或 checksum 不符，Toolchain 必须在长测试前失败。已交付 tag 不移动，production 资料不参与回滚。

## 教训与永久约束

代码格式器是编译工具链的一部分，不是“安装最新即可”的便利命令。可复现门禁必须同时固定版本、来源、digest 与统一调用入口，并在昂贵测试前证明实际二进制身份。

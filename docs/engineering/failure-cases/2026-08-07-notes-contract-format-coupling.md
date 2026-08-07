# FAIL-2026-08-07-12：Notes UI 静态门禁错误绑定源码换行

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T18:22:24Z
- 影响版本／构建：v0.2.4 build 19，source commit `64742657c713f329d60c0ab8d5047cab88ade31e`
- 引入提交：`6104a58e47c5c39471e9d62ae343241ccc6acd25`（`feat(flylight): refactor the Feiguang input and editing experience`）加入要求单行 `if state == .failed { return true }` 的 literal 门禁
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

build 19 的唯一 GitHub-hosted job 已通过固定 SwiftFormat Toolchain 并完成 Swift build，却在 `Notes UI contract` 立即报告 `Flylight retry action became disabled by its retained failure message`。实际 `canSubmit` 仍在 `.failed` 时返回 `true`，重试按钮仍以 `canSubmit == false` 决定 disabled；错误只存在于测试扫描器。tag、Release、DMG、production App 与用户资料均未触碰。

## 时间线

- 2026-08-04：Notes UI contract 以精确单行 literal 保护飞光失败重试。
- 2026-08-07：固定 SwiftFormat `0.62.1` 合法地把该 `if` body 展开为多行，非空白 token 与产品语义不变。
- 2026-08-07T18:22:24Z：run `31206472761` 在 Swift build 成功后由该 literal 判红；唯一 job ID 为 `92958678088`。
- 同名 contract 在本机对精确 source 立即复现；build 19 保留失败记录且不 rerun，随后退役。

## 复现与证据

`scripts/test-notes-ui-contract` 在 source commit `64742657` 上稳定退出 1，并输出与 GitHub 完全相同的错误。实际 `FlylightComposerSurface.canSubmit` 为 `guard non-empty`、`if failed { return true }`、其余状态再检查 issue 与 dirty；GitHub Xcode 26.2 已完整编译该源码。把空白移除后，原单行和 formatter 多行版本拥有完全相同的 token 序列。

## 排除的假设

- 不是产品重试按钮被禁用：失败分支仍返回 `true`，按钮仍以 `.disabled(canSubmit == false)` 绑定。
- 不是 SwiftFormat 破坏 Swift 语法：真实 hosted Swift build 已完成。
- 不是 formatter 工具身份再次漂移：Toolchain 明确输出固定 `0.62.1`。
- 不是 self-hosted 或重复 E2E：run 只有一个 `macos-15` job，失败发生在 hosted 静态 contract。

## 根因与破坏机制

门禁要保护的是 `failed` 状态允许 retry 的控制流，却把“控制流语义”降格为一条包含空格与换行的精确源码字符串。任何合法 formatter、注释或排版变化都能让测试在产品行为不变时误报；这类假红又位于 hosted 聚合入口早段，直接阻断发行。

## 根因修复

为 Notes UI contract 增加 `require_compact_literal`，只忽略空白并保留完整 token 顺序；真实断言同时绑定 `if failed { return true }` 与后续正常状态表达式，避免匹配无关片段。新增独立 matcher gate，内置单行正例、多行正例及 `return false` 负例；原产品代码不改。

## 验证结果

- Red（真实 hosted）：run `31206472761` 的 Notes UI contract 对合法换行判红。
- Red（本机 symptom）：同一脚本对精确 source 输出同一错误。
- Red（fast）：新 matcher gate 在旧扫描器上报告没有格式无关 matcher。
- Green（fast）：单行与多行结构均通过，`return false` 负例稳定失败。
- Green（本机 symptom）：真实 `scripts/test-notes-ui-contract` 完整通过。
- 待 Green（hosted／release）：build 20 必须由唯一 hosted job 完整执行同一 contract 与其余子集，tag job 再建立唯一 DMG 与 checksum。

## 永久门禁

- fast：`scripts/test-notes-ui-contract-formatting`，由 `scripts/check` 强制调用；验证格式无关 matcher 的一行、多行与反向 mutation。
- symptom：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用；真实飞光 composer 必须保留 failed retry 控制流及完整 Notes UI 契约。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；精确 hosted check 未成功或 tag job 未建立唯一 DMG／checksum 时不得发布。

## 发行与回滚

build 19 永久退役，不 rerun、不 tag；build 20 承接修复。未发布前可普通 revert matcher commit，但不得恢复空白敏感 literal；如 matcher 接受 `return false`，fast gate 必须在 push 前判红。灰度只使用 build 20 的唯一 GitHub-hosted main run，监控 job 数、runner label、contract 结果与最终 Release asset。production 资料不参与回滚。

## 教训与永久约束

静态源码门禁只能绑定稳定结构，不得把 formatter 可自由改变的空白当成产品语义。任何格式无关 matcher 都必须同时拥有等价排版正例和语义反例。

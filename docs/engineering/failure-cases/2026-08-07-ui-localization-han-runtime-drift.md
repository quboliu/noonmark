# FAIL-2026-08-07-08：UI localization 的 Han 判定跨运行时漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T16:18:27Z
- 影响版本／构建：v0.2.4 build 15，source commit `697023c0cad0bff49a856a8b14eca0dea8c34b9b`
- 引入提交：`d39944f42ee20d50ad5dad7abf004b46d6396bbb`（`test(ui): Strengthen real App and release gates`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`e18bb36c3f8e4363610b2047dfaefb5ac60094ee`（`fix(ci): stabilize Han localization scanning`）

## 用户症状与影响

build 15 的 hosted check 已完成产品编译、1527 项 XCTest、14 项年度 Demo 测试与确定性仿真，随后 UI localization guard 把 12 条只包含 U+00B7 `·` 的既有 separator 误报为新增 Han 文案并判红。真实 App E2E 因上游失败没有启动；产品文案、baseline、资料、tag、Release 与 production App 均未改变。

## 时间线

- 2026-07-15：localization scanner 以裸 Unicode Han property 识别中文 literal，并由本机生成 baseline。
- 2026-08-05：英文截图门禁已经发现 ICU Script_Extensions 会把 U+00B7 视作 Han 相关字符，并改用明确 scalar 范围；localization scanner 没有同步该约束。
- 2026-08-07：build 15 首次在安装了 ripgrep 的 hosted Xcode 26.2 路径到达 localization guard，12 条 separator 假阳性使 check 判红并退役该 build。

## 复现与证据

run `31196238509`／job `92925025613` 的 diff 新增项全部包含 U+00B7，且没有 Han ideograph。hosted 与本机都运行 ripgrep 15.2.0，排除 `rg` 版本差异；相同 source 在本机只产生 baseline 中 7 条真正的中文 label，在 hosted Perl scanner 则额外产生 12 条中点行。仓库 `verify-english-screenshot-content.swift` 已有独立运行证据与注释，证明裸 Han property 会因 Script_Extensions 把该 separator 纳入匹配。

## 排除的假设

- 不是 12 条新产品文案：这些源码行早已存在，且内容只是 separator 或包含英文插值的 separator。
- 不是 baseline 漏回填：把假阳性加入 baseline 会掩盖跨环境不确定性，下一台运行时仍可能得到另一集合。
- 不是 ripgrep 15.2.0 扫描差异：两端版本一致；`rg` 只枚举 Swift 文件，实际字符判定由临时 Perl scanner 完成。
- 不是 build 15 的飞光修复回归：同一 run 的 1527 项 XCTest 已 0 failure，原异步失败从红转绿。

## 根因与破坏机制

scanner 用没有限定语义的 Unicode Han property 作为字符 oracle。不同 Unicode engine／property table 会把它解释为 Script 或 Script_Extensions；后者把 U+00B7 这种多脚本共用标点关联到 Han。baseline 在一种运行时生成，hosted 在另一种运行时消费，因此同一 source 得到不同 inventory，门禁不是 source-deterministic。

## 根因修复

scanner 改用明确的 CJK Unified／Compatibility Ideograph scalar 范围，不再把 Unicode property alias 交给运行时解释。self-test 加入 direct `Text("·")` 与 helper `" · "` 两个负例，同时保留 direct、helper、持久化参数和模型 intent 四种真实中文正例。独立 fast contract 固定 scalar 定义、禁止恢复裸 property，并执行 scanner self-test；真实 baseline 仍保持 7 条，不接受假阳性扩表。

## 验证结果

- Red（原始 hosted 症状）：run `31196238509` 在 1527 项测试全绿后输出 12 条中点假阳性并阻断 build 15。
- Green（fast）：新增 Han contract 与 scanner self-test 全绿，两个中点负例不进入 inventory，四种中文正例仍被捕获。
- Green（本机 symptom）：真实 production inventory 精确保持已审核的 7 条中文 literal，baseline guard 全绿。
- 待 Green（hosted 受害路径）：build 16 必须在相同 macOS hosted image 得到同一 7 条 inventory，并完成后续门禁与真实 App E2E。

## 永久门禁

- fast：`scripts/test-ui-localization-han-contract`，由 `scripts/check` 强制调用；固定跨运行时 scalar oracle、中点负例和中文正例。
- symptom：`scripts/check-ui-localization`，由 `scripts/check` 强制调用；真实扫描 production SwiftUI source 并与 7 条审核 baseline 对账。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；canonical hosted check、签名、DMG 与 checksum 未全部完成时不得发布。

## 发行与回滚

build 15 已永久标记 `retired`，不得 rerun、复用或 tag；build 16 先经新的 `main` CI 验证 hosted inventory，再允许进入 tag 路径。若明确 scalar 范围漏掉产品实际使用的 Han ideograph，扩充范围与正例后使用新 build；不得恢复 runtime-dependent property、把中点假阳性加入 baseline或跳过 localization guard。回滚只撤销 scanner 与门禁提交，产品 UI 和资料均不需要迁移。

## 教训与永久约束

跨平台文本门禁不能把 Unicode property alias 当作固定 ground truth。字符集合必须以明确 scalar 或跨引擎对账定义，并同时保留正例与容易误报的标点负例；baseline 只能审核真实 source 变化，不能吸收 oracle 漂移。

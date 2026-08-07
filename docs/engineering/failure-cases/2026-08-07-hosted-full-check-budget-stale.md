# FAIL-2026-08-07-09：hosted 完整 check 仍使用初始 25 分钟预算

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T16:48:25Z
- 影响版本／构建：v0.2.4 build 16，source commit `c81b4a3b3d8e2b077f8064267764b95fdd572026`
- 引入提交：`3d5cc9e80915cd9c8f37a907e84cd3248692e9ae`（`feat(app): Complete the native experience and consistency acceptance upgrade`）把 DMG evidence contract 纳入 `scripts/check`，但没有同步 25 分钟 hosted job 预算
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`3492ccfe920ba5bc79c9a4a01363793d62ef3738`（`fix(ci): align the full hosted check budget`）

## 用户症状与影响

build 16 的 hosted check 已完成 Xcode 26.2 编译、1527 项 XCTest、14 项年度 Demo、确定性仿真、7 条 localization inventory 与后续证据 contract，进入 `scripts/test-dmg-evidence-contract` 约 15 分钟后被 GitHub 的 25 分钟 job 上限取消。没有断言失败或脚本错误；真实 App E2E 因上游取消没有启动，tag、Release、DMG 与 production App 均未触碰。

## 时间线

- 2026-07-05：最初 CI 建立 25 分钟 check job，当时尚无当前 DMG evidence matrix。
- 2026-07-18：3351 行 DMG contract 的初版加入 `scripts/check`，workflow 预算没有同步更新。
- 2026-07-31 至 2026-08-07：发行、诊断、签名、LaunchServices 与 evidence closure 持续增加负面矩阵，外层仍保持 25 分钟。
- 2026-08-07：build 16 首次越过此前的 hosted 工具、测试同步与 localization 阻断，在 DMG contract 执行中到达外层上限并被取消。

## 复现与证据

run `31197305770`／job `92928600208` 的日志在 `16:32:47Z` 进入 `==> DMG evidence contract`，到 `16:48:25Z` 只出现 GitHub `The job has exceeded the maximum execution time of 25m0s` 与取消信息，没有测试失败。当前 DMG contract 有 43 个 install 语义篡改案例、44 个 install manifest 篡改案例与 25 次直接 cross-validator 调用；同一完整 `scripts/check` 在 canonical `release-publish.yml` 已使用 90 分钟有界预算，本地完整链也已成功完成。

## 排除的假设

- 不是飞光异步回归：同一 run 的 1527 项 XCTest 为 0 failure。
- 不是 localization 误报：hosted 明确输出 `UI localization literal guard: ok (7 known literals)`。
- 不是 DMG 断言失败：contract 进入后没有 FAIL、error 或非零退出，唯一终止源是 workflow 外层超时取消。
- 不能删除、skip 或缩减 DMG matrix：这些案例是既有发行故障的 fast gate，必须继续由 `scripts/check` 聚合。

## 根因与破坏机制

普通 CI 的 25 分钟上限是项目初始测试规模的静态常数。`scripts/check` 后来成为完整 UT／IT／ST／DST、证据、DMG 与发行 contract 的聚合入口，但预算没有随责任边界更新。结果是所有断言都可能正确，GitHub 仍在后半段以基础设施取消覆盖测试结论；普通 CI 与执行同一入口的 canonical Release 也形成 25／90 分钟漂移。

## 根因修复

普通 CI check job 与 canonical Release 对同一 `scripts/check` 统一使用 90 分钟硬上限。新增 hosted check budget contract，从各自 job scope 读取 timeout，要求两者都恰为 90 且相等；不能靠另一 job 的 timeout 或简单 grep 冒充。内部 helper、observer 与 fixture 的短 fail-closed deadline 保持不变，测试矩阵不删、不 skip、不降级。

## 验证结果

- Red（原始 hosted 症状）：run `31197305770` 在 DMG contract 中被 25 分钟外层预算取消。
- Green（fast）：hosted budget contract、5 份 workflow 的 actionlint、62 个 failure-case registry、build 17 version contract、ShellCheck 与 `git diff --check` 全绿；ordinary CI 与 canonical Release 均精确使用同一 90 分钟预算。
- 待 Green（原始 hosted 受害路径）：build 17 必须让同一 `scripts/check` 完整返回成功，随后自动启动真实 App E2E。

## 永久门禁

- fast：`scripts/test-hosted-check-budget-contract`，由 `scripts/check` 强制调用；从 job scope 解析并固定两条 canonical hosted 路径的相同有界预算。
- symptom：`scripts/test-dmg-evidence-contract`，由 `scripts/check` 强制调用；完整 DMG evidence matrix 必须真实执行完毕，任一篡改案例失败仍 fail-closed。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；Release workflow 未完成 check、签名、DMG 与 checksum 时不得发布。

## 发行与回滚

build 16 已永久标记 `retired`，不得 rerun、复用或 tag；build 17 先经新的 `main` CI 完整验证，再允许进入 tag。若真实 contract 出现死锁，90 分钟外层仍会终止并退役候选，随后必须修复具体子进程生命周期；不得继续加大预算。回滚可恢复 workflow 与 contract，但不得删除既有测试、移动 tag 或复用失败 build。

## 教训与永久约束

聚合测试入口的执行预算也是接口契约。新增强制子门禁时必须同步验证所有 hosted consumer 的预算一致性；超时只能用于约束已知完整负载，不能代替子进程 deadline，也不能以删测换绿。

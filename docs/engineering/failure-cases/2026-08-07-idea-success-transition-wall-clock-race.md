# FAIL-2026-08-07-07：飞光成功过渡测试依赖 wall-clock 顺序

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T16:00:29Z
- 影响版本／构建：v0.2.4 build 14，source commit `ab66173a3dced744f54a2f8644acbadfc3d55a9a`
- 引入提交：`e9cc14d761e53b8ba7821dcd0aea35bb11daf541`（`fix(flylight): backfill edit restoration and real-interaction gates`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`a3df3f6b4af9ea0bfce8ee7dd1a9fc158221488c`（`fix(ci): await exact Flylight success transitions`）

## 用户症状与影响

build 14 的 GitHub hosted check 完成 Xcode 26.2 选择、工具安装与产品编译后，在 `IdeaCaptureSessionTests.testInlineEditorCommitsNormalizedTextAndEndsSession` 内出现四条断言失败。四条失败都读取到同一个完整的过渡前状态：编辑 ID 与草稿仍在、状态仍为 `saving`、最后保存 ID 仍为空。保存回调已经收到正确 ID 与归一化正文，故资料提交本身没有失败；上游 check 判红后，真实 App E2E 没有启动，tag、Release 与 production App 均未触碰。

## 时间线

- 2026-08-04：为让 SwiftUI 真实绘制 `saving`，共享 session 新增延迟成功过渡；同一提交把测试写成 1 ms 产品过渡配合 10 ms 固定睡眠。
- 2026-08-07T15:54:14Z：build 14 push 触发 CI run `31194926190`。
- 同一 run 较早执行的定向 session suite 通过；随后全量 1527 项测试在相同测试方法内读取到尚未执行过渡的状态。
- 2026-08-07T16:00:29Z：hosted check 判红，E2E job 因依赖失败被跳过，build 14 退役。

## 复现与证据

run `31194926190`／job `92920698454` 的同步断言先证明持久化闭包收到正确 `IdeaID` 与正文，并证明 session 已进入 `saving`。10 ms 固定睡眠返回后，四项状态仍精确等于 `save()` 建立未结构化 MainActor task 后的快照。该 run 的 source commit 没有修改 `Sources/`、`App/` 或此测试；同一代码此前通过及同一 run 先通过，证明问题依赖调度次序而非确定性的业务输入。

## 排除的假设

- 不是四个独立产品故障：四个失败值构成一次过渡尚未发生的原子状态。
- 不是保存或正文归一化失败：回调 ID、正文与 `save()` 返回值都已通过。
- 不是测试间共享资料污染：两种 session 与 `IdeaID` 都由测试局部建立，inline session 不持有共享 repository 或 static 可变状态。
- 不是 Xcode 或 ripgrep 依赖问题：同一 job 已精确选择 Xcode 26.2、完成编译并安装完整 hosted 工具集。

## 根因与破坏机制

产品延迟任务与测试自身的 `Task.sleep` 都在 MainActor 上恢复。Swift concurrency 只保证 sleep 不早于期限恢复，不保证两个未结构化 task 的 continuation 按截止时间或建立次序 FIFO 执行。测试用「1 ms 产品任务、10 ms 测试睡眠」推断另一个 task 已完成，建立了不存在的 happens-before；hosted 全量负载下测试 continuation 先恢复，便读取到合法的 `saving` 状态并误判产品。

## 根因修复

两个共享 session 保留自己实际建立的延迟成功 task，并提供 internal 的确定性等待边界。composer 与 inline editor 测试继续先断言持久化后的 `saving`，随后直接 await 对应 task 的 `value`，不再以 wall-clock 猜测完成。产品默认 240 ms 反馈时长、持久化时点、generation guard、UI 与资料模型均不改变。

## 验证结果

- Red（原始 hosted 症状）：run `31194926190` 在全量测试负载下稳定捕获一次完整的 pre-transition 状态并阻断 build 14。
- Red（fast 结构）：旧代码没有 retained transition task，两个测试均含固定 `Task.sleep`，不满足新增 contract。
- Green（fast）：`scripts/test-idea-success-transition-contract`、failure-case registry、build 15 version contract、ShellCheck、SwiftFormat 与 `git diff --check` 全绿；没有重跑本地完整测试链。
- 待 Green（原始 hosted 受害路径）：build 15 的新 GitHub run 必须完成同一 1527 项聚合测试，并继续完成真实 App E2E。

## 永久门禁

- fast：`scripts/test-idea-success-transition-contract`，由 `scripts/check` 强制调用；要求两个共享 session 都保留并 await 实际 transition task，同时禁止 session 测试恢复固定 sleep。
- symptom：`scripts/test-unit`，由 `scripts/check` 强制调用；以 Xcode 26.2 真实执行 composer 与 inline editor 的完整状态顺序。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；canonical hosted check、签名、DMG 与 checksum 任一未完成都不得宣称发布。

## 发行与回滚

build 14 已永久标记 `retired`，不得 rerun、复用或 tag；build 15 先通过新的 `main` CI 灰度，再允许进入 tag 路径。若 retained task 边界改变产品状态次序，撤销本案例对应提交并退役 build 15；不得延长测试睡眠、缩短产品反馈、跳过 XCTest 或复用失败候选。production 资料与 App 不参与本修复验证。

## 教训与永久约束

固定 sleep 只能表达「至少经过一段时间」，不能证明另一个并发 task 已完成。状态机测试必须等待真实完成句柄或事件，并把即时状态顺序与最终状态分别断言；增加 timeout 倍数不是同步方案。

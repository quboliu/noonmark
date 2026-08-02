# FAIL-2026-08-02-03：E2E 窗口身份与就绪标题跨时点漂移

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T10:04:49Z
- 影响版本／构建：Noonmark 0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2`；clean gate 修复 commit `51eca76cb306168cba7c29d4a440c62d325e021b` 的完整 E2E 验证
- 引入提交：`3616621c8c0ce76161e3686be2f03f078cb9464d`（`fix(e2e): 禁止全局探测正式版窗口`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`（`fix(e2e): 收紧原生交互与发行证据协议`）

## 用户症状与影响

clean commit `51eca76cb306168cba7c29d4a440c62d325e021b` 的静态 `scripts/check` 与真实 writer-lease E2E 均通过，随后完整 `scripts/test-e2e` 在第四个截图场景 `day-changed-target` 连续三次找不到符合合同的主窗口。每次 App 进程与 owner-only identity 文件都存在，但消费者把启动瞬间发布的 7 月 5 日标题与 0.2 秒后自动化切换完成的 7 月 4 日就绪标题要求为同一个值，因此在查询实时窗口前判红。套件提前退出后报告 English 场景证据为空，这是前置失败的连锁结果，不是第二个独立故障。

同一错误语义还会稳定伤害后续 `english-day-history-header`：身份发布时标题为 `5 Jul`，自动化就绪后标题为 `30 Sep`。因此不能只给中文场景增加特例。

本轮只运行 `app.noonmark.mac.e2e`，没有启动、读取、定位或 reset production identity 与资料。

## 时间线

- 2026-08-01 08:16 -04:00：`3616621c` 引入非生产 App 的一次性窗口身份发布，并让 E2E 消费者同时要求 identity title 等于截图就绪标题。
- 2026-08-02 05:51 -04:00：发行证据协议根因修复提交为 `51eca76c`。
- 2026-08-02 06:01 -04:00：同一 run ID 的 clean `scripts/check` 通过，起止 commit／tree 一致且 dirty 为 0。
- 2026-08-02 06:02 -04:00：真实 writer-lease E2E 通过。
- 2026-08-02 06:04 -04:00：完整真实 App E2E 在 `day-changed-target` 连续三次以 identity present but invalid 判红。
- 2026-08-02 06:10 -04:00：受控 exact-window probe 证明同一 PID／window 的发布标题为 7 月 5 日、实时就绪标题为 7 月 4 日，排除产品选择失败。

## 复现与证据

症状级命令：

```bash
NOONMARK_EVIDENCE_RUN_ID=local-20260802-51eca76-release-1 scripts/test-e2e
```

真实失败证据：

- `artifacts/e2e/day-changed-target.log` 连续三轮记录期望标题为 `晷迹 · Day Todo — 7月4日`，App 进程保持运行，exact identity 文件存在但被判为 invalid。
- 三份 owner-only canonical identity 均绑定各自 launch token、真实 E2E PID、`app.noonmark.mac.e2e` 与 exact window number，发布标题均为 `晷迹 · Day Todo — 7月5日`。
- 独立受控 probe 使用同一 E2E App、同一 PID 与 identity 发布的 exact window number：identity title 为 `晷迹 · Day Todo — 7月5日`，一秒后的 `NoonmarkWindowProbe` live title 为 `晷迹 · Day Todo — 7月4日`，owner PID 完全一致。
- `App/NoonmarkMacApp/NoonmarkMacApp.swift` 先把 identity publish 排入下一个主队列 turn；launch automation 固定在 0.2 秒后执行。`scripts/test-e2e` 的旧 parser 却在读取 identity 时执行 `identity.title == expectedTitle`，尚未进入 exact-window live probe 就失败。
- emergency candidate 的 source commit `61d82a8d` 已同时包含上述生产者时序与消费者比较，故障不是 candidate 打包后的产品功能改动引入。

## 排除的假设

- 产品 changed-target 选择失效：同一 PID、同一 exact window 的 live title 已真实变为 7 月 4 日。
- App 未启动、崩溃或身份文件缺失：三轮进程均存活，identity 的 token、PID、bundle、window number 与 canonical 结构均存在。
- WindowServer exact-ID API 再次回归：受控 `NoonmarkWindowProbe` 对 identity 发布的 exact window number 返回唯一记录、相同 owner PID 与正确 live title。
- English 场景自身先失败：套件在进入 English 场景前已退出；空 ledger 是清理阶段对账发现的派生缺口。
- 当前 gate-only commit 改坏产品代码：`51eca76c` 没有修改 `App/`、`Sources/`、资源或 `Package.swift`。

## 根因与破坏机制

一次性 identity 的 title 是「App 发布 token/PID/bundle/window number 绑定时观察到的标题」，而截图 expected title 是「所有启动后自动化完成时，同一窗口应呈现的就绪状态」。两者处于不同时间点。`3616621c` 在加强窗口隔离时把两个语义压进一个 `expectedTitle`，于是任何会在 identity 发布后改变窗口标题的合法自动化都会被误判。

直接给两个已知场景增加标题特例仍会让未来新自动化重复漂移。根本边界应是：identity parser 只认证不可变身份与发布字段的安全形状；实时 readiness probe 使用该 identity 的 exact window number，再验证当前 owner PID、layer、onscreen、标题与几何。

## 根因修复

- `resolve_exact_e2e_window_id` 不再把一次性 `identity.title` 与 live expected title 做跨时点相等比较。
- identity title 仍 fail-closed 校验为非空、最多 512 UTF-8 bytes 且不含控制字符；token、PID、bundle、App path、canonical bytes、owner-only descriptor 与 window number 校验不放宽。
- 同一 identity window number 仍必须由共享 `NoonmarkWindowProbe` 返回唯一 live record，并与 expected PID、layer 0、onscreen、ready title 和 frame 全部对账。
- fast contract 直接拒绝旧 `identity.title == expected*` 语义，并要求安全 publication 字段校验与 exact-window readiness 校验同时存在。

## 验证结果

- 症状红：完整真实 E2E 在 `day-changed-target` 连续三次稳定判红。
- 运行取证：同一 E2E PID／window 已证明 publication title 与 ready title 合法不同。
- Fast 绿：`scripts/test-e2e-evidence-contract` 已通过，并实际提取、typecheck 内嵌 Swift identity reader，防止纯文本契约漏掉语法错误。
- 聚焦 symptom 绿：run `local-20260802-window-title-focused-2` 的真实 `day-changed-target` 与 `english-day-history-header` 均通过截图、标题及 English ledger 对账。
- 全量静态／测试聚合绿：run `local-20260802-gate-audit-check-2` 的 `scripts/check` 以 1440 项测试、0 失败完成；两个显式禁用的 live iCloud 用例按合同不进入默认测试。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 的未过滤完整 E2E 完成 `day-changed-target`、`english-day-history-header` 及其余中英文窗口场景，实时 ready title、exact window、截图与 ledger 全部对账，suite exit status 为 0。
- Release：待 clean repair commit 的正式发行闭环后回填。
- 修复 commit：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，拒绝 identity publication title 与 live readiness title 的旧相等比较，并要求 publication 字段安全约束与 exact-window live probe 同时存在。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制运行真实 `day-changed-target` 与 `english-day-history-header`，覆盖两个启动后标题变化、截图和 English ledger。
- Release：`scripts/verify-development-validation-evidence --scope runtime/full` 由 `scripts/release-private-dmg` 强制对账同一 run／source 的完整 E2E、English 全场景与 writer-lease 证据；失败或 filtered manifest 不得进入打包动态门禁。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：修复只改变 E2E 消费者语义，不修改 production runtime、用户功能、数据库 schema 或同步 payload；主要风险是身份 parser 被错误放宽，因此保留 token、PID、bundle、App path、canonical owner-only file、window number 与 live exact-window 全量校验。
- 回滚：若新消费者合同误接受错误窗口，回滚本案例修复提交并继续阻断发行；不得恢复全局窗口扫描、跳过 title／PID 对账或用重试掩盖跨时点错误。
- 灰度：fast contract 转绿后先跑聚焦 changed-target／English screenshot 症状，再跑完整真实 E2E；只有同一 run 的 clean check、writer lease、完整 E2E、isolated release diagnostic closure、production DMG 静态门禁与派生 `dmg-validation` 全部通过才生成候选。
- 监控：持续对账 identity token／PID／bundle／window number、live PID／title／geometry、English scenario set、source commit/tree、run ID 与 `production_app_executed=false`；任一漂移立即 fail-closed。

## 教训与永久约束

1. 一次性身份快照与异步就绪状态必须分层建模，不能复用一个 expected 字段。
2. 安全身份绑定不应依赖可合法变化的 UI 文本；UI 文本必须在绑定后的 exact object 上按当前时点校验。
3. 修门禁漂移时要静态枚举同类时序消费者；本案在第一次真实失败后即发现并覆盖尚未执行到的 English history path。
4. 真实运行负责证明症状，fast contract 负责阻止已知错误语义复发；两者不能互相冒充。

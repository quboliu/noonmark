# FAIL-2026-08-04-18：Demo 重建后失去 WindowServer 输入授权

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 10:24 -04:00
- 影响版本／构建：`477cb3d43d58823906503e86f4d79d329f15df5e` 至修复前工作树
- 引入提交：`477cb3d43d58823906503e86f4d79d329f15df5e` `fix(flylight): 补齐编辑恢复与真实交互门禁`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话、Demo 物理交互入口与运行取证确认
- 修复提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec`

## 用户症状与影响

Demo fixture 已升级为真实 WindowServer 物理编辑，但 `scripts/test-interactive-demo-fixture` 与 `scripts/run-demo-app` 重建 Demo App 时仍允许 ad-hoc 签名。每次源码改变都会产生新 cdhash，macOS 不再把它视为已授权的输入客户端，年度 Demo 在第一下物理输入前失败，无法生成 ready manifest，也无法交给用户体验。

## 时间线

- Demo 入口原本主要执行程序内 presentation 检查，ad-hoc 构建尚未阻断主流程。
- 飞光门禁加入 `WindowServerInputDriver` 物理双击、输入与候选选择。
- 本轮源码重建后，`make test-demo-fixture` 返回 `eventAccessUnavailable`。
- 静态签名取证确认 Demo bundle 为 cdhash designated requirement、`TeamIdentifier=not set`；同机 E2E bundle 因入口强制稳定签名而可正常物理输入。

## 复现与证据

修改任一 App 源码后运行 `make test-demo-fixture`。旧入口构建 ad-hoc `app.noonmark.mac.demo`，App 内 `CGPreflightPostEventAccess()` 返回 false，manifest 为 `{"error":"eventAccessUnavailable","status":"failed"}`。`codesign -d -r-` 同时显示 designated requirement 只绑定 cdhash。

## 排除的假设

- 不是飞光目标坐标或视图消失：失败发生在 `WindowServerInputDriver.init()`，尚未解析或点击任何目标。
- 不是 production 身份权限：运行 bundle identifier 明确为 `app.noonmark.mac.demo`，资料根为隔离 Demo profile。
- 不能改回程序内模拟点击：那会撤销年度 Demo 的真实用户路径证据。

## 根因与破坏机制

Demo 两个构建调用者没有设置 `NOONMARK_REQUIRE_STABLE_UI_SIGNING=1`。`scripts/build-mac-app` 因而走 ad-hoc 分支，指定需求包含变化的 cdhash；一旦二进制改变，既有 WindowServer/TCC 授权不再适用。

## 根因修复

所有 Demo 运行入口在构建前强制稳定 UI 签名，由共享 identity resolver 唯一解析 Apple Development identity，并让 bundle identifier 与证书形成稳定 designated requirement。Demo 自动化首次运行时显式请求 event-posting access；用户仍掌握系统授权决定，拒绝或尚未授权时继续 fail-closed。runtime profile isolation fast gate 同时约束验收入口、用户 Demo 入口与授权请求只存在于 Demo 自动化，禁止任一入口重新漏签或静默降级。

## 验证结果

- 原故障症状与 ad-hoc 签名证据已取得。
- `scripts/test-runtime-profile-isolation` 通过；稳定 Apple Development 签名 Demo 只请求 CG event-posting 权限，真实交互、SQLite 与 sidecar 对账通过。
- 完整 `make check` 通过；全量报告为 1500 项测试、0 失败。

## 永久门禁

- fast：`scripts/test-runtime-profile-isolation`，由 `scripts/check` 强制调用，要求两个 Demo 入口显式强制稳定 UI 签名。
- symptom：`scripts/test-interactive-demo-fixture`，由 `scripts/test-all` 强制调用，重建真实 Demo App 后完成 WindowServer 物理交互并产出 ready manifest。

## 发行与回滚

只重建和运行 `demo` profile，不读取或启动 production。若稳定 identity 不可用，入口必须 fail-closed，不得回退 ad-hoc 或跳过物理交互。

## 教训与永久约束

只要 App 内部发出真实 WindowServer 事件，签名稳定性就是输入测试协议的一部分。新增物理交互时必须同步审查所有构建调用者，而不是只审查 E2E 主入口。

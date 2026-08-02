# FAIL-2026-08-02-07：诊断导出菜单物理选择协议漂移

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T14:34:34Z
- 影响版本／构建：Noonmark 0.1.1（4），clean source commit `cdbe2d69b1fdaf4f78f52ba32e66b8dc7154bc75`
- 引入提交：`d1b3c9a835633e381d7d5d0410820db041cbf640`（`feat(diagnostics): 闭合真实故障证据导出链路`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能单独证明实际操作者
- 修复提交：`53255d65b43b29c89f41c08fc3438a251aec3279`（`fix(e2e): 收紧诊断菜单物理选择协议`）
- Task-ID：noonmark-cloud-sync-debug

## 用户症状与影响

同一 run 的 clean static preflight 与 writer-lease 真实门禁已通过，未过滤 `scripts/test-e2e` 随后在诊断故障闭环失败。Helper 已通过真实 Help 菜单找到“导出诊断资料…”，但在等待精确“导出前预览”时超时；Helper 以正常 kernel exit、exit code 1 结束，导致正式发行链中止。

失败仅发生在固定 `app.noonmark.mac.e2e` 与隔离资料范围。没有启动、读取、定位、探测或 reset production identity、App 或资料。

## 时间线

- 2026-08-01 06:41 -04:00：`d1b3c9a` 新增诊断导出外部 Helper；其 `revealMenuItemWithoutShortcut` 把 AX 菜单项交还调用方后才执行物理 click。
- 2026-08-02 10:34 -04:00：run `release-20260802-cdbe2d6` 的完整 E2E 在 `diagnostic-menu` 后失败，原始错误为 `Timed out waiting for the exact diagnostic export preview`。
- 2026-08-02：三次隔离 `NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1` 与一次 English 前序组合转绿，证明问题是低频原生交互竞态；它们不能替代原始 full E2E 红证据。
- 2026-08-02：静态审计确认诊断导出、设置、快速记录和退出仍保留“返回可变 AX 菜单项再点击”的旧 seam；fast gate 只校验 ordered ledger step 名称，未检查可见性、pre-mouseDown re-resolution、menu dismissal 或 left-button-up。

## 复现与证据

原始症状命令：

```bash
NOONMARK_EVIDENCE_RUN_ID=release-20260802-cdbe2d6 scripts/test-e2e
```

失败 ledger 最小摘要：

```text
PASS diagnostic-menu title=导出诊断资料… shortcut=none source=cghidEventTap
FAIL fatal Timed out waiting for the exact diagnostic export preview
```

kernel exit observer 同时记录 `normal_exit=true`、`exit_code=1`，因此外层“没有正常 exit”的文案不是根因；真实失败是 Helper 在预览出现前主动以失败退出。

本修复前的 fast RED：

```bash
scripts/test-dmg-harness-evidence-contract
# shared physical menu protocol is missing: private func selectPhysicalMenuCommand(
```

## 排除的假设

- 诊断导出产品功能稳定失效：三个 isolation closure 和一次携带 English 菜单前序的 closure 都成功完成预览、保存面板、导出包、双锁与隐私哨兵对账。
- production 数据或 production App 参与：运行 profile、bundle identity、ledger 与 reset 记录均为 `e2e`。
- 只需延长等待：失败是在无接收端确认的物理 click 之后；延长 timeout 不会验证 mouseDown 的 target 仍有效，且会掩盖协议缺口。
- 只修诊断导出即可：同一旧 seam 同时被设置、快速记录、退出使用；逐点补丁会保留同类漂移。

## 根因与破坏机制

外部 Helper 把 AX 查询结果当成可跨越物理输入边界的稳定对象：先取得菜单项，记录 ledger，再由调用方按稍后的 frame 点击。期间没有验证菜单项仍 visible／enabled、AX identity 与 frame 是否不变、应用仍 frontmost，且 click 后没有统一要求菜单已关闭和全局左键已释放。

因此 ledger 中的 `diagnostic-menu` 只证明发送端曾观察到菜单项，不证明 mouseDown 落在仍有效的菜单项上。现有 fast gates 又只接受固定步骤名，无法在真实 full E2E 前阻断这个过时协议。

## 根因修复

- 以单一 `selectPhysicalMenuCommand` 深模块取代两种返回 AX 菜单项的旧接口。
- 该模块对所有外部菜单路径统一执行：frontmost／top-level visible+enabled → strict visible menu item → shortcut 对账 → pre-mouseDown top-level 与 item identity／frame 重解析 → 一次完整 CG HID click → 菜单关闭与 left-button-up 对账。
- Help、诊断导出、设置、快速记录与退出均迁移到该模块，禁止任一调用方持有跨 physical-click 边界的可变 AX menu item。
- 诊断预览等待失败改为输出只含 window role、已知窗口类别、window number、focus 与已知按钮／标题计数的最小摘要，不写任务正文、路径或自由文本。
- `scripts/test-dmg-harness-evidence-contract` 与 `scripts/test-e2e-evidence-contract` 先稳定判红，再约束共享模块、pre-mouseDown identity／frame 对账、menu close 与 button-up；旧接口再次出现即 fail-closed。

## 验证结果

- 症状红：run `release-20260802-cdbe2d6` 的未过滤 full E2E 在原始预览缺失点 exit 1。
- Fast 红转绿：新的 shared-menu static contract 先判红；Harness 编译、`scripts/test-dmg-harness-evidence-contract` 与 `scripts/test-e2e-evidence-contract` 已通过。
- 聚焦 symptom 绿：run `debug-20260802-menu-protocol-green-1`、`debug-20260802-menu-protocol-green-2` 与 `debug-20260802-menu-protocol-green-3` 的真实诊断闭环连续通过，ledger 明确记录 `pre_mouse_down=exact menu_closed=true left_button_up=true`。
- 完整 symptom 绿：run `debug-20260802-menu-protocol-full-green-1` 的未过滤 `scripts/test-e2e` 以 exit 0 完成，覆盖原始失败点及全部后续用户路径。
- Fast／回归绿：`scripts/check` 以 exit 0 完成；1,440 项自动测试通过、2 项显式 live iCloud 测试按环境策略 skip，确定性模拟、failure-case gates、DMG evidence／scope／ownership／observer 及 format lint 均通过。
- 发行状态：修复提交已确定；仍待从故障案例回填后的最终 HEAD 重跑正式发行链和 exact DMG validation，完成前不得交付发行物。

## 永久门禁

- Fast：`scripts/test-dmg-harness-evidence-contract` 与 `scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，拒绝旧 AX menu-item handoff，并要求共享物理选择、strict visible 查询、pre-mouseDown identity／frame 对账、菜单关闭与 left-button-up。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行，真实走“同步失败／锁等待／修改拒绝／SIGKILL／重启／Help 导出／预览／保存面板”。
- Release：`scripts/test-dmg-install` 由 `scripts/release-private-dmg` 强制执行，针对 exact package 的受控 `dmg-validation` 派生完成真实 Help 菜单、诊断预览、保存、重启与证据对账；不得运行 production App。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：改动仅处于 signed Helper 和 E2E／DMG validation 边界；主要风险是新 pre-click 对账过严导致真实 UI contract 变化时 fail-closed。它不改变 production 产品菜单、诊断 schema、SQLite 或同步资料。
- 回滚：若新共享协议被证明错误，只回滚该 Helper／gate 修复并继续阻断发行；不得恢复 AX item handoff、重复 click、固定 sleep、延长 timeout 或跳过预览症状门禁。
- 灰度：fast contracts → targeted diagnostic closure → full E2E → clean same-run release diagnostic closure → package static gate → 两轮相同 DMG validation。
- 监控：ordered ledger 必须持续保留 `pre_mouse_down=exact`、`menu_closed=true`、`left_button_up=true`；预览失败最小摘要只输出白名单化 UI 结构，不输出用户内容。

## 教训与永久约束

1. AX 只能用于只读 identity 与 geometry；把其对象跨越物理 input 边界交给调用方会重新引入 frame／identity 竞态。
2. “菜单项曾被观察到”与“真实动作被目标 App 接收”是不同证据层；ledger 必须记录 pre-click 对账与 post-click menu/button 状态。
3. 同类 native menu path 必须共享深模块；不能等每条入口在完整 E2E 或 DMG 验收中逐一暴露漂移。
4. fast gate 必须校验 producer 实现协议，不只校验最终 TSV 的步骤名称。

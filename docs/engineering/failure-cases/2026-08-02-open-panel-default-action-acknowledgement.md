# FAIL-2026-08-02-04：NSOpenPanel 物理 Open action 缺少端到端确认

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T10:33:00Z
- 影响版本／构建：Noonmark 0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2`；commit `51eca76cb306168cba7c29d4a440c62d325e021b` 后的完整 E2E 验证
- 引入提交：`3b40774c49f35e8acce847c82e800c3fda55c62c`（`feat(app): 完成原生体验与一致性验收升级`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`（`fix(e2e): 收紧原生交互与发行证据协议`）

## 用户症状与影响

完整真实 App E2E 已通过普通数据导入的 File 菜单、`NSOpenPanel`、取消、破坏性确认、SQLite 与重启，随后在四个损坏数据包的 fail-closed 套件中超时。失败前物理路径输入、exact file selection 与 Open Return 均已发出，但自动化没有来自目标 App 的 Open action 接受确认，因此完整发行验证被阻断。

第一次完整运行在第 2 个损坏包失败；隔离重跑在第 3 个失败，证明故障与特定 JSON 内容无关。两次失败均只运行 `app.noonmark.mac.e2e`；没有启动、读取、定位或 reset production identity 与资料。

## 时间线

- 2026-07-18 23:49 -04:00：`3b40774c` 增加四个连续损坏包的真实 `NSOpenPanel` 完整性套件，但每轮在 `runModal()` 返回后立即进入下一轮，没有对账 AppKit 关闭 transition 已收敛。
- 2026-08-02 06:33 -04:00：完整 E2E 的普通数据导入场景通过，完整性套件在第 2 个损坏包超时。
- 2026-08-02 06:41 -04:00：ONLY mode 隔离复现再次判红，这次前两个包成功、第 3 个包超时。
- 2026-08-02 06:44 -04:00：第一次修复尝试加入 modal settlement；前两轮明确完成 settlement 后第 3 轮仍失败，排除上一轮 transition 重叠是唯一根因。
- 2026-08-02 06:48 -04:00：失败前取证证明当前 panel 仍为 visible／key／modal、exact URL 正确、AX DefaultButton「打开」已 enabled；根因收敛为投递 Return 与 default action 接受之间没有确认。
- 2026-08-02，诊断阶段：同进程 async AX click 无法跨越阻塞 MainActor 的 `runModal()`；一次性 `panel.ok(nil)` A/B 也没有触发 delegate validation 或关闭 panel，排除把 App 内部 API／AX action 当成真实用户完成信号。
- 2026-08-02，外部 Helper 第一轮：错误套用了主窗口 layer／activation 假设；exact WindowServer 快照证明该 panel 的发布 layer 为 8。协议改为由 App 发布 exact layer，再由 Helper 对账同一 window number／title／frame。
- 2026-08-02，静态消费者审计：发现 exit observer 与 evidence contract 没有登记新 mode；在下一轮真实运行前同步补齐 allowlist、ordered ledger 与 release contract。
- 2026-08-02，远端 AX 取证：exact panel 不提供可依赖的 `kAXDefaultButtonAttribute`；最终边界改为 exact focused panel 内唯一 enabled、visible、localized `AXButton`「打开」／`Open`，不使用 AX action。
- 2026-08-02，run `local-20260802-import-integrity-external-helper-6`：四个损坏包的独立签名 Helper 物理点击、App delegate validation、modal return、Helper completion、SQLite／journal 不变与重启全部转绿。
- 2026-08-02 07:49 -04:00，run `local-20260802-import-ui-external-helper-1`：正常导入的取消与确认两轮同一路径转绿，并完成 SQLite 与重启对账。

## 复现与证据

完整症状命令：

```bash
NOONMARK_EVIDENCE_RUN_ID=local-20260802-window-title-full-precommit-1 scripts/test-e2e
```

隔离症状命令：

```bash
NOONMARK_E2E_DATA_IMPORT_INTEGRITY_ONLY=1 \
NOONMARK_EVIDENCE_RUN_ID=local-20260802-import-integrity-diagnosis-1 \
scripts/test-e2e
```

运行证据：

- 三轮 `panel-events.txt` 都记录失败场景已经完成 `typed-fixture-path`、exact URL 选择与 Open Return 投递，不是面板没打开或路径未输入；这些记录只能证明发送端动作，不能证明 AppKit 接受。
- 完整运行卡在 `dangling-subtask-parent`，隔离运行卡在 `invalid-subtask-terminal-facts`；同一 fixture 在另一轮能够成功，排除 JSON 内容决定性失败。
- 第一次修复后的 trace 证明前两轮各自完成 `post-modal-settled`，visible open panel 与 detached visible window 都为 0；第 3 轮仍失败，上一轮 transition 重叠不是充分解释。
- 增强的失败前 trace 证明当前 `NSOpenPanel` 仍为 visible、key、modal，exact selected URL 正确；AX 按钮列表中「打开」为 enabled。旧自动化只记录 Return 已投递，没有目标 App delegate validation、mouseDown target、mouse-up、modal return 或 panel close 的确认。
- 外部 Helper 诊断证明 modal panel 是独立的 WindowServer layer 8 窗口，不能沿用主窗口 layer 0 的 readiness 条件；Helper 必须消费 App 发布的 exact panel identity。
- 同进程 async action 在 `runModal()` 返回前不能恢复 MainActor continuation；`panel.ok(nil)` A/B 没有触发 `NSOpenSavePanelDelegate` validation，也没有关闭 panel。
- SQLite baseline 与 journal 在失败时没有被损坏包替换；失败发生在消费者交互完成判据，尚无产品数据边界失效证据。

## 排除的假设

- 特定损坏包触发 decoder 卡死：同一场景可在另一轮通过，失败位置会在第 2／3 个包之间移动。
- `NSOpenPanel` 未打开或物理输入失败：trace 已记录 panel key、路径 editor、完整路径、精确 URL 与 Open Return。
- 普通导入产品路径失效：紧邻其前的真实正常导入、取消、确认、SQLite 与重启全部通过。
- App 崩溃或主窗口丢失：失败 dump 中主窗口仍可见、key，且无崩溃报告。
- 当前窗口标题修复引入：本轮窗口修复只修改 screenshot resolver；该完整性自动化与缺失 settlement 边界来自 `3b40774c`，candidate 已包含。
- 上一轮 panel transition 没有收敛：加入逐轮 settlement 后仍在另一轮失败。
- 直接调用 App 内部 accept API 可替代用户动作：`panel.ok(nil)` 没有产生 validation 或 modal return，而且不构成真实物理路径。
- AX `DefaultButton` 是稳定远端契约：远端 exact panel 没有该属性；最终实现只接受 panel subtree 中唯一的本地化 Open `AXButton`，AX 仅用于只读 identity／geometry。

## 根因与破坏机制

`panel.urls` 已更新、WindowServer 键盘事件已投递、Open button 收到真实 pointer gesture、App delegate 接受 exact URL、`runModal()` 返回和 panel 离开 WindowServer 是不同完成时点。旧门禁在 URL 更新后无条件发送 Return，并把「事件已投递」当成「Open action 已接受」；它没有任何接收端 ACK。真实失败证明发送 Return 后 panel 仍可能保持 visible／key／modal，直至 12 秒 fail-closed 超时。

同进程 automation 又受 `runModal()` 的 MainActor 阻塞边界限制，不能可靠地在 modal action 完成前等待 async click。固定 sleep、重复发送 Return、调用 `panel.ok(nil)` 或延长超时都只会掩盖缺失的 action acknowledgement。根本边界是由 App 发布 exact panel／selection ready，独立签名 Helper 物理点击同一 panel 内唯一 Open button，再由 App delegate validation、modal return 与 Helper canonical completion 共同确认接收。

## 根因修复

- `NoonmarkMacE2ESupport` 新增 owner-only canonical ready／completion 协议：目录 0700、文件 0600、`O_NOFOLLOW`、exclusive publish、fsync、bounded read、inode／device／size 稳定性与 canonical re-encode 全部 fail-closed。
- App 继续通过真实 File 菜单、Go to Folder 和 HID 路径输入选择 exact file；选择完成后只发布 token、E2E PID、App path、panel window number／layer／title、selected path 与 interaction label，不再发送最终 Open Return。
- App 临时接管 `NSOpenSavePanelDelegate`，外部物理点击必须恰好触发一次 exact URL validation；菜单 action 返回后还必须证明原 panel invisible、已离开 modal，随后读取与 ready 全字段绑定的 Helper completion。
- shell 只用签名的 `NoonmarkDMGInstallHarness.app` 启动每轮独立 `e2e-open-panel` Helper，并以 kernel exit observer、exact ordered ledger、零 stderr／residual process 和 canonical completion 验证其身份及退出。
- Helper 将 ready 的 E2E PID／App path／window number／title／layer 与 WindowServer exact owner PID／snapshot 及 focused AX window 交叉对账；在 exact panel subtree 中只接受唯一 enabled、visible 的本地化「打开」／`Open` `AXButton`。
- AX 只读 identity 与 geometry，绝不调用 AX action。Helper 在 mouseDown 前重读 ready、exact WindowServer panel、focused AX panel、唯一 button identity／frame；任一变化立即 fail-closed，再通过 `cghidEventTap` 发出一次完整 mouse down／up。
- Helper 等待 exact panel 离开 WindowServer 并证明 left button 已抬起后发布 completion；App 最后对账 helper PID 不等于 target PID、source、button title、left-button-up、modal settlement 与真实业务结果。
- `dmg-install-exit-observer.swift`、harness ledger contract、evidence contract、failure-case gate map 与 release contract 同步登记新 mode，防止生产者新增而消费者过时。

## 验证结果

- 症状红：完整 E2E 与 ONLY mode 各稳定复现一次，失败位置不同但缺少接收端 ACK 的证据一致。
- Fast 绿：protocol／configuration／ordered-ledger 单测、`scripts/test-e2e-evidence-contract`、`scripts/test-dmg-harness-evidence-contract`、`scripts/test-dmg-install-observer`、`scripts/test-release-gate-contract`、`scripts/test-failure-case-gates` 与完整 DMG evidence mutation fixture 均通过。
- 聚焦 symptom 绿：run `local-20260802-import-integrity-external-helper-6` 的四个损坏包逐一完成独立 Helper 物理点击、可恢复错误、SQLite／journal byte-level 不变与重启；run `local-20260802-import-ui-external-helper-1` 的取消／确认、导入结果、SQLite 与重启全部通过；加入 exact WindowServer owner PID 后，run `local-20260802-import-ui-owner-bound-1` 再次通过两轮。
- 全量静态／测试聚合绿：run `local-20260802-gate-audit-check-2` 的 `scripts/check` 在静止 source 上通过 1440 项测试、DMG evidence mutation、签名、observer、lint／format 与发行契约，exit status 为 0。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 的未过滤完整 E2E 完成正常导入的取消／确认与两轮结果，并让四个损坏包逐一走真实 File 菜单、`NSOpenPanel`、独立签名 Helper exact Open click、App ACK、错误提示、SQLite／journal 不变与重启，suite exit status 为 0。
- Release：待 clean repair commit 的正式发行闭环后回填。
- 修复 commit：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，要求 owner-only ready／completion、独立签名 Helper、exact panel 内唯一 localized Open button、pre-mouseDown re-resolution、完整 mouse down／up、App delegate validation、modal return 与 settlement，并拒绝旧的无确认最终 Return、`panel.ok` 与同进程 click。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制运行正常导入两轮及四个损坏包，逐一要求真实 File 菜单、物理路径、外部 Helper exact Open click、canonical ACK、业务结果、SQLite／journal 与重启。
- Release：`scripts/verify-development-validation-evidence --scope runtime/full` 由 `scripts/release-private-dmg` 强制接受同一 run／source 的完整、未过滤 E2E 证据，并显式要求正常导入两轮及四个损坏包的 ready／completion、Helper ledger／kernel exit、trace、SQLite／state／result 全部进入同一 artifact inventory；ONLY mode 只能诊断，不能替代发行证据。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：App 侧改动只由固定 E2E launch arguments 启用，不改变 production 菜单、数据导入实现、schema 或 payload；主要风险是 ready／completion consumer 过宽、localized button 误匹配、pointer target 变化或 settlement 条件过严。
- 回滚：若条件误判，回滚本案例修复并继续阻断发行；不得恢复无确认最终 Return、使用 AX action／App 内部 accept API、固定 sleep、重复输入、提高超时或跳过损坏包场景。
- 灰度：fast contract → ONLY mode 四场景 → 普通导入 ONLY mode → 完整 E2E → clean 同一 run 发行闭环；每层必须保留真实面板、物理输入与 SQLite／journal 对账。
- 监控：逐场景对账 typed／ready／validated／modal-return／helper-complete／settled trace、Helper ordered ledger／kernel exit、exact panel window／layer、left-button-up、完整 E2E run／source／tree 与 `production_app_executed=false`。

## 教训与永久约束

1. URL selection、输入投递、物理 button gesture、delegate validation、`runModal()` 返回与窗口离开 WindowServer 是不同语义，原生面板必须逐层建立显式确认。
2. modal producer 与 async consumer 必须分离；独立 Helper 需要 canonical ready／completion，而不是跨进程猜测时序。
3. 单次面板成功不能证明连续操作稳定；真实用户路径存在重复操作时，symptom gate 必须覆盖重复序列。
4. 门禁修复不得减弱产品数据断言；本案继续要求四种损坏拓扑、SQLite／journal byte-level 不变与重启回读。
5. 新增 Helper mode 时必须枚举 parser、exit observer、ledger、evidence、release verifier 与 failure-case map，不能等真实发行运行逐个发现消费者漂移。

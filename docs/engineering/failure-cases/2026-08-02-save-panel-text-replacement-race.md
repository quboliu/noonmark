# FAIL-2026-08-02-02：Save Panel 物理文本替换竞态

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T05:46:40Z，隔离 E2E 诊断导出 helper
- 影响版本／构建：0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 的 `e2e`／`dmg-validation` 诊断导出验收
- 引入提交：`d1b3c9a835633e381d7d5d0410820db041cbf640`（`feat(diagnostics): 闭合真实故障证据导出链路`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`（`fix(e2e): 收紧原生交互与发行证据协议`）

## 用户症状与影响

真实诊断闭环已经完成重启证据恢复、打开 Help 菜单、诊断预览和系统 Save Panel，但 helper 偶发在“前往文件夹”输入后等待 exact path 超时，继而以 exit code 1 结束。exit observer 正确记录该非零退出，E2E 发行闭环因此 fail-closed。

本轮完整 E2E 再次在同一原生面板边界判红：Helper 已通过主窗口、双锁、Help 菜单与诊断预览，随后报告 `GoToWindow` AX context 超时。真实截图却明确显示 Cmd-Shift-G 已成功打开前往文件夹 sheet、路径 field 与 suggestion，证明输入投递成功而门禁仍按错误的跨时点 AX 对象／focused-window 语义判定。

故障只发生在固定 `e2e`／`dmg-validation` 验收身份的物理输入 helper；没有启动、读取、定位或 reset production App 与资料。

## 时间线

- `d1b3c9a` 加入诊断 Save Panel 物理输入，但直接依赖系统 text field 当时的隐式选择状态。
- 2026-08-02T05:46:40Z：阶段原因判定修复后首次到达下游 Save Panel，helper 因 exact location value 超时退出。
- 带最小无路径内容探针的重跑再次失败：输入框初始非空，目标 91 字符，最终只有 90 字符。
- 未修改输入逻辑的后三轮又全部通过，证明该问题是未确认系统 UI 状态造成的竞态，偶发绿色不能作为闭环。
- AX 层级取证确认 location field 位于 identifier 为 `GoToWindow` 的 sheet；sheet 内有两个 suggestion row，其中一个会异步转为 selected。location sheet 未消失时，底层 filename field 与其坐标重叠，过早点击会重新聚焦上层 field。
- 2026-08-02 09:14 -04:00：完整 E2E 在诊断导出阶段判红；kernel observer 证明 Helper `normal_exit=true`、`exit_code=1`，ledger 的最终业务错误为等待 exact `GoToWindow` sheet 超时。
- 2026-08-02：第一次复发修复尝试把 savePanel focused 与 field／sheet parent 绑定，但错误要求 Cmd-Shift-G 后 focused window 仍是 savePanel；targeted 真实闭环继续判红，未宣告完成。
- 2026-08-02 09:26 -04:00：外部真实截图证明 `GoToWindow` 已显示，排除快捷键未投递；无 Accessibility 权限的独立 probe 返回零窗口，因此被明确弃用，没有拿无权限结果推断层级。
- 2026-08-02 09:31 -04:00：已有 TCC 权限的签名 Helper 输出最小 AX identity：focused window 是 `AXSheet/GoToWindow`，focused UI 是 `AXTextField/PathTextField`，parent chain 为 `PathTextField → GoToWindow → save-panel → AXApplication`。
- 2026-08-02：按真实状态转换改为 shortcut 前 savePanel focused、shortcut 后 GoToWindow sheet focused，并在同一次 polling snapshot 重读 field、sheet、sheet parent；targeted closure 随后连续三轮通过。

## 复现与证据

重复运行：

```bash
NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 scripts/test-e2e debug
```

失败轮证据：

- `restart-result.txt` 已为 `ready: restart evidence converged`，排除上游恢复超时。
- helper ledger 依序通过 arguments、process、exit observer、permissions、activation、target、双锁、diagnostic window、menu 与 preview；随后记录 `Timed out waiting for exact save-panel location value`。
- 无原始路径差异探针记录：输入框初始值非空、初始长度 72、目标长度 91、最终长度 90；不是 scope 不存在或输入完全未送达。
- kernel observer 记录 `normal_exit=true`、`exit_code=1`；observer 自身没有失败或超时。
- 相同源码随后连续三轮通过，确认故障具有时序性，不能以增加 timeout 解决。
- 本轮失败产物中 `artifacts/e2e-diagnostic-closure/helper/ledger.tsv` 已通过 arguments、process、exit observer、permissions、activation、target、锁、窗口、菜单与 preview，最终只在 `GoToWindow` context 判红；`exit-status.txt` 为正常内核退出、exit code 1。
- 症状截图显示前往文件夹 sheet、路径字段及 suggestion 已真实可见，证明 Cmd-Shift-G 被系统接受；失败来自 AX consumer，而不是 WindowServer 键盘输入。
- 签名 Helper 的失败摘要只记录角色／identifier／关系，不记录 field value：focused window 精确等于 `GoToWindow` sheet；field parent 等于该 sheet；sheet parent 等于原 savePanel。旧 consumer 的 savePanel-focused 假设与实际状态相反。

## 排除的假设

- 排除 canonical scope 漂移：九行 manifest、helper SHA、database、repository lock、export、ledger 与 gate 均通过前置 exact 对账。
- 排除 restart evidence 不完整：App 在启动 helper 前已明确写入 `ready: restart evidence converged`。
- 排除 helper 或 observer 身份错配：PID／launch token／gate 与 exit status 完全一致，observer 精确捕获 exit code 1。
- 排除单纯等待不足：物理输入已产生接近完整的值，且相同源码随后可快速成功；延长等待不会补回丢失字符。
- 排除 production 资料影响：每轮只 reset 并运行固定 `e2e` profile。
- 排除 AX selection ACK 方案：该系统 `PathTextField` 没有稳定暴露 selected text 或 selected text range，不能把不可观察状态伪装成门禁。
- 排除“exact value 后立即 Return”足够：字段值已正确时 suggestion 仍可能尚未选定；Return 之前必须另行确认唯一 selected row。
- 排除 Cmd-Shift-G 没有送达：真实系统 UI 截图已显示 `GoToWindow`、路径字段和 suggestion。
- 排除“shortcut 后 focused window 仍是 savePanel”：签名 Helper 证明 App 的 `kAXFocusedWindowAttribute` 返回 exact `GoToWindow` sheet；它的 parent 才是 savePanel。
- 排除无权限 AX probe 的零窗口结果：该 probe 没有 TCC Accessibility 权限，证据强度不足；最终层级只采用已通过权限门禁的签名 Helper 输出。

## 根因与破坏机制

`performDiagnosticExport` 在打开 Save Panel 的“前往文件夹”sheet 后，只等待任意 focused AX text field，随后立即逐字符发送物理 Unicode 输入。该系统 field 已有非空预填值，而 helper 没有以物理操作建立并确认清空状态。输入因此与系统 field 初始化／隐式选择状态竞态，某些轮次会覆盖或丢失一个字符。

即使 location field 已达到 exact value，helper 也没有等待 suggestion row 的异步 selected 状态和 GoToWindow sheet 真正消失。底层 filename field 与仍存在的 location field 坐标重叠，过早点击会把输入重新送到 location field。两个调用点又没有共享可验证的文本替换协议，所以任一系统 UI 时序变化都可能再次漂移。

先前 fast gate 只检查代码中存在 `GoToWindow` identifier、selected row 与 dismissal 的文字及先后顺序，却没有约束 field、sheet、focused window 与 savePanel 必须来自同一次状态读取。实际实现先捕获“任意 focused text field”，再反复检查这个固定对象的 parent；若捕获发生在 sheet 建立前，它会拿到底层 filename field，正确 sheet 随后出现也无法恢复。

第一次复发修复又把两个生命周期阶段压成同一 focus 语义：shortcut 前 focused window 的确是 savePanel；shortcut 后系统会把 focused window 切换成 `GoToWindow` sheet。要求后者仍等于 savePanel，会在真实 UI 已正确显示时永久判红。

## 根因修复

两个调用点已经收敛到同一物理替换协议：三击精确 field、确认 exact focus、物理发送 Backspace、只读 AX 确认 value 为空，再物理输入目标并确认 exact focus 与 exact value。三击不再被当作替换成功证据；只有 Backspace 后的空值 ACK 才允许继续输入。

location 路径还必须先确认精确 `GoToWindow` sheet 关系，输入后等待 suggestion rows 中恰好一个 `AXSelected=true` 才发送 Return；随后确认 focused window 回到 Save Panel、location field 已失焦且 Save button enabled，才查找并替换 filename field。实现没有使用 AX action／`setValue`，也没有增加 timeout。

复发修复把 focus 状态明确拆成两个阶段：发送 Cmd-Shift-G 前等待 exact savePanel 成为 App focused window；发送后在同一个 `target.wait` snapshot 中重新读取 focused window、focused UI、field parent 与 sheet parent，只接受 `focusedWindow == GoToWindow sheet`、`focusedUI == PathTextField`、`field.parent == sheet`、`sheet.parent == original savePanel`。不再先保存任意 field，也不要求 shortcut 后 focused window 仍是 savePanel。

失败摘要永久保留最小 AX role／identifier／parent identity，使未来门禁判红能直接指出哪条状态假设错误；不记录 field value。fast contract 同时要求原子 context、sheet focus 和 savePanel parent，拒绝旧的分离 field wait。

## 验证结果

- 症状红：相同隔离真实 E2E 两轮在 Save Panel exact location 判红，observer 捕获 exit code 1。
- 时序确认：不改输入逻辑的随后三轮转绿，证明存在竞态且单轮绿不足以关闭。
- Fast 红：共享物理替换协议 contract 在实现前判红。
- Fast 绿：`scripts/test-e2e-evidence-contract` 已约束两个调用点共用物理清空协议、Backspace 后空值 ACK、exact value、GoToWindow identity、唯一 selected suggestion 及 sheet dismissal 顺序。
- 症状绿：修复后 `NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 scripts/test-e2e debug` 连续三轮完成真实 Save Panel location、filename、导出文件、toast 与 helper exit 对账。
- Release 配置绿：同一 targeted closure 以 `scripts/test-e2e release` 完成一次；正式入口改由临时 detached worktree 运行，避免覆盖主工作树 full E2E evidence。
- 复发症状红：完整 E2E 与修复尝试后的 targeted closure 均在 `GoToWindow` context 判红；真实截图与签名 Helper AX 摘要共同推翻“快捷键失败”及“focused window 仍是 savePanel”的假设。
- 复发 Fast 红转绿：加强后的 `scripts/test-e2e-evidence-contract` 在实现前因缺少三元原子 context 判红；实现后要求 shortcut 前 savePanel focus、shortcut 后 sheet focus、field／sheet／savePanel parent、最小失败摘要及旧分离 field wait 禁令并通过。
- 复发 symptom 绿：run `local-20260802-diagnostic-focused-sheet-green-1`、`-2`、`-3` 连续三轮从 reset 后完成失败同步、锁等待、修改拒绝、SIGKILL、重启、Help 菜单、Preview、Save Panel、GoToWindow、双锁导出、隐私与 kernel exit 对账，suite exit status 均为 0。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 的未过滤完整 E2E 在同一真实 Help／Preview／Save Panel 路径确认 shortcut 前 savePanel focus、shortcut 后 `GoToWindow` sheet focus、物理路径与文件名输入、导出文件、toast、隐私与 Helper kernel exit，随后继续完成全部后置探针，suite exit status 为 0。
- Release：待 clean repair commit 的正式发行门禁回填。
- 修复 commit：`b35541e8a5e5ac5290c173b5bc9dae260a63a45c`。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，要求 location 与 filename 共用“物理聚焦／Backspace／空值 ACK／物理输入／exact value”协议，要求 shortcut 前 savePanel focus 与 shortcut 后 exact focused GoToWindow／PathTextField／savePanel parent 的同一 snapshot，并约束 suggestion 与 sheet dismissal 的先后关系；旧分离 field wait 被禁止。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行真实 Help 菜单、预览、系统 Save Panel、双锁、导出、隐私 sentinel 与 helper kernel exit 对账。
- Release：`scripts/test-release-diagnostic-closure` 在 clean HEAD 的独立临时 worktree 强制运行 targeted closure，`scripts/release-private-dmg` 再由 `scripts/test-dmg-install` 对受控派生的同一 DMG 重走真实 Save Panel。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

修复必须通过重复 targeted E2E 和同一 DMG 的两轮真实门禁；单轮绿色不得关闭案例。若空值、suggestion 或 dismissal ACK 在目标系统不可用，继续 fail-closed 并保留原发行阻断，不得只依赖三击、写 AX value、延长 timeout 或跳过 exact value。

修复只改验收 helper 与门禁，不改 production runtime／schema。回滚时撤回 helper 协议提交，保留案例与发行阻断，直到找到同等强度的物理输入协议。

## 教训与永久约束

- “focused text field”不等于“可以安全替换文本”；物理清空、空值与 exact focus 都必须有可观察 ACK。
- 系统 UI 的预填值属于状态机输入，三击只能发起选择，不能替代 Backspace 后的空值证据。
- 字段 exact value 不等于导航状态 ready；异步 suggestion selection 与 sheet dismissal 必须分别确认。
- 物理输入的正确性要检查最终 exact value；偶发成功只能证明路径可行，不能证明协议可靠。
- 原生 sheet 出现后，App 的 focused window 可以从 parent window 切换成 sheet；focused identity 必须按生命周期阶段建模，不能把 parent 关系误作 focus 相等。
- `wait A` 后固定 A、再 `wait A.parent == B` 不是原子状态确认；异步 UI 必须在每轮重新读取整组关联对象，才能从合法 transition 中恢复。

# FAIL-2026-08-01-05：DMG 诊断导出跨进程证据契约漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T04:14:10Z
- 影响版本／构建：0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 与首轮 scope 修复 commit `675cad83df01c5711594f2065eedbb74997d8205` 的 `dmg-validation` 发行验收
- 引入提交：`d16a7cae13f24fe260a0805affa395b725f2e263`（`fix(diagnostics): 收紧诊断证据与窗口查询边界`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：待回填

## 用户症状与影响

首轮真实 DMG 的静态验证、派生 `dmg-validation` App、真实输入、退出、重启和持久化都已通过；后置诊断导出 helper 在解析参数时稳定拒绝 `diagnostic-export resources are outside the exact dmg-validation scope`，因此完整发行门禁判红。

scope 根因修复后，clean `675cad8` 的 targeted release E2E、production package 静态验证，以及派生 `dmg-validation` 的诊断窗口、锁竞争、隐私与导出 package 均已通过；紧随其后的 Bash consumer 却以 `diagnostic export helper omitted exact lock, UI, or package evidence` 拒绝 helper 实际写出的 15 条完整 PASS ledger。第二次失败没有发现产品功能回归，而是证明同一跨进程协议仍有另一份过时 consumer。

这是虚拟机隔离发行 harness 的故障，不证明宿主机状态，也不是 Noonmark 产品的资料导入、退出或同步逻辑回归。失败发生在 helper 打开数据库或读取诊断资料之前。

## 时间线

- `8251113` 的 Bash 调用方把 ledger 与 observer gate 固定在 `artifacts/dmg-install/` 根目录。
- `d16a7ca` 引入 descriptor-bound exact scope，把 Swift 侧 control artifacts 移入 `helper/`，但没有同步 Bash producer 与 evidence fixture。
- 同一 `d16a7ca` 在 diagnostic-export producer 新增 `diagnostic-lock-holder-exit`，但 `scripts/test-dmg-install` 仍保留 `8251113` 的 14 步清单与旧三字段锁断言；Swift producer、E2E consumer 与发行 consumer 因而不再使用同一协议。
- 2026-08-02：clean `61d82a8` 的首次正式门禁在 diagnostic-export 参数校验判红；对同一 DMG 再跑一次仍在相同守卫失败。
- 同一任务的 pre-commit review 进一步发现 manifest schema reader 仍复制在五个 Bash 消费端，且 E2E control directory 实际 mode 为 `0755`；两项都在提交前并入同一根因修复。
- 2026-08-02：clean `675cad8` 的正式门禁完成 scope、真实 UI、双锁竞争、隐私与 package 验收后，被过时的 `test-dmg-install` ledger consumer 判红；归档 ledger 实际包含按序的 15 条 PASS，包括 `diagnostic-lock-holder-exit`。
- 随后冻结真实 App／DMG 重跑并执行全量静态协议审计，进一步发现 exercise／restart 的 `quit-menu`、helper exit `fflags`、activation detail、release closure run ID／source／inventory 和 fixture scope 路径仍有复制或过时定义。
- clean-tree 失败路径审查还发现：临时 worktree 尚未建立时，空 `gate_worktree` 会被拼成根级 `/artifacts/e2e-*` 读取边界；未发现该路径存在或资料被复制，但该边界仍属 fail-closed 缺陷，现已由 dirty-source trace 负例阻断。
- 静态中断 probe 证明 closure 把 `EXIT`、`INT` 与 `TERM` 共用同一 `$?` 时，命令间隙收到 `TERM` 会得到 `handler_status=0` 与 `process_status=0`，把中断误报为成功；同轮还发现 observer gate 与 ledger helper PID／token 仍由最终 verifier 手写解析。

## 复现与证据

在 clean commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 上先后运行：

```bash
scripts/release-private-dmg
scripts/test-dmg-install dist/Noonmark.dmg
```

两次都以同一错误退出。两轮的 exercise／restart ledger 均先证明 activation、真实菜单、物理输入、App 内退出、进程消失、重启与资料持久化通过；随后 diagnostic-export 在 `Configuration.parse` 的 exact-scope equality 前置守卫判红。失败 manifest 固定 `production_app_executed=false`。

scope 修复后在 clean `675cad83df01c5711594f2065eedbb74997d8205` 上运行同一正式入口，targeted release E2E、package／static gate 与真实 `dmg-validation` diagnostic-export 都先通过；`scripts/test-dmg-install` 随后稳定输出：

```text
diagnostic export helper omitted exact lock, UI, or package evidence
```

同轮 `diagnostic-export` ledger 有 15 条、且全部为 PASS；生产者在 `diagnostic-package` 后写出 `diagnostic-lock-holder-exit`。失败来自 consumer 仍按旧清单解释新 ledger，不是 helper 缺少证据。该轮仍固定 `production_app_executed=false`。

审查扩展证据：`scripts/verify-development-validation-evidence --scope runtime` 的旧 targeted gate 产物因 `suite_mode=only:diagnostic-closure` 判红；同轮 `artifacts/e2e-diagnostic-closure/helper` 的 mode 为 `0755`、owner UID 才与当前用户一致，证明 E2E 侧尚未满足 owner-only control contract。

## 排除的假设

- 排除产品输入、退出或重启回归：两轮 exercise／restart ledger、SQLite 持久化与进程消失均先通过。
- 排除 helper binary 或签名漂移：helper start／end SHA、designated requirement 与 strict codesign 证据一致。
- 排除偶发 WindowServer 时序：同一 clean DMG 连续两轮都在 helper 打开数据库前的 exact scope equality 稳定失败。
- 排除仅修正两个 basename 即可根治：Swift、Bash、E2E、fixture 与 verifier 各自持有 layout／schema 片段，单点改名仍会留下多个 producer。
- 排除 production 资料影响：失败 manifest 固定 `production_app_executed=false`，动态路径只使用 `dmg-validation`／`e2e` profile。
- 排除 scope 修复后的产品诊断导出失败：clean `675cad8` 已完成真实诊断窗口、物理菜单与保存面板、锁竞争、隐私 sentinel 和 package 对账；判红发生在 helper 正常退出后的 Bash ledger 复核。
- 排除 helper 漏写 holder-exit：归档 ledger 明确含一条按序 PASS `diagnostic-lock-holder-exit`；旧 consumer 的 required steps 根本没有该步骤。
- 排除单纯把 14 改成 15 即可根治：静态审计还发现 `quit-menu`、activation、exit result、锁 vnode 三段对账及 release closure 关联分别复制在多个 consumer，继续逐点补数组会再次漂移。

## 根因与破坏机制

`8251113` 的 Bash 调用方最初把 ledger 与 observer gate 放在 `artifacts/dmg-install/` 根目录。`d16a7ca` 新增 descriptor-bound exact-scope contract 后，把两者统一派生为 `artifacts/dmg-install/helper/ledger.tsv` 与 `helper/exit-observer-gate.txt`，但没有同步真实 Bash producer。Swift 单测只验证 Swift fixture，evidence fixture 又独立固化 Bash 旧布局；双方各自自洽，却没有跨边界门禁。

根因不是两个 basename 或一个步骤拼错，而是同一跨进程发行协议存在 Swift producer、多个 Bash consumer、最终 verifier 与 evidence fixture 多份独立定义。`d16a7ca` 同时演进 scope 和 diagnostic ledger 后，各份实现仍可各自通过局部测试，却不能证明彼此使用相同布局、步骤、锁 identity、退出状态与 run identity。任何单点演进都可能再次漂移。

## 根因修复

1. 将 `DiagnosticExportScopeContract` 提升为唯一 canonical layout，由同一派生函数同时服务 validation、descriptor pinning 与版本化 TSV manifest。
2. 新增纯词法 `diagnostic-export-scope` CLI，只接受精确 App path 与 `e2e|dmg-validation` profile；不启动 App、不打开资料、不探测 production。
3. 发行、E2E、fixture 与 verifier 以已捕获 SHA-256 的同一 helper binary 获取 scope；唯一共享 shell parser 严格解析固定 key／顺序／版本，消费者不再复制 schema，也不使用 `eval` 或把 manifest 当 shell source。
4. ledger 与 gate 迁入 canonical control directory；DMG 与 E2E 都以 mode `0700` 创建并在使用前后复核 owner、mode 与非 symlink，ledger 必须全新 descriptor-bound 创建，observer 以 `O_EXCL|O_NOFOLLOW` 临时文件和 `RENAME_EXCL` 原子发布。
5. verifier 从归档 scope manifest 取得 export、sentinels、ledger 与 gate，不再维护第三份路径；scope manifest、空 stderr 与 helper SHA 纳入 runtime manifest 和最终 inventory。
6. 拒绝信息带具体漂移字段，使日志直接回答哪条路径假设错误。
7. 以版本化 `dmg-harness-ledger-contract.tsv` 作为六种 helper mode 的 canonical Bash／fixture 精确 PASS 步骤清单；Swift producer 使用 typed mirror 在写 ledger 时同步自校验，并由进入 `scripts/check` 的 Swift 测试逐 mode 对账两者。所有 Bash consumer 共用同一 parser，并拒绝缺失、重复、乱序和额外步骤。
8. 将 helper process／observer identity、observer gate、activation、九字段 helper exit result 与 diagnostic lock evidence 提升为共享 parser；锁证据同时绑定 target PID、SQLite／repository lock 的 device／inode，要求 before、after 与 holder-exit 三段 identity 完全一致；exit result 必须同时带 `NOTE_EXIT | NOTE_EXITSTATUS`，拒绝旧三字段、零 flags 或非零无关 flags。
9. release 入口在任何真实 App 前先验证同 run 的完整静态与 runtime evidence；diagnostic closure 清除旧证据后才检查 clean source，沿用同一 run ID，并把 inner E2E manifest、source tree、log、result 与 inventory 哈希全部纳入最终五方对账。outer／inner manifest 的 source tree 与 dirty state 必须在开始、结束完全稳定；`result.txt` 必须精确表达本轮 commit、run ID、零 exit code 与 PASS，`restart-result.txt` 必须精确表达 manifest 声明的重启结果，不能用重新计算过的哈希掩盖语义伪造。closure／runtime 根只有在非空临时 worktree 建立后才允许派生，dirty-source 负例以 shell trace 证明不会落到根级 `/artifacts`。
10. closure 的正常退出与信号清理使用不同 trap；`INT` 固定返回 130，`TERM` 固定返回 143，不能再从信号到达前一条成功命令继承零状态。清理失败也不能把原本成功的退出保持为绿。
11. evidence fixture 不再硬编码 diagnostic export／sentinel 路径，并新增针对步骤漂移、process／observer identity、observer gate、vnode 漂移、holder 异常退出、零或非零无关 exit flags、stale closure run、outer／inner source-end、closure result／restart result 与 inventory 自洽伪造的负例。

## 验证结果

- TDD 红：新增 scope mode 测试在实现前因 mode 与 manifest emitter 不存在而编译判红。
- Fast：canonical scope 与 descriptor ledger 专项 18 项通过；唯一 shared parser、E2E `0700` control contract 与 observer typecheck 通过。
- Fast：harness ledger producer／consumer exact-contract 专项 2 项 Swift 测试与缺失／乱序／额外步骤 fixture 通过；process／observer identity、observer gate／exit、锁 evidence、foreground ownership、release ordering／same-run closure 与 signal fail-closed 专项门禁通过。
- Fast：完整 DMG evidence fixture 通过；它会同时重算伪造产物的哈希与 inventory，仍正确拒绝 nonzero unrelated `fflags`、outer／inner source-end 漂移及 closure result／restart result 语义漂移。
- Fast：提交前完整 `scripts/check` 通过；后续真实发行闭环只接受最终 clean commit 上同一 run ID 的新证据，不复用本轮 dirty-worktree 产物。
- 症状与 release：待同一 clean DMG 连续两轮由红转绿后回填。
- 修复 commit：待回填。

## 永久门禁

- Fast：`scripts/test-dmg-diagnostic-scope-contract`、`scripts/test-dmg-harness-evidence-contract`、`scripts/test-diagnostic-lock-evidence-contract` 与 `scripts/test-release-gate-contract`，均由 `scripts/check` 强制执行；覆盖唯一 scope emitter、producer 自校验的精确步骤协议、共享 process／observer／activation／exit／lock parser、三段 lock vnode 对账、signal fail-closed、同一 run／source closure 和旧证据清除顺序。
- Symptom：`scripts/test-dmg-install`，由 `scripts/release-private-dmg` 强制执行真实诊断窗口、菜单、保存面板、双锁竞争与隐私 sentinel。
- Release：同一真实 DMG 入口对账 package identity、scope manifest、helper identity、diagnostic package 和最终 artifact inventory。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

正式候选必须在同一 clean commit 上连续两轮真实门禁转绿。若任一 scope、identity、descriptor、ledger、closure 或 inventory 证据缺失，继续 fail-closed；不得退回旧的扁平路径、放宽 exact equality，或把诊断阶段从 release gate 删除。

- 风险：本次只收紧测试／发行 harness，不改产品功能；主要风险是共享 parser 误拒绝合法证据，因此先以正／负 fixture、完整 `scripts/check` 和 isolated E2E 分层验证。
- 回滚：若新门禁自身错误，回滚整个门禁修复 commit，保留已知 candidate DMG 供比对；不得通过删除步骤或放宽证据继续发行，也不迁移或修改任何 production 资料。
- 灰度：静态与变异 fixture 全绿后，先跑 clean isolated `e2e` diagnostic closure，再 package／static verify，随后仅运行受控派生的 `dmg-validation`，最后执行完整五方 verifier；任一层失败即停止。
- 监控：逐轮对账同一 `evidence_run_id`、source commit／tree、artifact inventory、helper／App identity、DiagnosticReports delta 与 `production_app_executed=false`。

用户明确要求的紧急候选 DMG 可以独立标识交付，但不得描述为完整发行门禁已通过；正式候选仍须完成本案例闭环。

## 教训与永久约束

- 安全边界的路径布局必须有唯一 producer；多个语言各自复制常量只会制造“各自通过、集成失败”。
- 版本化 manifest 的 parser 也必须唯一；唯一 producer 配上五份 schema reader 仍是 shotgun surgery。
- fixture 自洽不能证明跨进程协议一致；真实调用方参数必须回喂消费者本身验证。
- 哈希只能证明内容没变，不能证明内容正确；scope 还必须绑定同一 helper binary、profile、App identity 与 production 隔离边界。
- 关键控制文件要同时防止 symlink、预先植入、覆盖和目录替换，不能只验证最终 basename。
- 虚拟机证据只证明虚拟机中的隔离验证路径，不得表述为宿主机已修复。
- 协议步骤必须由 producer 在写入时自校验，不能只让下游按各自数组解释同一 ledger。
- “同一轮发行”必须由可交叉验证的 run ID、source tree 与 inventory 定义，不能靠目录名、调用顺序或 ad hoc result 文件推断。
- `EXIT` 状态不能复用为 signal 状态；中断必须使用固定非零退出码，并复用同一幂等清理函数。

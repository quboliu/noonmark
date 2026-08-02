# FAIL-2026-08-01-05：DMG 诊断导出调用方与 helper scope 漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T04:14:10Z
- 影响版本／构建：0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 的 `dmg-validation` 发行验收
- 引入提交：`d16a7cae13f24fe260a0805affa395b725f2e263`（`fix(diagnostics): 收紧诊断证据与窗口查询边界`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：待回填

## 用户症状与影响

真实 DMG 的静态验证、派生 `dmg-validation` App、真实输入、退出、重启和持久化都已通过；后置诊断导出 helper 在解析参数时稳定拒绝 `diagnostic-export resources are outside the exact dmg-validation scope`，因此完整发行门禁判红。

这是虚拟机隔离发行 harness 的故障，不证明宿主机状态，也不是 Noonmark 产品的资料导入、退出或同步逻辑回归。失败发生在 helper 打开数据库或读取诊断资料之前。

## 时间线

- `8251113` 的 Bash 调用方把 ledger 与 observer gate 固定在 `artifacts/dmg-install/` 根目录。
- `d16a7ca` 引入 descriptor-bound exact scope，把 Swift 侧 control artifacts 移入 `helper/`，但没有同步 Bash producer 与 evidence fixture。
- 2026-08-02：clean `61d82a8` 的首次正式门禁在 diagnostic-export 参数校验判红；对同一 DMG 再跑一次仍在相同守卫失败。
- 同一任务的 pre-commit review 进一步发现 manifest schema reader 仍复制在五个 Bash 消费端，且 E2E control directory 实际 mode 为 `0755`；两项都在提交前并入同一根因修复。

## 复现与证据

在 clean commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2` 上先后运行：

```bash
scripts/release-private-dmg
scripts/test-dmg-install dist/Noonmark.dmg
```

两次都以同一错误退出。两轮的 exercise／restart ledger 均先证明 activation、真实菜单、物理输入、App 内退出、进程消失、重启与资料持久化通过；随后 diagnostic-export 在 `Configuration.parse` 的 exact-scope equality 前置守卫判红。失败 manifest 固定 `production_app_executed=false`。

审查扩展证据：`scripts/verify-development-validation-evidence --scope runtime` 的旧 targeted gate 产物因 `suite_mode=only:diagnostic-closure` 判红；同轮 `artifacts/e2e-diagnostic-closure/helper` 的 mode 为 `0755`、owner UID 才与当前用户一致，证明 E2E 侧尚未满足 owner-only control contract。

## 排除的假设

- 排除产品输入、退出或重启回归：两轮 exercise／restart ledger、SQLite 持久化与进程消失均先通过。
- 排除 helper binary 或签名漂移：helper start／end SHA、designated requirement 与 strict codesign 证据一致。
- 排除偶发 WindowServer 时序：同一 clean DMG 连续两轮都在 helper 打开数据库前的 exact scope equality 稳定失败。
- 排除仅修正两个 basename 即可根治：Swift、Bash、E2E、fixture 与 verifier 各自持有 layout／schema 片段，单点改名仍会留下多个 producer。
- 排除 production 资料影响：失败 manifest 固定 `production_app_executed=false`，动态路径只使用 `dmg-validation`／`e2e` profile。

## 根因与破坏机制

`8251113` 的 Bash 调用方最初把 ledger 与 observer gate 放在 `artifacts/dmg-install/` 根目录。`d16a7ca` 新增 descriptor-bound exact-scope contract 后，把两者统一派生为 `artifacts/dmg-install/helper/ledger.tsv` 与 `helper/exit-observer-gate.txt`，但没有同步真实 Bash producer。Swift 单测只验证 Swift fixture，evidence fixture 又独立固化 Bash 旧布局；双方各自自洽，却没有跨边界门禁。

根因不是两个 basename 拼错，而是同一安全布局存在 Swift、Bash 与 evidence fixture 多份独立定义。任何单点演进都可能再次漂移。

## 根因修复

1. 将 `DiagnosticExportScopeContract` 提升为唯一 canonical layout，由同一派生函数同时服务 validation、descriptor pinning 与版本化 TSV manifest。
2. 新增纯词法 `diagnostic-export-scope` CLI，只接受精确 App path 与 `e2e|dmg-validation` profile；不启动 App、不打开资料、不探测 production。
3. 发行、E2E、fixture 与 verifier 以已捕获 SHA-256 的同一 helper binary 获取 scope；唯一共享 shell parser 严格解析固定 key／顺序／版本，消费者不再复制 schema，也不使用 `eval` 或把 manifest 当 shell source。
4. ledger 与 gate 迁入 canonical control directory；DMG 与 E2E 都以 mode `0700` 创建并在使用前后复核 owner、mode 与非 symlink，ledger 必须全新 descriptor-bound 创建，observer 以 `O_EXCL|O_NOFOLLOW` 临时文件和 `RENAME_EXCL` 原子发布。
5. verifier 从归档 scope manifest 取得 export、sentinels、ledger 与 gate，不再维护第三份路径；scope manifest、空 stderr 与 helper SHA 纳入 runtime manifest 和最终 inventory。
6. 拒绝信息带具体漂移字段，使日志直接回答哪条路径假设错误。

## 验证结果

- TDD 红：新增 scope mode 测试在实现前因 mode 与 manifest emitter 不存在而编译判红。
- Fast：canonical scope 与 descriptor ledger 专项 18 项通过；唯一 shared parser、E2E `0700` control contract 与 observer typecheck 通过。
- 症状与 release：待同一 clean DMG 连续两轮由红转绿后回填。
- 修复 commit：待回填。

## 永久门禁

- Fast：`scripts/test-dmg-diagnostic-scope-contract`，由 `scripts/check` 强制执行；覆盖唯一 emitter／shared parser、严格 CLI schema、同一 helper 身份、E2E owner-only control、禁止旧布局、exclusive/no-follow publication 与专项测试。
- Symptom：`scripts/test-dmg-install`，由 `scripts/release-private-dmg` 强制执行真实诊断窗口、菜单、保存面板、双锁竞争与隐私 sentinel。
- Release：同一真实 DMG 入口对账 package identity、scope manifest、helper identity、diagnostic package 和最终 artifact inventory。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

正式候选必须在同一 clean commit 上连续两轮真实门禁转绿。若任一 scope、identity 或 descriptor 证据缺失，继续 fail-closed；不得退回旧的扁平路径、放宽 exact equality，或把诊断阶段从 release gate 删除。

用户明确要求的紧急候选 DMG 可以独立标识交付，但不得描述为完整发行门禁已通过；正式候选仍须完成本案例闭环。

## 教训与永久约束

- 安全边界的路径布局必须有唯一 producer；多个语言各自复制常量只会制造“各自通过、集成失败”。
- 版本化 manifest 的 parser 也必须唯一；唯一 producer 配上五份 schema reader 仍是 shotgun surgery。
- fixture 自洽不能证明跨进程协议一致；真实调用方参数必须回喂消费者本身验证。
- 哈希只能证明内容没变，不能证明内容正确；scope 还必须绑定同一 helper binary、profile、App identity 与 production 隔离边界。
- 关键控制文件要同时防止 symlink、预先植入、覆盖和目录替换，不能只验证最终 basename。
- 虚拟机证据只证明虚拟机中的隔离验证路径，不得表述为宿主机已修复。

# FAIL-2026-08-11-28：烛龙 pending-gate 保留 V1 baseline oracle

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T21:25:21-04:00
- 影响版本／构建：未发行的 schema 19 Replication V2 工作树
- 引入提交：`883f96495be703eb469630f6013027891e5b49b3` `docs(readme): Build the Noonmark v1.0 product homepage` 引入 V1 preferences journal oracle；`fd77ee795dccf73894bc9547c51234f0659f5183` `test(sync): align pending recovery fixture` 把总 journal 数固定为 1
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同值
- 实际修改者：既有提交的实际修改者未知；本次 clean cut 与门禁修正可由当前 Codex session 和工作树确认
- 修复提交：待回填

## 用户症状与影响

全量真实 App E2E 在烛龙 pending application setup 后失败，报告 SQLite 事实为 `onlineFirst 0 0 0 0 0 0 0`，测试却要求最后两项 V1 journal 计数为 1。失败发生在 setup oracle，令后续真实 SQLite writer lock、重启恢复和全局写围栏没有执行，也阻断最终回归闭环。

## 时间线

- 2026-07-28：E2E 加入 `formatVersion=6`、`pendingUpload`、`noonmark.bootstrap` 的 V1 preferences baseline 断言。
- 2026-08-08：断言进一步要求 `change_journal` 总数精确为 1。
- 2026-08-11：用户批准开发期 clean cut；`replaceForDataImport` 停止制造 V1 baseline journal。
- 2026-08-11T21:25:21-04:00：完整真实 App E2E 稳定取得 current schema 19、空 Engine、零 journal，却被陈旧 oracle 判红。

## 复现与证据

`scripts/test-e2e` 已经以签名 `app.noonmark.mac.e2e` 运行 setup automation。真实产物显示：setup result 为成功；加密 sidecar 恰有一个 Session 和一个 pending application journal；SQLite `user_version=19`、`app.data_mode=onlineFirst`、五类 Engine 事实均为零、12 项 current settings 完整、V1 `change_journal` 为零，V2 authority／outbox／publication 也均为零。原脚本随后只因期待 V1 `formatVersion=6` journal 而退出 1。

## 排除的假设

- 不是 pending sidecar 落盘失败：automation 保存后做 exact round-trip，产物也存在一份 journal 与一份 Session。
- 不是读错数据库或 profile：真实 App 的 `--data-url` 与 SQL probe 指向同一隔离证据目录，bundle 固定为 `e2e`。
- 不是 schema 初始化失败：运行产物明确为 exact schema 19，当前 settings 和本机 preferences 完整。
- 不是 V2 replication 初始化遗漏：该场景同步明确关闭，只验证烛龙跨 SQLite／sidecar 的恢复围栏，不应凭空建立 replication authority。

## 根因与破坏机制

clean cut 删除了数据导入／替换阶段生成 V1 baseline journal 的行为，但烛龙 pending-gate 仍把这项已退役的 V1 副作用当成 setup 正确性的必要条件。测试把同步实现细节误当作烛龙恢复领域事实，导致正确的 clean-cut 状态被判为故障。

## 根因修复

- pending-gate setup oracle 改为正向验证 exact schema 19、空 Engine、本机 preferences、12 项 current settings、零 V1 journal 和同步关闭时的零 V2 replication ledger。
- 保留一份 pending journal、一份 Session、三个 Engine snapshot 互异、真实 SQLite writer lock、所有写入口被拒、重启前后数据库与 sidecar bytes 不变等原症状级证据。
- clean-cut fast gate 静态拒绝 `formatVersion=6` pending-gate oracle 回流。

## 验证结果

- 修复前完整真实 App E2E 稳定判红，精确输出为 schema 19 clean-cut 状态与旧期望不符。
- clean-cut fast gate 通过：current format 7 round-trip 与 format 6 typed rejection 共 2 项、0 失败；故障案例映射共 103 个案例并 fail-closed 通过。
- focused 签名 App pending-gate 通过：setup 与 verify 均为 `ok`，真实 SQLite writer lock 下 direct Engine save、Store persist、自然日 rollover、数据导入和同步启动均被围栏拒绝。
- 完整签名 App E2E 通过：48 个场景、英文 10／10、烛龙 pending-gate、current format 7 File → Import、诊断异常终止闭环与 V2 lifecycle 全部转绿；manifest 为 `suite_exit_status=0`，source start／end、App binary 与 helper binary 均一致，新增 DiagnosticReports 为零。
- 最终 `make check` 运行 `20260812T022243Z-83938` 已以 `suite_exit_status=0` 结束，source start／end worktree OID 一致，104 个故障案例映射通过。修复提交仍待建立，因此案例按规则保持「处理中」。

## 永久门禁

- fast：`scripts/test-development-data-clean-cut` 由 `scripts/check` 强制运行，静态拒绝 V1 format 6 pending-gate oracle 回流。
- symptom：`scripts/test-e2e` 由 `scripts/test-all` 运行签名 App，并以真实 SQLite writer lock、重启和字节级 sidecar 不变验证 pending application 全局写围栏。

## 发行与回滚

- 风险：只删除旧断言可能弱化 setup 证据；修复同时增加 schema、完整 settings、preferences 与零 ledger 正向断言，避免只看“没有崩溃”。
- 回滚：若新 oracle 与 schema 19 真实约束不符，只回退本测试和案例改动后重新取证；不恢复 V1 baseline 生成，不操作 production 或任何 iCloud 对象。
- 灰度：先运行 clean-cut fast gate，再运行 focused 签名 App pending-gate，最后运行完整 E2E 与 `make check`。
- 监控：门禁只记录 typed 计数、schema 和 suite verdict，不记录用户资料、sidecar payload、路径、账号或凭证。

## 教训与永久约束

1. 跨存储恢复测试必须断言领域不变量，不得绑定已经退役的同步实现副作用。
2. clean cut 要同步审计完整真实 E2E 的 SQL oracle；源码删除旧路径不等于测试已删除旧假设。
3. 删除旧 oracle 时必须补上 current schema 的正向事实，不能用减少断言换取绿色。

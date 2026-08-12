# FAIL-2026-08-11-25：旧本机 schema 与旧数据包兼容路径越过开发期 clean cut

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-11T19:39:00-04:00
- 影响版本／构建：未发行的 schema 19 Replication V2 工作树
- 引入提交：`26f0cb91f0be8e756cc48b87b316a11200916aeb` `merge(release): integrate sync diagnostics with Feiguang compatibility`；`1f264ff9c38047c8ac959e9d0cd624c70d495116` 后续延续 schema migration；v18→v19 路径属于尚未提交的本次工作树
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同值；`mxt <mxt@local.com>`／同值
- 实际修改者：既有提交的实际修改者未知；v18→v19 未提交扩展可由本次 Codex session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

用户已明确要求开发期不兼容任何旧路径或旧资料，只允许清空后重新同步。审查却发现 App 仍会自动把 SQLite v15／v17／v18 改成 v19，并继续接受 JSON format 6；真实 File → Import E2E 还主动制造旧 format 6 fixture。若进入候选包，旧资料会被静默解释、改表或删除旧同步状态，违反 clean cut。

## 时间线

- 早期提交为了上一候选版本增加 v15／v17 migration 与 format 6 decoder。
- 本次 V2 工作树把相同模式延伸为 v18→v19 migration。
- 2026-08-11 用户明确取代旧兼容承诺，要求本机、远端与数据包都不背历史包袱。
- 2026-08-11T19:42:54-04:00：新拒绝门禁稳定判红，三个旧 schema 全部被自动改为 v19。
- 2026-08-11T19:44:46-04:00：format 6 拒绝门禁判红，decoder 实际成功导入。

## 复现与证据

受控 SQLite fixture 分别设置 `user_version` 15、17、18 并保存开库前 bytes 与旧 facts。修复前 repository 没有抛错：v15 新建飞光表，v17 清空 conflict evidence，v18 新建八张 V2 ledger 表，三者均把版本改成 19。受控 canonical format 6 package 在修复前同样成功 decode。

## 排除的假设

- 不是 iCloud repository compatibility：问题在本机 SQLite 与 File → Import 两条独立入口，尚未接触 iCloud。
- 不是只读探测：migration 明确启用 WAL、开启 IMMEDIATE transaction 并执行 DDL／DML。
- 不是当前备份会受损：用户提供的 2026-08-11 备份只读取顶层版本字段，确认是 current format 7。
- 不是必须保留已发行用户资料：用户明确确认项目开发期没有外部用户，并审核批准移除兼容。

## 根因与破坏机制

架构 clean cut 只落实到远端 repository 与 V2 runtime，旧的版本治理门禁仍把“上一版本自动升级”当成永久正确性。这个隐含前提没有随用户决策一起翻转，导致 source、unit test、真实 E2E 与故障案例互相强化错误兼容路径。

## 根因修复

- `SQLiteSchema` 只允许空库建立 schema 19，或 exact schema 19 验证后打开；删除所有旧版本分支、migration helper、DDL／DML 转换。
- exact version 19 也必须先验证完整 schema fingerprint，成功后才允许启用 WAL；版本号正确但 table／index 漂移时，拒绝前后主数据库 bytes、journal mode 与 sidecar inventory 必须完全不变。
- v15／v17／v18 fixture 改为断言 typed rejection、主数据库 bytes 不变、`user_version` 不变与旧 facts 不变。
- `NoonmarkDataPackage` 只接受 canonical current format 7；删除 format 6 常量、decoder、snapshot adapter 与 encoder。
- 真实 File → Import E2E 改用 `NoonmarkDataPackage.write` 产生 current format 7 fixture。
- iCloud root 解析提升为独立 `ICloudDriveRepositoryLocator`；V2 Store、V2 endpoint 与 append-only test namespace 禁止引用 V1 `ICloudDriveSyncTransport` helper，移除旧 transport error seam。

## 验证结果

- SQLite clean-cut 专项：旧 schema 与 current-version drift 均零迁移拒绝；current-version drift 在 `journal_mode=delete` 时判红，修复后拒绝仍保持 `delete`、主数据库 bytes exact 且没有 WAL sidecar。
- DataPackage clean-cut 专项：2 项、0 失败；current format 7 round-trip，format 6 明确拒绝。
- 真实签名 App E2E、最终 `make check` 与 release evidence 尚待本任务后续完成；因此案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-replication-v2-schema-contract` 由 `scripts/check` 强制执行，静态拒绝旧 migration symbol，并运行 current-version schema drift 必须先于 WAL 的症状测试。
- fast：`scripts/test-development-data-clean-cut` 由 `scripts/check` 强制执行，并静态拒绝旧 DataPackage decoder 与旧 E2E fixture path。
- fast：`scripts/test-replication-v2-app-stress-contract` 由 `scripts/test-replication-v2-recovery-contract` 强制执行，拒绝 V2 Store 或 iCloud endpoint 重新依赖 V1 transport。
- symptom：`scripts/test-e2e` 由 `scripts/test-all` 运行真实签名 App，证明 fresh schema 19 启动与 current format 7 File → Import、确认、SQLite 替换及重启回读。
- release：`scripts/verify-development-validation-evidence` 由 `scripts/release-private-dmg` 消费同 source 的完整签名 App 证据。

## 发行与回滚

- 风险：旧本机数据库与 format 6 包不再打开；这是用户批准的预期 clean cut，不得以隐藏 fallback 恢复。
- 回滚：V2 尚未发布；若 current schema 19 或 format 7 自身回归，只回滚未发行的本切片并重建非 production profile，不恢复旧 decoder／migration，也不操作任何 iCloud 对象。
- 灰度：受控 SQLite／JSON fixture → fresh 非生产 profile → 签名 `e2e` 真实 App → 私有 DMG validation。production 不进入 Agent 验证。
- 监控：只记录 typed schema／format verdict 与阶段计数，不记录路径、任务正文、payload、identity 或原始 Error。

## 教训与永久约束

1. clean cut 必须同时翻转 source、unit test、真实 E2E、故障案例和版本治理门禁，不能只改远端 adapter。
2. 旧格式 decoder 与 migration 即使“暂时不可达”仍是兼容 capability；用户批准移除后必须从 source 删除。
3. 当前备份能否导入必须以顶层 format 与真实 App 路径证明，不能借保留所有历史 decoder 来兜底。

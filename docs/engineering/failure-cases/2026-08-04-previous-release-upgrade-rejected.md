# FAIL-2026-08-04-23：上一版本机资料与 JSON 数据包在新版被拒绝

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04（合并前发布兼容性审查）
- 影响版本／构建：未发布的想法捕捉整合版本；从 0.2.0（5）升级会在启动或导入时被拒绝
- 引入提交：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` `feat(ideas): 原生想法记录与置顶、回收站、标签过滤`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 和现有 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

用户从上一版升级后，新 App 会拒绝非空的 SQLite schema v15，无法打开既有本机资料。用户选择上一版导出的 canonical JSON 时，format v6 也会被拒绝，因此无法通过导入恢复旧资料。

故障影响所有从 0.2.0 升级的用户；不涉及 production 资料读取、复制或探测。本案例的测试只构造受控 v15 SQLite fixture 和无业务正文的测试 JSON。

## 时间线

- 0.2.0 发布时 SQLite schema 为 v15，数据包 format 为 v6。
- `ff86af0` 新增飞光实体后将 schema 升至 v17、数据包升至 v7，但启动仅接受空库或当前 schema，decoder 仅接受 v7。
- 2026-08-04 合并前审查以 v15／v6 源码和运行测试确认兼容路径缺失。

## 复现与证据

原始失败条件由源码和可执行测试确认：`SQLiteSchema.installOrValidateUncached` 对非空 v15 进入“only an empty store or the current schema is supported”；`NoonmarkDataPackage.decode` 对 v6 返回 unsupported format version。

受控升级测试先创建含任务与 sync journal 的 v15 shape，再由新版 repository 打开；修复前该场景判红，修复后回读 snapshot、journal 与 schema version。旧包测试将 canonical v6 envelope 导入新版并对账 snapshot（飞光列表为空）。

## 排除的假设

- 排除 clean cut 规则要求 production 数据不迁移：该规则只适用于非生产开发 fixture，日常用户升级必须保持资料兼容。
- 排除只需放宽版本检查：旧库的两张同步表必须扩展 entity-type 约束；直接改 `user_version` 会让后续飞光同步写入失败。
- 排除 JSON 可接受任意旧结构：只接受准确的 canonical v6，未知版本、缺字段与非 canonical bytes 仍拒绝。

## 根因与破坏机制

飞光数据模型同时扩展了本机表、同步 entity-type 枚举和数据包 snapshot。实现只修改“新库创建”及“当前包读取”路径，遗漏了上一稳定发行物到当前模型的转换边界，导致升级和恢复两条用户路径同时断裂。

## 根因修复

- 在单一 IMMEDIATE transaction 内支持 v15 → v17：新增飞光表，并重建两个仅变更 check constraint 的同步表后逐列回填旧资料与依赖。
- 只支持紧邻上一发行版本；其他非空版本继续 fail-closed。
- 支持严格 canonical v6 decoder，映射到当前 snapshot 的空飞光集合；新导出仍只写 v7。
- 真实 File → Import E2E 固定选择 v6 fixture，继续经过原生选择、确认、SQLite 替换与重启回读。

## 验证结果

- Fast：待最终 `make check` 回填。
- Symptom：待最终真实 App E2E 回填。
- 修复提交：待回填。

## 永久门禁

- Fast：`scripts/test-unit` 经 `scripts/check` 执行 `SQLiteSchemaTests.testVersion15StoreMigratesInPlaceWithoutLosingDataOrSyncJournal` 与 `DataPackageTests.testJSONDataPackageImportsCanonicalPreviousV6Package`。
- Symptom：`scripts/test-e2e` 经 `scripts/test-all` 执行真实 File → Import，固定选择 canonical JSON v6 并验证确认、SQLite 替换与重启回读。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：迁移只重建约束扩展的同步表；若事务中任一步失败会 rollback，旧资料与 `user_version` 保持不变。
- 回滚：停止候选发行并回滚修复提交；不得通过删除用户 SQLite 或放宽任意未知 schema 来绕过。
- 灰度：先运行 v15 升级和 v6 导入专项门禁，再运行完整 `make check`、真实 E2E 与受控发行验证。
- 监控：本机诊断只保留结构化启动／持久化失败码，不记录用户任务、JSON 内容或资料路径。

## 教训与永久约束

1. 每次实体或数据包版本升级都必须同时实现并测试“上一稳定发行物 → 当前”的 SQLite 与 JSON 边界。
2. 开发 fixture clean cut 不能外推为用户日常资料可丢弃。
3. schema version 不是可直接改写的标记；约束变化必须以可回滚的资料保留迁移完成。
4. 旧格式兼容必须精确、可验证且有退出边界，不能把任意历史或畸形输入视为可导入。

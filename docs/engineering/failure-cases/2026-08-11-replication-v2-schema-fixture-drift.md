# FAIL-2026-08-11-03：Replication V2 schema 夹具漂移令旧版本升级误判 fingerprint

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:35:33-04:00
- 影响版本／构建：未发行的 schema 19 工作树
- 引入提交：未提交；本次 Replication V2 ledger schema 切片
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

没有进入发行或 production。扩大 Storage 回归时，schema current-version 契约仍预期 18，v15／v17 upgrade 测试则被当前 schema fingerprint 拒绝。若不修复，既有资料库升级门禁无法证明 v19 migration 保留领域资料，也可能让真正的迁移错误混在夹具漂移中。

## 时间线

- Replication V2 tracer 新增四张 ledger 表，并把 `SQLiteSchema.version` 提升至 19。
- 2026-08-11T09:34:46-04:00：Sync 293 项通过；Storage 271 项出现 3 个 schema 失败。
- 2026-08-11T09:35:51-04:00：第二次 Storage 全量稳定复现相同 3 个失败，排除偶发测试污染。
- 修正夹具并增加 v18→v19 保留性测试后，Schema 24 项与 Storage 272 项全部通过；普通 Storage 套件唯一 skip 是显式 live-iCloud 用例。

## 复现与证据

三个失败分别为：current schema version 实际 19、断言仍为 18；v15 与 v17 upgrade 在 `validateCurrentSchema` 抛出 `current database schema fingerprint does not match`。

降级夹具从 current v19 store 反向构造 v15／v17。它在重建 `change_journal` 前没有删除四张 V2 ledger 表；SQLite 的 table rename 会同步重写现存 foreign key，让 V2 publication-journal 外键指向临时 `change_journal_current`。夹具之后删除该临时表，留下现实 v15／v17 从未拥有的错误 schema，因此升级后的 fingerprint 合理地拒绝它。

## 排除的假设

- 不是 v19 source migration 遗漏创建表：全新 store 与 v18→v19 均建立八张空 ledger 表；早期文档与局部 assertion 漏数了 outbox 与 authority，不能替代实际 schema inventory。
- 不是资料清理策略错误：v15／v17 仍按既有 clean cut 清理旧 sync runtime；v18→v19 则完整保留 V1 journal、metadata 与 device identity。
- 不是 prepared-store cache 或并发：两个独立全量 run 在相同三处稳定失败，其余 Storage 测试通过。

## 根因与破坏机制

schema 版本提升、旧版本夹具形状与 migration 保留契约没有作为同一个切片更新。测试夹具直接从 current schema 降级，却未先移除旧版本不存在的新表；SQLite 正确维护 rename 外键的行为把夹具变成了不可能存在的混合 schema。

## 根因修复

current-generation 契约更新为 version 19，并明确断言八张 V2 ledger 表存在：第七张保存 fork resolution，第八张保存 resolution-specific conflict set。v15／v17 降级夹具在改写 `change_journal` 前按依赖逆序删除全部 V2 ledger 表。v18→v19 症状测试证明领域 snapshot、V1 journal、metadata 与 device identity 全部保留，同时八张 V2 ledger 表为空。

2026-08-11 后续用户决策取代上述 migration 保留契约：项目开发期不兼容任何旧本机资料。最终实现删除 v15／v17／v18 migration；这些夹具只用于证明旧 schema 在任何写入前被拒绝，且数据库 bytes、`user_version` 与旧 facts 不变。该决策没有改写本案例早期夹具漂移的历史事实。

## 验证结果

- `SQLiteSchemaTests`：24 项、0 失败。
- `NoonmarkStorageTests`：272 项、0 失败；1 项显式 live-iCloud 用例在普通套件中按设计 skip。
- `NoonmarkSyncTests`：293 项、0 失败。
- 真实 iCloud symptom gate 已由独立显式入口完成，不以普通 Storage suite 的 skip 代替。

## 永久门禁

- fast：`scripts/test-replication-v2-schema-contract` 固定执行 current version／八表契约，以及 v15、v17、v18 零写入拒绝行为；`scripts/check` 强制调用。
- symptom：`scripts/test-integration` 执行完整 `NoonmarkStorageTests`，由 `scripts/check` 强制调用；任何旧 schema 被迁移、改写或误开均判红。

## 发行与回滚

当前尚未 production cutover。若 schema gate 再次失败，停止后续 V2 切片并回滚未发行 schema 变更；不得在 production 资料库试跑、修补或手工改 `user_version`。灰度仍按临时 SQLite、隔离 App、真实 iCloud、双实体 Mac与 72 小时 soak 顺序推进。

## 教训与永久约束

- 从 current schema 反向构造旧版本夹具时，必须先删除该旧版本不存在的所有对象。
- SQLite rename 会维护 foreign key；夹具不能假设新表与被改名的旧表互不相关。
- schema version、fingerprint、可接受版本集合与 clean-cut 语义必须在同一个提交中更新并验证；当前可接受集合只有空库与 exact current schema。

# FAIL-2026-08-11-17：不可变最终键可在崩溃时留下半写对象

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:45:00-04:00 至 2026-08-11T16:12:45-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；content-addressed endpoint 与 marker bootstrap 初版直接写最终路径
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：`6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73`（`feat(sync): replace legacy synchronization with replication v2`）

## 用户症状与影响

旧实现以 `withoutOverwriting` 直接把 marker 与 immutable object 写到最终键。该选项只能拒绝已存在文件，不能保证进程在 write 中途崩溃时最终键不可见。半写文件会永久占据 content-addressed key；后续 retry 因不得覆盖或删除，只能报 corruption，令整个 repository 无法恢复。endpoint 还保留 mutable head 的 remove／rename 替换能力，与用户 append-only 铁命冲突。

## 时间线

- 双轴审查从实际 write path 指出 direct-final write 的 crash window，以及 delegated endpoint 内仍可达的 mutable index replace。
- 在全新真实 iCloud round 执行 hard-link capability probe：`link(2)` 成功，stage／final inode 相同且 bytes exact；现场永久保留。
- 新增 5-byte 中断 seam；旧设计没有可恢复的发布边界。
- 共享 append-only publisher、staging grammar 与 no-head cutover 完成后，marker／object 两条中断测试及 endpoint／bootstrap 全集转绿。

## 复现与证据

- marker tracer 在 canonical JSON 只写 5 bytes 后模拟进程中断：最终 marker 必须不存在，partial stage 必须保留；由于 marker 缺失时 repository 已非空，下一次 open 必须零写入 fail-closed，并要求开发期人工重置，不能把无法证明所有权的 staging 当成可恢复 repository。
- object tracer 在首个 chunk 只写 5 bytes 后中断：所有最终 object key 必须不存在；重启 publish 后 receipt confirmed、每个最终 bytes exact，旧 partial stage 仍为原 5 bytes。
- 真实 iCloud capability round 证明当前 CloudDocs 文件系统支持不覆盖 hard-link publish；没有删除、覆盖、rename 或 cleanup。

## 排除的假设

- `Data.write(.withoutOverwriting)` 不提供 crash-atomic regular-file content。
- `rename`／`replaceItemAt` 虽可原子切换，但会移动或替换目录项，违反用户铁命。
- 写完后删除 staging 不允许；所有 stage 都必须永久保留。
- 只在 iCloud wrapper 禁用 mutable head 不充分：破坏能力仍存在于 delegated content-addressed module。

## 根因与破坏机制

协议把「键不覆盖」误当成「最终对象原子可见」，并让同一 file module 同时拥有 immutable object 与 mutable index 两种相反语义。崩溃一致性和 append-only 能力因此无法由模块边界保证。

## 根因修复

- 新建 `AppendOnlyFilePublisher`：在 verified root descriptor 下，以 `openat／mkdirat` 与 `O_NOFOLLOW` 建立唯一 staging，完整写入并 `fsync` 后用 `linkat` 原子创建最终键；`EEXIST` 只接受 exact bytes。
- staging 位于 `v2/staging/{markers,objects}/<UUID>.stage`，永不清理。marker 已存在时 bootstrap 精确接受该 grammar；marker 发布前若只留下 staging，repository 已经非空，bootstrap 必须 fail-closed，禁止猜测该目录属于本轮失败初始化。immutable object 的 retry 则在已有 marker 的可信边界内使用新 stage 恢复。
- V2 endpoint 删除 mutable policy、heads directory、head repair、remove／rename replace code；fork truth 只来自 immutable announcements。
- append-only guard 同时扫描 wrapper、endpoint、bootstrap、publisher 与 CloudKit remote deletion API。

## 验证结果

- `ContentAddressedFileReplicationEndpointTests` 10 项、0 失败。
- `ReplicationRepositoryBootstrapTests` 8 项、0 失败；marker partial final 不可见，原 staging 保留，reopen 回报 `legacyRepositoryRequiresManualReset` 且 inventory 不变。
- `LocalFirstReplicationTests` 28 项、0 失败。
- `scripts/test-icloud-append-only-guard` 通过；真实 iCloud hard-link capability probe 通过。
- 全量签名 App stress 已在全新真实 iCloud round 通过：导入 1,013 条任务后完成 exercise 120／80／40 增改删、71 次跨领域 mutation，再于重启后完成 30／20／10 增改删；两阶段 pending 均为 0、最近同步与最近有效同步均存在、同步失败与修改拒绝均为 0。
- 第二 SQLite 首轮应用 18 份远端 publication，下一轮 pending 归零；重启为 0 次 remote apply。进入第二消费者前的 198 个 immutable 文件全部保持原 digest，最终只追加至 206 个，零 mutable head、零删除／覆盖／移动／改名。
- fast、真实签名 App 与第二 SQLite symptom 均已转绿；修复提交已回填，案例标记为「已修复」。

## 永久门禁

- fast：`scripts/test-replication-v2-recovery-contract` 固定执行 marker 中断后的零写入 fail-closed及可信 V2 repository 内的 object 中断恢复；`scripts/test-icloud-append-only-guard` 拒绝 destructive API 与 mutable index capability；两者均由 `scripts/check` 强制调用。
- symptom：`scripts/test-replication-v2-app-stress` 在签名 e2e App 与全新真实 iCloud round 执行资料导入、高密度变更、重启及第二 SQLite 对账；由显式 `scripts/test-replication-v2-real-validation` 强制调用。

## 发行与回滚

当前未发行。若真实 iCloud symptom 失败，停止发版与新 round 创建，保留所有现场；不得删除 stage／final。回滚不得恢复 direct-final write 或 mutable head，只能在未发行分支继续修正 append-only protocol。灰度仅限全新隔离 round；监控 final digest、stage count、pending outbox、confirmed count 与 restart apply count。

## 教训与永久约束

immutable key 必须代表「完整 bytes 原子出现」，不只是「禁止第二次打开」。把相反写入语义放在同一模块会让调用点配置失效；append-only 必须由唯一 deep module 和静态 capability gate共同保证。

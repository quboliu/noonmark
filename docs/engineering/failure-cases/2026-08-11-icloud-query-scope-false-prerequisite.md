# FAIL-2026-08-11-02：iCloud query scope 被误当成所有运行身份的确认前提

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T09:18:32-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 tracer 工作树
- 引入提交：未提交；错误假设在本次 tracer 首版实现中引入
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

这不是已发行 App 的新用户故障，而是为用户历史 iCloud「等待上传／同步中」问题建立真实门禁时捕获的验证器故障。四个 immutable 对象已经由系统明确报告上传完成，但测试 runtime 永远保持 waiting，若不纠正会把健康 iCloud 错判为无法收敛，并阻止后续架构验证。

## 时间线

- 2026-08-11T09:18:32-04:00：首轮 append-only 真实 iCloud tracer 启动；本地前置门禁全部通过。
- 约三分钟后：XCTest 仍没有进展；主动取样后终止进程，不清理 iCloud 现场。
- 2026-08-11T09:22:04-04:00：第二个全新 session 复现；精确对象的 resource values 全部 positive，但 ubiquitous query 结果为 0。
- 2026-08-11T09:26:43-04:00：修正证据 seam 后，以另一个全新 session 跑两轮真实 iCloud；43.188 秒内完整通过。

## 复现与证据

首版 `ICloudDriveReplicationEndpoint` 要求 `NSMetadataQueryDidFinishGathering` 完成且 query 结果包含四个精确 URL，才允许检查上传证据。真实 XCTest 中 query 确实完成，但结果数固定为 0；XCTest sample 显示主线程收到 metadata notification 并读取 query results，不是死锁。

对完全相同的四个对象进行只读取证：限定测试 round 的 Spotlight 查询返回 4；每个精确 URL 的 `URLResourceValues` 均为 `isUbiquitous=true`、`isExcludedFromSync=false`、`hasUnresolvedConflicts=false`、`isUploading=false`、`isUploaded=true`、upload error 为空。证明对象已上传，失败的是验证器对 entitlement capability 的假设。

## 排除的假设

- 不是 iCloud 上传延迟：四个精确对象全部已有明确 uploaded positive。
- 不是 query 未完成或 main run loop 卡死：运行 sample 捕获 finish notification 与 results 读取。
- 不是对象路径或 digest 错误：限定 round 的对象数为 4，byte count 与 SHA-256 均匹配 sealed receipt。
- 不是 SQLite runtime 死锁：本地同构 V2 纵向测试与 ledger restart 测试持续通过。

## 根因与破坏机制

`ICloudDriveSyncTransport.defaultRootURL` 在当前签名／entitlement 条件下使用 CloudDocs mirror fallback。该路径的精确文件 URL 可以提供 Apple ubiquitous resource evidence，但 `NSMetadataQueryUbiquitousDocumentsScope` 与 `NSMetadataQueryUbiquitousDataScope` 属于 app ubiquity container capability；无对应 container entitlement 的 XCTest 对这两个 scope 完成空查询。

首版 adapter 没有把 discovery strategy 与运行身份 capability 绑定，把「query scope 不可见」误解释成「精确对象未被观察」，所以任何等待都不可能转为 confirmed。

## 根因修复

上传确认改为 immutable exact URL evidence：exclusive-create 保证同一路径没有旧 generation；精确 byte count、SHA-256 与 Apple ubiquitous upload properties 缺一不可。CloudDocs fallback pull 只枚举当前全新 round，placeholder 请求系统 materialization，内容通过 `NSFileCoordinator` 读取。未来若签名 App 具备真正 ubiquity container capability，可在 capability 已证明后使用带精确 generation predicate 的 metadata query，不能把它设成 fallback 的共同前提。

## 验证结果

- fast：证据真值表覆盖缺 URL、digest unknown／mismatch、uploading、uploaded unknown、conflict、excluded、quota、server unavailable 与多对象优先级；immutable endpoint 覆盖两轮发布不创建 mutable head、不改变首轮 bytes。
- symptom：全新真实 iCloud session 内连续两个全新 round，各自完成独立 SQLite A → iCloud → SQLite B；每轮含 4 个 immutable publication object 与 1 个 canonical marker、0 mutable head；目标 restart 零重复 apply；第二轮后第一轮 inventory 与 digest 完全不变。
- 可重复性：完成 `NSFileCoordinator` 与 symlink fail-closed 加固后，第二个独立 session 再跑两个全新 round，37.315 秒通过同一组收敛、重启与不可变性断言。
- 当前仍未切换 production App authority，因此案例保持「处理中」，不得宣称用户 production 路径已经修复。

## 永久门禁

- fast：`scripts/test-icloud-append-only-guard` 进入 `scripts/check`，拒绝 iCloud 测试删除／覆盖命令、profile reset、旧固定 repository、mutable head 与命名空间铁命漂移。
- symptom：`scripts/test-icloud-append-only-symptom` 由显式 live 入口 `scripts/test-icloud-sync-live` 强制执行本地 V2 gates 与两轮真实 iCloud 收敛；环境不具备 iCloud 时必须失败，不得 skip 或伪造。

## 发行与回滚

当前只在全新非生产 append-only namespace 运行，未修改 production authority，不进入发行。回滚只停止继续建立新 round；已经创建的 iCloud 测试对象依用户铁命永久保留，禁止删除。未来 App cutover 仍须按 ADR-0047 的双实体 Mac、72 小时 soak、dmg-validation 与用户显式审批推进。

## 教训与永久约束

- Apple API 可用不等于当前签名身份具备对应数据 scope；capability 必须用运行产物证明。
- immutable key 让路径级 uploaded evidence能够绑定唯一版本；mutable head 做不到。
- 验证器的假阴性同样是故障；等待超过门禁时限必须取样并审查假设，不能盲目延长 timeout。
- 真实 iCloud 失败现场不清理，后轮永远使用全新 UUID round。

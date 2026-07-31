# ADR 0041：把输入法组合态与有序 durable mutation 分离

- 状态：已接受
- 日期：2026-07-30

## 背景

在年度演示负载下，macOS 腾讯拼音输入任务标题、描述、子任务、附言和日终复盘时出现明显回显延迟。真实 WindowServer 取证显示，marked text 的每次变化都经 SwiftUI binding 传播到共享 Store，并与领域 snapshot、投影重算和 SQLite 或加密 sidecar 写入重叠。

只增加 debounce 不能完整解决问题：输入组件仍不知道组合何时结束，无序后台任务可能让旧文本覆盖新文本，App 在 debounce 到期前退出又可能丢失最后一段草稿。

全输入面回归还发现第二条同源路径：烛龙内联任务的五个单行字段直接把 SwiftUI `TextField` 绑定到大型会话页的 `@State`。一次拼音提交会立即重建父视图并启动 sidecar autosave；下一段拼音与发布交叠时，AppKit field editor 会被替换，真实复现了字符丢失。该路径不能靠只修 Markdown 编辑器覆盖。

## 决策

1. 原生文本控件必须把文本与 `hasMarkedText()` 一起上报。组合态属于 UI draft，不属于领域事实。
2. 自动保存编辑器维护独立本地 draft；组合期间不保存，组合结束后才启动 debounce。SQLite 输入默认 700ms，烛龙 sidecar 输入默认 350ms。
3. 单行烛龙字段通过 `IMETextBindingBuffer` 把 AppKit 原生文本与父 binding 分层。marked text 和相邻短输入段留在 field editor；安静 200ms 后才原子发布完整文本。新组合会以 revision 使旧发布请求失效，父视图旧值不得覆盖尚未发布的原生 draft。
4. 失焦、控件拆除和 App 退出先结束 marked text，再同步发布单行字段最新 draft；随后才进入共享持久化 flush。200ms 安静窗口不是 durability 边界。
5. 所有领域自动保存进入单一 `OrderedEngineMutationLane`。clone、领域 mutation、snapshot 与 repository save 在后台顺序执行，MainActor 只发布已经 durable 的最新 commit。
6. 所有烛龙草稿写入独立有序 persistence lane；加密写入与主线程发布分离。
7. 文件型 SQLite 数据库固定使用 WAL。所有同路径 repository 共享 `SQLiteStoreRuntime`，首次完整校验后由 runtime 保留一条 WAL anchor connection，防止短连接降到 0 时触发 close-time exclusive checkpoint／WAL 清理。正常终止在同一 runtime 锁内尝试 truncate checkpoint、关闭 anchor，并把 runtime 标记为终止；无竞争时必须物化主库，外部 writer 导致 `SQLITE_BUSY` 时关闭自身 anchor 并保留标准 WAL recovery，其他 checkpoint 错误 fail-closed。终止后的新连接必须被拒绝。热路径以路径、device、inode、`user_version` 与 `schema_version` 命中准备缓存，不重复执行 `journal_mode`、schema fingerprint 或 `quick_check`；换文件或 schema 改变必须重新完整校验。
8. App 生命周期通过共享 flush coordinator 等待每个最新 draft revision 和两个 persistence lane，再收束 SQLite runtime。保存或 storage finalization 失败必须取消退出。
9. AppKit 退出不使用“`.terminateLater` 后等待 MainActor task”的嵌套协议；第一次请求返回 `.terminateCancel`，flush 成功后由 App 再次请求退出，第二次返回 `.terminateNow`。
10. 手动提交和显式保存输入继续以用户动作作为 durable boundary；搜索等非持久化输入不进入保存 lane。
11. 自动保存反馈不得继续挂在全局 Store 发布面；例如日终复盘使用独立窄作用域状态对象，仅让反馈文字观察保存状态。
12. AppKit 尺寸桥接等布局反馈只在值实际变化时发布，避免组合更新产生无意义的窗口重排。

## 后果

- 输入回显成本不再随 SQLite／sidecar 写入时长同步增长。
- 组合中的拼音不会成为可同步或可恢复的半成品领域事实。
- 保存顺序、故障反馈和退出行为由共享组件统一，不需要在每个输入框重复修补。
- 输入组件需要显式登记生命周期 flush；新增自动保存输入面若未进入机器清单和退出矩阵，门禁失败。
- 单行输入组件保留原生未发布 draft 时，SwiftUI 的旧 binding 更新只能被视为 stale acknowledgement，不能反向改写 field editor。
- 后台 mutation 必须保持领域行为与同步 journal 原子性，不能绕过 repository 或直接修改 live engine。
- SQLite 读写并发由 WAL 提供，不以忽略 `SQLITE_BUSY`、放宽日志门禁或测试重试伪装成功。
- Store 运行期至少保留一条 WAL attachment；业务读写连接仍按操作隔离，但不得反复穿过最后连接关闭的 1→0→1 竞争窗口。
- WAL anchor 只属于运行期；无竞争退出必须先把 WAL 物化进主库再关闭，不能依赖进程销毁时的隐式析构。有外部 writer 或异常退出时仍由 SQLite WAL recovery 恢复，不引入自定义日志协议。

## 被否决的替代方案

- 只调大 debounce：降低写入频率，但不识别 marked text，也不能保证退出 durability。
- 每次变化启动独立后台 `Task`：可能乱序落库。
- 只优化单个标题或复盘输入框：相同根因会继续存在于其他调用点。
- 退出时固定 sleep 或超时强退：无法证明最后 revision 已 durable，且会把数据丢失伪装成成功。
- 缩小演示数据或放宽性能阈值：掩盖而非消除规模相关退化。

## 验证

- `IMETextDraftAutosaveGateTests` 覆盖 marked text、revision、debounce、失败重试和同 revision 组合态失效。
- `IMETextBindingBufferTests` 覆盖 marked text 原生所有权、stale 外部值拒绝、相邻组合取消旧发布、只发布最新安静快照和失焦同步 flush。
- `OrderedEngineMutationLaneTests` 与 `ZhulongDraftPersistenceLaneTests` 覆盖有序执行和最新发布。
- `InputDraftFlushCoordinatorTests` 覆盖稳定快照、全 handler 执行和聚合失败。
- `SQLiteSchemaTests.testFileBackedRepositoryUsesWALSoDurableReadsDoNotBlockWrites` 持有真实读快照和写事务，验证并行写入与新读连接均不产生锁失败。
- `SQLiteSchemaTests.testPreparedStoreHotPathDoesNotRepeatFileLevelSchemaPreparation` 禁止热连接执行 `journal_mode` 与 `quick_check`；`testRepositoryLifetimePreventsWALTeardownAcrossProbeConnections` 用真实 journal-mode 转换证明活跃 repository 阻止 WAL teardown，同时 probe 读取成功；`testTerminationFinalizationMaterializesStandaloneDatabaseAndClosesRuntime` 证明无竞争退出后的主文件可独立回读，且终止 runtime 不会复活；`testTerminationFinalizationClosesRuntimeWhenExternalWriterDefersCheckpoint` 证明外部 writer 只延后 checkpoint，不阻塞 App 关闭自己的 anchor；文件 inode 替换与同 inode schema 改变都必须触发重新校验。
- `scripts/test-e2e` 的烛龙 pending-gate 与自动归类 contention 共用 ready-handshake WAL writer holder；只有 holder 明确就绪且第二 writer 被 SQLite 拒绝后才进入故障路径，异常退出必须释放锁。
- `scripts/test-e2e` 的子任务编辑探针在 synthetic marked-text 后显式结束 AppKit conversion session，并等待目标输入源、first responder 与全选选区就绪；十个 ASCII 物理键固定输出 event delivery、`keyDown`、AppKit 和 native snapshot 分段报告，任何缺样本或超过 120ms 均失败。
- `make test-tencent-ime-input-matrix` 在年度负载下验证 53 个真实输入面。
- `make test-tencent-ime-termination-persistence` 验证 24 个自动保存输入面的立即退出、重启回读、sidecar 明文缺失和一次可重试持久化故障。
- 2026-07-31 最终真实运行证据为 53／53 输入面通过，最高 paced p95 66.468ms、最高单次 108.368ms；24／24 立即退出输入面和一次注入失败后的重试均通过，全部重启回读一致。WAL close-race 修复另以 40 个独立真实 App 进程、1,320 个标题逐键样本和 40 次 durable readback 放大验证，锁失败为 0。

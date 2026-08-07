# 腾讯输入法输入性能与持久化门禁

本文固化晷迹对 macOS 腾讯拼音输入的复现、诊断和回归方法。目标不只是让任务描述“看起来不再卡”，而是让所有用户可输入位置在一年真实数据量下同时满足组合态正确、回显及时、持久化有序和退出不丢数据。

## 成功标准

真实签名 `NoonmarkMacAppE2E.app` 必须通过 WindowServer 把按键送入当前输入源 `com.tencent.inputmethod.wetype.pinyin`，不得直接调用 SwiftUI binding 或 Store action。默认负载必须是 `annual-v1`，即 365 个连续使用日、十二个跨季度功能重放日、十二条重复计划和二十场烛龙会话。

每个输入面使用三组拼音进行 paced 输入，并执行一组 burst。硬阈值为：

| 指标 | 上限或要求 |
| --- | --- |
| paced event-to-echo p95 | 100ms |
| paced event-to-echo max | 250ms |
| burst 总回显时间 | 1,000ms |
| 自动保存至 durable readback | 1,500ms |
| mutation／sidecar 主线程发布段 | 25ms |
| marked text | 除 `NSSecureTextField` API Key 外必须真实观测到 |
| 组合期间持久化 | 0 次 |
| live 与重启回读 | 必须与最终文本完全一致 |

阈值是门禁，不因失败而调高。API Key 使用系统安全输入控件，macOS 不向探针暴露 marked text，因此只验证事件到回显、内存草稿和保存按钮边界。

## 全部输入面

机器事实源是 `Tests/Fixtures/tencent-ime-input-surfaces.tsv`。以下 53 个位置全部进入真实 App 性能矩阵，其中 24 个自动保存位置另进入“最终回显后立即退出”重启回读矩阵。

| 区域 | 数量 | 输入面 |
| --- | ---: | --- |
| Day Todo | 7 | 快速新增、任务标题、任务描述、新增／已有子任务、新增／已有附言 |
| 未来计划 | 5 | 快速新增、任务标题、任务描述、新增／已有附言 |
| 任务池 | 7 | 快速新增、任务标题、任务描述、新增／已有计划子任务、新增／已有附言 |
| 共享导航 | 2 | 详情栏快速搜索、全局搜索 |
| 快速记录 | 1 | 全局快速输入 |
| 重复计划 | 5 | 新建标题、模板标题、模板描述、新增／已有模板子任务 |
| 日终复盘 | 3 | 今日总结、未完成原因、明日注意事项 |
| 任务生命周期 | 1 | 变更为新任务标题 |
| 分类 | 5 | 标签输入、详情新建分组、分类管理搜索／新建／重命名 |
| 设置 | 5 | 诗文、Provider 显示名称／Base URL／Model／API Key |
| 烛龙 | 12 | 首页意图、会话输入、决策补充、每日复盘总结／明日事项、内联任务标题／描述／附言／目标日期、内联子任务标题、Todo 变更标题／目标日期 |
| 合计 | 53 | 24 个自动保存输入面同时执行立即退出探针 |

首次年度全矩阵有 39 个输入面直接通过，另有 14 个非通过结果：

| 类型 | 数量 | 复现位置与意义 |
| --- | ---: | --- |
| 真实回显超预算 | 9 | Day Todo 快速新增／新增子任务／新增附言、任务池快速新增／新增子任务／新增附言、全局搜索、重复计划新增子任务、变更任务标题 |
| 安全输入实际延迟并伴随错误测试假设 | 1 | Provider API Key；真实回显约 173ms，同时探针错误要求安全控件暴露 marked text |
| 自动化定位失败 | 4 | 详情新建分组、分类管理搜索／新建／重命名；属于测试工具缺口，不能当作产品通过 |

用户首先报告的任务描述，随后报告的任务标题、今日总结、未完成原因和明日注意事项也都在取证范围内。它们共用同一条“编辑中的组合文本直接进入共享持久化状态”路径；即使个别短样本没有越过 p95 门槛，保存重叠期间仍能复现可见停顿，因此一并按共享根因处理，而不是逐个输入框打补丁。

第二轮 53 面回归进一步在烛龙内联任务标题复现真实丢键：连续输入和第一段保存交叠输入已经回显，紧接下一段的首字符没有进入 field editor。失败时 view tree 保留前一段文本，sidecar 持久化本身只用约 3ms，证明问题不是磁盘慢，而是直接 SwiftUI binding 在组合提交后重建父会话页并替换原生 field editor。

## 根因

| 层次 | 取证结论 |
| --- | --- |
| 输入法边界 | 原编辑器只转发文本值，没有把 `NSTextInputClient.hasMarkedText()` 作为状态边界。腾讯拼音每次 marked-text 变化都会像已提交文本一样向 SwiftUI 和业务层扩散。 |
| 状态边界 | 标题、描述、已有子任务、附言和复盘直接绑定共享 Store；一次组合输入会造成高频全局发布和依赖视图重算。 |
| 领域与投影 | 年度数据下，多处任务池、已完成层级、重复实例和搜索投影反复全量扫描；原先的小数据 fixture 掩盖了放大效应。 |
| 持久化 | 编辑保存曾重复构造、校验和写入完整 snapshot，并频繁创建日期 formatter；工作与 UI actor 重叠，造成真实按键回显阻塞。 |
| 并发顺序 | 仅把保存丢到无序 `Task` 会产生旧文本晚于新文本落库的风险，不能作为根本解。 |
| SQLite 连接并发 | 原文件库使用 rollback journal；切到 WAL 后，repository 仍为每次操作新开连接并立即关闭。真实全矩阵先后在 `PRAGMA journal_mode`、`PRAGMA user_version` 和只读 `SELECT epoch, revision` 复现 `database is locked`。SQLite 官方 WAL 锁语义说明，最后一个连接关闭会短暂取得 exclusive lock、checkpoint 并清理 WAL／SHM；新连接在该 1→0→1 窗口查询会返回 `SQLITE_BUSY`。因此问题不是某条 PRAGMA，而是 Store 缺少贯穿 repository 生命周期的 WAL attachment。 |
| 烛龙 sidecar | 可编辑 artifact 的加密 sidecar 写入同样与输入发布耦合。 |
| 烛龙单行输入 | 五个内联字段直接绑定大型会话页 `@State`；每次组合提交立即发布父状态并重启 autosave，下一段输入可能与父视图更新交叠并替换 field editor，造成真实丢键。 |
| 生命周期 | debounce 尚未到期时退出可能丢最后一段文本；最初尝试在 `applicationShouldTerminate` 返回 `.terminateLater` 后启动 MainActor flush，又与 AppKit 同步退出等待形成真实死锁。 |
| 测试激活边界 | Quick Entry 是预聚焦辅助窗口，旧探针在单次观察到 key window 与 first responder 后立即发键，绕过其他输入面的连续 WindowServer 激活判定，制造 171–200ms 首键长尾和偶发 p95 红灯。 |
| 测试组合现场 | 子任务布局探针用 `setMarkedText` 建立组合态后只手工恢复 `editor.string`，没有结束 AppKit 输入上下文；同时把 `Command-A` 投递在输入源切换之前。完整 E2E 因此捕获一次 429.762ms 首键长尾，但 30 次分段取证显示应用 `keyDown` 只有 1.3–3.2ms，延迟集中在输入源切换后的事件投递。 |

## 根本修复

1. 原生 `NSTextView` 每次变化同时上报文本和 `hasMarkedText()`；编辑组件维护本地 draft，组合期间绝不触发业务持久化。
2. 共享 `AutosavingMarkdownEditor` 统一承载标题、描述、已有子任务、附言、复盘和设置诗文；SQLite 自动保存只在组合结束后 debounce 700ms。
3. 烛龙五个单行字段统一改用 `IMECompositionIsolatedTextField` 与 `IMETextBindingBuffer`。marked text 和相邻输入段由 AppKit 本地持有；安静 200ms 后才发布完整文本，新输入会使旧发布 revision 失效，SwiftUI 旧值不能覆盖原生未发布 draft。
4. 单行字段失焦、拆除或 App 退出时同步发布最终文本；生命周期 coordinator 随后等待 sidecar durable，确保安静窗口尚未到期也不会丢稿。
5. `OrderedEngineMutationLane` 在后台按序 clone、执行领域 mutation 和持久化，再以极短 MainActor 段发布；旧 revision 不能覆盖新 revision。
6. SQLite 保存接收前后 snapshot，按变化写入；复用 ISO-8601 codec，并把任务池、重复计划、完成层级和搜索等热点投影改为单次索引／计数路径。
7. 文件型 SQLite 统一启用 WAL。`SQLiteEngineRepository`、`SQLiteSyncRepository` 与 `SQLiteAutomaticClassificationJobRepository` 按规范化数据库路径共享 `SQLiteStoreRuntime`；首次完整建库／校验后，runtime 保留一条不参与业务查询的 WAL anchor connection，防止 App 运行期间连接数降到 0 并触发 close-time exclusive cleanup。App 正常退出时，同一 runtime 在终止边界尝试 truncate checkpoint、关闭自己的 anchor，并在进程余下生命周期 fail-closed 拒绝新连接；无外部 writer 时必须把 WAL 完整物化进主库，若 SQLite 明确返回 `SQLITE_BUSY`，则只代表另一个 writer 暂时推迟 checkpoint，runtime 仍关闭自身连接并保留标准 WAL recovery，其他 checkpoint 错误继续阻止退出。完整 schema 准备缓存以路径、device、inode、`user_version` 与 `schema_version` 为身份；同文件热路径只做轻量版本检查，不重复 `journal_mode`、fingerprint 或 `quick_check`，换 inode 或 schema 变化必须重新完整校验。统一日志中的非预期 `database is locked` 仍直接令门禁失败，不增加 busy timeout，也不靠测试重试。需要验证写竞争的 E2E 使用同一个 ready-handshake holder：先证明第一条 WAL writer transaction 已持锁，再证明第二条 writer 被拒绝，避免测试探针自身与 holder 竞速。
8. 烛龙可编辑 artifact 使用独立 `ZhulongDraftPersistenceLane`，组合结束后 debounce 350ms，再有序加密写入 sidecar。
9. Provider 表单保持逐字本地内存草稿，只在用户按保存时进入 Keychain／配置持久化。
10. `InputDraftFlushCoordinator` 登记所有自动保存 draft。窗口关闭或 App 退出时先结束原生 marked text，再等待最新 revision、后台 mutation lane 和 sidecar lane 全部 durable。
11. App 退出采用两阶段握手：第一次取消当前退出请求，让 AppKit 返回事件循环并异步 flush；输入 draft、mutation lane、sidecar lane 和 SQLite runtime 全部收束成功后，才重新请求退出并返回 `.terminateNow`。任何保存或 storage finalization 失败都保持 App 打开，允许用户重试，不以超时或静默丢稿换取退出。
12. 日终复盘保存状态从全局 `NoonmarkStore` 发布面移到窄作用域 `ReviewAutosaveStatus`；只有保存提示视图观察它，保存完成不再令整棵年度工作区重新求值。
13. Quick Entry 的 AppKit 高度桥接只在内容高度真实变化时发布；预聚焦窗口的 E2E 在发键前也必须经过 `activate`，并连续三次确认 App 前台、key window 与 first responder 同时稳定。
14. 合成 marked-text 回归结束时按 AppKit 契约清除 client marked range、丢弃输入上下文 conversion session、恢复文本并通知内容与选区变化。性能计时只在目标输入源、first responder 与全选选区都可观察地就绪后开始；不得把跨输入源切换的排队事件算进首个业务键。

## 固化入口

```bash
# hosted runner 可执行：范围、阈值、Swift automation 与回归资产防漂移
make test-tencent-ime-input-contract

# 真实交互式 Mac：53 输入面年度负载性能矩阵
make test-tencent-ime-input-matrix

# 真实交互式 Mac：24 自动保存输入面立即退出、重启与故障重试
make test-tencent-ime-termination-persistence

# 私有 DMG 发行：一个稳定的真实用户路径
make test-tencent-ime-release-smoke

# 子任务原生编辑器：ASCII 分段计时、真实腾讯拼音、SQLite 与重启
NOONMARK_E2E_SUBTASK_LAYOUT_ONLY=1 scripts/test-e2e
NOONMARK_E2E_SUBTASK_LAYOUT_ONLY=1 \
  NOONMARK_E2E_SUBTASK_IME_INPUT_MODE=com.tencent.inputmethod.wetype.pinyin \
  scripts/test-e2e
```

真实矩阵需要稳定 Apple Development 签名、已授权 Input Monitoring 的交互式 WindowServer，以及已安装并可选中的腾讯拼音。缺少任何依赖都 fail-closed。`make check` 只包含快速 contract；Day Todo 输入、即时退出、重启 smoke、53 面性能矩阵与 24 面退出矩阵都保留为 push 前本地全集自测入口。GitHub workflow 不调度本机，也不伪造腾讯拼音通过结论。

结果保存在：

- `artifacts/e2e-tencent-ime-input-matrix/results.tsv`
- `artifacts/e2e-tencent-ime-termination/results.tsv`
- 每个输入面的 `result.txt`、App log、重启回读状态和隔离 SQLite／sidecar
- `artifacts/e2e-subtask-layout/ascii-latency.tsv`：十个物理按键的总耗时、event delivery、`keyDown`、AppKit `super.keyDown`、native snapshot 与观察耗时；缺列或缺样本会使完整 E2E fail-closed

`results.tsv` 每行固定 22 个字段。门禁同时检查响应分位数、burst、marked text、组合期提前保存次数、durable 时间、主线程工作、live readback 和重启 readback；只检查最终字符串不构成通过。

Storage 回归另固定五条 WAL 生命周期契约：已准备 Store 的热路径不得重复执行 `journal_mode` 或 `quick_check`；活跃 repository 必须阻止第二连接把数据库切出 WAL，同时普通 probe 读取仍成功；repository 生命周期结束后换 inode，或同 inode 的 `schema_version` 改变，都必须重新完整校验并 fail-closed 拒绝异常 schema；无竞争终止必须物化可独立回读的主库，并禁止已经终止的 runtime 再次打开连接；外部 writer 令 checkpoint 返回 `SQLITE_BUSY` 时，runtime 必须关闭自身 anchor 并把恢复交还 SQLite，而不是靠重试或阻塞退出。

## 最终运行证据

2026-07-31 的完整年度实测使用真实腾讯拼音、稳定签名 `NoonmarkMacAppE2E.app` 和 WindowServer 按键路径：

| 证据 | 结果 |
| --- | --- |
| 输入性能矩阵 | 53／53 通过 |
| 全矩阵最高 paced p95 | 67.633ms，未来计划编辑附言 |
| 全矩阵最高单次回显 | 114.100ms，详情新建分组；低于 250ms 硬上限 |
| 用户报告的任务标题／描述 p95 | 61.964ms／60.584ms |
| 用户报告的今日总结／未完成原因／明日注意事项 p95 | 54.254ms／53.652ms／55.531ms |
| 烛龙内联标题／描述／附言／日期／子任务 p95 | 56.399ms／56.750ms／57.516ms／54.389ms／57.524ms |
| Quick Entry 激活修复冷启动重复 | 5／5 通过，最大值由修复前 171.964–199.911ms 降至 54.700–61.143ms |
| 子任务输入现场修复重复 | 修复前 30／30 最慢键固定为首键，首键平均 39.260ms、event delivery 平均 24.220ms；修复后 30／30 通过，首键平均 17.074ms、最大 22.983ms、event delivery 平均 0.512ms |
| 子任务真实腾讯拼音专项 | marked text、两段候选、标点、autosave、SQLite WAL 与退出重启回读通过 |
| SQLite WAL close-race 放大复跑 | anchor 版本 30／30 通过；恢复同 inode schema 变更检测后的最终版本再 10／10 通过，合计 40 个独立真实 App 进程、1,320 个标题逐键样本与 40 次 durable readback，锁失败为 0 |
| SQLite 正常退出收束 | 单独复制 checkpoint 后主库可完整回读；真实畸形导入前、四次失败后与重启后的主库 SHA、journal digest 和记录数完全一致 |
| 组合期提前持久化 | 0 |
| mutation MainActor 段最高值 | 0.619ms |
| 烛龙 sidecar MainActor 发布最高值 | 0.052ms |
| 立即退出矩阵 | 24／24 输入面通过，另 1 次注入失败后重试通过 |
| 最终回显至退出请求最高值 | 8.951ms |
| 重启回读 | 25／25 live 与 durable 完全一致 |
| 烛龙 sidecar 明文缺失检查 | 6／6 通过 |

收口证据归档于 `artifacts/e2e-tencent-ime-diagnostics/final/`。性能矩阵固定保存 53 行结果和完整 runtime console；退出矩阵固定保存 24 个输入面加一次故障重试的 25 行结果。Quick Entry 修复前后五轮冷启动对照分别归档于同目录的 `2026-07-31-quick-entry-repeat-before-readiness-fix/` 与 `2026-07-31-quick-entry-repeat-after-readiness-fix/`。自动化在激活输入前要求前台 App、key window 与 first responder 连续三次稳定一致，只允许对可证明的瞬时窗口激活中断重试；持续找不到控件、输入目标错误或业务失败仍立即 fail-closed。

# Web 服务端数据与命令协议

Web 的任务事实只在个人实例的 Go 服务中提交，SQLite 是唯一持久事实源。浏览器发送命令、读取投影和显示提交状态；多设备共享同一服务，没有浏览器多主复制或数据模式切换。

- Task-ID：`noonmark-web-architecture`
- 状态：2026-10-12 修订提案；替代此前双模式协议。接口和表名均为拟建契约。
- 关联：[架构方案](README.md)、[自部署与恢复](self-hosting.md)、[验收计划](delivery-plan.md)。

## 1. 身份与数据范围

| 身份 | 含义 | 约束 |
| --- | --- | --- |
| `instance_id` | 个人服务实例的稳定身份 | 不从 Host、路径或用户名称猜测 |
| `instance_epoch` | 恢复、重建或控制面失效后的新随机控制身份 | 恢复旧备份必须重新生成，不能回退复用 |
| `dataset_id` | 一份领域数据的身份 | 首期仅一个 active dataset；staging 和历史恢复副本不接受普通命令 |
| `owner_id` | 实例唯一 owner | 不等于官方账号，也不开放多 owner 注册 |
| `session_id` | 一次可撤销登录会话 | 认证不因知道 dataset ID 而成立 |
| `command_id` | 客户端一次明确操作的 UUID | 在结果未知的重试中保持不变，新操作用新 ID |
| `dataset_sequence` | 服务端已提交变更的连续序列 | 在领域事务中递增，不能先确认后写入 |

所有查询和写入都要求正确实例、epoch、owner 权限与 active dataset。浏览器变更服务器地址或遇到不同实例身份时先清理旧查询缓存、停止待确认请求，不把原实例的输入自动发给新实例。

## 2. 单库模型与事务边界

`state.sqlite` 包含实例控制、认证 verifier／会话摘要、各 dataset 的领域事实、变更批次、命令 receipt、jobs／outbox，以及模块独立管理的烛龙加密记录。普通数据包排除认证与烛龙私有资料。数据目录中的导出包和诊断文件是派生产物，不是另一份任务事实源。

| 数据类 | 表示 | 原则 |
| --- | --- | --- |
| 核心事实 | Day、TaskChain、TaskDefinition、DayTrace、Subtask、重复计划、分类事实、IdeaEntry | 忠实移植原生规则，不把所有内容一律设为不可改或任意可改 |
| 查询结果 | Day Todo、任务池、完成／未完成池、飞光时间线 | 首期优先通过索引 SQL 派生，不把浏览器投影反向写为事实 |
| 提交证据 | `command_receipts`、`change_batches` | 同一业务事务写入；不以 change log 取代领域事实表 |
| 任务执行 | `jobs`、`outbox`、attempt／lease 状态 | 入队与源事实同事务；外部调用在事务外 |
| 控制状态 | `instance_state`、`datasets`、导入／备份作业 | 活动指针与 epoch 校验在同一数据库事务内完成 |

主键和外键包含 dataset 边界，至少保证每个 dataset 每日期一个 Day、每链最多一条活跃日轨迹、重复实例 occurrence 唯一、同一 command 唯一、引用不跨 dataset。历史保护由领域校验、约束和有针对性的触发器共同执行；复盘补写及合法草稿编辑不能被错误的全表只读规则阻断。

服务持有数据根独占进程锁。所有写入经一个协调器，使用 `BEGIN IMMEDIATE` 取得数据库写锁，再加载、验证和修改事实；读查询使用有界连接池。配置 WAL、`foreign_keys=ON` 和 `synchronous=FULL`，逐连接验证设置。队列有长度和等待预算，过载返回 typed busy，不无限堆积请求。

持久锁检查、写事务与 SQLite 约束共同防止重复写入；Go 内存 mutex 不能单独证明跨进程隔离。禁止两个活跃容器共用一个 SQLite 数据目录；容器编排也必须遵守该限制。进程退出前停止接纳新 mutation、结束或回滚事务，强制终止后的恢复由真实 crash gate 验证。

## 3. 领域时间与兼容编码

原生的 [MutationClock.swift](../../../Sources/NoonmarkCore/MutationClock.swift)为每次 mutation 分配严格晚于全部已持久事实 frontier 的 finite Double；[ADR-0022](../../adr/0022-use-one-persisted-mutation-frontier-with-exact-clocks.md)要求 exact bits 用于比较及恢复身份。Go 用相同数值语义和 `math.Nextafter`，时间、ID、日历上下文均可注入测试。

服务端在同一事务读取 dataset 的持久 frontier，验证命令依赖，分配唯一 mutation instant，并让事实、journal 和新 frontier 同时提交。frontier 汇总必须覆盖飞光、分类、附言、重复计划和偏好等所有相关事实；导入、恢复、后台任务与有限撤销都不能另开私有时钟。P0 先用完整 snapshot 实现正确性，再以全量对账验证持久 frontier 和受影响聚合加载的优化。

API 将两种时间分开：

- `wall_time` 为 UTC RFC 3339 展示／诊断用时间，不参与因果身份。
- `mutation_bits` 为 UInt64 十进制字符串，保留原生 exact clock；序列和 revision 也用十进制字符串，避免 JavaScript 精度损失。
- 自然日为有效的 `YYYY-MM-DD`。个人实例保存一个 owner 明确选择的 IANA timezone 与配置版本，不依赖容器 `TZ` 或浏览器随意传值来锁日。

上一版提案把新 API 时间统一写成固定精度 RFC 3339，现明确收窄为展示用途。有效的相邻 Double 经微秒格式化可能相同，不能据此做 LWW、CAS 或精确导出。

日结由 server job 执行，并在启动、读取今天和涉及日期的命令前幂等补算。服务停机跨过午夜后必须补结算；客户端挂起与否不影响日结。owner 改时区是显式操作，保留变更记录，不解锁历史、不重排既有轨迹。此规则是 Web 的服务端日历契约，与原生设备日历行为分别验收。

## 4. 命令提交、幂等和并发

请求形状示意：

```json
{
  "instance_id": "uuid",
  "instance_epoch": "uuid",
  "dataset_id": "uuid",
  "command_id": "uuid",
  "schema_version": 1,
  "type": "CompleteTrace",
  "expected_revision": "42",
  "payload": { "trace_id": "uuid" }
}
```

外层 ID 示例是占位符；实际请求必须通过严格 schema。Go 不信任前端传来的时间、完整实体、owner 或历史状态。候选命令覆盖创建、排期、完成、延续、回池、变更、有限撤销、子任务、重复计划、分类、飞光、复盘和确认 AI 建议；实现时逐项与 Swift 用户动作对账。

提交顺序：

1. 验证 token、权限、实例／epoch、active dataset、维护状态和请求资源预算。
2. 在写事务中再次核对控制状态，查询 `(dataset_id, command_id)` receipt；相同请求 hash 返回原结果，异 payload 返回 `IDEMPOTENCY_MISMATCH`。
3. 校验目标 revision、相关聚合依赖及自然日状态，分配 exact mutation instant，执行纯领域命令。
4. 写事实、历史、receipt、完整 change batch 与必要 jobs，递增 dataset sequence 和 mutation frontier。
5. COMMIT 成功后返回 `committed` 并通知订阅者。提交失败不改变已发布视图，不发成功通知。

receipt 的去重摘要在该 dataset 生命周期内保留，不能按固定 30 天后直接遗忘。响应只保存必要结果、产生身份、sequence 及摘要，不重复存整库快照。旧 dataset 或旧 restore epoch 永远拒绝新命令；摘要清理必须有明确退役边界，不能让延迟重试再次执行。

两个设备编辑同一版本，先提交者成功；后提交者获得 `VERSION_CONFLICT` 和新的受授权状态，保留输入由用户重新决定。全局 sequence 用于增量发现，不把任何无关变更都视为聚合冲突。不对任务历史采用最后写入覆盖。

请求超时或网络中断是“结果未知”，不是确定失败。浏览器保留原 command ID，重连查询 receipt 或用原 ID 重试；可持久保留结果待确认请求的 ID 与摘要，供刷新后查询，但不建立可自动执行的命令队列。刷新后如失去完整请求内容，先读取服务端事实，不偷偷生成新 ID 重发。普通断线草稿不会变成后台离线队列，重新提交时必须使用当前版本。

## 5. 查询、通知与客户端状态

| 拟建 API | 契约 |
| --- | --- |
| `POST /api/v1/auth/login` | 本实例 owner 认证，返回内存持有的 Bearer token |
| `POST /api/v1/commands` | 原子业务命令 |
| `GET /api/v1/commands/{id}` | 查询授权 scope 内不确定提交结果 |
| `GET /api/v1/views/...` | Day、任务池、轨迹、飞光等分页投影 |
| `GET /api/v1/snapshot` | 同一一致读事务生成的状态及 sequence／epoch |
| `GET /api/v1/changes?cursor=...` | 按完整已提交事务批次读取变更或失效通知 |
| `GET /api/v1/events` | fetch stream 提示有新 sequence；不承诺逐通知必达 |
| `POST /api/v1/exports`、`POST /api/v1/imports` | 建立受限、可查询状态的导出／导入作业 |
| `GET /api/v1/jobs/{id}` | 返回作业阶段、typed outcome，不返回敏感内部路径 |

初始查询的内容和 checkpoint 必须来自同一 SQLite 读事务。分页只切完整 change batch；客户端只在整批处理成功后更新内存 checkpoint。也可以收到批次后重新查询受影响视图，不必把整个服务器数据库镜像到浏览器。

序列在 COMMIT 后对外可见；不能用预分配计数作为已提交高水位。change feed 过期返回 `CHECKPOINT_EXPIRED`，重新取得 snapshot，不依赖无限保留增量。通知丢失、反向代理重连和多标签页不影响服务器提交正确性。使用 Authorization header 的 fetch stream，不将 token 放到 URL。

前端保持同源部署，实例 origin 是页面所在的服务，不使用用户可随意切换的隐藏生产 API 地址。API 回复携带 build／schema compatibility 信息；旧页签超出兼容窗口时停止新提交并保留输入，要求刷新，不能静默重放旧请求。

浏览器草稿仅记录输入控件内容、目标实体、最后已见 revision 和必要的请求查询引用，按 `(origin, instance_id, owner_id, dataset_id, editor_id)` 隔离；不保存 token、Provider API Key 或一套领域事实表。IME composition 中不提交领域命令，也不以未完成的组合文本覆盖最后可恢复草稿。草稿有大小／保留期限和明确“仅在此浏览器”的标识。

恢复草稿必须先确认登录身份、实例 epoch 和当前实体版本。退出时清理或由用户明确保留无凭证草稿，不展示给其他身份；换服务器、恢复备份或替换 dataset 后，只能作为独立输入恢复，不自动提交。草稿丢失不会改变服务器已有事实，但会影响尚未提交输入的恢复，因此也需要真实浏览器刷新／kill 测试。

## 6. 数据包、导入与实例搬迁

原生 format 7 的日期是 reference-date Double 的 UInt64 bit pattern，canonical 编码还有字段、数组及转义约束。浏览器上传原始文件流，Go 无损解码后验证；不要先经 `JSON.parse` 再重新编码。Go codec 和 exporter 必须由 Swift 双向验证，不能仅以 Go 自身 round-trip 证明兼容。

行为对账与字节对账分层：固定 ID、时钟、排序及偏好的 codec golden 可以验证字节一致；一年故事重放先比较规范化领域事实与关系，不把随机 UUID 或无序字典数组的不同误判为业务差异。需要严格字节相等的 fixture 必须先注入同一 ID／顺序来源。普通导出不包含凭证、会话或烛龙私有 sidecar；兼容偏好在导入目标按安全默认重建，不开放 Web `dataMode` 设置。

导入流程：

1. owner 明确选择文件及“替换活动数据”的意图；建立唯一 import ID，限制原始／解压大小、条目数、深度和资源时间。
2. 在隔离 staging 校验格式、checksum、引用、日期、轨迹拓扑和全部领域不变量。未知 schema、损坏引用或非法时钟直接拒绝，当前数据不变。
3. 以新 dataset ID 将已验证内容装入同一数据库的 inactive dataset，可分批落盘但不得暴露为活动资料；记录验证 manifest。
4. 用户确认来源和目标摘要后，在短控制事务中核对源 dataset／sequence 未变化，原子更新 active dataset、epoch 和导入 receipt。取消旧 dataset 待执行作业的激活资格；旧请求立即失效。
5. 客户端重新认证／取得新 snapshot。旧 dataset 保留为只读恢复副本，按明确保留规则由 owner 管理；不静默合并两个非空数据集。

如果源在确认后又有新写入，返回 `SOURCE_CHANGED` 并要求重新核对，不靠覆盖抹去晚到事实。崩溃后按 import ID 查询：激活事务提交前源仍有效，提交后目标为活动；丢响应不能再次导入出第二份目标。

跨主机搬迁采用“停源写入 → 验证完整备份 → 目标恢复并生成新 epoch → 验收 → 切地址”。源保持停止／只读，目标开始使用后不能再启动旧源作为同一实例。需要回退时先停止目标，再将其最新数据恢复回新运行根；禁止两端写入后宣称会自动合并。备份恢复和原生数据包导入的覆盖范围不同，见[运维文档](self-hosting.md)。

## 7. Jobs、AI 与错误模型

jobs 与触发事实同事务创建，执行器以持久 lease／attempt 领取，网络 I/O 在事务外。重启后可恢复未完成任务；最终业务效果仍以独立 command ID 去重。日结、归类和 AI 建议应用均调用同一命令边界，不能由 worker 直接更新任务状态。

AI 结果先作为可审查建议保存，owner 确认时重新验证事实版本与 scope。Provider 不支持幂等时，超时可能已经产生外部费用；保持 typed unknown，不无限重试。job body 中不持久化明文 API Key，日志不记录 prompt／response。

typed error 至少包括 `AUTH_REQUIRED`、`SESSION_REVOKED`、`INSTANCE_CHANGED`、`DATASET_INACTIVE`、`VERSION_CONFLICT`、`DAY_LOCKED`、`SOURCE_CHANGED`、`IDEMPOTENCY_MISMATCH`、`SCHEMA_UNSUPPORTED`、`STORAGE_FULL`、`MAINTENANCE` 与 `BUSY`。恢复动作应可解释：重新登录、重新读取、保留输入或由管理员修复存储；不能把未知错误一律改成成功、跳过坏记录或清库重试。

# Web 实施阶段与商业上线门禁

先交付可验证的本地纵向路径，再接入账号事务路径、恢复与同步。商业上线以症状级证据、安全评审和恢复演练放行，不以页面齐全或 build 成功代替。

- Task-ID：`noonmark-web-architecture`
- 状态：实施计划；下列拟建入口尚未实现，不能作为已通过的门禁引用。
- 关联：[架构](README.md)、[协议](data-protocol.md)、[外置工作目录](../../engineering/web-build-workspace.md)。

## 1. 依赖顺序与交付物

| 阶段 | 可交付内容 | 完成条件 |
| --- | --- | --- |
| P0：工具与契约 | 外置 build/test wrapper、Go／Web 锁定工具链、真实测试栈、领域动作清单、OpenAPI、格式 7 最小向量 | 只读源码挂载下完成最小 build/test；所有输出在外置根；Swift／TS／Go 对账至少完成创建、跨日延续和精确日期 |
| P1：本地纵向路径 | PWA → 创建任务 → 排期 → 完成／延续 → 日结 → 重启 → 导出／导入 | 真浏览器断网与进程终止后事实一致；不能依赖 mock persistence |
| P2：本地域能力对等 | 任务池、未来计划、子任务、重复计划、分类、飞光、复盘、有限撤销、长列表与输入法 | 对照原生能力清单逐项过关；一年演示故事跨季度覆盖每项普通能力 |
| P3：账号纵向路径 | OIDC、个人 workspace、PG 命令事务、权限、增量投影、草稿与可信缓存 | 两个真实浏览器并发；幂等／跨租户／跨日／token 过期测试通过；服务端重启不会丢已提交事实 |
| P4：迁移与复制 | 两向模式迁移、Mac 数据包互通；若首发包含本地托管复制，再完成加密与设备协议 | 每个迁移 crash window 可恢复；离线旧设备不污染新 dataset；无损 round-trip、fork、乱序、缺块通过 |
| P5：烛龙与运营能力 | scope、Provider、确认执行、计费权益、导出与删除、诊断 | Provider 故障不损核心能力；AI 重试不重复写任务；凭证与隐私哨兵全部通过 |
| P6：商业上线 | HA、容量、PITR／对象恢复、安全审查、灰度、告警与 runbook | 所有承诺能力有真实路径证据，恢复指标达标，值班及回滚责任落实 |

P0 完成后才能开始依赖安装和完整构建。P1／P3 是可体验的阶段版本，不代表原生功能对等；P2／P5 的能力清单完成前，不迁移正式用户来替代原生版本。可选同步若未通过 P4，只能明确不开放，不能显示为已同步或借在线路径偷偷实现。

本轮不估算固定周数：人员、UI 细节、身份供应商及首发复制范围尚未确定。以 P0 的三引擎向量和 P1 的真实存储结果作为重新估工依据，避免把同步与数据恢复当作普通 CRUD 工作量。

## 2. 测试架构

测试分为纯领域、真实存储／服务集成、浏览器症状、跨引擎差分和发行／恢复五层。TypeScript 使用单元 runner，Go 使用 `go test`／race／fuzz；存储集成用真实 PostgreSQL 与 S3 兼容服务；浏览器用 Playwright。涉及 WebKit 真实持久化、PWA 安装或 Apple 平台行为时，增加真实 Safari／iOS 设备验收，不能把 Playwright WebKit 当成所有 Apple 行为的证明。

拟建聚合入口如下，名字需在 P0 真正落地后方可进入门禁登记：

| 拟建入口 | 主要责任 |
| --- | --- |
| `scripts/web/check-workspace` | 检查外置路径、实际写入位置、profile、source tree 无产物 |
| `scripts/web/check` | lint、typecheck、Go vet／race、领域单测、schema 与协议 fast gates |
| `scripts/web/test-integration` | 独占 run 的 PostgreSQL、对象存储、真实 HTTP 与多进程重试 |
| `scripts/web/test-e2e` | 本地／账号两个模式的真浏览器路径、重启回读与网络证据 |
| `scripts/web/test-conformance` | Swift／TS／Go 命令序列、codec 和规范化快照对账 |
| `scripts/web/test-recovery` | 杀进程、失败切换、PITR、对象／密钥恢复与迁移断点 |
| `scripts/web/test-release` | 实际发行镜像／静态资源、schema 窗口、隐私与供应链验证 |
| `scripts/web/run-demo` | 重建一年中段故事、回读对账后才打开交互演示 |

新门禁增量接入现有 `make check` 与 GitHub-hosted workflow，保留原生 gate，不使 Linux 主机误运行 WindowServer 测试。平台 gate 由对应 hosted job 或现有本机验收运行；缺依赖是失败，不是 `skip`。此次文档设计尚不更改旧 Makefile 或 CI。

## 3. 必须覆盖的真实症状

| 风险 | Fast／集成门禁 | 症状门禁及成功证据 |
| --- | --- | --- |
| 保存是假成功 | IndexedDB 事务 abort、配额错误；PG COMMIT 失败 | UI 保存后立即杀浏览器／API，重启对账；失败保存不能显示已完成 |
| 重复命令／丢 ACK | 相同 ID 同／异 payload、并发重试、receipt 保留 | 提交成功后断开响应，再重试；任务和历史只增加一次 |
| 双事实源 | adapter 排他、mode／epoch CAS、源冻结 | 两页签＋断网旧设备＋模式迁移；只允许新 dataset 收新模式写入 |
| 越权与缓存串号 | RLS、复合 FK、对象 URL 和 cursor scope、后台任务 scope | A/B 两账号交换 ID、token、cursor、下载凭证；数据与存在性不泄漏 |
| 非法历史改写 | 日锁、延续与有限撤销不变量 | 修改系统时区、跨午夜恢复草稿；历史不被无痕重排 |
| 协议精度漂移 | UInt64／bit-pattern／Unicode golden，未知版本拒绝 | Mac 导出 → Web 导入 → Go 验证 → Mac 再导入，字节／事实对账 |
| 同步不能收敛 | 重复、乱序、fork、缺 chunk、依赖不完整 | 两个真实浏览器离线修改、重连、重启；等待与冲突如实显示，完成后对账 |
| 字段身份漂移 | 每字段 immutable／mutable 清单，子任务改名 regression | 首次同步后改名、延期撤回、重复模板传播，再同步不成毒记录 |
| PWA 版本与数据库冲突 | schema window、versionchange、旧页签写入拒绝 | 旧页签编辑时部署新资源；草稿保留、升级恢复，无清库行为 |
| IME 与长列表 | composition 不提交、顺序 durable mutation、分页索引 | 中文／英文输入、腾讯拼音可用平台、移动键盘；一年数据与长滚动截图 |
| 飞光／烛龙语义丢失 | 飞光独立于 Provider；AI confirmation 幂等 | 无 Provider 记录飞光；Provider 故障时其他页完整可用；AI 超时重试不重复应用 |
| 灾备名存实亡 | snapshot／WAL／对象 manifest 校验 | 在隔离栈从备份恢复，真实浏览器读取和继续写入，计量 RPO／RTO |
| 诊断泄密 | 所有日志出口注入隐私哨兵，4／8 MiB 边界 | 浏览器、API、网关和 worker 故障后导出，哨兵零命中 |
| 构建污染源码 | 只读 source mount、路径和 symlink 守卫 | 跑完整 build／test／失败路径，再扫描 tracked／untracked／ignored 真实产物 |

故障修复沿用 [failure-cases 规范](../../engineering/failure-cases/README.md)，每个已修复案例绑定 fast 与 symptom gate；涉及发布／启动再绑定 release gate。`gates.tsv` 只登记真实存在并被聚合入口强制调用的门禁，不能提前登记本表的拟建名称。

原生 oracle 只能由隔离的 audit／e2e／demo 引擎与 App 产生，禁止读取 production。先用已有 `NoonmarkDemoSupport` 故事和领域命令生成小型契约向量；完整数据库、截图与报告落在外置 run，禁止手工直接灌 SQL 来伪造业务路径。

## 4. 演示与 UI 验收

Web 演示同样重放连续一年、处于中段的用户故事：每季度重复使用排期、延续、子任务、重复计划、分组标签、飞光、复盘和普通清单动作；覆盖跨年、闰日、夏令时及暂停后恢复。由各引擎经真实命令执行，回读 IndexedDB／PG 与必要的加密 sidecar，机器报告通过后才开放可体验页面。

界面采用项目既有亮色基调、减少重复视觉单位，以原生领域与用户确认过的真实截图为依据。响应式布局、键盘、焦点、IME、屏幕阅读器、长滚动与失联状态均纳入验收；悬浮快速入口必须在长页测试。Web 视觉 reference 必须由用户确认后建立，不以旧 HTML 原型或新截图自我批准。

当前未提供 `frontend-verify` skill。实现期以等价证据补齐：真实浏览器交互与截图、DevTools／CDP Network、console、IndexedDB／PG 持久化探针和跨客户端对账。本次尚无 Web 实现，因而没有这些运行通过结论。

## 5. 部署、灰度与回滚

开发和分支切换始终在当前仓库，开发 Compose 只读挂载此源码，数据库和浏览器目录绑定到当前 run。部署配置出现后，每次改动相关运行代码都部署到全新隔离栈；`curl 200` 不能代替浏览器确认当前构建的 API origin。`CS_TEST_STACK=1`、环境 identity 和依赖实例 marker 必须同时匹配。

正式 Web／Go 发布使用独立 workflow、镜像／静态资源版本与迁移版本，不复用 Mac DMG tag 的含义。现有 Mac tag publisher、精确 source identity 与 DMG 静态门禁保持原规则。Web 产物绑定 commit、lockfile digest、OpenAPI/schema、SBOM 与镜像 digest；GitHub-hosted CI 不引入 self-hosted runner。

schema 采用 expand → 兼容读写 → backfill → 验证 → contract；破坏性收缩在旧客户端兼容窗口结束后单独发布。前端资源 hash 化并保留旧版本，API 至少支持已公布窗口内的客户端；数据库不可逆迁移不能依赖回滚二进制来撤销。

灰度顺序建议：团队合成数据 → 自愿内测账号 → 1% → 10% → 50% → 全量，每阶段至少覆盖一个完整日结周期；关键迁移与复制版本至少连续 72 小时 soak。按固定 workspace cohort 灰度，避免同一 dataset 同时接收不兼容写语义；测试阶段不使用真实生产资料。

任一确认后数据丢失、跨租户泄漏、历史被改写、不可恢复迁移或隐私哨兵命中立即停止放量，必要时只冻结受影响的云端 mutation。客户端保留草稿／本地事实；feature flag 只能关闭入口或新能力，不能将主数据路径暗切到另一模式。

代码回滚仅在 schema 兼容时执行；数据错误采用前向修复或恢复到新 dataset，并留下来源与用户可核对摘要。激活后的模式迁移用反向迁移回退，不能覆盖旧数据。值班监控至少观察命令失败率、p95、outbox 最老年龄、复制 waiting／fork、迁移阶段年龄、WAL 归档滞后、容量和恢复作业结果。

## 6. 风险、缓解与发布阻断

| 风险 | 缓解 | 何时阻断 |
| --- | --- | --- |
| 三份引擎语义漂移 | 版本化命令和真实差分向量 | 任一历史、身份或日期不变量不同 |
| 浏览器存储被清理 | 持久化状态、导出恢复、可选复制 | 保存假成功、恢复失败；不承诺平台做不到的保留 |
| 断网设备造成迁移分歧 | 新 dataset、fencing、来源 manifest、回归对账 | 出现静默丢弃／自动覆盖或谎称全设备完成 |
| 多租户数据泄漏 | 服务端权限、复合键、RLS、对象 scope | 任一路径跨租户可读写，包括导出和 worker |
| 密钥丢失或加密实现缺陷 | 成熟库、独立评审、恢复演练 | 未通过即不开放托管 E2EE 复制 |
| 队列积压及成本失控 | 公平调度、限额、并发预算、容量压测 | 核心操作被 AI／导出资源占满或成本无归属 |
| 数据不可恢复 | PITR、对象／密钥备份、定期演练 | 无完整恢复证据或未达到对外承诺指标 |
| 源码目录混入测试状态 | 统一外置入口、只读挂载、失败即关门 | 发现真实产物留在源码、旧 run 被复用 |

首发决策清单：确认个人版范围、部署地域与预算、身份服务、恢复／保留期限、本地复制首发范围、Web BYOK 路径，以及账号模式时区契约。架构提案为这些项给出默认建议；它们未确认前不采购服务、不上传资料、不迁移正式用户。

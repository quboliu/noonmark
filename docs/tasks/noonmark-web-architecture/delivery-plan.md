# Web 个人实例实施计划与发行门禁

先交付一个可安装、可保存、可重启和可恢复的个人实例，再补齐原生领域能力和运维路径。官方托管是后续独立阶段，首期不要求双数据库、多人账号或多租户平台。

- Task-ID：`noonmark-web-architecture`
- 状态：2026-10-12 修订计划；以下脚本、镜像、接口和门禁均为拟建入口，尚未执行。
- 关联：[架构](README.md)、[数据协议](data-protocol.md)、[自部署运维](self-hosting.md)、[外置工作目录](../../engineering/web-build-workspace.md)。

## 1. 阶段与完成条件

| 阶段 | 可交付内容 | 放行条件 |
| --- | --- | --- |
| P0：工具、协议和存储验证 | 外置 build/test wrapper、Go／JS 工具链、SQLite driver、exact clock／format 7 向量、同源服务壳 | 源码只读挂载下完成最小构建／测试；SQLite backup、取消、事务、amd64／arm64 发行路径有证据 |
| P1：最小个人实例 | owner 初始化／登录、任务创建排期、完成／延续、日结、重启、单容器 | 真实浏览器经真实 Go／SQLite 路径写入，杀进程后回读；无官方账号与外网也可在局域网用 |
| P2：领域与交互对等 | 任务池、未来计划、子任务、重复计划、分类、飞光、复盘、有限撤销、长列表、草稿和 IME | Swift／Go 命令对账；一年用户故事跨季度覆盖；所有普通用户能力都有症状级证据 |
| P3：数据可携带与运维 | format 7 导入导出、完整备份、恢复、换主机、升级与回滚 | 原生双向 codec 验证；备份期间并发写、缺 key、导入崩溃、迁移中断全部可解释并恢复 |
| P4：烛龙与接口 | Provider 配置、scope、建议确认、归类任务、可选个人 API token | Provider 故障不影响核心；重复确认只执行一次；权限、凭证和隐私哨兵通过 |
| P5：自部署商业发行 | 安装包、镜像签名、安全审查、资源预算、文档、升级兼容表、支持 runbook | 真实发行镜像全路径通过，恢复目标达标，72 小时关键路径 soak |
| 后续：官方托管 | 控制面、独立个人实例调度、计费、备份运营与托管 SLO | 另立容量、单卷 fencing、恢复和租户隔离设计；不提前作为 P1–P5 依赖 |

P1 是阶段版本，不能冒充原生全部能力。P2 和必要 P4 能力对账完成前，不把 Web 当作无功能损失的原生替代。阶段时间在 P0 和 P1 取得真实工作量后再估算，不把认证、恢复和领域移植混同于 CRUD。

## 2. 自动化入口

拟建工具均位于 `scripts/web/`，真实产物落 `.work` 对应外置根。名字只有实现并进入聚合入口后才能登记为已有门禁。

| 拟建入口 | 验证对象 |
| --- | --- |
| `check-workspace` | canonical output 路径、源码无真实产物、profile、run 所有权 |
| `check` | lint、typecheck、Go vet／race、纯领域与协议 fast gates |
| `test-integration` | 真实 SQLite、HTTP、事务／job／进程锁，禁止 mock persistence 冒充 |
| `test-e2e` | 真实浏览器 → Go → SQLite → 重启回读，真实 Network／console |
| `test-conformance` | Swift／Go 相同命令、fixed ID／clock、领域事实与格式向量 |
| `test-recovery` | snapshot／密钥恢复、换主机、导入和升级 crash windows |
| `test-release` | 已构建镜像、非 root、volume 权限、架构、版本与 SBOM／签名 |
| `run-demo` | 经领域接口重放一年中段故事，回读通过后打开 |

新 fast gate 增量接入现有 `make check` 和 GitHub-hosted workflow，保留原生 gate；Linux 不运行 WindowServer。真实原生 codec／App oracle 由合适 Apple 环境执行，缺依赖时失败，不能 `skip` 或复用历史通过报告。

当前旧 Makefile 仍有未参数化 SwiftPM 入口，本任务不运行它们。Web 工具出现前不安装依赖、不建立未外置的 `node_modules`／`dist`，不把临时脚本输出混入源码。

## 3. 症状门禁矩阵

| 风险 | Fast／集成 | 真实用户路径与证据 |
| --- | --- | --- |
| 保存假成功 | COMMIT／磁盘满故障、事务回滚、receipt 与事实原子性 | 保存后立即 kill 服务，重启由浏览器和 DB 同时对账 |
| 重复提交 | 同 ID 同／异 payload、并发重试、长期 receipt | 提交成功后丢 ACK，再重试只有一次任务／轨迹效果 |
| 多设备并发 | revision、活动轨迹唯一性、同一 writer 顺序 | 两浏览器同时操作同任务，冲突保留输入、不覆盖历史 |
| 跨日错误 | exact frontier、时区、日锁、停机补日结 | UTC 主机＋上海用户、DST、回拨、跨午夜重连，旧日不被解锁 |
| 实例串数据 | instance／epoch／dataset／session 检查 | 两独立实例交换 token／对象 ID／cursor，旧草稿不自动提交到新地址 |
| 草稿变成事实 | 草稿只存输入，无自动提交和事实统计 | 离线编辑、刷新、恢复连接，只有明确提交才生成事实 |
| 原生语义漂移 | 子任务 lineage、定义复用、重复计划和撤销向量 | 同一一年故事在 Swift／Go 对账，合法编辑不成毒记录 |
| 精度与格式丢失 | UInt64 bits、nextafter、Unicode、字段 shape | Mac 导出 → Go 导入 → Web 操作 → Go 导出 → Swift 验证 |
| 导入覆盖晚到写入 | inactive dataset、source sequence 与激活事务 | 确认前后另一设备编辑；导入拒绝陈旧激活、保留源数据 |
| 初始化或鉴权绕过 | 默认／空密码拒绝、登录限流、权限与 origin | 暴露未初始化实例不能抢注；退出、密码重置与恢复撤销旧会话 |
| 第二进程共写 | 数据根锁及路径／文件系统检查 | 第二容器在写入前退出，原服务可继续使用 |
| 备份不可恢复 | snapshot／manifest／密钥校验、job 恢复策略 | 并发备份后恢复到新目录，由真实浏览器继续写入并重启 |
| 升级失败 | schema 窗口、migration 原子性、前后验证 | migration 中断、旧镜像启动、升级后新写入，再执行允许的回滚路径 |
| IME／长页交互 | composition 状态、提交顺序、索引预算 | 中文输入法、长滚动、移动键盘与多页签，截图及事实回读 |
| AI 越权／重复应用 | scope、确认版本、job 幂等、外部未知结果 | Provider 超时不重复落任务，无 Provider 普通功能可用 |
| 隐私泄漏 | 浏览器、API、jobs、stdout 和代理哨兵 | 故障导出符合容量限制，日志与诊断包不含隐私样例 |
| 源码／环境污染 | 路径守卫、只读 source mount、run marker | 成功、失败、kill 三类路径后扫描 ignored 与 untracked 产物 |

故障修复仍遵守[案例库规则](../../engineering/failure-cases/README.md)：已修复案例绑定真实 fast／symptom gate；涉及安装、启动、退出、签名或发行再绑定 release gate。`gates.tsv` 不能提前登记本表尚不存在的脚本。

## 4. Oracle、演示与前端验证

[NoonmarkDemoSupport](../../../Sources/NoonmarkDemoSupport)一年故事是行为材料，不是可以直接承诺字节完全相同的跨语言输出。对账需注入相同 ID／时钟／排序来源；否则比较规范化领域事实与关系，单独使用固定输入 golden 证明 codec 字节兼容。

所有 fixture 通过真实领域命令生成，禁止手工补 SQL。Web 演示每次新建隔离实例，覆盖跨季度反复使用、跨年、日结、重复计划、飞光和复盘；SQLite 与必要的加密私有记录回读通过后才显示为可体验。不能使用用户 production 资料或已往测试库。

当前没有 `frontend-verify` skill。实现期以真实浏览器自动化补齐交互、截图、DevTools／CDP Network、console、服务运行证据与持久化回读。Chromium、Firefox、WebKit 必测；涉及真实 Safari／iOS 的平台差异再增加设备验收，不能把 Playwright WebKit 视为完整设备保证。

视觉采用用户确认过的真实 reference；不以历史 HTML 原型作为 oracle。悬浮输入或快捷入口在长页验证，焦点、键盘、屏幕阅读器和网络错误状态与功能一起验收。

## 5. 发布、灰度与回滚

自部署发行采用独立 Web 版本／workflow，绑定 commit、lockfile、API/schema、SQLite 编译版本、前端资源 hash、镜像 digest 与 SBOM。GitHub-hosted CI 不声明 self-hosted runner；现有 Mac release tag、source identity 和 DMG 门禁不被复用或改写。

构建完成的同一镜像用于验收和发布；amd64／arm64 都经过真实容器 smoke 和数据恢复，不只验证 manifest 声明。非 root、只读 rootfs、卷权限、启动身份和必需离线资源均进入 release gate。

灰度按实例和版本推进：合成数据 → 自愿内测 → 小批稳定实例。修改日结、schema 或恢复的候选至少 72 小时 soak；不把模拟器收敛或 `curl 200` 描述为真实安装验收。源码变更涉及运行面后必须主动部署到本轮隔离容器并走浏览器入口。

单容器没有滚动多副本升级的默认能力。升级走受控维护窗口；回滚受 schema 兼容约束。发生已确认事实丢失、认证绕过、历史改写、隐私哨兵或恢复失败即停止发行。数据修复优先前向修复；备份回滚涉及新写入时，先保护并对账这些事实，不无声丢弃。

监控只观察 typed 错误、写队列、日结／job 滞后、WAL 增长、存储预算、最后验证备份与恢复结果。初期不采购 SaaS、开生产服务或自动修改用户实例。

## 6. 风险与控制

| 风险 | 设计控制 | 阻断条件 |
| --- | --- | --- |
| Swift／Go 差异 | 规则逐项移植、exact clocks、契约向量 | 历史／身份／日期行为不同 |
| 单机磁盘故障 | 一致备份、异机复制、完整恢复演练 | 仅有同盘备份却承诺灾难恢复 |
| SQLite 双写或不可靠共享卷 | 进程锁、本机文件系统、安装守卫 | 两实例能同时写、未知文件系统仍冒险启动 |
| 不确定提交 | receipt、同 command ID 查询／重试 | 网络重试造成第二次业务效果 |
| 旧浏览器或恢复旧库 | compatibility、instance epoch、重新认证 | 旧请求静默写入新恢复实例 |
| 自动化越权 | 唯一 command 边界、AI 确认、job fencing | worker 直接改领域事实或超范围提交 |
| 功能缩水 | 原生能力清单、一年故事与真实 UI | 阶段子集被宣称完整替代 |

已确认决策不再重复征询：首期个人自部署、单 owner、多设备同实例、官方托管后续复用、Web 无本地优先。尚需 P0 证据的技术选型包括 SQLite driver、实际性能／资源预算和兼容镜像；这些都不要求把双数据库或多租户提前实现。

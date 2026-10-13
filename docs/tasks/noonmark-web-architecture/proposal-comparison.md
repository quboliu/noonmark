# Claude 新版自部署提案：对比与评审

结论：Claude 新版的服务端事实源、Go 内核、SQLite 个人实例和单容器方向可以采用；首期应按用户已确认的单 owner 范围收敛。幂等、原生领域语义、初始化、恢复及构建目录存在需要修改的契约，不能直接按原文实施。

- Task-ID：`noonmark-web-architecture`
- 日期：2026-10-12
- 评审对象：用户在会话中提供的 Claude 新版 13 节方案；未将其全文另存为本仓库的正式设计。
- 对照：本目录[修订架构](README.md)、[数据协议](data-protocol.md)、[自部署运维](self-hosting.md)。
- 证据：当前仓库源码与官方资料；没有运行两份尚未实现的服务。本评审的并发／恢复问题是协议缺口分析，不是已经复现的生产事故。

## 1. 方向对比

| 事项 | Claude 新版 | 当前修订方案 | 结论 |
| --- | --- | --- | --- |
| 领域执行 | Go 服务端唯一实现 | 相同，与 Swift 对账 | 采用 |
| 浏览器 | 在线客户端、非事实草稿 | 相同；重连不自动生成命令 | 采用并补充草稿 scope |
| 个人部署 | SQLite、单容器、owner | 相同；首期仅此形态 | 采用 |
| 托管 | 多租户 PG，与自部署同 binary | 后续复用同内核，优先评估独立个人实例 | 保留为后续设计，首期不实现双 Store |
| 打包 | 单 binary，前端输出到源码内 `dist` 再 embed | 单镜像，Go 与只读静态资源同版本封装 | 采用单镜像；修改违反源码纯净要求的构建路径 |
| SQLite driver | modernc，P0 对比 mattn | mattn 为基准候选，P0 对比 modernc | 两者都可评估，不以口头性能或便利性定案 |
| API | Connect-RPC／protobuf | HTTP JSON／OpenAPI | 都能满足；首期选一套，不叠加双协议 |
| 后台任务 | 同库 durable jobs | 相同，外部调用效果需单独幂等 | 采用 |
| 初始化 | 日志中的一次性 setup URL | 管理 CLI 先建 owner，未初始化不开放远程设置 | 推荐 CLI；如采用 URL，需补完整令牌威胁模型 |
| 升级 | 启动自动 snapshot＋migration | 显式维护、已验证备份、兼容表、受控 migration | 采用后者作为首期安全边界 |
| Mac 互通 | format 7＋一年字节相等 | 固定 codec 字节测试＋一年领域事实对账 | 修正 oracle 口径 |
| 认证 | Cookie 会话＋PAT | 按当前仓库规则使用 Bearer | Cookie 本身可行，但不能未经变更沿用到本项目 |

用户已经回答了 Claude 清单里的两项：自部署先行、一个实例一位 owner。多用户、Cloud 计费、PostgreSQL 和 Mac online client 不应因此重新成为当前决策阻塞点。

## 2. 实施前必须修正

### R1：任务定义并非每次编辑都新建版本

Claude 第 2 节将 `TaskDefinition` 描述为每次编辑都创建新版本。当前 [NoonmarkEngine.swift](../../../Sources/NoonmarkCore/NoonmarkEngine.swift) 的 `updateTaskTitle` 会检查历史引用：允许复用时，推进 `contentUpdatedAt` 并更新同一 definition；有历史约束时才形成新定义。计划子任务的合法编辑也会修改可编辑定义。

若按概括文字移植，定义数量、身份、撤销与导出会偏离原生。应先建立逐字段的 identity／mutable／history 规则及操作向量；仅对真实不可变事实实施触发器，不能把整个表简单设为 insert-only。

### R2：30 天 receipt 与“重试始终安全”互相矛盾

Claude 第 6 节给 command log 30 天窗口，同时声称相同 command ID 令所有重试安全。若服务已提交、客户端未收到 ACK，且请求在去重记录过期后再次到达，仅靠该窗口不能证明不会重复产生业务效果。

至少要永久保留活跃 dataset 的必要去重摘要，或将 receipt 回收绑定设备／实例 epoch 退役，明确拒绝窗口外请求。还应规定相同 ID 不同 payload 的错误、提交结果查询、restore epoch 及新实体 ID 的生成边界。数据库唯一键可以保护部分动作，但不能替代所有命令的幂等契约。

### R3：“整个目录备份”和“事务性替换数据库”不足以定义恢复

Claude 第 8 节的目录布局适合部署，但运行中复制目录不能自动取得 SQLite／WAL／密钥的一致恢复点。`VACUUM INTO` 可以建立一致 snapshot，却仍需处理未完成文件、密钥版本和恢复验证；它不是跨文件、运行连接及应用任务状态的整体事务。[SQLite VACUUM 文档](https://www.sqlite.org/lang_vacuum.html)明确区分完成的 snapshot 与中断输出。

应规定维护状态、backup ID、snapshot 内读取的 sequence、密钥封装、读回校验和空目录恢复。恢复后撤销旧会话、生成新 instance epoch，并核对可能已调用外部 Provider 的 job。新版本已接收任务后，不能用旧备份直接回滚而不保护新写入。

### R4：单 writer goroutine 没有覆盖第二个进程

Claude 为 SQLite 指定单 writer goroutine，能限制单进程内的写并发，但没有定义第二个容器误挂同一 volume 时的启动拒绝。网络／同步盘只给 `doctor` 警告也不足以支撑严格数据安全契约。

数据根应有进程独占锁，服务在任何 mutation 前核对所有权及支持的文件系统，不满足条件即失败。默认安装不能启动两个活跃副本共写同一 SQLite 文件；未来托管调度必须有卷级 fencing。SQLite 自身锁仍保留为第二层保证。

### R5：setup URL 是高权限凭证，不能仅凭“一次性”推导安全

高熵、短时、原子消费的 setup token 可以设计安全的初始化流程；原文没有定义这些条件，却直接得出陌生人不能抢占实例的结论。完整 URL 进入容器日志、代理或浏览器历史还会扩大凭证暴露范围，并与本项目日志不得记录 URL／凭证的规则冲突。

首期推荐本机管理 CLI 创建 owner，再启动服务。如果保留 Web setup，必须明确 token 产生／保存／到期／消费、先到者竞争、TLS、默认监听范围及重启行为；不把明文 setup URL 写入应用诊断。空密码和缺配置不能自动开放匿名访问。

Cookie + CSRF 是一种可行的 Web 认证设计，但 [AGENTS.md](../../../AGENTS.md) 当前要求 API 统一 Bearer。应明确提出修改该约束，或按现行约束实施，不能当作已经获准替换。

### R6：源码里的 `internal/httpapi/dist` 违反本次目录要求

用户要求当前目录只保留源码，所有编译／测试状态实际落到 `/share/broker/`。Claude 第 5 节把前端 build 写回 Go package 的 `dist`，与此要求直接冲突。

`go:embed` 的路径约束也不能通过普通外置 symlink 随意规避；[Go embed 文档](https://pkg.go.dev/embed)限制模块外文件和 symbolic link。单 binary 是可以另行设计的打包目标，但当前用户需要的是单容器体验，不要求为此创建源码副本或在 checkout 生成资源。

首期采用镜像同时装入 Go binary 和只读 Web 资源，二者绑定同一个 manifest；由 Go 同源服务，用户仍只运行一个容器。测试数据库、driver cache、Playwright profile、截图和 release fixture 同样必须走外置 wrapper。

### R7：一年故事的字节相等需要先解决非确定性

固定输入 codec golden 可以要求 exact bytes；原生一年演示和 snapshot 中存在随机 ID 以及无序字典编码问题，不能未经处理就要求两次独立重放的整个包字节相等。[NoonmarkDataPackage.swift](../../../Sources/NoonmarkStorage/NoonmarkDataPackage.swift)的 shape 校验本身就说明了非字符串 key 字典数组的顺序不稳定。

应分别验证领域行为相等、身份关系相等、exact clock 相等和 codec 字节兼容。对需要字节一致的向量，注入固定 ID／时钟／排序／偏好；不要用同标题去重或随意删字段“归一化”掩盖错误。

## 3. 应保留但补齐的设计

非事实草稿存 IndexedDB 能避免刷新后丢失长输入，已纳入修订方案。这不等于恢复 Web 本地优先。草稿必须按实例、owner、dataset 和编辑目标隔离；重新连接后恢复输入，由用户明确提交。Claude 风险表中的“drafts sync on reconnect”如果表示自动生成事实命令，就应删除；如果仅表示恢复编辑内容，应改清楚措辞。

`modernc.org/sqlite` 的纯 Go 分发确实减少 CGO 的构建负担，且提供在线备份接口。[官方包文档](https://pkg.go.dev/modernc.org/sqlite)支持这些能力，但尚未证明它在本项目上的吞吐、取消、内存及 crash 恢复优于其他驱动。P0 用同一 workload 和备份／故障门禁比较，再锁定唯一 driver 与 SQLite 版本。

Connect 提供浏览器可用的 HTTP／JSON RPC，适合生成类型化客户端；[Connect 协议](https://connectrpc.com/docs/protocol/)支持这一选择。当前 OpenAPI 路线也可满足 Web 与脚本调用需求。无论选哪个，protobuf 或 JSON 序列化都不能自动成为原生 canonical digest 编码，应保留独立 codec。

同库 jobs 事务入队值得采用，但 lease／retry 只解决领取与恢复，不能保证外部 API 只执行一次。需要命令幂等、attempt identity、取消语义和外部结果未知状态；Provider 无幂等能力时尤其要防重复费用。

前端错误采集、tracing 和 `slog` 不因使用现成库就自动满足隐私要求。诊断仅去掉任务正文不够；仓库还禁止账号、路径、URL、IP、原始 Error 等，浏览器诊断也须由用户主动导出，不能把通用 Sentry SDK 默认行为直接作为满足条件的实现。

## 4. 后续范围与最终建议

Cloud 多租户＋PostgreSQL、OIDC／passkey／TOTP、多账号、S3／WebDAV 备份、跨平台独立 binary、trusted-header auth 和付费策略都有独立价值，但它们不属于已经确认的首期个人实例要求。把 Store port 留在模块边界即可，不必为了将来切 PG 现在维护两套触发器、migration 和任务领取逻辑。

不要按“用了哪个库”决定整份方案优劣。建议最终基线为：服务端单一 Go 领域引擎、SQLite 个人实例、同库事务 jobs、同源浏览器、非事实草稿恢复、format 7 互通、真实备份恢复和外置构建测试；API 协议和 SQLite driver 由 P0 的明确成本／验证结果定案。

本轮已据此重写设计文档、补充自部署运维并更新领域语言和 ADR。没有建立 Go／Web 运行项目，也没有运行容器或以设计推理替代数据安全测试。

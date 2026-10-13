# 个人实例：部署、备份、升级与恢复

首期交付目标是一个应用容器、一个持久数据目录和一位 owner。实例可在个人电脑、NAS 或服务器运行，多设备访问同一服务；核心功能无需官方账号或外部服务。

- Task-ID：`noonmark-web-architecture`
- 状态：设计契约；以下镜像内容、配置项、CLI 和门禁尚未实现，不是可直接执行的安装说明。
- 关联：[架构](README.md)、[数据协议](data-protocol.md)、[交付计划](delivery-plan.md)。

## 1. 借鉴思源的范围

思源的官方 Docker 入口把 kernel 和界面资源一起分发，允许用户挂载 workspace 并设置访问认证。[官方 Docker 文档](https://github.com/siyuan-note/siyuan#docker-hosting)和 [Dockerfile](https://github.com/siyuan-note/siyuan/blob/master/Dockerfile)支持这一交付模式。

晷迹借鉴“部署服务 → 挂载资料 → 浏览器访问”的使用路径。领域模型、任务历史、认证细节和备份格式单独设计；不复制思源的实现代码、不接入其账号，也不把其整个产品的本地优先语义带入 Noonmark Web。

## 2. 安装产物与启动契约

正式产物包含版本化的 Linux amd64／arm64 OCI 镜像、Compose 声明、配置参考、升级兼容表、SBOM、校验和与恢复说明。Go binary、SQLite driver、前端资源及 migration 必须来自同一 source commit，镜像固定 digest，不能以浮动 `latest` 作为升级依据。

容器内规划布局：

```text
/opt/noonmark/bin/noonmark       # Go 服务与管理 CLI，只读
/opt/noonmark/web/              # 同版本前端资源，只读
/data/                         # 唯一应用持久目录，用户挂载
  state.sqlite                 # 实例控制、领域事实、jobs、加密私有记录
  state.sqlite-wal              # SQLite 管理，不能单独清理
  state.sqlite-shm              # SQLite 管理，不能单独清理
  instance.lock                # 数据根独占进程锁
  secrets/                     # master key；也可通过外部 secret 挂载提供
  staging/                     # 受限导入／备份中间产物
  backups/                     # 应用创建的完整备份
  exports/                     # 有过期策略的服务器临时导出
  diagnostics/                 # 有界 typed evidence
/tmp/                          # 有大小限制的 tmpfs
```

首期不要求 PostgreSQL、Redis、S3 或独立身份服务。容器监听规划为 `8080`；默认宿主只映射 loopback，跨机器访问需先配置 HTTPS，可接现有反向代理或挂载证书给 Go 服务。外部 TLS 入口属于可选部署设施，不是另一份业务服务。

初始化和启动分两步：

1. 管理员选择一个全新、自己拥有的空数据目录，运行拟建 `noonmark init`。CLI 从安全输入取得 owner 凭证，建立 verifier、instance ID 和 master key；已有或类型异常的目标必须拒绝，不能覆盖安装。
2. 运行拟建 `noonmark serve`，明确 data root、public origin、owner 时区及监听配置。启动前验证目录权限、锁、schema、加密 key 和静态资源版本。未初始化、缺 key 或 schema 不兼容时失败，不能退到匿名模式或建立空库。

管理 CLI 不将密码、Provider API Key 或恢复密钥放在 argv、日志或示例 `.env`。应用运行用户必须与挂载目录的 owner／权限匹配；不能靠启动时递归 `chmod 777` 或 `chown` 任意宿主目录解决。容器非 root、只读 rootfs、`no-new-privileges`、drop capabilities，只有明确数据目录可写。

建议配置面限于 `NOONMARK_DATA_DIR`、`NOONMARK_PUBLIC_ORIGIN`、`NOONMARK_LISTEN_ADDR`、`NOONMARK_OWNER_TIMEZONE`、TLS 文件位置及 secret 文件引用。敏感业务凭证经管理入口加密入库；挂载路径等配置不能写入应用诊断。具体键名在 P0 固化并验证环境／CLI 优先级。

## 3. 磁盘、单实例与网络边界

`state.sqlite`、WAL 和 SHM 必须位于同一受支持的本地文件系统。NAS 可用 NAS 主机上的本地数据卷，但不能把 NFS／SMB 共享路径挂载给多个服务共写。SQLite WAL 需要同机共享内存协调，[官方 WAL 文档](https://www.sqlite.org/wal.html)不能被“容器有 volume”这一事实替代。

进程先取得数据根独占锁才打开业务写入。第二个服务进程启动必须在任何 mutation 前失败；不能等到 SQLite 偶尔返回 busy 后再猜测已有实例。自动重启可以恢复原实例，横向扩容不能让两个副本共写同一卷。

有限读并发、单写协调器和事务内版本检查支持一个人的多台设备。Web 请求只访问同源实例，数据库不暴露网络端口。HTTPS、Host allowlist、trusted proxy 和认证失败限流进入安装门禁；没有公网域名的本机使用可通过 loopback HTTP 开始。

服务器不可达时浏览器不能提交任务。外网不通但局域网实例仍可达时，核心功能继续运行；不依赖官方登录、CDN、字体或脚本请求才能打开服务自带页面。所有必需前端资源由该镜像同源提供。

## 4. 两种导出与备份责任

| 产物 | 包含 | 用途与限制 |
| --- | --- | --- |
| 领域数据包 | 可校验任务事实与允许偏好，目标为原生 format 7 | Mac／Web 互通；不含会话、Provider 凭证和烛龙私有记录 |
| 完整实例备份 | 一致 SQLite snapshot、schema／版本／身份 manifest、必要密钥的加密恢复材料 | 同版本恢复、升级前保护、跨主机搬迁；敏感恢复材料必须在加密 envelope 内 |

普通下载导出不等于完整灾备。与服务器同一磁盘的 `/data/backups` 只能防部分逻辑故障；磁盘或主机损坏时需要异机副本。首期提供加密备份包和管理员复制到异机的明确操作，S3 等自动目标可后续扩展，不能把它变成必要依赖。

备份必须调用 SQLite Online Backup API，或者在受控停写／关闭数据库后采用已验证的冷备份流程。运行中不能只复制 `.sqlite` 而忽略 WAL。[SQLite Backup API](https://www.sqlite.org/backup.html)提供一致性备份机制；具体 Go driver 适配需要真实并发备份测试。

在线备份流程：

1. 建立唯一 backup ID 和受限 staging，固定密钥版本；密钥轮换不能与该备份交错产生不可解密组合。
2. 通过 backup API 完成一致 snapshot，再从目标 snapshot 读取 instance／dataset／sequence，写入 manifest；不拿备份开始前的 sequence 冒充 snapshot 边界。
3. 验证数据库 integrity、引用、领域不变量和加密记录可解密性。将 snapshot 与必要恢复材料流式封装到成熟的加密备份格式；不在 staging 落明文 Provider key。
4. 完成落盘、同步和读回校验后，才记录本机备份成功。上传异机后再按目标能力验证完整性，分别显示本机与异机状态。
5. 按 owner 明示的保留策略清理应用自己创建的过期备份；不删除用户下载的文件或用户自选导出目录，不触碰任何 iCloud 资料。

初始建议每日备份、保留最近 7 份本机备份；这是可配置的运维默认值，不是服务器持续零丢失保证。在每日且成功完成异机复制的配置下，磁盘灾难 RPO 最多约 24 小时；没有异机成功证据就不承诺该 RPO。对一年基准数据，隔离恢复演练的目标 RTO ≤ 30 分钟，不含替换硬件或上传下载不可控耗时。

## 5. 恢复与换服务器

恢复由管理员在新的空数据目录执行，不在线覆盖正在运行的目录。拟建 `noonmark restore` 先验证版本、checksum 和恢复密钥，再恢复一致 snapshot、核对所有加密资料、生成新的 `instance_epoch` 并撤销旧会话。

恢复程序将遗留执行中的 job 标为待核对：普通幂等作业可重新领取，可能已经产生外部费用的 Provider 调用不能盲目重发。内部命令 receipt 随事实一同恢复，但旧浏览器 epoch 被拒绝，避免恢复前的未知请求自动落在新时间线上。

验证完成后才允许启动 HTTP 写入服务。验收需要登录真实浏览器，读取日轨迹／飞光／复盘，提交新命令，再重启回读；只检查 backup checksum 或 SQLite 可打开不算恢复成功。

搬迁时先停止源写入，生成并校验备份，在目标空目录恢复，再切换浏览器入口；原服务器保持停止／只读。目标已开始写入后，回退必须把目标最新事实再次完整搬回，不能简单重启旧库。物理复制实例不能形成自动同步关系。

## 6. 升级与回滚

升级是明确的维护操作，不在普通启动时悄悄执行不可逆 schema 变更。每次发行提供源／目标 schema 兼容表、所需空闲空间、预期维护窗口和回滚条件。

1. 预检镜像 digest、架构、schema、磁盘空间和备份可恢复性；记录旧版本 manifest。
2. 进入维护状态，停止接纳新命令与新外部 job，等待在途事务结束，再停旧进程。
3. 由同版本管理 CLI 执行 migration，使用可验证事务／阶段记录；新进程验证 DB、密钥与资源一致后才对外 ready。
4. 真实浏览器检查历史、典型变更和重启回读，再解除维护。

旧镜像只允许打开它明确支持的 schema。若目标 schema 不兼容，回滚采用升级前备份恢复到新目录；若新版本已经接收新事实，必须先保护这些事实并进行前向修复或可验证的数据转换，不能以恢复旧备份无声丢弃新写入。

前端资源和 API 同镜像发布。静态资源带 hash，入口页面更新可控；首期不依赖 Service Worker，降低旧资源接管风险。旧页签请求通过 API compatibility 与 epoch 校验拒绝，保留输入并要求刷新；更新不能清除输入来掩盖兼容问题。

## 7. 商业质量、监控和故障处置

个人单机实例不声明自动 HA 或托管 SLA。商业质量通过安装和运维路径兑现：安装可重复、保存结果可判断、升级可恢复、导出可读回、权限不能绕过、故障有无内容证据。

健康接口分 liveness 与 readiness，公开返回最小状态；容量、schema、job 和备份详情仅 owner 可见。关键指标包括命令提交失败率／延迟、写队列长度、磁盘可用空间、WAL 增长、job 最老年龄、最后有效异机备份时间及恢复验证结果。指标不包含任务、账号、路径或 URL 标签。

为数据、staging、临时导出、备份和诊断设置分别可检查的预算。磁盘压力先停止非必要生成作业并提示 owner，不能删除事实或清空 DB 自动修复。配额和队列阈值在固定一年 fixture 与资源故障注入后锁定，不以增大 timeout 替代定位。

首发发行门禁必须覆盖：空目录初始化、已有目录拒绝、缺认证拒绝、第二实例拒绝、磁盘满、提交中断电／kill、备份期间继续写、恢复缺 key、错误 schema、升级中断、旧页签、反向代理断流及跨主机切换。每项具备真实发行镜像与浏览器证据。

灰度按实例推进：合成测试实例 → 自愿测试实例 → 小批稳定实例。涉及日结、migration 和恢复的候选至少 72 小时 soak，出现事实丢失、权限绕过、隐私哨兵或不可恢复升级立即停止发放；不自动修改用户部署。

## 8. 开发目录与用户运行数据分离

用户服务器上的 `/data` 是其个人正式资料，不是开发 fixture。开发、E2E、demo 和 release-validation 的容器 `/data` 只能绑定 `/share/broker/noonmark-build/runs/<profile>/<UUID>/databases` 等该轮专属目录；源码只读挂载，配置、浏览器 profile、报告和备份也全部外置。

每轮测试使用全新 run；同一 suite 内可重启验证持久化，下轮不可复用。清理只作用于本轮所有权可证明的数据和容器，不扫描主机上的正式实例。`CS_TEST_STACK=1` 必须与实例 marker、profile 和路径守卫同时成立。

当前仓库尚无上述镜像与 Compose，实现前只能验证设计和目录契约，不能声称已经完成 Docker 部署或恢复演练。

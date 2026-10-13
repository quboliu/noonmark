# 个人自部署 Web 实施记录

- Task-ID：`noonmark-web-self-hosted`
- 状态：实施中，2026-10-12 开始。
- 需求：按已确认的个人实例架构开始实现；服务端唯一事实源、一个 owner、多设备访问、单容器、源码与产物分离。原生 Mac 不变。
- 现状：基线 `83e9aed`，仓库干净；Linux arm64，Go 1.27、Node 22、Docker 和 Chromium 可用，Swift 不可用。外置根 `.work` 已指向 `/share/broker/noonmark-build`。

## 实施设计

先完成外置工具和真实纵向路径，再补充可独立验收的领域能力及运维。后端采用 `github.com/quboliu/noonmark/services/noonmark` Go module；`internal/core` 为纯领域模型，`internal/store` 负责 SQLite 与事务，`internal/httpapi` 负责权限与 HTTP，CLI 初始化 owner、启动和备份恢复。界面位于 `apps/web`，API 同源；所有依赖、构建和 E2E 数据由 `scripts/web` 路由到外置根。

初始共享 API：`POST /api/v1/auth/login` 接收 password；`GET /api/v1/snapshot` 返回 instance／epoch／dataset、sequence、today、timezone 和领域集合；`POST /api/v1/commands` 接收 command ID、控制身份、type、expected revision 和 payload；`GET /api/v1/commands/{id}` 查询结果；Bearer 存内存。网络失败不假报成功、不自动执行离线命令。

实施覆盖按实际证据登记，不能把新增 Web schema 导出宣称为 Mac format 7 兼容。Swift 对账、跨平台发行和原生完整能力未经运行验证不标完成。

## 首个实现的边界

当前实现为个人实例纵向版本。支持任务池、今日／未来安排、子任务与难度加权进度、延期／延续／回池、完成／废弃及其历史、飞光与便签投影、每日复盘。日轨迹按 owner 时区结算，锁定后拒绝改写；历史复盘仍可独立补写。一个数据目录由一个进程独占；关系事实、change batch 与命令 receipt 在同一 SQLite 事务提交。重试使用同一 command ID，内容不同则拒绝。

Web 只保存输入草稿，Bearer token 留在内存；重新载入需重新登录。断线后允许编辑草稿，但不自动排队执行领域命令。请求结果不明时查 receipt，并保留明确的人工处理入口。多设备收到 SSE sequence 后刷新服务端 snapshot。

实现选择与长期设计的区别：

| 部分 | 本版实际实现 | 后续门禁 |
| --- | --- | --- |
| 交付 | 单容器内静态 Go binary 和同版本 Web assets；也可在本机指定 web-dir | 多架构发行、签名、SBOM 与发布自动化 |
| SQLite | `mattn/go-sqlite3`，构建时启用 CGO，最终 Linux binary 静态链接 | 根据真实负载再评估驱动；不宣称纯 Go 或 Windows 支持 |
| HTTP | 固定 JSON command envelope，严格字段检查，SSE 通知 | 完整 OpenAPI／生成客户端；当前没有 Connect-RPC |
| 读取 | 完整 snapshot 校验与加载；命令在内存执行后持久化 diff | 大数据量查询／分页、聚合加载与容量基准 |
| 身份 | 单 owner 密码、Argon2id、内存 Bearer、服务端撤销 | Passkey／OIDC／个人 API token |
| ID | 随机 UUIDv4；顺序由 sequence 和 exact clock 决定 | 不依赖 ID 的时间排序 |
| 备份 | 手动 age 加密实例包、SQLite online backup、CLI 恢复到全新目录、epoch 更新并撤销所有会话 | 定时备份、远端目标和正式恢复演练政策 |
| 领域兼容 | 当前已实现命令的 Go／SQLite 自洽与真实浏览器验证 | Swift oracle、format 7、重复计划、分类、任务附言、ChangeTrace、AI |
| schema | Web schema 1，拒绝不认识的版本 | 首次升级前必须提供真实旧版本 fixture 与迁移门禁 |

本版的 `.noonmarkbackup` 是整个 Web 实例的加密恢复包，不能导入 Mac，也不是格式 7 的替代名称。备份数据库当前上限 256 MiB；超出限制明确失败。恢复必须指向不存在的目录，失败留下隔离标记，不能被 serve 打开。CLI 离线操作不能绕过运行进程的锁；运行中下载备份使用设置页面，并重新验证 owner 密码。

## 运行入口

```bash
make web-check   # 外置路径、Go、前端、真实容器／浏览器、备份恢复、一年演示
make web-demo    # 新建独立一年演示，交互输入密码，前台运行；Ctrl-C 停止
make web-package
```

开发和测试需要 Linux、Go 1.27.0、Node 22.22.3、GCC、bubblewrap、Python 3、OpenSSL、Docker 与 Chromium。具体容器操作见[自部署说明](../../../deploy/self-hosted/README.md)。所有测试都使用合成资料；没有在此 Linux 环境执行 Swift／真实 Mac App 验证。rootless Docker 中测试进程可用 namespace UID 0 映射宿主普通用户；镜像默认 UID 65532，rootful CI 使用非 root UID。

`make check` 根据平台进入对应聚合入口：macOS 继续原生套件，Linux 进入 Web 套件。平台选择会明确输出，互不冒充验证结果。

领域和运维 API 详见 [HTTP 契约](http-api.md)，一年覆盖见[演示契约](demo-fixture.md)。本版不应被标为完整商业 GA；后续发布必须先补齐能力对等、升级迁移、容量和安全评审门禁。

2026-10-13 用户要求后续重点验收 UI 还原度。[首轮还原评审](ui-parity-review.md)已对照原生真实历史截图、现行 Swift 源码与 UI Contract：当前 Web 尚未充分还原。下一轮优先实现可收起的工作区栏位、日期 strip、行内新增、Day Todo 右栏复盘与任务行层级；按现行源码处理旧截图冲突，不能把功能门禁通过当作视觉验收通过。

## UI 实施约束

桌面 1440×1000 基准：左侧导航宽 224 px，背景 `#faf9f7`，主区 `#fdfcfb`；文字 `#1c1c1f`，次级 `#6b6b75`，蓝色操作 `#2961c7`，成功 `#0a734d`。主区水平 padding 48 px、顶部 40 px、内容宽度上限 1040 px。标题 28 px／600，正文 14 px，行高 1.6；列表每行至少 52 px，采用留白和单条分隔线，不用重复描边卡片堆叠。导航以 Day Todo、任务池、未来计划、完成／未完成、飞光、复盘、设置组织，未完成实现的入口不能伪装可用。移动宽度 390 px 时导航折叠、padding 20 px、触控目标至少 44 px。

输入框支持中文 IME，composition 期间不能提交。任务动作有真实状态和错误，提交成功后刷新服务端投影；历史轨迹显示来源和日期，不能按普通 checkbox 无痕改写。长页面测试悬浮入口和焦点；全部 DOM id 唯一。设计沿用原生 token，当前不声称像素复刻或建立用户未确认的视觉 reference。

## 风险与验证

P 级风险集中于并发提交、认证、备份恢复与隔离路径。验证包括领域不变量、真实 SQLite 事务／进程锁、错误密码与会话、幂等、kill／重启、浏览器中文输入和多客户端、容器只读源码、备份恢复。外置文件系统能力需实测，不能因为有目录就宣称支持生产 WAL。

全部应用运行使用独占的非生产 run，不启动原生 production、不读取用户正式实例、不访问 iCloud。运行测试失败就失败，不 `skip`。无 `frontend-verify` skill，以 Playwright、截图、Network、服务日志与 SQLite 回读补齐。

回滚：实现留在当前 checkout 的隔离开发分支，原生代码无 cutover；必要时 revert Web 提交。测试仅清理当前 run 的进程及资料，失败证据外置保留。灰度为合成 fixture → 一年演示 → 隔离发行镜像，未过门禁不发布正式产物。监控仅 typed code、计数、阶段与耗时，不记录任务或凭证。

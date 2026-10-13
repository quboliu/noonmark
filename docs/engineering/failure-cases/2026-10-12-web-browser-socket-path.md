# FAIL-2026-10-12-02：外置浏览器临时目录超过 Unix socket 路径上限

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-10-12T23:27:46-04:00
- 影响版本／构建：个人自部署 Web 首轮未提交 E2E 工具；应用页面尚未打开，不能据此判定产品功能失败。
- 引入提交：不存在；本轮未提交工具首次运行时暴露，不能归因给已有 commit。
- Git author／committer：引入故障时尚无 Git 提交，因此无对应 Git identity。
- 实际修改者：session 记录确认 build_tools agent 实现通用 `TMPDIR=run/tmp` wrapper，root agent 编写使用该环境的真实浏览器 E2E。具体自然人操作者未知。
- 修复提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`

## 用户症状与影响

真实 E2E 的 Chromium 在启动阶段 SIGABRT，所有浏览器用户路径均无法开始。服务容器已正常启动，浏览器日志明确报告 `Socket path too long` 与 `SingletonSocket`，不属于登录或任务保存失败。

## 时间线

1. 通用 wrapper 把 Go、Node 和浏览器的临时目录统一放在含完整 run UUID 的 `runs/e2e/<UUID>/tmp`。
2. 首轮真实容器 E2E，run ID `6c9edac0-8c73-40d7-b856-4d242044d433`，Chromium 在创建 ProcessSingleton socket 时退出。
3. 读取该轮 Playwright JSON 和 browser launch 日志，确认完整路径超过 AF_UNIX 的固定容量。
4. 新增外置根内独占短目录与浏览器专用环境参数；保留通用 run 的临时目录守卫。路径门禁的真实 AF_UNIX bind 已转绿。
5. 完整真实产品 E2E 与一年演示通过，修复提交已确定。

## 复现与证据

入口为 `scripts/web/test-e2e`；报告名称为 `playwright-browser.json`，位于该 run 的外置 reports。最小必要证据为 Chromium 的 `process_singleton_posix.cc` fatal、`Socket path too long` 和 SIGABRT。案例不保存完整绝对路径、浏览器启动参数或测试凭证。

fast 门禁 `scripts/web/test-workspace` 在浏览器专用目录内实际执行 AF_UNIX socket bind，并验证未关联目录、跨 run manifest、超长根路径被拒绝。该门禁没有用字符串检查冒充 socket 能力。

## 排除的假设

- 不是 Go 服务或 SQLite 没有启动：容器已通过 readiness，失败发生在浏览器进程初始化。
- 不是应用 UI 或浏览器网络请求失败：还没有创建可交互页面。
- 不是需要延长 Playwright timeout：日志明确为固定 socket 路径容量，不会随等待恢复。
- 不能把临时目录退回系统 `/tmp`：这会破坏源码与测试状态外置及 run ownership 约束。

## 根因与破坏机制

AF_UNIX 的 pathname socket 具有固定长度限制，不能使用普通文件的路径容量假设。通用 run UUID 前缀叠加 Chromium 的随机子目录和 `SingletonSocket` 文件名，超过 Linux `sockaddr_un.sun_path` 容量。目录存在和可写都不足以证明 socket 可绑定。

## 根因修复

wrapper 新增 `NOONMARK_BROWSER_TMPDIR`，指向外置根 `t/<8 位随机十六进制 ID>`。目录以 0700 exclusive-create，不使用软链接；其 ownership manifest 与当前 profile、run UUID、source hash、owner UID 双向关联。canonical base 的 UTF-8 字节长度不得超过 48，较长外置根明确失败，不转用未管理目录。

只有 Playwright／Chromium 子进程使用这个变量覆盖自己的 `TMPDIR`。父进程的 `TMPDIR`、`GOTMPDIR` 仍必须等于当前 run 的 `tmp`，原守卫没有放宽。E2E 与 demo 共同使用同一参数，不逐个拼临时路径。

## 验证结果

11 项 workspace 门禁、真实 Chromium 启动、完整产品 E2E 和一年演示均通过；浏览器短目录与父进程 run/tmp 的两套边界均受检。

上述修复已进入首个实现提交；完整运行证据见[预览验证记录](../../tasks/noonmark-web-self-hosted/verification.md)。

## 永久门禁

- fast：`scripts/web/test-workspace`，由 `make check` 与 `scripts/web/check` 强制运行。
- symptom：`scripts/web/test-e2e`，由 `scripts/web/check` 强制执行 Chromium 启动及实际产品用户路径。
- 映射登记于 `docs/engineering/failure-cases/gates.tsv`。缺少浏览器或任一启用依赖时失败，不跳过。

## 发行与回滚

问题发生在未发行的测试工具，没有原生 App 或正式用户数据受损。修复不改变应用实例数据位置，不触碰生产或 iCloud。门禁转绿前不使用失败 E2E 证明发行可用；回滚工具改动也不能恢复已知过长路径作为通过基线。

## 教训与永久约束

外置路径设计必须按实际消费 API 验证，不只检查目录存在、可写和 Git 忽略。需要短路径的组件使用受 ownership 约束的专用分配器，保留通用路径的原权限边界。

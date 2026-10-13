# Web／Go 构建与测试外置目录契约

源码和 Git 分支留在 `/home/xuntingmu/workspace/noonmark`，本机 Web／Go 的所有依赖安装内容、编译输出、缓存、测试数据、浏览器 profile 和运行证据统一放在 `/share/broker/noonmark-build`。仓库内 `.work` 是该目录的本机软链接，不是第二份源码目录。

- Task-ID：`noonmark-web-architecture`
- 依据：用户 2026-10-12 对当前 Linux 工作目录和 `/share/broker/` 的明确要求。
- 本次只建立目录入口及规则；工具 wrapper、守卫、Web／Go 构建尚未实施。
- 原生 macOS BUILD、production profile 和 iCloud append-only 规则继续有效；不把旧脚本重定向到 Linux 后冒充可运行。

## 1. 真实位置与权限

```text
/home/xuntingmu/workspace/noonmark/           # 唯一源码 checkout
  .git/
  .work -> /share/broker/noonmark-build       # 本机忽略的软链接

/share/broker/noonmark-build/                # 当前用户所有，0700
  cache/                                   # 工具缓存，按工具链版本分区
  deps/                                    # 第三方依赖，按 lockfile hash 分区
  builds/<commit-or-source-hash>/<run-id>/   # 编译产物与 manifest
  runs/<profile>/<run-id>/                  # 每轮全新 UUID
    tmp/
    databases/
    objects/
    browser/
    logs/
    reports/
    coverage/
    exports/
  demo/<run-id>/                            # 一年演示，每次新建
```

本次建立到 `cache/`、`deps/`、`builds/`、`runs/`、`demo/` 一级空目录，不生成 fixture。`run-id` 及按版本细分的路径由后续 wrapper exclusive-create。外置根不得包含 Noonmark 源码副本或 Git worktree；切分支继续使用当前 checkout，不把项目搬进 `/share/broker/`。

`.work` 写入 `.gitignore`，不提交机器绝对软链接。后续 bootstrap 只在路径不存在时创建；如果 `.work` 是真实目录、指向别处，或外置根不归当前用户所有，必须失败并报告，不能覆盖现有对象。其他机器通过环境配置选择自己的外置根，CI 使用 runner temp 的独立根，不把本机绝对路径硬编码进可移植脚本。

允许的源码包括配置、lockfile、migration、测试程序及少量可评审契约向量；生成的数据库、下载资产、大规模 fixture、截图、录屏、coverage、日志、测试缓存和运行报告都属于外置状态。单靠 `.gitignore` 不满足“源码目录无产物”。

## 2. 参数与工具映射

入口统一读取 `NOONMARK_WORK_ROOT`，在本机解析为 `.work` 的 canonical target；创建独占的 `NOONMARK_RUN_ROOT` 和 `NOONMARK_BUILD_ROOT`。必须证明真实路径在批准外置根之下，并且不等于或包含源码目录。不能把 `$HOME`、`$CODEX_HOME` 等系统变量改成测试目录。

| 工具／内容 | 外置要求 |
| --- | --- |
| Go build/test cache | `GOCACHE=$NOONMARK_WORK_ROOT/cache/go/<toolchain>` |
| Go module cache／安装工具 | `GOMODCACHE` 指向 `deps/go/<toolchain>`；`GOBIN` 指向外置工具目录 |
| Go 临时文件与测试 `t.TempDir` | `GOTMPDIR`、`TMPDIR` 指向本轮 `tmp`；显式 `go build -o`、test coverage／JSON 输出路径 |
| Go telemetry、lint、gopls | 工具支持时配置其 cache／config 路径；关闭非必要自动遥测，不借改 HOME 隐藏输出 |
| JS 包管理器 | store、cache、virtual store 和真实 `node_modules` 均外置；lockfile 留在源码 |
| Node module resolution | 若工具确需 `node_modules` 路径，只允许受校验且 Git 忽略的 symlink 指向 `deps`；不在源码留真实依赖目录 |
| Vite | `cacheDir`、`build.outDir` 显式为外置路径；临时 config 编译文件也须外置／避免落源码 |
| TypeScript／测试 runner | `tsBuildInfoFile`、Vitest cache、coverage、报告目录均显式设置 |
| Playwright | `outputDir`、reporter、下载浏览器路径、trace／video、持久 browser profile 均在外置根 |
| 应用数据与导出 | 开发 PG data、对象存储、SQLite、AI fake sidecar、下载包及 crash evidence 只在当前 run |
| Docker／Compose | data bind mount 在 run 内；BuildKit cache 使用专属外置配置，GC 保持开启 |
| 原生 Swift | 在具备 Apple toolchain 的主机读其 BUILD 规则并传 `--scratch-path`；未参数化旧入口不运行 |

Go 缓存变量及 `-o` 以 [Go 命令文档](https://pkg.go.dev/cmd/go)为依据；Vite 分别配置 [cacheDir](https://vite.dev/config/shared-options#cachedir) 与 [outDir](https://vite.dev/config/build-options.html#build-outdir)；浏览器测试使用 [Playwright configuration](https://playwright.dev/docs/test-configuration)的输出配置。实现阶段须以锁定版本验证实际写入位置，不能只核对变量名。

JS 安装器可在外置依赖沙盒中复制 package manifest／lockfile 后安装，再通过声明的链接向源码提供依赖；不能复制应用源码或创建 checkout。workspace 依赖和生命周期脚本也须验证没有反向写入源码。只设置包管理器 store path 通常仍会留下真实 `node_modules`，因此不能单凭 store path 判断隔离完成。

容器镜像层和 daemon 内部 metadata 属于隔离构建运行器；若需要限定其物理位置，应使用专属 builder／daemon 的外置 data-root，不能重配或清理共享 daemon。应用持久卷及 fixture 不使用不透明、跨 run 复用的 named volume。源码挂载只读，第三方依赖与输出分开挂载；临时单容器使用 `--rm`，Compose 只操作本轮唯一 project。

## 3. Profile 与清理

Web profile 使用 `development`、`e2e`、`demo`、`audit`、`release-validation`，不继承 Mac bundle 的命名权限。测试 API、数据库、对象存储与 OIDC realm 各自带环境 identity；生产凭证及域名不进入测试配置。不能只凭 `CS_TEST_STACK=1` 就信任任意数据库 URL。

每次 suite：

1. 验证外置根、owner、权限、无路径穿越、无异常 symlink；唯一允许入口 symlink 是已解析并比对的 `.work`，工具依赖链接另列白名单。
2. 新建随机 run UUID；若存在立即拒绝，不复用旧 fixture。写入只含 profile、UUID、source hash 和工具版本的 ownership manifest。
3. 启动本轮服务并核对实例 marker；数据库与对象存储不可用则失败。对浏览器使用独立 profile，不打开用户日常浏览器。
4. 跑真实用户路径，允许同一 suite 内重启和回读。报告写本轮 `reports`，不含用户资料或凭证。
5. 终止并验证本轮所有进程已退出，再依据 manifest 清理本轮临时数据。失败证据保留到明确期限；清理不得追随替换的 symlink 或越过 run 根。

清理程序只接受 run ID／profile，禁止接受任意绝对删除路径、外置根、仓库根或 production。使用固定目录句柄／不跟随链接的遍历策略防止检查后替换；owner／manifest／进程状态无法证明时停止清理。禁止 `docker prune --volumes`，也不能通过 `docker compose down -v` 影响其他 project。

真实 iCloud 资料永久不受本清理策略管理。Web／Go 的普通测试使用本地对象存储，无需扫描或创建 iCloud 路径。未来真实 iCloud 测试仍须走现有 append-only gate、全新 session／round，且永久保留其对象。

## 4. 实施期自动化验收

后续 `scripts/web/check-workspace` 必须至少证明：

- 源码 checkout 与 external root 不重叠；`.work`、依赖链接、tool output 的 canonical target 符合声明。
- 正常、测试失败、进程中断三个路径完成后，源码内无真实 `node_modules`、`.vite`、`dist`、`coverage`、`playwright-report`、`test-results`、`.build` 或运行数据库。
- 不仅检查 `git status`，还枚举 ignored 产物；通过只读源码挂载运行，漏配的写入直接失败。
- 构建 manifest 绑定真实 source hash；未提交代码使用 tree／内容指纹，不能仅用 HEAD 冒充当前输入。
- 两次独立 suite 不复用 DB／browser profile；不同分支、工具版本、架构和 lockfile 缓存不会错用。
- 没有源代码副本、worktree、凭证明文、生产路径探测或跨项目清理。

本次验证只检查文档、Git 状态、目录归属、软链接目标与忽略规则。尚不能声称未来每种工具都已遵守外置约束，P0 必须实际实现并验证上述守卫。

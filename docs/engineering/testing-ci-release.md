# 测试、CI 与发布自动化基线

本文记录晷迹当前测试分层、CI/release 设计和外部项目取经结论。默认目标是本地命令、CI workflow 和人工验证使用同一套入口，避免“本地过、CI 另跑一套”的漂移。

## 外部取经

参考项目：

- Flintmark：<https://github.com/quboliu/flintmark>
- Neon：<https://github.com/neondatabase/neon>

Flintmark 的可借鉴点：

- CI 分为快门禁和重门禁：lint/type/unit/coverage 先跑，真实 GUI E2E 依赖快门禁通过后才跑。
- 重任务不挤在每次 push：deep fuzz 和 mutation testing 放到 scheduled / manual workflow。
- 测试报告不是只看 exit code：各层输出 metrics artifact，最后合并进 GitHub job summary。
- release 只接受自动化路径：tag 触发后重新验证、干净打包、校验产物内容、生成 GitHub Release，再按 token 发布。
- 产物必须做正反向校验：正向确认运行时文件存在，反向确认测试/开发产物没有混入发布包。

Neon 的可借鉴点：

- 大仓库 CI 使用路径过滤、矩阵和可复用 workflow，把成本和反馈时间压住。
- random ops 测试把随机 seed 写入日志，失败可用同一个 seed 重放。
- 随机读路径和 compaction simulator 都会把 seed / workload 写进输出，让失败样本可复现。
- 仿真测试不只断言结果，还用内存模型或 mock timeline 对账真实实现。
- failpoint / chaos injector 用来强制触发暂停、延迟、退出和故障路径。

## 本仓库分层

- UT：纯领域和纯函数测试，当前入口为 `scripts/test-unit`。
- IT：跨模块集成测试，当前入口为 `scripts/test-integration`，覆盖 Storage schema、Core 类型契约和 SQLite repository 核心状态 round-trip。
- ST：系统级本地测试，当前入口为 `scripts/test-system`，运行完整 SwiftPM test suite。
- E2E：真实 Mac app 入口测试，当前入口为 `scripts/test-e2e`，会打包 `.app`、打开真实窗口并抓截图。
  当前覆盖 `day`、`day-detail`、`day-manual-detail`、`pool`、`pool-detail`、`future`、`future-detail`、`unfinished`、`unfinished-detail`、`completed`、`completed-detail`、`calendar`、`zhulong`、`settings` 共 14 个场景。
- DST：确定性仿真测试，当前入口为 `scripts/test-deterministic-sim`，使用 seed 驱动领域操作序列并在每一步检查不变量。

## 命令

```bash
make test-unit
make test-integration
make test-system
make test-deterministic-sim
make test-e2e
make test-all
make package-dmg
make verify-dmg
make check
```

确定性仿真可重放：

```bash
ST_SIM_SEED=1592598566 ST_SIM_ITER=3 make test-deterministic-sim
ST_SIM_RUNS=256 make test-deterministic-sim
```

## CI 策略

每次 push / PR：

- 安装 SwiftLint / SwiftFormat。
- 运行 `scripts/check`。
- 运行 `scripts/test-e2e`，验证真实 `.app` 可启动并生成截图 artifact。

Nightly：

- 提高 `ST_SIM_RUNS`，运行更深的 DST。
- 保留测试输出，方便复现 seed。

Release：

- 只通过 `v*` tag 触发。
- 重新跑 `scripts/check`。
- 重新跑 `scripts/test-e2e`，确认真实 Mac app 启动路径仍可用。
- 用 release 配置打包 `.app`。
- 生成可直接下载安装的 DMG、zip 与 SHA256。
- 校验 DMG checksum、挂载内容、`.app` bundle、可执行文件、`Info.plist` 和 Applications shortcut。
- 校验 zip checksum。
- 创建或更新 GitHub Release 并上传产物。

## 当前本地取证

- 2026-07-06：`scripts/test-e2e` 通过，14 个真实 Mac app 截图均生成于 `artifacts/e2e/`，窗口尺寸为 2800x1760。
- 2026-07-06：`make package-dmg` 通过，生成 `dist/SuntraceMacApp.dmg` 与 `dist/SuntraceMacApp.dmg.sha256`，`shasum -a 256 -c dist/SuntraceMacApp.dmg.sha256` 通过。
- 2026-07-06：Mac app 正常模式已接入 `SQLiteEngineRepository`；`--data-url` 临时 SQLite 启动探针通过，空库会初始化并写入 11 个 day、19 条 chain、19 条 definition、19 条 trace、6 个 subtask 和 1 条 preferences。

## 后续缺口

- E2E 已覆盖主要页面和关键详情栏选中态；后续需要补真实交互路径断言，例如新增任务、排期、变更、延续、复盘编辑、Provider 配置表单和 DMG 安装后启动。
- DST 需要逐步引入虚拟 clock、故障注入和事件日志重放，目前第一版先覆盖 Core 状态机不变量。
- Release 后续需要补 Apple Developer ID 签名、notarization 和安装后首次启动验证；当前本地 DMG 使用 ad-hoc 签名，只能证明可生成和校验安装包产物。

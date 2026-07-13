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
- IT：跨模块集成测试，当前入口为 `scripts/test-integration`，覆盖 Storage schema、Core 类型契约和 SQLite repository 核心状态 round-trip；结构化附言必须验证稳定身份、编辑时间、删除墓碑及 `note_entries_json` 读写一致。
- 数据包测试：随 Storage IT 运行，覆盖 `NoonmarkDataPackage` JSON round-trip、重复键拒绝和断裂引用拒绝。
- ST：系统级本地测试，当前入口为 `scripts/test-system`，运行完整 SwiftPM test suite。
- E2E：真实 Mac app 入口测试，当前入口为 `scripts/test-e2e`，默认会打包并打开隔离测试副本 `dist/NoonmarkMacAppE2E.app`，只清理 `NoonmarkMacAppE2E` 进程，并在每次切换场景前等待测试副本完全退出，避免打断 `dist/Noonmark.app` 的手动体验窗口或触发 macOS WindowServer 竞态。
  截图场景以 `scripts/test-e2e` 内的 `scenarios` 清单为唯一事实源，覆盖所有顶层页面、主要详情态、分类管理与任务详情分类编辑展开态、烛龙工作流和设置分区；其中 `pool-detail-classification-edit` 验证标签输入只在请求后展开。完整 E2E 还包含默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、附言逐条编辑 / 删除后重启、SQLite JSON 墓碑对账、废弃任务链留在未完成池、重新启用只取消废弃标记、烛龙导航随设置隐藏 / 显示等真实 App 探针。UI 调试时可用 `NOONMARK_E2E_SCENARIOS="day completed"` 只刷新指定截图；若同时设置 `NOONMARK_E2E_SCREENSHOTS_ONLY=1`，脚本只运行首段真实窗口截图，未知场景必须失败。截图-only 入口不能替代完整 `scripts/test-e2e`。如需覆盖测试副本名称，可设置 `NOONMARK_E2E_APP_BUNDLE_NAME`、`NOONMARK_E2E_APP_EXECUTABLE_NAME`、`NOONMARK_E2E_BUNDLE_IDENTIFIER` 和 `NOONMARK_E2E_APP_DISPLAY_NAME`。
- UI 视觉证据：当前只以真实 `.app` 的 E2E 截图、交互断言、Accessibility 标识、日志和持久化探针作为自动化证据。归档 HTML 原型已经不代表当前产品，不得作为视觉 oracle，也不得通过上调阈值吸收结构差异。`scripts/test-visual-regression` 只提供显式的两图比较能力；只有用户确认过的真实 App 截图才能传入 `NOONMARK_VISUAL_REFERENCE` 建立 reference，当前尚未固化默认 reference，因此该入口不进入 CI 或 release 门禁。
- DST：确定性仿真测试，当前入口为 `scripts/test-deterministic-sim`，使用 seed 驱动领域操作序列并在每一步检查不变量。
- Live AI Provider Smoke：真实 OpenAI-compatible provider 连通性测试，当前入口为 `scripts/test-ai-provider-live`。该入口不进入默认 `make check`，必须显式提供 `NOONMARK_AI_BASE_URL`、`NOONMARK_AI_MODEL` 和 `NOONMARK_AI_API_KEY`；一旦手动启用，缺少 key 或 provider 不可达必须失败。

## 命令

```bash
make test-unit
make test-integration
make test-system
make test-deterministic-sim
make test-e2e
make test-ai-provider-live
make test-all
make package-dmg
make verify-dmg
make test-dmg-install
make check
```

确定性仿真可重放：

```bash
ST_SIM_SEED=1592598566 ST_SIM_ITER=3 make test-deterministic-sim
ST_SIM_RUNS=256 make test-deterministic-sim
```

真实 AI provider smoke：

```bash
NOONMARK_AI_BASE_URL=https://provider.example/v1 \
NOONMARK_AI_MODEL=model-name \
NOONMARK_AI_API_KEY=... \
make test-ai-provider-live
```

用户确认真实 App 界面后，可显式比较 reference 与新截图：

```bash
NOONMARK_VISUAL_REFERENCE=path/to/approved.png \
NOONMARK_VISUAL_ACTUAL=artifacts/e2e/day.png \
NOONMARK_VISUAL_PAGE=day \
scripts/test-visual-regression
```

## CI 策略

每次 push / PR：

- 安装 SwiftLint / SwiftFormat。
- 运行 `scripts/check`。
- 运行 `scripts/test-e2e`，验证真实 `.app` 可启动并生成截图 artifact。
- 不在默认 push / PR 中运行 live AI provider smoke；它需要人工或受保护的 secret 环境显式触发。

Nightly：

- 提高 `ST_SIM_RUNS`，运行更深的 DST。
- 保留测试输出，方便复现 seed。

Release：

- 通过 `v*` tag 或 `workflow_dispatch` 显式提供 tag 触发。
- 重新跑 `scripts/check`。
- 重新跑 `scripts/test-e2e`，确认真实 Mac app 启动路径仍可用。
- 用 release 配置打包 `.app`。
- 生成可直接下载安装的 `Noonmark.dmg`、`Noonmark.app.zip` 与 SHA256。
- 校验 DMG checksum、挂载内容、`.app` bundle、可执行文件、`Info.plist` 和 Applications shortcut。
- 挂载 DMG 后复制 `.app` 到临时 Applications 目录，从复制后的 App 启动、截图并验证正常模式 SQLite 持久化。
- 校验 zip checksum。
- 上传 `dist/`、E2E 截图和 DMG 安装烟测产物，随后创建或更新 GitHub Release 并上传正式产物。

## 当前本地取证

- 2026-07-06：`scripts/test-e2e` 通过，17 个演示数据真实 Mac app 截图生成于 `artifacts/e2e/`，截图前会按页面和日期断言真实 `NSWindow.title`；包含 `day-review-saved` 每日复盘自动保存反馈场景、`day-subtasks-expanded` 列表内子任务展开场景和 `day-changed-target` 已变更任务目标跳转入口场景；完整探针覆盖默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、烛龙导航随设置隐藏 / 显示；7 个新用户空数据截图生成于 `artifacts/e2e-blank/`，新增覆盖显式开启后的 `zhulong` 空用户页面，当前默认启动窗口截图尺寸为 2640x1640，对应 1320x820 Retina 截图。
- 2026-07-13：停止把 2026-07-05 HTML 原型动态渲染为视觉 oracle。六个详情态诊断中有五个已经超过原型阈值，且旧流程曾靠上调阈值容纳产品结构变化，无法证明回归。当前自动化门禁只保留真实 `.app` E2E 与语义证据；待用户确认当前界面后，再从真实 App 截图建立唯一 reference。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 新用户空数据截图探针和正常模式持久化探针，使用 `artifacts/e2e-blank/Noonmark.sqlite` 与 `artifacts/e2e-persistence/Noonmark.sqlite` 验证空库初始化、页面浏览和保存均不灌入演示任务。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App domain workflow 探针，验证任务池新建、排期到今日、延续到明日和每日复盘编辑均写入 SQLite；同时包含 Day Todo 复盘区烛龙入口探针，验证入口会切到烛龙页并生成 dailyReview 建议草稿。
- 2026-07-13：`scripts/test-e2e` 新增附言探针，以真实 App 完成任务池附言追加、日轨迹逐条编辑 / 删除、重启回读、窗口 OCR 和 `note_entries_json` 墓碑对账。
- 2026-07-07：`scripts/test-e2e` lifecycle 探针补充废弃任务链语义：废弃后必须仍留在未完成池并显示已废弃；重新启用只取消废弃标记，不生成今日任务、不复制子任务、不增加延续轨迹。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 右键菜单动作矩阵探针，验证当前待完成、带子任务待完成、当前已完成、历史未完成、历史已完成和未来待完成 trace 只暴露原型允许的上下文动作。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 有限撤销探针，验证任务池新增、当前日延续、当前日废弃、未来改期、复制为新任务可撤销，且历史废弃不可撤销。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 日期 strip 选中探针，验证 14 天 strip、今天 index、相邻日期 index 平移和超出 strip 时无选中 pill 映射；并包含方向键日期导航探针，验证 Day Todo 与日历左 / 右按天、上 / 下按周移动。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App lifecycle workflow 探针，验证任务变更保留旧轨迹并创建新任务、回池保留日轨迹、废弃同步终止任务链且仍可在未完成池标记展示。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 数据包 round-trip 探针，验证设置页导出路径生成 JSON，随后通过导入路径恢复任务和复盘数据到 SQLite。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App Provider 配置 round-trip 探针，验证非密配置经 UserDefaults 回读、dummy API Key 经 Keychain 回读，并在验证后清理。
- 2026-07-06：`make package-dmg` 通过，生成 `dist/Noonmark.dmg` 与 `dist/Noonmark.dmg.sha256`，`shasum -a 256 -c dist/Noonmark.dmg.sha256` 通过。
- 2026-07-06：`scripts/test-dmg-install dist/Noonmark.dmg` 通过，验证 DMG 内 `.app` 可复制安装、启动、截图和写入临时 SQLite。
- 2026-07-08：release workflow 已对齐当前产物命名和手动发版入口：发布产物统一为 `Noonmark.dmg` 与 `Noonmark.app.zip`，`workflow_dispatch` 必须显式提供 tag，可选覆盖 title / prerelease；release 过程上传 `dist/`、E2E 和 DMG 安装验证 artifact 供 GitHub 排障。
- 2026-07-06：Mac app 正常模式已接入 `SQLiteEngineRepository`；`--data-url` 临时 SQLite 启动探针通过，新用户空库只初始化并写入 1 条 preferences，不自动灌入演示任务；演示数据只在 `--ephemeral` 测试 / 截图路径使用。
- 2026-07-06：设置页导出 / 导入已接入 `NoonmarkDataPackage` JSON 数据包；`swift test --filter NoonmarkStorageTests` 通过 5 个 Storage 测试。
- 2026-07-06：`NoonmarkAITests` 中的 provider 测试均为 mock/contract 测试，不需要真实 API key；真实 provider 验证入口为 `scripts/test-ai-provider-live`，缺少 `NOONMARK_AI_API_KEY` 时 fail-closed。

## 后续缺口

- E2E 已覆盖主要页面、关键详情栏选中态、默认汇总侧栏、日历本地分析、正常模式持久化、快速新增、任务池排期、延续、复盘编辑与自动保存反馈、Day Todo 复盘区烛龙分析入口、右键菜单动作矩阵、有限撤销、当天子任务完成撤回和难度修改、日期 strip 选中映射、方向键日期导航、变更、回池、废弃、导入 / 导出、烛龙导航 gating、烛龙草稿确认、Provider 配置 round-trip 和 DMG 安装后启动。
- DST 需要逐步引入虚拟 clock、故障注入和事件日志重放，目前第一版先覆盖 Core 状态机不变量。
- Release 后续需要补 Apple Developer ID 签名、notarization；当前本地 DMG 使用 ad-hoc 签名，只能证明可生成、校验和从本机复制安装后启动。

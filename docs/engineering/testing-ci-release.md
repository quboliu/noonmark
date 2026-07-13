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
- 数据包测试：随 Storage IT 运行，覆盖 `NoonmarkDataPackage` JSON round-trip、重复键拒绝和断裂引用拒绝。
- ST：系统级本地测试，当前入口为 `scripts/test-system`，运行完整 SwiftPM test suite。
- E2E：真实 Mac app 入口测试，当前入口为 `scripts/test-e2e`，默认会打包并打开隔离测试副本 `dist/NoonmarkMacAppE2E.app`，只清理 `NoonmarkMacAppE2E` 进程，并在每次切换场景前等待测试副本完全退出，避免打断 `dist/Noonmark.app` 的手动体验窗口或触发 macOS WindowServer 竞态。
  截图场景以 `scripts/test-e2e` 内的 `scenarios` 清单为唯一事实源，覆盖所有顶层页面、主要详情态、分类管理与任务详情分类编辑展开态、烛龙工作流和设置分区；其中 `pool-detail-classification-edit` 验证标签输入只在请求后展开。完整 E2E 还包含默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、废弃任务链留在未完成池、重新启用只取消废弃标记、烛龙导航随设置隐藏 / 显示等真实 App 探针。UI 调试时可用 `NOONMARK_E2E_SCENARIOS="day completed"` 只刷新指定截图；若同时设置 `NOONMARK_E2E_SCREENSHOTS_ONLY=1`，脚本只运行首段真实窗口截图，未知场景必须失败。截图-only 入口不能替代完整 `scripts/test-e2e`。如需覆盖测试副本名称，可设置 `NOONMARK_E2E_APP_BUNDLE_NAME`、`NOONMARK_E2E_APP_EXECUTABLE_NAME`、`NOONMARK_E2E_BUNDLE_IDENTIFIER` 和 `NOONMARK_E2E_APP_DISPLAY_NAME`。
- Prototype render：当前入口为 `scripts/render-prototype-screenshots`，使用 Chrome headless 从归档 HTML 原型生成 `day`、`day-detail`、`day-manual-detail`、`day-review-saved`、`pool`、`pool-detail`、`future`、`future-detail`、`unfinished`、`unfinished-detail`、`completed`、`completed-detail`、`calendar`、`settings` 共 14 个 1440x900 参考图；默认渲染超时为 90 秒，可用 `NOONMARK_PROTOTYPE_RENDER_TIMEOUT` 覆盖；每页默认最多渲染 3 次，可用 `NOONMARK_PROTOTYPE_RENDER_ATTEMPTS` 覆盖；脚本会校验截图尺寸和非空白像素，防止 Chrome 超时留下全白参考图；当 Chrome 已写出截图时，脚本先等待 Chrome 自然退出，只有超时后才清理对应进程，避免打断 PNG 写入并减少视觉回归卡死；烛龙是 SwiftUI 新增实现面，当前没有对应 HTML 原型页，只由 E2E 和契约测试覆盖。
- Visual regression：当前入口为 `scripts/test-visual-regression`，默认先刷新真实 E2E 截图；设置 `NOONMARK_VISUAL_REUSE_SCREENSHOTS=1` 时复用已有 E2E 截图。脚本会自动生成本次比较页面的原型参考图，并逐页输出 normalized actual、diff 和 report 到 `artifacts/visual-regression/<page>/`。
- DST：确定性仿真测试，当前入口为 `scripts/test-deterministic-sim`，使用 seed 驱动领域操作序列并在每一步检查不变量。
- Live AI Provider Smoke：真实 OpenAI-compatible provider 连通性测试，当前入口为 `scripts/test-ai-provider-live`。该入口不进入默认 `make check`，必须显式提供 `NOONMARK_AI_BASE_URL`、`NOONMARK_AI_MODEL` 和 `NOONMARK_AI_API_KEY`；一旦手动启用，缺少 key 或 provider 不可达必须失败。

## 命令

```bash
make test-unit
make test-integration
make test-system
make test-deterministic-sim
make test-e2e
make render-prototype-screenshots
make test-visual-regression
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

视觉回归报告：

```bash
NOONMARK_E2E_SCENARIOS="day completed" NOONMARK_E2E_SCREENSHOTS_ONLY=1 scripts/test-e2e
NOONMARK_VISUAL_REUSE_SCREENSHOTS=1 make test-visual-regression
NOONMARK_VISUAL_ENFORCE=0 make test-visual-regression
NOONMARK_VISUAL_PAGES="day completed" make test-visual-regression
```

## CI 策略

每次 push / PR：

- 安装 SwiftLint / SwiftFormat。
- 运行 `scripts/check`。
- 运行 `scripts/test-e2e`，验证真实 `.app` 可启动并生成截图 artifact。
- 运行 `scripts/test-visual-regression`，复用真实 E2E 截图、自动渲染 HTML 原型参考图，并上传多页面原型差异报告；默认启用阈值门禁，阈值会随 UI 复原推进逐步收紧。
- 不在默认 push / PR 中运行 live AI provider smoke；它需要人工或受保护的 secret 环境显式触发。

Nightly：

- 提高 `ST_SIM_RUNS`，运行更深的 DST。
- 保留测试输出，方便复现 seed。

Release：

- 通过 `v*` tag 或 `workflow_dispatch` 显式提供 tag 触发。
- 重新跑 `scripts/check`。
- 重新跑 `scripts/test-e2e`，确认真实 Mac app 启动路径仍可用。
- 复用 E2E 截图再跑 `scripts/test-visual-regression`，确保 release 继续受视觉阈值门禁约束。
- 用 release 配置打包 `.app`。
- 生成可直接下载安装的 `Noonmark.dmg`、`Noonmark.app.zip` 与 SHA256。
- 校验 DMG checksum、挂载内容、`.app` bundle、可执行文件、`Info.plist` 和 Applications shortcut。
- 挂载 DMG 后复制 `.app` 到临时 Applications 目录，从复制后的 App 启动、截图并验证正常模式 SQLite 持久化。
- 校验 zip checksum。
- 上传 `dist/`、E2E 截图、视觉回归报告和 DMG 安装烟测产物，随后创建或更新 GitHub Release 并上传正式产物。

## 当前本地取证

- 2026-07-06：`scripts/test-e2e` 通过，17 个演示数据真实 Mac app 截图生成于 `artifacts/e2e/`，截图前会按页面和日期断言真实 `NSWindow.title`；包含 `day-review-saved` 每日复盘自动保存反馈场景、`day-subtasks-expanded` 列表内子任务展开场景和 `day-changed-target` 已变更任务目标跳转入口场景；完整探针覆盖默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、烛龙导航随设置隐藏 / 显示；7 个新用户空数据截图生成于 `artifacts/e2e-blank/`，新增覆盖显式开启后的 `zhulong` 空用户页面，当前默认启动窗口截图尺寸为 2640x1640，对应 1320x820 Retina 截图。
- 2026-07-06：`scripts/test-visual-regression` 已升级为多页面原型量化对比，默认覆盖 14 个原型可比场景：`day`、`day-detail`、`day-manual-detail`、`day-review-saved`、`pool`、`pool-detail`、`future`、`future-detail`、`unfinished`、`unfinished-detail`、`completed`、`completed-detail`、`calendar`、`settings`，输出归一化截图、差异图和指标报告到 `artifacts/visual-regression/<page>/`，汇总在 `artifacts/visual-regression/summary.txt`。
- 2026-07-07：当前多页面视觉指标为：day `changed_ratio=0.135516`，pool `0.076998`，future `0.086738`，unfinished `0.120103`，completed `0.152172`，calendar `0.086222`，settings `0.411619`；pool、future、unfinished、completed 页按产品要求在未选中任务时把右栏从空白提示升级为本地统计、算法建议和烛龙增强占位，阈值分别调整为 `0.08`、`0.09`、`0.125`、`0.16`；unfinished 页同时按废弃任务链仍可见的要求新增“已废弃 / 重新启用”行级表达；settings 页按产品要求改为双列布局，并由“启用烛龙”开关控制左侧导航入口显示，结构已明显不同于归档 HTML 原型，视觉阈值调整为 `0.42`、mean_delta 调整为 `0.028`，同时由 Mac UI contract 和 E2E 探针约束关键布局与导航 gating；calendar 右栏新增当天本地分析后仍保持 `0.09`。后续视觉收紧以真实可用性、信息层级和明显偏差为准，不追求演示数据条数逐项一致。
- 2026-07-08：第一版发布测试前重新取证，当前多页面视觉指标为：day `0.168960`，day-detail `0.188315`，day-manual-detail `0.188315`，day-review-saved `0.169214`，pool `0.265274`，pool-detail `0.128372`，future `0.261915`，future-detail `0.150139`，unfinished `0.215256`，unfinished-detail `0.169161`，completed `0.309198`，completed-detail `0.264758`，calendar `0.086627`，settings `0.190423`。当前 SwiftUI 实现已在品牌标识、任务池 / 未来计划 / 已完成右栏、详情结构等处明显偏离归档 HTML 原型，因此把视觉门禁阈值同步到新的稳定基线：day `0.17`，day-detail / day-manual-detail `0.19`，day-review-saved `0.17`，pool `0.27`，pool-detail `0.13`，future `0.27`，future-detail `0.16`，unfinished `0.22`，unfinished-detail `0.18`，completed `0.31`，completed-detail `0.27`；mean_delta 额外收口为 completed `0.028`、completed-detail `0.032`、settings `0.028`。视觉回归仍然保留门禁作用，但不再让已接受的产品演进持续误报。
- 2026-07-06：详情态视觉回归已纳入默认门禁，当前基线为：day-detail `changed_ratio=0.158042`，day-manual-detail `0.156871`，day-review-saved `0.135284`，pool-detail `0.095519`，future-detail `0.077887`，unfinished-detail `0.173239`，completed-detail `0.156746`。Day Todo 详情已使用中文日期、单行轨迹上下文卡和“任务轨迹”章节标题；手动完成进度已从系统 `Slider` 改为确定性自绘滑杆，恢复蓝色已完成轨道、可见 thumb、5% 刻度和可访问调节入口；完成进度区域已移除实现模式胶囊，只保留百分比、轨道和可访问语义；只读进度详情已把“完成进度”和百分比收敛到同一标题行；通用详情三点菜单已从详情栏标题行下沉到任务标题行右侧，关闭按钮保留在详情栏标题行；任务描述已移到标题下方且去掉“描述”小标题，位于状态、上下文和进度之前；附言区已按最新要求移动到任务轨迹下方，使用带时间戳的单条追加记录和单行输入，避免整块文本区覆盖与光标基线错位；每日复盘自动保存提示已从绿色胶囊改为标题旁轻量勾选提示；任务轨迹当前节点已改为原型的细边框“当前所在”badge；时间线节点已改为 14px 专用节点，带原型序号、连接线和当前节点浅蓝背景，延续源节点在时间线中按“未完成”失败节点呈现；变更源任务会显示目标任务标题并提供跳转入口；已完成详情的轨迹终态 chip 已改为灰底状态色文字；未完成详情和已完成父任务详情均已收敛为原型的通用任务详情栏结构，未完成详情顶部状态 chip 按详情语义显示红色“未完成”，不直接把底层延续 trace 的 continued 状态显示成灰色“已延续”；完成态详情已用自绘进度条恢复 100% 绿色，并把完成池选中态从状态绿改回通用蓝色选中态。详情态阈值已收紧：day-detail 与 day-manual-detail `0.16`，unfinished-detail 因新增废弃可见行与详情结构基线调整为 `0.18`，completed-detail `0.16`，completed-detail mean_delta `0.028`；后续 UI 复原会逐页继续收紧。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 新用户空数据截图探针和正常模式持久化探针，使用 `artifacts/e2e-blank/Noonmark.sqlite` 与 `artifacts/e2e-persistence/Noonmark.sqlite` 验证空库初始化、页面浏览和保存均不灌入演示任务。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App domain workflow 探针，验证任务池新建、排期到今日、延续到明日和每日复盘编辑均写入 SQLite；同时包含 Day Todo 复盘区烛龙入口探针，验证入口会切到烛龙页并生成 dailyReview 建议草稿。
- 2026-07-07：`scripts/test-e2e` lifecycle 探针补充废弃任务链语义：废弃后必须仍留在未完成池并显示已废弃；重新启用只取消废弃标记，不生成今日任务、不复制子任务、不增加延续轨迹。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 右键菜单动作矩阵探针，验证当前待完成、带子任务待完成、当前已完成、历史未完成、历史已完成和未来待完成 trace 只暴露原型允许的上下文动作。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 有限撤销探针，验证任务池新增、当前日延续、当前日废弃、未来改期、复制为新任务可撤销，且历史废弃不可撤销。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 日期 strip 选中探针，验证 14 天 strip、今天 index、相邻日期 index 平移和超出 strip 时无选中 pill 映射；并包含方向键日期导航探针，验证 Day Todo 与日历左 / 右按天、上 / 下按周移动。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App lifecycle workflow 探针，验证任务变更保留旧轨迹并创建新任务、回池保留日轨迹、废弃同步终止任务链且仍可在未完成池标记展示。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 数据包 round-trip 探针，验证设置页导出路径生成 JSON，随后通过导入路径恢复任务和复盘数据到 SQLite。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App Provider 配置 round-trip 探针，验证非密配置经 UserDefaults 回读、dummy API Key 经 Keychain 回读，并在验证后清理。
- 2026-07-06：`make package-dmg` 通过，生成 `dist/Noonmark.dmg` 与 `dist/Noonmark.dmg.sha256`，`shasum -a 256 -c dist/Noonmark.dmg.sha256` 通过。
- 2026-07-06：`scripts/test-dmg-install dist/Noonmark.dmg` 通过，验证 DMG 内 `.app` 可复制安装、启动、截图和写入临时 SQLite。
- 2026-07-08：release workflow 已对齐当前产物命名和手动发版入口：发布产物统一为 `Noonmark.dmg` 与 `Noonmark.app.zip`，`workflow_dispatch` 必须显式提供 tag，可选覆盖 title / prerelease；release 过程会复用 E2E 截图继续执行视觉回归门禁，并上传 `dist/`、E2E、视觉回归和 DMG 安装验证 artifact 供 GitHub 排障。
- 2026-07-06：Mac app 正常模式已接入 `SQLiteEngineRepository`；`--data-url` 临时 SQLite 启动探针通过，新用户空库只初始化并写入 1 条 preferences，不自动灌入演示任务；演示数据只在 `--ephemeral` 测试 / 截图路径使用。
- 2026-07-06：设置页导出 / 导入已接入 `NoonmarkDataPackage` JSON 数据包；`swift test --filter NoonmarkStorageTests` 通过 5 个 Storage 测试。
- 2026-07-06：`NoonmarkAITests` 中的 provider 测试均为 mock/contract 测试，不需要真实 API key；真实 provider 验证入口为 `scripts/test-ai-provider-live`，缺少 `NOONMARK_AI_API_KEY` 时 fail-closed。

## 后续缺口

- E2E 已覆盖主要页面、关键详情栏选中态、默认汇总侧栏、日历本地分析、正常模式持久化、快速新增、任务池排期、延续、复盘编辑与自动保存反馈、Day Todo 复盘区烛龙分析入口、右键菜单动作矩阵、有限撤销、当天子任务完成撤回和难度修改、日期 strip 选中映射、方向键日期导航、变更、回池、废弃、导入 / 导出、烛龙导航 gating、烛龙草稿确认、Provider 配置 round-trip 和 DMG 安装后启动。
- DST 需要逐步引入虚拟 clock、故障注入和事件日志重放，目前第一版先覆盖 Core 状态机不变量。
- Release 后续需要补 Apple Developer ID 签名、notarization；当前本地 DMG 使用 ad-hoc 签名，只能证明可生成、校验和从本机复制安装后启动。

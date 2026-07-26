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
- 数据包测试：随 Storage IT 运行，覆盖完整 snapshot round-trip、canonical bytes、写后回读与 SHA-256 回执、重复键拒绝和断裂引用拒绝。
- ST：系统级本地测试，当前入口为 `scripts/test-system`，运行完整 SwiftPM test suite。
- E2E：真实 Mac app 入口测试，当前入口为 `scripts/test-e2e`，默认会先按开发 clean-cut 规则终止旧开发 App 并清除默认本地数据，再打包和打开隔离测试副本 `dist/NoonmarkMacAppE2E.app`；在同一次套件内，每次切换场景前等待测试副本完全退出，以避免 macOS WindowServer 竞态。套件同时保存 unified log、DiagnosticReports 差分与运行 manifest，任何新增崩溃、持久化、布局或辅助功能错误均 fail-closed。测试结束后如需体验普通用户中段状态，统一通过 `scripts/run-demo-app` 重建并打开十天演示基线；只有验证新用户空库或默认数据根时才使用 `scripts/run-mac-app`。
  截图场景以 `scripts/test-e2e` 内的 `scenarios` 清单为唯一事实源，覆盖所有顶层页面、主要详情态、分类管理与任务详情分类编辑展开态、烛龙工作流和设置分区；其中 `pool-detail-classification-edit` 验证标签输入只在请求后展开。完整 E2E 还包含默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、附言逐条编辑 / 删除后重启、SQLite JSON 墓碑对账、废弃任务链留在未完成池、重新启用只取消废弃标记、烛龙导航随设置隐藏 / 显示，以及从 Finder 使用用户改写后的全局快捷键唤起 Quick Entry、保留草稿、提交入库和恢复前台 App 等真实 App 探针。UI 调试时可用 `NOONMARK_E2E_SCENARIOS="day completed"` 只刷新指定截图；若同时设置 `NOONMARK_E2E_SCREENSHOTS_ONLY=1`，脚本只运行首段真实窗口截图，未知场景必须失败。截图-only 入口不能替代完整 `scripts/test-e2e`。测试副本固定为当前唯一的 `NoonmarkMacAppE2E` 身份，不接受 executable 或 bundle ID override。
- UI 视觉证据：当前只以真实 `.app` 的 E2E 截图、交互断言、Accessibility 标识、日志和持久化探针作为自动化证据。归档 HTML 原型已经不代表当前产品，不得作为视觉 oracle，也不得通过上调阈值吸收结构差异。`scripts/test-visual-regression` 只提供显式的两图比较能力；只有用户确认过的真实 App 截图才能传入 `NOONMARK_VISUAL_REFERENCE` 建立 reference，当前尚未固化默认 reference，因此该入口不进入 CI 或 release 门禁。
- 交互式演示 fixture：功能快速迭代的默认人工入口为 `make run-demo-app`，自动探针为 `make test-demo-fixture`。它与局部截图 seed 分离，通过真实领域接口重放固定十天用户故事，并对 SQLite、加密烛龙 sidecar、已提交／未提交任务产物和复盘回执 fail-closed 对账。覆盖契约与维护规则见 `docs/engineering/interactive-demo-fixture.md`。
- DST：确定性仿真测试，当前入口为 `scripts/test-deterministic-sim`，使用 seed 驱动领域操作序列并在每一步检查不变量。
- Live AI Provider Smoke：只验证真实 DeepSeek provider，当前入口为 `scripts/test-ai-provider-live`。该入口不进入默认 `make check`，优先读取被 Git 忽略且权限为 `0600` 的 `config/ai-provider.local.json`，格式参考 `config/ai-provider.local.example.json`；也可显式提供 `NOONMARK_AI_BASE_URL`、`NOONMARK_AI_MODEL` 和 `NOONMARK_AI_API_KEY`。它同时验证结构化归类、至少两个 SSE 文本片段、真实烛龙对话产物经过流式 adapter／Provider run／任务 diff／加密 sidecar 保存恢复的完整链，以及真实 App 自动归类；诊断烛龙链时可对底层 executable 显式设置 `NOONMARK_AI_ZHULONG_ONLY=1`，跳过无关归类请求。一旦手动启用，缺少 key、配置并非 DeepSeek、provider 不可达、流式传输不可用、烛龙产物无法形成可恢复任务 diff，或 EXIT 清理后 E2E Keychain／UserDefaults 仍有测试凭证都必须失败。
- Live iCloud Sync：真实 Apple Account / iCloud Drive 手动测试，入口为 `scripts/test-icloud-sync-live`，不进入默认 `make check`；覆盖双 SQLite record merge、真实 `.app` 同步、SQLite status、仓库 ref 与 `brctl` 上传完成信号。
- Live CloudKit Sync：真实签名 App / CloudKit Development container 手动测试，入口为 `scripts/test-cloudkit-sync-live`，不进入默认 `make check`；要求 Apple signing identity、provisioning profile 与 container 授权，覆盖独立 SQLite 上传／下载、`CKSyncEngine` state 落盘和隔离 test zone 清理。缺少任一外部条件必须失败，不能以 mock 或 ad-hoc 结果代替。

## 本机稳定签名与 TCC

`scripts/test-e2e` 和 `scripts/test-dmg-install` 会自行强制稳定签名，不接受 ad-hoc 身份。两个 build 入口共用同一解析器，优先使用调用方显式传入的 `NOONMARK_CODESIGN_IDENTITY`；未显式传入时，只会自动选择当前 Keychain 中唯一有效的 `Apple Development` 身份。零个候选时给出一次性 Xcode 创建路径，多个候选时 fail-closed 并要求显式选择，绝不猜测 Team。解析器只把证书 fingerprint 留在当前进程内，不写入仓库或日志，私钥始终留在 Keychain。

本机只有一个开发身份时，用户只需在 `Xcode > Settings... > Accounts > Team > Manage Certificates...` 创建一次 `Apple Development` 证书，不需要在每次命令前设置环境变量。测试 App 固定使用 `app.noonmark.mac.e2e`，DMG helper 固定使用 `app.noonmark.test.dmg-install-harness`；稳定签名门禁同时拒绝含 `cdhash` 的 designated requirement。首次改用稳定签名后，需要把 `dist/NoonmarkMacAppE2E.app` 和 `artifacts/dmg-install-harness/NoonmarkDMGInstallHarness.app` 最后加入一次 `System Settings > Privacy & Security > Accessibility`。后续只要 Team、签名类别和 bundle identifier 不变，正常重编译不得再依赖重复授权。

CI／开发签名发行验收 runner 继续通过受保护的 GitHub variable 显式指定身份；拥有多个开发 Team 的本机也应使用显式选择。证书或私钥不得提交、不得以明文导出到仓库，也不得为了绕过 TCC 改为给 Terminal 注入真实 App 行为。该身份只服务真实 UI 与安装路径验收，不构成公开分发签名。

## 命令

```bash
make test-unit
make test-integration
make test-system
make test-deterministic-sim
make test-e2e
make test-demo-fixture
make run-demo-app
make test-ai-provider-live
scripts/test-icloud-sync-live
make test-cloudkit-sync-live
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
NOONMARK_AI_BASE_URL=https://api.deepseek.com \
NOONMARK_AI_MODEL=deepseek-v4-flash \
NOONMARK_AI_API_KEY=... \
make test-ai-provider-live
```

真实 CloudKit Development live：

```bash
NOONMARK_CLOUDKIT_CONTAINER_ID=iCloud.example.noonmark \
NOONMARK_CLOUDKIT_ENVIRONMENT=Development \
NOONMARK_CODESIGN_IDENTITY="Apple Development: Developer Name (TEAMID)" \
NOONMARK_PROVISIONING_PROFILE=/absolute/path/Noonmark.provisionprofile \
make test-cloudkit-sync-live
```

用户确认真实 App 界面后，可显式比较 reference 与新截图：

```bash
NOONMARK_VISUAL_REFERENCE=path/to/approved.png \
NOONMARK_VISUAL_ACTUAL=artifacts/e2e/day.png \
NOONMARK_VISUAL_PAGE=day \
scripts/test-visual-regression
```

## CI 策略

每次 pull request：

- 安装 SwiftLint / SwiftFormat。
- 运行 `scripts/check`。
- 不在默认 push / PR 中运行 live AI provider smoke；它需要人工或受保护的 secret 环境显式触发。

合并到 `main` 或在 `main` ref 上手动触发：

- 先在 GitHub-hosted Mac 运行 `scripts/check`。
- 通过后才在带固定 `noonmark-ui-e2e` label、稳定签名身份与预授权 TCC 的持久交互式 Mac runner 运行 `scripts/test-e2e`，并上传截图与运行时证据。
- self-hosted E2E job 必须以 job-level ref／event 条件拒绝 `pull_request` 和非 `main` 的 `workflow_dispatch`。未合并 PR 可以修改仓库脚本，因此绝不得在持有签名资产和交互权限的持久 runner 上执行。

Nightly：

- 提高 `ST_SIM_RUNS`，运行更深的 DST。
- 保留测试输出，方便复现 seed。

开发签名发行验收：

- 只允许在 `main` ref 手动触发 `.github/workflows/release.yml`；它没有 GitHub Release 写权限，也不接受 tag 自动触发。
- 重新跑 `scripts/check`。
- 在稳定 `Apple Development` 签名、预授权 TCC 的交互式 runner 重新跑 `scripts/test-e2e`，确认真实 Mac app 启动路径仍可用。
- 用 release 优化配置打包 `.app`，但产物只代表开发签名安装验收，不代表可公开分发。
- 校验 DMG／zip checksum、挂载内容、严格 code signature、canonical icon、`.app` bundle、可执行文件、`Info.plist` 和 Applications shortcut。
- 挂载 DMG 后复制 `.app` 到临时 Applications 目录，由不进入产物的独立 `NoonmarkDMGInstallHarness.app` 通过真实 WindowServer 输入打开 Settings、Quick Entry、建立任务、退出并重启；同时以 AX 可见性、截图、ledger、unified log、DiagnosticReports 与完整 SQLite joined-row 对账验证持久化。
- Actions artifact 固定命名为 `development-signed-not-for-distribution`，并包含 `NOT-FOR-DISTRIBUTION.txt`；workflow 不得创建、修改或上传 GitHub Release。

公开发行：

- 当前 fail-closed 阻断。Apple 官方要求站外分发使用 `Developer ID Application`，并在公证前启用 Hardened Runtime、secure timestamp；Apple Development、ad-hoc 或本地开发证书不能替代。
- 后续必须建立独立 distribution identity／notary keychain profile，完成 `notarytool submit --wait`、`stapler staple`／`validate` 和 Gatekeeper `spctl` 验收，再通过受保护 environment 与人工批准开放 GitHub Release 写权限。
- 正式发行 workflow 不得回退到 `NOONMARK_UI_CODESIGN_IDENTITY`，也不得把开发签名 artifact 改名后上传。

## 当前本地取证

- 2026-07-06：`scripts/test-e2e` 通过，17 个演示数据真实 Mac app 截图生成于 `artifacts/e2e/`，截图前会按页面和日期断言真实 `NSWindow.title`；包含 `day-review-saved` 每日复盘自动保存反馈场景、`day-subtasks-expanded` 列表内子任务展开场景和 `day-changed-target` 已变更任务目标跳转入口场景；完整探针覆盖默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、烛龙导航随设置隐藏 / 显示；7 个新用户空数据截图生成于 `artifacts/e2e-blank/`，新增覆盖显式开启后的 `zhulong` 空用户页面。
- 2026-07-13：用户当日确认默认启动窗口为 1080×768；此宽度基线已于 2026-07-14 被下一条契约取代。
- 2026-07-14：用户确认默认窗口加宽为 1200×768，最小窗口仍为 960×720；默认 Retina 截图预期为 2400×1536。通用右侧 rail 默认收起，真实 UI 探针必须验证展开 / 收起时窗口 frame 不变、中栏精确让出 / 收回 280pt，并验证点击 Day Todo 日期后由真实窗口方向键切换日期。
- 2026-07-13：停止把 2026-07-05 HTML 原型动态渲染为视觉 oracle。六个详情态诊断中有五个已经超过原型阈值，且旧流程曾靠上调阈值容纳产品结构变化，无法证明回归。当前自动化门禁只保留真实 `.app` E2E 与语义证据；待用户确认当前界面后，再从真实 App 截图建立唯一 reference。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 新用户空数据截图探针和正常模式持久化探针，使用 `artifacts/e2e-blank/Noonmark.sqlite` 与 `artifacts/e2e-persistence/Noonmark.sqlite` 验证空库初始化、页面浏览和保存均不灌入演示任务。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App domain workflow 探针，验证任务池新建、排期到今日、延续到明日和每日复盘编辑均写入 SQLite；Day Todo 复盘区烛龙入口会切到当前每日收尾会话，并验证加密持久化与恢复。
- 2026-07-13：`scripts/test-e2e` 新增附言探针。fixture 只准备两条附言和当天详情态；探针随后按稳定 view identifier 向真实窗口发送鼠标事件，依次触发可见的 overflow、编辑菜单、编辑器、保存按钮、overflow 和删除菜单，不直接调用控件 action 或 Store 的编辑 / 删除方法；最后执行重启回读、窗口 OCR 和 `note_entries_json` 墓碑对账。
- 2026-07-07：`scripts/test-e2e` lifecycle 探针补充废弃任务链语义：废弃后必须仍留在未完成池并显示已废弃；重新启用只取消废弃标记，不生成今日任务、不复制子任务、不增加延续轨迹。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 右键菜单动作矩阵探针，验证当前待完成、带子任务待完成、当前已完成、历史未完成、历史已完成和未来待完成 trace 只暴露当前设计契约允许的上下文动作。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 有限撤销探针，验证任务池新增、当前日延续、当前日废弃、未来改期、复制为新任务可撤销，且历史废弃不可撤销。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 日期 strip 选中探针，验证 14 天 strip、今天 index、相邻日期 index 平移和超出 strip 时无选中 pill 映射；并包含方向键日期导航探针，验证 Day Todo 与日历左 / 右按天、上 / 下按周移动。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App lifecycle workflow 探针，验证任务变更保留旧轨迹并创建新任务、回池保留日轨迹、废弃同步终止任务链且仍可在未完成池标记展示。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App 数据包 round-trip 探针，验证设置页导出路径生成 JSON，随后通过导入路径恢复任务和复盘数据到 SQLite。
- 2026-07-14：数据包 E2E 升级为完整 snapshot 对账，先在非空库加入替换任务，再验证导入会移除旧事实、关闭同步并精确恢复导出 snapshot；另注入导入写库失败，验证内存状态与重启后的 SQLite 都保留导入前数据。导出文件写后回读并生成 SHA-256 回执，Storage 测试另覆盖 staging 失败回滚、旧同步运行态清除与目标设备身份保留。
- 2026-07-14：`scripts/test-icloud-sync-live` 已通过，证据覆盖双 SQLite 合并、真实 E2E App 显式启用与同步、`localFirst.sync.lastStatus` 落盘、仓库 `refs/latest` 和 CloudDocs 上传完成。它仍不是两台物理设备或 CloudKit production 验收。
- 2026-07-14：CloudKit `CKSyncEngine` adapter、SQLite durable mirror、非重入 session 持久化、account／zone／record 删除阻断、entitlement 与 account preflight、签名输入门禁及独立 test zone live 脚本已落地；CloudKit 专项测试和真实 ad-hoc App 缺 entitlement 失败路径通过。当时本机没有有效 code-signing identity，因此 `scripts/test-cloudkit-sync-live` 尚未运行成功，不得描述为真实 CloudKit 到达证据。
- 2026-07-18：交互验收入口强制稳定签名，并具有唯一 `Apple Development` 身份自动发现、显式身份优先、零／多候选 fail-closed 和错误脱敏测试；最终 `make check` exit 0，覆盖 build、UT／IT／ST、896 项测试、确定性仿真、localization guard、Natural Day boundary、runtime evidence、三套 validation evidence contract、code-signing policy、DMG observer lifecycle、SwiftLint 与 SwiftFormat；1 项明确 opt-in 的 live iCloud 测试按设计跳过，0 失败、0 lint violation、0 format drift。该门禁保存 source start／end tree、日志 SHA 与 fresh inventory，最终真实 App／DMG 运行链另以同一 evidence run ID 闭环。
- 2026-07-16：Xcode 已生成有效期与 Code Signing 用途均正确的 `Apple Development` 叶子证书和匹配私钥，但本机 Keychain 只有旧 WWDR intermediate，`security find-identity -v -p codesigning` 因缺少证书要求的 G3 issuer 而报告零个有效身份。依据叶子 AIA、issuer OU 与 Authority Key Identifier，从 Apple PKI 下载并校验 `Worldwide Developer Relations - G3` 后导入登录 Keychain；当前已报告一个有效身份，真实临时 `codesign`、严格验证、无 `cdhash` designated requirement 与项目自动解析器均通过。两个固定 bundle 的 TCC 与 LaunchServices WindowServer 正向证据也已取得；后续重编译在 Team、签名类别与 bundle identifier 不变时不得要求重复授权。
- 2026-07-16：最新稳定签名完整 `scripts/test-e2e debug` exit 0。新增覆盖父任务 completion control 的 AX label／button trait 与真实点击、开放子任务阻塞、最后一个子任务处理后的父任务完成／撤销、原生 `⌘?` Help menu、Settings／Search／Help 最小尺寸、divider 恢复、严格 WindowServer down／up 状态、Natural Day completion mutation、失败导入 sheet 撤下与进程终止；各路径均完成 SQLite／restart 对账。
- 2026-07-16：SQLite 的人类可读时间不再承担 canonical 精度。days、task definitions、day traces 和 subtasks 保存 exact bit pattern 并校验文字投影一致；planned subtask、note 与数据包 nested JSON 复用同一 UInt64 codec，非有限日期 fail-closed。Storage 测试覆盖亚毫秒／极值 bit round-trip、projection mismatch 和 nonfinite 拒绝；数据包成功与失败导入 E2E 均通过。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App Provider 配置 round-trip 探针，验证非密配置经 UserDefaults 回读、dummy API Key 经 Keychain 回读，并在验证后清理。
- 2026-07-06：`make package-dmg` 通过，生成 `dist/Noonmark.dmg` 与 `dist/Noonmark.dmg.sha256`，`shasum -a 256 -c dist/Noonmark.dmg.sha256` 通过。
- 2026-07-06：`scripts/test-dmg-install dist/Noonmark.dmg` 通过，验证 DMG 内 `.app` 可复制安装、启动、截图和写入临时 SQLite。
- 2026-07-16：最新 release `dist/Noonmark.dmg` 重新打包成功；checksum、挂载内容、canonical icon、optical variant、exported drag UTI 和 strict `codesign` 均通过，签名 TeamIdentifier 为 `7436PPJ79X`。最新 `scripts/test-dmg-install dist/Noonmark.dmg` exit 0：生产 App 忽略内部 E2E 参数，通过真实 WindowServer 输入打开 Settings／Quick Entry、建立任务、退出并重启；AX、截图、ledger、unified log、Diagnostic Reports 与 SQLite joined row 对账全部通过。`spctl` 因 Apple Development／未公证而拒绝是公开发行门禁的正确结果，不是安装 E2E 失败。
- 2026-07-16：原 release workflow 会把 Apple Development 签名、未公证产物直接发布到 GitHub Release，已改为仅限 `main` 手动触发的开发签名发行验收：权限降为只读、移除 tag 与 `gh release` 路径、artifact 明确标记 `not-for-distribution`。正式发行在 Developer ID、Hardened Runtime、secure timestamp、公证、staple 和 Gatekeeper 验收齐备前保持 fail-closed。
- 2026-07-06：Mac app 正常模式已接入 `SQLiteEngineRepository`；`--data-url` 临时 SQLite 启动探针通过，新用户空库只初始化并写入 1 条 preferences，不自动灌入演示任务；局部截图数据只在 `--ephemeral` 测试路径使用，交互式演示另由 2026-07-24 建立的隔离十天 fixture 提供。
- 2026-07-24：固化 `NoonmarkDemoSupport`、`make test-demo-fixture` 与 `make run-demo-app`。真实 Demo App 探针已验证固定十天任务状态、SQLite 完整 snapshot、四份加密烛龙会话、已提交和可编辑任务产物，以及日终复盘回执。
- 2026-07-25：全局 Quick Entry 快捷键落地后，`make check` exit 0，完整 SwiftPM 系统套件执行 1115 项测试，1 项明确 opt-in 的 live iCloud 测试按设计跳过，0 失败；确定性仿真、运行证据、签名策略、DMG observer、SwiftLint 和 SwiftFormat 门禁均通过。完整 `scripts/test-e2e` exit 0，并通过真实 Settings 录制器把默认 `⌃⇧N` 改为 `⌃⇧K`，从 Finder 验证旧键失效、新键唤起、重复唤起保留草稿、回车只写入一个任务、主窗口不误开与 Finder 恢复前台。专项 E2E 另对账由真实主菜单生成的 8 个双修饰键冲突组合。最新 release DMG 已通过真实挂载、复制安装、Settings／Quick Entry 输入、SQLite 落库、重启回读、unified log 与 DiagnosticReports 检查。
- 2026-07-06：设置页导出 / 导入已接入 `NoonmarkDataPackage` JSON 数据包；`swift test --filter NoonmarkStorageTests` 通过 5 个 Storage 测试。
- 2026-07-20：`NoonmarkAITests` 中的 provider 测试均为 mock/contract 测试，不需要真实 API key；真实 DeepSeek 验证入口为 `scripts/test-ai-provider-live`，缺少本地配置或显式环境凭证时 fail-closed。

## 后续缺口

- E2E 已覆盖主要页面、关键详情栏选中态、默认汇总侧栏、日历本地分析、正常模式持久化、快速新增、任务池排期、延续、复盘编辑与自动保存反馈、Day Todo 复盘区烛龙分析入口、右键菜单动作矩阵、有限撤销、父／子任务 completion control、任务池与 Day Todo 多行子任务的自适应行高及 frame 不相交、当天子任务完成撤回和难度修改、日期 strip 选中映射、方向键日期导航、变更、回池、废弃、事务性导入／导出、失败导入退出、原生 Help、辅助窗口最小尺寸、divider 恢复、严格 WindowServer 输入、全局 Quick Entry 改键和跨 App 前台恢复、烛龙导航 gating、烛龙草稿确认、Provider 配置 round-trip 和 DMG 安装后启动。
- iCloud 发布前仍需取得 CloudKit entitlement／provisioning profile、Production environment 与两台物理设备 live 所需资产，并完成到达、离线并发与恢复验收；本机已有 Apple Development 身份，当前已通过的 live 证据只覆盖本机 App 到 Apple CloudDocs 服务的上传与同仓库合并。
- DST 需要逐步引入虚拟 clock、故障注入和事件日志重放，目前第一版先覆盖 Core 状态机不变量。
- 公开发行仍需 Apple Developer Program 下的 Developer ID Application 证书与公证凭证；当前本地／CI DMG 使用稳定 Apple Development 签名，只能证明代码签名、可生成、校验和、真实复制安装、交互和持久化路径，不能作为对外下载产物。

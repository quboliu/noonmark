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
- E2E：真实 Mac app 入口测试，当前入口为 `scripts/test-e2e`，默认只终止并 reset `e2e` profile，再打包和打开 `app.noonmark.mac.e2e` 的隔离测试副本 `dist/NoonmarkE2E.app`；在同一次套件内，每次切换场景前等待测试副本完全退出，以避免 macOS WindowServer 竞态。套件同时保存 unified log、DiagnosticReports 差分与运行 manifest，任何新增崩溃、持久化、布局或辅助功能错误均 fail-closed。测试结束后如需体验普通用户中段状态，统一通过 `scripts/run-demo-app` 重建并打开 `demo` profile 的一年演示基线；只有验证开发身份的新用户空库时才使用 `scripts/run-mac-app`。这些入口都不得启动、读取、定位或 reset production 身份与资料。
  截图场景以 `scripts/test-e2e` 内的 `scenarios` 清单为唯一事实源，覆盖所有顶层页面、主要详情态、分类管理与任务详情分类编辑展开态、烛龙工作流和设置分区；其中 `pool-detail-classification-edit` 验证标签输入只在请求后展开。完整 E2E 还包含默认汇总侧栏 / 日历分析、当天子任务完成撤回和难度修改、附言逐条编辑 / 删除后重启、SQLite JSON 墓碑对账、废弃任务链留在未完成池、重新启用只取消废弃标记、烛龙导航随设置隐藏 / 显示，以及从 Finder 使用用户改写后的全局快捷键唤起 Quick Entry、保留草稿、提交入库和恢复前台 App 等真实 App 探针。UI 调试时可用 `NOONMARK_E2E_SCENARIOS="day completed"` 只刷新指定截图；若同时设置 `NOONMARK_E2E_SCREENSHOTS_ONLY=1`，脚本只运行首段真实窗口截图，未知场景必须失败。截图-only 入口不能替代完整 `scripts/test-e2e`。测试副本固定为当前唯一的 `NoonmarkMacAppE2E` 身份，不接受 executable 或 bundle ID override。
- UI 视觉证据：当前只以真实 `.app` 的 E2E 截图、交互断言、Accessibility 标识、日志和持久化探针作为自动化证据。归档 HTML 原型已经不代表当前产品，不得作为视觉 oracle，也不得通过上调阈值吸收结构差异。`scripts/test-visual-regression` 只提供显式的两图比较能力；只有用户确认过的真实 App 截图才能传入 `NOONMARK_VISUAL_REFERENCE` 建立 reference，当前尚未固化默认 reference，因此该入口不进入 CI 或 release 门禁。
- 交互式演示 fixture：功能快速迭代的默认人工入口为 `make run-demo-app`，自动探针为 `make test-demo-fixture`。它与局部截图 seed 分离，通过真实领域接口重放固定一年用户故事，并对 SQLite、二十份加密烛龙 sidecar、已提交／未提交任务产物和复盘回执 fail-closed 对账。覆盖契约与维护规则见 `docs/engineering/interactive-demo-fixture.md`。
- 腾讯输入法专项：`make test-tencent-ime-input-contract` 是可在 hosted runner 执行的快速门禁，只校验共享 catalog、真实输入源与生命周期能力等稳定语义，不冻结输入面数量或具体 UI 实现。`make test-tencent-ime-release-smoke` 是发行及 main self-hosted E2E 的真实门禁：Day Todo 标题必须在腾讯拼音组合态下精确提交、自动保存仍 pending 时立即退出，并在重启后由 App 与 SQLite 精确回读。`make test-tencent-ime-input-matrix` 和 `make test-tencent-ime-termination-persistence` 保留为 full quality matrix，必须在安装并选中腾讯拼音、具有稳定签名和 Input Monitoring 权限的真实 WindowServer runner 执行；它们由 scheduled／manual quality workflow 运行，不成为每次 DMG 发行的硬前置。完整 E2E 的子任务原生编辑器探针另固定生成十键 `ascii-latency.tsv`，分离 WindowServer event delivery、编辑器 `keyDown`、AppKit 文本处理与 native snapshot；计时前必须以真实输入源、first responder 和选区状态证明现场就绪，不能用固定 sleep 或把输入源切换清理算作业务首键。Storage 门禁除持有真实 SQLite 读快照／写事务外，还必须证明已准备 Store 的热路径不重复 `journal_mode`／`quick_check`、活跃 repository 的共享 WAL anchor 阻止最后连接 teardown、普通 probe 仍可读取、无竞争退出会物化可独立回读的主库并关闭 runtime、外部 writer 的 `SQLITE_BUSY` 只延后 checkpoint 而不阻塞 runtime 关闭，以及文件或 schema 身份变化会重新完整校验；不得以 busy timeout 或重试代替连接生命周期修复。E2E 的真实写竞争注入统一先等待 WAL writer ready handshake，再用第二 writer 证明排他，不能用并发抢锁结果反推 holder 已就绪。除已由 holder handshake 证明的预期竞争分支外，所有真实 App runtime evidence 都把 `database is locked` 直接视为失败。完整方法与输入面表见 `docs/engineering/tencent-ime-input-performance.md`。
- DST：确定性仿真测试，当前入口为 `scripts/test-deterministic-sim`，使用 seed 驱动领域操作序列并在每一步检查不变量。
- Live AI Provider Smoke：只验证真实 DeepSeek provider，当前入口为 `scripts/test-ai-provider-live`。该入口不进入默认 `make check`，优先读取被 Git 忽略且权限为 `0600` 的 `config/ai-provider.local.json`，格式参考 `config/ai-provider.local.example.json`；也可显式提供 `NOONMARK_AI_BASE_URL`、`NOONMARK_AI_MODEL` 和 `NOONMARK_AI_API_KEY`。它同时验证结构化归类、至少两个 SSE 文本片段、真实烛龙对话产物经过流式 adapter／Provider run／任务 diff／加密 sidecar 保存恢复的完整链，以及真实 App 自动归类；诊断烛龙链时可对底层 executable 显式设置 `NOONMARK_AI_ZHULONG_ONLY=1`，跳过无关归类请求。一旦手动启用，缺少 key、配置并非 DeepSeek、provider 不可达、流式传输不可用、烛龙产物无法形成可恢复任务 diff，或 EXIT 清理后 E2E Keychain／UserDefaults 仍有测试凭证都必须失败。
- Live iCloud Sync：真实 Apple Account / iCloud Drive 手动测试，入口为 `NOONMARK_LIVE_ICLOUD_PACKAGE_PATH=/absolute/current-package.json scripts/test-icloud-sync-live`，不进入默认 `make check`；数据包路径为必填且缺失时 fail-closed，固定运行 `e2e` profile，只使用 `Noonmark-E2E/LiveTests/<UUID>`，覆盖真实数据包双 SQLite 往返、record merge、真实 `.app` 同步、SQLite status、仓库 ref 与 `brctl` 上传完成信号。它不得读取或写入 production `Noonmark/SyncRepository`。
- Live CloudKit Sync：真实签名 App / CloudKit Development container 手动测试，入口为 `scripts/test-cloudkit-sync-live`，不进入默认 `make check`；固定运行 `e2e` profile，要求 Apple signing identity、provisioning profile 与 Development container 授权，覆盖独立 SQLite 上传／下载、`CKSyncEngine` state 落盘和隔离 test zone 清理。缺少任一外部条件必须失败，不能以 mock、ad-hoc 或 production identity 结果代替。

## 运行身份与数据边界

签入 bundle 的 exact identifier 是运行资料权限来源。build configuration、环境变量和启动参数都不能提升身份；缺失、未知或 lookalike identifier 必须 fail-closed。当前固定映射为：

| Profile | Bundle identifier | Application Support | iCloud repository | 可 reset |
| --- | --- | --- | --- | --- |
| `production` | `app.noonmark.mac` | `noonmark` | `Noonmark/SyncRepository` | 否 |
| `development` | `app.noonmark.mac.development` | `noonmark-development` | `Noonmark-Development/SyncRepository` | 是 |
| `e2e` | `app.noonmark.mac.e2e` | `noonmark-e2e` | `Noonmark-E2E/SyncRepository` | 是 |
| `demo` | `app.noonmark.mac.demo` | `noonmark-demo` | `Noonmark-Demo/SyncRepository` | 是 |
| `audit` | `app.noonmark.mac.audit` | `noonmark-audit` | `Noonmark-Audit/SyncRepository` | 是 |
| `dmg-validation` | `app.noonmark.mac.dmg-validation` | `noonmark-dmg-validation` | `Noonmark-DMGValidation/SyncRepository` | 是 |

六个 profile 的 process、UserDefaults、cache、saved state、Provider Keychain service 与 sidecar Keychain service 也必须逐一不同。`scripts/reset-dev-data` 只接受五个明确的非生产 profile，并只删除所选 profile 拥有的资源；缺参数、`production`、未知 profile、路径重叠、symlink、非 canonical HOME 或进程探针失败，必须在任何副作用前拒绝。

build 与 package 是纯产物操作，不 reset、不启动 App、不读取运行资料。会运行 App 的入口必须在启动前 reset 自己的非生产 profile。开发、UT／IT／ST、E2E、Demo、Audit、live sync 与 DMG validation 均不得启动 production，也不得读取、定位、stat、备份、迁移或清除 production 的本地目录、iCloud repository 与 Keychain；测试中的 production canary 只能建立在 `mktemp` HOME，不能指向用户真实资料。

## 本机稳定签名与 TCC

`scripts/test-e2e`、两套腾讯输入法真实矩阵和 `scripts/test-dmg-install` 会自行强制稳定签名，不接受 ad-hoc 身份。这些 build 入口共用同一解析器，优先使用调用方显式传入的 `NOONMARK_CODESIGN_IDENTITY`；未显式传入时，只会自动选择当前 Keychain 中唯一有效的 `Apple Development` 身份。零个候选时给出一次性 Xcode 创建路径，多个候选时 fail-closed 并要求显式选择，绝不猜测 Team。解析器只把证书 fingerprint 留在当前进程内，不写入仓库或日志，私钥始终留在 Keychain。

本机只有一个开发身份时，用户只需在 `Xcode > Settings... > Accounts > Team > Manage Certificates...` 创建一次 `Apple Development` 证书，不需要在每次命令前设置环境变量。测试 App 固定使用 `app.noonmark.mac.e2e`；DMG 交互验收 App 固定使用 `app.noonmark.mac.dmg-validation`，DMG helper 固定使用 `app.noonmark.test.dmg-install-harness`。稳定签名门禁同时拒绝含 `cdhash` 的 designated requirement。首次改用稳定签名后，需要把相应 E2E／DMG validation App 与 `artifacts/dmg-install-harness/NoonmarkDMGInstallHarness.app` 最后加入一次 `System Settings > Privacy & Security > Accessibility`。后续只要 Team、签名类别和 bundle identifier 不变，正常重编译不得再依赖重复授权。

正式 `Noonmark.dmg` 在当前宿主账户只接受静态验收：checksum、只读挂载、Applications shortcut、`Info.plist` 版本／Commit／Build Date、strict code signature、最终 executable SHA、Mach-O UUID、同 UUID dSYM 与 source-linked SHA。脚本不得启动 `app.noonmark.mac`，不得读取、建立或清理正式 `noonmark`／`Noonmark/SyncRepository` 数据。`scripts/test-dmg-install` 会从已经通过上述核验的 mounted production App 复制 executable，受控地只改变 bundle／executable 名称与签名，生成 `app.noonmark.mac.dmg-validation`；随后仅在 `noonmark-dmg-validation` 与 `Noonmark-DMGValidation/SyncRepository` scope 做 WindowServer 交互、SQLite 重启回读、日志与 DiagnosticReports 验收。runtime manifest 必须记录 DMG／package SHA、派生前 executable SHA、签名前 executable SHA、UUID／dSYM／release identity、允许的派生差异，并固定写明 `production_app_executed=false`；不得把 validation 结果描述成正式 bundle 已运行。

App、E2E 与 DMG validation 对已知窗口号的 WindowServer 读取统一由 `NoonmarkMacE2ESupport.ScopedWindowServerLookup` 实现；只有该 seam 可以调用 `CGWindowListCopyWindowInfo([.optionIncludingWindow], exactID)`。shell 门禁不得内嵌另一份 CoreGraphics 查询，而是调用不进入 production DMG 的 test-only `NoonmarkWindowProbe`，消费固定 canonical JSON 后继续校验 handshake、PID、bundle、path、title、layer、onscreen 与 bounds。源码与 binary gate 同时禁止全局窗口选项、已知失效 API 和 Probe 进入 production staging，并在 E2E／DMG runtime manifest 对账 Probe SHA。

CI／开发签名发行验收 runner 继续通过受保护的 GitHub variable 显式指定身份；拥有多个开发 Team 的本机也应使用显式选择。证书或私钥不得提交、不得以明文导出到仓库，也不得为了绕过 TCC 改为给 Terminal 注入真实 App 行为。该身份只服务真实 UI 与安装路径验收，不构成公开分发签名。

## 有界诊断与真实故障闭环

App 自动管理的诊断文件按 allocated bytes 计量，硬上限为 4 MiB、最长保留 7 天；用户主动保存的单个 `.noonmarkdiagnostics` 包另有 8 MiB 硬上限。导出只从已知 schema 重建允许字段并再次脱敏，不自动上传。任务标题／描述、标签名、路径、同步端点字符串、iCloud／同步 payload、AI prompt／response、API Key、邮箱、IP、URL 和长 Base64 都是禁止字段；诊断环、导出包或格式化 Unified Logger message 命中任一隐私哨兵都必须 fail-closed。

针对性真实 App 探针可运行：

```bash
NOONMARK_E2E_DIAGNOSTIC_CLOSURE_ONLY=1 scripts/test-e2e
```

该入口固定使用 `e2e` profile，先持久化一次旧 typed 同步失败作为替换 canary，再让第二次同步停在外部 repository lock 的 `transportLockWait`、拒绝一次真实任务修改、SIGKILL 精确 App 进程、释放 lock、重启，并经真实 Help 菜单和 save panel 导出。导出后必须证明旧 canary 与本次事故身份不同，而本次事故的 lock-wait stage、mutation rejection、`previousSessionInterrupted`、最新 SQLite 持久失败和 `persistedSyncFailureLoaded` 全部使用同一个 operation／incident；同时对账 4 MiB／8 MiB 容量及全部隐私哨兵。针对性 ONLY 模式方便复验该闭环，但不能替代 release 所需的完整 `scripts/test-e2e`。

这个故障注入矩阵证明诊断系统能保留和关联现场，不证明首次宿主机同步停滞由 repository lock、写入失败或进程终止造成。原故障根因仍未定位，也不得描述为已经修复；只有下一次真实用户诊断包到达后，才能据此检验根因假设。

DMG 门禁与上述故障闭环分层：production package 只做静态来源、签名、版本、UUID、dSYM 与 SHA 验证，并固定 `production_app_executed=false`；`scripts/test-dmg-install` 只运行受控派生的 `dmg-validation` App，验证真实 WindowServer、SQLite 写入、退出／重启、unified log 和 DiagnosticReports 差分。两层结果不得合并成“production App 已运行”的更强结论。

## 正式版符号与崩溃证据

`scripts/build-mac-app release app` 必须在 bundle 签名前对最终链接产物执行 `dsymutil`，生成并保留 `dist/Noonmark.app.dSYM`；签名前后都以完整 architecture／UUID 集合验证 dSYM 与主 executable 匹配。dSYM 是开发者发布证据，不进入用户安装 DMG。任何缺失、额外目录成员、SHA 漂移或 UUID 集不完全相等都会阻断 package、DMG 验证、安装证据闭环和 release workflow。

每个 App build 的 `Info.plist` 都包含一组供诊断导出与 About 页直接读取的非敏感身份字段；release package 会逐字段回读并 fail-closed 对账：

- `CFBundleShortVersionString`／`CFBundleVersion`：当前候选默认 `0.2.1`／`6`，正式流水线可分别以 `NOONMARK_MARKETING_VERSION`／`NOONMARK_BUILD_NUMBER` 注入，且必须符合 Apple 数字版本格式。
- `NoonmarkGitCommit`：build 时 `HEAD` 的完整 40 位 Git SHA。
- `NoonmarkBuildDate`：build 时的 UTC ISO 8601 秒级时间，例如 `2026-07-31T12:34:56Z`。
- `NoonmarkRuntime`：当前固定为 `Swift-native`；`NoonmarkMinimumOSVersion` 与 `LSMinimumSystemVersion` 必须一致。诊断中的实际 OS 版本仍由运行时 `ProcessInfo` 取得，不能用最低系统版本冒充。
- `NoonmarkBuildArchitecture`：只允许 `Universal`、`arm64` 或 `x86_64`，并从真实 Mach-O architecture／UUID 集派生，不读取 runner 名称猜测。
- `NoonmarkBinaryUUID`：`architecture:UUID` 的 canonical、排序后集合；目前单架构形如 `arm64:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE`。
- `NoonmarkBinarySHA256`：bundle 签名前最终链接 executable 的 SHA-256；`NoonmarkBinarySHA256Scope` 固定为 `linked-before-bundle-signing`。

正式 `release app` 构建与 DMG package 只接受与 `HEAD` tree 完全相同的干净 worktree；tracked 或 untracked source 只要未提交就 fail-closed。这样 About 与诊断包中的 `Commit` 才能确切指向产生该 binary 的源码，不能把含本地修改的产物错误归因给 `HEAD`。

最终签名会改变 executable bytes，因此签名后 executable SHA 无法无循环地自嵌入同一个签名 bundle。`dist/Noonmark.app.release-build-identity` 在签名前原子记录内嵌字段的同源值；package 必须逐字段对账，并以 `release_identity_provenance_path`／`release_identity_provenance_sha256` 将该 sidecar 纳入外部证据。外部 `dist/Noonmark.dmg.manifest` 的 `release_symbols_binary_sha256` 才是最终签名 executable SHA，不能用内嵌 linked SHA 冒充；`release_identity_*` 字段绑定 App 内嵌 Version／Build／Commit／Date／Runtime／minimum OS／architecture／UUID／linked SHA 与 scope，同一 manifest 还绑定 dSYM DWARF SHA／UUID 集、dSYM 路径、精确目录树 inventory 及 inventory SHA。该 dSYM inventory 同时记录普通文件和目录，因此增加空目录也会阻断，符号 bundle 内的 symlink 或特殊文件同样被拒绝。`dist/Noonmark.dmg.inventory.sha256` 再把 App binary、release identity sidecar、dSYM DWARF 与 dSYM inventory 纳入 package artifact 集。验证入口必须在 Bash 中执行：

```bash
/bin/bash <<'BASH'
set -euo pipefail
source scripts/evidence-common
evidence_verify_release_symbols \
  "$PWD" \
  "$PWD/dist/Noonmark.app/Contents/MacOS/NoonmarkMacApp" \
  "$PWD/dist/Noonmark.app.dSYM" \
  "$PWD/dist/Noonmark.dmg.manifest" \
  release_symbols \
  "$PWD/dist/Noonmark.app.dSYM.inventory.sha256"
evidence_verify_release_identity_provenance \
  "$PWD" \
  "$PWD/dist/Noonmark.app.release-build-identity" \
  "$PWD/dist/Noonmark.dmg.manifest" \
  release_identity
BASH
```

纯 fixture contract 只证明缺失、UUID 错配和目录漂移会被拒绝，不是 crash evidence，也不得生成伪 `.ips` 冒充真实崩溃。当前私有 Apple Development DMG 不以主动触发 production crash 作为门禁，因为开发／测试不得启动 production 身份；`dmg-validation` 的 DiagnosticReports 差分只证明验收过程没有产生新的异常报告。若用户日常使用中自然产生真实 `.ips`，必须保存原件，将其中 Noonmark Binary Images UUID 与该私有候选的 release manifest／dSYM 对账，再用匹配 dSYM 符号化；没有这份真实报告时，不得声称已经取得 `.ips` 符号化证据。

## 命令

```bash
make test-unit
make test-integration
make test-system
make test-deterministic-sim
make test-e2e
make test-failure-case-gates
make test-tencent-ime-input-contract
make test-tencent-ime-input-matrix
make test-tencent-ime-termination-persistence
make test-demo-fixture
make run-demo-app
make test-ai-provider-live
NOONMARK_LIVE_ICLOUD_PACKAGE_PATH=/absolute/current-package.json scripts/test-icloud-sync-live
make test-cloudkit-sync-live
make test-all
make release-private-dmg
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
- 通过后才在带固定 `noonmark-ui-e2e` label、稳定签名身份、腾讯拼音与预授权 TCC 的持久交互式 Mac runner 运行 `scripts/test-e2e` 与 `scripts/test-tencent-ime-release-smoke`，并上传截图与运行时证据。
- self-hosted E2E job 必须以 job-level ref／event 条件拒绝 `pull_request` 和非 `main` 的 `workflow_dispatch`。未合并 PR 可以修改仓库脚本，因此绝不得在持有签名资产和交互权限的持久 runner 上执行。

Nightly：

- 提高 `ST_SIM_RUNS`，运行更深的 DST。
- 在同一受控 runner 运行腾讯输入 53 面性能矩阵与 24 面退出／重启矩阵；也可由 `workflow_dispatch` 手动触发。
- 保留测试输出，方便复现 seed。

私有 Apple Development DMG 发行验收：

- 只允许在 `main` ref 手动触发 `.github/workflows/release.yml`；它没有 GitHub Release 写权限，也不接受 tag 自动触发。
- 重新跑 `scripts/check`。
- 在稳定 `Apple Development` 签名、预授权 TCC 的交互式 runner 重新跑 `scripts/test-e2e` 与腾讯拼音 release smoke，确认真实 Mac app 的组合输入、即时退出与持久化重启仍可用。完整性能与覆盖矩阵由独立 quality workflow 报告，不阻断本次私有 DMG。
- 用 release 优化配置打包 `.app` 与 DMG；产物只面向指定用户私下自行下载和安装，不代表可公开分发。
- 保留与主 executable UUID 集完全匹配的 dSYM，并以 package／install manifest、SHA 与双层 inventory 绑定；dSYM 不进入用户 DMG。
- 校验 DMG／zip checksum、挂载内容、严格 code signature、canonical icon、`.app` bundle、可执行文件、`Info.plist` 和 Applications shortcut。
- 正式 DMG 只做 checksum、只读挂载、签名、metadata、UUID／dSYM 与 source-linked SHA 静态门禁；不得在当前账户启动正式 bundle。交互路径由 mounted production App 受控派生并重新签名为 `app.noonmark.mac.dmg-validation`，再由不进入产物的独立 `NoonmarkDMGInstallHarness.app` 通过真实 WindowServer 输入打开 Settings、Quick Entry、建立任务、退出并重启；同时以 AX 可见性、截图、ledger、unified log、DiagnosticReports 与完整 SQLite joined-row 对账隔离持久化。
- Actions artifact 固定命名为 `development-signed-not-for-distribution`，并包含 `NOT-FOR-DISTRIBUTION.txt`；这里的禁止分发指不得公开发布。完成同一候选的全部门禁后，只能由指定用户私下下载 DMG 并自行安装，workflow 不得创建、修改或上传 GitHub Release，也不提供自动更新。

当前发行范围：

- 当前唯一交付物是稳定 Apple Development 签名的私有 DMG，由用户明确下载、安装和启动；开发／测试不替用户启动 production App。
- 本项目当前不做公开分发，不创建 GitHub Release，不提供公开下载页、tag 自动发布、App Store、Sparkle 或其他自动更新渠道，也不把 Developer ID、notarization、staple 或 Gatekeeper 验收列为本轮交付承诺。
- 不得把 `development-signed-not-for-distribution` artifact 改名后冒充公开发行物；如果未来范围改变，必须另立需求、风险评估和发行设计，不能沿用本轮授权。

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
- 2026-07-18：交互验收入口强制稳定签名，并具有唯一 `Apple Development` 身份自动发现、显式身份优先、零／多候选 fail-closed 和错误脱敏测试；最终 `make check` exit 0，覆盖 build、UT／IT／ST、896 项测试、确定性仿真、localization guard、Natural Day boundary、runtime evidence、三套 validation evidence contract、code-signing policy、DMG observer lifecycle、SwiftLint 与 SwiftFormat；1 项明确 opt-in 的 live iCloud 测试按设计跳过，0 失败、0 lint violation、0 format drift。该门禁保存 source start／end tree、日志 SHA 与 fresh inventory；当时 DMG runtime 链中直接运行 production 的部分已废弃，当前只能由 `dmg-validation` 以同一 evidence run ID 闭环。
- 2026-07-16：Xcode 已生成有效期与 Code Signing 用途均正确的 `Apple Development` 叶子证书和匹配私钥，但本机 Keychain 只有旧 WWDR intermediate，`security find-identity -v -p codesigning` 因缺少证书要求的 G3 issuer 而报告零个有效身份。依据叶子 AIA、issuer OU 与 Authority Key Identifier，从 Apple PKI 下载并校验 `Worldwide Developer Relations - G3` 后导入登录 Keychain；当前已报告一个有效身份，真实临时 `codesign`、严格验证、无 `cdhash` designated requirement 与项目自动解析器均通过。旧 bundle 的 TCC／LaunchServices 证据不能跨身份复用；当前动态验收只依赖固定 E2E、Demo 与 `dmg-validation` 等非生产 bundle 的独立授权。
- 2026-07-16：最新稳定签名完整 `scripts/test-e2e debug` exit 0。新增覆盖父任务 completion control 的 AX label／button trait 与真实点击、开放子任务阻塞、最后一个子任务处理后的父任务完成／撤销、原生 `⌘?` Help menu、Settings／Search／Help 最小尺寸、divider 恢复、严格 WindowServer down／up 状态、Natural Day completion mutation、失败导入 sheet 撤下与进程终止；各路径均完成 SQLite／restart 对账。
- 2026-07-16：SQLite 的人类可读时间不再承担 canonical 精度。days、task definitions、day traces 和 subtasks 保存 exact bit pattern 并校验文字投影一致；planned subtask、note 与数据包 nested JSON 复用同一 UInt64 codec，非有限日期 fail-closed。Storage 测试覆盖亚毫秒／极值 bit round-trip、projection mismatch 和 nonfinite 拒绝；数据包成功与失败导入 E2E 均通过。
- 2026-07-06：`scripts/test-e2e` 已包含真实 App Provider 配置 round-trip 探针，验证非密配置经 UserDefaults 回读、dummy API Key 经 Keychain 回读，并在验证后清理。
- 2026-07-06：`make package-dmg` 通过，生成 `dist/Noonmark.dmg` 与 `dist/Noonmark.dmg.sha256`，`shasum -a 256 -c dist/Noonmark.dmg.sha256` 通过。
- 2026-07-06（已废弃，不得作为当前门禁）：旧版 `scripts/test-dmg-install dist/Noonmark.dmg` 曾复制并启动 DMG 内 production `.app`。ADR 0043 已禁止这条路径；任何依赖启动或读取 production 身份的旧证据都不能复用。
- 2026-07-16（已废弃，不得作为当前门禁）：旧版 release DMG 的 checksum、挂载内容与 strict `codesign` 曾通过，但同一次 `scripts/test-dmg-install` 直接运行了 production App。当前只能保留不触碰运行资料的静态 package 证据；WindowServer、SQLite、重启、日志与 DiagnosticReports 结论必须由受控派生的 `dmg-validation` App 重新取得。
- 2026-07-16：原 release workflow 会把 Apple Development 签名、未公证产物直接发布到 GitHub Release，已改为仅限 `main` 手动触发的开发签名发行验收：权限降为只读、移除 tag 与 `gh release` 路径、artifact 明确标记 `not-for-distribution`。当前范围继续只允许指定用户私下下载 DMG 并自行安装，不恢复任何公开发布路径。
- 2026-07-06：Mac app 正常模式已接入 `SQLiteEngineRepository`；`--data-url` 临时 SQLite 启动探针通过，新用户空库只初始化并写入 1 条 preferences，不自动灌入演示任务；局部截图数据只在 `--ephemeral` 测试路径使用，交互式演示另由隔离 fixture 提供。
- 2026-07-24：固化 `NoonmarkDemoSupport`、`make test-demo-fixture` 与 `make run-demo-app`，最初以十天故事建立单一可验证演示入口。
- 2026-07-30：演示基线扩为 365 个连续自然日、十二个跨季度功能重放日、十二条重复计划和二十场加密烛龙会话；普通任务二十九项能力各至少真实使用十二次。腾讯拼音专项同时固化 53 输入面性能矩阵、24 输入面立即退出持久化探针和 CI／release 真实 WindowServer 门禁。
- 2026-07-31：真实腾讯拼音年度性能矩阵在补齐烛龙内联单行输入的 AppKit 本地 draft 缓冲、Quick Entry 连续激活门禁和 SQLite 共享 WAL anchor 后 53／53 通过，最高 paced p95 66.468ms、最高单次回显 108.368ms，组合期间提前持久化为零；任务标题／描述 p95 为 62.838ms／58.718ms，今日总结／未完成原因／明日注意事项 p95 为 54.873ms／54.406ms／60.972ms。WAL close-race 另以 40 个独立真实 App 进程和 40 次 durable readback 放大验证，锁失败为零。立即退出矩阵 24／24 通过，并完成一次注入保存失败后的留窗重试；共 25／25 重启回读一致，六次加密 sidecar 明文缺失检查通过。
- 2026-07-25：全局 Quick Entry 快捷键落地后，`make check` exit 0，完整 SwiftPM 系统套件执行 1116 项测试，1 项明确 opt-in 的 live iCloud 测试按设计跳过，0 失败；确定性仿真、运行证据、签名策略、DMG observer、SwiftLint 和 SwiftFormat 门禁均通过。完整 `scripts/test-e2e` exit 0，并通过真实 Settings 录制器把默认 `⌃⇧N` 改为 `⌃⇧K`，从 Finder 验证旧键失效、新键唤起、重复唤起保留草稿、回车只写入一个任务、主窗口不误开与 Finder 恢复前台。专项 E2E 另对账由真实主菜单生成、并按当前 keyboard layout 解析为物理 virtual key 的 8 个双修饰键冲突组合。当时直接复制安装 production DMG 的动态结论已由 ADR 0043 废弃，不能作为当前门禁；当前必须使用 `dmg-validation` 派生链重新取得动态证据。
- 2026-08-01：六个运行 profile、非生产专属 reset、build／package 纯产物边界、production DMG 静态验证与 `dmg-validation` 受控派生已成为当前代码契约。真实 App 诊断探针已覆盖同步失败／lock wait／修改拒绝／SIGKILL／重启／Help 菜单导出，并检查 4 MiB 持久化、8 MiB 导出与隐私哨兵；这证明采集链，不证明首次宿主机同步故障根因已经找到。
- 2026-07-06：设置页导出 / 导入已接入 `NoonmarkDataPackage` JSON 数据包；`swift test --filter NoonmarkStorageTests` 通过 5 个 Storage 测试。
- 2026-07-20：`NoonmarkAITests` 中的 provider 测试均为 mock/contract 测试，不需要真实 API key；真实 DeepSeek 验证入口为 `scripts/test-ai-provider-live`，缺少本地配置或显式环境凭证时 fail-closed。

## 后续缺口

- E2E 已覆盖主要页面、关键详情栏选中态、默认汇总侧栏、日历本地分析、正常模式持久化、快速新增、任务池排期、延续、复盘编辑与自动保存反馈、Day Todo 复盘区烛龙分析入口、右键菜单动作矩阵、有限撤销、父／子任务 completion control、任务池与 Day Todo 多行子任务的自适应行高及 frame 不相交、当天子任务完成撤回和难度修改、日期 strip 选中映射、方向键日期导航、变更、回池、废弃、事务性导入／导出、失败导入退出、原生 Help、辅助窗口最小尺寸、divider 恢复、严格 WindowServer 输入、全局 Quick Entry 改键和跨 App 前台恢复、烛龙导航 gating、烛龙草稿确认与 Provider 配置 round-trip；DMG 动态启动只由 `dmg-validation` 派生 App 覆盖。
- 当前私有 DMG 使用的 iCloud Drive 路径仍需由用户真实使用继续观察；已有 live 证据只覆盖隔离 E2E App 到 Apple CloudDocs 服务的上传与同仓库合并，不是两台物理设备证据。CloudKit Production entitlement／provisioning profile 与双设备验收不在本轮私有 DMG 范围内，未来若启用该能力必须另立门禁。
- DST 需要逐步引入虚拟 clock、故障注入和事件日志重放，目前第一版先覆盖 Core 状态机不变量。
- 原同步故障仍缺少真实现场证据；下一次异常必须由用户主动提交不超过 8 MiB 的诊断包、完整版本信息、诊断编号和发生时间，才能进入根因判断。公开分发不是当前缺口或本轮目标，不得以此扩大私有 DMG 的发行授权。

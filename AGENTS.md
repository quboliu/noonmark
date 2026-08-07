# AGENTS.md

本文件是晷迹（Noonmark）项目的 agent 协作入口。所有 agent 在本仓库工作前必须先阅读并遵守本文件；若本文件与更高优先级的系统、开发者或用户即时指令冲突，以更高优先级指令为准，并在回复中说明取舍。

## 项目身份

- 中文名：晷迹
- 英文名：Noonmark
- 项目类型：Todo 清单研发项目
- 默认文档语言：新加坡中文

## 当前仓库基线

- 初始化日期：2026-07-05
- 最新确认日期：2026-08-01
- 当前仓库已经初始化 Git，主分支为 `main`，并已关联 `origin/main`。
- 当前技术栈为 Swift Package Manager 项目，`Package.swift` 使用 `swift-tools-version: 6.0`，目标平台为 macOS 14。
- 当前源码模块：
  - `NoonmarkMacApp`：SwiftUI Mac App，可通过 SwiftPM executable target 构建出 `.app`。
  - `NoonmarkCore`：Day Todo、任务链、日轨迹、子任务、池化视图等核心领域引擎。
  - `NoonmarkAI`：当前烛龙使用的 provider、scope、prompt 与 local insight 基础设施。
  - `NoonmarkStorage`：SQLite schema 与领域持久化结构。
  - `NoonmarkSync`：本地目录、iCloud Drive 与 CloudKit 同步边界。
  - `NoonmarkDiagnostics`：有界强类型诊断、隐私过滤、跨重启关联与用户主动导出。
  - `NoonmarkMacRuntime`：签名运行身份、数据 scope 与 Mac runtime 协调器。
  - `NoonmarkMacUIContract`：Mac UI 设计契约的代码化约束。
- 飞光已成为当前能力：`NoonmarkCore` 承载一等领域实体飞光条目（内部兼容类型仍为 `IdeaEntry`）与飞光时间线投影，`NoonmarkStorage` 以兼容表名 `idea_entries` 持久化并纳入同步，Mac App 在侧边栏「札记」下提供「飞光」页面与全局飞光速记浮窗；飞光不依赖 AI Provider，领域词汇与产品规格见 `CONTEXT.md` 与 `docs/product/idea-capture-spec.md`。
- 当前测试模块：
  - `NoonmarkMacApp` 的真实 App E2E 脚本验证
  - `NoonmarkCoreTests`
  - `NoonmarkAITests`
  - `NoonmarkStorageTests`
  - `NoonmarkMacUIContractTests`
  - `NoonmarkSimulationTests`
- 当前文档已包含产品范围、功能规格、烛龙、ADR、研究资料和 Mac UI 设计契约；领域术语以 `CONTEXT.md` 为准。
- 当前已有可运行 Mac App target 和本地 DMG 打包脚本；尚未发现后端服务、容器部署配置或生产 deployed endpoint。验证应覆盖 Swift Package 的 build/test、隔离真实 `.app` E2E 截图、持久化探针、production DMG 静态门禁和受控派生的 `dmg-validation` 交互，不得在开发或测试中启动 production App。

## 当前开发入口

- 基础环境：macOS，完整 Xcode 或能提供 XCTest 的有效 Apple developer toolchain。
- 本机已确认 `xcode-select -p` 指向 `/Applications/Xcode-26.2.0.app/Contents/Developer`。
- 本机已确认 `xcodebuild -version` 输出 Xcode 26.2，`swift --version` 输出 Apple Swift 6.2.3；项目声明仍以 `Package.swift` 的 Swift tools 6.0 为准。
- 本机已确认 `xcrun --find xctest` 和 `xcrun --find simctl` 可用。
- 基础命令：
  - `make build`
  - `make test`
  - build／package 是纯产物操作，不 reset 也不启动 App。若必须绕过仓库入口直接运行 `swift test`，先执行 `scripts/reset-dev-data audit`；不得无参数调用 reset，也不得传入 `production`。
- 当前环境取证：
  - `swift build` 通过。
  - `make check` 通过，覆盖 `swift build`、UT、IT、ST、确定性仿真测试、SwiftLint 和 SwiftFormat lint。
  - `swift test` 通过；测试数量以当前运行报告为准，不在本文固化陈旧计数。
  - 真实 `.app` E2E 是当前 Mac UI 的运行基线；归档 HTML 原型不得作为默认视觉 oracle。
  - 本机已安装 `swiftlint`、`swiftformat`、`xcbeautify`、`xcodegen`、`mas`、`xcodes` 和 `aria2`。
- 项目级工具入口：
  - `make build`
  - `make build-app`
  - `make run-app`
  - `make run-demo-app`：重建并打开固定一年中段用户状态，作为功能迭代的默认交互验收入口。
  - `make test-demo-fixture`：以真实 `.app`、SQLite 和加密烛龙 sidecar 验证演示基线。
  - `make test-tencent-ime-input-contract`：验证 53 个输入面、性能阈值与测试资产没有漂移。
  - `make test-tencent-ime-input-matrix`：在一年负载下以真实腾讯拼音验证全部输入面。
  - `make test-tencent-ime-termination-persistence`：验证自动保存输入后立即退出、重启与故障重试。
  - `make test`
  - `make lint`
  - `make format-check`
  - `make check`
  - `scripts/test-e2e`
  - `scripts/test-visual-regression`：只接受显式传入、已经由用户确认的真实 App reference 与 actual；当前没有默认 reference，不进入 CI 或 release 门禁。
  - `scripts/test-ai-provider-live`：手动 live AI provider smoke；必须显式设置 `NOONMARK_AI_BASE_URL`、`NOONMARK_AI_MODEL` 和 `NOONMARK_AI_API_KEY`，不进入默认 `make check`。
  - `scripts/package-dmg release`
  - `scripts/test-dmg-install dist/Noonmark.dmg`

## 运行身份与开发数据 clean cut（强制）

- 晷迹目前只把 Apple Development 签名 DMG 私下提供给指定用户自行下载和安装，不进行公开分发。用户日常使用的 production 资料不是开发 fixture；任何 agent、开发命令、测试、E2E、Demo、Audit 或 DMG validation 都不得启动 production 身份，不得读取、定位、探测或 reset production 数据。
- 签入 bundle 的 exact identifier 是数据权限来源。六个固定 profile 必须保持完全隔离：

| Profile | Bundle identifier | Application Support 目录 | iCloud repository |
| --- | --- | --- | --- |
| `production` | `app.noonmark.mac` | `noonmark` | `Noonmark/SyncRepository` |
| `development` | `app.noonmark.mac.development` | `noonmark-development` | `Noonmark-Development/SyncRepository` |
| `e2e` | `app.noonmark.mac.e2e` | `noonmark-e2e` | `Noonmark-E2E/SyncRepository` |
| `demo` | `app.noonmark.mac.demo` | `noonmark-demo` | `Noonmark-Demo/SyncRepository` |
| `audit` | `app.noonmark.mac.audit` | `noonmark-audit` | `Noonmark-Audit/SyncRepository` |
| `dmg-validation` | `app.noonmark.mac.dmg-validation` | `noonmark-dmg-validation` | `Noonmark-DMGValidation/SyncRepository` |

- `scripts/reset-dev-data <profile>` 必须显式接收 `development`、`e2e`、`demo`、`audit` 或 `dmg-validation` 之一，只终止和删除所选 profile 拥有的 process、Application Support、iCloud 顶层根、UserDefaults、cache、saved state 与 sidecar key。缺参数、`production`、未知 profile、路径重叠、symlink 或进程无法确认终止时，必须在任何副作用前 fail-closed。
- build 与 package 是纯产物操作，不执行 reset、不启动 App，也不读取任何运行资料。会运行 App 的开发、E2E、Demo、Audit 与 DMG validation 入口必须先 reset 自己的固定非生产 profile；不得以启动参数、环境变量或临时目录把 production 身份改造成测试身份。
- 非生产数据采用 clean cut：不迁移、不备份、不复用旧 schema。E2E 可以在单次套件内保留本轮隔离数据库以验证重启与持久化；下一轮套件必须由相同 profile reset 后重建，不得回读上一轮 fixture。
- Keychain 中的 Provider API 凭证属于开发者凭证，不是测试历史，clean cut 不得删除；不得扫描整个 Keychain、iCloud Drive 或 `$HOME`，也不得删除用户通过 NSSavePanel 自选路径导出的数据包。

## 正式版诊断与 DMG 边界（强制）

- 应用管理的本机诊断记录以 allocated bytes 计量，硬上限为 4 MiB、最长保留 7 天；用户主动保存的单个 `.noonmarkdiagnostics` 导出包硬上限为 8 MiB。诊断资料不自动上传，导出和发送都必须由用户主动决定。
- 诊断 schema 不得记录任务正文、标签名、文件路径、同步端点字符串、iCloud／同步 payload、AI prompt／response、API Key、邮箱、IP、URL 或长 Base64；不得保存原始 `Error`、`localizedDescription`、`userInfo` 或自由文本业务日志。任何隐私哨兵命中均阻断发行。
- 真实 App 故障闭环必须在 `e2e` profile 走完“同步失败／停滞 → transport lock wait → 任务修改被拒绝 → 非正常终止 → 重启 → Help 菜单导出”，并对账 operation／incident、previous-session interruption、持久化失败、4 MiB／8 MiB 容量和隐私哨兵。该闭环证明证据可采集，不等于已经定位或修复最初的同步故障。
- production DMG 只做 checksum、只读挂载、strict code-sign、版本身份、Mach-O UUID、dSYM、binary SHA 与 source-linked SHA 静态门禁，并固定证明 `production_app_executed=false`。需要对该 package 做 WindowServer、SQLite、重启或 DiagnosticReports 动态验收时，只能运行从精确 production package 受控派生并重新签名的 `dmg-validation` App；诊断故障导出闭环则固定运行 `e2e` profile。
- 发行物为稳定 Apple Development 签名的 DMG，由用户自行下载、安装和启动。本地开发机是质量门禁：推送候选 tag 前必须在精确 candidate commit 跑通 `make check` 与真实 E2E，建立只存在于本机的 annotated tag，再跑通要求该 tag 的 `scripts/release-private-dmg`；本地 tag 只是验证身份，不是交付。发版唯一入口是 tag 触发的 `.github/workflows/release-publish.yml`：在 GitHub-hosted runner 复跑 `scripts/check`、打包签名并发布公开 GitHub Release，CI 产物为分发正本（操作见 `.github/RELEASING.md`）。产物只有 Apple Development 签名：不得宣称 Developer ID、notarization、staple 或 Gatekeeper 分发已经完成。

## Agent skills

### Issue tracker

Issues 和 PRD 追踪于 `quboliu/noonmark` 的 GitHub Issues；外部 PR 不作为 triage 入口。详见 `docs/agents/issue-tracker.md`。

### Triage labels

采用五个默认 triage labels：`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human` 和 `wontfix`。详见 `docs/agents/triage-labels.md`。

### Domain docs

采用 single-context 布局：根目录 `CONTEXT.md` 记录领域语言，`docs/adr/` 记录架构决策。详见 `docs/agents/domain.md`。

## 强制工作流

任何任务都必须按以下顺序推进：

1. 需求：明确用户目标、成功标准、约束、影响范围。
2. 现状：读取仓库现有代码、配置、文档和运行状态，确认事实。
3. 设计：给出可执行方案、边界、风险和验证方式。
4. 实施：只在前三步完成后改代码或配置。
5. 验证：用能覆盖用户真实路径的证据验证结果。
6. 闭环：说明改了什么、验证了什么、剩余风险和下一步。

未完成「需求 / 现状 / 设计」三步之前，不允许动代码。

任务分级：

- S 级：小而明确的改动。需要简短说明需求、现状、设计和验证。
- A 级：中等复杂度或跨模块改动。需要记录方案、影响范围、测试策略和回归点。
- P 级：高风险、生产相关、数据相关、安全相关或大范围重构。必须带风险评估、回滚方案、灰度策略和监控方案。

## 调试和修 Bug 纪律

- 收到问题或用户报告的 bug 后，第一时间真实复现。
- 必须结合源码文本、测试日志、运行日志、浏览器 DevTools/CDP、数据库状态、网络请求等证据定位根因。
- 禁止仅根据源码文本猜测假设后直接修改。
- 同一 bug 修两次仍未解决，必须立刻停手，重新审查默认假设，并把假设转成证据和事实后再动手。
- 日志要回答「哪条假设错了」，不是只回答「代码跑到哪」。
- 不得用「代码能跑」替代症状级验证；`build` 成功、`curl 200`、单测通过都不能单独证明用户问题已解决。
- 嫌疑范围要主动扩层。多次失败或用户反馈「还是不行」时，旧根因必须降级为待验证假设。
- 先取证再定因。遇到前端 `Failed to fetch`，必须先看 DevTools/CDP Network，不得只用 `curl`。
- 多轮失败时，应并行使用可用的 codex、agy、Explore 或等价 agent，同时自己取得症状层证据。
- 所有 bug 修复必须走根本解，不接受绕过、workaround、屏蔽规则、超时 hack 或降级糊弄。

### 故障案例库（强制）

- 故障案例固定归档于 `docs/engineering/failure-cases/`。每次故障修复必须新建或更新一个独立 Markdown 案例；没有同步更新案例库的修复不得宣称完成、不得进入发行。
- 案例必须如实记录：用户症状与影响范围、首次发现时间、引入故障的精确 commit、Git author／committer、实际修改者是否可由证据确认、错误改动及其破坏机制、复现与定位证据、排除过的假设、根因修复、回归测试、发行／回滚处置和可执行教训。
- 「谁改坏的」只能依据 Git、PR、agent session 或其他可核验证据归因；Git identity 与实际操作者必须分开记录。无法证明时明确写「未知」，不得猜测、模糊归因或替任何人隐藏责任事实。
- 案例状态只有在原始症状级复现由红转绿、相关受害路径回归通过、修复 commit 已确定后才能标记为「已修复」。若验证或修复 commit 尚未完成，必须保持「处理中」并在同一任务闭环前回填。
- 所有已经发生的故障和问题都必须转化为自动化门禁：修复前能够捕获原始故障并判红，修复后转绿；只写案例、注释或人工检查步骤不算门禁。每个「已修复」案例至少同时绑定一个进入 `make check` 的 fast gate 和一个真实用户路径的 symptom gate；涉及安装、签名、启动、退出或发行产物时还必须绑定 release gate。
- 门禁映射统一登记于 `docs/engineering/failure-cases/gates.tsv`，并由 `scripts/test-failure-case-gates` 在 `make check` 中 fail-closed 校验。门禁入口必须真实存在并被登记的聚合入口强制调用；环境特定的真实 App／WindowServer 门禁可以由专用 runner 执行，但不得 `skip`、伪造结果或用静态 contract 冒充症状级验证。
- 案例不得落盘用户任务正文、文件路径、账号、凭证、同步 payload 或诊断包中的隐私资料；证据只记录最小必要摘要、仓库内相对路径、命令和无敏感信息的结果。
- 新案例以 `docs/engineering/failure-cases/README.md` 的模板和命名规则为准。修复 commit 正文必须引用对应案例 ID。

## 改代码与重构

- 只走根本解。禁止小修小补继续堆高技术债。
- 需要重构时要大胆重构，但必须保护行为和用户价值。
- 零功能损失：重构只许升级不许降级，不许把「优雅降级」或「已知 gap」当借口。
- 只有新旧路径能力对等后才允许 cutover。strangler 旧路保留期是补齐对等能力的窗口，不是提前切换许可。
- 同一问题在多个调用点反复出现时，必须回到共享组件、共享模块或边界设计上做根本解，不得逐点打补丁。
- 渲染类组件的 DOM id 必须全局唯一。

## 验证

- 有 deployed endpoint 或可运行应用时，验证必须打真实 deployed endpoint 或真实应用入口，并走用户实际路径；禁止用模拟路径或手工补数据自欺。
- 当前仓库已有真实 Mac App target；涉及 Mac UI 时必须使用对应非生产 profile 的真实 `.app` E2E 截图、真实交互路径、console / 运行日志和持久化探针等证据补齐。开发／测试不得以“真实路径”为由启动或读取 production；production 运行只属于用户明确发起的日常使用，不是 agent 验证入口。归档 HTML 原型不得作为 ground truth，也不得靠抬高阈值吸收产品演进；只有用户确认过的真实 App 截图才能建立视觉 regression reference。若当前环境未提供 frontend-verify skill，必须明确说明，并用等价自动化证据补齐。
- 悬浮或 fixed UI 验收必须使用长滚动页面，短页面不能作为充分证据。
- 隔离前端栈中，`NEXT_PUBLIC_API_URL` 必须烤进镜像；`curl` 后端 200 不等于浏览器实际走了那个后端。
- 若存在容器化部署配置，每次改完代码后主动部署到隔离容器验证；若当前没有容器或部署入口，必须明确说明，并用当前最高强度的本地运行产物验证补齐。

## 交互式演示基线（强制）

- 功能快速迭代期间，每轮交互验收统一使用 `make run-demo-app`，不得再把新用户空库、一次性手工灌数或 `--ephemeral` 截图 fixture 当成用户体验入口。
- 演示基线必须由 `NoonmarkDemoSupport` 通过真实领域接口重放，并覆盖连续一年的中段用户状态。真实 `.app` 安装后必须再以 SQLite 与加密烛龙 sidecar 回读对账，失败时不得打开成“可体验”状态。
- 新增或改变用户可见功能时，必须同步评估演示覆盖契约。若该功能需要状态或历史才能体验，应在同一改动中更新一年用户故事、机器可检查报告和 `docs/engineering/interactive-demo-fixture.md` 覆盖表；普通用户能力必须纳入跨季度重复使用计数。
- 演示数据根固定隔离于仓库 `artifacts/interactive-demo/`，运行身份固定为 `demo`，每次启动整体重建；不得读取、写入或复用 production 数据库与 iCloud repository。演示 bundle 只复用内部 E2E 参数能力，不得放宽 production bundle 的参数边界。

## 测试三铁律

- 无 ground truth 时，正确性 = 自洽 + 跨引擎对账 + 重构行为保持。
- fail-closed：集成测试或 e2e 被启用但连不上依赖时，必须 `t.Fatal`，不得 `t.Skip`。
- 隔离栈用完即焚；使用 `CS_TEST_STACK=1` 护栏防止误连主栈。

## 多 Agent 并行编排

- Claude 是组长；可以派 codex，但必须 review，不盲信。
- codex 实施使用默认档：`fast + gpt-5.5 + xhigh`。
- 后台跑 codex 必须加 `< /dev/null`。
- 复杂任务采用 codex 双跑并由 Claude 选优；简单任务可以并行派 agy。
- worktree 里的 codex 绝不触碰 live docker stack，避免 wipe 主 DB 卷。

## 凭证与安全

- LLM 凭证只走 shell 替换，绝不 `echo`，绝不落盘明文。
- CORS 不使用 `credentials: include`，统一使用 Bearer token。
- `NoonmarkAITests` 默认只跑 mock/contract 测试，不需要真实 API key；任何真实 AI provider 验证必须走 `scripts/test-ai-provider-live` 或等价显式 live 入口，缺少 key 时必须失败，不得把 mock 结果描述为 live AI 测试。

## Git 与文档语言

- commit message 一律使用英文（含正文）；`type(scope):` 前缀保持英文小写。
- 技术名词不硬翻译。
- task-id 必须在三处一致：目录名、task-id、commit footer。
- worktree 建在仓库父目录。
- rebase 优先。
- 禁止裸 `force push`。
- 所有落盘文档使用新加坡中文。
- 例外：根目录 README 中英双语。`README.md` 是默认英文版，`README.zh-CN.md` 是中文版，两文件顶部互相放仓库内相对链接切换语言。README 截图分目录维护：中文在 `docs/assets/screenshots/readme/`，英文在 `docs/assets/screenshots/readme-en/`，统一由 `scripts/capture-readme-screenshots zh|en` 再生（英文逐张过无汉字门禁），不得手工拼装或跨语言复用。

## Docker 与部署

- BuildKit GC 不许关。
- 临时容器必须使用 `--rm`。
- 不许执行 `docker prune --volumes`，避免误删数据。
- `AutoMigrate` 卡死且无日志时，优先检查 `pg_stat_activity` 并杀僵尸事务，不要先 restart 容器。
- 当前仓库尚未发现 Dockerfile、compose 或部署脚本；在部署入口出现前，不得臆造容器验证结论。
- 一旦新增容器化运行面，每次改完相关代码都要主动部署到隔离容器验证。

## UI 基调

- 首页基调不准暗色；黑色只可用于组件级元素。
- 视觉基调对标 Vercel / Stripe 亮模式。
- 默认优先减少视觉单位。卡片、描边容器、色块、分组标题、徽章、图标、尾箭头、说明块和空状态都各自算一个视觉单位；同一信息层级不得靠重复叠加这些单位制造层次。
- 新增视觉单位必须承载独立信息或真实操作；若只用于装饰、重复提示层级或填补空白，必须删除，并优先使用字号、字重、对齐、留白或单条分隔线建立秩序。严禁用“分组标题 + 描边卡片 + 色块图标 + 徽章 + 尾箭头”的组合堆砌一个简单列表。
- UI 复刻必须先写像素级 prompt 再实现，不得放养 subagent。

## 结论来源

- 结论必须来自源码或运行产物，不轻信文档或 probe。
- 证据强度从低到高：静态读 < 结构推理 < 运行产物。
- 安全、并发、数据一致性相关结论必须达到运行产物证据档。

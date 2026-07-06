# AGENTS.md

本文件是晷迹（suntrace）项目的 agent 协作入口。所有 agent 在本仓库工作前必须先阅读并遵守本文件；若本文件与更高优先级的系统、开发者或用户即时指令冲突，以更高优先级指令为准，并在回复中说明取舍。

## 项目身份

- 中文名：晷迹
- 英文名：suntrace
- 项目类型：Todo 清单研发项目
- 默认文档语言：新加坡中文

## 当前仓库基线

- 初始化日期：2026-07-05
- 最新确认日期：2026-07-05
- 当前仓库已经初始化 Git，主分支为 `main`，并已关联 `origin/main`。
- 当前技术栈为 Swift Package Manager 项目，`Package.swift` 使用 `swift-tools-version: 6.0`，目标平台为 macOS 14。
- 当前源码模块：
  - `SuntraceMacApp`：SwiftUI Mac App，可通过 SwiftPM executable target 构建出 `.app`。
  - `SuntraceCore`：Day Todo、任务链、日轨迹、子任务、池化视图等核心领域引擎。
  - `SuntraceAI`：烛龙 AI provider、scope、prompt、local insight、建议草稿和授权模型。
  - `SuntraceStorage`：SQLite schema 与领域持久化结构。
  - `SuntraceMacUIContract`：Mac UI 设计契约的代码化约束。
- 当前测试模块：
  - `SuntraceMacApp` 的真实 App E2E 脚本验证
  - `SuntraceCoreTests`
  - `SuntraceAITests`
  - `SuntraceStorageTests`
  - `SuntraceMacUIContractTests`
  - `SuntraceSimulationTests`
- 当前文档已包含产品范围、功能规格、烛龙 AI、ADR、研究资料和 Mac UI 设计契约；领域术语以 `CONTEXT.md` 为准。
- 当前已有可运行 Mac App target 和本地 DMG 打包脚本；尚未发现后端服务、容器部署配置或生产 deployed endpoint。验证应覆盖 Swift Package 的 build/test、真实 `.app` E2E 截图、持久化探针和 DMG 安装启动。

## 当前开发入口

- 基础环境：macOS，完整 Xcode 或能提供 XCTest 的有效 Apple developer toolchain。
- 本机已确认 `xcode-select -p` 指向 `/Applications/Xcode-26.2.0.app/Contents/Developer`。
- 本机已确认 `xcodebuild -version` 输出 Xcode 26.2，`swift --version` 输出 Apple Swift 6.2.3；项目声明仍以 `Package.swift` 的 Swift tools 6.0 为准。
- 本机已确认 `xcrun --find xctest` 和 `xcrun --find simctl` 可用。
- 基础命令：
  - `swift build`
  - `swift test`
- 当前环境取证：
  - `swift build` 通过。
  - `swift test` 通过，当前 46 个 XCTest 全绿。
  - `scripts/test-visual-regression` 默认覆盖 14 个原型可比场景：7 个顶层页面、6 个详情态和 `day-review-saved`。
  - 本机已安装 `swiftlint`、`swiftformat`、`xcbeautify`、`xcodegen`、`mas`、`xcodes` 和 `aria2`。
- 项目级工具入口：
  - `make build`
  - `make test`
  - `make lint`
  - `make format-check`
  - `make check`
  - `scripts/test-e2e`
  - `scripts/test-visual-regression`
  - `scripts/test-ai-provider-live`：手动 live AI provider smoke；必须显式设置 `SUNTRACE_AI_BASE_URL`、`SUNTRACE_AI_MODEL` 和 `SUNTRACE_AI_API_KEY`，不进入默认 `make check`。
  - `scripts/package-dmg release`
  - `scripts/test-dmg-install dist/SuntraceMacApp.dmg`

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

## 改代码与重构

- 只走根本解。禁止小修小补继续堆高技术债。
- 需要重构时要大胆重构，但必须保护行为和用户价值。
- 零功能损失：重构只许升级不许降级，不许把「优雅降级」或「已知 gap」当借口。
- 只有新旧路径能力对等后才允许 cutover。strangler 旧路保留期是补齐对等能力的窗口，不是提前切换许可。
- 同一问题在多个调用点反复出现时，必须回到共享组件、共享模块或边界设计上做根本解，不得逐点打补丁。
- 渲染类组件的 DOM id 必须全局唯一。

## 验证

- 有 deployed endpoint 或可运行应用时，验证必须打真实 deployed endpoint 或真实应用入口，并走用户实际路径；禁止用模拟路径或手工补数据自欺。
- 当前仓库已有真实 Mac App target；涉及 Mac UI 时必须使用真实 `.app` E2E 截图、`scripts/test-visual-regression` 原型量化对比、console / 运行日志和持久化探针等证据补齐。若当前环境未提供 frontend-verify skill，必须明确说明，并用等价自动化证据补齐。
- 悬浮或 fixed UI 验收必须使用长滚动页面，短页面不能作为充分证据。
- 隔离前端栈中，`NEXT_PUBLIC_API_URL` 必须烤进镜像；`curl` 后端 200 不等于浏览器实际走了那个后端。
- 若存在容器化部署配置，每次改完代码后主动部署到隔离容器验证；若当前没有容器或部署入口，必须明确说明，并用当前最高强度的本地运行产物验证补齐。

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
- `SuntraceAITests` 默认只跑 mock/contract 测试，不需要真实 API key；任何真实 AI provider 验证必须走 `scripts/test-ai-provider-live` 或等价显式 live 入口，缺少 key 时必须失败，不得把 mock 结果描述为 live AI 测试。

## Git 与文档语言

- commit 正文一律使用中文；`type(scope):` 前缀保留英文。
- 技术名词不硬翻译。
- task-id 必须在三处一致：目录名、task-id、commit footer。
- worktree 建在仓库父目录。
- rebase 优先。
- 禁止裸 `force push`。
- 所有落盘文档使用新加坡中文。

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
- UI 复刻必须先写像素级 prompt 再实现，不得放养 subagent。

## 结论来源

- 结论必须来自源码或运行产物，不轻信文档或 probe。
- 证据强度从低到高：静态读 < 结构推理 < 运行产物。
- 安全、并发、数据一致性相关结论必须达到运行产物证据档。

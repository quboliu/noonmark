# FAIL-2026-08-19-01：飞光 Markdown 普通换行在提交后被折叠

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-19T09:00:46Z
- 影响版本／构建：0.3.0 build 32；source commit `1eb9837c5f74728d04be61af559b4a62e6b12593`
- 引入提交：`18cc1a5c3da426b60a8f7ce208535c8077ca8b26`（`feat(app): integrate task classification sync and the Zhulong workbench`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；仓库只能证明 Git identity，不能证明实际操作者
- 修复提交：`7fb9024a96dd3a65c8e4ff980a31e4d7eeb9b85c`（`fix(markdown): preserve authored line breaks`）

## 用户症状与影响

用户在飞光 Composer 中按普通回车输入多行正文并提交后，已提交卡片把相邻正文行挤成同一行。标题、清单、链接等 Markdown 语义仍可渲染，因此不是整套 Markdown 失效，而是作者输入的普通换行被显示层静默改写。已确认症状发生于飞光卡片；同一 inline renderer 也供 Sticky Note、任务详情与烛龙内容使用，因此必须在共享边界修复。

## 时间线

- 2026-07-12T20:55:59-04:00：引入提交新增共享 `MarkdownInlineText`，使用 Foundation `.full` Markdown parsing。
- 2026-08-19T09:00:46Z：用户报告飞光提交后格式挤在一起。
- 2026-08-19：当前 source `.app` 真实物理输入与提交复现；SQLite 保留换行，但卡片 paragraph 高度只对应单行。
- 2026-08-19：先加入单元 tracer，以旧 `.full` 路径得到 `第一行 第二行 链接`，稳定判红。
- 2026-08-19：共享 renderer 改用 `.inlineOnlyPreservingWhitespace` 后，单元 tracer 与真实飞光症状路径转绿；完整验证与修复 commit 尚待闭环。
- 2026-08-19T09:25:20Z：真实 Demo `.app` fixture 与完整 `make check` 转绿；修复 commit 尚待闭环。
- 2026-08-19T05:40:33-04:00：根因修复以 `7fb9024a96dd3a65c8e4ff980a31e4d7eeb9b85c` 提交，案例完成闭环。

## 复现与证据

- `artifacts/flylight-markdown-red.agPmb8/exercise-result.txt` 记录当前 source App 的精确失败：`Flylight card did not preserve authored Markdown line breaks`。
- 同一 red run 的隔离 SQLite `idea_entries.body` 以真实换行保存标题、清单与两条普通正文，证明 Composer、领域实体与持久化没有丢失换行。
- `MacUIMarkdownInlineRendererTests.testPreservesAuthoredLineBreaksWhileRenderingInlineMarkdown` 在修复前实际得到 `第一行 第二行 链接`，同时用粗体与链接语义约束不能以纯文本替代 Markdown。
- `artifacts/flylight-markdown-green.1n8vMU/exercise-result.txt` 为 `ok`；`ideas-composer-saved.png` 显示两条普通正文保持独立行，且同一真实 App 流程继续通过编辑、过滤、来源恢复与 Sticky Note 路径。
- 所有运行只使用固定 `audit`／`e2e` 非 production profile 与仓库内隔离资料；没有启动、读取、定位或 reset production，也没有接触 iCloud。

## 排除的假设

- 不是飞光完全没有 Markdown renderer：真实卡片的 heading、list 与链接均已正确投影。
- 不是输入或 parser 删除换行：产品输入契约允许 Enter 加行，red run 的 SQLite 正文仍含精确 `\n`。
- 不是 SQLite 或同步 schema 压平正文：隔离数据库的 `body` 原样保留多行。
- 不是卡片布局统一限制行数：失败发生在 paragraph 的 `AttributedString` 字符已经从换行变为空格之后。
- 不是需要手工把 `\n` 改成 Markdown hard break：这会篡改作者输入语义，并在每个调用点制造 workaround。

## 根因与破坏机制

block parser 会把相邻普通正文行组合成同一 paragraph，并用 `\n` 保留作者分行。共享 `MarkdownInlineText` 随后以 `AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)` 再解释该 paragraph；Foundation 的 full Markdown 语义把 soft line break 规范化为空格。换行因此在最后的共享 inline projection 边界丢失，而不是在输入、领域或存储边界丢失。

## 根因修复

- 把 inline Markdown projection 提取到 `NoonmarkMacUIContract.MacUIMarkdownInlineRenderer`，让 App 与 fast test 共用同一实现。
- 使用 Foundation 已有的 `.inlineOnlyPreservingWhitespace`；保留作者换行，同时继续解释粗体、链接等 inline Markdown。
- 飞光 E2E 草稿加入同一 paragraph 内的两条普通正文，并以已提交 paragraph 的真实几何高度证明分行，而不是只检查 block 类型或数据库文本。
- 年度 Demo 的一条非置顶发布飞光保留作者普通换行；覆盖报告 fail-closed 要求至少一条活跃多行飞光。置顶飞光继续保持单行，保护现有可视区契约。

## 验证结果

- 聚焦 renderer 单元测试：1 项、0 失败；字符结果保留 `\n`，粗体与链接 run 同时存在。
- 英文 Demo 故事：5 项、0 失败；中英文覆盖报告相同，非置顶飞光含换行，三条置顶飞光保持单行。
- 飞光 Demo 时间线：1 项、0 失败；`multilineIdeaCount == 1`，既有八条时间线、Sticky Note 与墓碑计数不变。
- 真实 current-source `e2e` App 飞光物理输入、提交及完整 Idea Capture 自动化：`artifacts/flylight-markdown-green.1n8vMU/exercise-result.txt` 为 `ok`。
- `make test-demo-fixture` 通过；真实 Demo `.app` 完成一年 fixture 安装、SQLite／加密 sidecar 回读，页面切换总耗时 1311 ms，低于 6000 ms 门限。
- 完整 `make check` 以 exit 0 结束：1594 项 system tests 中 2 项显式 live iCloud 测试按设计未启用，其余 0 失败；Demo 14 项、failure-case 108 个案例、SwiftLint 与 SwiftFormat 门禁均完成。SwiftLint 只报告仓库既有非阻断 warning，本次新增 import 排序 warning 已在随后聚焦 lint 中消除。
- 根因修复 commit 已精确回填，原始症状由 red 转 green，相关受害路径与永久门禁均通过；案例状态为「已修复」。

## 永久门禁

- fast：`scripts/test-unit` 执行 `NoonmarkMacUIContractTests`，直接验证普通换行、粗体与链接；由 `scripts/check` 强制调用。
- symptom：`scripts/test-e2e` 的 Idea Capture 真实 App 路径物理输入并提交多行 Markdown，以已提交 paragraph 几何捕获原始挤行症状；由 `scripts/test-all` 强制调用。

## 发行与回滚

风险等级为 A：共享 Markdown inline renderer 会影响飞光、Sticky Note、任务详情与烛龙文本。回归重点是 inline 格式仍可解析、block 分层不变、既有卡片高度与置顶可视区不漂移。未通过 fast、真实飞光 symptom、Demo fixture 与完整 `make check` 前不进入发行。若验证发现共享消费者回归，只回滚本次 renderer、E2E 与 fixture 修复提交；不迁移、不重写任何用户正文，因为持久化数据从未损坏。

## 教训与永久约束

Markdown 解析模式是用户内容语义的一部分，不能只以 heading／list 是否出现判断渲染正确。凡是编辑器承诺普通回车可表达分行，门禁必须同时证明领域／存储保留字符与最终 UI 保留可见行；共享渲染问题必须在共享边界修复，并保留 inline 语义的反向断言。

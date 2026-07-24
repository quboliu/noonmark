# 持久化任务池分析并支持停止 Provider 生成

**Status**: Accepted  
**Date**: 2026-07-24  
**Risk**: A 级——跨 Provider 运行、加密会话账本、Mac UI、任务池投影与真实 App E2E

## Context

ADR 0031 先把本地统计和 Provider 分析分开，但分析区只有入口，也没有可验证的报告协议。烛龙 Composer 同时存在发送与会话暂停概念；Provider 运行时没有真实停止能力，标题栏在详情栏展开后也容易被左右文字控制挤压。

任务池分析若只显示自然语言，会缺少来源、时效和失败边界；若只显示数量，则会再次把本地统计冒充成 LLM 判断。停止若只隐藏流式文字而不取消运行，会继续计费并产生晚到响应；若把取消当失败，则会把用户主动决定误报成故障。

## Decision

### Provider 停止

- App 持有当前 Provider `Task` 的唯一取消句柄。Provider 运行期间，Composer 的单一圆形主动作由发送切换为停止，不并列显示第二个动作，也不显示键盘提示。
- Streaming Adapter 累积已经真实收到的可见正文。用户停止后取消运行，保存 `.stopped` 发送结果；已有部分正文作为普通烛龙消息进入加密 sidecar，没有片段时不制造空消息。
- 停止是正常终态，不进入失败投影；会话恢复为可继续发送。结构化 JSON 未完整通过校验前不得形成可执行产物。
- 会话暂停／继续保留原有工作空间语义，收进“视图”菜单，不与 Provider stop 或 Composer 主动作混用。

### 响应式会话头部

- 头部固定 56pt，以主内容区为轴居中“烛龙”，不再显示诗句或会话副标题。
- 左侧只有全部会话，右侧只有视图和必要的详情栏展开动作；可用宽度低于 720pt 时，文字控制收成 32×32pt 图标。
- 标题中心不得因详情栏展开／收起而移动，左右控制与标题之间至少保留 8pt。

### 任务池分析报告

- Provider 就绪时，任务池右栏投影 `未生成／生成中／报告／过期／失败` 状态；Provider 未就绪时整个分析区隐藏，本地统计始终独立可用。
- `taskPoolAnalysis` 产物最多包含三项发现。每项必须包含语义结论、至少一个来自本次发送范围的 `taskID + title` 证据、置信度、不确定性和可选择建议；原题为空时 typed evidence 明确保存 `title: null`，只由界面按当前语言显示“无标题”／“No title”。允许零项发现表达证据不足。
- Provider payload 独立保存 typed evidence index 与 response contract；grounding 只按 index 中的 `taskID + title` 精确配对，不从可被任务正文换行混淆的 prompt 文本反推授权证据。
- Adapter 修复 prompt 与 Orchestrator 持久化边界共同执行 response contract。必须且只能返回一份 grounded `taskPoolAnalysis`；缺少产物、混入可写产物、schema 无效或范围外证据都在保存成功结果前 fail-closed 为失败。报告、发现和证据的 Codable 解码必须重新执行领域构造校验，避免加密 sidecar 绕过 canonical schema。
- 任务池报告是只读成功结果：保存正文、报告和 `analysisReportReady` 事件后回到可继续对话状态，不建立 draft version、Todo diff 或复盘草稿。
- 报告保存发送时任务池内容的 SHA-256 context version。当前任务池变化后，旧报告仍可查看，但必须明确标为过期；重新分析建立新会话和新发送记录。
- 报告使用文本、留白和分隔线建立层级，不为每项发现再套卡片；纯数量继续只属于本地统计区。

## Consequences

- 用户可以真正停止 Provider，重启后仍能看到停止前已经落屏的部分内容和停止记录。
- 任务池分析可审查、可追溯、可判断时效，不会把固定规则或旧结果伪装为当前 LLM 判断。
- `ZhulongProviderSendResult`、typed response contract 和 sidecar canonical schema 新增停止／报告终态；加密会话 envelope 升至 `formatVersion = 3`。项目尚未发布，继续执行 clean cut，不提供旧 sidecar 迁移或兼容分支。
- 首页移除重复的自由对话范围小字；精确范围与接收方仍在设置、工作流说明和真正需要决定的授权面披露。

## Rejected alternatives

- 只停止 UI 动画：Provider 仍在后台运行，不能证明费用和晚到响应已停止。
- 把取消映射为失败：会污染故障历史，也无法表达用户主动保留部分内容。
- 在发送旁边新增独立停止按钮：运行中会形成两个竞争主动作。
- 用自然语言报告直接渲染右栏：无法验证证据、结构或时效。
- 让 Provider 返回本地统计：浪费远程调用并模糊 ADR 0031 的事实边界。

## Verification

- Orchestrator 测试取消真实 Streaming 任务，证明部分内容、`.stopped` 发送记录、会话可继续状态和 sidecar 回读一致。
- Parser、Adapter、Orchestrator、Runtime 和 UI Contract 测试固定零至三项、typed grounding、prompt 换行注入不扩权、只读报告状态、过期标记和单一发送／停止动作。
- 真实 App 对话 E2E 通过 WindowServer 点击停止，验证停止按钮替换发送、部分正文持久化、后续继续对话和重启回读。
- 真实 App 几何 E2E 分别在详情栏收起和展开时验证标题居中且不与左右控制重叠。
- 十天演示基线保存一份 grounded 任务池分析报告；Provider 就绪时真实右栏显示报告，未就绪时分析区完整隐藏。

## Rollback

项目没有 deployed endpoint、容器或生产灰度面。回滚以本 ADR 对应原子 commit 为边界，使用 `git revert` 恢复代码；下一次构建由 `scripts/reset-dev-data` 删除当前开发 SQLite 与 sidecar 后重建 fixture。不得保留只隐藏 UI、但继续写入新停止／报告 schema 的半回滚状态。

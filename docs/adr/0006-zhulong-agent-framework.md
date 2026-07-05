# 烛龙 AI 采用证据优先的建议草稿框架

**Status**: Accepted

晷迹第一版的烛龙 AI 不采用自主工具调用 agent loop，而采用 **本地证据分析 + provider 中立模型调用 + AI 建议草稿 + 用户确认落库** 的框架。

**Context**

已调研 Codex、Hermes、OpenCode、OpenClaw 和 Claude Code 类框架。它们适合编码 agent 的原因是能在一个 turn loop 中构造上下文、调用模型、执行工具和记录事件。但晷迹的核心约束是日轨迹不可删除、历史事实不可改写、AI 不得越过用户确认直接写入任务状态。因此，完整自主工具循环会放大误写历史的风险。

**Decision**

- 新增 `SuntraceAI` target，依赖 `SuntraceCore`。
- `SuntraceCore` 不依赖 `SuntraceAI`，普通清单能力不受 provider、网络或 AI 故障影响。
- provider adapter 只负责模型请求和响应，不持有任务状态，不调用领域写入接口。
- `LocalInsightAnalyzer` 先从本地任务轨迹生成证据报告，再由模型基于证据做解释和建议。
- `AIPromptBuilder` 负责把授权范围、领域规则和证据报告组装为请求，并避免向远程 provider 发送内部 ID。
- `ZhulongAgent` 只输出 `AISuggestionDraft`。
- `AISuggestionDraft` 中的操作必须经用户确认后，才可转换为普通领域接口调用。

**Consequences**

- 烛龙的第一版能力更像“复盘与排期建议引擎”，不是自动驾驶清单。
- 习惯画像必须绑定时间窗口和证据，不作为永久身份标签。
- 后续可以增加 OpenAI-compatible、本地模型、自定义 HTTP provider adapter，但不能让 adapter 直接写任务事实。
- 后续如果增加“应用建议草稿”服务，也只能调用 `SuntraceCore` 现有领域接口，不能绕过日轨迹状态机。
- AI 建议草稿可以持久化和清理；它不是不可删除历史事实。

**Alternatives Considered**

采用完整工具调用 loop：能复用编码 agent 模式，但风险是模型直接调写入工具后绕过“用户确认”和“历史不可改写”原则。

把 AI 写进 `SuntraceCore`：集成简单，但会让核心清单功能对 AI provider 产生结构性耦合，违背旁路 Agent 决策。

只做普通聊天页：实现最轻，但无法稳定输出可预览、可确认、可回滚的结构化建议。

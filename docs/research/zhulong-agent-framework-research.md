# 烛龙 Agent 框架调研

> 历史研究记录（2026-07-05）：本文保留早期框架取舍的来源证据，已被 ADR-0015 的 clean-sheet cutover 与当前烛龙会话模型取代。文中的 `AIProviderRegistry`、`ZhulongAgent`、`AISuggestionDraft` 和“应用草稿”不是当前接口、测试目标或兼容路径。

本文记录对 `/home/muxunting/WorkSpace/Aranya/CodeStudy/deep-into-agent/exemplar_project/` 下多个 agent 框架的源码调研，并给出晷迹第一版烛龙的框架取舍。

## 调研对象

- `codex-rust-v0.130.0`：重点看 `codex-rs/core/src/session/turn.rs`、`tools/registry.rs`、`agent/role.rs`。
- `hermes-agent-v0.12.0`：重点看 `agent/codex_responses_adapter.py`、`agent/prompt_builder.py`、`agent/insights.py`。
- `opencode-v1.14.35`：重点看 `packages/opencode/src/agent/agent.ts`、`config/agent.ts`、`config/provider.ts`。
- `openclaw-v2026.5.4`：重点看 `src/acp/runtime/registry.ts`、`agents/auth-profiles/types.ts`、`agent-runtime-policy.ts`。
- `claude-code-source`：重点看学习文档中的架构拆解，确认其核心也是上下文构造、模型调用、工具执行和权限控制的循环。

## 可借鉴点

Codex 的价值在于核心循环清晰：上下文构造、工具注册、模型请求、工具调用分发、事件记录集中在一条 turn loop 里。工具注册还显式标注是否 mutating、是否可并行、前后置 hook，这对权限边界很重要。

Hermes 的 provider adapter 值得采用：适配器只做格式转换和响应规范化，不承载业务状态。它的 prompt builder 还会把身份、平台、技能和上下文分层，并做 prompt injection 风险清理。`insights.py` 的经验是：先用本地结构化数据算出事实，再让模型解释这些事实。

OpenCode 把 agent 定义成配置层：name、mode、permission、model、prompt、temperature 等。这个模型说明“人格”和“执行权限”应当分离，烛龙不需要把每个能力做成独立运行时。

OpenClaw 的 runtime registry 和 auth profile 值得保留：provider/runtime 要可注册、可健康检查，凭证引用和 provider 配置要分离，不能把 API key 放进普通配置或日志。

## 不采用的部分

第一版不采用自由工具调用循环。烛龙面向的是用户个人任务轨迹，不是代码修改 agent；如果让模型直接调用写入工具，很容易绕过“日轨迹不可删除、历史任务只能延续复制或废弃、AI 建议必须用户确认”的产品底线。

第一版不做隐藏长期记忆系统。习惯画像只来自用户授权时间窗口内的本地证据报告，不能沉淀成不可见的永久人格标签。

第一版不把 provider 绑定到某一家模型。provider adapter 必须中立，先留 OpenAI-compatible、本地模型、自定义 HTTP 三类配置，实际网络 adapter 后续再实现。

## 敲定框架

烛龙 第一版采用独立 Swift target：`NoonmarkAI`。它依赖 `NoonmarkCore`，但 `NoonmarkCore` 不依赖 `NoonmarkAI`。

框架分层：

- `AIProviderRegistry`：注册和选择 provider，拒绝 disabled provider，未来承载健康检查。
- `AIProvider`：provider adapter 协议。adapter 只处理模型请求，不执行业务写入。
- `AIScopeSnapshot`：用户授权的数据范围快照，可来自 Day Todo、任务池、未完成池、已完成池和 label。
- `LocalInsightAnalyzer`：先从本地轨迹计算证据，例如延续次数、完成率、未完成任务链数量、部分完成。
- `AIPromptBuilder`：把领域规则、本地证据和授权快照组装成请求；发送给远程 provider 的文本不得包含内部 ID。
- `ZhulongAgent`：协调本地证据、prompt 和 provider 响应，产出 `AI 建议草稿`。
- `AISuggestionDraft`：只保存建议、证据、置信度和待确认操作，不直接改写任务事实。

建议草稿中的操作只表达普通领域动作，例如创建任务池任务、添加子任务、排期、延续复制、废弃、更新复盘、分配 label。后续 UI 必须逐条预览，用户确认后才调用 `NoonmarkCore` 的普通接口。

## 后续接入点

- 增加真实 OpenAI-compatible provider adapter，并把 API key 读取限定在 Keychain。
- 增加建议草稿持久化表，但草稿不是历史事实，可以清理。
- 增加“应用草稿”服务，把用户确认的建议转换成 `NoonmarkCore` 操作。
- 增加 provider 健康检查 UI 和本地诊断指标。
- 标签分类建议必须接入普通分类 Module，并在用户确认后保留来源与决定引用。

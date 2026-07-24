# 分离页面本地统计与 Provider 分析

**Status**: Accepted
**Date**: 2026-07-24
**Risk**: A 级——跨 Runtime、Mac UI、Provider readiness 与真实 App 演示契约

## Context

任务池右栏原先由一个 `SidebarAnalysisModel` 同时产生数量指标、本地信号、确定性建议、烛龙提示和会话入口。这个 Interface 把领域事实、产品解释与 Provider 能力混成同一层，导致三个问题：

- “未分组”错误复用了“没有分组且没有标签”的自动分类口径；已有标签但没有主要分组的任务没有被统计。
- 没有 Provider 时仍显示烛龙提示与本地算法建议，容易把固定规则理解成 LLM 分析。
- Provider 只启用页面开关、但没有保存可执行凭证时，右栏仍可能显示分析入口。

烛龙会话头部也把会话导航、阅读投影和会话暂停放在同一行。暂停是会话运行控制，领域层只允许在没有 Provider 请求运行时暂停；它不属于页面导航，也不能伪装成中断正在进行的 Provider 请求。

## Decision

引入两个边界清楚的深 Module：

1. `TaskPoolStatisticsSnapshot` 只接收已经投影好的任务池事实，输出总任务、池内分组、池内标签、未分组、有说明、已拆分和重新回池数量。它不依赖 Provider、页面开关或 LLM 会话。
2. `TaskPoolAnalysisAvailability` 只表达 Provider 分析区是否可见。Mac App Adapter 必须同时确认当前草稿配置有效、有已保存凭证，并且持久化 execution revision 可以解析为 ready，才把它映射为 `.ready`。

任务池右栏只保留一个统计容器。原来的本地信号、确定性建议与未接入提示卡不再进入任务池首页。分析区在 Provider 未就绪时完整省略；就绪时首版只显示明确的“分析任务池／继续任务池分析”入口，待分析产物协议定稿后再承载有证据、可审查的判断。纯统计不得进入分析区，固定文案也不得冒充分析结果。

烛龙会话顶部只保留“全部会话”和“视图”两个持久动作，标题与诗句继续以主内容区为轴居中。暂停／继续移动到 Composer 右侧：活动且没有 Provider 请求时显示暂停，已暂停时在同一位置显示继续，Provider 请求运行时不显示伪暂停。

## Consequences

- 任务池统计在无网络、无 Provider 和烛龙页面关闭时仍完整可用。
- 标签和主要分组使用独立统计口径；“未分组”只由 `categoryID == nil` 决定。
- 页面分析的可见性与真实执行 readiness 对齐，不再被功能页面开关替代。
- 首版分析区是 Provider 能力入口，不声称已经存在持久化分析报告；后续报告状态可在现有 Seam 后增加，不需要改统计 Module。
- 暂停仍保持原有会话语义；这次只调整操作位置与层级，不新增取消 Provider 请求的能力。

## Rejected alternatives

- 继续扩充 `SidebarAnalysisModel`：调用方便，但会让统计、规则建议和 Provider 结果继续共享同一 Interface。
- 无 Provider 时显示“开启烛龙”提示卡：它会在用户明确要求分析区缺席时制造额外视觉单位。
- 用本地规则生成任务池健康分：缺少可解释 ground truth，也混淆统计和情境判断。
- 把暂停改成 Provider stop：当前领域和 Provider Adapter 没有可证明的取消协议，改变标签而不补齐能力会制造伪控制。

## Verification

- Runtime 测试证明分组与标签独立去重，已有标签但没有分组的任务仍计入未分组。
- UI Contract 测试固定一个统计容器、两列次级统计、统计不依赖 Provider、无 Provider 不显示分析，以及会话运行控制位于 Composer。
- 真实 `.app` 十天演示同时验证无 Provider 时分析区缺席、统计区仍存在；有 Provider 的交互入口验证分析区出现。
- 真实 SwiftUI 视图树验证烛龙顶部只有会话／视图导航，Composer 内存在暂停控制，并继续验证历史会话没有多余阅读范围确认卡。

## Rollback

回滚以本 ADR 对应 commit 的父提交为边界。该改动只调整展示投影、Provider readiness Adapter 与 UI 层级，不修改任务事实、SQLite schema、烛龙 sidecar 或 Provider 凭证；回滚不需要数据迁移。晷迹仍在未发布 clean cut 阶段，下一次构建按 `scripts/reset-dev-data` 重建开发数据。

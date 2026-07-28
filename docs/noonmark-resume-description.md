# 本地优先 AI Todo macOS 应用

**技术栈:** Swift / SwiftUI / AppKit / SQLite / iCloud Drive / CloudKit / Claude / Codex / OpenAI-compatible API *2026.07 - 至今*

1. 工程化 Vibe Coding 体系：通过 `CONTEXT.md` 统一领域语言，以 Spec 和 ADR 固化需求边界与架构决策，多 Agent 协作设计、编码和 Review；1200+ 自动化用例、真实 App E2E、SQLite 回读和 DMG 安装测试。
2. 每日任务轨迹引擎：以 TaskChain、TaskDefinition 和 DayTrace 分离当前计划与不可改写历史，覆盖 Day Todo、任务池、未来计划、已完成池、未完成池、重复任务和每日复盘，完整保留延期、延续、回池及变更等跨日轨迹。
3. Local-first 数据与 iCloud 同步：核心数据存储于本机 SQLite，离线状态下完整可用；通过 iCloud Drive 按领域记录同步，以因果依赖和冲突合并处理多设备离线修改。
4. 内置 Todo Agent：基于任务轨迹提供任务拆解、排期建议、每日复盘和自动分类；任务方案以可编辑预览呈现在对话中，用户确认后才写入清单或执行任务变更。

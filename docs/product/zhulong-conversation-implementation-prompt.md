# 烛龙默认对话 renderer 像素级实现约束

- 日期：2026-07-20
- 适用：`ZhulongSessionStreamPage` 的 `conversation` 投影；不适用于卷宗、章节、双轨三个可选旧投影。

## 实现提示词

在 macOS 明亮模式中实现一个类似 Claude、Codex、ChatGPT 的普通工作对话页：主内容最大可读宽度 760pt，单列左对齐，页面水平 padding 使用既有 `NoonmarkVisualMetrics.pageHorizontalPadding`。消息不置于 dashboard、卷宗、章节、双轨或大描边卡片中。

烛龙消息左侧使用 22×22pt `sparkles` 身份标记，标题 13pt semibold，正文 12pt、3pt 行距；整条消息上下 padding 11pt，不要外围背景或描边。用户消息右对齐，最多占可读列宽减 84pt，使用 13pt／12pt 文字、水平 13pt、垂直 10pt、14pt 圆角、`Theme.controlFill` 的轻量气泡。系统行使用单行图标、11.5pt 标题、11pt 辅助文字和 8pt 垂直留白；不使用卡片。

权限、计划、Todo、执行状态、错误和结果均作为消息流末端的动作记录：与上一条消息间隔 12pt，不能作为流外面板。只有用户当前必须确认或编辑时，允许其内部表单使用 8pt 圆角、13pt 内边距和一条 3pt 强调边；成功后的低价值细节默认保持摘要。

Composer 固定在窗口底部，上方只有 1pt `Theme.line` 分隔；内层使用 8pt 圆角、12pt 水平 padding、最小高 54pt。默认对话在 Composer 右下显示 10.5pt 的紧凑“视图 · 对话”菜单；PageHeader 保留同一菜单作为远端可发现入口。切换到旧投影可以恢复各自容器，但旧容器不得被 conversation 使用。

右侧检视仅由来源消息的动作打开；关闭后不保留空白卡片。整体以文字层级、对齐和留白建立秩序，避免重复徽章、描边和色块。

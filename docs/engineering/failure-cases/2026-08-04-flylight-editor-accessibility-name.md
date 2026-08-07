# FAIL-2026-08-04-17：飞光编辑器用 placeholder 冒充 accessibility 名称

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 10:03 -04:00
- 影响版本／构建：`3ab199ec94e5de9e2bf6b0143a11f173e2fa63c6` 至修复前工作树
- 引入提交：`3ab199ec94e5de9e2bf6b0143a11f173e2fa63c6` `feat(notes): 建立飞光与 Sticky Note 多视图`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话、Git blame 与正式 review 确认
- 修复提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec`

## 用户症状与影响

VoiceOver 把整段「记录一条飞光，支持 Markdown……」placeholder 当成编辑器唯一名称。开始输入后 placeholder 的提示语仍承担控件身份，名称冗长、不稳定，也无法形成清晰的「飞光正文」label 与实际正文 value 关系。

## 时间线

- 共享 MarkdownEditor 初始实现为方便，直接把 placeholder 同时传给 AppKit accessibility label。
- 飞光加入较长的 Markdown、分类、快捷键与草稿提示后，该做法变成明显的可访问性缺陷。
- 正式 Spec review 对照 K3 accessibility 建议指出必须把稳定名称与 hint 分离。
- 根修后 placeholder 只负责空态提示，原生 NSTextView 始终报告稳定名称与当前完整 value。

## 复现与证据

旧实现读取 `ideas.composer.input` 的原生 `accessibilityLabel()`，结果等于随语言和功能增长的 placeholder。修复后真实 App 在空态与脏草稿收起态均对账 label 为本地化「飞光正文」，value 分别为空字符串与草稿原文。

## 排除的假设

- 不是缺少 accessibility identifier：identifier 已稳定存在，但 identifier 不是用户可听见的控件名称。
- 不是 NSTextView 无法提供 value：原生控件一直能返回正文 value，缺陷只在 label 绑定错误。
- 不能缩短 placeholder 代替根修：placeholder 与控件身份语义不同，未来文案变化仍会复发。

## 根因与破坏机制

共享 MarkdownEditor 没有独立 accessibility label 参数，调用者只能被迫让 placeholder 同时承担提示与名称。飞光 composer 因此无法表达稳定控件语义。

## 根因修复

为共享 MarkdownEditor 增加独立、可选的 accessibility label；现有调用者默认兼容 placeholder，FlylightComposerSurface 显式传入本地化「飞光正文」。AppKit scroll view 与 NSTextView 共用稳定 label，原生 value 继续由 NSTextView 正文提供。

## 后续词汇调整（2026-08-06）

「飞光」现只作为模块入口名，编辑器稳定名称相应从「飞光正文／Flylight body」调整为「记录正文／Entry body」。名称与 placeholder 分离、原生动态 value 和真实 App AX 门禁保持不变。

## 验证结果

- `swift build` 通过。
- 定向真实 `.app` E2E 在空态与脏草稿态对账原生 label／value 均通过。
- `make test-demo-fixture` 与完整 `make check` 均通过；全量报告为 1500 项测试、0 失败。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，拒绝飞光继续从 placeholder 派生 accessibility name，并要求 Demo 覆盖。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，读取真实 NSTextView 的 label 与 value。

## 发行与回滚

只使用非生产 profile。若共享参数影响其他编辑器，停止交付并修复调用顺序；不得删掉飞光 label 或回退为 placeholder 冒充名称。

## 教训与永久约束

placeholder 是 hint，不是名称。任何长提示型编辑器都必须以真实 App AX 树同时验证稳定 label 与动态 value。

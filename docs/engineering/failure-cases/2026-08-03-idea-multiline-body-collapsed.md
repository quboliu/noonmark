# FAIL-2026-08-03-03：多行想法保存后被压成单行

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-03（想法重做双轴代码审查）
- 影响版本／构建：`feature/idea-capture` 的 `ff86af0`，0.2.0 之后未发布开发构建
- 引入提交：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` `feat(ideas): 原生想法记录与置顶、回收站、标签过滤`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 和现有 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

用户在想法 composer 输入两行或更多正文后保存，原有换行会被替换为空格。重新打开卡片或重启 App 后只能看到单行正文，段落、列表和逐行记录的结构永久丢失。

问题影响页面 composer 与全局想法浮窗，因为两者最终共用同一个想法提交函数。单行想法、分类事实与同步身份不受影响。

## 时间线

- 2026-08-03：`ff86af0` 让想法提交复用 `NewTaskDraftParser`。该 parser 为任务标题设计，会把全部 whitespace 合并成单个空格。
- 同日：真实想法 E2E 只输入单行正文，因此保存、SQLite 与重启门禁全部转绿，没有观察段落结构。
- 想法重做把 composer 明确定义为多行输入；双轴审查追踪最终 mutation 后发现 UI 接受换行，但提交边界仍调用任务标题 parser。
- 在 `ff86af0` 的隔离 detached worktree 中把原有真实 E2E 草稿改成两行，原始路径稳定判红。

## 复现与证据

在 `ff86af0` 的隔离 worktree 中，只把 Idea Capture E2E 的第一条草稿及预期正文改成两行，然后运行：

```bash
NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e
```

红色结果：

```text
failed: Cmd+Enter did not save the idea draft
```

源码证据：`NoonmarkStore+Ideas.swift` 把想法交给 `parsedTaskDraft`；`NewTaskDraftParser.parse` 最终执行 `title.split(whereSeparator: \.isWhitespace).joined(separator: " ")`。因此输入面能显示换行不代表 mutation 收到的正文仍有换行。

## 排除的假设

- 排除 `MarkdownEditor` 不能承载多行：同一个真实编辑器接受两行草稿，并继续触发分类候选与 `⌘Enter`。
- 排除领域实体主动压平正文：`IdeaEntry` 只修剪首尾 whitespace；新的 parser fast test 把保留换行的正文交给领域层后可以原样保存。
- 排除 SQLite 或 sync 编解码丢换行：故障在进入 `appendIdea` 之前已经发生；修复后的同一真实 App 重启从 SQLite 回读两行正文成功。
- 排除 production 资料影响：红色与绿色复现都只 reset 并运行固定 `e2e` profile，没有启动、读取、定位或 reset production 身份与资料。

## 根因与破坏机制

任务标题和 memo 正文被错误地视为同一种输入。任务标题需要单行规范化，而想法正文必须保留用户的段落结构；复用同一个 parser 把两种不同领域语义藏在一个看似方便的 seam 后面。

既有测试又只验证单行输入，导致 parser、Store、真实 App 与 SQLite 在错误终态上自洽，未能捕获信息损失。

## 根因修复

实现与验证已完成，修复提交待回填：

- 新增独立 `IdeaDraftParser`，复用分类 token 识别规则，但只移除 token 与其邻接 horizontal whitespace，不合并正文行。
- 页面与全局浮窗的想法提交统一改走 `IdeaDraft`；任务创建继续使用原有单行 `NewTaskDraftParser`。
- 搜索与集合投影在领域边界统一，正文换行不会影响标签搜索或置顶独立分组。
- 真实 E2E 第一条想法固定为两行并带分组／标签；保存、卡片呈现、重启与 SQLite 回读必须保持换行。
- shell SQLite probe 使用 `char(10)` 精确比较正文换行，并把 compact 连续流截图列为必需产物，避免 App 内断言转绿而外层证据仍停留在旧单行 fixture。

## 验证结果

- 症状红：`ff86af0` 隔离 worktree 的真实 `.app` 两行草稿以 `Cmd+Enter did not save the idea draft` 判红。
- Fast：`NewTaskDraftParserTests.testIdeaDraftPreservesLineBreaksWhileRemovingClassificationTokens` 与相关 Idea collection/search 测试通过。
- 症状绿：`NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e` 通过；同一两行正文经物理输入、`⌘Enter`、卡片、App 重启和 SQLite 回读后仍保持两行，外层 SQLite probe 为 `5 4 1 1 1 1 0 1 1 1 1`。
- 修复提交：待回填。

## 永久门禁

- Fast：`scripts/test-unit` 由 `scripts/check` 强制执行，固定区分任务标题的单行 normalization 与想法正文的多行 preservation。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行；Idea Capture 场景以真实多行 composer 输入保存，并在第二个 App process 与 SQLite 中对账精确正文。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

故障存在于未发布 feature branch，没有 production 迁移或发行物。修复随想法重做进入 `demo`／`e2e` 验证；若 parser 或持久化门禁失败，回滚整个原子提交并对指定非生产 profile clean cut，不允许退回“UI 多行、数据单行”的半完成状态。

本案不涉及安装、签名、启动、退出或发行产物，不增加 release tier。

## 教训与永久约束

- 任务标题与 memo 正文不是同一个领域值；共享 token scanner 不等于共享正文 normalization。
- 输入控件显示正确不能证明持久化正文正确；多行内容必须在 mutation、SQLite 与重启回读后做精确对账。
- 真实用户路径 fixture 必须包含会暴露结构性信息损失的最小样本，不能只覆盖单行 happy path。

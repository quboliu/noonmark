# FAIL-2026-08-03-02：想法正文双击不能编辑且编辑入口隐藏在溢出菜单

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-03（本任务用户体验审查）
- 影响版本／构建：`feature/idea-capture` 的 `ff86af0`，0.2.0 之后未发布开发构建
- 引入提交：`ff86af0a1fa47518667348e3df0d61d1c9caf09e` `feat(ideas): 原生想法记录与置顶、回收站、标签过滤`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 和现有 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

用户在「想法」时间线查看一条既有想法时，双击正文没有任何反应。要修改正文，必须先找到卡片右侧三点菜单、打开菜单，再选择「编辑」。这把高频直接操作藏进低可发现的辅助入口，使想法流无法像 flomo、Thino 或 Memos 一样原位连续编辑。

问题影响全部活动想法，不依赖正文、标签、日期或 Provider。删除、置顶和 SQLite 本身不是本案症状。

## 时间线

- 2026-08-03：`ff86af0` 新增 `IdeaCardView`。正文只负责渲染，`beginIdeaEdit` 只由 `IdeaCardOverflowMenu` 的「编辑」按钮调用。
- 同日交接声称真实 E2E 覆盖“行内编辑”，但自动化也是从三点菜单选择编辑，因此没有覆盖用户期望的双击入口。
- 本任务用户明确报告旧想法编辑必须走三点菜单，认为交互不可接受。
- 2026-08-03：把同一真实 `.app` E2E 改为对正文锚点发送 WindowServer 物理双击；旧实现稳定判红，编辑器没有出现或取得焦点。

## 复现与证据

症状命令：

```bash
NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e
```

红色结果：

```text
idea capture exercise failed: failed: idea inline edit field did not take focus
```

运行产物 `artifacts/e2e-idea-capture/exercise-result.view-tree.txt` 同时证明正文目标 `ideas.card.body.<IdeaID>` 可见、未隐藏且具有 915×16 pt 的可点击区域；物理双击成功投递后，`editingIdeaID` 仍未变为目标身份，`ideas.card.edit-field.<IdeaID>.input` 没有出现。

源码证据：`App/NoonmarkMacApp/IdeasPage.swift` 的 `displayBody` 没有双击 gesture；`IdeaCardOverflowMenu` 的按钮是唯一调用 `store.beginIdeaEdit(idea)` 的用户入口。

## 排除的假设

- 排除正文不可见或没有点击区域：view-tree 运行产物记录正文锚点可见且宽度 915 pt。
- 排除过滤后目标卡片消失：双击前目标正文仍在当前时间线，E2E 以稳定 IdeaID 查找。
- 排除原位编辑领域命令完全不存在：从三点菜单进入后，既有 `beginIdeaEdit`／`commitIdeaEdit` 与 SQLite 写入可以运行；缺陷在进入编辑的交互 seam。
- 排除等待不足：旧视图没有任何双击 handler，等待不会产生编辑状态；120 次确定性轮询后仍保持未编辑。
- 排除 production 资料影响：复现只 reset 并运行固定 `e2e` profile，没有启动、读取、定位或 reset production 身份与资料。

## 根因与破坏机制

旧规格把“支持行内编辑”理解为“存在一个行内 editor”，却没有定义用户怎样直接进入它。实现因此只在溢出菜单中接线 `beginIdeaEdit`；E2E 又复用了同一菜单路径，形成实现与门禁共同绕过真实期望的盲区。

结果是低频管理菜单承担了高频内容编辑入口。正文看起来像可阅读内容，却没有任何直接 manipulation，用户必须为每次修改执行额外定位、打开与选择操作。

## 根因修复

实现与验证已完成，修复提交待回填：

- 正文稳定提供唯一可识别的双击区域；物理双击直接建立同一条目的 inline editor session。
- editor 在原位置、原宽度和近似原高度出现，保持滚动位置。
- `Enter` 换行、`⌘Enter` 保存、`Esc` 取消、失焦安全保存；失败保留正文与编辑状态。
- 三点菜单继续作为可发现性和辅助功能入口，但不再是主要路径。
- 页面与自动化都通过 editor session interface，而不是分别维护编辑规则。

## 验证结果

- 症状红：真实 `.app` 已以 WindowServer 物理双击稳定复现，结果为 `idea inline edit field did not take focus`。
- Fast：`scripts/reset-dev-data audit && swift test --filter IdeaCaptureSessionTests` 通过 6 项 session 测试，覆盖共享草稿、成功后清空、失败保留、正文归一化、保存／取消和编辑错误留存；`scripts/test-unit` 已强制调用该 suite。
- 症状绿：`NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e` 通过；同一真实 `.app` 场景对正文锚点发送 WindowServer 物理双击，原位 editor 出现并取得焦点，保存后正文、重启和 SQLite 探针一致。三点菜单没有参与进入编辑。
- 年度回归：`make test-demo-fixture` 通过；同一真实 Demo App 额外覆盖宽屏双栏、按需搜索、旧想法回看、右侧检视与回收站。
- 修复提交：待回填。

## 永久门禁

- Fast：`scripts/test-unit` 由 `scripts/check` 强制执行；正式修复将加入 `IdeaInlineEditorSession` interface 测试，覆盖双击进入后的保存、取消、失焦和失败保留状态。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制执行；`IdeaCaptureE2EAutomation.exerciseInlineEdit` 对真实正文锚点发送 WindowServer 物理双击，并要求原位 `NSTextView` 出现、聚焦、接收输入、保存和 SQLite 回读。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

当前想法功能只在未 push 的 feature branch，尚无 production 资料迁移或发行。修复随想法重做整体进入 `demo`／`e2e` 验证；若 editor session 或新 UI 未全绿，回滚对应原子 commit 并对指定非生产 profile clean cut，不保留菜单可编辑但正文双击失效的半完成状态。

本案不涉及安装、签名、启动、退出或发行产物，不增加 release tier。

## 教训与永久约束

- “存在行内 editor”不等于“用户能直接编辑”；规格必须定义进入、提交、取消、失焦和失败的完整交互。
- 高频内容操作不得只藏在三点菜单或 context menu。
- UI E2E 必须走用户期望的最短路径；用菜单、Store 或领域命令建立相同终态不能替代入口级症状验证。
- 双击验收必须使用真实 WindowServer 事件和可见正文目标，不能直接调用 gesture closure。

# FAIL-2026-10-12-06：草稿异步就绪后速记浮窗没有取得输入焦点

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-10-13T03:35:14.619Z（真实 E2E 报告 startTime；本地 2026-10-12 晚间）
- 影响版本／构建：首轮未提交 Web 实施；source hash 前缀 `4655d435` 的隔离容器镜像。
- 引入提交：尚未形成提交。基线 `83e9aedd6003632b26b26b80808e132e1187ebc5` 只有 Web 设计文档，不含本次界面代码。
- Git author／committer：引入代码尚未提交，因此没有对应 Git author／committer；不可把基线文档的 Git identity 当成实施者。
- 实际修改者：当前 agent 协作记录可确认由 Codex `/root/web_ui` 编写 `apps/web/src/ui.tsx`、`Tasks.tsx` 与 `Notes.tsx` 的初始实现。
- 修复提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`

## 用户症状与影响

打开“添加任务”浮窗后，草稿已读取、标题输入已启用，但键盘焦点没有进入标题。长页面通过快捷键打开速记时也受影响。采用相同 `autoFocus` 写法的“编辑记录”浮窗存在同一生命周期问题。

## 时间线

1. 初始实现以 `FormFields` 禁用尚未完成 IndexedDB 草稿读取的表单，同时给标题及记录正文配置 React `autoFocus`。
2. 隔离真实容器的 Playwright 套件在 `self-hosted.spec.ts` 的标题焦点断言判红。
3. 读取报告后将“字段未 ready”“dialog 打开顺序”“pending 往返”的假设拆开；增加可控制真实 IndexedDB 成功回调交付时机的 focused gate。
4. 修复共享表单焦点生命周期；原始套件、focused gate 与一年演示随后全部通过。

## 复现与证据

`self-hosted.spec.ts` 已完成真实登录，再打开“添加任务”；`toBeEnabled()` 成功，但 `toBeFocused()` 连续 15 秒得到 `inactive`。原始报告属于隔离 E2E run `3273330f-a507-4aa9-8141-8eb4c75ece89`，报告名 `playwright-browser.json`。报告中的实际 DOM 为已启用的 `<input name="task-title">`，不含原生 `autofocus` 属性。

`apps/web/e2e/focus.spec.ts` 使用原始 IndexedDB open／get 请求，只推迟成功回调交付，明确验证 disabled → ready → focused；它不伪造草稿内容、API 结果或领域数据库。随后通过真实命令校验拒绝，使 pending 往返，确认初次聚焦不会再次抢夺焦点。第二条受害路径为真实创建后打开记录编辑浮窗。

## 排除的假设

- 不是输入一直禁用：原始测试先通过 enabled 断言。
- 不是 15 秒不足以等待草稿：实际 DOM 早已启用，重复观察仍为 inactive。
- 不能仅凭源码断言 dialog 抢焦点；focused gate 控制草稿交付时机，将初次 ready 与后续 pending 明确分开验证。

## 根因与破坏机制

React `autoFocus` 在首次挂载尝试聚焦，当时其祖先 fieldset 因草稿未就绪而禁用；这次聚焦无法成功。草稿读取完成只改变 `disabled`，不会再次触发 React 的首次挂载聚焦。原生 `<dialog>` 因此把焦点留在其他可用控件，标题虽已可输入但不会自动取得焦点。

## 根因修复

统一由 `FormFields` 管理第一次可输入时的焦点。需要初始焦点的输入以 `data-autofocus` 标明；`useLayoutEffect` 在 ready 且非 pending 时调用真实 DOM focus，并以每次表单挂载的一次性状态防止随后 pending 往返重复聚焦。取消两处不符合异步就绪生命周期的 React `autoFocus`。不增加 timeout、轮询、延迟阈值或测试专用产品行为。

## 验证结果

focused gate、原始真实浏览器套件及一年长页面速记均通过。测试中预填 textarea 的标签定位歧义已用实际 Chromium 确认，改为准确角色／名称定位；原有 disabled、value、focus 和 pending 后不抢焦点断言保持不变。

上述修复已进入首个实现提交；完整运行证据见[预览验证记录](../../tasks/noonmark-web-self-hosted/verification.md)。

## 永久门禁

- fast：`scripts/web/test-focus` 执行 `focus.spec.ts`，通过 Linux `make check`／`scripts/web/check` 运行真实浏览器焦点检查；`gates.tsv` 已登记。
- symptom：`apps/web/e2e/self-hosted.spec.ts` 的原始标题焦点断言，以及一年演示 `demo.spec.ts` 的长滚动页面速记焦点断言。
- 门禁不得把 `toBeFocused()` 改为仅检测 enabled，不得增加等待时长吸收问题。

## 发行与回滚

问题在首轮隔离验收发现，尚未发布。未通过症状门禁前不对外交付镜像；必要时撤回未发布的 Web 实施，不改原生运行面。

## 教训与永久约束

输入的挂载时机、实际可编辑时机和浮窗打开时机是不同状态。共享表单必须以可编辑生命周期管理焦点；所有依赖异步草稿恢复的浮窗都走同一机制，并同时验证“第一次应聚焦”和“以后不得抢焦点”。

# FAIL-2026-08-04-28：飞光 E2E 点击目标在 presentation 过渡中失稳

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-05T01:36:52Z；2026-08-07T13:54:04Z 复发并重开
- 影响版本／构建：0.2.4 build 11，source commit `72825020ac8e7b278649cf96bee5d896336045c2`
- 引入提交：`249e11d9504169254b1d419d813644c95bee90d8`（`feat(ideas): native idea capture with pinning, trash, and tag filtering`）；`4244ae89b6981fde76055a0c1190f9d0d032db65` 只完成局部修复，遗留本次协议缺口
- Git author／committer：上述两项提交均为 `quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：`ff62a33938e15d8ecdce827e7f3ae82ddc666ca9`

## 用户症状与影响

v0.2.4 build 11 的本地完整发行 E2E 在真实 WindowServer 点击飞光「换一组」前判红。随后同一 commit 的聚焦飞光 E2E 两次通过、第三次又在全局飞光的具体分类候选上判红。两次都发生在 `mouseDown` 之前，阻断发行，但没有执行重复动作、启动 production App 或触碰用户资料。

## 时间线

- 2026-08-03：`249e11d9` 引入飞光共享点击 helper，以被动锚点几何作为最后兜底。
- 2026-08-04：`4244ae89` 加入真实文字输入／按钮 hit-test，并只把「目标消失」字符串列为可恢复过渡；重试仍只有三次连续 `Task.yield()`。
- 2026-08-05：`569b61eed26a9c4f9b26bc44f8784b124c2887ad` 根据当时通过的运行关闭案例，但案例内的引入与修复 commit 引用后来无法由当前 Git object database 解析。
- 2026-08-07T13:54:04Z：build 11 完整 E2E 在 `ideas.review.refresh` 判红；前台 PID、bundle 与当前进程一致。
- 2026-08-07T13:57Z 至 14:01Z：同一聚焦路径前两轮通过，第三轮在独立全局飞光 Panel 的具体分类候选判为零可点击面积。
- 2026-08-07：对账失败 view tree、窗口关系与源码后重开本案例；fast contract 先判红，随后开始修复共享目标解析与 presentation settlement。

## 复现与证据

完整发行路径：

```text
NOONMARK_EVIDENCE_RUN_ID=release-v0.2.4-b11-20260807T133025Z \
NOONMARK_EVIDENCE_REQUIRE_FULL_SUITE=1 scripts/test-e2e release
```

原始错误为：

```text
ideas.review.refresh: idea capture target changed before mouseDown
```

失败树同时出现 `ideas.collection=review`、旧分类筛选与旧卡片，却没有由同一个 `ideaBrowseMode == .review` 条件渲染的刷新按钮。这是 SwiftUI conditional subtree 尚未收敛的中间 presentation，不是稳定业务状态。

聚焦复现：

```text
NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e release
```

同一 source commit 的结果为两次 `ok`，第三次：

```text
idea-capture.field.suggestions.item.<classification-id>:
idea capture target has no clickable visible area
```

第三次失败时独立 `NSPanel` 可见且是 key window，候选已经挂载，但 Panel 正在随候选列表调整内容高度。两次失败的前台 PID、bundle 与 current PID 都一致，且共享同一个 `click` helper。

## 排除的假设

- 不是飞光领域动作失败：错误发生在 `mouseDown` 之前，review seed 与分类选择动作都尚未执行。
- 不是错误 App 或失去前台：两次 terminal 报告的 PID 与 bundle 都精确匹配 E2E App。
- 不是单个刷新按钮损坏：同一缺口在另一个窗口的分类候选上复现。
- 不是稳定缺少按钮：聚焦路径可完整通过创建、筛选、回看、全局捕捉、持久化与重启回读。
- 不是 production 身份或资料：所有复现都使用固定 `e2e` profile。

## 根因与破坏机制

共享 helper 把「数据状态已发布」或「锚点单帧出现」误当成「用户已经拥有稳定可点击目标」。`isTargetPresentationTransition` 依赖错误字符串，只覆盖目标消失，不覆盖同样发生在 `mouseDown` 前的零面积与真实 hit target 暂不可用；三次立即 `Task.yield()` 也没有建立跨布局轮次的稳定性条件。

此外，`AppViewTreeE2E.buttonInteractionTarget` 通过主窗口的 `currentWindowTree()` 判断 anchor 与重叠按钮可见性。全局飞光是无 parent／sheetParent 的独立 `NSPanel`，因此永远无法走真实按钮解析；此前通过的运行实际落到被动锚点中心兜底，与门禁声称的 hit-test 强度不对等。

## 根因修复

- 按 anchor 自己的精确 window 枚举可见按钮与 hit-test，不再把独立 Panel 排除在外。
- 飞光单击不再回退被动锚点中心；文字输入必须命中精确编辑器，其他动作必须解析到真实 hit-test 目标。
- 目标消失、文字输入重挂载、可见面积归零与物理 hit target 暂不可用改为 typed pre-`mouseDown` presentation state，不再解析错误字符串。
- 点击前要求同一 window 实例、window number 与 pointer coordinate 连续三个主循环采样稳定；未收敛会在既有有界等待内保存证据并判红。
- WindowServer driver 在发出 `mouseDown` 后把任何失败（包括 `mouseUp` cleanup 失败）标成 typed `afterMouseDown`；共享 contract 从 erased error 读取 phase，未分阶段错误一律为不可重试的 `unknown`。飞光 presentation error 显式声明 `beforeMouseDown`，driver phase 采用无 `default` 的穷举映射，外层只重试明确的 `beforeMouseDown`，不能根据稍后采样到的按键状态推断阶段，也不能对可能已经触发的动作再点击。
- 错窗口、重复 identifier、隐藏／遮挡、坐标拓扑、焦点、pointer、`mouseDown` 后与行为断言失败继续 fail-closed。

## 验证结果

- Red：更新后的 `scripts/test-idea-capture-interaction-target-contract` 在旧实现上 exit 1；phase retry 单元测试在 contract 实现前编译判红。
- 中间修复证据：早期 repair tree 的 fast contract 与 release build 编译通过，并连续五轮跑绿聚焦真实飞光 E2E；后续又加入窗口可见性与 post-`mouseDown` phase 守卫，因此这五轮只证明原始失败位置曾转绿，不作为当前候选的最终症状证据。
- 当前 Green：phase retry 单元测试、收紧到精确函数范围的 fast contract 与 failure-case gate 已通过；精确修复 commit `ff62a33938e15d8ecdce827e7f3ae82ddc666ca9` 的聚焦与完整真实 App E2E 均通过，并完成分类候选、回看刷新、SQLite 与重启对账。
- build 12 的 `make check`、writer lease、完整 E2E 与本地 DMG 发行链使用同一 source commit 全绿。随后 build 12 因独立的 GitHub workflow／hosted SDK 故障退役，不改变本案例原始用户症状已经由红转绿的事实；build 13 因独立 hosted 工具缺口退役，build 14 继续继承同一修复。

## 永久门禁

- fast：`scripts/test-idea-capture-interaction-target-contract`，由 `scripts/check` 强制调用，固定精确 window 解析、typed pre-`mouseDown` state、连续稳定坐标、禁止被动几何兜底，以及 `afterMouseDown` 失败永不重试；`NoonmarkMacE2ESupportTests` 证明 post-down activation failure 的 `mouseDown` 计数只能为一。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，真实点击回看刷新与独立 Panel 的具体分类候选，再对账 review seed、分类、SQLite 与重启。

## 发行与回滚

build 11 已在本地完整 E2E 判红并永久退役。build 12 完成原始症状验证后因独立发行基础设施故障退役，build 13 又因 hosted 工具依赖故障退役；v0.2.4 仍没有 GitHub Release。build 14 保留精确修复 commit。若修复本身回归，回退共享 E2E 修复 commit 并继续阻断发行；不得恢复被动坐标兜底、放宽 WindowServer 校验或触碰 production 资料。

## 教训与永久约束

SwiftUI model state、anchor 存在与用户可点击 presentation 是三个不同事实。真实交互门禁必须在精确目标窗口内证明 identifier 唯一、可见、hit-test 可达且跨布局轮次稳定；独立 Panel 不能借主窗口树推断，也不能以偶发通过证明几何兜底正确。

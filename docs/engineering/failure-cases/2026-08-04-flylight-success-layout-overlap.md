# FAIL-2026-08-04-10：飞光发布成功动画与列表上下文重叠

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:06 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至 `0d62105`
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由工作会话、提交与真实 App 截图确认
- 修复提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec`

## 用户症状与影响

发布成功后 Composer 立即失焦并开始收起，列表同时插入新分组。真实截图中「最近 · 1」一度绘制在 Composer 操作栏内，成功状态、工具栏与集合标题互相覆盖，使已保存反馈看起来像布局故障。

## 时间线

- K3 视觉 review 指出 `ideas-composer-saved.png` 存在集合标题进入操作栏的瞬态。
- 源码和截图共同定位：成功时立即清除 expanded intent，并对整个 surface 施加隐式高度动画。
- 成功反馈的 1.2 秒内保持工作态高度，只去除 first responder；状态回到 pristine 后稳定收起，并移除 whole-surface expansion animation。

## 复现与证据

真实 App 发布第一条飞光后在 success 窗口截图。旧截图可见「最近 · 1」覆盖 action chrome。新的 E2E 在成功后等待 250 ms，要求 surface 仍处于工作态高度、集合 frame 完全位于其下方且互不相交，再保存截图。

## 排除的假设

- 不是集合本身 padding 恒定错误：空态和稳定态布局正常，只在成功收起动画中出现。
- 不是截图时机伪影：用户也会看到该 160 ms 动画，瞬态仍是产品体验。
- 不是提高 z-index 可修复：那只会遮住其中一层，空间所有权仍冲突。

## 根因与破坏机制

成功事件同时改变正文、焦点、expanded intent、surface 高度与列表内容；SwiftUI 的 whole-surface 隐式动画让父布局与子绘制不同步。集合先取得新位置，Composer 仍在旧尺寸绘制，造成视觉重叠。

## 根因修复

成功态保持展开，只展示清晰的已记录反馈；1.2 秒后 session 回到 pristine 且正文为空时才无隐式 surface 动画地收起。E2E 以延迟后的 frame 顺序约束真实稳定窗口，而不是只检查视图存在。

## 验证结果

- 新真实截图中操作栏、成功状态与「最近」标题边界清楚。
- 延迟 250 ms 的工作态高度和集合 frame 门禁通过。
- `make test-demo-fixture` 与完整 `make check` 均通过；全量报告为 1500 项测试、0 失败。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，拒绝 `value: isExpanded` whole-surface 动画并要求成功布局顺序断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，真实发布后延迟取证工作态高度、集合顺序及截图。

## 发行与回滚

只运行隔离 `e2e` 身份。若回归，停止交付成功态 cutover；不得靠 z-index、裁切或缩短截图窗口吸收。

## 教训与永久约束

结构高度、列表插入与反馈状态不应同时做隐式动画。成功反馈应先稳定呈现，再在独立状态边界完成收起。

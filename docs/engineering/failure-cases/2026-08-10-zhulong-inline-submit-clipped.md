# FAIL-2026-08-10-04：烛龙内联任务草稿提交动作被固定 Composer 遮挡

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-10T13:46:00Z
- 影响版本／构建：v0.2.6 build 25 候选，source commit `be3066cb347ab1d2bc71420780939b1582107a4e`
- 引入提交：`f4ee883d95d1b46752a13fa7737d0fe5cb992acb`（`feat(ui): Refine the Zhulong conversation page and add the waiting-response breathing state`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`5953eeb0ab4793de5511c6c0b925df56977e4b71`（`fix(e2e): reveal the Zhulong artifact submit action`）

## 用户症状与影响

完整真实 App E2E 进入烛龙会话后，Provider 已建立三项可编辑任务草稿，但物理提交步骤持续等待并最终报告「inline task draft did not appear」，阻断 v0.2.6 build 25 候选。底层草稿和完整卡片其实已经存在；提交按钮位于固定 Composer 后方，当前自动化没有先执行用户可做的滚动动作，因此无法取得真实 WindowServer hit target。没有证据显示 Provider、加密 sidecar 或 Todo 写入失败，production App 与资料均未运行或读取。

## 时间线

- 2026-07-29：`f4ee883d95d1b46752a13fa7737d0fe5cb992acb` 重排烛龙会话与 Composer，并把提交动作改为较高的 `SmallActionButton`；原自动化仍假设按钮天然位于可点击区域。
- 2026-08-10T13:46Z：v0.2.6 build 25 的完整 E2E 首次在本次发行验收中判红。
- 同日：独立 focused E2E 再次稳定复现；同一 seam 在只加入精确滚动动作后转绿。
- 同日：独立 worktree 以同一真实 App 命令验证引入提交父级为绿、引入提交本身为红。

## 复现与证据

红灯命令为 `NOONMARK_E2E_ZHULONG_INLINE_ARTIFACT_ONLY=1 scripts/test-e2e`。build 25 原始代码与 focused 重跑都得到 `phase=draftReview`、`workspaceStatus=active`、`providerFailure=none`、`artifacts=1`、`drafts=1`、`receipts=0`，同时 view-tree 包含同一 `conversationRunID` 的草稿与提交 anchor。提交 anchor 的窗口 frame 为 `y=78...106`，固定 Composer 的 frame 为 `y=16...106`，物理命中校验正确拒绝被覆盖目标。

同一命令在独立 worktree 的 `f4ee883d^` 返回 0，在 `f4ee883d` 返回 1；两次均重建并签名隔离 e2e App、重置自己的非生产 profile，故引入边界达到运行产物证据档。

## 排除的假设

- 不是 Provider 或协议解析失败：Provider failure 为空，response artifact 和会话草稿均各有一份。
- 不是草稿 ID、版本或字段错配：三项任务结构已通过自动化字段断言，同一 run 的草稿卡和提交 anchor 都在 view-tree。
- 不是 sidecar 持久化失败：会话保持 `draftReview`，草稿身份与当前 diff 均可回读。
- 不是完整 E2E 长跑污染：只运行 inline artifact 的 focused seam 仍稳定判红。
- 不是 `buttonInteractionTarget` 新增后才出现：该 helper 引入提交的父级使用旧按钮解析时也判红。

## 根因与破坏机制

草稿卡高度超过会话可视区，固定 Composer 占用窗口底部。引入提交改变卡片动作高度与会话布局后，自动滚动只把所属对话 record 对齐到底部，没有保证 record 底端的提交动作离开固定 Composer。E2E driver 随后直接要求按钮已可命中；AppKit view-tree 能看见已附着的 anchor，但其可点击区域被 sibling overlay 覆盖，因此真实 hit-test 返回失败。自动化把「草稿已渲染但提交动作尚未滚入可点击区域」错误归类为「草稿未出现」。

## 根因修复

driver 先通过 attached view 解析精确提交 anchor，对该 anchor 执行带 24 pt 垂直余量的 `scrollToVisible`，强制窗口完成 layout 与 display，再解析同一窗口中的可见 anchor 和 hit target，最后仍由 WindowServer 发出真实点击。产品 action、Provider、sidecar、Todo 原子应用和 UI 布局不改变；修复只补齐真实用户需要执行的滚动步骤，不直接调用按钮 action，也不放宽命中判定。失败输出改为区分「已渲染」与「可物理提交」。

## 验证结果

- Red（完整用户路径）：build 25 完整 `scripts/test-e2e` 在烛龙 inline artifact 步骤返回 1。
- Red（focused）：`NOONMARK_E2E_ZHULONG_INLINE_ARTIFACT_ONLY=1 scripts/test-e2e` 在 build 25 原始代码稳定返回 1。
- Red／Green（引入边界）：`f4ee883d^` 返回 0，`f4ee883d` 返回 1。
- Green（根因探针）：只增加精确滚动、layout、display 后，同一 focused seam 返回 0，并完成真实提交、回执及历史保留。
- Green（完整候选）：build 26 同一 evidence run `release-v0.2.6-b26-20260810T141700Z` 的完整 `scripts/test-e2e` 返回 0，真实 inline artifact 提交及历史保留证据落盘；writer-lease E2E 与 `make check` 也返回 0。
- Green（发行门禁）：本地 annotated tag `v0.2.6` 精确绑定修复 commit；`scripts/release-private-dmg` 消费同 source／run 的完整 E2E 证据并返回 0，production App 未执行，受控 `dmg-validation` 安装／退出／重启通过。

## 永久门禁

- fast：`scripts/test-zhulong-inline-artifact-interaction-contract`，由 `scripts/check` 强制调用；要求 attached anchor、带 Composer 余量的滚动、layout／display、hit-test 与 WindowServer 点击保持正确顺序，并拒绝直接 action bypass。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用；固定 Provider 建立三项内联草稿后，必须通过真实滚动与 WindowServer 点击完成原子提交并保留只读产物历史。
- release：`scripts/verify-development-validation-evidence`，由 `scripts/release-private-dmg` 强制调用；私有 DMG 前必须消费同 source/run 的完整 E2E 成功证据。

## 发行与回滚

build 25 与本地候选 tag 必须退休，不得移动或复用；修复只能使用更高 build 建立新的 v0.2.6 候选。若精确滚动影响其他会话交互，只撤回本案例的 E2E driver 修复并再次提升 build，不回退产品草稿、Provider 或 sidecar 能力，不改用直接 action、固定等待或放宽 hit-test。production App 与资料不参与验证。

## 教训与永久约束

「view 已附着」不等于「用户可点击」。长内容内的动作遇到 fixed／safe-area UI 时，真实交互门禁必须先滚动精确控件并重新执行 hit-test；失败信息必须分别回答资料是否存在、控件是否渲染、控件是否可见及控件是否可物理命中，不能把四层状态压成「未出现」。

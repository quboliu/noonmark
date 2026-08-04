# FAIL-2026-08-04-02：Sticky Note 展示模式控件目标漂移

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 02:02 -04:00
- 影响版本／构建：2026-08-04 未提交工作树所构建的隔离 E2E App
- 引入提交：无；故障在本轮尚未提交的 Sticky Note 首版实现中引入
- Git author／committer：不适用；故障改动尚未提交
- 实际修改者：Codex 当前 agent session
- 修复提交：`3ab199ec94e5de9e2bf6b0143a11f173e2fa63c6`

## 用户症状与影响

Sticky Note 页面可以显示清单流，但点击「便签墙」时，模式按钮的目标视图会在 `mouseDown` 前消失并被重建。严格物理输入因目标身份漂移而拒绝点击；用户侧也可能遇到命中反馈不稳定，且无法为视图切换建立可靠交互门禁。

## 时间线

- 2026-08-04：首版使用 SwiftUI `Picker(.segmented)`，并把验证锚点放在 Picker 的 `Label` 背景中。
- 2026-08-04 02:02：隔离真实 App E2E 第一次执行视图切换，稳定以 `target changed before mouseDown` 判红。
- 2026-08-04：视图树证明父 Picker 和清单流存在，但 `sticky-notes.mode.wall` 子目标不在失败时视图树内。
- 2026-08-04：改为应用自有、身份稳定的双按钮展示控制；同一路径重跑转绿。
- 2026-08-04：产品后续要求收敛为单一下拉清单；稳定身份迁移到应用拥有的 `Menu` 触发器，原生菜单条目只在菜单 tracking 期间由键盘选择，不再承担长期锚点。

## 复现与证据

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。exercise 进程返回：

```text
failed: idea capture WindowServer click failed for sticky-notes.mode.wall:
idea capture target changed before mouseDown: sticky-notes.mode.wall
```

失败时 `artifacts/e2e-idea-capture/exercise-result.view-tree.txt` 包含 `sticky-notes.mode`、`sticky-notes.presentation=stream` 与目标条目，但不包含 `sticky-notes.mode.wall`，证明不是页面未打开或资料未投影。

## 排除的假设

- 不是 Sticky Note 资料为空：页面计数为一，源飞光正文已渲染。
- 不是侧栏导航失败：当前页锚点为 `sticky-notes.page`。
- 不是领域选择未保存：`pinnedAt` 与 `stickyNoteIdeas` 已在进入页面前对账。
- 不是自动化提前点击：严格驱动已先等待目标出现，失败发生在同一次点击的 mouseDown 前身份复核。

## 根因与破坏机制

SwiftUI segmented Picker 的选项 Label 属于 AppKit 管理的瞬态内部层级。验证锚点放在 Label 背景后，会随 Picker 的内部更新或鼠标状态被拆除／重建；它不是应用拥有的稳定命中边界。物理输入先解析锚点，再在 mouseDown 前复核 exact view identity，因此正确拒绝了漂移目标。

## 根因修复

- 用单一 `StickyNotePresentationMenu` 建立应用自有、身份稳定的下拉触发器。
- 选择状态与 E2E 锚点挂在触发器边界；清单流／便签墙条目由原生菜单 tracking 选择，不给瞬态内部 Label 挂长期锚点。
- 展示偏好和页面布局接口保持不变，presentation adapter 可继续扩展第三种视图。

## 验证结果

- `scripts/test-notes-ui-contract`：通过，确认单一应用自有下拉触发器存在，且旧双按钮／逐模式锚点不再出现。
- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：exercise／verify 均为 `ok`；WindowServer 连续点击便签墙与清单流，重启后仍保留便签墙偏好。
- `make test-demo-fixture`：通过；三条 Sticky Note 在清单流与便签墙中逐条对账。
- `make check`：通过，1493 项测试无失败；两项 live iCloud 测试按既有环境约束跳过，其余 lint、format、真实 App、仿真、DMG 与故障案例门禁全部通过。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求单一下拉触发器，并拒绝旧双按钮与逐模式瞬态锚点。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，以 WindowServer 点击稳定触发器、等待原生菜单 tracking，再依次选择便签墙和清单流。

## 发行与回滚

故障只发生在未提交的非生产构建，未触碰 production App 或资料。若稳定控制仍不能通过物理点击，应停止交付并撤回 Sticky Note 页面，不得放宽 exact-target 检查。

## 教训与永久约束

对必须承载真实交互门禁的模式切换，验证锚点必须位于应用拥有的稳定命中区域。可以验证原生 Menu 的 tracking 与选择结果，但不能把 SwiftUI Picker、Menu 或其他桥接控件的瞬态内部 Label 当作可长期识别的交互身份。

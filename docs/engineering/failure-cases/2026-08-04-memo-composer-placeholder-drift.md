# FAIL-2026-08-04-01：飞光空输入框提示与光标错位

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-03 23:41 -04:00
- 影响版本／构建：`7a639ee4deac5969a103796076e9147c7fb54a3b` 所构建的隔离 Demo／E2E App
- 引入提交：`23a406e28bb6f0c8e049b5880c2314af9d82c110 feat(app): 收敛任务操作与详情编辑`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；仓库只能证明 Git identity，不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

空飞光 composer 的提示文字位于容器上方，而获得焦点后的插入光标出现在下方，中间留下明显空白；输入面也被拉高。用户无法判断实际输入起点，首屏空间被无效占用。共享 `MarkdownEditor` 的其他输入面具有同类漂移风险。

## 时间线

- 2026-08-03 23:41：用户以真实 App 截图报告飞光输入框提示与光标之间存在大段空白。
- 2026-08-04：隔离 E2E 新增空 composer 几何断言，首次稳定判红。
- 2026-08-04：逐层排除原生 inset、点击位置与 clip view 方向后，确认 SwiftUI 外层与原生 editor 使用不同的布局边界。
- 2026-08-04：修复后同一真实 App 症状断言转绿，完整飞光 E2E 的 exercise／restart 结果均为 `ok`。

## 复现与证据

运行 `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`。修复前稳定返回：editor 高 54pt，但 placeholder 与 focused caret 的垂直中点相差 39pt；原生 text view 的 `y=0` 已正确映射到自身顶部，说明不是 TextKit 把光标排到底部。修复前截图为 `artifacts/e2e-idea-capture/ideas-empty-focused.png` 的当轮产物。

## 排除的假设

- 不是 `textContainerInset` 过大：运行值为水平 5pt、垂直 6pt。
- 不是物理点击落点导致：直接把 editor 设为 first responder 与物理点击后的 caret 坐标相同。
- 不是 `NSClipView.isFlipped`：clip view 与 text view 均已 flipped，显式替换 clip view 不改变 39pt 偏移。
- 不是 fixture 偶发：每轮 clean `e2e` profile 均在同一几何位置判红。

## 根因与破坏机制

共享 `MarkdownEditor` 把 placeholder 放在 SwiftUI 外层 overlay 中，却把实际输入交给 `NSViewRepresentable` 内的 `NSTextView`。外层只设 `minHeight`／`maxHeight`，会接受父布局提供的额外高度；原生 editor 仍按自身测量高度呈现。于是 overlay 以扩张后的 SwiftUI 边界定位，caret 以较小的原生边界定位，两者在空飞光 composer 中相差 39pt。

## 根因修复

- placeholder 改为 `MarkdownNSTextView` 自有的被动原生子视图，与 caret 共用 text container inset 和坐标空间。
- 共享 editor 在垂直方向使用自身测量尺寸，不再吸收父布局的无意义剩余高度。
- 飞光 E2E 同时测量原生 editor、可见 surface 与 placeholder／caret 中点，任何一层重新漂移均判红。

## 验证结果

- `scripts/test-notes-ui-contract`：通过。
- `swift test --filter NewTaskDraftParserTests`：11／11 通过。
- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：exercise／verify 均为 `ok`；空 composer surface 与 editor 同为 54pt，placeholder／caret 偏移不超过 6pt。
- `make test-demo-fixture`：通过；一年演示资料中的飞光与 Sticky Note 投影经真实 `.app`、SQLite 和 sidecar 回读对账。
- `make check`：通过，1493 项测试无失败；两项 live iCloud 测试按既有环境约束跳过，其余 lint、format、真实 App、仿真、DMG 与故障案例门禁全部通过。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，约束共享 editor 自测高度、原生 placeholder、可测 surface 与几何断言仍存在。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，在隔离真实 App 中聚焦空飞光 composer，并校验 surface 高度及 placeholder／caret 实际位置。

## 发行与回滚

不触碰 production App 或资料。本轮只使用固定 `e2e`／`demo` profile；若后续回归，停止候选交付并回退本轮 UI 变更，但不能恢复跨坐标系 placeholder。

## 教训与永久约束

输入控件的 placeholder 与 caret 必须由同一个原生布局边界定位。SwiftUI overlay 可以承载装饰，但不能模拟原生 editor 的第一行文字。涉及输入面的验收必须同时测量可见容器与原生 editor，不能只判断控件存在或截图大致可见。

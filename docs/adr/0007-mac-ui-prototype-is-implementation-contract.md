# 真实 Mac App 与设计契约作为 UI 验收基线

**Status**: Accepted

晷迹仍在开发阶段，当前产品实现是唯一版本。归档 HTML 原型只保留设计探索证据，不再作为实现契约、测试 fixture 或视觉回归 oracle。

**Context**

2026-07-05 的 HTML 原型曾用于启动 Mac UI 实现，但 SwiftUI 产品随后在品牌外壳、页面汇总、详情结构、分类管理和烛龙工作空间上持续演进。2026-07-13 的六个详情态诊断中有五个超过原型比较阈值；旧流程还曾通过抬高阈值吸收产品演进。该比较只能量出两个不同设计之间的距离，不能证明当前产品发生了回归。

UI 的行为与领域语义已经由 `docs/design/mac-ui-design-contract.md`、`NoonmarkMacUIContract`、真实 `.app` E2E、Accessibility 标识、日志和持久化探针覆盖。继续把归档原型当 ground truth 会迫使当前实现回退到已经不成立的结构。

**Decision**

- 当前 SwiftUI 实现、用户即时确认和 `docs/design/mac-ui-design-contract.md` 共同定义唯一 UI 要求。
- `NoonmarkMacUIContract` 继续把页面、控件、窗口尺寸、颜色 token、动效、详情栏状态、操作、弹窗和后端能力做成可测试契约。
- UI 改动必须用真实 `.app` 走用户路径并产出截图；涉及数据时同时验证日志和持久化状态。
- 归档 HTML 原型不得进入 CI、release 或默认本地门禁，也不得通过放宽差异阈值来追随产品变化。
- `scripts/test-visual-regression` 只比较显式传入的两张截图，不提供默认 reference。只有用户确认过的真实 App 截图才能成为 reference。
- 当前界面尚未被用户确认前不预先冻结 golden；确认后只建立一套当前 reference，并在有意改变 UI 时同步替换。

**Consequences**

- CI 与 release 继续执行真实 `.app` E2E 并上传截图，但不再动态渲染旧原型作比较。
- UI 回归证据由真实交互、截图、可访问性、日志、SQLite 探针和代码化设计契约共同组成。
- 视觉 golden 的建立是一次明确的产品确认动作，不能由实现者在同一轮改动中自行把 actual 覆盖成 expected。
- 设计探索文件可以帮助理解来源，但不携带运行期兼容义务，也不是产品版本。

**Alternatives Considered**

继续提高旧原型差异阈值：会让门禁越来越宽，并把结构性差异误写成允许的噪声。

每次运行都从当前 App 重新生成 expected：actual 与 expected 来自同一产物，无法检测回归。

立即冻结当前截图：用户尚未完成交互确认，无法证明当前画面已经是可接受的产品基线。

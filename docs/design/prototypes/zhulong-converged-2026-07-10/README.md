# 烛龙统一工作空间历史原型

> 归档于 2026-07-13。本目录只保留 2026-07-10 的交互探索证据；它不是当前产品规格、实现入口、测试数据、验收路径或视觉 oracle。

目录中的 HTML、设计说明和截图记录了 clean-sheet 烛龙在“活简报、一次性规划委托、决策门、Todo diff 与用户确认”上的探索过程。当前唯一产品路径已经落在 SwiftUI `.app`；当前契约以 `docs/design/mac-ui-design-contract.md`、`NoonmarkMacUIContract`、真实 App E2E 运行产物和用户即时确认为准。

本归档不得用于以下用途：

- 驱动当前 UI 实现或复刻旧布局；
- 作为 visual regression reference 或阈值基线；
- 作为运行 fallback、兼容目标或测试 fixture；
- 证明真实 Provider、SQLite、Keychain、Todo 写入或 macOS 交互已经通过。

仓库不再提供该原型的 render、serve 或 prototype acceptance 脚本。需要验证当前烛龙时，使用真实 `.app` 入口与 `scripts/test-e2e`。

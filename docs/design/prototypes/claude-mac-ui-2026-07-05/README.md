# 晷迹 Mac 界面设计原型

本目录保存 Claude Design 在 2026-07-05 产出的 **晷迹 Mac 界面设计原型**。

来源文件：

- 外部来源：`~/WorkSpace/DataVolume/tmp-to-test/晷迹 Mac 界面设计.zip`
- 原始 HTML 已重命名为 `noonmark-mac-prototype.dc.html`，避免中文文件名影响工具链。
- `macos-window.jsx`、`support.js`、`uploads/` 和 `thumbnail.webp` 是原型运行和视觉检查所需文件。

定位：

- 这是早期设计探索材料，不是生产代码、当前版本、测试 fixture 或视觉 oracle。
- 当前 UI 要求以 `docs/design/mac-ui-design-contract.md`、`NoonmarkMacUIContract` 和真实 SwiftUI 运行产物为准。
- 本目录不得进入 CI、release 或默认本地门禁；不得为了贴近本目录而回退当前产品设计。

实施约束：

- 生产 SwiftUI 不直接依赖本目录中的 HTML/JS。
- 本目录只用于追溯设计来源，不承担视觉对照或验收职责。

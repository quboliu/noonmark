# 晷迹 Mac 界面设计原型

本目录保存 Claude Design 在 2026-07-05 产出的 **晷迹 Mac 界面设计原型**。

来源文件：

- 外部来源：`~/WorkSpace/DataVolume/tmp-to-test/晷迹 Mac 界面设计.zip`
- 原始 HTML 已重命名为 `noonmark-mac-prototype.dc.html`，避免中文文件名影响工具链。
- `macos-window.jsx`、`support.js`、`uploads/` 和 `thumbnail.webp` 是原型运行和视觉检查所需文件。

定位：

- 这是设计原型，不是生产代码。
- 原型中的页面、控件、文案、状态、交互和数据含义是当前 Mac 端 UI 的硬标准。
- 后续 SwiftUI 实现不得遗漏、糊弄或暗改原型元素。
- 如果原型暴露出后端领域模型缺口，后端模型和 ADR 必须跟进，而不是降级 UI。

实施约束：

- 生产 SwiftUI 不直接依赖本目录中的 HTML/JS。
- 本目录用于视觉对照、交互盘点和验收基准。
- 对原型文件的任何替换必须保留来源说明，并同步更新设计契约。

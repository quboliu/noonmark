# macOS 双侧栏开关模式调研

- 调研日期：2026-07-19
- 调研对象：晷迹主窗口左侧导航栏与右侧详情栏的显示入口
- 资料边界：Apple、Microsoft、Zed 与 JetBrains 的官方设计指南、产品文档或开发者文档
- 最终决策：采用面板边界控制；左栏收成图标列，右栏完全收起

## 问题与结论

晷迹原本把左栏开关放在空标题栏前端、右栏开关放在最尾端。两个按钮虽然分别对应左右区域，但标题栏缺少标题、搜索或主操作来建立工具栏语法，结果是两个相距很远的视觉孤岛。

用户比较三种可交互 HTML 原型后选择面板边界方案，并补充确认：

- 原生 titlebar 保持纯净，只保留 traffic lights；
- 展开时，开关贴近所控制面板的内侧边界；
- 图标只用两个同向尖括号，不再使用侧栏框图标；
- 左栏收起后保留 `72pt` 图标列，而不是完全隐藏；该宽度仍是一列图标，并让原生绿色 traffic light 与分隔线保持安全间距；
- 右栏仍可完全收起，恢复入口进入页面标题行右端；
- “显示 / View”菜单与快捷键继续作为并行入口。

## 一手资料发现

Apple 将 toolbar 定义为按逻辑区段组织的控制集合，并建议减少分组数量；macOS toolbar 命令还应有菜单路径作为替代入口。[Apple HIG：Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

Apple 对 sidebar 的指导是：macOS App 可以提供显示／隐藏按钮或 View 菜单命令，并要确保隐藏后有可靠的恢复方式。[Apple HIG：Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)

Xcode 把 Navigators 与 Inspectors 控制分置标题栏两端，同时提供菜单和快捷键。[Apple：Configuring the Xcode project window](https://developer.apple.com/documentation/xcode/configuring-the-xcode-project-window) 这套结构适合控制丰富的 IDE toolbar；晷迹的标题栏近乎为空，直接复制会放大两个孤立图标。

VS Code 的 Primary Side Bar 与 Secondary Side Bar 分处内容两侧，并通过 layout controls、View > Appearance 与快捷键提供多条恢复路径。[Microsoft：VS Code Custom Layout](https://code.visualstudio.com/docs/configure/custom-layout) 可借鉴的是直接控制、菜单与快捷键并存；晷迹不需要复制完整的 Panel 和 Customize Layout 系统。

Zed 将 left、right、bottom dock 建模为独立区域，聚焦隐藏面板时会自动打开对应 dock。[Zed：Introducing Zed's new panel system](https://zed.dev/blog/new-panel-system) 它证明入口与面板位置邻近具有清晰的空间语义，但晷迹只有两个稳定栏位，不需要额外永久 dock bar。

JetBrains 通过窗口边缘的 Tool Window Bars 管理大量工具窗。[JetBrains：Menus and toolbars](https://www.jetbrains.com/help/idea/customize-actions-menus-and-toolbars.html) 对晷迹而言，完整工具窗条带会新增过重的视觉容器；只保留一列已有导航图标更合适。

## 方案比较

| 方案 | 视觉噪音 | 一击操作 | 隐藏后恢复 | 与晷迹匹配 |
| --- | ---: | ---: | ---: | ---: |
| 标题栏两端按钮 | 高 | 是 | 好 | 低 |
| 标题栏尾端双段组 | 中 | 是 | 好 | 中 |
| 面板边界控制 | 低 | 是 | 好 | **高** |
| 单一布局菜单 | 低 | 否 | 好 | 中 |

尾端双段组能消除两个视觉孤岛，但仍会让几乎为空的 titlebar 为布局开关长期占位。面板边界控制让按钮与被控制区域形成直接空间关系；左栏保留图标列后，恢复入口、导航能力和当前页状态都不会消失，因此解决了早期方案最主要的发现性风险。

## 最终像素与行为契约

- titlebar 使用原生 `NSWindow` full-size content，不安装空 `NSToolbar`；三栏表面进入原生标题栏区域，不显示品牌、重复标题或栏位开关。
- 左栏完整宽度 `220pt`，可在 `180...320pt` 内拖拽；紧凑宽度固定 `72pt`。
- 左栏完整态显示 `<<`，紧凑态显示 `>>`；紧凑态保留全部导航图标和当前页轻量选中背景，隐藏名称、数量和分组标题。
- 右栏展开态在栏内侧显示 `>>`；收起后在页面标题行右端显示 `<<`。
- 两个尖括号由两枚同向 chevron 组成，图形约 `15pt`；完整 `28×28pt` 矩形都是命中区。
- 静止态无常驻描边、阴影或彩色底；hover 仅使用低对比浅底与发丝线。
- 左右栏独立控制，窗口 frame 不变；菜单、快捷键、任务选中自动展开详情栏等既有路径继续保留。
- 上次拖拽形成的完整左栏宽度必须独立持久化，紧凑态的 `72pt` 不得覆盖它。
- 右栏没有内容时不显示恢复入口；栏位控件的辅助功能名称随动作变化。

## 验证边界

生产实现必须由真实 `.app` 验证，而不是以 HTML 原型作为视觉 oracle。验证至少覆盖：真实鼠标收起／恢复两栏、紧凑导航仍可点击、窗口 frame 稳定、自定义完整栏宽跨重启恢复、右栏内容 gating、View 菜单与快捷键，以及双栏展开和左栏紧凑态截图。

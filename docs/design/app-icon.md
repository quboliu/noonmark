# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**晷迹 02 macOS 图标版（Noonmark 02 macOS Icon）**。它以仓库内的 SVG 为唯一正式视觉源，保留日晷语义，同时按 macOS Dock 的实际显示比例精修主体占比、笔画重量、刻度节奏和颜色关系。

## 品牌语义

- 黑色开口圆弧保留日晷主体，不再使用普通时钟或清单符号。
- 斜向晷针指向右上方，形成 Noonmark 的“标记”动作。
- 橙色日面位于上方，右侧橙色弧与五枚短刻线补足时间语义；三者使用同一暖橙，不再以两套近似橙色制造噪声。
- 128 px 以上由同一 SVG 等比渲染；16／32 pt 使用同一品牌几何的 optical variants，优先保留日晷、晷针和日面的整体轮廓。

## 视觉规格

- 视觉源：[`AppIcon-source.svg`](../../App/NoonmarkMacApp/Resources/AppIcon-source.svg)，`viewBox` 为 `0 0 1024 1024`，不得内嵌 raster image。
- 生成画布：SVG 以 `1024 × 1024` 为设计坐标；发布产物为 PNG／ICNS、sRGB 并保留 alpha。
- macOS 图标体：`824 × 824 px`，位于 `x = 100`、`y = 100`，圆角半径 `188 px`；图标体外保持透明，控制 Dock 中的视觉尺寸。
- 图标内容：完整保留暖白背景、黑色日晷主体、黑色晷针、橙色日面与橙色刻度。黑弧与橙弧在底部保留可见呼吸缝，不能重新堆叠成粗重接头。
- 主符号占画布约 `59% × 61%`，有效符号像素约占画布 `9.0%`；同机 256 px TickTick 图标的取证基准约为 `55.5% × 55.9%` 和 `10.9%`。该基准只用于校准 Dock 视觉量级，不复制其勾选语义或造型。
- 黑色主弧笔画为设计画布的 `51／1024`，橙色弧为 `32／1024`，五枚刻线为 `26／1024`；晷针底座为 `32／1024`，不得重新增重为与主弧竞争的第二个横轴。较旧 raster 版本不再作为兼容基线。
- 视觉单位：圆角白色 app icon tile、日晷主体、晷针、日面与刻度；不额外叠加文字、徽章或替代色块。
- 16 pt optical variant：加粗日晷与晷针，只保留 3 个关键刻度；`16x16` 与 `16x16@2x` 共用该逻辑构图。
- 32 pt optical variant：使用较细相对笔画并保留 5 个刻度；`32x32` 与 `32x32@2x` 共用该逻辑构图。同为 32 个物理像素的 `16x16@2x` 与 `32x32` 不得相同。

## 唯一资产源

[`AppIcon-source.svg`](../../App/NoonmarkMacApp/Resources/AppIcon-source.svg) 是 128 px 以上构图的唯一正式源；[`app-icon-optical-renderer.swift`](../../scripts/app-icon-optical-renderer.swift) 是 16／32 pt optical variants 的程序化矢量源。两者共享相同的品牌几何，生成脚本负责输出同一个 macOS 图标身份。以下均为生成产物，不可单独手改：

- `AppIcon-master.png`
- `AppIcon.iconset/` 的 10 个 macOS 标准尺寸
- `AppIcon.icns`

重新生成与验证：

```bash
make generate-app-icon
make verify-app-icon
```

`make build`、`make check` 与 App 构建入口会 fail-closed 检查母版、PNG、iconset 和 `.icns`。真实 `.app` 与 DMG 验证还会通过 macOS `NSWorkspace` 解析 bundle 图标，并与 1024 px 母版逐像素对账。

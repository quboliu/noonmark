# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**晷迹 01 macOS 图标版（Noonmark 01 macOS Icon）**。它使用最终 logo 资产包中的 `01_icon_logo.png` 原图作为视觉源，并把原图嵌入 macOS 风格的圆角图标体，避免 Dock 中出现满画布方块或视觉尺寸过大的问题。

## 品牌语义

- 黑色开口圆弧保留日晷主体，不再使用普通时钟或清单符号。
- 斜向晷针指向右上方，形成 Noonmark 的“标记”动作。
- 橙色日面位于上方，右侧橙色刻度补足时间语义。
- 128 px 以上完整保留原图视觉；16／32 pt 使用同一品牌几何的 optical variants，优先保留日晷、晷针和日面的整体轮廓。

## 视觉规格

- 视觉源：最终 logo 资产包的 `01_icon_logo.png`，仓库内保存为 `AppIcon-source.png`。
- 生成画布：`1024 × 1024 px`，PNG，sRGB，保留 alpha。
- macOS 图标体：`824 × 824 px`，位于 `x = 100`、`y = 100`，圆角半径 `188 px`；图标体外保持透明，控制 Dock 中的视觉尺寸。
- 图标内容：完整保留 01 原图的白色背景、黑色日晷主体、黑色晷针、橙色日面与橙色刻度。
- 视觉单位：圆角白色 app icon tile、日晷主体、晷针、日面与刻度；不额外叠加文字、徽章或替代色块。
- 16 pt optical variant：加粗日晷与晷针，只保留 3 个关键刻度；`16x16` 与 `16x16@2x` 共用该逻辑构图。
- 32 pt optical variant：使用较细相对笔画并保留 5 个刻度；`32x32` 与 `32x32@2x` 共用该逻辑构图。同为 32 个物理像素的 `16x16@2x` 与 `32x32` 不得相同。

## 唯一资产源

[`AppIcon-source.png`](../../App/NoonmarkMacApp/Resources/AppIcon-source.png) 是 128 px 以上构图的视觉源，来自最终 logo 资产包的 `01_icon_logo.png`；[`app-icon-optical-renderer.swift`](../../scripts/app-icon-optical-renderer.swift) 是 16／32 pt optical variants 的可编辑矢量源。生成脚本负责把两者渲染进同一个 macOS 圆角图标体。以下均为生成产物，不可单独手改：

- `AppIcon-master.png`
- `AppIcon.iconset/` 的 10 个 macOS 标准尺寸
- `AppIcon.icns`

重新生成与验证：

```bash
make generate-app-icon
make verify-app-icon
```

`make build`、`make check` 与 App 构建入口会 fail-closed 检查母版、PNG、iconset 和 `.icns`。真实 `.app` 与 DMG 验证还会通过 macOS `NSWorkspace` 解析 bundle 图标，并与 1024 px 母版逐像素对账。

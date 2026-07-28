# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**墨迹日晷（Noonmark Ink Sundial）**。它以手绘黑金日晷为核心，在保留原始墨迹层次的同时，适配 macOS Dock、Finder 和小尺寸系统界面。

## 品牌语义

- 黑色开口圆弧代表日晷主体；保留真实笔刷的浓淡、毛边和收笔，不改造成普通时钟或清单符号。
- 斜向晷针指向右上方，形成 Noonmark 的“标记”动作。
- 上方金色日面、右侧金色弧和四枚刻线共同表达时间；使用低饱和暖金，不再使用旧版高饱和橙色。
- 暖白图标体提供纸张和器物感，浅色内缘与底部 rim 建立克制的立体层级。
- 128 px 以上由同一高保真 SVG 等比渲染；16／32 pt 使用同一品牌几何的 optical variants，优先保证日晷、晷针和日面的辨识度。

## 视觉规格

- 视觉源：[`AppIcon-source.svg`](../../App/NoonmarkMacApp/Resources/AppIcon-source.svg)，`viewBox` 为 `0 0 1024 1024`，不得内嵌 raster image。
- 生成画布：SVG 以 `1024 × 1024` 为设计坐标；发布产物为 PNG／ICNS、sRGB 并保留 alpha。
- macOS 图标体：有效边界为 `x = 100…924`、`y = 100…924`，圆角半径 `188 px`；图标体外必须透明，不把浏览器预览用的背景或投影烤进 AppIcon。
- 图标内容：完整保留暖白图标体、黑色手绘日晷、黑色晷针、金色日面与金色刻度。图标体内可以使用浅色 rim 和内高光，但不得加入文字、徽章或额外色块。
- 主符号在 1024 px 母版中保持约六成画布占比，并与图标体四周保留稳定留白；不得为了放大墨迹而挤压透明边界。
- 16 pt optical variant：使用简化但加粗的日晷与晷针，只保留 3 个关键刻度；`16x16` 与 `16x16@2x` 共用该逻辑构图。
- 32 pt optical variant：使用较细的相对笔画并保留 4 个刻度；`32x32` 与 `32x32@2x` 共用该逻辑构图。同为 32 个物理像素的 `16x16@2x` 与 `32x32` 不得相同。
- 默认色彩方向：墨黑接近 `#282624`，暖金中心色接近 `#C48D3F`，图标体为暖白；高保真母版允许保留原始笔刷产生的相邻色阶。

## 唯一资产源

[`AppIcon-source.svg`](../../App/NoonmarkMacApp/Resources/AppIcon-source.svg) 是 128 px 以上构图的唯一正式源；[`app-icon-optical-renderer.swift`](../../scripts/app-icon-optical-renderer.swift) 是 16／32 pt optical variants 的程序化矢量源。两者共享同一个黑金日晷身份。以下均为生成产物，不可单独手改：

- `AppIcon-master.png`
- `AppIcon.iconset/` 的 10 个 macOS 标准尺寸
- `AppIcon.icns`

不可变原图 reference 为 [`noonmark-logo-reference.png`](../assets/brand/noonmark-logo-reference.png)，作者工具为 [`vectorize-app-icon-source.py`](../../scripts/vectorize-app-icon-source.py)。PNG 追踪、曲线重建、原图要求和限制记录于 [`png-to-vector-workflow.md`](../engineering/png-to-vector-workflow.md)。

重新生成与验证：

```bash
make generate-app-icon
make verify-app-icon
```

`make build`、`make check` 与 App 构建入口会 fail-closed 检查母版、PNG、iconset 和 `.icns`。真实 `.app` 与 DMG 验证还会通过 macOS `NSWorkspace` 解析 bundle 图标，并与 1024 px 母版逐像素对账。

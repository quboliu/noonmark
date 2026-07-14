# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**晷迹 01（Noonmark 01）**。它采用最终 logo 资产包中的 `01_icon_logo.png` 设计：开口日晷、斜向晷针、橙色日面与右侧刻度共同表达“正午标记”。

## 品牌语义

- 黑色开口圆弧保留日晷主体，不再使用普通时钟或清单符号。
- 斜向晷针指向右上方，形成 Noonmark 的“标记”动作。
- 橙色日面位于上方，右侧橙色刻度补足时间语义。
- 图标不依赖文字或系统字体；小尺寸优先保留日晷、晷针和日面的整体轮廓。

## 视觉规格

- 母版：最终 logo 资产包的 `01_icon_logo.png`，仓库内保存为 `AppIcon-source.png`。
- 生成画布：`1024 × 1024 px`，PNG，sRGB。
- 图标内容：完整保留 01 设计的白色背景、黑色日晷主体、黑色晷针、橙色日面与橙色刻度。
- 视觉单位：日晷主体、晷针、日面与刻度；不额外叠加文字、徽章、描边容器或替代色块。

## 唯一资产源

[`AppIcon-source.png`](../../App/NoonmarkMacApp/Resources/AppIcon-source.png) 是唯一设计来源，来自最终 logo 资产包的 `01_icon_logo.png`。以下均为生成产物，不可单独手改：

- `AppIcon-master.png`
- `AppIcon.iconset/` 的 10 个 macOS 标准尺寸
- `AppIcon.icns`

重新生成与验证：

```bash
make generate-app-icon
make verify-app-icon
```

`make build`、`make check` 与 App 构建入口会 fail-closed 检查母版、PNG、iconset 和 `.icns`。真实 `.app` 与 DMG 验证还会通过 macOS `NSWorkspace` 解析 bundle 图标，并与 1024 px 母版逐像素对账。

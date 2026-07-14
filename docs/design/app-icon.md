# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**晷迹 01 矢量版（Noonmark 01 Vector）**。它以最终 logo 资产包中的 `01_icon_logo.png` 为视觉参考，重新绘制开口日晷、斜向晷针、橙色日面与右侧刻度，作为桌面 App 的高清矢量母版。

## 品牌语义

- 黑色开口圆弧保留日晷主体，不再使用普通时钟或清单符号。
- 斜向晷针指向右上方，形成 Noonmark 的“标记”动作。
- 橙色日面位于上方，右侧橙色刻度补足时间语义。
- 所有主体轮廓、刻度和晷针均为 SVG 几何；小尺寸优先保留日晷、晷针和日面的整体轮廓。

## 视觉规格

- 母版：`AppIcon.svg`，按最终 logo 资产包的 `01_icon_logo.png` 重绘。
- 生成画布：`1024 × 1024 px`，PNG，sRGB。
- 图标内容：保留 01 设计的浅色背景、黑色日晷主体、黑色晷针、橙色日面与橙色刻度。
- 视觉单位：日晷主体、晷针、日面与刻度；不额外叠加文字、徽章、描边容器或替代色块。

## 唯一资产源

[`AppIcon.svg`](../../App/NoonmarkMacApp/Resources/AppIcon.svg) 是唯一可编辑母版。以下均为生成产物，不可单独手改：

- `AppIcon-master.png`
- `AppIcon.iconset/` 的 10 个 macOS 标准尺寸
- `AppIcon.icns`

重新生成与验证：

```bash
make generate-app-icon
make verify-app-icon
```

`make build`、`make check` 与 App 构建入口会 fail-closed 检查母版、PNG、iconset 和 `.icns`。真实 `.app` 与 DMG 验证还会通过 macOS `NSWorkspace` 解析 bundle 图标，并与 1024 px 母版逐像素对账。

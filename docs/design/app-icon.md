# 晷迹 App 图标

晷迹只保留一个正式 App 图标身份：**一体式晷影（Noon Stroke）**。它把正午刻针、当日日面与不可擦除的轨迹合成一个符号，不使用普通时钟、清单、勾选框或烛龙的紫色星芒语言。

## 品牌语义

- 金色竖向刻针表示正午的确定时刻。
- 金色日面表示当天已经形成的承诺边界。
- 右下蓝色负形表示时间经过后留下、不能无痕抹去的轨迹。
- 图标不依赖文字、数字、细描边、纹理或微小装饰，在 16 px 下仍须保留同一轮廓。

## 视觉规格

- 画布：`1024 × 1024 px`，sRGB，保留 alpha。
- 可见图标体：`824 × 824 px`，位于 `x = 100`、`y = 88`，圆角半径 `188 px`；外部透明空间用于与 macOS 系统图标保持一致的视觉尺寸。
- 主色：Noonmark cobalt，由 `#3478E8` 过渡到 `#0B2D79`。
- 强调色：solar gold，由 `#FFE17A` 过渡到 `#E89117`。
- 视觉单位：一个蓝色图标体与一个金色主标记。负形属于主标记本身，不再增加太阳、光芒、轨道终点、文字或徽章。

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

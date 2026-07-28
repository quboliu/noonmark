# PNG 高保真矢量化方法与限制

本文记录晷迹 Logo 从 PNG 到 SVG 的实际处理方法、工具链、验证方式和已知限制。目标是让后续执行者能够复现流程，并避免把“像素外观保真”误称为“恢复原始矢量”。

## 先说结论：PNG 不能真正无损还原成原始矢量

PNG 只保存采样后的像素，不保存原始圆弧、控制点、图层、笔刷轨迹、字体或设计约束。原始矢量在导出 PNG 时已经丢失，因此不存在一种通用算法，能够从 PNG 唯一且无损地恢复原始矢量。

工程中常说的“无损转矢量”可能指三件不同的事：

| 目标 | 能否做到 | 实际含义 |
| --- | --- | --- |
| 原始文件字节无损 | 可以 | 原 PNG 原样保留，使用 SHA-256 对账；这不是矢量化 |
| 源分辨率下视觉近似无损 | 可以接近 | 用大量色块／路径复现原像素，在原尺寸看起来几乎一样 |
| 任意倍率下仍是干净曲线 | 只能重建 | 需要识别语义轮廓并人工修 Bézier 曲线，不可能自动保证与未知原稿完全一致 |

生产 Logo 应优先追求第三种：轮廓正确、节点少、可维护、能在不同尺寸下保持品牌特征。第一种应作为归档依据；第二种适合比对和取色，不宜直接充当长期 canonical Logo。

## 晷迹这次实际采用的流程

### 1. 固化原图

先复制原始 PNG，不做覆盖，并记录尺寸、alpha、色彩空间和摘要：

```bash
file input.png
sips -g pixelWidth -g pixelHeight -g hasAlpha -g profile input.png
shasum -a 256 input.png
```

本次原图为 `1254 × 1254`、8-bit RGB、无 alpha。另生成过 `5016 × 5016` 的 4 倍工作图。放大图只增加采样密度，不会创造原图没有的真实细节，因此不能把它当作“恢复高清原稿”。

晷迹把原图以不可变 reference 纳入仓库：

- 文件：[`docs/assets/brand/noonmark-logo-reference.png`](../assets/brand/noonmark-logo-reference.png)
- SHA-256：`9130bd34e01eb56c5637f28f04acfbc2ac541bf3422467f43796b8fe93d092a3`

正式转换脚本会先核对该摘要，不匹配就 fail-closed，避免用错截图、压缩版或二次缩放版。

### 2. 用 VTracer 生成多个追踪候选

实际工具：

- [VTracer](https://github.com/visioncortex/vtracer)：Rust raster-to-vector 引擎；本地 Python binding 为 `0.6.15`，产物 metadata 中的核心版本为 `0.6.12`。
- Pillow `11.3.0`：检查、缩放和处理 PNG。
- Python 标准库：候选统计、颜色分类、路径筛选和 SVG 组装。

环境安装：

```bash
python3 -m venv .venv
.venv/bin/pip install "vtracer==0.6.15" "pillow==11.3.0"
```

正式流程已经固化在 [`scripts/vectorize-app-icon-source.py`](../../scripts/vectorize-app-icon-source.py)。下面是其中实际使用并在本机执行通过的 spline 候选参数：

```python
import sys

import vtracer

source_path, output_path = sys.argv[1:3]

vtracer.convert_image_to_svg_py(
    image_path=source_path,
    out_path=output_path,
    colormode="color",
    hierarchical="stacked",
    mode="spline",
    filter_speckle=1,
    color_precision=8,
    layer_difference=8,
    corner_threshold=60,
    length_threshold=2.0,
    max_iterations=10,
    splice_threshold=45,
    path_precision=4,
)
```

运行：

```bash
.venv/bin/python scripts/vectorize-app-icon-source.py \
  --input docs/assets/brand/noonmark-logo-reference.png \
  --output /tmp/noonmark-app-icon-source.svg
```

这些参数不是所有图片的万能值：

- `filter_speckle` 越大，越能移除噪点，但也越可能吃掉细小笔触。
- `color_precision` 越高，保留的颜色层次越多，文件也越大。
- `layer_difference` 越小，颜色分层越细；本机 binding 使用 `0` 会触发除零 panic，最低应从 `1` 起试。
- `mode="spline"` 会拟合曲线，适合 Logo；`mode="pixel"` 会忠实保存像素阶梯，只适合作为视觉对照。
- `path_precision` 影响坐标精度和文件大小，不代表真实图像细节。

该 spline 候选共生成 `2,867` 条曲线路径；分离背景、黑色墨迹和金色笔触后，正式 canonical SVG 保留 `1,645` 条曲线路径，并且不含 1×1 方格路径。

本次也生成了 pixel 候选。它在源尺寸最接近原图，但产生约 `157,546` 个 path，其中大量是 1×1 方格，文件约 14 MB。它证明“看起来一样”不等于“得到可维护的矢量”。

### 3. 分离 Logo 符号与背景

原图包含暖白画布、图标体、投影、黑色墨迹和金色刻度。为了让 AppIcon 外部保持透明，[`vectorize-app-icon-source.py`](../../scripts/vectorize-app-icon-source.py) 使用 XML parser 读取 VTracer 中间产物，再按颜色筛选：

- 低亮度、低色差区域归入黑色墨迹。
- 暖色 hue、一定 saturation 且 `red > green > blue` 的区域归入金色。
- 暖白画布和外部投影不进入符号层。

仓库中的实际处理逻辑与产物：

- [`scripts/vectorize-app-icon-source.py`](../../scripts/vectorize-app-icon-source.py)
- [`AppIcon-source.svg`](../../App/NoonmarkMacApp/Resources/AppIcon-source.svg)

随后用 SVG 原生元素重建暖白 tile、rim、内高光、裁剪框和坐标变换。正式 AppIcon 使用 `0 0 1024 1024` 画布，图标体外保持透明。

结构检查同样不能依赖 `<path ` 这种文本拼法。晷迹使用 [`app-icon-svg-structure.py`](../../scripts/app-icon-svg-structure.py) 解析 XML，因此 `<path\n …>`、属性换序和不同空白不会绕过门禁。

### 4. 浏览器与多尺寸视觉检查

SVG 先通过本地 HTTP server 在真实浏览器打开，再检查：

- 原尺寸轮廓和颜色是否接近参考图。
- 4 倍放大后，曲线是否仍平滑，是否暴露像素方格。
- 256／128／64 px 是否保留主体。
- 32／16 px 是否需要单独 optical variant。
- 透明四角、tile 边界和内高光是否正确。

PNG 放大预览可用 `sips`：

```bash
sips -s format png -z 1024 1024 input.svg --out output-1024.png
sips -s format png -z 64 64 input.svg --out output-64.png
```

### 5. 接入 macOS AppIcon 链路

晷迹使用以下入口生成和验证正式资产：

```bash
make generate-app-icon
make verify-app-icon
make build-app
```

验证覆盖：

- canonical SVG 不内嵌 `<image>`。
- canonical SVG 的 XML、viewBox、文件大小、path 数量、path-data 长度和命令复杂度。
- 识别 `M/L`、`H/V` 和相对命令等多种写法的 1×1 像素方格。
- PNG 尺寸、alpha 和 sRGB profile。
- tile 的透明边界和主体占比。
- 黑色／金色符号在大图和 optical variants 中可辨识。
- `iconset`、`ICNS` 与 canonical renderer 一致。
- macOS `NSWorkspace` 从真实 `.app` 解析出的 bundle 图标与母版一致。

### 6. 在干净 checkout 中复现

同一原图、固定 VTracer binding 和固定参数可以重建当前 canonical SVG：

```bash
python3 -m venv .venv
.venv/bin/pip install "vtracer==0.6.15" "pillow==11.3.0"

.venv/bin/python scripts/vectorize-app-icon-source.py \
  --output /tmp/noonmark-app-icon-source.svg

python3 scripts/app-icon-svg-structure.py \
  /tmp/noonmark-app-icon-source.svg
cmp App/NoonmarkMacApp/Resources/AppIcon-source.svg \
  /tmp/noonmark-app-icon-source.svg
```

`cmp` 应无输出并返回 `0`。正式提交后，再用 `make generate-app-icon` 生成 PNG／iconset／ICNS。VTracer 中间候选不需要入库，因为它可以由已提交 reference 和固定脚本重新生成。

## Code review 暴露出的重要教训

第一次正式接入虽然通过了全部图标门禁，也能在目标尺寸呈现认可的外观，但 canonical SVG 中仍有 `58,443` 个 1×1 方格 path。它只是把 raster 像素改写成 SVG path：

- 放大后仍会暴露像素阶梯。
- 9 MB 级源文件不可审阅、不可手工维护。
- `<image>` 检查无法识别这种“等价内嵌 raster”。
- 不能诚实地称为干净的语义矢量。

因此，生产 Logo 的门禁不能只检查“文件扩展名是 `.svg`”或“不含 `<image>`”。还应通过 XML parser 检查 path 数量、重复 unit-square 数量、文件大小、path-data 长度和命令复杂度，并进行 4 倍以上的曲线视觉检查。

可快速取证：

```bash
wc -c output.svg
python3 scripts/app-icon-svg-structure.py output.svg
```

当前门禁上限为：文件 `2,000,000` bytes、`5,000` paths、总 path-data `1,500,000` 字符、`50,000` 条 path 命令、单条 path `100,000` 字符。上限是针对这枚手绘 Logo 的维护性护栏，不是通用 SVG 标准。

## 推荐的生产流程

对于 Logo，推荐以下 hybrid 路线：

1. 原 PNG 只作为不可变 reference，并保存 SHA-256。
2. 使用 VTracer spline 模式生成候选轮廓和取色依据。
3. 在 Affinity Designer、Adobe Illustrator、Figma 或 Inkscape 中人工重绘关键几何。
4. 每条主弧、晷针、日面和刻线使用少量可解释 path；墨迹质感只保留有限、可控的轮廓扰动。
5. 重新构造透明边界、tile 和 optical variants，而不是追踪原图中烤死的背景与投影。
6. 在 4 倍放大、1024、256、64、32 和 16 px 下逐级验收。
7. 最后才生成 PNG、iconset、ICNS 和真实 `.app`。

对于手绘 Logo，不应把所有毛边都删掉。应区分：

- 品牌笔触：有方向、有节奏的收笔和干刷纹理，应保留。
- raster 锯齿：固定在像素网格上的方块边，应删除。
- 压缩／生成噪声：孤立小点和不连续色块，应删除。

## 原图要求

理想输入：

- 最短边至少为最终常用尺寸的 2～4 倍。
- PNG 或 TIFF，无 JPEG 压缩块。
- 主体与背景对比明确。
- 颜色数量可控，最好能提供透明背景版本。
- 文字已转轮廓，或另行提供字体和排版参数。
- 阴影、发光、纸张纹理和 Logo 主体最好能分层提供。
- 没有经过社交平台二次压缩、锐化或截图缩放。

仍可处理但成本较高：

| 原图情况 | 主要问题 | 推荐处理 |
| --- | --- | --- |
| 分辨率低 | 轮廓位置不确定 | 人工重绘，不依赖自动追踪 |
| 有 JPEG 块 | 产生大量假色块 | 先去噪，再减少颜色 |
| 渐变／阴影很多 | path 爆炸或 banding | 用 SVG gradient／filter 重建 |
| 毛笔／水彩纹理 | 自动追踪节点极多 | 保留主轮廓，只抽象关键纹理 |
| 半透明边缘 | 前景色与背景色已混合 | 取得透明原稿，或人工去背 |
| 照片 | 没有明确语义轮廓 | 不适合 Logo 式矢量化 |
| 很小的文字 | 字形细节已丢失 | 重新排版，不追踪像素 |

## 无法突破的限制

- 放大算法不能创造原图没有的信息。
- 自动追踪无法知道某个锯齿是笔刷质感还是像素噪声。
- 同一 PNG 可以对应无数种不同的 Bézier 组合，不存在唯一正确答案。
- 路径越多不代表越高清，只可能代表越接近像素马赛克。
- 复杂渐变、透明叠加和阴影可能在不同 SVG renderer 中表现不同。
- 小尺寸 Logo 不能只靠等比缩小，通常需要 optical variant。
- 若原图的版权、字体授权或生成来源不清楚，矢量化不会消除这些权利问题。

## 交付验收清单

- [ ] 原 PNG、尺寸、profile 与 SHA-256 已记录。
- [ ] SVG 没有内嵌 raster image。
- [ ] 主轮廓由可解释的 Bézier path 构成，不是 unit-square 像素网格。
- [ ] path 数量、重复方格数量和文件大小在可维护范围内。
- [ ] 4 倍放大检查没有像素阶梯。
- [ ] 1024／256／64／32／16 px 均完成视觉检查。
- [ ] 透明边界和色彩空间符合目标平台要求。
- [ ] optical variants 与正式身份一致。
- [ ] 生成资产可由 canonical 源重复生成。
- [ ] 真实 App／浏览器入口已验证，而不是只看编辑器预览。

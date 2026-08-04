# 飞光 Composer 浏览器原型

> PROTOTYPE — 可随时删除，不是生产实现、视觉 oracle、测试 fixture 或资料入口。

## 要回答的问题

飞光的新建、双击原位编辑、发布／保存修改／取消和 Markdown 工具，采用哪一种空间结构最自然、最成熟？

本原型在同一个 Noonmark 桌面壳层内提供三套结构明显不同的方案，通过 `?variant=` 和页面底部切换器比较：

- `A — 安静工作台`：顶部一体化 composer，正文与时间线同轴，推荐基线。
- `B — 底部捕捉坞`：时间线优先，composer 固定在主内容底部。
- `C — 聚焦编辑台`：空闲时压缩、写作时展开为具有清楚模式标题的编辑台。

三套都必须展示：

- 同一 surface 内的 Markdown 正文、`#`／`@`／`Aa`、状态槽和主次动作；
- 好看的 `32pt` 主／次按钮，不使用裸文字动作；
- 空白、有效、保存中、成功、失败状态；
- 双击旧飞光后的原位编辑、保存修改与取消；
- 时间线、可收起详情栏和 Sticky Note 来源导航。

所有资料和 mutation 只存在浏览器内存中，刷新即重置，不读取 SQLite、iCloud 或任何 Noonmark profile。

## 启动

从仓库根目录运行：

```bash
python3 -m http.server 4173 --directory docs/design/prototypes/flylight-composer-2026-08-04
```

然后打开：

```text
http://127.0.0.1:4173/?variant=A&demo=valid
```

可用 `variant=A|B|C` 直接进入三套结构；`demo=valid|failed|editing`
可直接观察有内容、保存失败和旧飞光编辑状态。页面底部也可切换方案与状态。

## 视觉 prompt

- 明亮的 Vercel／Stripe 式桌面工作面，不使用暗色首页。
- 保持 Noonmark 的三栏壳层、紧凑 sidebar、约 `760px` 可读正文宽度和 `280px` detail rail。
- Composer 只使用一个 surface、一个工具区和一个动作区，不叠加卡片、说明块和徽章。
- 主按钮为 accent 填充、白色 `12.5px semibold` 文案、`8px` 圆角、`32px` 高；次按钮为中性 tonal surface、同高、完整命中区。
- 条目正文优先，日期、时间、分类和 Sticky Note 关系为第二层；菜单只在 hover、focus 或 selection 时增强可见度。
- 原型切换器和状态控制使用深色，仅作为明确的 prototype chrome，不属于候选设计。

# 晷迹札记、飞光与 Sticky Note 产品规格

**状态**：已接受，实施中

**日期**：2026-08-04

**风险等级**：P

## 目标与成功标准

晷迹在侧边栏新增与「计划」「轨迹」并列的第三个信息分组「札记」。札记内固定先显示 **Sticky Note**，再显示 **飞光**；原有独立速记能力整体统一为飞光。

成功标准：

- 侧边栏稳定排序为计划 → 轨迹 → 札记；札记内 Sticky Note → 飞光。
- 产品文案、页面标题、全局速记与操作只使用飞光／Flylight，不再使用 Memo、想法或 Ideas。
- 用户可从任意活动飞光条目选择「加入 Sticky Note」，也可从飞光或 Sticky Note 中移出。
- Sticky Note 不复制正文；源条目仍留在飞光时间线，编辑立即同步，删除自动退出精选投影。
- Sticky Note 提供清单流与便签墙两种展示视图；视图切换不改变内容、精选关系或同步事实。
- 飞光继续支持 Markdown、多行共享草稿、双击原位编辑、搜索、分类、回看、全局速记和隐藏墓碑。

## 产品语言与兼容边界

- **札记** 是侧边栏信息分组，不是新的持久化实体。
- **飞光** 是完整的 note-first 来源库；一条活动记录称为 **飞光条目**。
- **Sticky Note** 是飞光条目的精选投影，不是新的内容类型或副本。
- 现有 `IdeaEntry`、`IdeaID`、`idea_entries`、`pinnedAt`、sync payload key 与相关 API 是已发布兼容标识符。本轮只在领域外观与 App intent seam 使用新语言，不迁移 storage 或 wire format；见 ADR 0044、0045。

## 信息架构

侧边栏分组与页面顺序固定为：

1. 计划：Day Todo、任务池、未来计划、重复计划。
2. 轨迹：未完成、已完成、日历、烛龙。
3. 札记：Sticky Note、飞光。

收起侧边栏时保留三个分组之间的单条分隔线，不显示空标题，也不把 Sticky Note 嵌进飞光页面内部。

## 飞光

### 捕获与编辑

- 页面顶部与全局浮窗共用持久化 Markdown composer session。
- `Enter` 换行、`⌘Enter` 保存；关闭、失败与 App 重启不丢草稿。
- 空 composer 基线高 54pt；placeholder 与 caret 使用同一个原生 `NSTextView` 坐标空间。
- `#标签`／`@分组` 分类 scanner 不得误读 Markdown heading、代码、转义字面量、显式链接目标或裸 URL。
- 双击旧飞光正文原位编辑；三点菜单只提供辅助编辑入口。

### 浏览

- 最近集合按创建时间倒序、按自然日分组；所有活动飞光都留在时间线，包括已经加入 Sticky Note 的条目。
- 宽窗为时间线＋右侧详情，窄窗为同一投影的连续流。
- 卡片与详情使用同一个块级 Markdown renderer。
- 搜索、分组／标签过滤与回看继续是互斥主集合，不堆叠多段列表。

### 操作

- 活动飞光提供编辑、删除、加入／移出 Sticky Note。
- 「加入 Sticky Note」只建立精选关系；不得改创建时间、复制正文或把条目移出飞光。
- 删除清空正文并保留同步墓碑，同时清除精选关系。

## Sticky Note

### 内容投影

- 只显示当前仍活动且已被用户选中的飞光条目。
- 按加入 Sticky Note 的时间倒序；相同时间以稳定身份排序。
- 编辑源飞光后，所有 Sticky Note 视图立即读取同一正文。
- 移出后源飞光不变；删除源飞光后 Sticky Note 不得残留幽灵卡片。
- 空状态引导用户前往飞光选择内容，不提供独立新建输入框。

### 展示视图

- **清单流**：稳定可扫读的单列布局，正文优先，保留时间与分类摘要。
- **便签墙**：自适应多列布局，使用独立 presentation container；首版只建立轻量暖色便签基线，不固定未来纸张颜色、尺寸、旋转或自由排布规则。
- 页面提供明确的视图切换操作；选择属于 profile 隔离的本机偏好，不进入 SQLite snapshot、数据包或同步。
- 两种布局复用同一个条目内容组件与操作模型；新增第三种视图不得修改领域实体或精选 mutation。

## 删除与墓碑

- 删除后的飞光立即退出飞光、Sticky Note 与详情，正文清空并留下同步墓碑。
- 侧边栏、札记页面、菜单与任何用户可达 route 都不显示回收站、墓碑数量或恢复操作。
- 底层兼容恢复命令不属于开放产品能力，生产 App 层不提供调用入口。

## 持久化与同步

- 继续使用 `idea_entries.pinned_at` 作为 Sticky Note 精选时间的兼容载体，不新增 schema、不双写。
- 加入、移出、编辑与删除继续通过现有原子 engine mutation、SQLite 事务与 sync outbox。
- LWW／乱序同步不得复活墓碑或已移出的精选关系。
- 展示视图偏好不进入任务数据库、同步或 Provider scope。

## 明确不包含

- 不提供独立 Sticky Note 正文、新建便签、拖拽自由画布、任意旋转、纸张颜色编辑或空间坐标同步。
- 不提供飞光转任务、归档、回收站、恢复、附件、图片、双链、知识图谱或 AI 自动归类。
- 不把飞光或 Sticky Note 投影进 Day Todo、任务池、未来计划、日历或任务统计。

## 风险、回滚与监控

- 风险：旧 `pinnedAt` 与新产品语言不一致。通过 ADR、intent wrapper 和静态文案门禁隔离兼容标识符，禁止生产 UI 再暴露置顶。
- 风险：同一条目在飞光与 Sticky Note 同时出现时出现重复编辑状态。Sticky Note 首版只展示和跳转，唯一 inline editor 仍由飞光持有。
- 风险：便签墙被写死为一种卡片。布局模式、容器和条目内容组件必须拆分，并由两种真实视图验收。
- 回滚：本轮不迁移 schema；若 UI cutover 失败，可回滚页面与文案代码，非生产 profile clean cut 后重建，不处理 production 数据。
- 监控：只记录有界 mutation 结果码和展示模式枚举，不记录正文、分类名、搜索词或其他自由文本。

## 验证

- fast gate：侧边栏三分组顺序、飞光语言、Sticky Note 操作、两种布局 seam、隐藏墓碑与 Markdown contract。
- domain／storage：精选加入／移出、源条目继续出现在飞光、编辑同步、删除清除精选、SQLite round-trip 与 sync 收敛。
- symptom gate：真实 `.app` 物理点击飞光加入 Sticky Note，切换两种展示视图，返回飞光仍可见，重启后关系与视图正确。
- Demo：一年期 fixture 至少包含多条精选飞光，并由同一真实 Demo App 截取 Sticky Note 清单流、便签墙与飞光页面。
- 最终运行 `make check`、隔离真实 App E2E 与 `make test-demo-fixture`；不得启动或读取 production App／资料。

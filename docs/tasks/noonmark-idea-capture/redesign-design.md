# 晷迹札记、飞光与 Sticky Note 重做设计

- Task-ID：`noonmark-idea-capture`
- 等级：P
- 状态：实施中
- 更新：2026-08-04

## 目标与产品骨架

晷迹新增与「计划」「轨迹」并列的第三个侧栏分组「札记」。札记内的固定顺序是：

1. Sticky Note
2. 飞光

飞光是轻量记录的唯一产品名。用户可以先写下内容，再通过搜索、分组、标签和回看重新遇见它。Sticky Note 不是另一套内容库，而是用户从飞光中挑出的少量长期可见条目，用来保留特别的记忆、提醒或警醒。

## 已确认的核心行为

- 飞光编辑支持 Markdown；`Enter` 换行，`⌘Enter` 保存，草稿自动保留。
- 双击旧条目正文立即原位编辑；`⌘Enter` 保存、`Esc` 取消、失焦安全保存，失败时修改留在原处。
- 三点菜单只保留辅助操作，不再是进入编辑的唯一入口。
- 搜索和分类过滤只改变当前投影，不改内容事实。
- 删除形成内部墓碑并从所有用户视图消失；当前不开放回收站或恢复 UI。
- 加入 Sticky Note 不搬走飞光，也不复制正文。飞光仍在原日期分组中；编辑源条目后 Sticky Note 同步更新。
- 从 Sticky Note 移除只清除展示关系；删除源条目则同时从 Sticky Note 消失。

## 领域与兼容边界

`IdeaEntry`、`idea_entries` 和 `pinnedAt` 暂时保留为源码、SQLite 与同步兼容标识。产品界面和 App 意图统一使用飞光与 Sticky Note；不得建立第二份正文，也不得以双写维持两套实体。

`IdeaCollectionProjection` 同时提供：

- `ideas`／`groups`：完整飞光源时间线，包含已经加入 Sticky Note 的条目；
- `pinnedIdeas`：旧字段承载的 Sticky Note 选择投影。

删除继续清空 `pinnedAt`。这个兼容映射不改变同步事实，因此本轮不需要 schema migration；回滚时只需撤回新页面与产品投影，既有资料仍可读取。

## 展示架构

Sticky Note 的内容、选择关系和展示方式分层：

```text
飞光条目（唯一正文）
  └─ Sticky Note 选择关系（是否展示）
       └─ 本机展示偏好
            ├─ 清单流
            └─ 便签墙
```

首版提供清单流与便签墙。两种视图共享 Markdown、时间、分类与操作组件，仅由布局／surface adapter 决定排列和外观。展示偏好保存在 profile 隔离的本机偏好中，不参与领域快照与同步。

未来可以增加纸张颜色、手写感、堆叠、空间看板或更多便签形态；新增展示不得复制正文、改变 Sticky Note 选择关系或产生新的同步实体。

## UI 基调

- 继续使用明亮、克制的 Vercel／Stripe 亮色基调。
- 飞光时间线默认无独立置顶区；日期、字重、留白和单条分隔线负责主要层级。
- composer 空态保持紧凑，placeholder 与光标处于同一个原生坐标空间，不允许再次出现顶部大片假空白。
- 清单流减少容器；便签墙允许轻量纸张 surface，但不得把描边、色块、图标、徽章和说明重复叠加。
- Sticky Note 页面不提供第二套编辑器；双击或操作菜单可回到飞光源条目，保证只有一个编辑事实。

## 演示与验证

年度 Demo 通过真实领域接口生成至少三条 Sticky Note，且每条仍出现在飞光日期分组。真实 `demo` App 必须验证：

- 侧栏分组顺序为计划、轨迹、札记，札记内 Sticky Note 在飞光上方；
- 飞光 composer 几何、Markdown、双击编辑、搜索、回看和隐藏墓碑；
- 加入 Sticky Note 后源条目不离开飞光；
- Sticky Note 清单流和便签墙均渲染相同条目；
- 展示模式切换及跨进程本机偏好；
- 删除后投影和源时间线都不再显示该条目；
- SQLite 的 `pinned_at` 事实与 App 投影一致。

最终门禁包括核心投影单测、静态 UI contract、真实 `.app` E2E、Demo fixture／SQLite 回读，以及完整 `make check`。任何验证只运行 `development`、`e2e`、`demo`、`audit` 或 `dmg-validation` profile，不启动或读取 production。

## 风险、灰度与回滚

- 风险：旧“置顶”语义残留会让条目在飞光中消失。门禁必须断言 Sticky Note 条目仍属于日期分组。
- 风险：两种视图各自实现正文和操作会漂移。所有模式必须复用同一内容与 intent 组件。
- 风险：本机展示偏好污染生产资料。偏好必须依赖签名 bundle profile 的 UserDefaults 隔离。
- 灰度：先在固定年度 Demo 与隔离 E2E 身份验证，再交给用户以 `make run-demo-app` 体验；不迁移、不探测 production。
- 回滚：撤回札记导航、Sticky Note 页面与新 App 投影；不删除数据、不改 schema，旧 `pinnedAt` 资料保持可读。
- 监控：有界诊断只记录 mutation 结果码、展示模式枚举和查询耗时桶，不记录正文、标签、搜索词或路径。

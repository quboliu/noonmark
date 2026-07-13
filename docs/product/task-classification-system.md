# 晷迹任务分类体系重做规格

**状态**：已接受设计，实施中  
**日期**：2026-07-11  
**风险等级**：P 级——跨领域、历史事实、SQLite、多设备同步和全 App UI

## 目标与成功标准

新版任务分类必须提供一个显式可选 **主分类** 和零到多个对等 **标签**，完整覆盖快速捕获、任务详情、任务池分组、跨状态检索、历史轨迹、分类管理和烛龙逐项／批量建议。

成功标准：

- 产品、领域和中文 UI 只使用“分类／主分类”和“标签”，不再显示 `Tag I / II / III`、`Tag` 或 `Label`。
- 主分类单值可选；标签没有主次顺序，也没有任意的三个数量限制。
- 所有任务创建与分类变更原子执行，失败时任务、分类、关系、审计和同步 outbox 全部零增量。
- 当前分类可调整；历史主分类快照和标签快照不可改写，只能追加显式更正。
- 分类库、关系和历史事实从 `AppPreferences` 与 `TaskChain` blob 中拆出，成为独立领域、持久化和同步实体。
- SQLite 与数据包只接受当前分类格式；空库可直接建立，任何非当前格式都 fail-closed。
- 真实 `.app` E2E 与截图、SQLite 探针、同步乱序／并发测试、DMG 安装启动全部通过。

## 非目标

- 首版不允许用户自定义第三种分类类型或任意分类图。
- 首版不引入完整 event sourcing；关系表仍是事实源，变更记录用于白盒、同步和诊断。
- 不提供烛龙后台自动扩张分类库或无人确认写入。
- 不提供旧分类数据的读取、转换、导入、备份恢复或双写路径；现有测试数据直接作废。
- 不用任意字符数、标签数或批次数作为产品语义限制；资源护栏必须来自真实基准并在提交前明确报错。

## 领域模型

### 分类项

```swift
public struct TaskCategory: Codable, Equatable, Sendable, Identifiable
public struct TaskLabel: Codable, Equatable, Sendable, Identifiable

public enum ClassificationLifecycle: String, Codable, Sendable {
    case active
    case archived
    case merged
}
```

主分类与标签使用不同强类型 ID；名称唯一范围分别是 `(category, canonicalKey)` 与 `(label, canonicalKey)`，因此同名主分类和标签可以共存，跨类型合并在编译期和领域层同时拒绝。

每个分类项保存稳定身份、当前名称、规范化 key、颜色、生命周期、创建与更新时间。改名不改变身份；历史名称版本保留用于历史快照与旧名称解析。颜色属于当前展示属性，不作为历史语义快照；改变颜色可以统一改善当前与历史的可读性，但仍生成分类变更记录。

### 当前分类关系

```swift
public struct TaskClassification: Codable, Equatable, Sendable {
    public let chainID: TaskChainID
    public var category: TaskCategoryRelation?
    public var labels: [TaskLabelRelation]
    public var revision: UInt64
}
```

- `category` 至多一个。
- `labels` 在领域上是 Set；序列化和显示使用 canonical key、ID 的确定性顺序，顺序不表达优先级。
- 关系保存来源、用户决定引用、创建时间、更新时间和 revision；替换或移除关系会追加不可覆盖的关系历史。
- active 分类项才能接受新关系；archived 项保留既有关系；merged 项只保留到目标项的可追溯关系。

### 历史分类

每条日轨迹第一次成为历史事实时，必须在同一领域事务中生成一个非空 header，即使当时没有分类或标签：

```swift
public struct TraceClassificationSnapshot: Codable, Equatable, Sendable {
    public let traceID: DayTraceID
    public let capturedAt: Date
    public let category: HistoricalCategoryValue?
    public let labels: [HistoricalLabelValue]
    public let provenance: ClassificationProvenance
}
```

历史值自包含当时的分类 ID、名称和名称版本，不能依赖当前分类库才能显示。日轨迹完成、日结束未完成、延续、变更、回池或废弃时捕获；新生成的活跃／未来轨迹继续读取当前分类，直到自身成为历史。

历史分类更正是 append-only 关系，保存原值、建议更正、理由、来源和时间。历史投影同时提供 original、按时间排列的 corrections 和 effective 解释结果；UI 不得只展示 effective 后隐藏原始事实。

现有产品允许废弃任务链后以同一个 `DayTrace` 身份原地重新启用，因此一条轨迹可能多次跨越“活跃／历史”边界。分类历史必须按生命周期事件追加，而不能只以 `traceID` 保存一个可覆盖快照：每次废弃保留当时事件；重新启用不删除该事件；轨迹后来再次结算时追加新事件。默认历史详情显示与当前轨迹状态对应的最新有效事件，同时提供完整事件链；任何事件均不可删除、覆盖或伪装成用户更正。

### 生命周期与来源

- 从未进入当前关系或关系历史、历史快照及合并关系的分类项可以硬删除。分类变更记录是自包含审计事实，不依赖 live identity 才能解释，因此单纯的创建、改名或归档记录不构成“已使用”；任何曾经建立的任务关系都会通过关系历史永久阻止硬删除。
- 分类管理可以先创建尚未关联任务的分类项；硬删除移除 live identity 和名称版本，但永久保留不含名称占用的最小 ID tombstone。名称可以由新身份重新使用，旧 ID 永不复活。
- 已使用项可以归档、恢复或合并。合并只允许同类型，来源项只有一个目标，合并图必须无环。
- 合并前必须生成完整影响计划；确认后迁移当前关系并去重，历史快照不改写，统计可沿合并关系聚合。
- 变更、复制为新任务默认继承当前主分类和标签并披露来源；延续和回池沿用同一任务链；历史快照永不继承到新任务链。
- 来源至少区分用户直接操作、分类继承、烛龙建议后用户确认和确定性领域动作。同步只是运输方式，不得替换原来源。
- 烛龙来源保存会话、草稿版本、依据和用户决定引用；完整 AI 说明仍归对应 sidecar 会话，Core 保存最小可追溯引用。

## 深 Module Interface

外部 seam 放在 `NoonmarkEngine`，不为唯一 in-process implementation 虚构 protocol：

```swift
public final class NoonmarkEngine {
    public func classification(
        _ query: ClassificationQuery
    ) throws -> ClassificationProjection

    public func prepareClassification(
        _ intent: ClassificationIntent,
        source: ClassificationSource,
        interactionID: UUID,
        now: Date = Date()
    ) throws -> ClassificationPlan

    public func commitClassification(
        _ plan: ClassificationPlan,
        confirmation: ClassificationConfirmation,
        now: Date = Date()
    ) throws -> ClassificationReceipt
}
```

### 查询

查询返回 render-ready 但不依赖 SwiftUI 的投影：任务当前分类、历史 original/corrections/effective、分类库分页、合并影响、快速输入建议和烛龙 review。UI 不自行解析合并链、名称版本、来源或历史更正。

### 准备计划

`ClassificationIntent` 可以包含：

- 新建主分类或标签候选；
- 以完整期望状态调整一条或多条任务链的主分类与标签；
- 改名、改色、归档、恢复、硬删除；
- 同类分类合并；
- 追加历史分类更正。

`ClassificationPlan` 由 Module 生成，调用者不能伪造，至少包含 plan ID、base revision、digest、规范化逐项 diff、受影响任务与历史数量、重复关系、近似重复名称、warnings、blockers 和必要确认类型。用户修改或排除任何项目后必须重新 prepare。

### 确认提交

提交必须检查 revision、digest、interaction ID、确认 authority 和全部引用。stale plan 不能静默 rebase；同一 interaction ID 重试返回同一 receipt。Implementation 在工作副本中建立依赖顺序并全量验证，全部成功后才发布状态和 receipt。

直接用户操作与烛龙批量操作共用 Interface。烛龙只能产生 intent 和计划，不能构造有效 confirmation；用户确认后的 AI 关系与用户直接关系拥有相同保护，来源不产生未来修改权限。

## 快速捕获事务

`#名称` 只表示标签；主分类由显式选择器、当前分类分组上下文或任务详情设置，不能再用第一个 `#` 暗示。

快速捕获必须先完整解析并 prepare，再一次提交：任务链、任务定义、目标 Day Todo／任务池、所有新标签、主分类关系、标签关系、分类变更记录和 sync outbox。重复 `#标签` 可以去重，但 receipt 必须披露；超过三个标签必须全部保存；任何 blocker 或持久化失败都不得留下半成品任务。

## 名称规范化

Core、SQLite、导入和同步必须共用一个版本化 canonical key 算法，数据库只对已计算 key 做二进制唯一约束，不使用 SQLite `NOCASE` 代替 Unicode 规则。

第一版算法要求：

1. 去除首尾 Unicode whitespace；
2. 连续 whitespace 归一为 U+0020；
3. 执行固定版本的兼容正规化与 locale-independent case folding；
4. 保存算法版本和 UTF-8 key；
5. 同类型 key 完全相同属于 blocker；confusable／近似名称只产生可审查 warning。

macOS 实现调用 ICU 的 `unorm2_getNFKCCasefoldInstance`，并把 `u_getUnicodeVersion` 返回值写入算法 ID，例如 `unicode-16.0.0.0-nfkc-casefold-whitespace-v1`。比较键必须使用 `(algorithmVersion, canonicalKey)` 原子对；运行环境 Unicode 版本不同或 payload 只带 key／version 其中之一时 fail-closed，必须经过显式再索引迁移，禁止用当前运行时静默重算后冒充同一算法。

旧名称作为同一身份的 alias 保留，防止改名后另一分类抢占旧名称并令快速输入产生歧义。

## SQLite 与数据包

SQLite 采用本代首个 schema，`PRAGMA user_version = 1`。初始化只允许两种输入：完全空白数据库，或结构与约束精确匹配当前版本的数据库。任何其他非空数据库立即拒绝，不猜测来源、不修改旧表，也不创建转换备份。

当前分类事实表：

- `task_categories`
- `task_labels`
- `classification_name_versions`
- `task_chain_categories`
- `task_chain_label_relations`
- `trace_classification_snapshot_headers`
- `trace_category_snapshots`
- `trace_label_snapshots`
- `trace_classification_corrections`
- `classification_merges`
- `classification_change_records`
- `classification_commits`

保存顺序必须由一个 SQLite `BEGIN IMMEDIATE` 事务覆盖：分类身份与名称版本 → 任务链 → 当前关系 → 历史快照／更正 → 变更记录 → commit／outbox。不得先全量删除分类库和关系再重建。

`NoonmarkSnapshot` 必须显式携带独立 classification state。数据包只有一个当前 envelope，`formatVersion = 1` 为必需整数；日期按 `Date.timeIntervalSinceReferenceDate.bitPattern` 精确编码。缺版本、版本不同、原始 snapshot、缺字段、旧日期编码或完整性不成立一律拒绝。

## Clean-cut 边界

项目尚无用户，既有本地数据全部是可丢弃测试数据。因此本次换代明确不实施兼容：

- 删除上一代分类类型、写 API、表、column、fixture、decoder、source variant 与 UI 入口。
- 不保留 adapter、双写、fallback、一次性 converter、旧库备份或待整理清单。
- 开发机遇到非当前数据库时，由开发者删除测试数据库后重启；App 必须清楚报告拒绝原因，不能静默清空。
- 数据导入只接受当前数据包。测试需要的状态全部由当前公开领域行为重新建立。
- 普通同步 payload 也只接受 canonical current envelope：顶层必须精确为 `formatVersion = 1` 与 `payload`，原始模型 JSON、未知字段、非当前版本及非 canonical bytes 一律拒绝。
- 回滚实现只使用 Git，不在产品中保留反向投影或旧 schema 恢复能力。

## 同步

分类同步不再把上一代分类字段塞入 `AppPreferences` 或 `TaskChain`。普通实体统一使用 byte-canonical、必需 `formatVersion = 1` 的 current envelope；每个分类提交生成 transport-only `ClassificationCommitEnvelope`，携带 typed base/post delta、来源、审计记录、可选用户 receipt 与完整性 digest。`DayTrace` payload 只表达轨迹事实；每条历史分类快照使用唯一 UUID 的 immutable `traceClassificationEvent`，携带自身 revision 与 predecessor。关系表仍是本地事实源。

同步规则：

- 分类身份、当前关系、历史快照、更正和变更记录是首类 record。
- 一个 envelope 在接收端只能全部应用、全部等待依赖或全部进入冲突，不能部分可见。
- TaskChain 或分类身份尚未到达时，完整 wire record 与依赖以 current schema 的 durable pending dependency 落盘；远端下一轮不再返回该 record 时仍须重试。terminal 清理使用本轮 observed token 做事务内 CAS，不能按裸 ID 删除并发写入。
- 一轮下载产生的 snapshot、冲突、durable pending、审计、同步 metadata 与 terminal pending 清理必须在同一个 SQLite 事务中提交；任何失败都回到下载前状态。
- 轨迹 record 必须先于其分类事件到达；事件缺 trace、分类 identity、前驱事件或 revision frontier 时进入 durable waiting。快照事件只允许沿 predecessor append；分叉、循环、identity collision 或改写进入可审查冲突。
- classification state revision 只由已接纳且会推进状态的 change record 与历史快照事件计数得出；远端 record 不能用裸数字直接覆盖本地 revision。
- `changeRecords` 与 `relationHistory` 使用共享 canonical order 插入和验证，设备不得因到达顺序不同而形成不同审计数组。
- 显式依赖按完整 DAG 的传递闭包判断先后；分页暂缺的前驱进入 durable waiting。已经 terminal 拒绝的提交，其因果后代一并以可解释原因拒绝，不能无限等待。
- 同链后继提交从 immutable before／after audit 重放完整 causal frontier：顺序观察到的 heads 可收束，未观察到的并发主分类／标签 present／absent heads 必须全部列为 predecessor。merge source 与 target 都是 item causal barrier。
- 精确 rename no-op 只追加审计与 receipt，不修改分类、不推进 revision、不建立新事实前驱；晚到时不能覆盖后续真实改名，也不能在 hard delete 后复活对象。
- rename 只可与按稳定 item ID 的普通 `setCurrent` 关系写交换；与 merge、lifecycle、hard delete 的并发必须 fail-closed，具有显式前驱的顺序操作则按 DAG 反序到达也能收敛。
- hard delete 释放规范名称后，复用当前名称或任一历史别名的新建提交必须显式依赖释放所有权的 hard-delete commit。
- 不同标签关系独立合并；同一主分类的并发替换、同一分类的并发改名和同源多目标合并产生用户可审查冲突，不能按时间静默选胜者。
- 冲突必须持久化产生冲突的完整 canonical remote record，并校验其 identity；即使远端下一轮不再返回，也要保留用户审查与处理所需的 immutable 证据。
- 历史快照只允许幂等重复；不同内容的同 trace snapshot 属于数据一致性冲突。
- hard delete 需要 tombstone 与已知设备确认边界，防止离线设备把已删除项复活；第一阶段永久保留 tombstone，不在缺少完整设备确认前做 GC。
- SQLite 的 change-record／relation-history sequence 只表达 canonical 展示顺序；事实按 ID 与完整内容 immutable。并发事实需要排到旧事实之前时，事务内无删除重排投影，同 ID 异内容或旧事实缺失拒绝整笔保存。
- Local Folder、iCloud 复用路径与 InMemory transport 对 immutable records 采用 create-or-exact-match；同 ID 不同 identity、metadata、payload 或非当前 canonical file bytes 均保留先到原件并报告 collision。

## Mac UI 像素级实现 Prompt

以下 prompt 是实现和视觉评审的前置契约：

> 在晷迹当前 SwiftUI Mac App 的亮色工作台上实现“分类与标签”，严格保持现有 1320×820 默认窗口、约 240pt 左侧导航、主内容区和约 300pt 右侧详情 rail；背景使用现有 `Theme.panel/panel2`，发丝线使用 `Theme.line`，圆角维持 7–8pt，不新增暗色大面板、重阴影或孤立 Dashboard。任务行先显示一个不带 `#` 的主分类 badge：高度 20pt、水平 padding 8pt、6pt 色点、10.5pt semibold、1px 稍强描边；其后显示最多两个带 `#` 的对等标签 chip，再显示同高 `+N` chip，点击以 popover 展开全部，绝不截断数据。快速新增保持 32pt 输入高度，在尾部加入 24pt“分类”图标入口；输入 `#` 时在输入框下方 overlay 最多六条 28pt 标签建议，新项明确写“新建标签”，归档或已合并命中显示阻塞原因，只有完整事务成功后才清空输入。右侧任务详情把旧 Tag 区拆为 34pt 单选分类 picker 与可自动换行的全部标签区，当前／未来任务可编辑，历史任务显示带“当时”标记的冻结值、现名关联及独立“追加更正”入口。设置页增加“分类与标签”pane：顶部 30pt 主分类／标签／已归档 segmented control、32pt 搜索框、44pt 线性列表行、右侧 300pt inspector；改名和颜色是轻操作，归档、硬删除和合并必须先进入完整影响预览 sheet，sheet 基准约 720×560pt，显示任务数、历史数、去重数、逐项展开和明确确认按钮。所有动效使用 160–220ms ease-in-out，列表、popover 和详情切换保留视觉轨迹；键盘建议支持上下选择、Enter 接受、Esc 关闭；每个移除按钮和 badge 都有目标相关 accessibility label。烛龙批量分类沿用已确认流式会话：左侧烛龙工作、右侧用户决定，before/after 与理由逐项展示，重大批量确认块全宽，确认后在原流中追加 receipt 并平滑滚动。

## UI 行为

- 任务池默认按主分类分组；未分类单独成组。分类标题和 badge 可以点击筛选。
- 分类与标签筛选是组合视图，不改变任务事实；支持未分类／无标签筛选。
- 当前、未来、任务池和未结算任务详情都能编辑当前关系；历史详情只读原快照并允许追加更正。
- 列表 chip 折叠只是展示；详情、popover、搜索和导出始终可访问全部标签。
- 分类管理页提供创建、改名、改色、归档、恢复、硬删除、合并、使用量、当前任务和历史入口。
- 合并、批量操作、历史更正和所有烛龙建议都使用 plan／confirm；轻量单任务关联也经同一 Module prepare／commit，但 UI 可以自动显示短暂保存反馈。
- 烛龙批量草稿按新增标签、移除标签、替换主分类、新建分类项分区，允许逐项修改或排除；摘要不能替代逐项展开。

## 风险、回滚、灰度与监控

### 主要风险

- 历史快照捕获时机遗漏会产生无法补真的历史空洞。
- 分类与任务跨表事务不完整会重现半成品任务。
- 同步乱序或并发会制造悬空关系、静默覆盖或离线复活。
- 巨型 SwiftUI 文件中复制规则会破坏 Module locality。
- 开发机遗留测试数据库会被严格拒绝；错误地静默清空会掩盖 schema 问题，因此只能显式报错并由开发者清理。

### 回滚

- 代码回滚以本次改动前的 Git commit 为唯一边界。
- 当前格式保存事务失败时执行 SQLite rollback，不能留下部分分类事实或 outbox。
- 测试数据无恢复承诺；回滚代码后重新生成对应版本测试数据库。
- 不因回滚需要而保留旧源码、旧表、旧 decoder 或反向投影。

### 灰度

当前没有生产服务或 deployed endpoint，也没有用户数据，不臆造生产灰度。验证分层采用独立空库、当前 schema fixture、双设备同步目录、真实 `.app` 和 DMG 安装环境；每个环境只运行当前路径。

### 监控

- 启动和每次提交后运行轻量分类完整性检查：规范名称唯一、无悬空引用、主分类单值、合并无环、历史快照不可变。
- schema 拒绝、保存事务回滚和完整性失败进入 console，并包含可定位但不泄露正文的原因。
- sync conflicts、pending dependencies、重试和 envelope digest 进入现有同步审计与 console；不能只打印“保存失败”。
- UI 对失败显示具体 blocker，输入和用户选择保留，不以 toast 替代可恢复状态。

## 测试与验证矩阵

### Core

- 一个主分类、零到多个标签、超过三个标签、重复标签去重披露。
- Unicode canonical key、旧 alias、同类冲突、跨类型同名与跨类型合并拒绝。
- stale plan、digest mismatch、幂等 interaction ID、整批 rollback。
- 改名、改色、归档／恢复、硬删除、合并去重／环检测。
- 延续、回池、变更、复制继承；新任务链不复制历史快照。
- 所有历史化状态捕获快照；改当前关系不改历史；更正只追加。
- 用户直接与用户确认 AI 关系保护对等；未确认 AI intent 不可提交。

### Storage 与数据包

- 新 schema 约束与完整 round-trip，不再全量删除重建分类库。
- 空库安装当前 schema；当前库精确打开；任何其他非空 schema fail-closed 且零改动。
- 数据包 current envelope 精确 round-trip；缺 `formatVersion`、版本不同、原始 snapshot 和缺字段全部拒绝。
- 数据包重复 canonical key、悬空关系、非法合并、快照冲突拒绝。

### Sync

- envelope 乱序、分页缺依赖等待与父项到达后重试。
- `setCurrent`、创建、改名、生命周期、合并与硬删除共用唯一 typed commit envelope；精确 no-op 保留审计但不推进 revision。
- item 因果关系使用真正建立该事实的前驱 commit ID；缺前驱时跨空 fetch 与进程重启持久等待，不能以全局 revision 猜测因果。
- 完整依赖 DAG 的传递先后、循环先于分叉判定、terminal 拒绝后代闭包，以及 hard-delete 后历史别名复用乱序均有确定性测试。
- 两个并发标签 heads 后的 C 提交携带双 predecessor；分页只到 B+C 时 C durable waiting，A 到达后六种排列均收敛。
- category／label 的 merge source／target 与 rename 并发全排列 fail-closed；合法 merge→rename target 反序到达按显式前驱收敛。
- 两设备修改不同标签不互相覆盖；并发主分类、改名和合并形成冲突。
- 历史快照幂等、内容冲突 fail-closed；hard-delete tombstone 防复活。
- 本地提交成功但网络离线仍保留 outbox；outbox 写入失败则本地事务回滚。
- journal CAS 拒绝只差 sub-millisecond 日期 bit 的同 ID 记录；下载事务任一 pending／conflict／audit／metadata 写入失败时，snapshot 与全部同步状态保持下载前原值。
- 冲突跨重启后仍可读取并验证完整 remote record，不依赖远端再次发送。
- canonical audit 前插经过真实 Sync merge 与两阶段 SQLite 保存后完整 round-trip；sequence 重排、change-record collision 与 relation-history collision 都验证事务回滚且不删除历史。
- 两类 immutable record 的 exact replay、cross-type ID collision、多个 transport actor 并发发布与非 canonical 文件拒绝均有测试；普通 current record 覆盖行为保持。

### 真实 App

- 键鼠输入超过三个标签，真实列表显示 `+N`，详情和重启后保留全部。
- 重复标签、无效名称、持久化失败后无半成品任务。
- 任务池、今日、未来、未完成、已完成、日历和排期选择器一致展示。
- 当前分类调整与历史快照并列验证；历史更正保留 original。
- 长滚动分类管理、搜索、归档、合并预览、过期计划和键盘／无障碍路径。
- 烛龙逐项排除、用户修订、批量确认、整批失败回滚和事件历史。
- 没有 frontend-verify skill 时，用真实 `.app` 分类场景截图、交互断言、SQLite 探针、console 和 DMG 安装启动补齐；归档 HTML 原型不得作为分类 UI 的 ground truth。

## Cutover 完成条件

- 运行期源码、schema、测试 fixture 与产品 UI 中不存在上一代分类类型、三槽关系、旧表或旧写方法。
- `make check`、分类 deterministic simulation、真实 `.app` E2E、当前 schema 探针、双设备同步测试、DMG 打包及安装启动全部通过。
- 当前分类路径是唯一读写入口，不存在双重事实源、兼容 decoder、migration 或 fallback。

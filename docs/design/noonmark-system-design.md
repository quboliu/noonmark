# 晷迹（Noonmark）完整系统设计

> 文档性质：根据当前成品反向还原的 As-built 系统设计
>
> 适用对象：产品负责人、研发人员、代码审阅者，以及需要在面试中完整介绍本项目的人
>
> 当前基线：`main` 分支，提交 `42b0d97`
>
> 编写日期：2026-07-25
>
> 文档语言：新加坡中文

## 0. 如何阅读本文

通常，系统设计文档先于代码产生；晷迹当前的情况相反：产品、领域模型、Mac App、SQLite、同步、烛龙和测试体系已经形成，本文再根据当前成品把它们还原成一份统一设计。

因此，本文遵循以下事实优先级：

1. 当前源码与真实运行产物；
2. 已接受且未被后续决策取代的 ADR；
3. 当前产品与领域文档；
4. 已归档原型和历史方案。

如果早期文档与当前源码冲突，本文描述当前源码，并在“关键架构决策与取舍”章节解释变化。本文不会把规划中的 S3、WebDAV、在线优先后端、Developer ID notarization 或非 Apple 客户端说成已经完成。

阅读建议：

- 15 分钟总览：阅读第 1、2、5、6、18 节。
- 60 分钟理解系统：继续阅读第 7、8、10、11、12、14、16、19 节。
- 准备技术面试：重点阅读第 1、6、7、11、12、16、18、19、20 节。
- 维护代码：阅读第 6 至 17 节及附录的源码索引。
- 讨论产品语义：以根目录 `CONTEXT.md` 为领域语言权威。

---

## 1. 执行摘要

晷迹是一款围绕“每日任务轨迹”和“每日复盘”设计的 macOS 原生 Todo 应用。它解决的不是“把事项打勾”这一单点问题，而是：

- 一件任务跨日期推进时，怎样保留真实历史；
- 今日未完成、主动延期、任务变更和回到任务池怎样保持不同语义；
- 用户怎样知道任务当前在哪里，以及它为什么出现在这里；
- 离线和多设备环境下，怎样避免旧记录复活或历史被覆盖；
- AI 怎样提供帮助，又把无需逐次确认的权力限制在“新任务自动分类”这一条窄路径。

系统采用 Apple-first、local-first、模块化单体架构：

```text
macOS 原生 App
├── AppKit：应用、窗口、菜单、分栏、原生文本编辑、系统面板
├── SwiftUI：页面、列表、详情、设置与烛龙工作空间
├── Combine：主界面可观察状态
├── Swift Concurrency：Provider、同步、后台工作与取消
├── NoonmarkCore：任务轨迹、生命周期、分类与领域不变量
├── SQLite：本机任务事实、同步流水与自动分类工作
├── NoonmarkSync：同步 record、合并、冲突与 transport seam
├── CloudKit / iCloud Drive：可替换的同步 adapter
├── NoonmarkAI：Provider 中立的模型调用与提示词
└── NoonmarkZhulong：加密会话、授权、产物、Todo diff 与恢复
```

核心架构判断：

- 它不是 Electron、WebView、Flutter 或跨平台 UI。
- 它不是完整 event sourcing；关系事实和当前状态保存在 SQLite，append-only 流水用于历史、审计和同步。
- 它不是以云端为唯一事实源；本机 SQLite 是当前 local-first 模式的主要事实源。
- 除新任务自动分类这一窄授权例外，AI 产出的 Todo 内容和生命周期变更都须用户确认；Provider 本身不直接持有任务写接口。
- 它没有第三方 Swift Package runtime 依赖；主要依赖 Apple 系统框架和系统 `sqlite3`。

### 1.1 术语与心智模型

本文先固定以下词义，避免把产品页面、领域对象和持久化实现混在一起：

| 术语 | 本文含义 |
|---|---|
| local-first | 用户先在本机完成读写；SQLite 是本机耐久事实，云端是可选复制与合并渠道，不是每次操作的前置依赖 |
| Day | 一个 Gregorian 自然日的领域对象，保存锁定状态与每日复盘 |
| Day Todo | 围绕某个 Day 展示和操作当日任务的产品集合／页面，不是另一张独立数据表 |
| TaskChain | “同一件事”的稳定身份；跨日、延期、延续和回池时保持不变 |
| TaskDefinition | 某条任务链的标题、描述和计划子任务版本；当前实现是任务定义／计划草稿，不等同于领域文档规划的“承诺快照” |
| DayTrace | 一条任务链在某个自然日留下的执行事实 |
| current relation | 可以随当前计划变化的关系，例如任务链目前位于任务池或某个 Day |
| immutable fact | 一旦形成便不能被同 ID 异内容覆盖的历史事实；更正要追加新事实 |
| snapshot | 某一时刻完整、通过领域校验的 `NoonmarkEngine` 状态 |
| journal / outbox | 与本地 mutation 同事务写入、供同步或恢复继续处理的耐久流水 |
| Module | 对外接口小、内部实现强，能隐藏大量领域复杂度的代码单元 |
| interface | 调用者依赖的操作与数据契约 |
| seam | 允许实现发生真实变化的位置，例如同一同步接口连接 CloudKit 或本地文件夹 |
| adapter | 把外部系统或平台能力翻译成 seam 所需接口的实现 |
| canonical | 同一语义只有一种确定字节表达，便于摘要、幂等和跨设备比较 |
| digest | 对 canonical bytes 计算的摘要，用于绑定版本和检查身份 |
| tombstone | 删除后留下的最小身份事实，用来阻止旧 ID 复活 |
| durable pending | 因依赖尚未到达而不能应用、但已持久保存等待重试的远端记录 |
| sidecar | 与主 SQLite 分开的 AES-GCM 加密烛龙文件仓库 |
| artifact | Provider 返回并通过结构校验的对话产物，还不是已执行的 Todo 写入 |
| Todo diff | 从 artifact 得出的、用户可审阅编辑并绑定当前 snapshot 的候选变更 |

最小心智模型是：

```text
TaskChain：它是谁
TaskDefinition：现在如何描述／计划它
DayTrace：某一天实际发生了什么
SQLite：本机耐久事实
NoonmarkEngine：内存中的校验后工作快照
SyncRecord：跨设备复制和合并的领域记录
Sidecar：与 Todo 主事实分开的 AI 高敏感上下文
```

---

## 2. 产品问题与设计目标

### 2.1 普通 Todo 模型的不足

传统 Todo 通常只有：

```text
Todo -> Doing -> Done
```

这种模型难以回答：

- 任务星期一未完成，星期二继续后，星期一应显示什么？
- 用户星期一主动延期到星期三，是否应该被统计为星期一“未完成”？
- 任务范围发生变化时，是改标题，还是形成一件新任务？
- 任务回到任务池后，旧日期的记录是否应该消失？
- 一条任务在多设备被并发修改时，哪一部分可以覆盖，哪一部分必须冲突？

晷迹把“当前计划”和“历史事实”分开，通过任务链、任务定义、日轨迹和显式关系回答这些问题。

### 2.2 产品目标

系统的主要目标是：

1. 快速捕获必须即时、离线可用，不依赖账号、网络或 AI。
2. 每个自然日都有真实、可解释的 Day Todo。
3. 任务跨日、延期、回池、变更和废弃后仍保留可追溯轨迹。
4. 历史事实不能被普通编辑、撤销或同步静默覆盖。
5. 同一任务链必须有唯一、可解释的当前位置。
6. 多设备同步必须复用同一套领域合并规则。
7. AI 是旁路能力；没有 Provider 时核心 Todo 完整可用。
8. AI Todo 内容与生命周期写入必须经过结构验证、版本绑定和明确授权；新任务自动分类是唯一无需逐次确认的受限例外。
9. 用户数据、Provider 凭证和烛龙高敏感数据必须分层保护。
10. 发布结论必须来自真实 `.app`、持久化和安装产物，而不只是单元测试。

### 2.3 非目标

当前系统不追求：

- Web、Windows、Android 共用 UI 代码；
- 完整 event sourcing；
- 在线账号系统或中心后端；
- 多人协作；
- AI 无人值守修改任务内容或生命周期；已授权的新任务自动分类除外；
- 直接同步 SQLite 文件；
- 兼容未发布开发版本的旧数据库和旧 sidecar；
- 用 AI 生成一个不可解释的“生产力分数”。

---

## 3. 需求与质量属性

### 3.1 功能需求

核心清单：

- Day Todo 快速新增、完成、延期、回池、变更和废弃；
- 任务池创建、编辑、排期和删除未排期新任务；
- 未来计划查看与改期；
- 未完成池按任务链聚合，并发起延续或重新启用；
- 已完成池按完成日轨迹展示任务及子任务记录；
- 日历月视图及选中日分析；
- 每日复盘；
- 描述、附言、计划子任务和执行子任务；
- 主分组与多标签；
- 搜索、快捷录入、菜单和键盘操作；
- 中文与 English；
- 冷灰与微暖纸感主题。

数据与同步：

- SQLite 本地持久化；
- canonical JSON 数据包导入导出；
- iCloud Drive / CloudKit / 本地文件夹同步；
- 同步冲突、durable pending、审计和结果统计；
- 手动与自动同步模式。

AI：

- OpenAI-compatible Provider 配置和连接测试；
- 流式对话；
- 任务成形、每日复盘、任务池分析等对话产物；
- 用户可停止正在进行的 Provider 生成；
- 新任务后台自动分组和标签；
- 加密会话、授权、事件历史和应用回执。

### 3.2 关键质量属性

| 属性 | 设计响应 |
|---|---|
| 离线可用 | 核心领域与 SQLite 不依赖网络或 Provider |
| 数据完整性 | 领域校验、SQLite 约束、事务、schema fingerprint、回读校验 |
| 历史真实性 | 日轨迹和分类历史采用不可覆盖／append-only 事实 |
| 可恢复性 | 原子写、应用 journal、启动恢复、数据包和 DMG 安装验证 |
| 同步安全 | 稳定 ID、canonical record、因果依赖、冲突持久化、fail-closed |
| 隐私 | 最小 Provider scope、Keychain、AES-GCM sidecar、普通数据包排除 sidecar |
| 可测试性 | 领域接口 seam、transport adapter、真实 App E2E、SQLite 探针 |
| 原生体验 | AppKit 生命周期和桌面能力，SwiftUI 主界面，NSTextView 编辑 |
| 可解释性 | 任务轨迹、同步结果、AI evidence、授权记录和应用回执 |
| 可演进性 | 模块化 SwiftPM targets；跨平台可复用领域语义、schema、算法规格和测试向量 |

### 3.3 Fail-closed 原则

以下情况系统选择拒绝，而不是猜测或降级：

- 数据库不是空库，也不是当前完整 schema；
- 数据包版本或 canonical 结构不匹配；
- 同步 record 缺少前驱、引用断裂或 immutable identity 冲突；
- 烛龙 sidecar 密钥、格式或完整性校验失败；
- AI 结构化产物不符合 schema；
- Provider 返回的任务池分析引用了发送范围外的任务；
- CloudKit 缺少正确签名、entitlement 或账号条件；
- E2E 被启用但真实依赖不可用。

### 3.4 规模假设与性能边界

当前成品面向单用户、少量个人设备和个人 Todo 数据集，不是多人协作服务。仓库尚未建立正式性能 SLO、10 万任务 benchmark、长期 sync record compaction 或 Provider 成本预算，因此本文不虚构“毫秒级”承诺。

当前实现特征：

- App 启动把完整 `NoonmarkSnapshot` 读入 `NoonmarkEngine`，主要页面从内存投影；
- 搜索建立本机内存索引，单次最多返回 50 个结果；
- SQLite 为日期／优先级、subtask lineage、sync journal、pending、conflict 和自动分类队列建立针对性 index；
- 本地 mutation 采用短 `BEGIN IMMEDIATE` transaction；
- 同步底层每批默认 100 条，但一次用户操作循环到队列清空；
- Provider scope 有字段级限制，但尚未形成统一 token、费用和超时预算；
- 没有证据证明当前 full-snapshot 架构在 10 万级任务、数年历史或大规模同步积压下仍满足交互目标。

发布前建议建立并固化以下预算：冷启动到可操作、快速录入提交、万级搜索、月历投影、1 万 pending record 同步、sidecar 解密加载、Provider 首 token 与总费用。若 full snapshot 或 record 累积成为瓶颈，再以测量结果决定 lazy loading、分页、增量投影或 compaction，不应预先引入一套没有证据的复杂架构。

---

## 4. 技术栈

### 4.1 平台与工具链

| 项目 | 当前选择 |
|---|---|
| 语言 | Swift |
| Package manifest | Swift Tools 6.0 |
| 当前开发编译器 | Apple Swift 6.2.3 |
| 当前 Xcode | Xcode 26.2 |
| 最低系统 | macOS 14 |
| 构建系统 | Swift Package Manager |
| App 形态 | SwiftPM executable 手工组装 `.app` |
| UI | AppKit + SwiftUI |
| 状态 | Combine `ObservableObject` / `@Published` |
| 异步 | Swift Concurrency |
| 本地数据库 | 系统 `sqlite3`，直接 C interface |
| 网络 | Foundation `URLSession` |
| 云同步 | CloudKit `CKSyncEngine`、iCloud Drive |
| 加密 | CryptoKit AES-GCM |
| 凭证 | Security.framework Keychain |
| 测试 | XCTest 为主、少量 Swift Testing、真实 App E2E |
| 质量工具 | SwiftLint、SwiftFormat |
| 打包 | codesign、hdiutil、DMG |

### 4.2 没有采用的技术

- 没有 Core Data、SwiftData、Realm 或 GRDB。
- 没有 TCA、RxSwift 或第三方依赖注入框架。
- 没有 OpenAI 官方 SDK。
- 没有 Electron、Tauri、Flutter 或 React Native。
- 没有 Docker、后端服务或生产 deployed endpoint。
- 没有标准 Xcode App project 作为构建事实源。

### 4.3 构建架构限制

当前构建脚本从本机 SwiftPM 产物组装应用，没有 `lipo` 或双架构流水。因此在当前 Apple Silicon 环境中默认输出 `arm64`，不是 universal binary。最低系统声明为 macOS 14。

---

## 5. 系统上下文

### 5.1 外部参与者

```text
                         ┌──────────────────────┐
                         │ OpenAI-compatible LLM │
                         └──────────▲───────────┘
                                    │ HTTPS / loopback HTTP
                                    │
┌──────────┐     原生交互     ┌──────┴───────┐
│ macOS 用户├───────────────►│ Noonmark.app │
└──────────┘                 └───┬───────┬──┘
                                 │       │
                    SQLite / files│       │CloudKit / iCloud Drive
                                 ▼       ▼
                         ┌──────────┐  ┌──────────┐
                         │ 本机磁盘  │  │ Apple 云 │
                         └──────────┘  └──────────┘
```

### 5.2 信任划分

| 区域 | 内容 | 信任级别 |
|---|---|---|
| 核心 Todo 数据库 | 任务、日轨迹、分类、复盘、同步流水 | 本机主要事实 |
| UserDefaults | 非敏感 Provider 指针、窗口和本机偏好 | 可重建配置 |
| Keychain | Provider API Key、sidecar 加密密钥 | 高敏感 |
| 烛龙 sidecar | 会话、记忆、产物、发送记录 | 高敏感、加密 |
| 同步仓库 | canonical sync records 和索引 | 不可信输入，合并前验证 |
| AI Provider | 用户明确授权发送的数据 | 外部接收方 |

### 5.3 无后端设计的影响

优点：

- 启动快、离线完整、部署简单；
- 用户不需要账号；
- 核心数据不必先上传服务器；
- 领域逻辑可在本机确定性执行。

代价：

- 多设备并发合并必须由客户端处理；
- CloudKit 签名和真实账号环境成为验证难点；
- 无中心顺序器，必须保留因果前驱、冲突和 durable pending；
- AI Provider 配置和费用由用户自己承担。

---

## 6. 模块架构

### 6.1 模块依赖图

```text
NoonmarkMacApp
├── NoonmarkCore
├── NoonmarkDayContext ─────► NoonmarkCore
├── NoonmarkMacRuntime ─────► NoonmarkCore + NoonmarkDayContext
├── NoonmarkStorage ────────► NoonmarkCore + NoonmarkSync + sqlite3
├── NoonmarkSync ───────────► NoonmarkCore + CloudKit + Security
├── NoonmarkAI ─────────────► NoonmarkCore
├── NoonmarkZhulong ────────► NoonmarkCore + Security
├── NoonmarkZhulongAI ──────► NoonmarkAI + NoonmarkZhulong
├── NoonmarkMacUIContract
├── NoonmarkMacE2ESupport
└── NoonmarkDemoSupport ────► NoonmarkCore
```

### 6.2 模块职责

#### NoonmarkCore

系统最重要的深 Module。

接口向调用者提供：

- 创建、排期、完成、延期、延续、回池、变更、废弃等领域操作；
- Day Todo、任务池、未来计划、未完成池、已完成池和日历投影；
- snapshot 和完整性验证；
- 分类查询、计划、确认与提交；
- 有限撤销所需的领域补偿。

实现隐藏：

- 状态转换条件；
- 唯一活跃轨迹；
- 任务链和变更拓扑；
- 子任务 lineage；
- 进度下限；
- 分类 revision、digest 和审计；
- 历史不可改写规则。

删除该模块会让复杂度扩散到 UI、存储、同步和 AI，因此它提供了高 leverage 和高 locality。

#### NoonmarkDayContext

定义自然日，而不是让各页面直接调用 `Date()`：

- Gregorian civil calendar；
- 当前自然日、时区和 instant；
- 日期变化观察；
- 测试可注入固定环境。

它建立“当前是哪一天”的唯一 seam，避免 UI、同步和日结束分别计算出不同答案。

#### NoonmarkMacRuntime

承载可独立测试的 Mac presentation 和 runtime policy：

- 日期格式和日历网格；
- workspace selection；
- 页面排序和分组偏好；
- 搜索索引；
- 日切协调；
- 烛龙和任务池分析 presentation；
- 窗口状态及本机偏好 repository。

#### NoonmarkStorage

负责：

- SQLite schema 安装和精确验证；
- `NoonmarkEngine` snapshot 保存和读取；
- 任务事实与同步 outbox 同事务提交；
- 自动分类 durable job；
- 同步上传、下载和本地协调；
- 数据包 encode/decode；
- 数据根单写者 lease。

#### NoonmarkSync

同步规则和 transport seam：

- `SyncRecord`；
- record mapper；
- merge engine；
- conflict；
- causal dependency；
- snapshot materialization；
- Local Folder、iCloud Drive、CloudKit 和 mock adapter。

CloudKit 只负责远端交互，不拥有领域合并规则。

这里所说的“可跨平台复用”需要收窄理解：可复用的是领域语义、canonical schema、merge algorithm specification 和测试向量，不是当前 Swift binary 或整个 `NoonmarkSync` target。该 target 当前仍直接连接 CloudKit 和 Security 等 Apple 框架；Windows 端需要按相同契约重写实现。

#### NoonmarkAI

Provider seam：

- Provider 配置和健康状态；
- OpenAI-compatible adapter；
- prompt 构建；
- local insight；
- 自动分类请求和严格响应 contract。

#### NoonmarkZhulong

烛龙领域与安全模块：

- 会话和授权；
- Provider run 记录；
- 对话产物；
- Todo diff 与一次性写入授权；
- 记忆和每日收尾；
- 加密 persistence；
- Engine、Session 和 Journal 的跨存储恢复。

#### NoonmarkZhulongAI

把通用 Provider 接入烛龙领域，不让 `NoonmarkZhulong` 依赖具体 HTTP 实现。

#### NoonmarkMacApp

composition root 和 Mac adapter：

- 创建各模块；
- AppKit 生命周期；
- SwiftUI 页面；
- `NoonmarkStore`；
- 系统窗口、菜单和文件面板；
- 把用户动作翻译为领域调用；
- 把结果投影为 UI。

### 6.3 主要 seam 和 adapter

| Seam | Adapter |
|---|---|
| AI Provider | OpenAICompatibleProvider、测试 Provider |
| SyncRecordTransport | CloudKit、iCloud Drive、Local Folder、Mock |
| ZhulongSessionRepository | AES-GCM 加密文件 repository |
| ZhulongMemoryRepository | AES-GCM 加密 memory repository |
| 自然日环境 | 系统环境、固定 E2E 环境 |
| 工作区状态 | UserDefaults repository、测试隔离 repository |

表中的 seam 均有生产 adapter 与测试替身，或至少两个真实 transport 实现。AppKit shell 与 SwiftUI content 是职责分工，不冒充拥有多 adapter 的抽象 seam。

### 6.4 事实源与一次本地 mutation

“谁是事实源”取决于状态种类：

| 状态 | 耐久权威 | 内存投影／缓存 | 修改者 |
|---|---|---|---|
| Todo 领域事实 | 本机 SQLite | `NoonmarkEngine` | Core 产生候选状态，Storage 原子保存 |
| 页面、selection、栏位状态 | `NoonmarkStore`；部分偏好进入 UserDefaults | SwiftUI / AppKit view | MainActor 上的 Store |
| 远端同步记录 | 所选 transport 的 record repository | 本机 sync metadata、pending、conflict | Sync coordinator |
| 烛龙会话、授权与产物 | 加密 sidecar | Zhulong workspace | Zhulong coordinator |
| Provider API Key | Keychain | 单次请求解析结果 | Provider 配置流程 |

普通用户动作的完整顺序是：

```text
用户动作
  ↓ MainActor
NoonmarkStore 复制当前 snapshot，建立候选 NoonmarkEngine
  ↓
NoonmarkCore 在候选 engine 上执行领域操作并校验
  ↓
SQLite repository 在 BEGIN IMMEDIATE 中保存事实、outbox 与关联工作
  ↓ 成功
Store.engine 替换为候选 engine
  ↓ @Published
SwiftUI / AppKit 投影刷新
```

若 repository 失败，候选 engine 不发布，UI 继续显示上一个已持久化状态。这是“SQLite 为耐久事实源、Engine 为内存工作快照”的准确含义。

### 6.5 运行时与并发模型

`NoonmarkStore` 标记为 `@MainActor`，因此用户 mutation、页面 selection、日切发布、同步结果回装和 Provider presentation 都在一个 UI actor 上排序。后台能力的责任分配如下：

| 工作 | 所有者与串行化 | 取消／回装 |
|---|---|---|
| 普通 Todo mutation | MainActor Store；SQLite 使用 `BEGIN IMMEDIATE` | 保存成功后才替换 `engine` |
| 自动分类 | Store 持有 worker、backlog decision 与 retry Task；job 在 SQLite 耐久 claim | 配置变化、导入和销毁时取消；结果回到 MainActor 并重验 fences |
| 手动／自动同步 | Store 持有 automation Task；transport 为 actor | 下载在独立 SQLite transaction 合并，完成后由 MainActor reload |
| CloudKit session | `CloudKitSyncEngineTransport` 与 persistence 为 actor | 账号检查和 engine callbacks 受专用访问 gate 约束 |
| 烛龙 Provider | Store 持有唯一生成 Task；`ZhulongProviderOrchestrator` 为 actor | 用户停止时取消网络 stream，再由 MainActor 保存终态 |
| sidecar commit | coordinator 编排；文件 transaction lock 使用 `NSLock` | journal 保留到 Engine 与 Session 都可证明完成 |

SQLite repository 本身不是 actor。当前安全性来自四层组合：生产数据根的跨进程单写者 lease、MainActor 上的用户写入编排、后台用例自己的 operation gate，以及 SQLite `BEGIN IMMEDIATE` 事务。同步使用独立连接写入后，不把共享可变 `NoonmarkEngine` 跨 actor 传递，而是保存／重载 snapshot，再在 MainActor 发布。

Swift 6 的 actor 和 `Sendable` 检查保护异步接口，但这不是“所有类型天然线程安全”的声明；新增后台写入口时仍须接入现有 gate 和事务协议，不能直接并发调用 repository。

---

## 7. 领域模型

### 7.1 核心对象

#### Day

代表一个自然日：

- 日期；
- 是否已锁定及锁定时间；
- 每日复盘文本；
- 创建和更新时间。

一个 Day 对应一个 Day Todo。

#### TaskChain

代表“同一件事”的连续身份。

任务排期、延期、延续、回池和再排期仍属于同一 TaskChain。只有“变更为新任务”才会建立新 TaskChain。

#### TaskDefinition

代表任务链某个版本的标题、描述和计划子任务。

同一个 TaskChain 可以有多个 TaskDefinition。系统通过新版本保存任务定义／计划草稿演进，而不是覆盖历史定义。它不等同于 `CONTEXT.md` 中需要手动确认或自动确认授权才能形成的“承诺快照”；后者是已接受但尚未在源码落地的后续领域能力。

#### DayTrace

代表任务在某个自然日留下的执行事实。

它包含：

- 所属 TaskChain 和 TaskDefinition；
- 日期；
- 状态；
- 当日优先级；
- 描述和附言快照；
- 手动进度；Core 根据链上历史轨迹动态计算进度下限；
- 延期／延续／变更关系；
- 创建、更新和终态时间。

#### Subtask

附属于 DayTrace，不独立成为 TaskChain。

通过 lineage identity 追踪同一子任务在延期或延续后的跨日连续性。

#### TaskCategory 与 TaskLabel

- 每条任务链最多一个当前主分组；
- 可以有零个或多个平级标签；
- 分类项有稳定 ID、规范名称、颜色、生命周期和名称版本；
- 历史日轨迹拥有冻结的分类事件。

### 7.2 对象关系

```text
Day 1 ────────────── 0..* DayTrace
                           │
                           ├── *..1 TaskChain
                           ├── *..1 TaskDefinition
                           └── 0..* Subtask

TaskChain 1 ───────── 1..* TaskDefinition
TaskChain 1 ───────── 0..* DayTrace
TaskChain 1 ───────── 0..1 Current Category
TaskChain 1 ───────── 0..* Current Labels

DayTrace 1 ────────── 0..* Historical Classification Events
```

### 7.3 当前状态和历史事实

这是理解整个系统的关键：

| 类型 | 可编辑性 | 示例 |
|---|---|---|
| 当前草稿 | 在允许情境可编辑 | 任务池草稿、未来计划、今日待完成 |
| 当前关系 | 可以通过新决定改变 | 当前分组、标签、当前位置 |
| 历史事实 | 不覆盖，只追加关系或更正 | 锁定日轨迹、历史分类事件 |
| 内部取消事实 | 用户不可见，但防止身份复活 | `cancelledDraft`、tombstone |
| 运行状态 | 可重试、可过期、不同步 | 自动分类 job、Provider circuit |

### 7.4 状态集合

TaskChain：

```text
active
abandoned
```

DayTrace：

```text
pending
completed
unfinished
deferred
changed
returnedToPool
cancelledDraft
abandoned
```

不是所有 DayTrace 都构成 Day Todo 行：

- `pending`、`completed`、`unfinished`、`deferred`、`abandoned` 可以形成用户可见日结果；
- `changed`、`returnedToPool`、`cancelledDraft` 主要进入任务轨迹或内部关系；
- 同日已有更晚正式轨迹时，旧 `deferred` 来源也会退出 Day Todo 行投影。

### 7.5 唯一当前位置

一条未终结任务链在任一时刻应只有一个主要位置：

```text
任务池草稿
或
某个未来计划
或
当前日待完成
或
历史未完成且等待处置
或
历史未完成且已有一个后续执行目标
或
已废弃
```

历史记录可以有很多条，但当前位置只能有一个。这一规则防止同一任务同时出现在任务池和未来计划，或从同一未完成历史分叉出多个执行前沿。

### 7.6 任务生命周期

```text
创建到任务池
    │
    ├── 编辑草稿
    └── 排期 ───────────────► Future / Today pending
                                  │
                                  ├── 完成 ─────────► completed
                                  ├── 延期 ─────────► deferred + future target
                                  ├── 回池 ─────────► returnedToPool + pool draft
                                  ├── 变更 ─────────► changed + new TaskChain
                                  ├── 废弃 ─────────► abandoned
                                  └── 日结束 ───────► unfinished
                                                         │
                                                         ├── 延续到未来日期
                                                         ├── 废弃
                                                         └── 后续完成后退出未完成池
```

### 7.7 延期与延续

两者不能混为一谈：

| 动作 | 来源 | 来源结果 | 是否增加延续次数 |
|---|---|---|---|
| 延期 | 当前日 pending | 当日 `deferred` | 否 |
| 延续 | 历史 `unfinished` | 保持 `unfinished` | 是 |

延期是当前日主动决定；延续是对已经形成的未完成事实进行后续安排。

### 7.8 回池

回池改变任务的当前位置，但不删除来源事实：

- 来源 DayTrace 保留；
- 任务链回到任务池；
- 从来源生成下一版 TaskDefinition；
- 带回最新描述、有效附言和未完成子任务；
- 已完成子任务留在历史日。

### 7.9 变更

“修改文字”和“改变任务边界”不同。

变更操作：

- 旧 DayTrace 形成 `changed` 事实；
- 创建新的 TaskChain；
- 创建新的 TaskDefinition 和新 DayTrace；
- 通过显式指针连接来源和目标；
- 默认继承描述、附言和未完成子任务；
- 已完成子任务不进入新任务定义。

这避免把“写周报”直接改成“完成季度战略”而丢失旧任务语义。

### 7.10 子任务与进度

进度有两种互斥模式：

- 无子任务：用户维护 0–100 的手动进度；
- 有子任务：按简、中、难权重自动计算。

存在开放子任务时父任务不能完成。延期或延续后的新轨迹不能低于历史进度下限。

### 7.11 有限撤销

撤销用于纠正当前日和计划草稿的误操作，不是删除历史：

- 可以撤销尚未固化的当前或未来操作；
- 不能撤销锁定历史；
- 新建身份被撤销时保留内部取消事实；
- 这些事实阻止重启或旧同步 record 让身份复活；
- undo/redo 同时处理自动分类 job 的取消和恢复。

---

## 8. 自然日与时间设计

### 8.1 为什么需要独立 DayContext

Todo 系统最危险的时间问题不是格式化，而是：

- 时区变化；
- 设备休眠跨午夜；
- App 不在午夜运行；
- 在途操作跨过日边界；
- 系统时间回拨；
- 同步 record 的时间早于本机 mutation frontier。

因此，系统不让每个调用者自行解释 `Date()`，而通过 `NaturalDayContext` 提供：

- 当前 civil date；
- 产生该日期的 instant；
- 使用的时区环境；
- 日期变化事件；
- 可测试的固定时钟。

### 8.2 日结束

当有效自然日推进时：

1. 加载当前 engine；
2. 把此前未锁定 Day 结算到候选日期之前；
3. 将仍为 pending 的任务变成 unfinished；
4. 锁定历史 Day；
5. 在同一个持久化路径保存；
6. 更新 UI 的 today 和 selection；
7. 失败时阻断新的用户 mutation。

### 8.3 时间与 mutation frontier

领域事实时间不能因为系统时钟回拨而倒退。当前实现没有单独一张“frontier 表”，而是从已持久 snapshot 的所有 mutation 日期取最大值，包括 Day、TaskChain、TaskDefinition、DayTrace、Subtask、分类事实及主题／语言版本。

生成下一次本地 mutation 时间时：

```text
reference = 当前自然日时钟给出的时间
frontier  = snapshot 中所有持久 mutation 时间的最大值

reference > frontier  → 使用 reference
reference ≤ frontier  → 使用 frontierSeconds.nextUp
```

例如，设备 A 从同步取得 `10:05:00` 的远端事实，之后系统时钟回拨到 `10:00:00`；下一次本地修改不会写成更早的 `10:00:00`，而会取 `10:05:00` 的下一个可表示 `Double` instant。frontier 来自 snapshot，因此重启后仍可重建。

时间通过 `timeIntervalSinceReferenceDate.bitPattern` 精确编码，避免 JSON 毫秒截断把两个不同 mutation 合并。同步 journal 的 compare-and-swap 比较 journal ID 与 canonical 内容／精确时间；Provider job 等并发状态则使用自己的 generation、claim 和 revision fences。也就是说，“exact clock”解决确定排序和字节身份，不代替领域冲突规则。

---

## 9. 任务分类设计

### 9.1 模型

分类不是任务状态：

- 主分组表达主要归属；
- 标签表达多个平级维度；
- 分类不会改变任务所在日期或生命周期。

### 9.2 深 Module interface

分类操作采用三阶段：

```text
Query
  ↓
Prepare ClassificationPlan
  ↓ 用户确认 / 有界 authority
Commit
  ↓
ClassificationReceipt + audit record
```

Plan 绑定：

- base revision；
- interaction ID；
- 来源；
- 完整 changes；
- notices 和 blockers；
- digest。

Commit 会再次验证 revision、确认能力、引用和 digest。重复 interaction 只有在 plan、decision 和审计记录完全一致时才幂等返回。

### 9.3 分类生命周期

分类项可以：

- 创建；
- 改名；
- 归档；
- 恢复；
- 合并；
- 在从未被引用时硬删除。

被历史引用的分类项不能物理消失。改名保留 name versions；合并保留来源身份；硬删除保留最小 tombstone，旧 ID 永不复活。

### 9.4 当前分类与历史分类

- 当前任务链关系可以改变；
- DayTrace 形成历史结果时冻结分类事件；
- 后续修改当前分类不会改写历史日；
- 历史解释错误通过追加更正事件处理。

### 9.5 自动分类

新任务创建和自动分类解耦：

```text
用户创建任务
   ↓ 同一 SQLite 事务
任务事实 + automatic classification job
   ↓ 立即返回 UI
后台 worker claim job
   ↓
Provider
   ↓
strict proposal checkpoint
   ↓ fences 校验
分类事实 + audit + sync outbox + job completed
```

关键规则：

- 创建任务不能等待网络；
- 只发送标题、描述和 active 分类目录；
- 必须返回一个分组及一至三个 AI 标签；
- 用户明确输入的标签不能被删除；
- 用户在等待期间手动修改分类，用户事实胜出；
- Provider、任务内容或目录基线变化会使旧 proposal 失效；
- job、Provider 配置和 circuit 都是本机运行状态，不同步；
- 最终分类是普通可同步领域事实。

### 9.6 Provider circuit

失败不是对每条 job 独立重试：

- 401/403 等确定配置错误进入 blocked；
- 429、5xx、超时和断网进入全局退避；
- 冷却后只允许一条 half-open probe；
- 成功 checkpoint 后才恢复；
- 历史积压在 Provider 首次可用时需要用户决定是否付费处理。

---

## 10. 存储设计

### 10.1 为什么选择 SQLite

SQLite 符合：

- local-first；
- 单应用进程；
- 事务；
- 关系和外键；
- 可直接探针；
- 数据包 staging；
- change journal；
- 无第三方运行依赖。

系统没有采用完整 event sourcing。当前状态和不可覆盖关系直接存表，journal 用于同步和审计。

### 10.2 Schema

当前 schema version 为 11。

主要数据类型包括：

- Day；
- TaskChain；
- TaskDefinition；
- DayTrace；
- Subtask；
- 分类 catalog、当前关系、历史事件和 audit；
- App preferences；
- sync device identity、metadata、journal、conflict、pending；
- automatic classification job 和 circuit。

### 10.3 Schema 安装策略

启动时：

1. 启用 foreign keys；
2. 读取 `PRAGMA user_version`；
3. 如果是当前版本，验证完整 schema fingerprint；
4. 如果是空库，使用一个 `BEGIN IMMEDIATE` 安装当前 schema；
5. 如果是非空旧 schema，fail-closed；
6. 执行 `quick_check` 和 `foreign_key_check`。

项目尚未发布，因此采用 clean cut，而不是维护开发期迁移。

### 10.4 保存事务

典型本地 mutation：

```text
BEGIN IMMEDIATE
  ├── 写任务关系事实
  ├── 更新 snapshot generation
  ├── 写 classification audit（如有）
  ├── 写 change_journal/outbox
  ├── 写 automatic job（如有）
  └── 校验
COMMIT
```

任一步失败，整个 mutation 回滚。应用层只有在 repository 保存成功后才发布新的内存 engine。

### 10.5 单写者 lease

同一个数据根只允许一个 Noonmark 进程作为写者。应用启动时获得 process lease；冲突时拒绝继续，避免生产 App、E2E App 或演示 App同时写同一数据库。

### 10.6 数据包

当前数据包：

- canonical JSON；
- format version 4；
- 包含完整 NoonmarkSnapshot；
- 不包含 API Key；
- 不包含烛龙 sidecar；
- 不包含另一设备的同步运行状态。

导出：

1. 校验 snapshot；
2. canonical encode；
3. atomic write；
4. 回读字节；
5. 重新 decode；
6. 比较持久化结果；
7. 计算 SHA-256。

导入：

1. 严格解析 header；
2. 验证必填字段、重复身份和引用；
3. canonical bytes 比较；
4. 在隔离 SQLite staging 安装；
5. 通过当前 schema repository 回读；
6. 获得独占应用操作；
7. 原子替换目标数据库和内存 engine；
8. 保留本机 device identity；
9. 关闭外来同步配置；
10. 失败时保留导入前状态。

---

## 11. 同步设计

### 11.1 目标

同步的核心不是“把文件传上去”，而是：

- 多设备离线修改后仍能合并；
- 历史事实不被 current record 覆盖；
- immutable record 不被同 ID 异内容替换；
- 缺少依赖时等待而不是乱序应用；
- 冲突必须保存足够证据供解释。

### 11.2 数据流

```text
本地领域 mutation
  ↓
SQLite change_journal
  ↓
SyncRecordMapper
  ↓
SyncRecord
  ↓
Transport.push
  ↓
远端记录仓库
  ↓
Transport.fetch
  ↓
canonicalization + dependency ordering
  ↓
SyncRecordMerger
  ↓
ValidatedSyncSnapshot
  ↓ 单一事务
SQLite snapshot + conflicts + pending + audit + metadata
```

### 11.3 Record 类型

wire 层只有八种 `SyncEntityType`：

- current entity：Day、TaskChain、TaskDefinition、DayTrace、Subtask、AppPreferences；
- immutable entity：ClassificationCommit、TraceClassificationEvent。

取消草稿等状态随 DayTrace／Subtask current payload 同步，不是独立 immutable entity。以下则是本机下载协调元数据，不是 wire entity：

- durable pending 及其 dependency；
- conflict evidence；
- terminal rejection；
- sync metadata 与 audit。

immutable record 使用 create-or-exact-match：

- 第一次到达可以创建；
- 相同 ID、完全相同内容是幂等；
- 相同 ID、不同内容是 identity collision；
- 冲突时保留原件并拒绝覆盖。

### 11.4 因果与排序

不能只用更新时间做 last-write-wins。

分类和历史 record 使用：

- 显式前驱 change record ID；
- causal frontier；
- dependency DAG；
- 稳定拓扑序；
- durable waiting；
- terminal rejection propagation。

缺少前驱时先等待；依赖环、分叉不满足交换条件或引用断裂时 fail-closed。

### 11.5 下载原子性

一轮下载必须在同一个 SQLite transaction 提交：

- 新 snapshot；
- 完整 remote conflict evidence；
- durable pending；
- terminal rejection；
- audit；
- sync metadata。

这样不会出现“任务已经变了，但冲突和同步游标没保存”的半状态。

### 11.6 Transport

#### Local Folder

使用目录存放逐条 canonical record、snapshot index 和 ref。它不复制 SQLite。

#### iCloud Drive

复用 Local Folder record repository，但根目录位于用户 iCloud Drive。

#### CloudKit

使用：

- `CKContainer`；
- private database；
- custom record zone；
- `CKSyncEngine`；
- engine state serialization；
- remote notification；
- account binding。

只有显式 CloudKit launch configuration、签名、provisioning profile、entitlement 和 live 环境满足时才选择 CloudKit。普通开发包的 `.iCloud` 设置默认仍走 iCloud Drive，不能把“adapter 已实现”说成所有用户已经默认使用 CloudKit。

### 11.7 一次同步的用户语义

底层上传批次默认 limit 100，但一次用户点击会循环处理所有 pending batch，直到：

- 队列清空；或
- 出现真实失败。

UI 不显示 change journal 数量，而显示：

- 新增了多少条真实任务；
- 更新了多少条真实任务；
- 是否有未解决冲突。

同一任务的 definition、trace、subtask、分类 commit 和 journal 不能被重复计算成多条“任务”。

### 11.8 当前端点状态

| 端点 | 当前状态 |
|---|---|
| Local Folder | 已实现 |
| iCloud Drive | 已实现 |
| CloudKit | adapter 已实现；仅显式启动配置与签名 live 门禁下可达 |
| S3 | 只有领域占位，未实现 |
| WebDAV | 只有领域占位，未实现 |
| 自定义在线服务 | 未实现 |

### 11.9 冲突与收敛决策矩阵

系统不是对所有字段套一个 LWW。current record 先按 entity 的内容时钟和领域终态规则合并；只在允许选择一个 current base 时，才使用确定性顺序：

```text
modifiedAt 数值
→ 精确 bitPattern
→ canonical payload 字节
→ writer device ID
```

该顺序确保两端收敛，不表示后到的墙上时钟可以推翻历史不变量。

| 并发情景 | 当前规则 | 用户可见结果／证据 |
|---|---|---|
| 同一 TaskDefinition 改标题或描述 | 在身份、sequence 和 content clock 合法后选择确定性 current base | 两端收敛到同一版本；不创建“混合标题” |
| 同一任务的附言并发增删改 | 附言按稳定身份独立合并，删除保留删除事实 | 可保留另一端新增附言，不被整个 TaskChain 的 base winner 吞掉 |
| 一端完成、一端仍 pending／修改附言 | 终态感知合并；完成事实保留，同时合并合法附言 | 完成不会仅因较晚 pending payload 静默复活 |
| 一端撤销完成 | 只有原 Day 未锁定且字段符合明确 undo 形态时允许 | 锁定历史上的撤销形成 conflict，不覆盖历史 |
| 一端废弃、一端重新启用 | 废弃优先，除非存在完整 reactivation witness | 无 witness 的旧 active record 不能复活链 |
| 两端同时延期／延续并形成冲突后继 | 校验 continuation sequence、来源和拓扑；重复位置、环或不完整关系拒绝 | 整个相关 component 冲突或等待，不发布一半拓扑 |
| current entity delete | 没有可证明 tombstone 语义时 fail-closed | 不把裸 delete 当作安全删除 |
| 分类并发新增不同标签 | 从同一 base 可交换时合并 | 两项都保留 |
| 分类并发改同一项、merge 与 hard-delete 竞态 | immutable commit 的 base／前驱不满足时 typed conflict | 保存 remote evidence，禁止任一分支静默覆盖 |
| 相同 immutable ID、不同 bytes | create-or-exact-match 失败 | identity collision；原事实保留 |
| 依赖尚未到达 | durable pending | 后续同步重试；不是立即丢弃或假装成功 |

当前冲突主要通过本机 conflict ledger、结果提示和诊断 evidence 留存；还没有一个面向普通用户、可以逐字段选择“保留本地／保留远端”的完整冲突编辑器。这是实现边界，不应在面试中夸大成 CRDT 能自动解决所有语义冲突。

---

## 12. 烛龙与 AI 设计

### 12.1 总原则

烛龙是旁路 Agent：

- 不参与普通 Todo 启动；
- 不拥有任务事实；
- 不直接修改历史；
- Provider 故障不影响清单；
- 普通 Provider 产物不能自动写 Todo；
- 新任务自动分类是唯一受限自动写入例外。

### 12.2 Provider seam

OpenAI-compatible adapter 支持：

- `GET /models` 健康检查；
- `POST /chat/completions`；
- JSON Object response format；
- Server-Sent Events streaming；
- Bearer token；
- extra headers；
- 自定义 Base URL 和模型；
- request cancellation。

远程 Provider 必须使用 HTTPS；HTTP 只允许 loopback。

`extra headers` 是底层通用 adapter capability。当前 Mac 设置页与 `StoredZhulongProviderConfig` 并未提供或持久化该字段；因此它不是当前用户可配置能力。若未来开放，header value 可能包含凭证，必须禁止敏感值或改由 Keychain 保存，不能直接当作普通 UserDefaults 字符串。

### 12.3 Provider 配置

非敏感配置保存在 UserDefaults：

- display name；
- kind；
- base URL；
- model；
- enabled；
- execution revision 指针。

API Key 只存 Keychain。每个 execution revision 使用独立凭证引用：

1. 先保存新 revision 的 Key；
2. 再切换非敏感指针；
3. fresh launch 确认后回收旧 Key；
4. 请求只能解析精确匹配 revision 的 Key。

这避免崩溃窗口把新 Key 发给旧 URL 或旧模型。

### 12.4 会话授权

系统分开三种权力：

1. 读取本机任务数据；
2. 把数据发送给远程 Provider；
3. 修改 Todo。

前两项在设置中有允许、询问、禁止三态上限。授权绑定：

- 精确数据范围；
- 本地／远程性质；
- 完整远程 endpoint。

以下变化要求重新确认：

- 数据范围扩大；
- endpoint 改变；
- Provider 从本地变成远程或相反。

显示名称或模型变化本身不扩大接收方，因此不单独触发重新授权，但实际 execution identity 仍记录在发送历史中。

Todo 内容和生命周期写入永远不从读取授权继承；新任务自动分类使用独立设置、durable job 和严格 fences，不从烛龙会话授权继承。

### 12.5 对话产物

自然对话可以附带严格结构化产物：

- `taskPlan`；
- `dailyReview`；
- `taskPoolAnalysis`。

Provider 的自然语言正文和协议区块分开解析。结构非法时：

- 不从正文猜测任务；
- 可以在同一次授权 run 内进行至多一次格式修复；
- 修复不能扩大 scope 或获得写权限；
- 仍不合法则整个产物 fail-closed。

### 12.6 Todo diff

任务方案不会直接写库：

```text
Provider artifact
  ↓ schema validation
对话内可编辑 artifact
  ↓ 用户修改 / Provider revision
Todo Diff
  ↓ 绑定当前版本、snapshot、日期和 digest
一次性 Todo Write Authorization
  ↓
普通 NoonmarkCore interfaces
  ↓
原子持久化
  ↓
Apply Receipt
```

用户可以：

- 编辑父任务和子任务；
- 调整任务池、今天或未来日期落点；
- 继续对话要求修订；
- 明确点击提交或发送语义明确的提交消息。

疑问、否定和普通讨论不构成授权。

### 12.7 Provider 停止

Provider 运行时：

- Composer 主动作从发送切换成停止；
- App 持有唯一 Task cancellation handle；
- 取消真实网络流；
- 已接收的部分文字作为普通回复保存；
- 没有片段时不创建空消息；
- 发送记录保存为 `.stopped`；
- stopped 是正常终态，不显示成故障；
- 未完成 JSON 不能生成可执行产物。

### 12.8 任务池分析

本地统计与 Provider 分析严格分开：

- 统计只依赖本地领域事实；
- Provider 未 ready 时分析区整体隐藏；
- Provider ready 时可以生成最多三项发现；
- 每项发现包含结论、typed task evidence、置信度、不确定性和建议；
- evidence 必须来自该次发送保存的 index；
- 当前实现会把 `TaskChainID` 作为 typed evidence 的 `taskID` 发送给 Provider；它不是数据库文件，但属于稳定内部标识；
- 不能从 prompt 文本反推授权范围；
- 任务池改变后旧报告标记为过期。

若产品目标升级为“绝不向 Provider 暴露稳定内部 ID”，应改为每次发送生成短期 opaque handle，并在本机 evidence index 中映射；当前版本尚未这样做。

### 12.9 Sidecar

烛龙高敏感数据不进入主 SQLite：

- 会话；
- 记忆；
- Provider 发送记录；
- 自然语言正文；
- 对话产物；
- Todo diff；
- 授权；
- 应用回执；
- application journal。

sidecar 使用：

- AES-GCM；
- 32-byte 随机密钥；
- Keychain `AfterFirstUnlockThisDeviceOnly`；
- envelope magic 和 current format version；
- authenticated additional data；
- 目录 `0700`；
- 文件 `0600`；
- atomic write；
- transaction lock。

### 12.10 跨存储应用与恢复

Todo 写入涉及两套存储：

- 核心 SQLite；
- 加密烛龙 sidecar。

不能依赖一个跨 SQLite 和文件系统的数据库 transaction，因此使用 application journal：

1. 保存 pending application；
2. 保存新的 engine snapshot；
3. 保存新的 session；application receipt 已包含在 `afterSession`；
4. 在验证持久 session 等于 `afterSession` 后清理 journal。

启动恢复会比较：

- journal 中的 before/after identity；
- 当前 engine digest；
- 当前 session 是否精确等于 beforeSession 或 afterSession。

只接受可证明的状态组合；不确定时阻断新的 mutation，而不是重复应用。

恢复协议按以下阶段运行：

| 崩溃／失败点 | Engine | Session／Receipt | Journal | 恢复行为 |
|---|---|---|---|---|
| pending journal 耐久后、Engine 保存前 | before | before／无新 receipt | present | 以 journal 的 afterSnapshot 补写 Engine，再继续 |
| Engine 保存调用返回错误，耐久结果未知 | before、after 或其他 | before | present | 重载 SQLite，对照 before/after digest；before 可重试，after 继续，其他状态阻断 |
| Engine 已 after、Session 保存前 | after | before | present | 以 expected-before compare-and-swap 写入 afterSession |
| Session 已保存、journal 清理前 | after | after／receipt 已在 session | present | 验证两端均为 after 后，只清理 journal |
| journal 清理过程结果未知 | after | after | present 或 absent | 文件 committer 解析未决 fence；可证明清理完成则视为 verified completion，否则保留恢复阻断 |
| 任一存储既不等于 before 也不等于 after | conflict | conflict | present | fail-closed，显示 recovery conflict，不猜测或重复提交 |

因此这里实现的是“可恢复的跨存储提交协议”，不是一个真正的跨存储原子 transaction。测试覆盖 coordinator、snapshot identity、sidecar transaction、journal 文件提交和进程退出阶段；仍需持续维护 crash matrix，不能仅凭正常路径宣称绝对原子。

---

## 13. Mac 原生应用设计

### 13.1 为什么是 AppKit shell + SwiftUI content

纯 SwiftUI 适合声明式页面，但晷迹需要可靠控制：

- App 生命周期；
- 主菜单；
- responder chain；
- 多窗口；
- Window restoration；
- 三栏拖动；
- 原生文本编辑；
- 文件面板；
- 物理键盘和焦点。

因此：

- AppKit 管理桌面壳层；
- SwiftUI 管理主要内容和状态投影；
- 需要成熟系统行为时通过 representable 使用 AppKit。

### 13.2 启动结构

应用不是 `SwiftUI.App`：

```text
@main NoonmarkMacApp
  └── NSApplicationDelegate
      ├── 创建 NoonmarkStore
      ├── 安装 NSMenu
      ├── 创建 NoonmarkWindow
      ├── 注册本机全局 Quick Entry hotkey
      ├── NSHostingView(NoonmarkRootView)
      ├── 注册 CloudKit remote notification
      └── 管理 Settings / Quick Entry / Search / Help windows
```

### 13.2.1 全局 Quick Entry 边界

`NoonmarkMacRuntime` 定义快捷键值、偏好仓库、安全策略和切换 coordinator；App target 只实现 Carbon adapter、系统快捷键读取和窗口调用。这个边界让注册失败、冲突和偏好损坏可以脱离 WindowServer 做确定性测试。

生产 adapter 使用非独占 `RegisterEventHotKey`，不使用 Accessibility、Input Monitoring 或 event tap。切换顺序固定为“校验候选 → 注册候选 → 注销旧引用 → 写入偏好”，避免失败后把用户最后一个可用入口一并删除。

系统冲突分两层：

- 晷迹自身命令目录从实际 `NSMenu` 递归生成，再由当前 Text Input Source 的 Unicode keyboard layout 把菜单字符翻译为物理 virtual key，避免菜单、键盘布局与校验规则各维护一份；`CopySymbolicHotKeys` 返回的 macOS 系统组合也会硬拦截；
- 第三方 App 自定义组合无法完整枚举，只能在设置中披露并要求用户在常用 App 中试按。

keyboard layout 或 `CopySymbolicHotKeys` 读取失败属于未知状态，不等于空集合；coordinator 会拒绝保存候选组合并保留旧注册。两份 snapshot 都在每次校验时重新取得，输入源切换后不会沿用启动时映射。录制器保存 `NSEvent.keyCode` 对应的物理 virtual key，不通过当前键盘布局的字符重新映射。Carbon event handler 安装失败也只表现为注册失败，不终止 App。

全局触发记录先前 `NSRunningApplication`，只呈现 Quick Entry panel。提交或取消后恢复先前 App；主窗口关闭时保持关闭。应用内 `⌘N` 仍走菜单命令并保留原有行为。

### 13.3 三栏工作区

主窗口使用原生 `NSSplitViewController`：

- 左侧导航；
- 中间主页面；
- 右侧详情或复盘栏。

每栏内部由 `NSHostingController` 承载 SwiftUI。分栏宽度、折叠和恢复由单一 coordinator 管理。

### 13.4 页面

主导航：

- Day Todo；
- 任务池；
- 未来计划；
- 未完成池；
- 已完成池；
- 日历；
- 烛龙。

Settings 是独立原生窗口，不属于主导航工作区。内部 pane：

- 通用；
- 组织；
- 数据；
- 同步；
- 烛龙；
- 隐私。

### 13.5 State Store

`NoonmarkStore` 是 `@MainActor ObservableObject`。

它持有：

- `NoonmarkEngine`；
- 当前页面和 selection；
- 左右栏状态；
- 日期上下文；
- repository；
- sync task；
- automatic classification worker；
- Provider health task；
- Zhulong workspace；
- undo/redo；
- toast 和错误 presentation。

这是当前架构的主要编排点。优点是用户动作和 UI 状态集中；代价是 Store 较大，因此部分可测试逻辑已经下沉到 `NoonmarkMacRuntime` 和独立模块。

### 13.6 原生文本编辑

描述和附言不使用自绘文本系统，而是包装 `NSTextView`：

- 中文输入法；
- selection；
- cut/copy/paste；
- undo/redo；
- responder chain；
- Tab focus；
- Markdown 快捷键；
- Accessibility。

SwiftUI 只负责绑定和布局，输入行为仍由 AppKit 提供。

### 13.7 UI 设计原则

- 始终使用亮色基调；
- Vercel / Stripe 亮模式式克制层级；
- 减少卡片、描边、badge 和装饰图标；
- 信息层级优先使用字号、字重、留白和单条分隔线；
- 分组视图不在每条任务重复显示分组；
- 日历网格使用窗口或右栏边界，不制造重复外框；
- 本地统计不得伪装为 AI 分析；
- 当前真实 App 和代码化 UI Contract 是验收基线。

### 13.8 Accessibility

应用对关键视图设置：

- accessibility label；
- accessibility identifier；
- selected trait；
- adjustable action；
- AppKit AX 元素。

E2E 会通过真实 `AXUIElement` 树、物理输入和 screenshot 验证，而不只检查 SwiftUI view model。

### 13.9 本地化

当前产品支持中文与 English，但实现不是 String Catalog，而是类型化的 `AppCopy(language:)` 及按功能拆分的 extension。语言是领域偏好，切换时与精确 mutation clock 一起持久化并可同步。

- UI 文案、菜单、Accessibility label 和动态计数由同一语言值投影；
- 日期与自然日语义由 `NoonmarkMacRuntime` 集中格式化，避免每个 view 自行选择 locale；
- 英文长标题、最小窗口、日期选择器、菜单、附言和分类有真实 App E2E；
- 英文复数目前由逐个 helper 处理，不是完整 ICU message format；
- 新增文案必须同时提供中英文并进入相关 copy contract 或 E2E。

这种方式类型安全、便于当前双语产品快速审阅，代价是文案规模扩大后维护成本高，也不利于交给专业翻译流程。增加第三种语言前应评估迁移到 String Catalog，同时保留现有领域语言偏好和 E2E 契约。

---

## 14. 安全与隐私

### 14.1 资产分类

| 资产 | 保护 |
|---|---|
| Todo 主数据 | SQLite 事务、约束与完整性校验；无应用层加密 |
| Provider API Key | Keychain |
| Sidecar 加密密钥 | Keychain，设备绑定 |
| 烛龙会话和 Provider 正文 | AES-GCM sidecar |
| 同步记录 | canonical 校验、immutable identity、冲突保留；无应用层端到端加密 |
| 普通数据包 | 无凭证、无 sidecar、canonical 与回读校验；文件本身不加密 |
| 日志 | 不记录凭证和完整正文 |

### 14.2 最小发送

向 Provider 发送数据前：

- 先建立授权 scope；
- 只使用必要字段；
- 不发送数据库文件；
- 不发送 Keychain 值；
- 不发送同步端点配置；
- 不发送已删除附言正文；
- 保存 typed evidence，供结果 grounding。

例外必须透明：任务池分析目前发送稳定 `TaskChainID` 作为 typed evidence 的 `taskID`，用于把 Provider 结论精确映射回本机任务。其他 scope 不应据此扩大。若要隐藏稳定 ID，需改为单次请求的 opaque handle。

### 14.3 威胁边界

当前加密目标是静态数据保护，不承诺：

- 防御已控制用户 session 的本机攻击者；
- 密码学防篡改审计链；
- Todo 主库、导出包和同步 record 的应用层端到端加密；
- 服务端密钥托管；
- 多用户权限系统。

这些需要新的威胁模型，而不能从 AES-GCM 自动推导。

当前 Todo 主库依赖 macOS 账号、文件权限和用户磁盘加密；CloudKit／iCloud Drive 依赖 Apple 账号与平台传输／静态保护；用户自行选择的 JSON 导出位置由用户负责保护。SHA-256 与 canonical 校验能发现意外损坏和结构漂移，不提供持有文件者无法伪造的真实性。

任务标题和描述也是 Provider prompt 中的不可信输入，可能包含 prompt injection。当前控制面是 scope 最小化、结构化 output contract、typed evidence、Todo diff 和用户确认；它限制注入后的写入能力，但不保证模型文字永不受任务内容影响。

### 14.4 已知安全缺口

- 通用 HTTP adapter 支持 `extraHeaders`，但没有“禁止 secret”或 header value Keychain 模型；当前 Mac UI 不暴露该字段，未来开放前必须先解决；
- 没有 SQLCipher 或 Todo 主库应用层加密；
- 普通数据包不是加密备份；
- 同步不是只有用户持钥才能解密的端到端协议；
- 没有生产 crash／metric 后端，也没有完整用户诊断包的保留与脱敏策略；
- 没有对恶意 Provider 的可信执行保证；Provider 输出始终按不可信数据处理。

---

## 15. 错误、恢复与可观测性

### 15.1 错误分类

- 用户输入错误：显示可操作说明；
- 领域不变量错误：拒绝 mutation；
- 持久化错误：内存状态不得先行发布；
- 同步冲突：保存完整 remote evidence；
- Provider 配置错误：阻断 AI，不阻断 Todo；
- sidecar 错误：阻断烛龙，不阻断 Todo；
- 数据根冲突：拒绝第二写者；
- 自然日结算错误：阻断新的日期相关 mutation。

### 15.2 可观测性

当前拥有的是开发、验收和本机故障取证能力，不是生产 SaaS 式 observability。它覆盖：

- Provider 状态与失败类别；
- automatic classification job 和 circuit 状态；
- sync pending、conflict 和结果；
- sidecar 恢复；
- E2E unified log；
- SQLite probe；
- validation manifest；
- artifact SHA-256 inventory。

不记录：

- API Key；
- Key hash；
- 完整任务正文；
- 完整 Provider 原始响应；
- sidecar 明文。

当前没有集中式 crash reporting、metric、distributed trace、告警或服务端 dashboard；也没有正式定义本机日志保留周期和用户诊断导出格式。因为应用没有后端，这不会阻断核心 Todo，但会限制真实发布后的问题发现与跨用户聚合分析。

### 15.3 恢复原则

- 能精确证明已完成：返回幂等结果；
- 能精确证明未应用：安全重试；
- 已产生外部付费结果但未发布：优先使用 checkpoint，不重复请求；
- 状态组合不确定：fail-closed，要求恢复或人工处理。

---

## 16. 测试与质量门禁

### 16.1 测试分层

```text
单元测试
├── Core
├── DayContext
├── Runtime
├── AI
├── Zhulong
├── Sync
└── UI Contract

集成测试
├── SQLite
├── 数据包
├── 自动分类 durable job
└── Sync coordinator

确定性仿真
└── 多步骤领域状态和跨引擎对账

真实 App E2E
├── WindowServer 物理输入
├── AppKit 菜单、焦点和窗口
├── Accessibility tree
├── screenshot
├── SQLite probe
├── restart persistence
└── unified log

安装验证
├── DMG mount
├── 拖入隔离 Applications
├── 启动
├── 用户路径
└── 持久化与退出
```

### 16.2 为什么不依赖截图原型

归档 HTML 原型只能说明设计来源，不能证明当前产品正确。当前 UI ground truth 来自：

- 用户即时确认；
- 真实 `.app`；
- `NoonmarkMacUIContract`；
- Accessibility；
- screenshot；
- SQLite 和日志。

只有用户确认过的真实 App screenshot 才能成为 visual regression reference。

### 16.3 主要命令

| 命令 | 用途 |
|---|---|
| `make build` | 清理开发数据并 Swift build |
| `make test` | Swift tests |
| `make check` | build、分层测试、lint、format 和证据门禁 |
| `make run-demo-app` | 一年中段状态的交互验收 |
| `make test-demo-fixture` | demo SQLite 与加密 sidecar 回读 |
| `make test-tencent-ime-input-matrix` | 年度负载下的真实腾讯拼音 53 输入面性能矩阵 |
| `make test-tencent-ime-termination-persistence` | 输入后立即退出与重启持久化对账 |
| `scripts/test-e2e` | 真实 Mac App E2E |
| `scripts/test-ai-provider-live` | 显式凭证的 live Provider smoke |
| `scripts/test-cloudkit-sync-live` | 签名 CloudKit live 验证 |
| `scripts/package-dmg release` | release DMG |
| `scripts/test-dmg-install` | DMG 安装启动验证 |

### 16.4 门禁矩阵

这些入口互相补充，不可把 `make check` 说成已经包含所有外部与 GUI 验证：

| 门禁 | 覆盖 | 明确不包含 |
|---|---|---|
| 默认 `make check` | build、UT、IT、ST、确定性仿真、SwiftLint、SwiftFormat 与 evidence contract | 真实 WindowServer App E2E、DMG 安装、live AI、live CloudKit |
| 真实 UI E2E | 签名 `.app`、物理输入、AX、截图、日志、SQLite、进程 lease | 公网 Provider、CloudKit 双设备、公开分发签名 |
| release validation | `make check` + lease E2E + 全量 App E2E + DMG package／verify／install | notarization、stapling、公开发行 |
| 手动 live external | 显式凭证 AI smoke 或签名 CloudKit live | 默认 CI；缺少真实依赖时必须失败，不以 mock 代替 |

文档本身修改不需要运行会清除开发数据的全量应用门禁；代码、schema、同步、AI 或 UI 行为修改则应按影响层级选择真实路径。

### 16.5 GitHub Actions

仓库有三条 CI／交付 workflow：

| Workflow | 触发与 runner | 作用 |
|---|---|---|
| `ci.yml` check | PR、main push、手动；GitHub hosted `macos-15` | 执行 `scripts/check`，无论成功失败上传 check evidence，保留 14 天 |
| `ci.yml` E2E | 仅 main push 或显式 main dispatch；持久 self-hosted Mac | 在 hosted check 成功后验证签名身份、writer lease、完整真实 App E2E 与 runtime evidence |
| `nightly-deterministic-sim.yml` | 每日或手动；hosted `macos-15` | 固定 seed 默认运行 512 次深度确定性仿真 |
| `release.yml` | 仅手动 main；self-hosted Mac | 全量 check、E2E、DMG 安装和证据归档；产物明确标记不可公开分发 |

最重要的供应链安全选择是：pull request 的可变代码绝不运行在持有 UI signing identity 和预授权 TCC 的 persistent runner。PR 只运行 hosted check；合并到 main 后，才由受保护的 runner 执行真实 GUI 门禁。

当前 release workflow 使用 Apple Development identity，产物会生成 `NOT-FOR-DISTRIBUTION.txt`，不冒充 Developer ID notarized release。

### 16.6 开发数据 clean cut

每次新编译和测试前清理固定开发数据：

- 终止 Noonmark 开发／E2E／Audit 进程；
- 删除固定 Application Support 数据根；
- 删除对应 UserDefaults、cache 和 window state；
- 删除测试 iCloud sync repository；
- 删除 sidecar 生成密钥；
- 保留开发者 Provider 凭证。

原因是项目尚未发布，当前 schema 和当前二进制是唯一版本。保留旧测试数据库会制造假的兼容问题和错误同步记录。

### 16.7 一年演示 fixture

交互验收不使用空库：

- 由 `NoonmarkDemoSupport` 通过真实领域接口重放 365 天用户故事；
- 十二个功能重放日横跨四个季度，每项普通任务能力至少真实使用十二次；
- 覆盖五大集合、跨日轨迹、子任务、分类、复盘和烛龙会话；
- 十二条重复计划覆盖四种生命周期，二十场烛龙会话覆盖四个季度；
- 写入隔离 SQLite；
- 写入加密 sidecar；
- 写后精确回读；
- 每次启动重新生成。

这使产品体验、领域规则和验收数据共享同一事实来源。

---

## 17. 构建、签名与发布

### 17.1 App bundle

构建脚本：

1. 重置开发数据；
2. `swift build -c release --product NoonmarkMacApp`；
3. 创建 `.app/Contents/MacOS` 和 `Resources`；
4. 复制 executable 和 `.icns`；
5. 生成 `Info.plist`；
6. 设置 bundle identifier、版本和最低系统；
7. codesign。

当前版本字段：

- `CFBundleShortVersionString = 0.1.1`
- `CFBundleVersion = 2`
- `LSMinimumSystemVersion = 14.0`

### 17.2 CloudKit 签名

CloudKit build 额外要求：

- 合法 `iCloud.*` container identifier；
- Development 或 Production environment；
- 非 ad-hoc signing identity；
- 未过期 provisioning profile；
- profile 的 bundle ID、team、CloudKit、container 和 APNs entitlement 完全匹配；
- 签名后再次读取 entitlement 验证。

### 17.3 DMG

DMG 包含：

- `Noonmark.app`；
- `/Applications` 软链接。

使用 `hdiutil` 生成 UDZO 压缩镜像，并输出 SHA-256、manifest 和 artifact inventory。

### 17.4 当前发布缺口

当前仓库尚未形成完整公开发行链：

- 未发现 Developer ID notarization；
- 未发现 stapling；
- 未构建 universal binary；
- 没有自动更新框架；
- 没有生产遥测后端；
- CloudKit 仍需真实签名环境和双设备验证后才能称为稳定默认同步。

这些是诚实的项目边界，不应在面试中描述为已完成。

---

## 18. 关键架构决策与取舍

下表给出面试时最实用的决策框架；后续小节解释演进：

| 决策 | 当时约束与候选 | 当前选择与收益 | 代价／重新评估条件 |
|---|---|---|---|
| 平台策略 | macOS 原生深度 vs Flutter／Web 跨平台 | Apple-first；获得菜单、文本、AX、窗口和系统同步能力 | Windows 必须重写；若产品目标变成多端同时上市，重新评估 |
| UI shell | 纯 SwiftUI vs AppKit + SwiftUI | AppKit 管生命周期、窗口、菜单、分栏、文本；SwiftUI 管内容 | 框架桥接和状态协调增加；SwiftUI 原生能力成熟后逐项收缩 AppKit |
| 本地 persistence | Core Data、SwiftData、GRDB、直接 sqlite3 | 直接 sqlite3；精确控制 schema、transaction、outbox、canonical 与探针，且无第三方 runtime dependency | 代码量、migration 和 bus factor 高；发布 migration 或查询复杂度失控时评估 GRDB 等薄封装 |
| 状态框架 | Observation、TCA、Combine | `@MainActor ObservableObject` + Combine，兼容 macOS 14 且直接接 SwiftUI | Store 容易变大；若用例继续膨胀，优先深化领域／coordinator Module，而非先换全局框架 |
| 工程形态 | Xcode App project vs SwiftPM executable 手工组装 `.app` | Package manifest 成为模块和构建事实源，脚本可重复组装、签名与验证 | entitlement、archive、notarization 与 universal 管线更手工；公开发布前重新评估 Xcode archive integration |
| 历史模型 | CRUD current row vs 完整 event sourcing | 关系 current facts + immutable historical facts + 必要 journal | 需维护三者一致；若将来要求任意时间点重建与事件订阅，再评估 event sourcing |
| 同步权威 | 复制 SQLite、CloudKit-specific merge、领域 record merge | 领域 record、canonical bytes、因果依赖；transport 只传输 | 客户端复杂；若中心服务成为事实权威，需一次性重画 ordering 与 conflict ownership |
| 后端 | 中心账号／服务 vs 无后端 | 无后端 local-first，快速录入和隐私不依赖服务可用性 | 多人协作、跨平台身份、远程诊断弱；出现团队协作需求时重新评估 |
| AI persistence | 主 SQLite、第二套 SQLite／SQLCipher、AES-GCM 文件 sidecar | 小规模高敏感会话用独立 AES-GCM sidecar，Key 存 Keychain | 跨存储 commit 更复杂、查询能力弱；会话规模或检索需求显著增长时评估加密数据库 |
| AI 写权限 | tool calling 直写 vs artifact + confirmation | 结构化 artifact、可编辑 diff、一次性授权；自动分类为窄例外 | 交互多一步；只有建立等价可审查与恢复能力后才扩大自动化 |
| 开发数据 | 迁移每个未发布 schema vs clean cut | 当前二进制与 schema 是唯一版本，避免虚假兼容债 | 不能用于真实用户升级；首次公开发布前必须停止 clean cut 并建立 migration |

### 18.1 Flutter 改为 Apple-first

早期考虑 Flutter，以换取跨平台复用；随后改为 SwiftUI / Swift 的 Apple-first 路线。

取舍：

- 获得更好的 macOS 窗口、菜单、输入、Accessibility 和系统集成；
- 放弃 Windows UI 代码复用；
- 未来 Windows 需要原生重写，但可以复用领域语义和同步协议。

### 18.2 SwiftUI 改为 AppKit + SwiftUI 协作

并未推翻 SwiftUI，而是让它承担适合的内容层；窗口和桌面原生行为交给 AppKit。

### 18.3 不采用完整 event sourcing

选择：

- SQLite 关系事实作为主要事实；
- append-only 历史与 journal 作为必要补充；
- 视图从关系派生。

好处是查询和本地实现直接；代价是必须同时维护 current relations、immutable facts 和同步 journal 的一致性。

### 18.4 通用同步底座优先于 CloudKit

同步合并属于领域问题，不属于 CloudKit。先建设 transport-neutral record、merge algorithm specification 和测试向量，使不同 transport 共享规则。当前 Swift target 本身仍依赖 Apple 框架，不等于二进制可直接搬到 Windows。

### 18.5 AI 旁路

核心 Todo 不依赖 Provider。烛龙通过结构化产物和一次性授权获得受控写入能力；唯一无需逐次确认的自动分类路径由独立设置、durable job、strict contract 和 stale fences 限定。

### 18.6 Sidecar 与主库分离

普通 Todo 和高敏感 AI 历史有不同：

- 数据保留要求；
- 同步授权；
- 加密要求；
- 删除语义。

分离后，清理烛龙不会删除已确认的普通任务；普通数据包也不会意外携带对话正文。

### 18.7 Clean cut

项目尚未发布，因此优先保持一个严格 current schema，不为测试数据建立迁移债务。

这个选择发布前合理；一旦正式发布，就必须引入真实数据库、数据包和 sidecar migration policy。

---

## 19. 风险与改进方向

### 19.1 NoonmarkStore 过大

当前 Store 同时编排 UI、持久化、同步、自动分类和烛龙。虽然复杂规则已经下沉，composition root 仍有较大认知负担。

改进方向：

- 继续把用例编排收敛到深 Module；
- Store 只保留 presentation state 和命令转发；
- 以真实 seam 划分生命周期、同步、分类和烛龙 coordinator；
- 不增加只转发一层的浅 Module。

### 19.2 MacApp target 包含大量 E2E automation

这方便真实应用内取证，但会：

- 增大 target；
- 增加编译时间；
- 让生产与测试实现更难区分。

长期可以在保持安全启动参数边界的前提下，把测试 driver 拆成独立 support target 或测试宿主。

### 19.3 手写 SQLite 复杂度

优点是约束精确、无第三方依赖；代价是：

- statement、bind、decode 代码量大；
- schema 演进成本高；
- 容易出现重复 persistence logic。

发布前应建立正式 migration framework，而不是继续依赖 clean cut。

### 19.4 同步复杂度

客户端承担 canonicalization、依赖 DAG、pending 和 conflict，测试成本高。未来如果增加中心后端，需要决定：

- 保留 peer-like merge；
- 或由服务器提供 authoritative ordering。

无论选择哪一种，不能同时存在两套不一致的事实权威。

### 19.5 跨存储原子性

SQLite 与 sidecar 的 application journal 已实现可恢复提交，但协议复杂。应持续通过 crash injection 验证每个 commit phase，而不能只验证正常路径或把它称为真正的跨存储原子 transaction。

### 19.6 正式发布准备

- Developer ID signing；
- notarization / stapling；
- universal binary 或明确只支持 Apple Silicon；
- 隐私政策和 Provider 数据披露；
- 正式数据迁移；
- CloudKit 双设备与账号切换矩阵；
- 崩溃报告脱敏；
- 更新分发策略。

### 19.7 可执行风险登记表

概率和影响是当前工程判断，不是生产统计：

| 风险 | 概率 | 影响 | 当前缓解／证据 | 触发条件与下一步 | 发布阻断 |
|---|---|---|---|---|---|
| 无正式 migration | 高 | 高 | 未发布期 clean cut、schema fingerprint | 首批外部用户前建立 SQLite、数据包、sidecar migration 与 rollback fixture | 是 |
| 未 notarize／staple、仅 arm64 | 确定 | 高 | DMG 安装 harness、明确 NOT-FOR-DISTRIBUTION | 公开分发前接 Developer ID、notary、staple；决定 universal 或仅 Apple Silicon | 是 |
| CloudKit 双设备与账号边界未闭环 | 中 | 高 | adapter、mock／contract、签名 live gate | 默认切换 CloudKit 前跑双设备、账号切换、配额、token 失效矩阵 | 是，若默认启用 |
| full snapshot 驻留内存 | 中 | 中至高 | 当前个人数据范围、内存投影快 | 建立 1 万／10 万任务 benchmark；超预算后分页或增量投影 | 视目标规模 |
| sync record 长期累积 | 中 | 中 | 批量循环、pending／terminal ledger | 建立多年历史 fixture、仓库体积预算和安全 compaction 协议 | 否，需监控 |
| custom Provider 兼容漂移 | 高 | 中 | OpenAI-compatible contract、health check、显式 live smoke | 维护 Provider 能力矩阵和协议错误分类，不承诺所有兼容服务 | 否 |
| `extraHeaders` 未来承载 secret | 低（当前 UI 不可达） | 高 | 当前 Mac 设置不暴露 | 开放前先做禁止 secret 或 Keychain-backed header model | 是，若开放 |
| Todo／同步／导出无应用层 E2E 加密 | 确定 | 高（特定威胁模型） | OS 权限、Apple 账号、sidecar 单独加密 | 完成产品隐私披露；若目标要求用户持钥，再设计密钥与恢复协议 | 取决于承诺 |
| Store 和手写 SQLite bus factor | 中 | 中 | 模块测试、真实 E2E、源码索引 | 深化用例 Module，补 migration/runbook，避免继续把规则放进 Store | 否 |
| 跨存储 crash phase 回归 | 低至中 | 高 | journal、digest、CAS、阶段测试 | 保持进程退出／fault injection matrix 为 release gate | 是 |
| 无生产遥测 | 高 | 中 | 本机日志和 evidence | 发布前定义脱敏 crash report、用户同意和诊断导出 | 视发布范围 |

---

## 20. 面试讲述指南

### 20.1 30 秒版本

> 晷迹是一款 Swift 开发的 macOS 原生 local-first Todo。它的核心不是普通待办，而是用 TaskChain、TaskDefinition 和 DayTrace 区分当前任务和不可改写的每日执行历史。AppKit 负责窗口、菜单、分栏和原生编辑，SwiftUI 负责主要页面；数据直接存 SQLite。同步层先定义 transport-neutral record schema、领域合并规则和测试向量，再接 CloudKit 与 iCloud Drive。AI 烛龙只生成结构化、可编辑的 Todo diff，用户确认后才通过普通领域接口应用；新任务自动分类是独立且受 fences 限定的唯一自动写入例外。

### 20.2 三分钟版本

> 项目最难的地方是任务跨日期后的语义和一致性。普通 Todo 把任务当成一行 current state，但晷迹要求星期一未完成、星期二延续、星期三完成后，三个日期仍能准确解释发生了什么。因此我把领域拆成 TaskChain、版本化 TaskDefinition 和不可删除的 DayTrace，并建立延期、延续、回池和变更等显式关系。
>
> 架构上是 SwiftPM 模块化单体。NoonmarkCore 完全负责生命周期和投影；App 是 AppKit shell 加 SwiftUI 内容；SQLite repository 在一个事务里保存任务事实、同步 outbox 和自动分类 job。同步不直接复制数据库，而是通过 canonical SyncRecord、因果依赖、冲突和 transport seam 接 CloudKit、iCloud Drive 或本地文件夹。
>
> AI 是可选旁路。API Key 在 Keychain，对话和 Provider 记录进入 AES-GCM 加密 sidecar。模型不能直接持有任务写接口；对话只返回严格 schema 的 conversation artifact，用户编辑并确认后，系统生成绑定 snapshot 和 digest 的一次性 Todo diff，再调用普通 Core 接口。唯一自动例外是新任务分类，它通过独立 durable job 和 stale fences 受限提交。测试除了 XCTest，还会启动真实 `.app`，用物理键鼠、Accessibility、截图和 SQLite 回读验证，并对 DMG 做安装启动测试。

### 20.3 最值得讲的五个难点

#### 难点一：当前状态与历史事实分离

问题：

- 覆盖一行任务很简单，但会丢失真实轨迹。

设计：

- TaskChain 保持身份；
- TaskDefinition 表达任务定义／计划版本；
- DayTrace 表达某日事实；
- 变更建立新链；
- 回池只改变位置，不删除来源。

结果：

- 每个页面和历史都能解释同一件事。

#### 难点二：同步不是文件复制

问题：

- 多设备同时写时，同步 SQLite 文件会造成覆盖和不可解释冲突。

设计：

- canonical record；
- immutable create-or-exact-match；
- explicit causal frontier；
- durable pending；
- atomic download transaction；
- transport adapter。

结果：

- CloudKit 不再承载领域规则，其他端点可复用 merge engine。

#### 难点三：AI 权限

问题：

- 直接给模型任务写工具会扩大误写和隐私风险。

设计：

- 读取、远程发送和 Todo 写入三种权力分离；
- structured artifact；
- editable diff；
- snapshot/digest-bound authorization；
- apply receipt。

结果：

- 保留自然对话体验，同时让对话产生的 Todo 内容和生命周期写入可审查；自动分类则受独立窄授权与 fences 约束。

#### 难点四：SQLite 与 sidecar 跨存储提交

问题：

- 一个操作既改变任务数据库，又改变加密会话，无法共享数据库 transaction。

设计：

- application journal；
- before/after digest；
- phase commit；
- 启动 reconciliation。

结果：

- 崩溃后可以判定继续、完成或阻断，而不盲目重复应用。

#### 难点五：真实 Mac UI 验证

问题：

- SwiftUI 单测通过不能证明焦点、输入法、菜单、窗口和 DMG 安装正确。

设计：

- AppKit 原生控件；
- stable code signing 保持 TCC 授权；
- WindowServer 输入；
- AXUIElement；
- screenshot；
- SQLite 和日志对账；
- DMG 安装 harness。

结果：

- 验证覆盖用户真正使用的二进制。

### 20.4 高频追问与回答

#### 为什么不用 Core Data / SwiftData？

领域需要精确 schema、current 与 immutable record、同步 outbox、冲突证据、canonical bytes 和直接 SQL 探针。直接 SQLite 提供更明确的事务与约束控制。代价是代码量和 migration 成本更高。

#### 为什么不用 event sourcing？

系统需要历史，但不需要让事件日志成为唯一事实源。完整 event sourcing 会增加投影重建和版本演进复杂度。晷迹用关系事实表达当前与历史，只在真正需要的分类、同步和审计位置采用 append-only record。

#### 为什么任务变更要创建新 TaskChain？

标题小改是编辑；任务边界发生变化代表一件新任务。若继续复用原链，旧历史会被错误解释成新任务的执行史。新链加显式变更关系既保留历史，也能双向跳转。

#### 为什么延期和延续分开？

延期发生在当前日，表示用户主动改变计划；延续发生在历史未完成之后。它们的事实、统计和责任语义不同，因此不能共用一个状态。

#### 为什么不直接同步 SQLite？

文件同步不能安全合并两个离线设备的局部修改，也无法按 record 解释冲突。系统同步 canonical domain records，SQLite 只是本机 materialization。

#### CloudKit 为什么只是 adapter？

上传和下载属于 CloudKit；“这个 record 能否覆盖历史”属于领域。把合并写进 CloudKit 会导致其他端点重复实现并产生规则漂移。

#### AI 怎样防止越权？

Provider adapter 没有任务写 interface。对话输出先经过严格 schema，形成可编辑 artifact 和 diff；一次性 authorization 绑定版本、snapshot、日期和 digest；最终只调用 NoonmarkCore。自动分类是唯一例外，但只可写分组／标签，并受用户设置、job identity、generation、目录 revision 和内容 fingerprint 约束。

#### 用户停止模型时怎样处理？

取消真实 Swift Task 和网络 stream，保存已收到正文及 `.stopped` 记录，不把取消当故障；半截结构化 JSON 不形成产物。

#### 为什么 sidecar 不放主 SQLite？

AI 对话比普通 Todo 更敏感，默认不同步，删除和导出策略也不同。独立加密 sidecar 能建立清楚的隐私 seam，同时不让 AI 故障影响核心 Todo。

#### 如何保证本地 mutation 与同步 outbox 一致？

任务事实、snapshot generation、审计和 change journal 在同一个 `BEGIN IMMEDIATE` transaction 中提交。

#### 自动分类怎样避免覆盖用户操作？

job 保存任务内容、分类 fingerprint、目录 revision 和 generation。Provider 返回后重新检查所有 fence；用户手动修改后旧 job 进入 superseded。

#### 为什么 AppKit 和 SwiftUI 混用？

SwiftUI 提高界面表达效率；AppKit 提供成熟的窗口、菜单、文本系统、分栏、焦点和 Accessibility。两者在明确 seam 协作，比强迫一种框架承担全部职责可靠。

#### 最大技术债是什么？

`NoonmarkStore` 和 MacApp target 体积较大；手写 SQLite persistence 复杂；正式发布 migration、notarization 和 universal build 尚未完成。

#### 内存 Engine 和 SQLite 谁是事实源？

SQLite 是 Todo 的耐久事实源，Engine 是完整校验后的内存工作快照。mutation 在候选 Engine 上执行，repository 成功提交后 Store 才发布候选；失败时不改变当前 UI engine。

#### 用户 mutation、同步和日切怎样避免竞态？

用户状态在 MainActor Store 上排序；日切先 reconcile，失败会阻断后续日期相关 mutation；同步 transport 用 actor，下载以独立 SQLite transaction 提交后再回到 MainActor reload；后台写入还受 operation gate、单写者 lease 与 `BEGIN IMMEDIATE` 保护。

#### 两台设备同时完成或延期同一任务怎么办？

不是简单按到达顺序覆盖。DayTrace 使用终态感知合并，合法完成优先于陈旧 pending；撤销完成只在 Day 未锁定且符合显式 undo 形态时成立。延期／延续还校验后继 sequence、来源和拓扑；重复位置或不完整 component 进入 waiting／conflict，不发布半状态。

#### 10 万条任务表现怎样？

当前没有 10 万任务 benchmark，不能声称已满足。App 当前全量加载 snapshot 并建立内存投影，适合个人数据规模；发布前要先测冷启动、搜索、日历、同步积压和内存，再决定分页、增量投影或 compaction。

#### 正式发布后怎样 migration 和 rollback？

当前尚未发布，所以非空旧 schema fail-closed 并 clean cut。首个公开版本前必须为 SQLite、数据包和 sidecar 建立逐版本 migration、旧版 fixture、失败回滚和安装升级 E2E；在那之前不能声称支持用户数据升级。

#### 为什么不用 GRDB 或 SQLCipher？

当前直接 sqlite3 是为了精确控制 transaction、schema fingerprint、outbox 和探针，并避免第三方 runtime dependency；代价是大量 bind／decode 与 migration 代码。SQLCipher 解决主库应用层加密，但会引入密钥恢复和分发问题。若发布威胁模型要求用户持钥，或 persistence 复杂度超过团队承受范围，应分别重新评估。

#### 为什么不用 Xcode App project？

SwiftPM manifest 统一了模块与测试依赖，脚本能确定性组装、签名和验证 `.app`。代价是 archive、entitlement、universal 和 notarization 更手工；公开发布前可接入 Xcode archive，但不能形成第二套相互漂移的模块事实源。

#### journal 每个 crash phase 怎么恢复？

pending application 同时保存 before／after Engine 与 Session。启动时重载 SQLite：若是 before 就补写 after，若已经 after 就继续；其他 digest 阻断。Session 只接受 expected-before 或 already-after；receipt 已在 afterSession。最后验证 afterSession 才清 journal，清理结果未知则由文件 fence 解析。

#### `extraHeaders` 和同步／导出是否加密？

当前 Mac UI 不开放 `extraHeaders`；底层 adapter 虽支持，但在有 Keychain-backed value 或禁止 secret 规则前不应开放。Todo SQLite、JSON 导出和 sync records 没有应用层端到端加密，依赖 OS／Apple 账号保护；只有烛龙 sidecar 使用应用层 AES-GCM。

#### CloudKit 账号切换、配额或 token 失效怎么办？

当前有 account binding、持久 engine state、blocking reason 和 live gate，但完整双设备、账号切换与配额矩阵尚未闭环。因此默认 `.iCloud` 仍可走 iCloud Drive，不能把 CloudKit 描述为生产稳定默认。

#### task content 的 prompt injection 怎么办？

任务内容按不可信输入处理。scope 限制发送范围，输出必须通过 schema 和 typed evidence，Todo diff 仍需用户确认；这限制写入后果，但不保证模型文字完全不受注入影响。自动分类还必须通过固定 schema 和 stale fences。

#### 为什么 PR 不能跑 self-hosted UI E2E？

持久 runner 拥有 signing identity 和预授权 TCC。运行未审阅 PR 代码会把这些能力交给不可信代码，因此 PR 只跑 hosted check；合并到 main 后，受保护 runner 才执行真实 GUI 门禁。

#### 如果现在做 Windows 版，能复用什么？

不能直接复用 SwiftUI/AppKit，但可以复用：

- 领域词汇和状态机；
- 数据包 schema；
- SyncRecord 协议和合并测试向量；
- AI artifact schema；
- 权限模型；
- E2E 用户场景。

Windows 客户端应该按平台原生重写 UI 和 persistence adapter。

### 20.5 个人贡献与 AI 辅助口径

下面是填写模板，不是可以直接背诵的事实。只有与个人真实经历相符时，才把方括号替换为具体内容：

> 这是一个［个人／团队］项目。我主要负责［产品语义、领域建模、Mac 架构、存储、同步、AI 安全、测试／发布中的真实范围］。我亲自作出的关键决策是［两至三项］，亲自定位过的代表性问题是［同步计数、Provider 配置、右栏状态或其他真实案例］。我用［哪些工具／AI］加速［资料整理、样板实现、测试生成］，但需求边界、架构取舍、代码 review、真实 App 验收和最终发布判断由［真实责任人］负责。

建议准备两段真实故障案例，每段按“症状 → 错误假设 → 运行证据 → 根因 → 修复 → 症状级验证”讲。不要用“测试通过”代替用户路径，也不要把 AI 生成的代码行数说成个人手写产出。

如果本项目确实大量使用 AI 辅助，一个可信口径是：

> AI 帮我提高实现和检索速度，但我不把生成结果当事实。我用领域不变量、源码 review、独立测试、真实 `.app`、SQLite 回读、日志和安装产物逐层验收；出现漂移时先修改错误测试或设计，而不是为了绿灯降低门禁。

### 20.6 面试中不要夸大的内容

不要声称：

- 已经正式上架或 notarized；
- 已有生产用户数据迁移；
- S3 和 WebDAV 已完成；
- CloudKit 已完成所有双设备生产验证；
- 有在线后端；
- 已支持 Intel Mac；
- AI 可以自动管理全部 Todo；
- 主 SQLite、同步和导出已经端到端加密；
- 已验证 10 万任务性能或建立生产 SLO；
- 加密能防御已控制本机用户 session 的攻击者。

可信的回答应明确“已实现”“已验证”“规划中”的差别。

---

## 21. 当前完成度

### 21.1 已实现

- macOS 原生 App；
- Day Todo、任务池、未来计划、未完成池、已完成池、日历；
- 任务链、定义、日轨迹和子任务；
- 生命周期和有限撤销；
- 分组、标签、历史分类和自动分类；
- SQLite schema 11；
- JSON 数据包 v4；
- Local Folder、iCloud Drive 和 CloudKit adapter；
- OpenAI-compatible Provider；
- 烛龙加密会话、产物、停止、Todo diff 和任务池分析；
- 真实 App E2E；
- 交互 demo fixture；
- DMG 打包和安装验证。

### 21.2 受条件限制

- CloudKit 需要正确签名、profile、entitlement、账号和 live 环境；
- Provider live 验证需要用户显式提供凭证；
- 自动分类只有 Provider ready 时执行；
- visual regression 没有默认 golden，必须由用户确认真实 App reference。

### 21.3 已接受设计、尚未落地

这些不是当前源码能力，不能因为 ADR 已接受就描述成“已实现”：

- ADR 0011：Core-owned、明确授权、不可覆盖且可版本化的承诺快照，以及承诺兑现／实际产出分离；
- ADR 0012：本地历史基准与 LLM 情境判断并列的双通道承诺风险，以及校准资格；
- ADR 0014：有来源、版本、单位和不确定性的世界约束库。

当前 `TaskDefinition` 只是任务定义／计划草稿版本，不是承诺快照；源码中尚无 `CommitmentSnapshot` 或 `WorldConstraint` 对等模型。

### 21.4 尚未实现或未闭环

- S3、WebDAV、自定义在线服务；
- 在线优先后端；
- 正式数据库和 sidecar migration；
- Developer ID notarization / stapling；
- universal binary；
- 自动更新；
- 生产遥测服务；
- Windows / iOS 客户端。

---

## 22. 代码规模与维护提示

当前 Swift 代码约 18.7 万行：

- App 与 source modules 约 13.1 万行；
- Tests 约 5.3 万行；
- 其余为安装和 E2E 工具。

`NoonmarkMacApp` 约 7.1 万行，但包含大量 E2E automation，不能把这个数字等同于产品 UI 代码。

维护原则：

- 领域规则先进入 NoonmarkCore；
- presentation policy 优先进入 NoonmarkMacRuntime；
- transport 不拥有 merge 规则；
- Provider adapter 不拥有 Todo；
- UI 不自行推导历史语义；
- 同一问题出现多个调用点时，回到共享 Module；
- 测试通过 Module interface，不绕过 seam 验证实现细节；
- 最新源码和真实运行产物高于陈旧说明。

---

## 23. 证据与源码索引

### 构建与模块

- `Package.swift`
- `Makefile`
- `scripts/build-mac-app`
- `scripts/package-dmg`

### AppKit 与 SwiftUI

- `App/NoonmarkMacApp/NoonmarkMacApp.swift`
- `App/NoonmarkMacApp/NoonmarkRootView.swift`
- `App/NoonmarkMacApp/NativeWorkspaceSplitView.swift`
- `App/NoonmarkMacApp/MarkdownEditing.swift`
- `App/NoonmarkMacApp/NoonmarkStore.swift`
- `App/NoonmarkMacApp/WorkspaceShellViews.swift`
- `App/NoonmarkMacApp/SettingsPaneContent.swift`

### 领域

- `Sources/NoonmarkCore/Models.swift`
- `Sources/NoonmarkCore/NoonmarkEngine.swift`
- `Sources/NoonmarkCore/NoonmarkSnapshot.swift`
- `Sources/NoonmarkCore/TaskClassification.swift`
- `Sources/NoonmarkCore/AutomaticTaskClassification.swift`
- `Sources/NoonmarkCore/MutationClock.swift`
- `Sources/NoonmarkCore/TrajectoryTopologyValidator.swift`

### 日期

- `Sources/NoonmarkDayContext/NaturalDayContext.swift`
- `Sources/NoonmarkDayContext/GregorianCivilCalendar.swift`
- `Sources/NoonmarkMacRuntime/DayRolloverCoordinator.swift`

### 存储与数据包

- `Sources/NoonmarkStorage/SQLiteSchema.swift`
- `Sources/NoonmarkStorage/SQLiteEngineRepository.swift`
- `Sources/NoonmarkStorage/NoonmarkDataPackage.swift`
- `Sources/NoonmarkStorage/NoonmarkDataRootProcessLease.swift`
- `Sources/NoonmarkStorage/AutomaticClassificationJob.swift`

### 同步

- `Sources/NoonmarkSync/SyncRecord.swift`
- `Sources/NoonmarkSync/SyncRecordMapper.swift`
- `Sources/NoonmarkSync/SyncRecordMerger.swift`
- `Sources/NoonmarkSync/CurrentSyncRecordMerger.swift`
- `Sources/NoonmarkSync/SyncRecordTransport.swift`
- `Sources/NoonmarkSync/CloudKitSyncEngineTransport.swift`
- `Sources/NoonmarkSync/ICloudDriveSyncTransport.swift`
- `Sources/NoonmarkStorage/SQLiteLocalFirstSyncCoordinator.swift`

### AI 与烛龙

- `Sources/NoonmarkAI/OpenAICompatibleProvider.swift`
- `Sources/NoonmarkAI/AIPromptBuilder.swift`
- `Sources/NoonmarkZhulong/ZhulongSession.swift`
- `Sources/NoonmarkZhulong/ZhulongConversationArtifact.swift`
- `Sources/NoonmarkZhulong/ZhulongTodoDiff.swift`
- `Sources/NoonmarkZhulong/ZhulongApplicationCommitCoordinator.swift`
- `Sources/NoonmarkZhulong/ZhulongApplicationMutationClock.swift`
- `Sources/NoonmarkZhulong/EncryptedFileZhulongApplicationJournal.swift`
- `Sources/NoonmarkZhulong/EncryptedFileZhulongSessionRepository.swift`
- `Sources/NoonmarkZhulong/KeychainZhulongSidecarKeySource.swift`
- `App/NoonmarkMacApp/ZhulongProviderSettings.swift`

### 测试与交付

- `scripts/check`
- `scripts/test-e2e`
- `scripts/test-interactive-demo-fixture`
- `scripts/test-dmg-install`
- `.github/workflows/ci.yml`
- `.github/workflows/nightly-deterministic-sim.yml`
- `.github/workflows/release.yml`
- `Sources/NoonmarkDemoSupport/NoonmarkDemoFixture.swift`
- `Tools/NoonmarkDMGInstallHarness`

### 领域与决策文档

- `CONTEXT.md`
- `docs/product/phase-1-functional-spec.md`
- `docs/product/task-lifecycle-behavior-policy.md`
- `docs/product/task-classification-system.md`
- `docs/product/zhulong-ai-agent.md`
- `docs/design/mac-ui-design-contract.md`
- `docs/adr/`

---

## 24. 一句话结论

晷迹不是“用 SwiftUI 写了一个 Todo 列表”，而是一套以自然日执行事实为核心、通过深领域 Module 保持历史真实性，以 SQLite 支撑 local-first，以通用 record merge 支撑多端同步，并通过结构化授权把 AI 限制在可审查行动边界内的 macOS 原生桌面系统。

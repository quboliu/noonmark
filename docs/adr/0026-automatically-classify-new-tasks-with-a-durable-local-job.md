# 以本地持久工作自动归类新任务

**Status**: Accepted
**Date**: 2026-07-20
**Risk**: P 级——远程 AI、任务创建事务、分类事实、恢复与用户覆盖保护

## Context

智能分组与标签是晷迹的核心捕获能力。用户可以预先建立分组与标签，也可以保持空目录；无论从 Day Todo、未来日期、任务池、全局快速输入或经用户确认的烛龙 Todo diff 新建任务，晷迹都应在保存任务后自动为它选择一个分组和一组标签。现有分类 Module 已能原子复用或新建分类项，但原有契约把所有 AI 分类都视为等待用户确认的烛龙草稿，无法承载后台、可恢复的新任务归类。

远程 Provider 不能成为创建任务的可用性依赖。网络中断、额度不足、配置缺失或 App 退出时，用户刚输入的任务仍必须立即保存；与此同时，异步结果不能覆盖等待期间发生的用户手动分类，也不能把 Provider 请求包在 SQLite 写事务内。

## Decision

新增一个边界明确的 **新任务自动归类** 路径；它是原有“烛龙建议必须确认”规则的唯一例外，不授予其他 Todo、历史轨迹或批量分类写入权限。

### 事务与恢复

- 用户可见的新任务与一条本机专属的 **自动归类工作** 在同一个 `BEGIN IMMEDIATE` 事务中保存。任一写入失败则两者都不出现。
- Provider 调用始终在数据库事务外执行，并由单一串行 worker 领取；进程退出或重启后，已经获得付费授权的未终结工作继续运行。Provider 重新可用时，不得借恢复流程绕过历史积压的用户决定。
- Core 事实与同步 journal 的因果顺序使用 domain mutation clock；本机 durable job 的 `createdAt`、`availableAt`、claim、transition、lease 与 backoff 使用独立的 operational wall clock。需要同时保存领域事实与队列状态的原子事务必须显式携带两种时钟，禁止把可能领先于真实时间的 domain mutation clock 复用于队列生命周期。
- 工作队列只保存任务身份、任务内容与归类资格 digest、分类基线、目录 digest、尝试代数、状态和安全错误码；不保存 API Key、原始 Provider 响应或任务正文副本，也不进入同步记录或数据包。该 digest 不是 Provider request body 的摘要；当前任务定义身份与 mutation clock 也属于 fail-closed 资格边界，任何触碰该边界的变更都必须换新 generation，不能把旧 proposal 静默 rebase 到新事实。
- 每次调用成功先保存经严格解析和规范化的 typed proposal。若 App 在 Provider 返回后、分类提交前退出，恢复时复用该 proposal，不重复计费请求。
- 付费授权与工作生命周期是两条正交轴。Provider 可用时创建的新工作获得自动授权；Provider 不可用时创建的工作等待用户决定；用户明确启动历史积压后获得显式授权。授权决定以用户当时看到的精确工作集合做 CAS，不得把稍后进入队列的工作顺带放行。
- Provider 健康度由本机 durable circuit 独立记录。`open` 冷却到期后只能有一条工作进入 `half-open` 探测；成功保存 proposal 后才关闭 circuit。401／403 等确定性配置拒绝直接进入 `blocked`；429、5xx、超时和断网使用全局退避，不能让每条积压工作分别消耗完整重试次数。
- circuit 只引用不透明的 Provider execution revision，不保存 API Key、API Key hash、URL、模型名、请求正文或原始响应。显示名称、开关等不改变执行身份的保存不得废弃在途 claim；真正的 URL、模型或凭证变化才产生新 revision。
- Keychain 凭证以 execution revision 建立不可变项目。保存新身份时必须先写入新 revision 的凭证，再切换非敏感配置指针；Provider resolver 只接受与该次请求 revision 完全匹配的凭证引用。保存进程不删除旧 revision；只有下一次 fresh launch 观察到已经持久化的配置指针后，才在当前 App 的固定 Keychain service 内回收非 active 项目。显式清除则先完整删除该 service 的凭证，再删除非敏感指针；中断时宁可留下无凭证的可重试指针，也不能留下仍存在、却无法再由 App 识别的 Key。任一步骤崩溃绝不能把新凭证配给旧 URL 或模型。
- `proposalReady` 已经完成外部付费步骤，始终绕过 dispatch authorization 与 Provider circuit，只执行本地严格校验和提交。
- Provider 返回到 proposal checkpoint 落盘之间若发生 SQLite 瞬态竞争，worker 必须保留内存 proposal 与同一 claim 原地退避重试，不得重新调用 Provider。若进程在 checkpoint 前不可恢复地退出，而 Provider 又不支持幂等请求键，外部 exactly-once 无法由本机单方面保证；监控必须将该极窄窗口与已 checkpoint 的零重复恢复区分开。
- 最终分类项、当前关系、分类审计、同步 outbox 与工作完成状态在一个事务中发布；不得出现“显示已完成但分类没保存”或部分新建标签。

### AI 契约与最小数据

- 请求只发送任务标题、任务描述，以及 active 分组／标签的稳定 handle、显示名称和目录 revision；不发送内部 UUID、附言、历史、复盘、同步资料或其他任务。
- 远程 Provider 必须使用 HTTPS；HTTP 只允许 `localhost`、`127.0.0.1` 或 `::1` loopback，供用户本机服务和确定性 E2E 使用。
- 输出必须是严格 JSON typed proposal：恰好一个分组及一至三个 AI 标签。快速输入中用户显式给出的 `#标签` 必须保留，AI 可以补充但不能删除。
- 优先复用语义匹配的现有项；只有没有合适项时才提议新建。名称仍须经过分类 Module 的 canonical、近似重复和 lifecycle 规则，模型输出不能绕过领域验证。
- 自动新建项使用本地确定性颜色；Provider 不能决定任意 UI 色值或稳定身份。

### 覆盖保护与撤销

提交前必须同时验证任务仍可展示、任务内容与归类资格 digest 未变、任务当前分类 fingerprint 未偏离入队基线、目录引用仍有效，以及 claim／attempt／generation 完全匹配。任一 fence 失效都终止旧工作，不静默 rebase。排期与附言只有在不触碰当前任务定义资格时钟时才继续沿用原工作；其他定义 touch、Provider 可见内容或目录 digest 改变且用户分类基线未变时，队列以新 context／generation 原子取代旧工作。这是一笔可审计的新尝试，不是把旧 proposal 套到新事实上。

用户在等待期间手动修改分组或标签时，用户事实胜出，旧自动结果进入 `superseded`。快照撤销新建任务时，任务隐藏、自动归类工作取消，并对该任务的自动分类追加移除记录；重做只对“因本次撤销而取消”的工作重新入队。已经成功后又被用户手动清除的分类不得因重做自动复活。

### 失败与界面

- 未配置 Provider 显示 `等待配置 AI`；Provider 已可用但历史工作尚未授权时显示 `等待你开始`；运行中显示 `智能归类中…`；单项终结失败显示 `归类失败 · 重试`。
- Provider 首次可用且存在历史积压时，设置页显示准确数量，提供 `开始 N 项`、`仅处理今后新任务` 与 `稍后`。未作决定前不得发送历史任务；跳过只终结对应本机工作，不修改任务或手工分类。
- 401／403 和其他确定性 Provider 拒绝全局暂停；429、5xx、超时和断网采用全局有界退避与单一 canary，达到上限后全局暂停。不得按积压数量逐项烧穿失败请求。测试连接或真实 execution revision 变化可以恢复已授权工作，但不能替未授权历史积压作决定。
- UI 只增加一条贴近任务的轻量状态，不增加卡片、分组标题或重复说明。

## Consequences

- 普通捕获不再等待网络，失败也不会丢任务；分类最终一致，但在完成前允许短暂未分组。
- 自动分类拥有独立来源与审计，不伪装成用户直接操作、用户确认建议或确定性领域动作。
- 分类关系仍是可同步的普通领域事实；本机队列和 Provider 配置不跨设备同步。另一设备收到已归类事实后不得为同一同步任务再发请求。
- 导入、同步、seed、延续、回池、变更生成的继承任务链及复制为新任务的既有继承路径不自动入队；只有明确的新任务创建入口入队。
- 其他烛龙规划、排期、历史处置、批量分类和复盘写入仍必须预览并由用户确认。

## Rejected alternatives

- 创建任务时同步等待 Provider：网络和计费会成为 Todo 捕获的硬依赖，也会扩大持锁事务。
- 失败时静默使用关键词规则或固定模板：会把未验证 fallback 描述成 AI，并产生不可解释的分类库污染。
- 每次启动扫描所有未分类任务：会误处理导入、同步和用户有意留空的任务，且无法证明一次且仅一次的创建意图。
- 把队列放进 `NoonmarkSnapshot` 或同步：会跨设备泄漏运行状态并造成重复请求。
- 直接调用确定性分类提交接口：来源和 authority 不真实，无法表达用户覆盖与自动工作 fence。

## Rollback, rollout and monitoring

- 回滚以本 ADR 前的 Git commit 为边界；关闭自动归类 worker 后，已保存任务和已完成分类仍是合法普通事实，未完成的本地工作可由当前 schema 明确取消，不能删除任务。
- 当前未发布且执行 clean cut，不增加旧 schema 迁移或双读；开发数据库由 `scripts/reset-dev-data` 重建。
- 首次交付以默认启用的本机功能进入真实 `.app`，但只在 Provider 已配置时发请求；没有 deployed endpoint 或容器，不声称生产灰度。
- 本机诊断记录工作状态与授权状态计数、circuit 转换、尝试次数、规范化错误码、冷却区间、fence 作废与人工重试；不得记录 API Key、API Key hash、请求正文或原始响应。

## Verification

- AI contract 测试覆盖 DeepSeek/OpenAI-compatible JSON 请求、严格解析、现有项复用、新项建议和畸形响应拒绝。
- Core 测试覆盖自动来源 authority、原子应用、用户修改优先、目录 revision fence、撤销补偿及重做边界。
- Storage 测试覆盖任务与工作同事务、claim 恢复、typed proposal checkpoint、最终发布原子性、精确积压授权、跳过、全局 circuit、单一 half-open probe、重启及本地队列不进入同步／导出；并以领先 wall clock 的未来领域 frontier 验证新工作仍可立即 claim、队列 transition 不受未来领域时间污染。
- 真实 `.app` E2E 覆盖各新任务入口、等待配置、积压未授权零请求、显式授权、跳过、运行、401／429 全局背压、成功、失败重试、用户抢先修改和重启恢复，并用 Provider 请求计数、SQLite 探针与运行日志对账。
- Provider 设置 E2E 使用四个独立 App launch，依次覆盖“新 revision 凭证已写但指针尚未切换”、“新指针已发布但旧 Key 尚未回收”及“显式清除已删 Key 但尚未删指针”的确定性中断状态；每个后续 fresh launch 都对配置 revision、Keychain 项与 resolver fence 对账，最终由 App 与 shell 双重证明 E2E Keychain service 及配置指针已经清空。
- `scripts/test-ai-provider-live` 必须用本机显式 DeepSeek 配置走生产 provider 与自动分类 contract；缺 key 或依赖不可达时 fail-closed，不进入默认 `make check`。

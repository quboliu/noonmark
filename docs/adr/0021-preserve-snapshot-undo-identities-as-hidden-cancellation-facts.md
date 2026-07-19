# 把有限撤销新增身份保存为隐藏取消事实

**Status**: Accepted

晷迹的 snapshot undo 会把操作前的领域 snapshot 重新应用为一次新的前向写入。旧实现只遍历目标 snapshot 已存在的身份；若被撤销的操作创建了新的 Day、任务链、任务定义、日轨迹或子任务，这些 current-only facts 会从内存 snapshot 消失。

SQLite 采用 UPSERT，逐记录同步也只发布新 snapshot 中存在的实体。因此这种“消失”既不是持久化删除，也不是同步墓碑：当前进程看似撤销成功，重启后旧行会复活，其他设备也可能用旧 creation record 重新显示被撤销的内容。

## Decision

- `prepareSnapshotUndo` 不得移除 current-only 领域身份。它必须把同一批身份改写为 append-only、可持久化、可同步、默认不可见的取消事实：
  - current-only Day 保留，空 Day 不进入用户统计或导入摘要。
  - current-only 任务链改为 `abandoned`；redo 必须通过既有 chain reactivation witness 恢复同一身份。
  - current-only 任务定义保留。若所属任务链在撤销前已存在，例如历史任务重命名，新增定义以 supersession transition witness 退役，旧定义恢复为 current；redo 仍使用原定义身份。
  - current-only 日轨迹改为 `cancelledDraft`，写入稳定 `draftCancellationID`、`settledAt` 与取消日期。计划草稿回池继续使用“取消日早于计划日”的规则；snapshot undo 使用“取消日期等于轨迹日期”的明确关系事实，因此可以保留延续来源与进度快照，但仍不得成为 Day 历史。
  - 既有可见轨迹上 current-only 子任务改为 `cancelledDraft`，写入稳定 `draftCancellationID`、`settledAt` 与新的 `updatedAt`。若子任务属于同时被隐藏的 current-only 轨迹，它可以保留原 pending lineage，由隐藏父轨迹承担投影边界。
- Undo 与 redo 都是 Hybrid Logical Clock 前沿之后的前向版本。Redo 只能用同一 cancellation／transition witness、相同不可变身份字段和更新时钟恢复 `pending`／`active`；较旧或缺少见证的 creation record 不得复活取消事实。
- SQLite schema、数据包、ordinary sync payload、current-record merge 与 snapshot merge 必须完整保存取消身份和 exact Date bit pattern。保存撤销 snapshot 后重启，加载结果必须与撤销后的内存 snapshot 相同。
- Day Todo、任务池、未来计划、日历、搜索、进度、完成轨迹、导入摘要、AI scope／prompt、烛龙日结与所有 Mac UI projection 必须显式排除隐藏 trace／subtask facts。同步、持久化、mutation clock 与 recovery identity 则必须保留它们。
- 当前项目尚未发布，继续遵守 clean cut；不得为旧开发库增加迁移、兼容或物理删除分支。

## Consequences

- 有限撤销不再依赖“从 snapshot 删掉实体”的假删除，SQLite 重启和多设备同步不会复活被撤销的新任务、排期、延续、替换任务、重命名定义或子任务。
- Redo 保留原身份与 lineage，不制造第二条任务链、定义、轨迹或子任务。
- `cancelledDraft` 是跨 trace／subtask 的内部取消语义，但不是用户状态。任何 presentation switch 收到它都应 fail-closed，而不是映射成普通“已取消”文案。
- 空 Day、退役定义与隐藏后代会增加持久化事实数量；这是 append-only 可审计语义的预期成本，不能靠清理任务静默删除。

## Risk And Rollout

- 风险等级：P。主要风险是隐藏事实泄漏、definition transition 产生双 current、同步错误接受缺少见证的 redo，以及 SQLite UPSERT 后仍残留旧可见状态。
- 灰度：仅在 Core add／schedule／continue／change／rename／subtask undo-redo、SQLite restart、DataPackage、两种输入顺序 sync merge、AI／Search projection、真实 `.app` E2E 与 DMG 安装验证全部通过后合并。
- 监控：E2E 与 SQLite probe 同时对账 raw hidden row、用户可见数量、cancellation identity、exact clock、journal pending／failed 数量和重启后结果；console 不得出现 snapshot integrity、同步冲突或 presentation 泄漏。
- 回滚：以普通 `git revert` 回退本 ADR 对应提交并按 clean cut 重建开发数据。不得只移除投影过滤、只放宽 schema，或恢复从 snapshot 丢弃 current-only facts 的旧路径。

# FAIL-2026-08-04-12：飞光发布失败重复展示两个错误表面

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:24 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至修复前工作树
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由工作会话、Git diff、真实 SQLite 故障截图确认
- 修复提交：待回填

## 用户症状与影响

真实 SQLite 写失败时，Composer 内已显示「发布失败，草稿仍在这里，请重试」，页面底部又出现持久全局错误条，而且文案是「飞光修改未完成」。同一次失败占用两个视觉单位，新建与修改语义还相互矛盾，降低恢复入口的清晰度。

## 时间线

- 为 K3 review 补真实 SQLite `BEGIN IMMEDIATE` contention 后，失败截图首次稳定呈现重复错误。
- E2E 加入 `operationFailureNotice == nil` 症状断言，原实现稳定判红。
- Composer／行内编辑失败改为只记录强类型诊断证据，UI 恢复由本地 editor surface 独占；删除、Sticky Note 等没有本地恢复面的动作仍保留全局通知。

## 复现与证据

飞光专项 E2E 锁住真实数据库后按 `⌘Return`。修复前截图同时包含 Composer warning row 和底部全局 notice，E2E 返回 `real SQLite contention did not expose a recoverable publish failure`。修复后同一锁场景只显示内联说明与「重试」，诊断事件仍写入隔离 diagnostics，解锁后物理点击重试成功。

## 排除的假设

- 不是两个不同故障：两者来自同一个 `commitEngineMutation` error。
- 不是应删除诊断：问题是 presentation 重复，强类型 incident 证据必须保留。
- 不是所有 idea mutation 都应静默：没有本地恢复表面的删除、置入 Sticky Note 等操作仍需要全局反馈。

## 根因与破坏机制

首轮 Composer 重构新增本地 failed 状态，但沿用旧 `showOperationFailure(.ideaMutation)`。该 API 同时记录诊断和创建全局 notice；调用者已有局部恢复面后，没有把 evidence 与 presentation 两项职责拆开。

## 根因修复

Composer 创建与行内编辑 catch 改走 `recordIdeaEditorFailure`，内部只调用 `recordOperationFailureEvidence`。强类型 mutation gate 仍映射到本地、可操作恢复文案，特别是 pending Zhulong 会明确要求先完成恢复；任意 persistence error 使用隐私安全的通用本地提示。session 继续保留草稿、失败状态与本地重试；成功后照常 resolve 旧的同 context notice。

## 验证结果

- 重复 notice 的真实 App 红测已转绿。
- SQLite 写失败、草稿、焦点、选区、零误写、`.mutationRejected + idea + persistenceFailure` 诊断记录与重试成功全部通过。
- 完整 `make check` 尚待最终执行。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求 editor failure 走 evidence-only seam，并保留 E2E 无全局 notice 断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，以真实 SQLite writer lock 触发错误；重复 notice、草稿／选区丢失、误写或重试失败均判红。

## 发行与回滚

只使用 `e2e` profile。若回归，停止交付 Composer failure UI；不得关闭诊断、吞错或隐藏本地重试来减少视觉单位。

## 教训与永久约束

故障证据与故障呈现是两项职责。已有局部、可操作恢复面的输入组件，应独占 UI 反馈，同时继续经过统一诊断边界记录最小必要证据。

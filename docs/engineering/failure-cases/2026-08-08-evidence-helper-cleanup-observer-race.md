# FAIL-2026-08-08-01：evidence helper 清理观察器把已删除子目录误判为门禁失败

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-08T09:49:00-04:00
- 影响版本／构建：v0.2.5 build 22 候选，未发行
- 引入提交：`038e4e71f72b2d808e3327aae7b7f23f570f3850`（`fix(evidence): harden evidence paths and session lifecycle`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 资料不能证明实际操作者。
- 修复提交：`16eeb13b3b4fc8d4d8820fdc01135a60cfed53e4`（`fix(sync): close release-blocking regressions`）

## 用户症状与影响

发行前 `make check` 会在 evidence helper 生命周期门禁偶发失败，即使被测 helper 已正确退出并清理自己的临时根。失败会阻断候选发行；不影响用户资料或同步资料。

## 时间线

- 2026-08-08：完整门禁在 signal cleanup 情境出现 `find` 对已删除 helper 临时子目录的 `No such file or directory`。
- 2026-08-08：独立生命周期用例随即转绿，证明这是观察器与被测清理并发的竞态，而不是残留根目录。

## 复现与证据

原始完整 `make check` 在 intentional signal cleanup 后，以 `find` 读取已由 custodian 删除的 helper 根而退出 2。修复后连续三次运行 `scripts/test-evidence-helper-lifecycle` 均通过，覆盖 TERM、HUP、KILL、custodian rollback、截断 transport 与并行 session。

## 排除的假设

- 不是同步实现或 SQLite 资料损坏：同轮同步集成测试与真实 App pending-gate 路径均通过。
- 不是 helper 根残留：失败信息指向已经消失的目录，独立重跑能完成清理并转绿。

## 根因与破坏机制

观察函数以 `set -e` 直接执行 `find`。custodian 在枚举后、元数据读取前删除同一子目录时，`find` 返回非零；shell 把这个短暂的观察竞态升级为整个门禁失败。

## 根因修复

观察函数把 `find` 的短暂失败视为需要重试同一受控父目录的状态；只有在截止时间后仍能观察到匹配根时才报告 retained root。持续观察失败会明确报为不可检查，不能被静默接受。

## 验证结果

- `scripts/test-evidence-helper-lifecycle`：修复后连续三次通过。
- `make check`：修复后待最终候选 commit 全量回填。

## 永久门禁

- fast：生命周期脚本直接覆盖 custodian／signal 并发清理并由 `scripts/check` 强制执行。
- symptom：同一脚本以真实子进程、signal 与临时目录删除重现被观察对象的实际退出路径；任何持续残留仍 fail-closed。

## 发行与回滚

修复只改变测试观察器对已经删除目录的判定，不改变生产 App 或资料格式。若发布前门禁仍有残留根，将继续阻断发行；回滚只需回退测试脚本提交，不涉及用户资料。

## 教训与永久约束

并发清理的观察器必须区分「目录仍存在」与「目录在合法清理窗口消失」。对已拥有、稳定父目录重试可以消除观察竞态；不能用忽略所有 `find` 错误替代真实残留检查。

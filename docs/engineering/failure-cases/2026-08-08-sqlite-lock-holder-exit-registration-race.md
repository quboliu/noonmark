# FAIL-2026-08-08-02：SQLite 锁持有子进程退出登记竞态

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-08T15:16:17Z
- 影响版本／构建：0.2.5（build 22）候选，source commit `230baa48e9683907e42f07692a4e8335d1a8cd00`
- 引入提交：`9afac7343a3c3a1a1d01344488d0cb8a27a47efa` `fix(diagnostics): tighten diagnostic evidence and window query boundaries`
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；仅能由 Git 身份确认提交记录。
- 修复提交：`1a0132b84c6d0369c7267aadf9ba7026bfab5a88`

## 用户症状与影响

发布前真实诊断导出路径的 SQLite 锁持有子进程在正常释放后，偶发以 `errno=3 No such process` 失败。结果是 DMG validation 的诊断导出闭环可能被错误阻断，发行不能依据不稳定的本机验证放行。

## 时间线

- 2026-08-08：`make check` 的 1,507 项测试中，`DiagnosticExportLocksTests` 出现一次失败。
- 同日：以原始单测试连续执行 30 次，第 6 次重现相同 `register SQLite lock-holder exit` 失败。
- 同日：修复后原始单测试连续执行 60 次为 0 失败；新增 40 次真实 spawn／锁证明／shutdown 回归测试通过。

## 复现与证据

原始红测命令：

```sh
swift test --filter 'DiagnosticExportLocksTests/testSpawnedHolderProvesExactChildPIDInodesAndFourFDContract'
```

压力执行 30 次时，第 6 次捕获：`register SQLite lock-holder exit failed: errno=3 No such process`。失败点位于 `waitForChildExit` 的 kqueue `EVFILT_PROC` 登记与紧随其后的非阻塞 `waitpid` 之间；前者已看到子进程退出，后者尚未取得可回收状态。

## 排除的假设

- 子进程没有持有精确 SQLite byte-range lock：失败前 `proveLocks` 已验证 database 与 shared-memory 两把锁均由精确 child PID 持有。
- 子进程被其他测试回收：`waitpid` 只针对当前父进程创建的 child；压力测试每轮建立、证明并关闭独立 holder。
- 同步协议回归：失败发生在诊断 export harness 的 child reaping，未进入同步 transport 或 SQLite 同步协调器。

## 根因与破坏机制

`kqueue` 对已经进入退出窗口的 child 可能以 `ESRCH` 拒绝登记，而立即一次 `waitpid(..., WNOHANG)` 仍可返回 0。原实现将这组合法的瞬态状态误判为不可恢复的 POSIX 错误，未继续等待同一 child 变为可回收状态。

## 根因修复

保留正常 kqueue 等待路径；只在 `ESRCH` 且第一次 `waitpid` 返回 0 时，使用有界、单调时钟的 `waitpid(..., WNOHANG)` 回收循环。循环只服务已经验证的 exact child PID，保留原超时与其他 errno 的 fail-closed 行为，不扩大任何锁或运行身份边界。

## 验证结果

- 修复前：原始单测试 30 次中第 6 次失败。
- 修复后：原始单测试连续 60 次，0 失败。
- 新增 `testRepeatedSpawnedHolderShutdownReapsEveryExactChild`：40 次真实 child spawn、锁证明、release、reap，0 失败。
- `scripts/format` 与 `scripts/test-failure-case-gates` 必须通过；完整 `make check` 与 release 诊断闭环在本次发行流程中重跑。

## 永久门禁

- fast：`scripts/test-unit` 运行新增 40 次 exact-child reaping 回归测试。
- symptom：`scripts/test-release-diagnostic-closure` 在隔离 worktree 运行实际 App 的诊断导出、锁释放与重启闭环。
- release：`scripts/release-private-dmg` 强制执行上述隔离诊断闭环，失败时不允许签发私有 DMG。

## 发行与回滚

仅在完整 `make check`、同一候选 commit 的真实 E2E／lease evidence 与 `scripts/release-private-dmg` 全绿后创建并推送 tag。若 release 门禁重现此错误，停止 tag 推送；回滚为撤回候选，不操作 production profile、用户资料或同步端点。

## 教训与永久约束

对 child exit 的“已经不可登记”与“尚未可回收”必须视为同一个合法竞态窗口。进程生命周期代码在保留上限的前提下，应完成对 exact child 的回收，而不能把两次相邻系统调用的观察差异误报为业务失败。

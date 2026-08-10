# FAIL-2026-08-10-02：同步 transport 拒绝污染本机 outbox

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-09T02:33:27Z
- 影响版本／构建：0.2.5 build 24，source commit `4d7c2ca52d13dbea8dcf160c1c5d606dc23f6880`
- 引入提交：`1f264ff9c38047c8ac959e9d0cd624c70d495116` `fix(sync): replace full-history replication`
- Git author／committer：mxt <mxt@local.com>／mxt <mxt@local.com>
- 实际修改者：未知
- 修复提交：`b6cca0b70140fec507384508b90381eacc98b897` `fix(sync): make active runs safely stoppable`

## 用户症状与影响

升级后的 repository format guard 正确拒绝旧格式目录，但 upload coordinator 把这项 transport 级拒绝错误标记成每条本机记录的 corruption block。后续同步因此报告「部分本机资料无法安全生成同步记录」，即使本机记录仍能从当前 snapshot 正常物化。影响约为当次 outbox 的整批健康记录，并阻止后续 retry 收敛。

## 时间线

- 2026-08-09T02:33:27Z 与 2026-08-09T02:33:32Z：两次同步以 `syncProtocol/7`、detail `syncProtocol/205` 拒绝旧 repository format。
- 随后多次同步变成 `syncProtocol/4`，失去原始 transport format 原因。
- 2026-08-10：真实 SQLite regression 证明 format rejection 后健康 journal row 被移入 `blockedCorruption`；修复后同一 row 保持 retryable。

## 复现与证据

`SQLiteSyncUploadCoordinatorTests.testRepositoryFormatRejectionKeepsMaterializableUploadPending` 使用真实 SQLite snapshot／journal 与只拒绝 repository format 的 transport。修复前 `pendingUpload` 变成零且 `blockedCorruption` 增加；修复后 transport error 继续向上传播，journal 保持 pending。`testExplicitRecoveryRequeuesMaterializableCorruptionBlock` 证明显式恢复只重排能由当前 snapshot 成功物化的历史误伤记录。

## 排除的假设

- 排除本机 payload 真正损坏：同一 materializer 对当前 snapshot 与 journal row 成功生成 canonical record。
- 排除 repository format guard 错误：detail code 205 与旧布局一致，按批准方案 B 必须继续 fail-closed。
- 排除应自动重试所有 corruption block：真正无法物化的 row 必须继续隔离，避免 automatic sync 无限循环。

## 根因与破坏机制

`SQLiteSyncUploadCoordinator.uploadPending` 的 `catch SyncRecordTransportError` 无条件调用 `markBlockedCorruption`。该 error type描述 remote／transport acceptance，而不是本机 journal materialization；把两个 failure domain 合并后，一次 repository format 拒绝会永久改写整批本机 row 状态。后续 coordinator 只看见 blocked count，便将表象收缩成 generic code 4。

## 根因修复

transport rejection 只写隐私安全的 `uploadRetryPending` audit 并保留 `pendingUpload`，不再修改为本机 corruption。用户明确执行「立即同步」时，coordinator 会用当前 snapshot、既有 materializer 与 atomic upload unit 重新验证历史 `blockedCorruption`；只有完整成功物化的 unit 才原子重排为 pending，真正损坏的 row 不动。automatic sync 不执行这项历史恢复。旧 repository 不迁移、不兼容、不删除。

## 验证结果

两个真实 SQLite regression 已由红转绿，相关 upload coordinator 套件、`scripts/test-integration`、`make check` 与完整真实 App `scripts/test-e2e` 均在修复提交上通过。transport format rejection 后健康 row 保持 pending；显式恢复只重排可完整物化的 atomic unit，最终 queue 能上传收敛。原始症状、受害路径、fast gate 与 symptom gate 已全部闭环。

v0.2.6 build 27 候选在精确 commit `764f781076f72a80ccdefb976617ebb54b66bcda` 和同一 evidence run `release-v0.2.6-b27-20260810T151224Z` 上再次完成 `make check`、writer-lease E2E、完整 `scripts/test-e2e` 与 `scripts/release-private-dmg`；production App 未执行。

## 永久门禁

- fast：`scripts/test-integration` 执行真实 SQLite transport rejection、journal state 与显式 materialization recovery 测试。
- symptom：`scripts/test-e2e` 走真实 App 的同步失败、用户 retry、SQLite status、warning 清理与重启路径。

## 发行与回滚

风险等级为 P：涉及 outbox 状态与资料一致性。回滚只回滚本案例修复提交；不得删除 blocked rows 或旧 repository。灰度由 `audit` SQLite tests 进入 `e2e` 真实 App，再进入私有 DMG 全集。监控 pending／publishedLocal／blockedCorruption 数量、transport typed code、explicit recovery count 与最终 queue drain。

## 教训与永久约束

transport integrity 与 local materialization integrity 是不同 failure domain。只有 materializer 对本机事实的确定性失败可以形成 local corruption block；remote acceptance failure 不得改写本机资料健康结论。

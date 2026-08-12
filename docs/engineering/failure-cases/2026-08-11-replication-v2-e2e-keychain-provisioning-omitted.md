# FAIL-2026-08-11-23：V2 E2E 签名遗漏 Keychain provisioning

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-11T17:43:00-04:00 至 2026-08-11T17:51:00-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；V2 把 publication watermark 升级为 mandatory Data Protection Keychain 后，通用 E2E build 入口仍沿用无 entitlement 的稳定签名
- Git author／committer：不适用；尚无提交
- 实际修改者：Codex agent；可由本次 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

真实签名 Preferences E2E 启动 V2 后立即形成 `KeychainReplicationPublicationWatermarkError`，无法建立 clean-cut authority 或执行同步。若只看普通 build／unit，会误以为功能正常；若为让 E2E 通过而退回内存 watermark，则会绕过 V2 防止 SQLite rollback 后复用旧 producer epoch 的核心安全边界。

## 时间线

- V2 lifecycle automation 第一次走通真实 App 初始化时失败，typed incident 指向 publication watermark Keychain。
- 对签名 App 运行 entitlement 检查，确认 bundle identifier 正确且为 Apple Development 签名，但没有签入所需 Keychain entitlement。
- 对比独立 signed watermark gate 后确认，该 gate 已显式使用 provisioning profile 与 Data Protection Keychain signing；通用 `scripts/test-e2e` 没有使用同一构建边界。
- 统一 E2E build 后，Preferences 与诊断真实 App 均成功使用 mandatory Keychain watermark。

## 复现与证据

- 修复前，`scripts/test-e2e` 只调用 `scripts/build-mac-app <configuration> e2e`；真实 V2 Runtime 在 Keychain watermark 初始化处 fail-closed。
- `codesign` 运行产物证明失败 App 没有所需 entitlement；不是 bundle identity 或 SQLite schema 错误。
- `scripts/test-replication-watermark-keychain-signed` 已有三阶段真实签名 App 证据，证明正确 provisioning 下 Keychain 写入、重启读取与 SQLite mismatch epoch rotation 可以工作。
- 没有打印、复制或落盘 provisioning 内容；测试只接收调用者传入的 absolute regular profile 文件。

## 排除的假设

- 不是 Keychain 暂时不可用：同一机器、同一 `e2e` identity 在正确 provisioned build 下稳定通过。
- 不是应当增加 in-memory fallback：watermark 是防 rollback／fork 的 protocol truth，fallback 会让测试绕过 production 安全语义。
- 不是 provisioning profile 可选：只要 E2E 覆盖 V2 Runtime，就必须与真实签名 entitlement 对等；缺失必须在启动 App 前 fail-closed。

## 根因与破坏机制

V2 把 SQLite seal watermark 与 `ThisDeviceOnly` Keychain watermark 的 exact match 设为发布前置条件，但通用 E2E 的签名策略仍停留在“保持 designated requirement／TCC 稳定”。Apple Development 签名本身不自动产生 app 所需 entitlement；因此运行身份看似正确，Keychain access group 实际不可用。构建门禁与 Runtime 安全模型发生分层漂移。

## 根因修复

- `scripts/test-e2e` 在任何构建或 App 启动前要求 `NOONMARK_PROVISIONING_PROFILE` 为 absolute、regular、非 symlink 文件。
- 通用 E2E build 统一设置 `NOONMARK_DATA_PROTECTION_KEYCHAIN_SIGNING=1`、精确 provisioning profile 与 stable UI signing。
- 保持 Runtime fail-closed；不增加内存 watermark、跳过 Keychain、entitlement 猜测或测试专用降级。
- static evidence contract 固定上述三项签名边界，防止将来某个 E2E only mode 绕回无 entitlement build。

## 验证结果

- `scripts/test-e2e-evidence-contract` 已转绿并固定 provisioning／Data Protection Keychain／stable signing 三项契约。
- 真实签名 Preferences 三进程路径完成 failure、disable + join、restart 与 re-enable convergence。
- 真实签名诊断三进程路径完成异常终止与跨重启导出；最终 manifest 为 `suite_exit_status=0`。
- Keychain watermark 的专用签名门禁与 V2 recovery contract 已通过本轮定向验证；完整 `make check` 审计运行 `20260811T223945Z-98349` 也以 `suite_exit_status=0` 完成，且运行前后 worktree tree OID 一致。案例仍因修复提交尚未确定而保持「处理中」。

## 永久门禁

- fast：`scripts/test-e2e-evidence-contract` 固定通用 E2E 必须使用 absolute regular profile、Data Protection Keychain signing 与稳定签名；由 `scripts/check` 强制调用。
- symptom：`scripts/test-e2e` 用 provisioned 真实 App 运行完整 V2 生命周期与诊断路径，Keychain 不可用即形成真实失败；由 `scripts/test-all` 强制调用。
- release：`scripts/verify-development-validation-evidence` 只消费同 source／run、签名身份和证据 manifest 完整的 E2E 结果；由 `scripts/release-private-dmg` 强制调用。

## 发行与回滚

风险等级为 P：涉及签名、Keychain、producer epoch 与启动。缺少 entitlement 或 signed gate 时停止发行。回滚只撤回未发行 V2 App cutover并重建非 production profile；不得以 fallback 降低 watermark 安全性。灰度为专用 signed watermark gate → Preferences／diagnostic only mode → 完整 E2E／DMG validation。监控只记录 watermark match verdict、epoch rotation reason、typed Keychain result 与 restart state，不记录 access group、凭证或 profile 内容。

## 教训与永久约束

签名字符串相同不代表 capability 对等。只要运行逻辑依赖 entitlement，真实 App 门禁就必须从同一个 provisioned build 入口产生；测试不得通过替换安全依赖来制造绿色结果。

# FAIL-2026-08-07-02：DMG 身份验证器混淆目标身份与 cached-info 观察

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T07:01:10Z（0.2.4 (10) 最终发行证据对账判红）
- 影响版本／构建：0.2.4 (10) 本机候选，source commit `8a90e311f21a0e62a1164c44a4371e26bed243df`；不影响已交付版本
- 引入提交：`403110f0784a9a1ed89a3c9ffa5bafe1955cd2ff` fix(release): verify cached LaunchServices app identity
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：Codex agent（当前发行 session 的工具与会话记录可确认）
- 修复提交：`e1a27e23d6ae952eb20c48e94c150155d9f27a2f` fix(release): bind LaunchServices identity by subject ASN

## 用户症状与影响

0.2.4 (10) 候选完成正式 DMG 打包、静态验证，以及受控派生 App 的窗口、设置、Quick Entry、退出、重启、SQLite 回读和诊断导出后，最终证据对账报告 `DMG install exercise system runtime log has contradictory PID-bound App identity`（旧错误文字）并阻止发行。远端 tag 尚未推送，用户资料与 production App 均未触碰。

## 时间线

- 2026-08-07：`FAIL-2026-08-07-01` 首次修复加入 cached-info fallback，并要求目标进程输出的每条 cached-info 都同时包含 exact executable path、bundle identifier 与 `LSBundlePath`。
- 2026-08-07：同一候选的最终发行复跑真实归档三个阶段日志；真实交互全绿，最终 evidence consumer 因统一日志截断与无关 App 观察判红。
- 2026-08-07：取证确认三个阶段的直接 `appInfo`、PID、audit token、executable path、bundle path 和 identifier 全部一致；错误来自 cached-info 分类与可选字段语义。

## 复现与证据

1. 以 evidence run `release-v0.2.4-b10-20260807T061945Z` 运行 `scripts/release-private-dmg`；`scripts/test-dmg-install` 的真实用户路径先通过，最终 `scripts/verify-development-validation-evidence --scope full` 判红。
2. exercise／restart／diagnostic-export 的目标 App cached-info 分别归档 11／11／13 条；全部包含 exact executable path 与 bundle identifier，但 macOS unified log 在 `LSApplicationHasRegistered` 附近以 `<…>` 截断，未输出 `LSBundlePath`。
3. diagnostic-export 另有一条由目标进程打印、内容属于 BackgroundOnly App 的 cached-info。日志前缀只能证明谁执行了查询，不能证明 cached-info 描述的对象就是该进程。
4. 三个阶段均有一条直接 `CoreServicesUIAgent ... appInfo=`，其 exact path、bundle path、identifier 与从 audit token 反解的 PID 全部一致；因此不是 App 身份污染。

## 排除的假设

- 错误 DMG 或错误派生 App：正式包的版本、build、签名、UUID、dSYM、source-linked SHA 与派生边界均通过。
- PID 复用或跨阶段日志污染：每个日志只有对应阶段的目标 App PID，时间戳落在阶段窗口内，audit token 反解为相同 PID。
- 产品功能故障：真实窗口、物理输入、退出、重启、持久化和诊断导出均在判红前通过。

## 根因与破坏机制

`403110f` 把「目标进程打印某条 cached-info」错误等同于「该 cached-info 描述目标 App」，并把统一日志中未出现的 `LSBundlePath` 错当成矛盾值。LaunchServices cached-info 是进程对任意 App 身份的观察，且统一日志会截断字典尾部；旧判断同时混淆了观察者与被观察对象，也混淆了字段缺失与字段冲突。

## 根因修复

- 直接 `appInfo` 继续要求 executable path、bundle path、bundle identifier 与 audit-token PID 全部一致。
- 有直接 `appInfo` 时，从其中提取权威 LSASN；缺少 `appInfo` 时，仅由 executable path 与 bundle identifier 均完全一致的 cached-info seed 确定唯一 subject ASN，多 ASN 或无 ASN 均判红。
- 先由目标进程 observer 确定 fallback subject ASN，再从整份 phase capture 收集所有 observer 对该 subject ASN 的 cached-info 作为目标身份全集；任何 observer 查询的其他 ASN 不参与目标 App 身份判断。
- subject ASN 下每条 payload 都必须包含 exact executable path 与 bundle identifier；`LSBundlePath` 若实际出现则必须 exact，若被统一日志截断则不臆造缺失值。即使伪造 payload 完全不含目标字段，也不能逃过 ASN 绑定后的全集校验。

## 验证结果

- fast：`scripts/test-dmg-evidence-contract` 独立完整运行与 evidence run `release-v0.2.4-b10-20260807T081500Z` 的 `make check` 均通过；canonical／fallback、统一日志截断、其他 ASN、跨 observer 同 ASN 伪造、非法 subject、多个 exact subject 与可见错误 `LSBundlePath` 均完成正负向对账。
- symptom：同一 run 的真实 App E2E 通过飞光、子任务、Sticky Note、输入、退出、重启与 SQLite 等用户路径；`scripts/test-dmg-install` 从正式 DMG 受控派生 `dmg-validation` App，完成真实窗口、Settings、Quick Entry、退出、重启、AX／SQLite 恒等与锁中诊断导出。
- release：同一 run 的 `scripts/release-private-dmg` 输出 `Full development-validation evidence is internally consistent` 与 `Private DMG package and complete same-run validation evidence passed`，production App 保持 `production_app_executed=false`。
- 本轮 exercise／restart／diagnostic-export 的 canonical subject ASN 分别聚合 9／10／11 条跨 observer cached-info；其中目标 App observer 分别为 8／9／10 条。restart 阶段 `appInfo` 计数为 0，真实覆盖 fallback；其余两阶段各有一条权威 `appInfo`，真实覆盖 canonical 分支。
- 发行证明包 SHA-256 为 `4b7218f80623b7348e6107980f6eef51ab7ecd02600f0912cb1f699f5e0a723f`。两位独立只读 reviewer 最终均报告无剩余高／中 finding。

## 永久门禁

- fast：`scripts/test-dmg-evidence-contract` 覆盖权威 `appInfo` 与 fallback 两个分支中的截断目标 cached-info、同一进程查询其他 ASN、目标 ASN 下完整伪造 payload、错误 `LSBundlePath`、非法 subject 与多个 exact subject。
- symptom：`scripts/release-private-dmg` 先以 `scripts/test-dmg-install` 真实启动受控派生 App、归档全阶段统一日志和身份 ledger，再由 `scripts/verify-development-validation-evidence --scope full` 消费同一批证据；最终 consumer 是原始症状判红点。
- release：本机 `scripts/release-private-dmg` 要求同一 evidence run 内正式 DMG 静态门禁、真实安装路径与最终跨清单验证全部通过。

## 发行与回滚

风险限于发行证据消费，不改变 App 代码、production 身份或用户资料。回滚时撤回该验证器修正，保持远端 tag 不推送，并重新设计可稳定证明目标身份的证据；不得通过跳过最终 verifier 或放宽为任意 cached-info 存在来发行。灰度策略是先在本机候选重复执行 fast fixture 与真实 `dmg-validation` full verifier，全绿后才推 tag。监控分两层：本机 `release-private-dmg` 承担真实 GUI 与 full consumer 的 fail-closed release gate；GitHub-hosted tag workflow 复跑 `scripts/check` 中的 fast contract、打包和静态 `verify-dmg`，不宣称执行本机 GUI 门禁。

## 教训与永久约束

- 统一日志前缀标识观察者，不自动标识被观察对象；必须解析消息载荷再分类。
- 被系统截断的字段是未知，不是矛盾；只有实际出现且不一致的字段才能判为冲突。
- fallback 证据必须同时覆盖「合法变体能通过」与「部分冒充仍判红」，不能只测试理想化完整字典。

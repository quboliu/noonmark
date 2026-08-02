# FAIL-2026-08-02-05：PreferencesClock 临时同步根仍使用 symlink 路径

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02（现有运行证据只能把首次发现精确到本轮完整 E2E 尾段）
- 影响版本／构建：Noonmark 0.1.1（4），source commit `61d82a8dd7bbe6ee1eb0033b7ff5a3b5dea320b2`；该 source 已包含引入提交
- 引入提交：`699ea0cccba3fa0c10536305114f1e002ea49122`（`fix(runtime): 绑定运行身份与数据范围`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认实际操作者
- 修复提交：待回填

## 用户症状与影响

完整真实 App E2E 在尾段进入 `preference logical-clock remote setup` 时，目标 E2E App 在建立结果文件前以 `EX_CONFIG`（78）退出。套件只报告 result 未建立且 `setup.log` 为空，导致根因需要另做直接进程取证；发行门禁因此被阻断。

这不是已经证实的 production 用户功能或数据故障。失败只由 `app.noonmark.mac.e2e` 的内部 `--sync-folder-url` 参数触发，发生在偏好 HLC 场景开始前；没有启动、读取、定位或 reset production identity 与资料，也没有证据显示 SQLite、同步 payload 或 Open Panel 修复受损。

## 时间线

- 2026-07-18 23:49 -04:00：`3b40774c` 建立 PreferencesClock 真实 App 场景，并把同步 fixture 根固定为 `/tmp/noonmark-e2e-preferences-clock-sync-<pid>`；场景自身也只接受同一文字前缀。
- 2026-08-01 03:34 -04:00：`699ea0cc` 为内部 `--sync-folder-url` 增加 `NoonmarkRuntimeProfile.validateInternalPathOverride`，正确拒绝任一祖先为 symlink 的运行资料路径，但没有同步迁移既有 PreferencesClock 场景。
- 2026-08-02：完整 E2E 在 `preference logical-clock remote setup` 失败，只留下空 `setup.log`，没有 result、SQLite 或 state。
- 2026-08-02：`NOONMARK_E2E_PREFERENCES_CLOCK_ONLY=1` 隔离重跑稳定复现同一缺失 result。
- 2026-08-02：直接运行精确签名 E2E executable 并传旧 `/tmp` 根，进程在建立任何场景产物前以 78 退出。
- 2026-08-02：只把根改为 `/private/tmp` 的 A/B 运行已越过 runtime isolation、建立数据库与诊断资料，随后由场景自身的旧 `/tmp` 前缀 guard 明确拒绝，证明两个消费者同时漂移。
- 2026-08-02：静态枚举全部 `--sync-folder-url` 调用后，只有 PreferencesClock 把 `/tmp` 用作受保护运行资料根；普通导入的临时 JSON fixture 不属于同一边界。
- 2026-08-02，第一次修复专项运行：remote setup 转绿，但目录建立后通过 LaunchServices 启动的 Settings exercise 被新 `/private/tmp` guard 拒绝。最小 Foundation 探针证明 `standardizedFileURL` 对不存在的 `/private/tmp/<child>` 保留该拼写，对已经存在的同一路径却返回 `/tmp/<child>`；先前“standardized 会保持 canonical 拼写”的假设错误。
- 2026-08-02，第一次完整 `scripts/check`：1,440 项 Swift tests、确定性仿真与前序静态门禁均通过，最终由 DMG evidence contract 判红；合法 full fixture 仍手写旧 E2E inventory，没有建立新增 PreferencesClock SQLite。该失败证明 verifier 与 contract fixture 各自维护清单会再次漂移。
- 2026-08-02：把 full E2E 必需 inventory 抽成共享只读 producer，发行 verifier 与 DMG contract fixture 同源消费；合法 fixture 与逐项删证据 mutation 随后全部转绿。

## 复现与证据

隔离症状命令：

```bash
NOONMARK_E2E_PREFERENCES_CLOCK_ONLY=1 \
NOONMARK_EVIDENCE_RUN_ID=local-20260802-preferences-clock-isolate-1 \
scripts/test-e2e
```

修复前证据：

- `artifacts/e2e-preferences-clock/setup.log` 为零字节，`setup-result.txt`、SQLite 与 state 均不存在。
- `run_terminating_ui_probe` 看到进程已退出后仍无条件调用 cleanup，并以 `wait ... || true` 丢弃了真实退出状态，因此原始完整日志只能显示 result 缺失。
- `AppLaunchArguments.validateRuntimeDataIsolation()` 会把 `--sync-folder-url` 交给 runtime profile 校验；macOS 的 `/tmp` 是指向 `/private/tmp` 的 symlink，祖先 symlink 检查按 ADR 0043 正确 fail-closed。
- 精确可执行文件 A/B 只改变 `/tmp` 为 `/private/tmp`：旧路径退出 78；canonical 路径越过启动边界，随后命中 `PreferencesClockE2EAutomation` 的旧文字 guard。
- 第一次修复后的真实 App 运行证明 remote setup 已转绿；同一 `/private/tmp` 目录存在后，`URL.standardizedFileURL.path` 返回 `/tmp/...`，Settings exercise 因此在业务断言前被 guard 拒绝。该行为由独立、无 App 的 Foundation 探针稳定复现。

## 排除的假设

- Open Panel 外部 Helper 再次失败：PreferencesClock 不调用数据导入面板，进程在该场景启动前退出。
- 偏好 HLC 或本地文件夹同步算法失败：旧路径没有建立 SQLite／state；canonical A/B 已越过 bootstrap，失败点先于 HLC 业务断言。
- Provider bootstrap 缺少凭证：失败进程没有设置 live Provider 环境，且直接 A/B 只改变同步根路径便改变失败层级。
- runtime symlink 拒绝规则错误：ADR 0043 明确要求 leaf 或祖先 symlink fail-closed；放宽它会重新允许 E2E 路径重定向到范围外。
- 所有 `/tmp` fixture 都必须修改：静态调用审计显示，其他 `/tmp` 用法是普通一次性文件或已 canonicalize 的工具临时目录，不作为 `--sync-folder-url` 运行资料根。

## 根因与破坏机制

`3b40774c` 建立场景时，`/tmp` 仍能作为未经统一 profile 校验的同步 fixture 根。`699ea0cc` 后，内部路径在 App 启动阶段必须先通过禁止祖先 symlink 的运行身份边界；macOS `/tmp` 本身是 symlink，因此旧场景必然在自动化建立 result 前退出。

同时，场景内部 replacement guard 仍按字符串要求 `/tmp/noonmark-e2e-preferences-clock-sync-`。这使得调用方即使改传 canonical `/private/tmp`，也会在下一层被旧 guard 拒绝。根因不是安全边界过严，而是安全边界升级时没有静态枚举并同步更新既有消费者。

第一次修复还暴露了 guard 的第二个隐含假设：`standardizedFileURL` 不是“保持调用方 canonical spelling”的纯词法标准化。在 macOS 上，目标不存在与已经存在时，它会分别返回 `/private/tmp/...` 与 `/tmp/...`。PreferencesClock 恰好在第一阶段创建目录、后续阶段复用目录，因此用 standardization 结果做文字 scope 判断会发生跨阶段漂移。

## 根因修复

- shell 创建与 cleanup 统一使用 `/private/tmp/noonmark-e2e-preferences-clock-sync-<pid>`，保留每轮唯一、非生产且可回收的 fixture scope。
- `PreferencesClockE2EAutomation` 保存原始 `--sync-folder-url` canonical 参数，以 `/private/tmp` exact prefix、单层正整数 PID suffix 和 file URL 原始 path 一致性共同约束 replacement scope；不再用会按存在状态改写 `/private/tmp` 拼写的 `standardizedFileURL`，也不为系统 `/tmp` 建例外。
- `run_terminating_ui_probe` 在 result 缺失时区分进程已退出／仍运行，并保留真实 `wait` status，使未来 `EX_CONFIG` 不再被 `|| true` 吞掉。
- fast contract 同时约束 shell producer、Swift consumer、完整 E2E 聚合调用、旧 literal 禁令与 release inventory，防止再次只更新一端。
- full E2E inventory 由 `scripts/development-validation-e2e-inventory` 单点产生；release verifier 与 DMG evidence contract fixture 都调用同一函数，不再分别手写必需证据清单。
- release verifier 通过该共享 inventory 要求 PreferencesClock 的 SQLite、state、四阶段结果／日志、WindowServer 输入 trace、截图、远端记录、最终 winner snapshot 与 probe 全部进入同一 full E2E inventory。

## 验证结果

- 症状红：完整 E2E 与隔离 ONLY mode 均在第一阶段 result 缺失处判红；直接 executable 取得退出 78。
- 最小 A/B：只使用 `/private/tmp` 已越过 runtime isolation，并由旧场景 guard 证明第二个漂移消费者。
- 第一次修复未宣告完成：真实专项运行的 remote setup 转绿、Settings exercise 判红；最小 Foundation 探针据此推翻 standardization 保持 canonical 拼写的假设，并把 guard 收紧为原始参数加 exact PID suffix。
- Fast 绿：`scripts/test-e2e-evidence-contract`、`scripts/test-dmg-evidence-contract`（合法 fixture 与逐项删证据 mutation）、`scripts/test-failure-case-gates`（11 个案例）、`scripts/test-release-gate-contract`、shell syntax、SwiftFormat lint 与 `git diff --check` 全部通过。
- 专项 symptom 绿：run `local-20260802-preferences-clock-raw-canonical-2` 的真实签名 E2E App 依次完成 remote setup、原生 Settings 物理输入、stale-remote restart 与 persisted-failure restart；四个 result 均为 `ok`，SQLite／journal／audit probe 为 `1 1 3 3 0 1 2 10 3 1 6`，WindowServer input trace probe 为 `1 1 1 1 1 1`，suite exit status 为 0。
- 完整 symptom 绿：run `local-20260802-full-e2e-dirty-3` 的未过滤完整 E2E 使用 canonical `/private/tmp` 根完成 remote setup、原生 Settings 物理输入、stale-remote restart、persisted-failure restart、SQLite／journal／audit、input trace 与截图对账，probe 为 `1 1 3 3 0 1 2 10 3 1 6`，suite exit status 为 0。
- Release：待 clean repair commit 的同一 run 正式发行闭环后回填。
- 修复 commit：待回填。

## 永久门禁

- Fast：`scripts/test-e2e-evidence-contract` 由 `scripts/check` 强制执行，要求 shell 与 Swift 同时使用 canonical `/private/tmp`、拒绝旧 `/tmp` literal 与 `standardizedFileURL` scope 判断、强制单层正整数 PID suffix、保留 missing-result process／exit status，并要求完整 E2E 恰好调用一次 PreferencesClock probe。
- Symptom：`scripts/test-e2e` 由 `scripts/test-all` 强制以真实签名 E2E App 走完 remote setup、原生 Settings 物理输入、stale remote、持久化失败重启、SQLite／journal／audit 与 screenshot 对账。
- Release：`scripts/verify-development-validation-evidence --scope runtime/full` 由 `scripts/release-private-dmg` 强制同一 run／source 的完整 E2E inventory 持有 PreferencesClock 全套运行产物；ONLY mode 不得冒充发行证据。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：改动只影响固定 E2E 参数下的 fixture 路径和证据报告，不修改 production runtime、同步算法、schema 或 payload；主要风险是 shell／Swift prefix 再次不一致或 cleanup 遗漏 canonical 根。
- 回滚：若 canonical 场景引出未预期越界，整组回滚本案例修复并继续阻断发行；不得恢复 `/tmp`、放宽 ancestor symlink 校验、跳过 PreferencesClock 或删除 release inventory 要求。
- 灰度：fast contract → PreferencesClock ONLY 真实 App → 完整 E2E → clean 同一 run 的 check／writer lease／发行闭环；任一层失败立即停止晋级。
- 监控：对账 profile、bundle、sync root、进程退出状态、SQLite、四阶段结果、input trace、screenshot、source tree、run ID 与 `production_app_executed=false`。

## 教训与永久约束

1. 加强共享路径安全边界时，必须在真实运行前静态枚举全部启动参数消费者及其内部 guard。
2. canonical path 与文字 prefix 是一份协议的两端，producer／consumer／cleanup／release inventory 必须由同一 fast gate 同时约束。
3. missing-result 错误必须保留进程退出状态；吞掉 `EX_CONFIG` 会把启动边界问题伪装成自动化超时。
4. 系统提供的便利 symlink 也不能成为运行资料范围的隐式例外；调用方应直接使用 canonical path。
5. Foundation 的 file URL standardization 可能根据目标是否存在选择 `/tmp` alias；安全 scope 应校验保留下来的原始 canonical 参数与受限 suffix，不能把 display alias 当权限来源。

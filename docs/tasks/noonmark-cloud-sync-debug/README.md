# Noonmark 正式版本机诊断证据

- Task-ID：`noonmark-cloud-sync-debug`
- 风险等级：P
- 状态：诊断实现、运行隔离与自动化故障闭环已落地；等待私有候选 DMG 最终交付及下一次真实异常证据

## 目标

为正式版补齐有证据能力且严格控盘的本机诊断系统：以强类型事件串起同步、任务修改、持久化与跨重启状态；应用管理的诊断文件实际占用始终不超过 4 MiB、最长保留 7 天，用户主动保存的单个导出包不超过 8 MiB；不记录任务正文、路径、iCloud／同步内容、AI 内容或凭证，也不自动上传。

本任务不是对首次宿主机同步故障的根因修复。现有资料不足以证明该故障由哪个底层条件造成，因此不得把代码审阅或故障注入样本写成真实根因；本轮交付的成功标准，是下一次异常发生时能由用户主动导出足以检验假设的现场证据。

## 约束与验收

- 开发与测试不得启动 production `app.noonmark.mac`，也不得读取、定位、探测或 reset production 的 `noonmark`、`Noonmark/SyncRepository`、UserDefaults、cache、saved state 或 Keychain service。production 资料只属于用户日常使用。
- `development`、`e2e`、`demo`、`audit` 与 `dmg-validation` 各有独立 bundle、process、Application Support、iCloud repository、UserDefaults／cache／saved state 和 Keychain services；build／package 不 reset 或启动 App，运行入口只 reset 自己的非生产 profile。
- 用户可先查看摘要，再主动导出或清除诊断资料；清除只拥有诊断根，不能触及 Todo SQLite、烛龙 sidecar、同步仓库或数据包。导出包必须经过已知 schema 重建、第二层脱敏和 8 MiB 硬上限检查。
- MetricKit 只作非保证交付的补充；release 必须保留可与 Mach-O UUID、最终签名 binary SHA 和 source-linked SHA 对账的 dSYM。
- 真实 `e2e` App 必须闭合“同步失败／停滞 → transport lock wait → 任务修改被拒绝 → SIGKILL → 重启 → Help 菜单导出”，并对账 operation／incident、previous-session interruption、持久化失败、4 MiB／8 MiB 容量及隐私哨兵。
- production DMG 只接受静态门禁并证明 `production_app_executed=false`；动态安装验收只运行从该精确 package 受控派生的 `app.noonmark.mac.dmg-validation`，且只使用 `noonmark-dmg-validation` 与 `Noonmark-DMGValidation/SyncRepository`。
- 当前只交付稳定 Apple Development 签名的私有 DMG，由用户自行下载、安装与启动；不建立公开下载页或 GitHub Release，也不宣称 Developer ID、公证、staple、Gatekeeper 或公开分发能力。

详细设计、风险、灰度、回滚与门禁见 `docs/adr/0042-use-bounded-typed-local-diagnostic-evidence.md` 和 `docs/adr/0043-isolate-runtime-data-and-split-dmg-validation.md`。

## 已交付

- 版本与发行身份能力已经落地；当前候选预留为 `0.1.1 (4)`，拟包含异步 App 入口造成的 MainActor 饥饿根因修复，以及 build 3 暴露的 WindowServer 发行验证回归修复。build 4 在真实 `dmg-validation`、完整 `make check` 与最终 clean-source 重打全部通过前不得宣称已交付。“关于晷迹”与发行 manifest 可对账 Version、Build、Commit、UTC Build Date、OS 与架构，打包链另外保留 Mach-O UUID、binary SHA、dSYM 和 DMG identity。
- 同步、任务修改、持久化、启动与退出路径写入固定 schema 的强类型事件；operation ID、incident ID 与 active marker 可跨重启关联，长时间同步只记录安全进度变化与有界心跳。
- App 管理的证据按实际 allocated size 执行 4 MiB 硬上限与 7 天保留；critical drop、compaction、corrupt、oversized 与 Metric eviction 均进入 manifest，不把缺失伪装成完整证据。用户主动导出的 `.noonmarkdiagnostics` 另受 8 MiB 硬上限约束。
- 诊断文件操作固定在初始化时持有的目录 descriptor 下；读取、轮替、删除和 MetricKit 采集均验证文件身份、owner、link count 与类型，并对序列耗尽 fail-open 关闭 file sink。
- 用户可在 App 内预览、导出和清除诊断资料；不会自动上传，也不会记录任务正文、路径、同步 payload、Provider 内容或凭证。操作与分析流程见 `docs/engineering/noonmark-diagnostic-reporting.md`。
- 六个运行 profile 与 reset 所有权已在 Swift、shell、bundle metadata 和 fixture contract 中对账；production profile 不可 reset，所有可执行开发／测试入口固定使用自己的非生产身份。
- release 链把 production DMG 的静态来源、签名、版本、binary、dSYM 与 inventory 证据，和 `dmg-validation` 派生 App 的 WindowServer／SQLite／重启／日志证据分开记录，不把派生结果冒充 production runtime。

## 当前证据与发行边界

- 测试数量不在本文固化；每个候选必须以当次命令输出、manifest、checksum 和 inventory 为准。快速契约至少覆盖 runtime profile isolation、诊断日志 guard、诊断隐私边界、E2E evidence contract 与 DMG evidence contract。
- `scripts/test-e2e` 的真实 App 故障闭环先建立一笔旧的已持久化同步失败，作为重启后必须被当前事故替换的基线 canary；第二次同步停在精确 lock-wait stage 后拒绝一次任务修改并 SIGKILL 精确进程。重启后，当前 stalled operation 与 mutation incident 必须共同串起 stage、修改拒绝、previous-session interruption、SQLite 最新失败和 `persistedSyncFailureLoaded`，再从真实 Help 菜单导出并扫描 8 MiB 上限与隐私哨兵。该样本验证采集能力，不是首次宿主机故障的复现或根因。
- `scripts/test-dmg-install` 不启动 production App。它先静态验证 mounted package，再派生并运行 `dmg-validation` App，完成真实 WindowServer、SQLite 写入、退出／重启、unified log 与 DiagnosticReports 门禁；runtime manifest 必须固定报告 `production_app_executed=false`。
- 计划中的用户恢复路径由用户本人执行：保留已导出的 canonical JSON，删除自己的 production 同步目录，安装私有候选 DMG，再导入 JSON 继续使用。开发／测试工具不得代替用户读取、删除、备份或迁移这些 production 资料。
- 若再次出现同类异常，用户需提供 `.noonmarkdiagnostics`、完整“关于晷迹”版本信息、诊断编号、发生时间与可见症状；若 macOS 同时生成 crash／hang `.ips`，再由用户主动附上。只有这些真实证据到达后，才能重新进入根因诊断与修复审批。

## 风险、发布与回滚

- 风险：敏感内容泄漏、日志风暴突破配额、诊断 I/O 改变业务语义、跨重启错误归因、profile 漏接资源，以及把 validation 派生证据误报为 production runtime，全部按 P 级处理。
- 发布监控：阻断条件包括 4 MiB／8 MiB 超限、隐私哨兵命中、unknown schema、critical evidence 缺失、`mktemp` HOME 内 synthetic production canary 改变、任一非生产入口出现未经允许的 production literal、dSYM／UUID／SHA 不一致或 `production_app_executed` 非 false。监控不得读取真实 production 根建立 canary。
- 灰度：先通过纯契约和隔离真实 App E2E，再通过 production DMG 静态验证与 `dmg-validation` 动态验证，最后才把同一 Apple Development 签名 DMG 私下交给用户自行安装；任何阶段都不自动上传资料或公开分发。
- 回滚：可以停止交付候选并整体关闭 bounded file sink／MetricKit 缓存，保留最小 Apple `Logger`；不得为回滚触碰 production SQLite、iCloud、Keychain 或用户导出的数据包，也不得恢复旧的 production-owning reset。

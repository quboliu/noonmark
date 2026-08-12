# FAIL-2026-08-11-15：iCloud 删除能力逃逸 append-only 门禁

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T15:00:00-04:00 至 2026-08-11T15:59:59-04:00
- 影响版本／构建：未发行的 Local-First Replication V2 工作树
- 引入提交：未提交；既有开发 reset 与 CloudKit live validation 代码早于本轮铁命
- Git author／committer：不适用；尚无修复提交
- 实际修改者：历史实际操作者未知；本轮修复由 Codex agent 完成，可由 session 与工作树确认
- 修复提交：待回填

## 用户症状与影响

用户明确要求任何 iCloud 资料都不得由 App、Agent、脚本或测试删除、覆盖、移动或改名，并要求每轮真实测试永久保留。双轴审查发现 `scripts/reset-dev-data e2e` 的边界仍覆盖整个 `Noonmark-E2E`，因此能删除 `AppendOnlyLiveTests`；CloudKit transport 也仍公开远端 zone 删除入口。即使正常 live script 没有调用它们，代码库仍保留违反铁命的可达破坏能力。

## 时间线

- 用户建立最高优先级 append-only 铁命后，初版 guard 只扫描 live script 与 iCloud V2 adapter。
- 双轴审查从调用图发现 `scripts/test-e2e → scripts/reset-dev-data e2e` 仍可命中真实测试顶层根。
- 新增静态判红后，旧 reset helper 因含 CloudDocs／iCloud target 字面量稳定失败。
- 修复移除 reset 的全部 iCloud target，而非缩窄到另一个可能漂移的子路径；CloudKit zone 删除 API 同时删除。
- 最终复审又发现协作入口前段仍残留「reset 删除 iCloud 顶层根」的旧文字，虽然实际代码已经保留 iCloud，仍会误导后续 Agent 重新引入删除能力；同一 fast gate 随即扩展为拒绝这项矛盾授权。

## 复现与证据

`scripts/test-icloud-append-only-guard` 对 reset script、boundary helper、V2 endpoint、共享 file publisher 与 CloudKit transport 做静态能力审计。修复前命中 iCloud reset target；修复后门禁通过。`scripts/test-runtime-profile-isolation` 在隔离 fixture 中执行 profile reset，并证明 iCloud canary 与 append-only live data 原样保留。

## 排除的假设

- 不是 live test 当前没有调用 reset 就安全：永久约束必须消除所有可达删除能力，不能依靠调用者自律。
- 不能只把 e2e 删除范围改成 `SyncRepository`：用户铁命禁止删除任何 iCloud 资料，未来目录改名仍会重新产生边界漂移。
- 不能在测试后清理新 round：每轮证据依要求永久保留。

## 根因与破坏机制

旧设计把「本机 profile reset」与「远端 iCloud repository reset」放进同一 helper，并以 profile 顶层目录代表所有该 profile 资料；新的 append-only live namespace 后来成为该顶层目录的后代。安全门禁又只扫描直接 live adapter，没有审计 reset 与遗留 CloudKit transport，导致删除能力逃逸。

## 根因修复

- `scripts/reset-dev-data` 与 boundary helper 完全移除 iCloud target、路径计算及删除验证；reset 只处理本机非 production 资料，并明确报告 iCloud preserved。
- `AGENTS.md` 的 profile reset 约束同步改为只处理本机资料，并明确禁止 reset 读取、定位或修改所有 iCloud 资料；guard 对旧矛盾文字 fail-closed。
- runtime profile isolation 将 iCloud fixture 从「应删除」改为「必须完整保留」。
- append-only guard 扩展到 reset helper、V2 wrapper、content-addressed endpoint、bootstrap、共享 publisher 与 CloudKit transport。
- 全量真实 iCloud 压力入口本身也进入能力审计，并强制先在独立 Local Folder root 完成相同签名 App 导入、增删改、收敛与重启；该症状前置失败时，脚本不得生成 session／round，也不得写入 iCloud。
- 删除 CloudKit live-validation zone 的远端删除 API 与测试，不保留隐藏开关或兼容入口。

## 验证结果

- `scripts/test-icloud-append-only-guard`：通过。
- `scripts/test-replication-v2-app-stress-contract`：通过；静态证明 Local Folder exercise／restart 完整结束后才可开始 iCloud exercise，且 iCloud 路径不接受任意 `--sync-folder-url`。
- `scripts/test-runtime-profile-isolation`：通过；隔离 iCloud canary 与 live data 均保留。
- production App／资料未启动、未读取、未修改；所有既有真实 iCloud round 保持原样。

## 永久门禁

- fast：`scripts/test-icloud-append-only-guard` 由 `scripts/check` 强制执行，任何 reset iCloud target、协作文档重新授权删除、远端删除 API、destructive file API 或真实 live runner 绕过 Local Folder 前置即判红。
- symptom：`scripts/test-runtime-profile-isolation` 由 `scripts/check` 强制执行，真实 reset fixture 必须证明本机资料清理与 iCloud 永久保留同时成立。

## 发行与回滚

当前未发行。若门禁回归，停止所有真实 iCloud 测试与发行，不执行任何远端回滚或清理；代码回滚也不得恢复 iCloud 删除能力。灰度只允许全新 append-only round，监控每轮 inventory／digest 单调扩展。

## 教训与永久约束

append-only 不是调用约定，而是 capability boundary。任何可执行删除入口即属故障；安全审计必须覆盖 adapter、共享 file module、reset、live helper 与遗留 transport 的完整调用面。

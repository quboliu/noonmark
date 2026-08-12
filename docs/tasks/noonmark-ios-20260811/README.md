# 晷迹 iOS 版本首个可运行切片

- Task-ID：`noonmark-ios-20260811`
- 状态：实现已完成，完整 parity 仍在进行中
- 范围：iOS development Simulator、共享 Core／Storage／Sync／AI 边界、JSON 数据包导入、真实 UI symptom gates

## 目标

在不读取 production 资料的前提下，为晷迹建立可运行的 iOS development target。iOS 必须复用现有领域规则和 SQLite snapshot 语义，提供今日 Todo、任务池、重复计划、日历复盘、飞光、Sticky Note、分类、设置、烛龙配置、数据包导入导出和诊断边界的第一轮原生交互；页面存在不等于能力完成，必须以真实 Simulator 用户路径和重启回读作为证据。

## 已交付

- 新增 `app.noonmark.ios.development` iOS target、Xcode project generation、Store 和原生页面。
- 以共享 `NoonmarkCore`、`NoonmarkStorage`、`NoonmarkSync` 和 `NoonmarkAI` 为能力边界；iOS 缺少 CloudKit／iCloud 条件时 fail-closed。
- 接入 `NoonmarkDataPackage` JSON 导入／导出、完整性校验、导入确认和事务性 SQLite 替换。
- 在固定 development Simulator 中导入用户提供的数据包，重启后真实页面显示；SQLite 对账为 252 个 days、938 条 day traces、1035 条 task chains 和 31 条 idea entries。
- 增加 iOS unit/UI tests、target contract、failure-case gates，并修复已发现的 compact navigation、SwiftUI alert 路由、飞光导航和日历长滚动等症状。

## P 级风险与处置

- 数据完整性：导入只接受通过 `NoonmarkDataPackage` 校验的 snapshot；替换失败时保留当前引擎，不改 production schema。
- 同步误报：development Simulator 不宣称 CloudKit 或跨设备同步成功；缺少 entitlement、account 或真实 transport 证据时保持不可用。
- AI 隐私与运行条件：没有明确的 provider endpoint、model 和开发凭证时不宣称 live AI 通过；日志不保存正文、prompt、response、路径或凭证。
- 回滚：移除新增 iOS target、iOS sources、project generation 和 iOS-specific platform seams；共享 Core API 只有在 Core 回归通过后才保留。
- 灰度：仅使用固定 `app.noonmark.ios.development` Simulator 或明确的 development 真机 profile，不触碰 `app.noonmark.mac` production 身份。
- 监控：保留结构化阶段、计数、稳定 ID、失败 reason code 和重启恢复状态；不上传诊断资料。

## 验证证据

- 固定 iOS Simulator UI suite：9 项 UI tests、0 failures，覆盖任务、重复计划、飞光、Sticky Note、分类、日历复盘、详情编辑和重启回读。
- `scripts/test-ios-target-contract`、`scripts/test-failure-case-gates`（83 cases）、`scripts/format --lint` 和 `git diff --check` 通过。
- 完整 `make check` 自然退出 0；DMG evidence helper lifecycle、DMG evidence contract 和 release gate aggregation 均通过。
- 当前没有 iOS archive／signing／CloudKit 双设备或 live AI provider 运行证据；这些条件不在本任务中虚构为已完成。

## 交接与后续

继续开发时，应优先补齐年度规模、设置／数据包完整 UI、真实同步双端、诊断故障闭环和 delegated planning 的 iOS symptom gates。任何新增故障必须先登记 failure case，再建立 fast gate 与真实用户路径 gate。

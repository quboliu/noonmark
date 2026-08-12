# FAIL-2026-08-11-08：iOS 分类硬删除确认弹窗未呈现

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-11T17:32:00-04:00
- 影响版本／构建：iOS development Simulator 工作树；未提交 source
- 引入提交：待回溯；故障由分类真实 Simulator 症状门禁暴露
- Git author／committer：基线提交记录中的仓库 author；本次未提交
- 实际修改者：未知
- 修复提交：`00c17fa`

## 用户症状与影响

在设置的分类目录中，归档并恢复标签可以完成，但点击硬删除后确认弹窗没有出现，用户无法完成删除；测试若继续点击会把系统取消按钮误当成确认，导致路径没有完成。

## 时间线

1. 分类 Simulator 路径首次在硬删除确认步骤失败。
2. SQLite 运行日志证明归档与恢复已经写入，问题集中在确认 UI 呈现，不是分类目录事务失败。
3. 源码审计发现同一 SwiftUI view chain 同时挂载删除和合并两个 `.alert(item:)` modifier。
4. 两个弹窗路由合并为一个 `ClassificationAlert`，删除确认按钮按稳定标题点击；focused UI gate 已转绿。

## 复现与证据

- 固定设备：`Noonmark iPhone 17 Pro`，iOS Simulator 26.3.1，bundle `app.noonmark.ios.development`。
- 修复前 focused XCTest：创建、搜索、归档、恢复通过；硬删除确认弹窗未出现。
- 修复后 focused XCTest：`testUserCanSearchArchiveRestoreAndDeleteClassificationInSimulator` 执行 1 项、0 failures；日志显示“删除”按钮出现并点击，标签随后从目录消失。

## 排除的假设

- 不是分类写入失败：归档和恢复状态均在 SQLite 中真实变化。
- 不是测试点击了系统 Cancel：测试已改为按确认按钮标题选择，并由运行层观察到确认按钮出现。
- 不是分类查询缓存：硬删除确认后的目录查询不再返回该标签。

## 根因与破坏机制

SwiftUI 同一 view chain 上的多个 `.alert(item:)` 竞争 presentation，删除状态有时不能获得弹窗呈现资格。于是删除事务从未获得用户确认，症状表现为“按钮点了但没有确认弹窗”。

## 根因修复

删除与合并统一进入单一 `pendingAlert` 路由，由一个 `.alert(item:)` 根据枚举分派标题、消息和操作；确认操作仍经过既有分类事务与 blocker 校验。

## 验证结果

修复后的 focused 症状门禁已转绿；完整 iOS Simulator 套件已执行 9 项 UI tests、0 failures。修复提交为 `00c17fa`，案例标记为「已修复」。

## 永久门禁

- `scripts/test-ios-target-contract`：保证分类目录与硬删除 UI 测试入口存在。
- `scripts/test-ios-simulator`：固定 Simulator 必须真实创建、搜索、归档、恢复、确认硬删除并在目录中消失。

## 发行与回滚

当前没有 iOS 发行入口。若分类目录增加新的确认操作，必须复用单一 alert 路由；回滚只能回到仍通过分类创建、归档、恢复和硬删除症状门禁的版本。

## 教训与永久约束

同一个 SwiftUI presentation 类型在一个 view chain 上只能保留明确的单一状态路由；增加第二个 `.alert` 前必须先证明 presentation ownership 和真实确认按钮路径。

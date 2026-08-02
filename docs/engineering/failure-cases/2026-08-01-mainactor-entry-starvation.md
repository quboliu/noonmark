# FAIL-2026-08-01-01：异步 App 入口饿死 MainActor 任务

- 状态：处理中
- 首次发现：2026-08-01，安装构建执行数据导入时
- 影响版本／构建：Noonmark 0.1.1 (2)，source commit `9ca5b44f47179ec04da76147d2b0b81d7fdb0f45`
- 引入提交：`688d9b0bfbf4d4d212663a0a3f7734c436bdb985`，`fix(diagnostics): 收紧启动与错误映射边界`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 记录只能证明 author／committer identity，不能证明内容由本人还是 agent 实际编写
- 修复提交：待回填

## 用户症状与影响

在真实安装构建中选择有效的 Noonmark JSON 后，`NSOpenPanel` 正常关闭，但不出现「替换当前所有数据」确认页，界面仍为空，SQLite 没有写入，应用也没有显示失败提示。转换后的 JSON 已由当前 decoder、隔离 SQLite replace 及重启回读验证有效，因此数据包不是原因。

影响面不局限于导入。启动后的 `Task { @MainActor in ... }` 均无法开始，包括退出前输入 flush、部分同步 automation 与自动分类 worker；导入只是最先被稳定观察到的受害路径。原始 0.1.0 同步故障是否具有相同根因仍未得到证据证明，不在本案例中合并归因。

## 时间线

- 2026-08-01 05:57 -04:00：引入提交的 author date；入口由同步 `main` 改为异步 `main`。
- 2026-08-01 06:41 -04:00：`688d9b0` 写入仓库。
- 2026-08-01：包含该提交的 0.1.1 (2) 安装构建复现静默导入失败。
- 2026-08-01：LLDB、SQLite 与诊断资料完成交叉取证；Kimi K3 独立复核根因。
- 2026-08-01：隔离真实 App 数据导入 E2E 在修复前稳定失败、修复后转绿。

## 复现与证据

原始安装构建的症状级路径为「File → Import → 真实 `NSOpenPanel` → 选择有效 JSON」。取证结果如下：

1. `panel.runModal()` 返回 `.OK`，且 `panel.url` 非空。
2. Swift runtime 的 `swift_task_create` 断点命中，证明导入 Task 已创建。
3. Task closure 入口、`prepareDataImport`、`NoonmarkDataPackage.read` 与 `showOperationFailure` 断点均为零次命中。
4. Main thread 停在 `NSApplication.run()` 的 AppKit event loop；SQLite 核心表在操作前后均为空。
5. 诊断记录没有导入事件，证明执行在业务操作开始前已经中断，也暴露了 MainActor 活性证据缺口。

可重复的隔离红测命令：

```sh
NOONMARK_E2E_DATA_IMPORT_UI_ONLY=1 scripts/test-e2e debug
```

修复前结果：fixture setup 的 MainActor Task 无法执行，`artifacts/e2e-data-import-ui/setup-result.txt` 不会生成，套件 fail-closed。

## 排除的假设

- JSON schema 或数据损坏：当前 decoder、writer、隔离 replace 与重启回读均通过。
- security-scoped URL 失效：执行从未进入 `prepareDataImport`，尚未触及该边界。
- Store 或 delegate 提前释放：delegate 有静态强引用，store 是 delegate 的强引用属性。
- SwiftUI sheet 刷新失败：prepared import 从未形成，不是 presentation 更新问题。
- 导入错误被吞掉：错误处理 closure 同样从未执行。

## 根因与破坏机制

`NoonmarkMacApp` 是 `@MainActor` 的 `@main` 类型。引入提交为了 `await NoonmarkStore.preparePersistentBootstrap()`，把 `static func main()` 改为 `static func main() async`，之后仍在同一个 MainActor job 内同步调用永不返回的 `NSApplication.run()`。

AppKit event loop 因此仍能处理窗口、菜单与 `NSOpenPanel`，造成应用表面正常；但 Swift MainActor executor 认为启动 job 始终没有结束，后续继承 MainActor 的 Task 只能入队，永远得不到调度。这与「Task 创建命中、closure 入口不命中」的运行证据完全一致。

## 根因修复

- 恢复同步 `static func main()`，把 `NSApplication.run()` 永久置于 Swift concurrency job 之外。
- 启动期持久化与诊断 I/O 通过单一 `SynchronousApplicationBootstrapExecutor` 在非 MainActor executor 完成；同步入口只等待明确的成功或失败结果，然后才进入 AppKit event loop。
- `preparePersistentBootstrap` 改为显式接收已解析的 database URL，并标记为 `nonisolated`，避免后台准备隐式跳回 MainActor。
- 没有修改导入函数，没有逐点把 Task 换成 GCD，也没有加入延时、超时或重试绕过。

## 验证结果

- `SynchronousApplicationBootstrapExecutorTests`：后台执行、同步交付与失败传播通过。
- `scripts/test-e2e-evidence-contract`：同步 main 架构不变量通过。
- 真实数据导入 E2E：File menu、真实 NSOpenPanel、取消、再次选择、破坏性确认、SQLite 精确对账和重启回读通过；probe 为 `0 1 1 2 1 1 0 2 1 0 0 0 1 6 3`。
- malformed import integrity E2E：错误数据 fail-closed、SQLite／journal 不变及重启回读通过。
- 退出持久化 focused E2E：`review-summary` 输入在退出请求后 3.489 ms 完成，live 与 durable readback 均通过。
- 完整 `make check`、代码审查、最终修复 commit 与 DMG 门禁：处理中，完成后回填。

## 发行与回滚

包含 `9ca5b44` 的 0.1.1 (2) interim DMG 不应继续使用，必须由通过完整门禁的新构建替换。修复保持数据 schema 不变，不需要迁移。若新的启动 executor 发生回归，回滚单位是本案例对应的独立修复提交；不得回滚 `688d9b0` 中无关且有效的诊断错误映射改进。

## 教训与永久约束

1. AppKit 的永驻 event loop 不能运行在 Swift async entry job 内；`main` 必须同步。
2. 「窗口能操作」不能证明 MainActor Task 可调度；启动后必须有真实 Task 驱动的行为门禁。
3. 涉及入口生命周期的改动必须重跑数据导入与退出持久化两条真实 App 路径，不能只接受 build、UT 或旧 commit 的 E2E 证据。
4. 发行证据必须绑定将要打包的精确 source tree；早于风险提交的归档 E2E 不具备放行效力。
5. 故障修复必须更新本案例库并记录精确引入提交；无法证明实际操作者时明确写未知，不把 Git identity 当作个人事实。

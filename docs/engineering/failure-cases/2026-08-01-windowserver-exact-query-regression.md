# FAIL-2026-08-01-02：精确 WindowServer 查询 API 回归

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-01 20:54 -04:00，私有 DMG 发行门禁
- 影响版本／构建：Noonmark 0.1.1 (3)，source commit `811064550340390606ff5b514b9e248b20ae2bc9`；用户功能尚未据此判定异常，直接影响是候选 DMG 无法通过安装发行门禁
- 引入提交：`cb8f4a34015b4f4530986ad2f7a5b24ccdf2844d`，`fix(e2e): 改用精确窗口描述查询`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 记录不能证明内容由本人还是 agent 实际编写
- 修复提交：待回填

## 用户症状与影响

统一私有发行入口成功构建、签名、生成并静态校验 DMG，随后以隔离的 `app.noonmark.mac.dmg-validation` 派生身份安装和启动。App 的本地持久化加载成功，主窗口已经显示，但 `scripts/test-dmg-install` 在八秒内始终报告「scoped main window was not verified」，随后因缺少 `validation_app_executed` 证据而 fail-closed。

当前环境是虚拟机，以上证据只描述虚拟机内的发行验证，不映射为用户宿主机现场。验证路径使用 `noonmark-dmg-validation`、`Noonmark-DMGValidation/SyncRepository` 和派生 bundle identity，没有启动 production bundle，也没有读取 production 数据。

## 时间线

- 2026-08-01 09:17 -04:00：`cb8f4a3` 把 DMG 与 E2E 脚本从 `CGWindowListCopyWindowInfo([.optionIncludingWindow], exactID)` 换为 `CGWindowListCreateDescriptionFromArray([exactID])`，并同步反转静态合同。
- 2026-08-01 20:54 -04:00：0.1.1 (3) 候选 DMG 的真实安装门禁首次稳定判红。
- 2026-08-01 20:55 -04:00：保留的 owner-only response 证明 App 已发布 canonical 窗口身份，故障位于后续 WindowServer 复核。
- 2026-08-01：同一活跃窗口、同一调用进程和同一时刻完成两个 API 的对照取证；Kimi K3 独立审查修复方案。
- 2026-08-01：双审查发现首版未提交修复仍在 E2E 与 DMG shell 脚本复制四处查询实现；按 K3 的共享组件要求收敛为 test-only `NoonmarkWindowProbe`，脚本不再直接调用 CoreGraphics 查询。
- 2026-08-01：阶段证据 writer 的首个注入测试判红；原因是 rename 后合法变化的 ctime 被错误地与 rename 前快照比较。实现改为 rename 后同时复核仍打开的 descriptor 与最终路径，测试转绿；该缺陷从未进入 commit 或发行物。
- 2026-08-01：实现提交 `217df19607105472942b9e3d791e8f857bb6161f` 后的 standards 定点复核发现两项证据缺口：递归 `find` 的实际 process-substitution 退出码未观察，以及失败文件虽然写入 manifest，但 fixture 只检查源码字串、未核对真实路径与 SHA。两项均先补行为注入再修复；真实 release gate 仍待重跑，案例继续保持「处理中」。

## 复现与证据

症状级红测：

```sh
scripts/test-dmg-install dist/Noonmark.dmg
```

本轮 response 包含与启动 token 一致的 profile、PID、bundle identifier、窗口号和自然日标题；文件为 owner-only canonical JSON。应用自身诊断同时记录 persistence `localLoad` 在 7 ms 内成功，AppKit 日志显示窗口已经 order front。

对 response 发布的单一窗口号执行同进程对照：

- `CGPreflightScreenCaptureAccess()` 返回 `true`。
- `CGWindowListCreateDescriptionFromArray([exactID])` 返回 0 条。
- `CGWindowListCopyWindowInfo([.optionIncludingWindow], exactID)` 返回且只返回 1 条。
- 返回记录的 window ID、owner PID、标题、layer 0、onscreen 状态均与 response 相同，bounds 为 `1200 × 768`。

真实运行产物因此直接推翻「两个 exact-ID API 在当前发行环境等价」的假设。Apple 内部为何让前一 API 在该环境返回空，目前没有可验证机制解释；本案例不把 timing、Space 或 TCC 猜测写成事实。

## 排除的假设

- App 未启动或提前退出：LaunchServices、存活 PID 和 AppKit 窗口日志均证明 App 持续运行，最后由失败清理以 `SIGTERM` 终止。
- 持久化 bootstrap 再次饿死 MainActor：persistence 成功、窗口已显示，owner-only identity publisher 已在 MainActor 上完成写入。
- identity handshake 丢失或被污染：request／response token、profile、PID、bundle 和 canonical bytes 全部通过严格 parser。
- Screen Recording 未授权：同一查询进程的 preflight 为 `true`，替代 API 能读取完整的单窗口元数据。
- 标题或窗口尺寸不符合合同：替代 API 返回的标题完全一致，尺寸高于 `960 × 720` 最小值。

## 根因与破坏机制

`cb8f4a3` 把经过真实环境验证的 `CGWindowListCopyWindowInfo([.optionIncludingWindow], exactID)` 误标为「枚举式 API」，基于未验证的行为等价假设统一替换为 `CGWindowListCreateDescriptionFromArray([exactID])`。同一个错误假设此前已在 `d16a7cae13f24fe260a0805affa395b725f2e263` 引入共享 `ScopedWindowServerLookup`，但 `cb8f4a3` 才把真实 DMG 发行脚本也切到该路径并造成当前稳定故障。

当前 macOS 运行时对活跃窗口返回空数组，脚本的 `count == 1` 校验因此持续失败。更严重的是，静态合同同时禁止可工作的 API、强制失效 API；门禁不是单纯漏测，而是主动固化了错误实现。现有通用超时又吞掉「response 已验证、WindowServer query 返回 0」这一阶段差异，延长了定位时间。

查询实现当时散落在 App／Helper 共享 seam、E2E shell 内嵌 Swift 与 DMG shell 内嵌 Swift。即使逐点改回正确 API，未来仍能再次漂移；因此「API 选错」是直接根因，「运行查询有多个实现所有者」是让直接根因进入发行链的结构根因。

## 根因修复

- 已实施、待真实门禁确认：唯一 CoreGraphics exact-ID 查询留在 `ScopedWindowServerLookup`；test-only `NoonmarkWindowProbe` 输出固定 canonical schema，DMG 与 E2E shell 只消费该 Probe，不再复制查询实现。Probe 不进入 production DMG。
- 已实施、待真实门禁确认：继续强制 query count、returned ID、PID、title、layer、onscreen 和 bounds 校验；若未来 OS 行为漂移则 fail-closed，并输出固定 typed stage，不落盘自由文本。
- 已实施、待真实门禁确认：静态合同约束 exact ID 来源与调用所有权，禁止 `optionAll`、`optionOnScreenOnly`、above／below、`kCGNullWindowID` 和已知失效 API，并对源码扫描错误 fail-closed。
- 已实施、待真实门禁确认：失败产物记录 response 是否出现、是否通过 canonical validation，以及 WindowServer 复核的安全阶段码；文件以 descriptor-bound 临时文件、`RENAME_EXCL`、`fsync` 和 `0600` 原子发布，不覆写既有文件，不写用户内容。
- 已实施、待真实门禁确认：递归 App 文件清单先完整落入受控临时 inventory 并检查 producer 退出码，再逐项检查改名 Mach-O；失败证据 fixture 使用与 cleanup 相同的 manifest binder，核对实际 SHA、路径和非零闭合状态。

## 验证结果

修复前已经取得三条 focused red：E2E production-window isolation、DMG window identity contract、共享 window lookup boundary 均准确命中旧实现。共享 Probe 重构前，同三条门禁再次准确判红，分别命中 shell 复制查询与缺失 Probe binary。当前 `ScopedWindowServerLookupTests` 5 项、E2E production-window isolation、DMG window identity contract（含真实 `query-count-0`／0600／非法 reason／symlink／既有目标注入）和共享 binary boundary 已转绿。真实 App symptom、完整 `make check` 和私有 DMG release gate 仍待执行；在全部转绿前本案例保持「处理中」。

## 永久门禁

- Fast gate：`scripts/test-window-lookup-boundary` 由 `scripts/check` 强制执行，限制 WindowServer 查询只能存在于唯一共享 Swift seam，并校验 App、DMG Helper 与 test-only Probe 的最终二进制符号，同时证明 Probe 不进入 production DMG staging。
- Fast gate：`scripts/test-dmg-window-identity-contract` 由 `scripts/check` 强制执行，要求 owner-only token handshake、exact ID、单窗口强校验和阶段化失败证据。
- Symptom gate：`scripts/test-e2e` 由 `scripts/test-all` 强制执行，用真实 `app.noonmark.mac.e2e` 主窗口及辅助窗口验证 exact-ID 查询。
- Release gate：`scripts/test-dmg-install` 由 `scripts/release-private-dmg` 强制执行，使用派生 DMG identity 完成真实安装、窗口、输入、退出、重启和持久化对账；不得启动 production bundle。

## 发行与回滚

0.1.1 (3) 候选 DMG 没有通过完整发行门禁，不得据此宣称可交付。修复不改变用户 schema 或同步 payload；若修复回归，回滚单位是待生成的独立修复提交，不得重新启用 `CGWindowListCreateDescriptionFromArray` 或放宽 `count == 1` 等身份校验。

## 教训与永久约束

1. SDK 层面同样接收 exact ID，不等于两个 API 在目标 OS 上运行行为等价；发行判断以运行产物为准。
2. 安全边界应约束「输入来自哪里、查询范围是什么、返回值如何验证」，不能只按函数名建立黑白名单。
3. 静态合同不能替代真实 WindowServer symptom gate；改变窗口查询 API 后必须运行 DMG 安装验证。
4. fail-closed 错误必须保存能区分假设的阶段码，否则「安全失败」仍可能缺乏定位价值。
5. 虚拟机发行证据与宿主机用户现场必须严格分开表述。

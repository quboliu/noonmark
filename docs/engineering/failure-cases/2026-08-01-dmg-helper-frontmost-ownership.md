# FAIL-2026-08-01-04：DMG 验证助手没有建立目标 App 前台所有权

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02T02:00:00Z 至 2026-08-02T03:05:07Z（首次失败产物后来被第二次复现覆盖）
- 影响版本／构建：0.1.1（4），source commit `5827b60c0b5da42b2556908c97053654a24f9e37` 的 `dmg-validation` 发行验收
- 引入提交：`303483bb1649f4617243d1369565b115292dfdfc`（`fix(ui): 闭环 Mac 原生发行审查`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git 历史只能证明 author／committer identity，现有仓库与 session 证据不足以确认 2026-07-15 的实际操作者
- 修复提交：待回填

## 用户症状与影响

production DMG 的静态门禁通过，受控派生的 `dmg-validation` App 也已经启动并显示精确主窗口，但发行助手在进行真实菜单和物理输入前等待八秒，最终报 `Timed out waiting for the validation app to be AX-frontmost`。因此发行门禁判红，DMG 不得交付。

此故障只发生在虚拟机的隔离发行验收路径。它不证明宿主机状态，也不是 Noonmark 产品的资料导入或退出逻辑再次失败。

## 时间线

- 2026-07-16T02:18:25Z：`303483bb1649f4617243d1369565b115292dfdfc` 同时引入 `open -n -g` 的 LSUIElement 助手启动方式，以及只等待、不主动建立目标前台所有权的 `validateTarget`。
- 2026-08-01T07:36:28Z：`0f66f07458ee6648b4c789fdec2c9a4ec5025eed` 把 production DMG 的动态交互迁到隔离 `dmg-validation` 身份；原有前台假设继续被继承。
- 2026-08-02T03:01:15Z：`5827b60c0b5da42b2556908c97053654a24f9e37` 修复验证包菜单身份漂移；验证助手开始以与 production 相同的产品显示身份、不同的精确 bundle identifier 运行，潜伏的前台假设稳定暴露。
- 2026-08-02T03:05:07Z：同一 commit、同一真实 DMG 的第二次独立运行再次在完全相同的 AX frontmost 阶段判红。
- 2026-08-02：虚拟机最小运行探针证明派生 App 的 activation policy 是 `.regular`，精确 `NSRunningApplication.activate(options: [])` 请求返回接受并达到 `isActive=true`。
- 2026-08-02：Kimi K3 只读复核同意根因方向，并要求以 AppKit active 与 AX frontmost 双信号证明、保留后续交互的只读复核，以及让 ledger 缺证据时 fail-closed。

## 复现与证据

真实复现入口：

```bash
scripts/test-dmg-install dist/Noonmark.dmg
```

第二次稳定失败证据：

- `artifacts/dmg-install/installed-exercise-window.txt`：精确 PID、`app.noonmark.mac.dmg-validation`、canonical bundle path、WindowServer window ID 与标题已经对账。
- `artifacts/dmg-install/installed-exercise-before-input.png`：失败前已经取得 2400×1536 的真实窗口截图。
- `artifacts/dmg-install/exercise-ledger.tsv`：进程、exit observer 与权限通过，随后在 AX frontmost 阶段失败。
- `artifacts/dmg-install/runtime-manifest.txt`：`suite_exit_status=1`，失败清单完整闭合，production App 仍为 `production_app_executed=false`。

源码证据：

- 引入提交里的 `validateTarget` 在 identity guards 后直接调用 `target.waitUntilFrontmost()`，没有激活动作。
- `AXTarget.waitUntilFrontmost()` 只读轮询 `kAXFrontmostAttribute`。
- 助手以 `/usr/bin/open -n -g` 启动；`-g` 只约束助手自身不前置，不是目标 App 持续 frontmost 的所有权协议。

## 排除的假设

- 不是目标 App 未启动：精确 PID、bundle identifier、bundle path 都已通过。
- 不是没有可见窗口：WindowServer exact-ID 查询、layer 0、onscreen 与真实截图都已通过。
- 不是 Accessibility 或 CG event 权限不足：助手 ledger 记录两项权限均为 `true`。
- 不是派生 App 的 activation policy 变成 accessory：虚拟机运行探针得到 `.regular`。
- 不是把 production App 当成验证目标：全部运行证据绑定 `app.noonmark.mac.dmg-validation`，清单固定 `production_app_executed=false`。
- 不是延迟太短：同一状态连续八秒未变化，且根因是从未发起所有权建立；延长等待不会产生缺失的动作。

## 根因与破坏机制

发行助手与目标 App 之间缺少显式的前台所有权协议。实现把“目标通过 `open -n` 启动、助手通过 `open -g` 启动”错误等同于“目标在助手整个交互期间必定保持 frontmost”。窗口可见、layer 0 和 AX tree 可读都不能证明 App 是当前输入接收者；当虚拟机前台状态变化时，助手只会等待一个没有任何代码负责建立的状态，最终稳定超时。

`5827b60c0b5da42b2556908c97053654a24f9e37` 让合法菜单身份恢复后触发了这条潜伏路径，但没有引入缺失协议；引入点仍是 `303483bb1649f4617243d1369565b115292dfdfc`。

## 根因修复

新增独立、可注入且只使用精确 `NSRunningApplication` 实例的前台所有权模块：

1. 在任何激活动作前重新核验 PID、未终止状态、expected bundle identifier 与 canonical bundle path；每次观察重新解析 PID，并用 `NSRunningApplication.isEqual` 与 `proc_pidinfo(PROC_PIDTBSDINFO)` 进程启动时刻同时拒绝 PID reuse／进程替换。
2. 要求 activation policy 为 `.regular`。
3. 只发起一次 `activate(options: [])`；请求被拒即 fail-closed，不用名称查找、LaunchServices 重开、AX mutation 或静默 fallback。
4. 用单调 uptime 执行原有八秒硬预算，并在等待间隔推进 AppKit RunLoop；只有预算内同时证明 fresh `NSRunningApplication.isActive=true` 与 AX `kAXFrontmost=true` 才通过。
5. 将目标 PID、内核进程启动时刻、请求结果、前后 AppKit／AX 状态写入独立 `activation` ledger 步骤；发行脚本必须把 PID 与 arguments／窗口身份对账，缺少或无法精确对账时判红。
6. 完成初次所有权建立后，菜单与物理输入路径继续使用既有只读 frontmost 检查；不在每个输入点自动重新激活，以免吸收中途失焦故障。

## 验证结果

- TDD 红：新增测试在实现前因 `TargetForegroundOwnership` 不存在而编译判红。
- Fast tests：身份不匹配／已终止时零激活请求、同 PID 同路径的不同进程实例判红、非 regular 零激活请求、请求拒绝判红、AppKit-only／AX-only 判红、越过单调 deadline 判红、双信号同时成立才通过。
- 症状与 release 结果：待真实 `scripts/test-dmg-install` 连续两次由红转绿后回填。
- 修复 commit：待回填。

## 永久门禁

- Fast：`scripts/test-dmg-foreground-ownership-contract`，由 `scripts/check` 强制执行，覆盖 Swift 行为测试、RunLoop pump、PID reuse 防护、单一激活机制、禁止 AX mutation／LaunchServices fallback、身份核验顺序与 PID-bound ledger 对账。
- Symptom：`scripts/test-dmg-install`，由 `scripts/release-private-dmg` 强制执行，走派生 App 的真实窗口、真实菜单、物理输入、退出、重启、持久化与诊断导出。
- Release：`scripts/test-dmg-install`，同一入口绑定真实 DMG、签名、source evidence、进程身份、激活 ledger 和最终清单。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

在真实 DMG symptom gate 连续两次转绿、修复 commit 确定、案例状态回填为「已修复」之前，不向下载目录交付任何候选 DMG。若修复门禁仍红，回滚处置是保留上一份未交付候选并继续 fail-closed；不得删除前台证明或放宽为窗口可见即可。

## 教训与永久约束

- “后台助手不抢前台”不等于“目标 App 拥有前台”。跨进程物理输入必须有显式、精确身份绑定的前台所有权协议。
- `onscreen`、layer 0、截图和 AX tree 只能证明窗口存在，不能替代输入接收者证明。
- 一次激活请求必须由 AppKit 与 AX 两套状态共同对账；任何单边信号都不能放行。
- `NSRunningApplication` 的 PID 不能代表进程实例；必须依照 AppKit 的 `isEqual` 语义并叠加内核启动时刻，防止 PID reuse 让旧证据绑定新进程。
- 轮询 AppKit KVO 状态时必须推进 RunLoop，并以单调时钟独立限制预算；同步睡眠可能把真实状态变化冻结在消息队列里。
- 测试助手的关键动作必须进入 ledger 并由外层脚本精确对账，否则代码存在不等于证据存在。
- 虚拟机证据只证明虚拟机中的隔离验证路径，不得表述为宿主机已修复。

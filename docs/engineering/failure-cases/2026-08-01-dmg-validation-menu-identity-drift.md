# FAIL-2026-08-01-03：DMG 验证包菜单身份漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-01 22:24 -04:00，私有 DMG 真实安装门禁
- 影响版本／构建：Noonmark 0.1.1 (4)，source commit `217df19607105472942b9e3d791e8f857bb6161f`；production DMG 已构建并通过静态门禁，但候选未通过动态发行门禁、不得交付
- 引入提交：`0f66f07458ee6648b4c789fdec2c9a4ec5025eed`，`feat(release): 隔离正式 DMG 与交互验收`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际内容由本人或 agent 编写
- 修复提交：待回填

## 用户症状与影响

私有发行入口完成 release 构建、签名、DMG 生成、只读挂载和 production 静态身份验证。受控派生的 `app.noonmark.mac.dmg-validation` 随后正常启动、成为前台、显示唯一主窗口，WindowServer exact-ID 复核也已通过；物理输入 helper 在执行设置、快速输入和退出路径前失败，报告找不到顶层菜单 `Noonmark` 或 `晷迹`，所以退出、重启与持久化验证无法继续。

本案例发生在虚拟机的隔离 `dmg-validation` profile。production bundle 固定记录为未执行，production 数据和正式 iCloud repository 均未读取或清理；不能把本案例描述为用户宿主机 App 故障。

## 时间线

- 2026-08-01 03:36 -04:00：`0f66f07` 新增 production DMG 的隔离派生流程，同时把派生 App 的 `CFBundleName` 改为 `NoonmarkDMGValidation`、`CFBundleDisplayName` 改为 `Noonmark DMG Validation`。
- 2026-08-01 22:24 -04:00：真实发行门禁证明派生 App 和主窗口正常，但 helper 在第一个 App 菜单操作稳定判红。
- 2026-08-01 22:25 -04:00：派生 `Info.plist` 回读为 `NoonmarkDMGValidation`／`Noonmark DMG Validation`；同一 helper 的菜单合同只接受与产品 UI 一致的 `Noonmark`／`晷迹`。
- 2026-08-01：旧实现下新增 derivation contract 与 failure-manifest contract 均准确判红；修复后聚焦合同转绿。

## 复现与证据

症状级命令：

```sh
scripts/release-private-dmg
```

真实 helper ledger 依次记录：参数、唯一 helper PID 与 launch token、kernel exit observer、Accessibility／CGEvent 权限、目标 bundle／绝对路径／前台状态、唯一可见主窗口均为 `PASS`，随后记录：

```text
FAIL fatal Validation UI contract failed: missing top-level menu ["Noonmark", "晷迹"]
```

派生包运行时 `Info.plist` 回读：`CFBundleName=NoonmarkDMGValidation`、`CFBundleDisplayName=Noonmark DMG Validation`、`CFBundleIdentifier=app.noonmark.mac.dmg-validation`。production 包对应值为 `Noonmark`、`晷迹`、`app.noonmark.mac`。这证明数据隔离所需的 bundle identifier 变化被错误扩大成用户可见菜单身份变化。

同一次失败的清理又报告缺少 `diagnostic_export_ui_completed`，说明成功路径专属字段被无条件当成失败 manifest 的必填字段；原始 helper ledger 仍保留，但 manifest 未以非零状态正常闭合。该次级证据缺陷由 `8251113c4ca942d63cede67a1fc34e9ab13dc54f` 引入，Git author／committer 同为 `quboliu`，实际修改者未知。

## 排除的假设

- WindowServer 查询仍失败：主窗口 handshake、exact ID、PID、标题、layer、onscreen 与 bounds 已通过，helper 也确认原生 AXWindow 可见。
- App 未启动或不在前台：LaunchServices、精确 bundle/path/PID 和 helper ledger 均证明目标正常运行且 frontmost。
- Accessibility 或物理输入权限缺失：ledger 明确记录 `AXIsProcessTrusted=true` 与 `CGPreflightPostEventAccess=true`。
- 产品菜单本身被删掉：production 包的名称字段仍是 `Noonmark`／`晷迹`；漂移只发生在隔离派生步骤。

## 根因与破坏机制

`0f66f07` 为避免动态测试触碰 production 身份，正确地改变了 bundle identifier、executable 名称和签名；但又改变了 `CFBundleName` 与 `CFBundleDisplayName`。这两个字段参与 macOS App 菜单身份，令派生包不再保持 production UI 行为。helper 坚持查找产品菜单并不是候选集合过窄，而是暴露了派生包与被验证发行物不再能力对等。

静态 derivation contract 当时把 `bundle-name,display-name` 明列为允许差异，因此主动固化了错误假设。发行门禁此前没有成功跑到真实菜单操作，导致该不对等直到本轮才被运行产物揭示。

## 根因修复

- 派生包只允许改变 `bundle-identifier,executable-name,code-signature`；保留并在签名前后对账 production 的 `CFBundleName` 与 `CFBundleDisplayName`。
- cross-evidence verifier 直接回读 production 与 validation 两份 `Info.plist`，菜单身份不一致即 fail-closed；不通过扩大 helper 菜单候选绕过 UI 等价要求。
- App 内容枚举改为先把 NUL-delimited 清单写入受控临时文件并检查真实 `find` 退出码，再消费清单；失败注入即使先产生完整输出也必须判红。
- 窗口失败证据的写入与 manifest 绑定收敛到同一函数；fixture 核对真实文件 SHA、固定相对路径和非零闭合状态。真实失败 manifest 只要求失败阶段必然存在的字段，避免用尚未执行的成功阶段字段阻断证据闭合。

## 验证结果

修复前：`scripts/test-dmg-validation-derivation-contract` 以「changed the production menu identity」判红；`scripts/test-dmg-window-identity-contract` 以「not behaviorally bound into a manifest」判红；显式 partial-output find failure 注入被旧 verifier 错误接受。修复后上述三条聚焦合同均转绿。完整 DMG evidence contract、真实 `dmg-validation` 输入／退出／重启／持久化和最终 `make check` 仍待执行，因此案例保持「处理中」。

## 永久门禁

- Fast gate：`scripts/test-dmg-validation-derivation-contract` 由 `scripts/test-dmg-evidence-contract` 强制执行，证明派生只改变隔离必需身份并保留产品菜单名称。
- Fast gate：`scripts/test-dmg-evidence-contract` 由 `scripts/check` 强制执行，交叉核对 production／validation `Info.plist`、失败 manifest 三元组与篡改注入。
- Symptom gate：`scripts/test-dmg-install` 由 `scripts/release-private-dmg` 强制执行，以真实 AX 菜单和物理输入完成设置、快速输入和退出。
- Release gate：同一 `scripts/test-dmg-install` 必须继续完成进程消失、重启、SQLite 回读与诊断导出，且证明 production App 未执行。

## 发行与回滚

失败候选没有复制到下载目录，不存在需要回收的交付物。修复只收窄派生允许差异和增强测试证据，不改变 production binary、数据库 schema 或同步 payload。若回归，回滚待生成的独立修复提交；不得恢复 validation 菜单改名，也不得把 helper 候选扩成测试专用名称来掩盖不对等。

## 教训与永久约束

1. 隔离身份应只改变数据权限所必需的字段；任何用户可见字段变化都会削弱发行物等价性。
2. derivation allowlist 本身必须从真实用户路径反证，不能因为变化“有意为之”就视为正确。
3. 失败门禁也必须产出可闭合、可校验的 manifest；成功阶段未执行不能反过来销毁已取得的失败现场。
4. shell 的 process substitution 不会自动把 producer 失败传给父循环；安全枚举必须显式观察 producer 的最终状态。

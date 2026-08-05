# FAIL-2026-08-04-29：设置页诗文复选框命中目标漂移

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-05T02:12:00Z
- 影响版本／构建：`d819ef02c2e9199a327cbbeedbe5da520e992468` 的 macOS E2E 构建
- 引入提交：待以修复后的 Git 历史比对回填；目前无法从运行产物证明精确引入提交
- Git author／committer：待回填
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

真实设置页 E2E 经 WindowServer 点击「在“关于晷迹”中展示诗文」后，偏好仍保持开启，导致完整 E2E 阻断。产品设置本身没有被证明损坏；受影响的是自动化交互能否可靠命中用户可点击的原生复选框。

## 时间线

- 2026-08-05：完整 E2E 的 Preferences logical-clock 场景报出“local-only poem checkbox did not turn off through WindowServer input”。
- 2026-08-05：失败输入轨迹显示目标可访问性框宽 155.5pt，点击中心落在标签区域；SwiftUI Toggle 的实际可操作目标是前导原生复选框。
- 2026-08-05：同源码、有效 Apple Development 签名的 E2E 快照在隔离临时资料中复跑通过，确认该症状具有时序性，不能归因于确定性的偏好提交失败。
- 2026-08-05：修复后的真实 E2E 证明被动锚点已挂载但处于滚动容器裁剪区；因此必须先滚入可见区域，不能只以 AX 语义框为可点击证据。
- 2026-08-05：运行时视图树证明最小滚动会把 anchor 停在 y=0 的裁剪边缘，原生 18×18pt checkbox 的 focus ring 因而跨出边界；仅等待 anchor 可见仍会造成命中解析抖动。
- 2026-08-05：连续两次真实 E2E 通过：以所属 Settings window 遍历原生控件、以 24pt 边距滚入完整可点击区域，并等待实际 hit target 已解析。

## 复现与证据

- 红色真实路径：`scripts/test-e2e` 的 `preference logical-clock native Settings exercise`，运行结果为上述症状。
- 输入与视图树证据：`artifacts/e2e-preferences-clock/input-trace.txt` 与同目录 `exercise-result.view-tree.txt`；仅记录控件几何与稳定测试标识，不含用户资料。
- 绿色对照：相同 source commit 的已签名 E2E App snapshot，使用新建隔离数据库与受限同步根执行 setup/exercise，结果为 `ok`。

## 排除的假设

- 主题、语言偏好提交链路损坏：同一次红色运行中二者均完成逻辑时钟推进和 journal 对账，排除。
- 本机诗文偏好被同步覆盖：诗文属于 local-only，且失败发生在首次点击后的内存状态等待阶段，排除。
- 可访问性权限缺失：场景已读取到唯一、可见且启用的目标，排除。

## 根因与破坏机制

旧自动化把 SwiftUI Toggle 的可访问性语义容器中心当作鼠标目标。该容器包含宽标签，但实际可操作的是左侧 AppKit `NSButton` 复选框；当界面重排或命中分派时，标签中心不保证触发复选框，形成偶发无效点击。首次根治实现又错误地从主窗口树枚举原生控件；Settings 是独立窗口，故解析器在已可见的锚点旁仍找不到 checkbox。最小 `scrollToVisible` 亦只保证像素级露出，未保证 focus ring 中心处于命中区域。

## 根因修复

交互层先将已挂载的被动 E2E anchor 以 24pt 垂直边距滚入可点击区域，再只在该 anchor 所属的 Settings window 枚举可见原生 checkbox `NSButton`，验证其中心在锚点内且 hit-test 可达，并在 mouseDown 前再次解析后投递 WindowServer 输入。等待条件升级为真实 hit target 已解析，而非 anchor 的像素级可见。第一次实现错误地以 80% 面积重叠作判据，忽略了原生 focus ring 比 14×14pt checkbox glyph 更大；真实 E2E 已将该假设判红，现以控件中心的语义归属取代。不会改变偏好领域逻辑、同步语义或旧版资料迁移。

## 验证结果

待回填原始红色路径转绿、完整 E2E 和发行门禁结果。

## 永久门禁

- fast：`scripts/test-preferences-checkbox-interaction-target-contract`，由 `scripts/check` 强制调用。
- symptom：`scripts/test-e2e` 的 Preferences logical-clock 原生设置路径。

## 发行与回滚

在 `scripts/test-e2e`、`make check`、DMG 打包与受控 `dmg-validation` 全部通过前不得推送或清理分支。若该修复引入回归，回滚本案例关联修复提交；设置数据不做变换，现有用户资料不受影响。

## 教训与永久约束

SwiftUI 的可访问性几何不能替代原生 AppKit 控件的真实 hit-test 边界。对 Checkbox、Segmented Control 等桥接控件，E2E 必须以实际可点击的原生目标为准，并在投递鼠标事件前重新验证。

# FAIL-2026-08-04-14：年度 Demo 没有验收飞光核心编辑交互

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:35 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至修复前工作树
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话、Demo automation 与 K3 review 确认
- 修复提交：待回填

## 用户症状与影响

一年 Demo 有飞光数据，也会检查页面骨架、搜索与回看，但没有真实双击旧条目、点击保存／取消，也没有打开全局面板选择分类候选。交互实现即使退化，默认体验入口仍可能报告 ready，用户拿到的是未经核心路径验收的演示 App。

## 时间线

- 年度 fixture 已提供跨日飞光、分类、编辑历史与 Sticky Note 数据。
- Composer 重构沿用旧 Demo presentation check，只验证锚点和投影。
- K3 对照设计规格发现真实编辑与全局候选没有 Demo 证据。
- 修复把 WindowServer 物理路径、独立报告字段与截图纳入同一 demo profile。

## 复现与证据

旧 manifest 只有 `ideasPresentationVerified`，automation 在搜索前没有任何 `WindowServerInputDriver` 飞光动作。修复后真实 Demo 双击条目，分别取消和保存，再恢复原 fixture 正文；随后用真实快捷键打开全局速记、输入 `@工` 并物理选择「工程」。

## 排除的假设

- 历史数据含 `updatedAt > createdAt` 不能证明当前编辑器可操作。
- 静态锚点存在不能证明保存／取消的 blur 顺序正确。
- 飞光专项 E2E 不能替代默认 demo profile 的用户体验契约，两者资料负载与入口不同。

## 根因与破坏机制

Demo 覆盖只随领域数据扩展，没有随 Composer 用户路径扩展；泛化的 `ideasPresentationVerified` 掩盖了「页面存在」与「核心交互可用」的差异。

## 根因修复

新增 demo-profile WindowServer 验收：双击、取消零修改、编辑保存、saving 截图、恢复原正文和分类／Sticky 身份对账；再验证全局分类候选并清空草稿。Manifest 独立记录编辑与候选两项，截图 contract 收纳原位编辑、saving 与候选面板。

## 验证结果

- `make test-demo-fixture` 已通过真实 `.app`、WindowServer、SQLite 与加密 sidecar 对账。
- Manifest 新字段及三张新增截图均由脚本 fail-closed 检查。
- 完整 `make check` 待最终执行。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求 Demo 交互与 manifest 契约存在。
- symptom：`scripts/test-interactive-demo-fixture`，由 `scripts/test-all` 强制调用，真实 Demo App 任一物理路径、报告、截图或最终资料对账失败即判红。

## 发行与回滚

只使用每轮整体重建的 `demo` profile。若失败，不得打开成可体验状态；不得改用一次性手工灌数或 production 数据绕过。

## 教训与永久约束

有状态的 Demo 数据只是体验前提，不是交互证据。用户可见核心路径必须在默认演示身份中自己走一遍并写入机器报告。

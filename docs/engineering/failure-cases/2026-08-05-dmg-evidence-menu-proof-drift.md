# FAIL-2026-08-05-03：发行证据验证器与 harness 菜单证据串漂移

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-05（0.2.2 (8) 候选发行链 dmg-install 证据对账判红）
- 影响版本／构建：0.2.2 (8) 候选；不涉及已交付的 0.2.1 (6) DMG 本身
- 引入提交：`70d46e3` fix(e2e): tighten the physical diagnostics menu selection protocol（2026-08-02）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`（历史已统一改写为该身份）
- 实际修改者：未知
- 修复提交：`37d627007ecbc9efc96c7909d9d6e7a5b9cb3d36` fix(release): align the DMG evidence verifier with the harness menu proofs

## 用户症状与影响

0.2.2 (8) 候选发行链在 `scripts/release-private-dmg` 的最终证据对账阶段判红：`DMG install exercise ledger has an invalid native quit proof`。真实 dmg-validation App 的安装、退出、重启验证实际全部 PASS，但验证器拒绝承认证据，发行被正确阻断（fail-closed 按设计工作）。

## 时间线

- 2026-07-18：`3d5cc9e` 起验证器对 `quit-menu` 等菜单步骤使用精确短串期望（`title=退出晷迹 shortcut=Command-q`）。
- 2026-08-02：`70d46e3` 把 harness 的菜单步骤证据升级为强证据串（追加 `source=cghidEventTap pre_mouse_down=exact menu_closed=true left_button_up=true`），但未同步更新验证器期望与 `scripts/test-dmg-evidence-contract` 的 fixture。
- 2026-08-05：v0.2.1 为回填的历史基线，从未以当前验证器+harness 组合完整跑过发行链，漂移潜伏未被发现；0.2.2 (8) 是首个真实跑全链的候选，在对账阶段命中。

## 复现与证据

1. 完整发行链跑通 make check、完整 E2E、writer-lease、DMG 打包与静态验证后，`scripts/verify-development-validation-evidence --scope full` 判红。
2. 真实 ledger（`artifacts/dmg-install/exercise-ledger.tsv`）：`quit-menu` 行为 `title=退出晷迹 shortcut=Command-q source=cghidEventTap pre_mouse_down=exact menu_closed=true left_button_up=true`，PASS。
3. 验证器期望：`title=退出晷迹 shortcut=Command-q`（精确等值比较），必然不匹配。
4. 受影响步骤：`quit-menu`、`settings-menu`、`quick-entry-menu`、`diagnostic-menu`（中英文两串）。

## 排除的假设

- dmg-validation App 真实退出失效：ledger 与进程证据均 PASS，排除。
- harness 输出错误：强证据串是 70d46e3 有意收紧的协议，信息严格更强，排除。
- 本轮性能修复引入：漂移自 2026-08-02 即存在，与性能改动无关，排除。

## 根因与破坏机制

协议两侧编辑不同步：harness 产出侧收紧证据串时，消费侧（验证器精确期望串）与 fast 门禁 fixture（`test-dmg-evidence-contract` 内的模拟 ledger）未同步更新。fast 门禁只验证「验证器 vs 旧 fixture」自洽，不验证「验证器 vs 真实 harness 输出」，漂移因此穿过 `make check` 潜伏。

## 根因修复

- `scripts/verify-development-validation-evidence`：五处菜单证据期望串升级为 harness 实际输出的强证据串（含 `source=cghidEventTap pre_mouse_down=exact menu_closed=true left_button_up=true`）。
- `scripts/test-dmg-evidence-contract`：fixture ledger 的对应行同步为强证据串，使 fast 门禁反映真实 harness 输出。

## 验证结果

- `scripts/test-dmg-evidence-contract`、`test-dmg-harness-evidence-contract`、`test-dmg-install-observer`：全部通过。
- 完整发行链重跑（2026-08-05，run id `release-v0.2.2-b8-20260805T184618Z`）：make check、完整 E2E、writer-lease、DMG 打包与静态验证、dmg-validation 受控安装/退出/重启、诊断导出对账全部通过，`Private DMG package and complete same-run validation evidence passed`。0.2.2 (8) 已交付。

## 永久门禁

- fast：`scripts/test-dmg-evidence-contract`（随 `make check`）fixture 已与真实 harness 输出对齐，验证器期望回退到短串会判红。
- symptom：`scripts/test-e2e`（随 `scripts/test-all`）保持真实 App 路径可运行；菜单强证据串对账由 release 层承担。
- release：`scripts/test-dmg-install`（随 `scripts/release-private-dmg`）真实 dmg-validation 安装/退出/重启证据对账。

## 发行与回滚

本案例本身是发行门禁的缺陷，0.2.2 候选因此按流程重新验证。无用户资料影响。

## 教训与永久约束

- 证据协议是双侧契约：收紧产出侧时必须同 commit 更新消费侧与 fixture 自证，否则 fast 门禁会用旧 fixture 证明一个已经不成立的契约。
- 回填式历史基线不能替代真实全链验证；任何「基线」之后第一次真实跑链都必须预期暴露潜伏漂移。

# FAIL-2026-08-07-13：Clean checkout 缺少 DMG evidence output boundary

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T18:55:19Z
- 影响版本／构建：v0.2.4 build 20，source commit `86b8ea0bf955162950e31676eb50d77002773316`
- 引入提交：`038e4e71f72b2d808e3327aae7b7f23f570f3850`（`fix(evidence): harden evidence paths and session lifecycle`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`d37ced6cc5c04001367c18a678dd326f30be37e4`（`fix(release): initialize the package evidence boundary`）

## 用户症状与影响

build 20 的唯一 GitHub-hosted CI 已成功，但 tag 触发的唯一 Release job 在导入并证明 Apple Development 身份后，于 production DMG 打包的第一份 evidence manifest 写入失败。GitHub 没有建立 Release、DMG 或 checksum；production App 与用户资料均未执行或触碰。

## 时间线

- 2026-07-18：`package-dmg` 开始在构建 App 前写入 `dist/Noonmark.dmg.manifest`，旧 writer 会建立父目录。
- 2026-08-01：evidence writer 改为 descriptor-bound helper；安全 helper 刻意只绑定已经存在的父目录，但 `package-dmg` 没有承接建立 output boundary 的责任。
- 2026-08-07T18:55:19Z：Release run `31209112249` 的唯一 job `92967360457` 在 clean checkout 报 `open evidence directory boundary failed with errno 2`。
- 同日：确认 GitHub 没有 Release 后，失败候选 tag 已撤回，build 20 退役且不 rerun。

## 复现与证据

在新临时目录中直接对缺少父目录的绝对路径调用 `evidence_begin_manifest`，稳定退出 1，并复现 GitHub 的 `replace-path`、`errno 2` 与目标 manifest 错误；只建立同一父目录后，完全相同的调用退出 0。Release log 证明签名身份导入与证明已经成功，失败精确发生于 `scripts/package-dmg release` 的首份 manifest 写入。

现有 `scripts/test-dmg-evidence-contract` 在运行 package fixture 之前预先建立 `dist/Noonmark.app` 和 stale manifest，因此没有覆盖 GitHub clean checkout 的目录生命周期。

## 排除的假设

- 不是 Apple Development 身份错误：导入与身份证明步骤已成功完成。
- 不是 GitHub evidence helper 无法启动：session 已完成握手，并返回具体 `replace-path` 目录打开错误。
- 不是 manifest 内容、权限或追加阶段错误：失败发生在目标文件尚不存在的首次原子 replace。
- 不是 production App 运行故障：Release job 尚未产出 DMG，更没有启动 App。

## 根因与破坏机制

安全强化把父目录建立责任从通用 writer 移除，以便 helper 能先绑定并验证既有目录；`package-dmg` 仍隐含依赖旧 writer 的自动 `mkdir -p` 行为。开发机和既有 fixture 都残留或预建 `dist/`，把 clean checkout 才出现的契约断层完全遮蔽。GitHub runner 上 `BoundAtomicDestination` 打开 `dist` 时收到 `ENOENT`，因此在真正构建前 fail-closed。

## 根因修复

`package-dmg` 在任何 manifest 写入前调用既有 `evidence_guard_repo_path`，从 physical repository root 逐级建立并验证 package-owned output boundary；symlink、目录逃逸和非目录仍然 fail-closed。完整 package fixture 新增第一轮 clean-checkout 调用，随后保留第二轮 stale-output 调用，兼顾新旧契约。

## 验证结果

- Red（真实 hosted）：Release run `31209112249` 在 clean checkout 的首份 package manifest 写入失败。
- Red（本机最小症状）：缺少目标父目录时退出 1；预建同一父目录后退出 0。
- 待 Green（fast）：release gate contract 必须验证 output boundary 建立早于 `evidence_begin_manifest`。
- 待 Green（symptom）：完整 DMG evidence fixture 必须从不存在 `dist/` 的状态成功打包，再验证 stale-output replacement。
- 待 Green（release）：build 21 的唯一 tag job 必须发布唯一 DMG 与 checksum。

## 永久门禁

- fast：`scripts/test-release-gate-contract`，由 `scripts/check` 强制调用；验证 package output boundary 的建立顺序。
- symptom：`scripts/test-dmg-evidence-contract`，由 `scripts/check` 强制调用；真实 package fixture 首轮从不存在 `dist/` 的 clean checkout 开始。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；精确 tag job 必须成功建立唯一 DMG／checksum。

## 发行与回滚

build 20 永久退役，不 rerun；确认无 Release 后撤回失败 tag。build 21 先跑 targeted fixture，再由唯一 GitHub-hosted main run 灰度；只有该 run 首次成功才重建 `v0.2.4` tag。若修复失败，撤回未交付 tag并退休 build 21，不恢复不安全的自动 writer，也不触碰 production 资料。

## 教训与永久约束

安全 helper 收紧文件系统责任时，所有调用方必须对 clean checkout 的资源生命周期重新做运行产物对账。发行 fixture 不得预建生产流程本应拥有的 output boundary；“本机常驻目录存在”不能作为 clean runner 契约。

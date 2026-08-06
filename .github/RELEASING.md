# 私有发行流程（Tag 触发 CI 发版）

本文件是晷迹发版的唯一操作说明。发行入口是 `.github/workflows/release-publish.yml`：**推送版本 tag 自动触发**，在常驻 self-hosted Mac runner 上跑完整验证链，从干净 checkout 构建、签名并发布 GitHub Release。CI 构建的 DMG 是分发的唯一正本。

## 前置条件（已配置）

- 常驻 self-hosted runner，labels：`self-hosted, macOS, noonmark-ui-e2e`，预装 Xcode、腾讯拼音与预授权 TCC。
- runner 钥匙串持有稳定 Apple Development 签名身份，并由 repository variable `NOONMARK_UI_CODESIGN_IDENTITY` 显式命名（与 `release.yml` 校验链同一身份，不需要额外 secrets）。

## 发版步骤

1. 在 `main` 完成开发与本地全链验证（`make check`、真实 E2E），故障案例与门禁按纪律闭环。
2. 准备候选：更新 `release/VERSION`（PATCH 修复递增 build；MINOR 新能力；MAJOR 需用户明确批准）、`release/BUILD-LEDGER.tsv` 登记 `candidate`、新建 `docs/releases/vX.Y.Z.md`，commit 并 push `main`。
3. 打带注释 tag 并推送：`git tag -a vX.Y.Z -m "Noonmark X.Y.Z (N) private release candidate" && git push origin vX.Y.Z`。
4. workflow 自动执行：`scripts/check` → writer-lease E2E → 完整 `scripts/test-e2e` → `scripts/release-private-dmg`（诊断闭环、腾讯拼音 smoke、打包、DMG 静态验证、dmg-validation 安装/重启）→ 创建或更新 GitHub Release 并上传 `Noonmark.dmg` 与 `Noonmark.dmg.sha256` → 校验 asset 可公开下载。
5. 全绿后回填 `docs/releases/vX.Y.Z.md`（发行 commit、CI 产物 SHA-256、验证摘要、Release 链接），`BUILD-LEDGER.tsv` 标 `released`，commit 并 push。

任何一步判红：删除未交付的候选 tag，修复后用**新 build 号**重开；不得移动已交付 tag，不得复用 build 号。

也可以手动触发：Actions → Release → Run workflow（发布当前 ref 的 `release/VERSION` 对应版本）。

## 边界

- 产物只含 Apple Development 签名：没有 Developer ID、notarization、staple；用户自行下载安装，首次打开按 Gatekeeper 提示确认。
- production App 本体在 CI 中只做静态验证；动态验收固定跑受控派生的 `dmg-validation` 身份，与本地发行纪律一致。
- 旧的手动校验 workflow（`.github/workflows/release.yml`）保留不变，只做 main 上的发行链健康校验，产物标记不可分发。

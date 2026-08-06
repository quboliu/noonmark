# 私有发行流程（Tag 触发 CI 发版）

本文件是晷迹发版的唯一操作说明。发行入口是 `.github/workflows/release-publish.yml`：**推送版本 tag 自动触发**，在 GitHub-hosted runner 上复跑 `scripts/check`、打包、签名并发布公开 GitHub Release。CI 构建的 DMG 是分发的唯一正本。

## 分工：本地是门禁，CI 是发布

- **本地（质量门禁）**：打 tag 前在开发机跑完整验证链——`make check`、writer-lease E2E、完整 `scripts/test-e2e`、`scripts/release-private-dmg`（诊断闭环、腾讯拼音 smoke、DMG 静态验证、dmg-validation 安装/重启）。全绿才允许打 tag。
- **CI（发布通道）**：hosted runner 跑不了真实 GUI／TCC／腾讯拼音的链路，只做 `scripts/check` + `scripts/package-dmg release` + `scripts/verify-dmg` 静态验证 + 创建 GitHub Release。tag 绑定的 commit 与本地验证过的 commit 是同一个，门禁效果等价。

## 前置条件：签名 secrets（一次性配置）

CI 里 `scripts/package-dmg` 强制稳定 Apple Development 签名，证书以 secrets 形式注入临时 keychain。配置一次，直到证书过期（Apple Development 证书一年有效）：

1. 打开「钥匙串访问」→ 左侧「登录」→ 顶部「我的证书」→ 找到 `Apple Development: <你的名字> (<Team ID>)`，展开左侧三角确认挂着私钥。
2. 右键证书 → 导出 → 格式 `.p12` → 设一个一次性强密码。
3. 终端执行（p12 路径按实际替换）：

   ```bash
   base64 -i ~/Desktop/证书.p12 | tr -d '\n' > /tmp/cert.b64
   gh secret set APPLE_DEV_CERT_P12_BASE64 < /tmp/cert.b64
   gh secret set APPLE_DEV_CERT_PASSWORD        # 回车后粘贴 p12 密码
   gh secret set APPLE_DEV_KEYCHAIN_PASSWORD    # 随机生成一个串即可
   rm -P ~/Desktop/证书.p12 /tmp/cert.b64       # 粉碎本地副本
   ```

铁律：p12 与 base64 绝不进 git、绝不粘到聊天或 issue；缺 secrets 时 workflow 会 fail-closed 并指向本文件。

## 发版步骤

1. 在 `main` 完成开发，本地跑通完整验证链（见上），故障案例与门禁按纪律闭环。
2. 准备候选：更新 `release/VERSION`（PATCH 修复递增 build；MINOR 新能力；MAJOR 需用户明确批准）、`release/BUILD-LEDGER.tsv` 登记 `candidate`、新建 `docs/releases/vX.Y.Z.md`，commit 并 push `main`。
3. 打带注释 tag 并推送：`git tag -a vX.Y.Z -m "Noonmark X.Y.Z (N) release candidate" && git push origin vX.Y.Z`。
4. workflow 自动执行：tag 与 `release/VERSION` 对账 → 导入签名身份 → `scripts/check` → `scripts/package-dmg release` → `scripts/verify-dmg` → 创建或更新 GitHub Release 并上传 `Noonmark.dmg` 与 `Noonmark.dmg.sha256` → 校验 asset 可公开下载。
5. 全绿后回填 `docs/releases/vX.Y.Z.md`（发行 commit、CI 产物 SHA-256、验证摘要、Release 链接），`BUILD-LEDGER.tsv` 标 `released`，commit 并 push。

任何一步判红：删除未交付的候选 tag，修复后用**新 build 号**重开；不得移动已交付 tag，不得复用 build 号。

也可以手动触发：Actions → Release → Run workflow（发布当前 ref 的 `release/VERSION` 对应版本）。

## 边界

- 产物只含 Apple Development 签名：没有 Developer ID、notarization、staple；用户自行下载安装，首次打开按 Gatekeeper 提示确认。
- production App 本体在 CI 中只做静态验证；动态验收固定在本地跑受控派生的 `dmg-validation` 身份。
- 旧的手动校验 workflow（`.github/workflows/release.yml`）保留不变，只做 main 上的发行链健康校验，产物标记不可分发；它需要 self-hosted runner，当前未注册 runner 时不会运行，不影响发版。

# GitHub 发行流程（Tag 触发 CI 发版）

本文件是晷迹发版的唯一操作说明。发行入口是 `.github/workflows/release-publish.yml`：**推送版本 tag 自动触发**，在 GitHub-hosted runner 上复跑 `scripts/check`、打包、签名并发布公开 GitHub Release。CI 构建的 DMG 是分发的唯一正本。

## 分工：本地是门禁，CI 是发布

- **本地（质量门禁）**：先在开发机跑 `make check`、writer-lease E2E 与完整 `scripts/test-e2e`，再创建只存在于本机的 annotated tag，最后运行 `scripts/release-private-dmg`（诊断闭环、腾讯拼音 smoke、DMG 静态验证、dmg-validation 安装／重启）。完整入口签发同一 run 的全部证据后，才允许推送 tag。
- **CI（发布通道）**：hosted runner 跑不了真实 GUI／TCC／腾讯拼音的链路，只做 `scripts/check` + `scripts/package-dmg release` + `scripts/verify-dmg` 静态验证 + 创建 GitHub Release。tag 绑定的 commit 与本地验证过的 commit 是同一个，门禁效果等价。

## 前置条件：签名 secrets（一次性配置）

CI 里 `scripts/package-dmg` 强制稳定 Apple Development 签名，证书以 `release` Environment secrets 注入临时 keychain。该 Environment 只允许 `v*` tag，配置一次后沿用至证书过期或撤销：

1. 打开「钥匙串访问」→ 左侧「登录」→ 顶部「我的证书」→ 找到 `Apple Development: <你的名字> (<Team ID>)`，展开左侧三角确认挂着私钥。
2. 右键证书 → 导出 → 格式 `.p12` → 设一个一次性强密码。
3. 终端执行（p12 路径按实际替换；base64 不落盘，三个 secret 都明确写入 `release` Environment）：

   ```bash
   base64 -i /绝对路径/证书.p12 | tr -d '\n' | gh secret set --env release --repo quboliu/noonmark --app actions APPLE_DEV_CERT_P12_BASE64
   gh secret set --env release --repo quboliu/noonmark --app actions APPLE_DEV_CERT_PASSWORD
   openssl rand -base64 48 | tr -d '\n' | gh secret set --env release --repo quboliu/noonmark --app actions APPLE_DEV_KEYCHAIN_PASSWORD
   rm -P /绝对路径/证书.p12
   scripts/verify-github-release-readiness
   ```

`APPLE_DEV_CERT_PASSWORD` 由 `gh` 的隐藏输入提示接收，不得放进命令参数。铁律：p12、base64 和密码绝不进 git、日志、聊天或 issue。readiness 只能证明 secret 名称与 tag policy 存在；secret 内容与私钥可用性由 CI 的隔离 keychain、唯一身份检查和一次性签名探针 fail-closed 验证。workflow 使用固定 commit 的 checkout action，并在成功或失败路径删除 p12、签名探针和临时 keychain。

## 发版步骤

1. 在 `main` 完成开发与候选资料：更新 `release/VERSION`（PATCH 修复递增 build；MINOR 新能力；MAJOR 需用户明确批准）、`release/BUILD-LEDGER.tsv` 登记 `candidate`、新建 `docs/releases/vX.Y.Z.md`，闭环故障案例与门禁，形成最终 candidate commit 并 push `main`。
2. 在该精确 commit 运行 `make check`、writer-lease E2E 与完整 `scripts/test-e2e`，三者必须使用同一 evidence run ID；验证开始后不得再修改候选源码或文档。
3. 只在本机打带注释 tag：`git tag -a vX.Y.Z -m "Noonmark X.Y.Z (N) release candidate"`，暂不 push。
4. 在同一 tagged commit 与 evidence run 运行 `scripts/release-private-dmg`；它消费前序证据，并生成诊断闭环、腾讯拼音 release smoke、DMG 与受控安装／重启证据。
5. 运行 `scripts/push-release-tag`。该入口会重新消费同一 run 的完整本地检查、writer-lease、E2E、诊断闭环、腾讯拼音 smoke 与 DMG 证据，再拒绝脏工作树、未同步的 `origin/main`、既有远端 tag／Release、缺失签名 secret 或过宽 Environment policy，并在推送后对账 annotated tag object 与 commit。
6. workflow 自动执行：tag 与 `release/VERSION` 对账 → `scripts/check` → 导入并实际证明签名身份 → `scripts/package-dmg release` → `scripts/verify-dmg` → 创建全新的 GitHub Release 并上传 `Noonmark.dmg` 与 `Noonmark.dmg.sha256` → 校验 asset 可公开下载。workflow 拒绝覆盖既有 Release 或 asset。
7. 全绿后回填 `docs/releases/vX.Y.Z.md`（发行 commit、CI 产物 SHA-256、验证摘要、Release 链接），`BUILD-LEDGER.tsv` 标 `released`，commit 并 push。

任何一步判红：删除未交付的候选 tag，修复后用**新 build 号**重开；不得移动已交付 tag，不得复用 build 号。

发行只接受 tag push，不提供 `workflow_dispatch` 或其他手动发布入口。重复 run attempt，或同一 candidate commit 的任何既有 workflow run 都会被 fail-closed 拒绝。tag push 没有建立 run 或任何 run 判红时，必须删除未交付候选并按新 build 号重新开始；既有 Release 与 asset 也始终拒绝覆盖或重签。

## 边界

- 产物只含 Apple Development 签名：没有 Developer ID、notarization、staple；用户自行下载安装，首次打开按 Gatekeeper 提示确认。
- production App 本体在 CI 中只做静态验证；动态验收固定在本地跑受控派生的 `dmg-validation` 身份。
- 旧的手动校验 workflow（`.github/workflows/release.yml`）保留不变，只做 main 上的发行链健康校验，产物标记不可分发；它需要 self-hosted runner，当前未注册 runner 时不会运行，不影响发版。

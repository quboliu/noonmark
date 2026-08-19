# GitHub 发行流程（Tag 触发 CI 发版）

本文件是晇迹发版的唯一操作说明。`ci.yml` 在 main push 上运行 GitHub-hosted 子集；发行入口 `.github/workflows/release-publish.yml` 由版本 tag 自动触发，在打包前与发布前分别验证完整 source identity、live `origin/main` 和该精确 commit 的 hosted CI 已成功，然后签名并发布公开 GitHub Release，不重跑子集。CI 构建的 DMG 是分发的唯一正本。

## 分工：本地是自测，CI 是发布门禁

- **本地（发布前自测）**：开发机先运行 `make check`、writer-lease E2E 与完整 `scripts/test-e2e`；候选经 review、push 到 `origin/main` 且精确 hosted CI 成功后，才运行 `scripts/release-private-dmg --trial /absolute/Downloads/Noonmark-X.Y.Z-buildN.dmg`，覆盖真实 GUI／TCC／腾讯拼音／安装重启，并在全部证据转绿后 exclusive-create 指定 trial 产物。pre-tag trial 与双实体 Mac／72 小时 soak 完成后才允许建立 tag；本机证据不上传、不被 tag publisher 消费，也不是线上发布的机器依赖。
- **CI（发布门禁）**：所有 workflow 只使用 GitHub-hosted runner。main push 只运行一次 `scripts/check` 子集；tag workflow 验证完整 source identity、live `origin/main` 与该精确 commit 的 main CI 结果，不重跑子集，并在最终发布前再次重验。验证成功后才继续 `scripts/package-dmg release`、`scripts/verify-dmg` 与 GitHub Release 发布。CI 不调度本机，也不读取本地自测产物。
- **格式工具链**：`scripts/check` 与 CI 都只通过 `scripts/install-pinned-swiftformat` 使用 checksum 锁定的 SwiftFormat `0.62.1`；不得直接安装或调用 Homebrew 浮动版本。

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

`APPLE_DEV_CERT_PASSWORD` 由 `gh` 的隐藏输入提示接收，不得放进命令参数。p12、base64 和密码绝不进 git、日志、聊天或 issue。readiness 只证明 secret 名称与 tag policy 存在；secret 内容与私钥可用性由 CI 的隔离 keychain、唯一身份检查和一次性签名探针 fail-closed 验证。workflow 使用固定 commit 的 checkout action，并在成功或失败路径删除 p12、签名探针和临时 keychain。

## 发版步骤

1. 在本机 `main` 完成开发与候选资料：更新 `release/VERSION`、`release/BUILD-LEDGER.tsv` 与 `docs/releases/vX.Y.Z.md`，闭环故障案例与门禁。
2. 在该精确 commit 运行本地 `make check`、writer-lease E2E 与完整 `scripts/test-e2e`，完成双轴 review；普通 PR checkout 精确 head，只有 identity 相对 PR 与 current base 的唯一 merge-base 变化时才审计真实 source transition。
3. fast-forward 合入并 push 精确 candidate commit 到 `origin/main`，等待该 SHA 的 `ci.yml` 单一 GitHub-hosted job 成功。不得先打 trial 包再补 push。
4. 确认同名 tag 与目标文件均不存在，运行 `scripts/release-private-dmg --trial /absolute/Downloads/Noonmark-X.Y.Z-buildN.dmg` 完成本地诊断闭环、腾讯拼音、DMG、安装重启自测与不可覆盖的 trial 交付。trial 与真实安装入口都会再次要求 `origin/main` 精确等于 `HEAD`，并消费该 SHA 唯一首次成功的 hosted CI；最终复制前还会重跑完整 trial authority verifier。输出 basename 必须精确匹配 current version／build。全部本地 evidence 只服务自测审计，不上传给 GitHub。
5. 把独立命名、不覆盖的 trial DMG 交给当前指定用户；完成双实体 Mac 与连续 72 小时 soak。任一失败即退休 build，使用更大 build 重新开始。
6. 灰度全绿并获审核后，在精确候选 `HEAD` 创建 annotated tag `vX.Y.Z`，先不 push；运行默认 `scripts/release-private-dmg`，让 exact tag、live `origin/main`、GitHub release Environment 与完整本机门禁再次通过。
7. 运行 `scripts/push-release-tag`。该入口拒绝脏工作树、未同步的 `origin/main`、未成功的精确 commit hosted CI、既有远程 tag／Release、缺失签名 secret 或过宽 Environment policy；它不读取本地测试 evidence。
8. tag workflow 自动执行：tag 与 `release/VERSION` 对账 → 验证完整 source identity、live `origin/main` 与该 commit 的单一 GitHub-hosted CI 成功 → 导入并实际证明签名身份 → `scripts/package-dmg release` → `scripts/verify-dmg` → 从上一个稳定 tag 至当前 tag 的英文 conventional commits 生成简要英文 Release notes → 再次验证 source、live remote 与 hosted CI → 创建全新的 GitHub Release 并上传 `Noonmark.dmg` 与 `Noonmark.dmg.sha256` → 校验 Release 正文语言与 asset 可公开下载。workflow 不重跑 `scripts/check`，也拒绝覆盖既有 Release 或 asset。
9. 全绿后回填 `docs/releases/vX.Y.Z.md`（发行 commit、CI 产物 SHA-256、验证摘要、Release 链接），`BUILD-LEDGER.tsv` 标 `released`，commit 并 push。

未交付候选的 tag workflow 若失败，删除远程候选 tag，修复后用新 build 号重开；不得移动已交付 tag，不得复用失败 build 号。发行只接受 tag push，不提供 `workflow_dispatch` 或其他手动发布入口；重复 run attempt 与既有 Release／asset 始终 fail-closed。

## 边界

- `.github/workflows/` 不允许出现 `self-hosted` runner；真实 App、腾讯输入法、TCC 与 DMG 安装重启入口保留为本地自测。
- production App 本体在 CI 中只做静态验证；本地动态验收固定使用受控派生的 `dmg-validation` 身份。
- 产物只含 Apple Development 签名：没有 Developer ID、notarization、staple；用户自行下载安装。

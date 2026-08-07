# FAIL-2026-08-07-03：GitHub 发行签名环境未就绪

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T09:56:37Z
- 影响版本／构建：v0.2.4 build 10，source commit `c2fbfc0ee2c894f008458be28cc0dad0c09cb741`
- 引入提交：`b1f609c1e5d7403a3bc44c4fe735430e94dc406c`（`ci(release): simplify publishing to hosted runners with local gates`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

推送 v0.2.4 build 10 tag 后，GitHub Release workflow 在导入签名身份前立即失败，没有建立 Release，也没有上传 DMG 或 checksum。失败发生在外部发行通道，已在本机验证的 App 与 DMG 内容没有因此改变；用户资料与 production App 均未被运行或触碰。

## 时间线

- 2026-08-07T09:56:37Z：workflow run `31167996734` 的签名导入 step 检测到三个必要 secret 都为空并退出。
- 随后两次只读 metadata 对账都确认 `release` Environment 没有 Actions secret；部署 policy 则精确为 tag `v*`。
- 确认 v0.2.4 没有 GitHub Release 后，build 10 按发行纪律退役，build 11 作为新候选。

## 复现与证据

run `31167996734`／job `92833146463` 显示版本、tag 与 toolchain step 成功，`APPLE_DEV_CERT_P12_BASE64`、`APPLE_DEV_CERT_PASSWORD`、`APPLE_DEV_KEYCHAIN_PASSWORD` 在签名导入 step 均为空；后续检查、打包、DMG 验证与发布 step 全部 skipped。`gh secret list --repo quboliu/noonmark --env release --app actions` 返回零项。旧有 `scripts/test-release-version-contract` 与 `scripts/test-failure-case-gates` 同时保持绿色，证明既有门禁没有覆盖 canonical `release-publish.yml` 的外部 readiness。

## 排除的假设

- 不是 App、Swift 测试或 DMG 打包失败：这些 step 在远端没有执行；同一 commit 的本地完整链已经通过。
- 不是 tag 与版本不匹配：workflow 的 tag 绑定 step 已通过。
- 不是 Environment tag policy 拒绝：policy 精确允许 `v*`，且 job 已进入该 Environment。
- 不是证书内容损坏：失败时根本没有证书 secret 可供解码；内容可用性留给修复后的隔离导入与签名探针验证。

## 根因与破坏机制

hosted-runner 发行路径在 `b1f609c1e5d7403a3bc44c4fe735430e94dc406c` 引入三个外部签名 secret 依赖，但 tag 前本地门禁没有检查 `release` Environment 是否已经配置。发行说明中的 `gh secret set` 也遗漏 `--env release`，照文档操作会把 secret 写到 repository scope，而 workflow 从 Environment scope 读取，形成无法闭环的操作路径。canonical workflow 本身还没有被现有 contract 约束，checkout 未固定到 commit，失败路径也不会无条件清除临时签名材料。

## 根因修复

新增 live GitHub readiness verifier，并强制本地发行入口与唯一 tag 推送入口调用；新增 fixture contract 捕获缺 secret、错误 branch policy 与过宽 tag policy。canonical workflow 固定 checkout commit、关闭凭证留存，把签名导入移至仓库检查后，签名材料只写入 `RUNNER_TEMP`，要求恰好一个有效 Apple Development 身份，并以一次性 probe 实际签名／验证；成功与失败路径都清除 p12、probe 与临时 keychain。发行说明改为 Environment-scoped secret 和受保护 tag 推送路径。

## 验证结果

待 build 11 的 fixture red／green、live readiness、本地完整发行链与 tag workflow 实际签名／公开资产 checksum 对账完成后回填。

## 永久门禁

- fast：`scripts/test-github-release-readiness-contract`，由 `scripts/check` 强制执行。
- symptom：`scripts/verify-github-release-readiness`，由 `scripts/release-private-dmg` 在昂贵的 App／DMG 门禁前强制执行。
- release：`scripts/verify-github-release-readiness`，由 `scripts/push-release-tag` 在任何远端 tag 副作用前强制执行；tag workflow 再验证 secret 内容、私钥签名能力与公开资产。

## 发行与回滚

build 10 永久标记 `retired`。未交付的 v0.2.4 tag 只有在再次确认不存在 GitHub Release 后才可删除，并只在 build 11 最终 commit 的完整本地链全绿后重建。若 secret 配置异常，删除三个 Environment secret；若私钥疑似泄露，必须在 Apple 侧撤销证书并换证，不能只删 GitHub secret。workflow 与门禁可用普通 revert 回滚，但不得移动已经交付的 tag 或复用 build 10。

## 教训与永久约束

外部发行前置条件必须在产生 tag 副作用前以 live metadata fail-closed；文档命令必须与 workflow 的 secret scope 完全对等。secret 名称存在不等于内容有效，因此 metadata readiness 与隔离 keychain 的真实签名 probe 缺一不可。canonical workflow 必须由 fast contract 直接约束，不能让旧 workflow 的绿色掩盖真实发布路径。

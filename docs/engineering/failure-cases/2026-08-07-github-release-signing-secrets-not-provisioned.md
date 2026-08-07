# FAIL-2026-08-07-03：GitHub 发行签名环境未就绪

- 状态：已修复
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T09:56:37Z
- 影响版本／构建：v0.2.4 build 10，source commit `c2fbfc0ee2c894f008458be28cc0dad0c09cb741`
- 引入提交：`b1f609c1e5d7403a3bc44c4fe735430e94dc406c`（`ci(release): simplify publishing to hosted runners with local gates`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`2f06f7d310fba59bd6a2c2bc743cac67d0d9f99c`（`fix(release): require tag-triggered publication`）

## 用户症状与影响

推送 v0.2.4 build 10 tag 后，GitHub Release workflow 在导入签名身份前立即失败，没有建立 Release，也没有上传 DMG 或 checksum。失败发生在外部发行通道，已在本机验证的 App 与 DMG 内容没有因此改变；用户资料与 production App 均未被运行或触碰。

## 时间线

- 2026-08-07T09:56:37Z：workflow run `31167996734` 的签名导入 step 检测到三个必要 secret 都为空并退出。
- 随后两次只读 metadata 对账都确认 `release` Environment 没有 Actions secret；部署 policy 则精确为 tag `v*`。
- 确认 v0.2.4 没有 GitHub Release 后，build 10 按发行纪律退役，build 11 作为新候选。
- 旧的未交付 v0.2.4 annotated tag object `e7aad9dd04757545ab56c0cd61c3669274deae12`（peeled commit `c2fbfc0ee2c894f008458be28cc0dad0c09cb741`）经再次确认没有 Release 后，从远端与本机删除。
- 本机唯一有效 Apple Development 身份以随机 P12 密码导出，在隔离临时 keychain 完成 exact identity、证书有效期与一次性文件签名／验证，再通过 stdin 写入三个 `release` Environment secret；临时 P12、probe、keychain 与目录全部清理，未打印 secret 值。
- build 11 的本地完整 E2E 在 `mouseDown` 前捕获 `FAIL-2026-08-04-28` 的飞光 presentation settlement 复发；该 build 按纪律退役，build 12 成为新候选。
- build 12 的完整本地发行链通过，但 tag workflow 因 `FAIL-2026-08-07-04` 在 job 建立前失效；普通 CI 同时暴露 `FAIL-2026-08-07-05`。该 build 没有 Release，已退役并删除未交付 tag；hosted signing 修复改由 build 13 的首次 tag run 证明。
- build 13 已修正 workflow 与 Xcode 基线，但普通 hosted check 在完成全部 build／test 后暴露 `FAIL-2026-08-07-06` 的缺失 `rg` 依赖；该 build 未建立 tag 或 Release，并已退役，最终 hosted signing 证明顺延至 build 14。
- build 14 已安装 `rg` 并完成产品编译，但全量测试暴露 `FAIL-2026-08-07-07` 的飞光成功过渡 wall-clock 竞态；该 build 未建立 tag 或 Release，并已退役，最终 hosted signing 证明顺延至 build 15。
- build 15 的 1527 项 XCTest 已全绿，但后续 UI localization guard 暴露 `FAIL-2026-08-07-08` 的 Han Unicode oracle 漂移；该 build 未建立 tag 或 Release，并已退役，最终 hosted signing 证明顺延至 build 16。
- build 16 越过 localization 后，在完整 DMG evidence matrix 中触达初始 25 分钟 CI 上限并被取消，暴露 `FAIL-2026-08-07-09`；该 build 未建立 tag 或 Release，并已退役，最终 hosted signing 证明顺延至 build 17。

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

新增 live GitHub readiness verifier，并强制本地发行入口与唯一 tag 推送入口调用；新增 fixture contract 捕获缺 secret、额外 secret、错误 branch policy 与过宽 tag policy。guarded publisher 还必须消费同一 run 的 make check、writer-lease、完整 E2E、诊断闭环、腾讯输入 source／run 绑定 evidence 与完整 DMG evidence。canonical workflow 固定 checkout commit、关闭凭证留存，把签名导入移至仓库检查后，签名材料只写入 `RUNNER_TEMP`，要求恰好一个有效 Apple Development 身份，并以一次性 probe 实际签名／验证；成功与失败路径都清除 p12、probe 与临时 keychain。Release 与 asset 只能建立一次，不准 edit、clobber 或重复 run；经用户明确批准后移除 `workflow_dispatch`，发行只接受 tag push。发行说明改为 Environment-scoped secret、真实本地 tag 验证顺序和受保护 tag 推送路径。

## 验证结果

- Red：没有配置 secret 时，`scripts/verify-github-release-readiness` exit 1，并精确报告缺少 `APPLE_DEV_CERT_P12_BASE64`；旧门禁仍绿，证明原始覆盖空洞。
- Green：配置完成后，同一 live verifier exit 0，精确确认 `quboliu/noonmark` 的 `release` Environment；secret 列表恰有三个预期名称，部署 policy 恰为 tag `v*`。
- Green（release）：run `31213156156` 从 `release` Environment 成功导入并证明 Apple Development 身份，随后发布唯一 DMG 与 checksum。
- 本机签名验证：导出的 P12 在隔离 keychain 中只有一个有效 Apple Development identity，证书未过期，一次性 probe 的 `codesign --verify --strict` 通过，清理后临时目录计数为零。
- Fast gates：`scripts/test-github-release-readiness-contract`、`scripts/test-failure-case-gates`、`scripts/test-release-gate-contract` 与 `scripts/test-release-version-contract` 在 build 12 全绿，覆盖额外 secret、policy、workflow pin／cleanup／不可覆盖与完整 evidence；build 13 另以 `actionlint` 修补 workflow 语义覆盖空洞。
- Pre-release review：以 `c2fbfc0ee2c894f008458be28cc0dad0c09cb741...HEAD` 为边界的实现 Standards 与 Spec 双轴复核在进入真实发行 gate 前零 finding。
- 本案例保持「处理中」，直到 build 17 的 tag workflow 实际签名与公开资产 checksum 全绿；只有原始 hosted victim path 由红转绿并完成最终复核后才改为「已修复」。

## 永久门禁

- fast：`scripts/test-github-release-readiness-contract`，由 `scripts/check` 强制执行。
- symptom：`scripts/verify-github-release-readiness`，由 `scripts/release-private-dmg` 在昂贵的 App／DMG 门禁前强制执行。
- release：`scripts/verify-github-release-readiness`，由 `scripts/push-release-tag` 在任何远端 tag 副作用前强制执行；tag workflow 再验证 secret 内容、私钥签名能力与公开资产。

## 发行与回滚

build 10 至 build 16 永久标记 `retired`。未交付的 v0.2.4 tag 只有在再次确认不存在 GitHub Release 后才可删除；build 17 只在针对性门禁与普通 hosted CI 全绿后重建 tag。若 secret 配置异常，删除三个 Environment secret；若私钥疑似泄露，必须在 Apple 侧撤销证书并换证，不能只删 GitHub secret。workflow 与门禁可用普通 revert 回滚，但不得移动已经交付的 tag 或复用已退役 build。

## 教训与永久约束

外部发行前置条件必须在产生 tag 副作用前以 live metadata fail-closed；文档命令必须与 workflow 的 secret scope 完全对等。secret 名称存在不等于内容有效，因此 metadata readiness 与隔离 keychain 的真实签名 probe 缺一不可。canonical workflow 必须由 fast contract 直接约束，不能让旧 workflow 的绿色掩盖真实发布路径。

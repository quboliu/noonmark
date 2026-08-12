# 晷迹版本体系与 GitHub 发行流程

## 状态与范围

- 生效日期：2026-08-05
- 当前已发行基线：`0.2.6 (28)`；精确 commit 为 `12ed27bf5d43077744a65c932703f2051f6d4ca4`，由 annotated tag `v0.2.6` 绑定。
- 当前未发行 trial candidate：`0.3.0 (30)`；采用 schema 19 Replication V2 clean cut，在双实体 Mac 与连续 72 小时 soak 完成前不得建立 tag 或宣称 release ready。
- 发行方式：在公开仓库建立公开 GitHub Release，提供 Apple Development 签名 DMG；不宣称 Developer ID、notarization、staple 或 Gatekeeper 分发完成。

本文是营销版本、构建号、资料兼容与 GitHub 发行的唯一流程说明。它不改变任何用户资料兼容承诺；改变兼容范围前必须取得用户明确审核与同意。

## 唯一版本来源

受 Git 管理的 [`release/VERSION`](../../release/VERSION) 是唯一版本来源，且只能包含：

```text
marketing_version=MAJOR.MINOR.PATCH
build_number=正整数
```

- `marketing_version` 写入 `CFBundleShortVersionString`，并对应精确 Git tag `v<marketing_version>`。
- `build_number` 写入 `CFBundleVersion`。每一次私有 DMG 候选都必须使用从未使用过的更大构建号；不得覆盖、重签或替换既有 build 的 DMG。
- [`release/BUILD-LEDGER.tsv`](../../release/BUILD-LEDGER.tsv) 是不可复用 build 的机器可检登记。版本文件必须恰好指向一条 `candidate` 或 `released` 记录；build 必须严格递增。失败候选保留并在后续准备时标为 `retired`，绝不回收其号码。
- `scripts/release-version` 是 shell 读取入口。版本环境变量一旦存在即 fail-closed；不得再用环境变量生成另一套身份。
- App 内的 Commit、UTC build date、Mach-O UUID、dSYM 和 SHA 继续由真实构建产物派生，不能手写进版本文件。

现有历史 tag `v1.0`、`v0.1.0-test.1` 不满足本流程，不作为当前发行序列的依据，也不回写或移动。`v0.2.1` 是本流程落地前已验证的历史基线，精确指向其发行 commit `5f4d6cd`；新 tag 校验只适用于本流程启用后的新候选，下一次发行必须先提升版本／build，再让 tag 指向该候选 `HEAD`。

## 版本与资料兼容矩阵

| 当前基线 | SQLite | JSON 数据包 | 升级／导入承诺 |
| --- | --- | --- | --- |
| `0.3.0 (30)` trial candidate | current schema `19` | current format `7` | 开发期 clean cut：只接受空库或 exact schema 19；只导入 canonical format 7。v15／v17／v18、format 6、V1 或无 marker 非空 repository 全部在写入前 fail-closed，不迁移、不兼容、不自动删除 |
| `0.2.7 (29)` 退役候选 | 当前 schema `18` | 当前 format `7` | 只记录历史 confirmed-frontier 候选；源码与 schema 已被 Replication V2 取代，build 29 不得重打、交付或复用 |
| `0.2.6 (28)` | 已发行 schema `18` | 已发行 format `7` | 从 `0.2.5` 升级不改变 SQLite、JSON 或同步 repository 格式；旧的不兼容同步 repository 继续 fail-closed，不迁移、不兼容、不自动删除 |
| `0.2.5 (24)` | 已发行 schema `18` | 已发行 format `7` | 受控 v15／v17 SQLite 原地升级至 v18；保留领域事实和设备身份，clean cut 旧同步 runtime；用户自行准备空的新 repository 后由本机 snapshot 建立 baseline |
| `0.2.4 (21)` | 已发行 schema `17` | 已发行 format `7` | 受控 v15 SQLite 原地升级至 v17；严格 canonical v6 JSON 可导入，v7 可导入与导出 |

支持范围必须由源码、专项测试和真实 App 路径共同证明；未知非空 schema、未知 JSON format 与非 canonical 输入保持 fail-closed。下一版是否继续支持、扩展或移除任一旧格式，必须在编码前写入该版 release note 的兼容矩阵并由用户明确批准。开发／E2E／Demo 资料仍遵守 clean cut，不以生产用户升级规则替代。

## 迭代与发行流程

1. **立项与版本分配**：在需求设计中声明用户可见范围、目标 `MAJOR.MINOR.PATCH`、下一构建号和资料兼容矩阵。营销版本只在兼容决策、产品范围和验证方式被审核后修改；build 号随候选递增。
2. **开发与合并**：每项工作使用隔离 worktree，按需求、现状、设计、实施、验证、闭环推进。修复必须更新故障案例和 fast／symptom／release 门禁映射。
3. **合入 `main`**：只接受经过 review 的干净提交。trial 阶段允许本机 `main` 尚未 push；任何未提交内容都不能进入 package。正式发布前再按已审核步骤正常 push `main`，它仍是唯一发行候选分支。
4. **发行前验证**：在实际打包的 `main` worktree 运行 `make check`、writer-lease E2E 与完整 `scripts/test-e2e`，得到同一 evidence run 的成功清单。新增或改变用户可见能力时，同步运行 `make test-demo-fixture`；资料变更额外运行 clean-cut 与 current JSON 导入专项测试。
5. **Pre-tag trial 门禁**：在没有同名 tag 与目标输出时运行 `scripts/release-private-dmg --trial /absolute/Downloads/Noonmark-X.Y.Z-buildN.dmg`。`scripts/verify-release-trial-version` 要求 current version 精确指向 ledger 最后一条最高 build 的 `candidate`；随后执行与 tagged 本机候选相同的静态证据、诊断闭环、腾讯输入 release smoke、DMG 打包、只读静态验证、受控 `dmg-validation` 安装／退出／重启及最终证据对账。入口在 full verifier 前后固定同一 package manifest SHA；全部成功后，publisher 仍须把 source、临时副本和 final output 三次对账到该 manifest 的 `dmg_sha256`，才按 current version／build 的 canonical basename，在 physical non-symlink parent 内 exclusive-create trial DMG 并报告 SHA-256。既有输出永不覆盖。trial 不检查 GitHub Environment，也不触发 hosted CI、push 或 Release。
6. **实体灰度与 soak**：trial DMG 只以全新、不覆盖的名称交给当前指定用户。双实体 Mac 与连续 72 小时 soak 全绿前不建立 tag；失败时退休该 build，下一候选使用更大 build，不覆盖现存产物。
7. **本地候选 tag 与 tagged 门禁**：灰度完成并获审核后，在精确候选 commit 创建带注释 tag `v<marketing_version>`，先不 push。默认运行 `scripts/release-private-dmg`；它继续要求 tag 精确指向 `HEAD`、GitHub release Environment ready，并重跑完整本机 package／install 门禁。`make package-dmg` 与 `make release-private-dmg` 只委托默认 tagged 入口，不会隐式进入 trial。
8. **候选发布**：只用 `scripts/push-release-tag` 推送。该入口要求 `origin/main` 精确等于 `HEAD`、远端没有同名 tag／Release、GitHub `release` Environment 恰有三个签名 secret 且只允许 `v*` tag。tag workflow 还拒绝重复 run attempt 和同一 commit 的既有 run，验证该 commit 已有且唯一的 GitHub-hosted CI 成功，再以临时 keychain 验证唯一签名身份和一次性签名探针，最后发布公开 GitHub Release。公开 Release notes 只从英文 conventional commits 生成，过滤 CI／release／test／docs 等非用户作用域，并在发布前后拒绝 Han 正文；内部版本记录继续使用新加坡中文。若任一门禁失败，删除未交付候选并用新 build 重新开始；不得移动已交付 tag。成功后保留 SHA-256、release manifest、dSYM 和 release note。

## 版本号语义

- `MAJOR`：只有在用户明确批准不兼容产品或资料边界时才递增。
- `MINOR`：新增完整、可独立说明的用户能力，且兼容矩阵已审核。
- `PATCH`：修复、稳定性、诊断或不扩展用户能力的改进。
- 同一营销版本的候选重打必须只递增 build；若源码、门禁或发行证据改变，不得沿用旧 build。

这是一项分类与沟通规则，不会自动授权资料迁移、兼容层、回退路径或移除旧路径。

## 风险、回滚、灰度与监控

| 风险 | 预防与检测 | 回滚／处置 |
| --- | --- | --- |
| 版本、tag 或二进制身份错配 | `release/VERSION` 单一来源、精确 tag、manifest／UUID／dSYM／SHA 对账 | 停止交付该 DMG；不移动已推送 tag，使用新 build 修复并重新验证 |
| 用户资料升级或导入损失 | 每版显式兼容矩阵、SQLite／JSON 专项测试、真实 File → Import E2E | 不自动降级或删除用户资料；停止候选，保留原 DMG，由用户审核恢复路径 |
| 发行验证误触 production | production 只读静态验证；动态验证固定 `e2e`／`dmg-validation` profile | 立即停止发行流程，保留最小无敏感证据并审查 profile 边界 |
| 小范围设备／输入环境回归 | 本地真实 IME smoke、公开资产 checksum、用户主动导出的有界诊断 | 撤下 Release 资产，回退到上一已验证 DMG；诊断不自动上传 |

监控只使用用户主动导出的、隐私哨兵保护的结构化诊断，以及发行 manifest 的版本／commit／SHA 证据。不得记录任务正文、路径、账户、同步 payload、AI 内容或凭证。

# FAIL-2026-08-12-01：Pre-tag trial 被正式发行 tag 前置条件阻断

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-12T05:20:00Z
- 影响版本／构建：`0.2.7 (29)` candidate；Replication V2 source commit `f225dd98bc22650ba09122fe69fc2f4e11e2a06b`
- 引入提交：`a2eaca6571b8226c55fcd5cc289fdeefeb28890d`（`feat(release): standardize versioning and the private release process`）
- 加重提交：`885d0843be615bcab4357848e90a8851f00f71ed`（`fix(release): harden GitHub signing readiness`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：`84a1b113835bd3d4ce800f7ef24ac0e3ed57d4ea`（trial 状态与版本身份）、`314bbf1eb996ab6ddb2c5ae19c680042643d1d56`（exclusive output）、`461fb598d80ed548669295f08137d2dd7108f47a`（package evidence authority）；build 30、31、32、33、34、35 已退役，后续验证由 `0.3.1 (36)` 继续；案例保持处理中

## 用户症状与影响

用户批准的顺序是先生成本机签名 trial DMG，完成双实体 Mac 与 72 小时 soak 后才建立 tag、push 和发布。实际唯一 DMG 入口在任何打包前强制要求 exact annotated tag，因此本机 trial 被阻断。与此同时，旧 `0.2.7 (29)` 身份已经在 Replication V2 之前分配并产生过 DMG，继续沿用会把不同源码和 schema 19 clean cut 错装进同一 build 身份。

故障正确地在打包副作用前 fail-closed，没有启动 production App、没有创建新 DMG、没有 tag／push／hosted CI，也没有读取或修改用户资料与 iCloud repository。

## 时间线

- 2026-08-05：commit `a2eaca6571b8226c55fcd5cc289fdeefeb28890d` 把 exact tag 无条件放入本地 DMG 唯一入口。
- 2026-08-07：commit `885d0843be615bcab4357848e90a8851f00f71ed` 再把 GitHub Environment readiness 放入同一前置链，加重本机质量门禁与线上发布条件的耦合。
- 2026-08-11T04:42:42Z：commit `012aa8595db51d42d60f6c59515a6939acf98a32` 分配 `0.2.7 (29)` 给 schema 18 confirmed-frontier trial。
- 2026-08-12：Replication V2 schema 19 clean cut 在 commits `6a16e02bbaaf10b7e7d2cdcc2b10db5e3d141d73` 与 `f225dd98bc22650ba09122fe69fc2f4e11e2a06b` 完成并通过本机完整验证。
- 2026-08-12T05:20:00Z 后：`scripts/release-private-dmg` 报 `release requires exact tag v0.2.7 on the candidate commit`，确认 tag-first 与已批准 trial-first 顺序冲突。

## 复现与证据

在 clean HEAD `f225dd98bc22650ba09122fe69fc2f4e11e2a06b` 上，完整签名 App E2E run `20260812T045233Z-41547`、同 run writer-lease 与完整 `make check` run `20260812T050414Z-55770` 均成功。随后调用唯一发行入口，在 `scripts/verify-release-version-tag` 立即退出 1；源码 blame 把无条件 tag 调用定位到引入提交 `a2eaca6571b8226c55fcd5cc289fdeefeb28890d`。

`release/VERSION` 与 ledger 的运行时读取证明 current identity 仍为 `0.2.7 (29)`；旧 `dist/Noonmark.dmg` 的 SHA-256 为 `c8680ae9fe0e018594bf509e0f8b577cdffd644855938d66ac0f1ad384fb9e5a`，修改时间早于 V2 commits，因此不能作为 V2 trial。

## 排除的假设

- 不是 V2 build、测试或 App 症状失败：完整 `make check`、签名 App E2E 与 writer lease 已在同一 clean source 上通过。
- 不是 provisioning profile 或 code-sign identity 失败：流程尚未进入 package 或签名阶段。
- 不是 GitHub-hosted CI 失败：本轮没有触发 workflow；用户也没有授权 hosted CI。
- 不是缺少用户授权建立 tag：用户明确要求 trial、双机与 soak 完成后才进入 tag／push／release。

## 根因与破坏机制

版本治理把“本机候选质量门禁”与“GitHub 发布身份／环境门禁”合并成单一无参数阶段，缺少 pre-tag trial 这一真实生命周期状态。结果是唯一安全 DMG 入口只能通过提前建立 tag 来使用，迫使操作者在违反批准顺序与绕过唯一门禁之间二选一。

同一模型也没有在候选源码发生大范围变化时自动阻止继续指向已分配 build；若直接沿用 build 29，会破坏版本／源码／产物的一一对应和不可复用 ledger 约束。

## 根因修复

commit `84a1b113835bd3d4ce800f7ef24ac0e3ed57d4ea` 已新增显式 pre-tag trial 状态及独立 trial version verifier；trial 只跳过 tag 与 GitHub Environment readiness，随后复用全部本机发行证据链。默认模式继续强制 exact annotated tag 和 GitHub readiness。build 29 永久退役，Replication V2 分配 `0.3.0 (30)`。

审查整改 commits `314bbf1eb996ab6ddb2c5ae19c680042643d1d56` 与 `461fb598d80ed548669295f08137d2dd7108f47a` 进一步把 trial output 纳入唯一入口：调用者必须显式提供 absolute canonical output；入口在 full verifier 前后固定 package manifest SHA，publisher 再把 source、同目录临时副本与 final output 全部对账到该 manifest 的 `dmg_sha256`，最后才以不可覆盖 hard link 原子暴露最终名称。既有输出、source／manifest／parent symlink、manifest replacement、路径 alias、错误 basename 或 checksum 漂移全部 fail-closed；门禁精确校验 tagged／trial 两条命令序列与每一阶段参数。

## 验证结果

- Red（症状）：旧入口拒绝 `--trial`，且无 tag 时默认入口在 package 前退出 1。
- Green（fast）：`scripts/test-release-version-contract` 已在 `0.3.0 (30)` 上通过；版本、ledger、tagged／trial verifier 均被聚合入口固定。
- Green（symptom）：`scripts/test-release-trial-contract` 已以隔离 Git／命令 fixture 证明 trial 与 tagged 前置分流、共享阶段的 exact order／arguments、full verifier 期间 manifest replacement 拒绝，以及 tag／retired／非最新 candidate 拒绝；`scripts/test-release-trial-output-contract` 已证明 manifest-authoritative 新输出、source／manifest tamper 拒绝、既有输出不可变、canonical basename 与 symlink 边界。
- Green（release）：build 31 已在其精确 commit 上真实完成完整 pre-tag trial DMG 门禁；后续源码与门禁变化已依次退休 build 31、32、33、34 与 35，`0.3.1 (36)` 必须重新取得完整门禁证据。

## 永久门禁

- fast：`scripts/test-release-version-contract`，由 `scripts/check` 强制调用；固定 current candidate、严格递增 ledger 与 tagged／trial 两种版本前置条件。
- symptom：`scripts/test-release-trial-contract` 与 `scripts/test-release-trial-output-contract`，由 `scripts/check` 强制调用；以隔离 fixture 证明无 tag candidate 可进入 trial、tag／retired／非最新 build 均 fail-closed，两种入口按 exact order／arguments 汇合到同一 package chain，package manifest authority 在 full verifier 前后保持不变，最终 trial output 只能按该 authority canonical exclusive-create。
- release：`scripts/test-dmg-install` 与 `scripts/publish-trial-dmg`，由 `scripts/release-private-dmg --trial <absolute-output-dmg>` 强制调用；对 exact package 的受控 `dmg-validation` 身份完成真实安装、交互、退出、重启与资料回读，随后才 exclusive-create canonical trial output。

## 发行与回滚

build 29、30、31、32、33、34、35 永久退役且不覆盖。后续候选只能生成独立命名的 `0.3.1 (36)` trial；精确 `main` 按用户要求先 push 并等待 hosted CI，再进入私有出包，但不建立或 push tag、不触发 GitHub Release。任何本机、双 Mac 或 soak 故障都停止扩大试用并退休当前 build；下一候选使用更大 build，不移动 tag、不降级资料、不恢复 V1，也不触碰既有 iCloud 对象。

## 教训与永久约束

“候选质量已经通过”与“发布身份已经建立”是两个相邻但不同的状态。唯一入口必须显式表达状态，而不是要求提前制造 tag，也不能以直接调用底层 packager 绕过真实门禁。每个实际打包过的 build 只对应一份源码身份；源码或门禁改变后必须分配新 build。

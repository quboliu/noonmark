# FAIL-2026-08-07-04：GitHub Release workflow 在 job 建立前失效

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T15:22:40Z
- 影响版本／构建：v0.2.4 build 12，source commit `895caff49b7f1ecc975d5eb6cdba8303dca9e117`
- 引入提交：`885d0843be615bcab4357848e90a8851f00f71ed`（`fix(release): harden GitHub signing readiness`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`84b6127983f3a07bf28d153aec0be3752e542bc2`（`fix(release): validate hosted publication boundaries`）

## 用户症状与影响

build 12 的 `main` push 与 v0.2.4 tag push 都产生零秒失败的 Release workflow run；两个 run 都没有建立任何 job，GitHub 只报告 workflow file issue。公开 Release、DMG 与 checksum 均未建立。App、production 资料、签名 secret 内容和测试逻辑都没有进入执行路径。

## 时间线

- 2026-08-07T15:22:40Z：run `31192294933` 在 `main` push 后零 job 失败。
- 2026-08-07T15:24:30Z：run `31192448677` 在 v0.2.4 tag push 后以相同症状失败。
- `gh release view v0.2.4` 与远端 tag 对账确认没有 Release 后，build 12 退役，未交付 tag 从远端和本机删除，build 13 成为新候选。

## 复现与证据

两个 run 的 API 记录均为 `status=completed`、`conclusion=failure`、`jobs=[]`；`gh run view` 明确提示 workflow file issue。最小确定性复现为：

```text
actionlint .github/workflows/release-publish.yml
```

旧文件稳定报告三项 `context "runner" is not allowed here`，精确指向 job 级 `env` 中的 `NOONMARK_CI_CERT_P12`、`NOONMARK_CI_KEYCHAIN` 与 `NOONMARK_CI_SIGNING_PROBE`。

## 排除的假设

- 不是 App、Swift 测试或 DMG 打包失败：任何 job 都没有建立。
- 不是 signing secret 缺失或证书损坏：导入 secret 的 step 没有机会启动。
- 不是 tag／版本绑定失败：解析 tag 的 step 同样没有启动。
- 不是本机发行证据失效：本机完整链已通过；本故障只发生在 GitHub 解析 workflow 的阶段。

## 根因与破坏机制

`885d0843` 把依赖 runner 建立后才存在的 `runner.temp` 放进 job 级 `env`。GitHub 在建立 runner 和 job 之前解析该位置，而该位置只允许 `github`、`inputs`、`matrix`、`needs`、`secrets`、`strategy` 与 `vars` context，因此整份 workflow 在调度前失效。既有 release contract 只以文字匹配确认临时路径存在，反而没有验证表达式在真实 GitHub context 中是否合法。

## 根因修复

三个临时签名路径只放进“导入签名身份”和 `always()` 清理 step 的 `env`；job 级只保留合法的 run identity 与 token。`actionlint` 成为 `scripts/check` 的必要工具并扫描全部 workflow，仓库配置只声明真实存在的 `noonmark-ui-e2e` 自定义 runner label，不忽略任何语义错误；tag publisher 在推送前记录既有 run，推送后只接受本次 commit 的新 run，并要求至少建立一个 job、成功完成且建立唯一 DMG 与 checksum 资产。

## 验证结果

- Red：旧 workflow 的 `actionlint` 稳定输出三项 `runner` context error。
- Green（fast）：修复提交上的 5 份 workflow 已通过 `actionlint`；release readiness、release aggregation 与 failure-case registry contract 同时通过。
- 待 Green（受害路径）：build 13 普通 CI 已建立真实 job，但因独立的 hosted 工具依赖故障退役；build 14 的 tag workflow 必须建立真实 job 并成功完成。
- 本案例在公开 Release、两个 canonical 资产与 checksum 尚未完成前保持「处理中」。

## 永久门禁

- fast：`scripts/test-github-actions-workflows`，由 `scripts/check` 强制调用，使用 `actionlint` 验证全部 GitHub workflow 的 context、表达式、YAML 与内嵌 shell。
- symptom：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 在 tag push 后强制调用；新 run 若零 job 完成会精确判红。
- release：同一 live verifier 必须等候精确 run 成功，并确认 Release 中恰有一个 `Noonmark.dmg` 和一个 `Noonmark.dmg.sha256`。

## 发行与回滚

build 12 与 build 13 永久标记 `retired`，不得复用。build 13 的普通 CI 已证明 workflow 能建立真实 job，但因独立工具依赖故障停止；build 14 由完整 tag-only 路径触发 Release。若 hosted run 再失败，退役该 build，保留失败 run 与 commit，不 rerun、不移动 tag。workflow 代码可以普通 revert，但不得恢复 job 级 `runner.temp`。

## 教训与永久约束

GitHub workflow 是可执行发行代码，文字 contract 不能替代官方 context 语义验证。任何 workflow 修改必须在产生远端 tag 前经过 `actionlint`；真实 tag publisher 还必须证明 job 确实建立，不能把“run 记录存在”误当成 workflow 已进入执行。

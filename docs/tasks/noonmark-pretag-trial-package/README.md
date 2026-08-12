# noonmark-pretag-trial-package

- Task-ID：`noonmark-pretag-trial-package`
- 风险等级：P
- 状态：实施中

## 需求

Replication V2 在正式 tag／push 前必须先产生一份可安装的 Apple Development 签名 trial DMG，供当前指定用户完成双实体 Mac 验收与连续 72 小时 soak。trial 必须走与正式本机候选相同的真实 App、诊断、输入法、DMG 静态与 `dmg-validation` 动态门禁，但不得要求预先建立 tag、访问 GitHub release 环境、触发 hosted CI、push 或发布 Release。

本次完整 V2 重构不能复用已经为旧 schema 18 候选分配并实际打包过的 `0.2.7 (29)` 身份。新候选分配为 `0.3.0 (30)`；build 29 永久退役，不覆盖、不重签、不回收。

## 现状证据

- `release/VERSION` 当前指向 `0.2.7 (29)`，ledger 状态为 `candidate`；该身份由 commit `012aa8595db51d42d60f6c59515a6939acf98a32` 在 Replication V2 commit 前建立。
- `dist/Noonmark.dmg` 已存在一份 2026-08-11 生成的旧候选产物，SHA-256 为 `c8680ae9fe0e018594bf509e0f8b577cdffd644855938d66ac0f1ad384fb9e5a`。它不得被描述为 V2 trial。
- 在干净 V2 HEAD 上完成完整签名 App E2E、writer lease 与 `make check` 后，调用唯一发行入口会在任何打包副作用前报错：`release requires exact tag v0.2.7 on the candidate commit`。
- `scripts/release-private-dmg` 无参数入口在共同本机门禁前无条件执行 `scripts/verify-release-version-tag` 与 `scripts/verify-github-release-readiness`，因此无法表达“先本机 trial、后 tag”的已批准流程。

## 设计

`scripts/release-private-dmg` 保留默认的 tagged release-candidate 模式，并新增唯一显式参数 `--trial`：

1. 默认模式继续验证 exact annotated `v<marketing_version>` tag 与 GitHub release 环境，不改变 `scripts/push-release-tag` 或 hosted publisher 的任何规则。
2. `--trial` 先运行独立 `scripts/verify-release-trial-version`。验证器要求当前 `release/VERSION` 精确对应 ledger 中最后一条、最高 build 的 `candidate`，并要求本机不存在同名版本 tag；任一不满足即在 App／DMG 副作用前 fail-closed。
3. 两种模式随后共用同一条本机证据链：static preflight → same-run runtime evidence → diagnostic closure → Tencent IME release smoke／evidence → production identity 静态打包 → read-only DMG verify → 受控 `dmg-validation` 安装／退出／重启 → full evidence verifier。
4. trial 模式只跳过与 GitHub 发布本身有关的 tag 和 remote Environment readiness；它不增加低强度 package 捷径，也不允许直接调用 `scripts/package-dmg` 冒充已验证 trial。
5. trial DMG 以独立、不覆盖的 `Noonmark-0.3.0-build30.dmg` 名称复制到 Downloads。`dist/Noonmark.dmg` 只是受控构建输出，不作为历史候选登记。

## 影响范围与测试策略

- 版本身份：`release/VERSION`、`release/BUILD-LEDGER.tsv`、`docs/releases/v0.2.7.md`、新建 `docs/releases/v0.3.0.md`。
- 发行编排：`scripts/release-private-dmg`、新 trial version verifier、release version／gate contract。
- 永久门禁：fast gate 固定版本与 ledger；symptom gate 运行 trial verifier 的正反 fixture 并证明 tagged／trial 分流；release gate 必须在最终精确 commit 上真实执行 `--trial` 的完整 DMG 安装链。
- 回归点：默认无参数入口仍要求 tag 与 GitHub readiness；`make package-dmg`／`make release-private-dmg` 不自动进入 trial；production App 不执行；用户资料与 iCloud repository 不读取、不修改。

## 风险评估、回滚、灰度与监控

| 项目 | 处置 |
| --- | --- |
| 风险：trial 分支意外削弱正式发行 | 默认模式行为保持不变；contract 同时校验两条前置链汇合到完全相同的本机 package／install 门禁 |
| 风险：旧 build 被误当成 V2 | build 29 标 `retired`，0.3.0 build 30 成为唯一 current candidate；二进制、manifest、DMG 名称与 SHA 必须对账 |
| 风险：trial 被误称已发布 | 不建立 tag、不 push、不触发 hosted CI、不建立 GitHub Release；trial 输出明确标记 pre-tag |
| 回滚 | 任一门禁失败即停止交付 build 30并保留失败证据；不覆盖旧 DMG，不降级或改写资料，不恢复 V1；下一候选使用更大 build |
| 灰度 | 本机完整门禁 → 当前指定用户第一台 Mac → 第二台实体 Mac → 连续 72 小时 soak → 另行审核 tag／push／Release |
| 监控 | 只观察 confirmed／pending、最近同步、最近有效同步、typed incident、收敛耗时和用户主动导出的有界诊断；不记录正文、路径、账号、payload 或原始 Error |

## 完成条件

- 新增门禁先在旧实现上复现 `--trial` 无法进入流程，再在新实现上转绿。
- `0.3.0 (30)` 精确 commit 完成完整 `make check`、签名 App E2E、同 run writer lease、`scripts/release-private-dmg --trial` 与最终 evidence 对账。
- Downloads 中只创建全新、不覆盖的 trial DMG，并报告 SHA-256；不 tag、不 push、不发布。
- 双实体 Mac 与 72 小时 soak 尚未完成前，任务保持灰度中，不宣称 release ready。

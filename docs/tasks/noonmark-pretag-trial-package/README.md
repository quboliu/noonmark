# noonmark-pretag-trial-package

- Task-ID：`noonmark-pretag-trial-package`
- 风险等级：P
- 状态：build 30、31、32、33、34、35、36 已退役；当前 `0.3.1 (37)` 等待 review、push 精确 `main` 与 hosted CI 后完成本机 release 验证；双实体 Mac 与 72 小时 soak 待新 trial DMG 交付后执行

## 需求

Replication V2 在正式 tag 前必须先产生一份可安装的 Apple Development 签名 trial DMG，供当前指定用户完成双实体 Mac 验收与连续 72 小时 soak。按用户最新明确顺序，精确候选必须先 push 到 GitHub `main`，再开始私有出包；trial 必须走与正式本机候选相同的真实 App、诊断、输入法、DMG 静态与 `dmg-validation` 动态门禁，但不得预先建立或 push release tag、访问 GitHub release 环境或发布 Release。

本次完整 V2 重构不能复用已经为旧 schema 18 候选分配并实际打包过的 `0.2.7 (29)` 身份。build 30 因 runtime inventory 漂移退役，build 31 因后续同步修复改变源码身份退役。build 32 分配后又加入飞光 Markdown 修复，却因 trial verifier 没有绑定 candidate source 而错误复用身份，现已退役。用户指定营销版本为 `0.3.1`；build 33 因相邻 commit 历史检查缺口退役，build 34 因 shallow CI、历史 build 回退复用、首次同 build 绑定与 docs／empty follow-up commit 绕过退役，build 35 又因 identical-tree amend、未 push synthetic merge、identity 引入前历史 build 复用与普通 PR 假红边界退役。build 36 因 trial、tag、真实安装与 hosted publisher 没有共同强制 exact-SHA hosted CI、公开发布缺少最终 authority recheck，以及陈旧 PR 会被 current base 前进误判而退役。当前验证候选为 `0.3.1 (37)`；build 29 至 36 均不覆盖、不重签、不回收。

## 现状证据

- 首次取证时，`release/VERSION` 指向 `0.2.7 (29)`，ledger 状态为 `candidate`；该身份由 commit `012aa8595db51d42d60f6c59515a6939acf98a32` 在 Replication V2 commit 前建立。此条是历史证据，不描述当前候选。
- `dist/Noonmark.dmg` 已存在一份 2026-08-11 生成的旧候选产物，SHA-256 为 `c8680ae9fe0e018594bf509e0f8b577cdffd644855938d66ac0f1ad384fb9e5a`。它不得被描述为 V2 trial。
- 在干净 V2 HEAD 上完成完整签名 App E2E、writer lease 与 `make check` 后，调用唯一发行入口会在任何打包副作用前报错：`release requires exact tag v0.2.7 on the candidate commit`。
- `scripts/release-private-dmg` 无参数入口在共同本机门禁前无条件执行 `scripts/verify-release-version-tag` 与 `scripts/verify-github-release-readiness`，因此无法表达“先本机 trial、后 tag”的已批准流程。
- build 30 首次真实 trial preflight 还暴露了 Replication V2 E2E producer 与发行 verifier 的 inventory 漂移：真实 E2E 已产出 V2 lifecycle 截图与单一失败／禁用／重启轨迹，共享 inventory 却仍要求不再生成的 V1 remote-preferences、旧截图和独立 failure-restart 文件。E2E 成功 manifest 没有在结束前消费共享 inventory，因此错误延迟到发行 runtime verifier 才被发现。

## 设计

`scripts/release-private-dmg` 保留默认的 tagged release-candidate 模式，并新增唯一显式形式 `--trial <absolute-output-dmg>`：

1. 默认模式继续验证 exact annotated `v<marketing_version>` tag 与 GitHub release 环境，不改变 `scripts/push-release-tag` 或 hosted publisher 的任何规则。
2. `--trial <absolute-output-dmg>` 先运行独立 `scripts/verify-release-trial-version`。验证器要求当前 `release/VERSION` 精确对应 ledger 中最后一条、最高 build 的 `candidate`，并要求本机不存在同名版本 tag；任一不满足即在 App／DMG 副作用前 fail-closed。
   trial 与 tagged verifier 还必须共同调用 `scripts/verify-release-source-identity`，把 current version／build 对账到 tracked release source fingerprint；源码或发行脚本变化而版本不变时立即判红。首次 identity 必须大于引入前完整历史中的最高 build，后续 identity 必须严格高于全部历史 binding。
   两条发行入口共同调用 `scripts/verify-release-candidate-authority`；该共享深模块固定依序组合完整 source history、live `origin/main == HEAD` 与该 SHA 唯一首次成功的 GitHub-hosted CI push run，避免任一调用点漏掉其中一层。amended commit、PR synthetic merge、未 push follow-up、missing／divergent origin 或 CI 未完成／失败全部在 App／DMG 副作用前判红。真实 DMG 安装入口在 runtime profile setup 前重复同一审计；trial 最终复制与 hosted Release 创建前再次重验同一入口。
3. 两种模式随后共用同一条本机证据链：static preflight → same-run runtime evidence → diagnostic closure → Tencent IME release smoke／evidence → production identity 静态打包 → read-only DMG verify → 受控 `dmg-validation` 安装／退出／重启 → full evidence verifier。
4. trial 模式只跳过与 GitHub 发布本身有关的 tag 和 remote Environment readiness；它不增加低强度 package 捷径，也不允许直接调用 `scripts/package-dmg` 冒充已验证 trial。
5. trial DMG 只在精确候选已到达 `origin/main`、该 SHA 的 hosted CI 成功且全部本机门禁通过后，以独立、不覆盖的 `Noonmark-0.3.1-build37.dmg` 名称 exclusive-create 到显式 Downloads 目标。full verifier 前后的 package manifest SHA 必须不变；source、临时副本与 final output 都须匹配该 manifest 的 `dmg_sha256`。source／manifest、output parent 与 canonical basename 也须 fail-closed 校验；既有目标、symlink、manifest replacement 或 checksum 漂移不得覆盖。`dist/Noonmark.dmg` 只是受控构建输出，不作为历史候选登记。
6. `scripts/development-validation-e2e-inventory` 是 V2 E2E producer 与发行 verifier 的唯一 inventory authority。完整 E2E 在生成 artifact inventory 后、写入成功 manifest 前必须消费同一 authority 并逐项证明存在且已被 inventory 哈希绑定；partial E2E 不冒充完整发行证据。

## 影响范围与测试策略

- 版本身份：`release/VERSION`、`release/BUILD-LEDGER.tsv`、`release/CURRENT-BUILD-SOURCE`、`docs/releases/v0.3.0.md` 与 `docs/releases/v0.3.1.md`。
- 发行编排：`scripts/release-private-dmg`、新 trial version verifier、release version／gate contract。
- 永久门禁：fast gate 固定版本与 ledger，并以隔离 Git／bare origin fixture 覆盖历史 build、amend、synthetic merge、missing／divergent／exact remote、hosted CI 失败、发布前重验与陈旧 PR merge-base transition；symptom gate 运行 trial verifier、精确有序编排、package manifest authority 与 exclusive output 的正反 fixture；release gate 必须在最终精确 pushed commit 上真实执行 `--trial <absolute-output-dmg>` 的完整 DMG 安装与交付链。
- E2E 证据回归：fast gate 拒绝 V1 inventory 名称回流并要求 producer 消费共享 authority；symptom gate 必须让真实完整 E2E 自己对缺项判红；release runtime verifier 对同一 inventory 与 SHA 再次独立对账。
- 回归点：默认无参数入口仍要求 tag 与 GitHub readiness；`make package-dmg`／`make release-private-dmg` 不自动进入 trial；production App 不执行；用户资料与 iCloud repository 不读取、不修改。

## 风险评估、回滚、灰度与监控

| 项目 | 处置 |
| --- | --- |
| 风险：trial 分支意外削弱正式发行 | 默认模式行为保持不变；contract 同时校验两条前置链汇合到完全相同的本机 package／install 门禁 |
| 风险：旧 build 被误当成当前 V2 | build 29 至 36 标 `retired`，0.3.1 build 37 成为唯一 current candidate；完整 identity 历史、live `origin/main == HEAD`、exact-SHA hosted CI、source fingerprint、二进制、manifest、DMG 名称与 SHA 必须对账 |
| 风险：普通 PR 被误当成发行候选 | 通用 `scripts/check` 只运行隔离 fixtures；hosted CI checkout PR head，仅在 identity 相对 PR 与 current base 的唯一 merge-base／push first parent 改变时审计真实 transition |
| 风险：trial 被误称已发布 | 只按授权 push 精确 `main`；不建立或 push release tag、不建立 GitHub Release，trial 输出明确标记 pre-tag |
| 风险：producer／verifier inventory 再次漂移 | 两者共享唯一函数；完整 E2E 在成功 manifest 前先验证，发行 verifier再独立复核同一份哈希 inventory |
| 回滚 | 任一门禁失败即停止交付当前 build 并保留失败证据；不覆盖旧 DMG，不降级或改写资料，不恢复 V1；下一候选使用更大 build |
| 灰度 | 本机完整门禁 → 当前指定用户第一台 Mac → 第二台实体 Mac → 连续 72 小时 soak → 另行审核 tag／push／Release |
| 监控 | 只观察 confirmed／pending、最近同步、最近有效同步、typed incident、收敛耗时和用户主动导出的有界诊断；不记录正文、路径、账号、payload 或原始 Error |

## 完成条件

- 新增门禁先在旧实现上复现 `--trial` 无法进入流程，再在新实现上转绿。
- `0.3.1 (37)` 先完成完整 `make check`、签名 App E2E、同 run writer lease 与双轴 review，再把精确 commit push 到 `origin/main` 并等待 hosted CI；只有随后才运行 `scripts/release-private-dmg --trial <absolute-output-dmg>` 与最终 evidence 对账。
- Downloads 中只创建全新、不覆盖的 trial DMG，并报告 SHA-256；不建立或 push release tag，不发布 GitHub Release。
- 双实体 Mac 与 72 小时 soak 尚未完成前，任务保持灰度中，不宣称 release ready。

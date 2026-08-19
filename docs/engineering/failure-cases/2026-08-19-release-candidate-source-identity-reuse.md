# FAIL-2026-08-19-02：源码变化后私有包复用旧发行身份

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-19T13:17:59Z
- 影响版本／构建：`0.3.0 (32)`；错误 trial source commit `d22df46799caf2d6dcdb687b971bcd7af229cbd9`
- 引入提交：`7fb9024a96dd3a65c8e4ff980a31e4d7eeb9b85c`（`fix(markdown): preserve authored line breaks`）改变候选源码时没有同步分配新发行身份
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：Codex（本次 agent session；可由对话、Git worktree 与本机发行 evidence 确认）
- 修复提交：待回填

## 用户症状与影响

用户收到飞光 Markdown 修复后的新私有 DMG，却发现 App 版本仍显示 `0.3.0 (32)`。build 32 已在修复前的源码上分配；新二进制继续使用相同营销版本与 build，无法仅凭版本身份区分两份不同源码，也违反每个私有候选使用全新递增 build 的发行规则。该包没有发布为 GitHub Release，但不得继续分发。

## 时间线

- 2026-08-12：commit `1eb9837c5f74728d04be61af559b4a62e6b12593` 分配 `0.3.0 (32)` trial candidate。
- 2026-08-19T05:40:33-04:00：飞光 Markdown 根因修复改变 App 源码，但 `release/VERSION` 与 ledger 保持 build 32。
- 2026-08-19：在 source `d22df46799caf2d6dcdb687b971bcd7af229cbd9` 完成一次本机 trial；既有 verifier 只确认 build 32 是 ledger tip，因此错误放行。
- 2026-08-19T13:17:59Z：用户指出新包版本没有更新，发行身份复用被确认。
- 2026-08-19：新增 source-mutation fixture；旧 verifier 真实报出 `trial verifier accepted changed source under the same version and build`，稳定判红。
- 2026-08-19：首版修复绑定 source identity，并把营销版本提升为用户指定的 `0.3.1`、分配 build 33。
- 2026-08-19：双轴 review 证明首版历史检查只比较 `HEAD^..HEAD`；同 build 非法重新绑定之后追加无关文档 commit 会令 verifier 遗忘违规。隔离 Git fixture 复现后，build 33 退役，候选提升为 `0.3.1 (34)`。
- 2026-08-19：第二轮双轴 review 以运行 fixture 证明 build 34 仍可被 shallow hosted CI、首次同 build introduction、历史 build 回退再恢复及 docs／empty follow-up commit 绕过；真实安装 gate 也只证明 package 内部自洽，未消费 build allocation 历史。build 34 退役，验证候选提升为 `0.3.1 (35)`。
- 2026-08-19：第三轮双轴 review 证明 identical-tree amend 会改变 App 内嵌 commit 却被本地 exact-HEAD 推断接受，GitHub PR synthetic merge 也可被 first-parent 推断接受；与此同时，把真实 verifier 与 fingerprint 相等检查放进通用 `scripts/check` 会令普通 follow-up PR 无法通过。另一个历史 fixture 证明 identity 引入前先出现 build 35、回退至 34、再首次绑定 35 仍会被直接-parent 比较接受。build 35 退役，验证候选提升为 `0.3.1 (36)`。
- 2026-08-19：第四轮双轴 review 证明 build 36 的 trial、tag 与真实安装只要求 live `origin/main`，没有机器消费该 SHA 的 GitHub-hosted CI 成功事实；hosted publisher 也未调用 source／live remote verifier，且 package 完成后至最终复制／公开 Release 创建之间仍有 authority TOCTOU。陈旧普通 PR 还会直接比较后来前进的 current base 而被假判 identity change。三个运行／结构 contract 先分别判红，build 36 退役，验证候选提升为 `0.3.1 (37)`。
- 2026-08-19：完整 `make check` 在最后的 GitHub release readiness contract 判红。`05e543f725b5de1b1977edf711dede1e4cd52dac` 已把 workflow 与 tag publisher 收敛到共享 `verify-release-candidate-authority`，但同一提交遗漏更新 readiness contract 中两组旧 direct hosted-CI 顺序断言；`require_order` 又因 `set -euo pipefail` 在缺项时静默退出，最初只暴露总入口 exit 2。目标 gate 先稳定复现 exit 1，再修正共享 seam 断言与明确诊断。

## 复现与证据

- `release/VERSION` 在错误 trial 时仍为 `marketing_version=0.3.0`、`build_number=32`，ledger 的 build 32 仍为 `candidate`。
- 错误 trial 的 package evidence 绑定 source commit `d22df46799caf2d6dcdb687b971bcd7af229cbd9`，证明不是旧二进制或旧文件名残留；其 `Info.plist` 与 canonical 输出名同样写入 `0.3.0 (32)`。
- `scripts/test-release-trial-contract` 的隔离 Git fixture 在固定 VERSION／ledger 后提交一次 tracked source 变化；旧 `scripts/verify-release-trial-version` 仍退出 0，测试因此判红。
- 第二轮 fixture 在相同 build 下更新 fingerprint 后证明首版修复会拒绝当下的非法重新绑定；但再追加无关文档 commit 后 verifier 错误恢复退出 0，证明问题不是 clean tree 或 fingerprint 范围，而是历史观察窗口过短。
- shallow fixture 只 fetch candidate `HEAD`，旧 verifier 因看不到 parent 而跳过历史比较；source 与 trial verifier 均错误退出 0。hosted `ci.yml` 当时正使用默认 depth 1。
- rollback fixture 依次提交 build 34／source A、build 33 回退、build 34／source B 恢复；旧 verifier 只见最后一步 `34 > 33`，最终错误接受已经用过的 build 34。
- docs fixture 证明旧 fingerprint 排除 `docs/*`，但 App 会把变化后的 `HEAD` 写入 `NoonmarkGitCommit`；docs-only 与 empty follow-up commit 均可在同 build 下产生不同 package identity。
- identical-tree fixture 把 bound commit `a1f49030a4580ae3a1505184b0c7a601ab515129` 只 amend message 为另一 SHA；tree 与 fingerprint 完全相同，本地 source verifier 仍退出 0。synthetic fixture 再以旧 main 为 first parent、bound candidate 为 second parent 建立未 push merge，本地 verifier 同样退出 0；两者都被新增 live remote verifier 拒绝。
- preidentity-history fixture 先在没有 identity 时提交高 build，再回退一个 build，最后用原高 build 首次绑定；旧 verifier 只和直接 parent 比较而错误退出 0。修复后首次 binding 必须严格大于 identity 引入前完整 first-parent 历史中的最高 `release/VERSION` build。
- CI 结构证据确认 `pull_request` 默认 checkout synthetic merge；通用 `scripts/check` 的真实 fingerprint／exact-HEAD 对账会把没有发行意图的普通 source PR 判红。修复后 hosted CI checkout PR head，只有 identity 相对 PR 与 current base 的唯一 merge-base 或 push first parent 发生变化时才调用真实 source transition verifier；普通 PR 继续运行全部隔离回归 fixture，但不冒充发行候选。
- hosted CI failure fixture 把 exact pushed HEAD 的 CI verdict 固定为失败，旧 trial verifier 仍退出 0；trial 编排 trace 也证明 full evidence verifier 结束后会直接调用 publisher，没有再次验证候选 authority。
- stale PR fixture 从旧 base 建立只修改普通 source 的分支，再让 current base 独立修改 release identity；旧 transition verifier 直接比较 current base 与 PR head，多调用一次 source audit 并判红，证明比较点不是 PR 自己引入的变化。
- `scripts/test-release-version-contract` 的 workflow wiring 断言在旧实现上先报 `tag verifier does not require successful hosted CI`；逐层补齐后继续暴露真实 `test-dmg-install` 与 hosted publisher 缺少相同 authority，以及 package 后发布前没有 remote／CI recheck。
- `scripts/test-github-release-readiness-contract` 在 `05e543f725b5de1b1977edf711dede1e4cd52dac` 后真实退出 1；`bash -x` 定位到它仍查找已删除的 `name: Verify prior GitHub-hosted CI`，而 `push-release-tag` 的旧断言仍查找已经封装进共享 authority 的 direct `verify-github-hosted-ci`。修正第一项后，改良的诊断立即精确报出第二项，证明不是 GitHub secret、tag policy、Release notes 语言或 workflow 签名步骤本身失败。
- 旧 `scripts/test-dmg-install` 只对账 installed App、package manifest 与 current VERSION；错误 build 32 的这些字段本来就彼此一致，因此不能单独证明该 build 未属于另一份 source。
- 复现不启动 production App，不读取 production 资料，也不接触 iCloud。

## 排除的假设

- 不是 Finder 缓存或 About 界面缓存：DMG、App `Info.plist`、manifest 与文件名一致地使用旧身份。
- 不是只漏改营销版本：build 32 也已被先前源码占用，单独改成 `0.3.1 (32)` 仍会复用 build。
- 不是 GitHub push 延迟：远端 commit 与本机 package source 已一致，错误位于发行身份治理。
- 不是 exclusive-create 失效：publisher 没有覆盖同一目标文件，但不同目录仍可生成同 identity 的不同二进制。

## 根因与破坏机制

最初的 `scripts/verify-release-trial-version` 只证明 `release/VERSION` 指向 ledger 最后一条最高 `candidate`，并检查同名 tag 不存在。前两版 source identity 先只比较最近 identity commit 与直接 parent，后虽扫描完整 first-parent 历史，仍以 identity blob transition 推断 exact commit；Git commit message amend 与未 push synthetic merge 不改变 tree／fingerprint，无法由这种自包含推断区别。首次 binding 也只高于直接 parent，没有高于 identity 引入前完整历史的最高 build。另一方面，把发行专用的当前 fingerprint 与 exact-HEAD 断言放入通用 check，混淆了普通开发 commit 与已分配候选；PR transition 又错误使用会随时间前进的 current base，而不是 PR 分叉的 merge-base。package／install manifest 能证明“这次打了什么”与内部版本一致，live remote 只能证明“当前已推送”，二者都不能独立证明该 SHA 的 hosted CI 已成功；这些 authority 没有组合成 trial、tag、真实安装与 hosted publisher 的共同前置条件，最终复制／公开发布前也没有重验，因此留下 TOCTOU。

## 根因修复

- 新增 `release/CURRENT-BUILD-SOURCE`，把 current marketing version、build 与 tracked release source fingerprint 绑定。
- fingerprint 使用 Git index 的 mode、blob OID、stage 与路径，覆盖除 identity 自身外的全部 tracked 输入，包括叙述文档、机器消费的 gate registry 与 workflow；只排除 identity 文件自身以避免自引用。
- 新增共享 `scripts/verify-release-source-identity`，由 trial 与 tagged verifier 在任何 App／DMG 副作用前共同调用。它要求非 shallow repository，并逐个审计完整 first-parent commit tree 的 identity blob transition：首次绑定必须高于 identity 引入前所有历史 VERSION build，后续每次绑定必须高于所有历史 identity build，移除／重新引入与回退复用都 fail-closed；clean committed candidate 的最后 identity transition 必须精确等于 `HEAD`。
- 新增共享 `scripts/verify-origin-main-candidate`，每次用 `git ls-remote --exit-code --heads origin refs/heads/main` 读取唯一 live ref，并要求其精确等于本机 `HEAD`。trial、tagged、真实 install 与 tag publisher 全部消费同一 authority；missing／divergent remote、identical-tree amend、未 push follow-up 与 PR synthetic merge 都在发行副作用前 fail-closed。
- 通用 `scripts/check` 不再对真实工作树强制 current fingerprint 相等或 exact-HEAD source verifier，只保留隔离 fixture。hosted `ci.yml` 固定 full history 并 checkout `pull_request.head.sha`；`scripts/verify-release-source-transition` 对 PR 先求 current base 与精确 PR head 的唯一 merge-base，只在 identity 相对该 merge-base 或 push first parent 发生变化时审计真实 candidate transition。无共同祖先或多 merge-base fail-closed，普通陈旧 PR 不因 base 前进消费 build。
- 新增 `scripts/verify-release-candidate-authority <commit>` 作为唯一组合边界：先要求参数精确等于 `HEAD`，再依序执行完整 source history、live remote 与 exact-SHA hosted CI 三项审计。trial、tagged verifier、真实 `scripts/test-dmg-install`、tag publisher 和 hosted workflow 全部消费这个共享入口，避免调用点再次漏掉某一层。
- readiness contract 同步验证统一 seam：workflow 必须在导入签名身份前运行 `Verify release candidate authority`；tag publisher 必须保持 `release readiness → candidate authority → git push → publication verification` 的严格顺序。`require_order` 对缺失匹配显式归一为空值再进入统一 `fail`，不再被 shell strict mode 抢先静默终止。
- `scripts/release-private-dmg` 在 full evidence 和 package manifest SHA 对账后、调用 trial publisher 前重新执行整个 trial verifier。tag-triggered hosted workflow 在 package 前执行共享 candidate authority，并在 `gh release create` 前再次执行同一入口，阻断 package 期间的远端或 CI 漂移。
- build 32、33、34、35、36、37、38 与 39 标为 `retired`；按用户决定保持营销版本 `0.3.1`，建立 build 40 validation candidate。既有错误 trial 保留作证据但禁止分发，不覆盖、不重签；build 37 捕获 bootstrap staging 竞态，build 38 绑定同机修复后因案例闭环退役，build 39 又因 review 捕获跨 Mac authority、timing test 与 non-local version 缺口而退役，三者都没有 push 或打包。

## 验证结果

- Red：source-mutation fixture 在旧 verifier 上失败，精确证明相同版本／build 放行变化源码。
- Red：同 build 重新绑定后的即时检查判红，但追加无关文档 commit 后首版 verifier 错误转绿，精确证明相邻 commit 检查会遗忘违规历史。
- Red：新增 shallow、首次同 build introduction、exact HEAD、tracked docs fingerprint 与历史 build rollback／reuse fixture；旧实现分别报出接受浅历史、忽略 tracked docs 与复用旧 build。第三轮又由 `scripts/test-release-origin-main-contract` 先判红为缺少 live remote verifier，preidentity-history fixture 判红为旧 verifier 接受 identity 前历史 build 复用；review 的 identical-tree amend 与 synthetic merge 运行 fixture 均证明本地推断单独不足。
- Red：第四轮 `scripts/test-release-trial-contract` 先证明编排缺少复制前重验，再证明 CI verdict 为失败时旧 trial verifier 仍放行；`scripts/test-release-source-transition-contract` 证明 current base 前进会让陈旧普通 PR 错误触发 source audit；`scripts/test-release-version-contract` 依次暴露 tag、真实 install 与 hosted publisher 缺少 exact-SHA CI／source／remote authority。
- Green（fast）：`scripts/test-release-trial-contract` 已覆盖完整历史、preidentity maximum、amend／synthetic remote mismatch、hosted CI failure、最终复制前重验与更大 build；`scripts/test-release-origin-main-contract` 覆盖 exact、amended、follow-up、synthetic 与 missing origin；`scripts/test-release-source-transition-contract` 覆盖普通 PR／push 跳过、陈旧 PR merge-base 与 identity transition 强制审计；`scripts/test-release-version-contract` 固定共享 candidate authority，以及 trial、tag、真实 install、tag publisher 和 hosted workflow 的统一消费与发布前重验；`scripts/test-github-hosted-workflow-boundary` 固定 hosted workflow 通过共享入口消费 exact CI，五者均已退出 0。其余 fast 与真实 `dmg-validation` 安装路径待 build 40 clean commit 完成后回填，在此之前案例保持处理中。
- Green（fast，补充）：修正后的 `scripts/test-github-release-readiness-contract` 退出 0，继续覆盖 exact Environment secrets／tag policy、英文 Release notes、签名凭证清理、共享 candidate authority 顺序、tag push 与 publication verification 边界；完整 `make check` 与真实发行路径仍待重新运行，因此案例保持处理中。
- 真实发行仍必须在精确 pushed clean commit 上完成同一 evidence run 的 `make check`、完整签名 App E2E、writer lease 与 `0.3.1 (40)` validation package；这些是交付门禁，不以静态 contract 结果替代。

## 永久门禁

- fast：`scripts/test-release-version-contract` 固定 VERSION／ledger 结构、共享 candidate authority 内部顺序、PR-head conditional transition，以及 trial／tag／真实 install／tag publisher／hosted workflow 的统一消费与发布前重验；`scripts/test-github-release-readiness-contract` 固定 workflow 与 tag publisher 只通过共享 candidate authority 消费 hosted CI，并保持签名、push 与 publication verification 的顺序；`scripts/test-release-trial-contract` 在隔离 Git fixture 证明 shallow、首次及 identity 前历史 build 复用、历史 binding 回退复用、docs／empty follow-up、source mutation、amend、synthetic merge 与 hosted CI failure 全部判红，只有更大 build 的 exact pushed、CI-success HEAD 可转绿；`scripts/test-release-origin-main-contract` 与 `scripts/test-release-source-transition-contract` 分别固定 live remote authority 和 merge-base PR 边界。全部由 `scripts/check` 强制执行。
- symptom：`scripts/test-dmg-install` 先用完整历史证明该 build 从未绑定另一 source，再以 live remote 证明当前精确 commit 已到达 `origin/main`，并消费该 SHA 的成功 hosted CI，随后对精确 DMG 受控派生并签名为 `dmg-validation`；真实安装后读取 App identity，要求营销版本与 build 都等于 current binding。该入口由 `scripts/release-private-dmg` 强制执行。
- release：同一 `scripts/test-dmg-install` 继续走真实交互、退出、重启、持久化与诊断闭环，并在诊断 identity 中对账版本／build／commit；私有 publisher 在最终复制前重验完整 trial authority，hosted publisher 在 package 前与 `gh release create` 前重验 source、remote 和 CI，只有该复合门禁全绿才可暴露产物。

## 发行与回滚

风险等级为 P。`0.3.0 (32)` 与 `0.3.1 (33)`、`(34)`、`(35)`、`(36)`、`(37)`、`(38)`、`(39)` 已退役，不删除现有文件但禁止分发。`0.3.1 (40)` 只有在 full-history source binding、live `origin/main == HEAD`、exact-SHA hosted CI、完整 `make check`、真实签名 App E2E、writer lease、DMG 静态门禁与受控 `dmg-validation` 全绿后才可作为修复验证依据。任一失败即停止候选并使用更大 build；不覆盖旧 DMG，不建立或移动 tag，不操作 production 资料或 iCloud 对象。灰度仍为第一台 Mac、第二台实体 Mac 与连续 72 小时 soak；监控只使用 hosted CI、版本／commit／SHA evidence、typed state 与用户主动导出的有界诊断。

## 教训与永久约束

“ledger tip 正确”不等于“candidate source 未变化”，package 内部自洽也不等于本机 commit 已获远端和 hosted CI 授权。Git tree／fingerprint 不能辨别 identical-tree amend，first-parent transition 也不能单独辨别 PR synthetic merge；发行身份必须在打包副作用前同时绑定完整历史、严格递增 build、全部 tracked 输入、live `origin/main` 精确 commit 与 exact-SHA hosted CI，并在最终暴露产物前重验。通用开发检查与发行授权必须分层：普通 PR 只按 merge-base 审计自身变化、不消费 build，但任何实际 package 都必须使用全新 build 的 exact pushed、CI-success HEAD。exclusive output 只能防覆盖，不能替代这三层 authority。

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

## 复现与证据

- `release/VERSION` 在错误 trial 时仍为 `marketing_version=0.3.0`、`build_number=32`，ledger 的 build 32 仍为 `candidate`。
- 错误 trial 的 package evidence 绑定 source commit `d22df46799caf2d6dcdb687b971bcd7af229cbd9`，证明不是旧二进制或旧文件名残留；其 `Info.plist` 与 canonical 输出名同样写入 `0.3.0 (32)`。
- `scripts/test-release-trial-contract` 的隔离 Git fixture 在固定 VERSION／ledger 后提交一次 tracked source 变化；旧 `scripts/verify-release-trial-version` 仍退出 0，测试因此判红。
- 第二轮 fixture 在相同 build 下更新 fingerprint 后证明首版修复会拒绝当下的非法重新绑定；但再追加无关文档 commit 后 verifier 错误恢复退出 0，证明问题不是 clean tree 或 fingerprint 范围，而是历史观察窗口过短。
- shallow fixture 只 fetch candidate `HEAD`，旧 verifier 因看不到 parent 而跳过历史比较；source 与 trial verifier 均错误退出 0。hosted `ci.yml` 当时正使用默认 depth 1。
- rollback fixture 依次提交 build 34／source A、build 33 回退、build 34／source B 恢复；旧 verifier 只见最后一步 `34 > 33`，最终错误接受已经用过的 build 34。
- docs fixture 证明旧 fingerprint 排除 `docs/*`，但 App 会把变化后的 `HEAD` 写入 `NoonmarkGitCommit`；docs-only 与 empty follow-up commit 均可在同 build 下产生不同 package identity。
- 旧 `scripts/test-dmg-install` 只对账 installed App、package manifest 与 current VERSION；错误 build 32 的这些字段本来就彼此一致，因此不能单独证明该 build 未属于另一份 source。
- 复现不启动 production App，不读取 production 资料，也不接触 iCloud。

## 排除的假设

- 不是 Finder 缓存或 About 界面缓存：DMG、App `Info.plist`、manifest 与文件名一致地使用旧身份。
- 不是只漏改营销版本：build 32 也已被先前源码占用，单独改成 `0.3.1 (32)` 仍会复用 build。
- 不是 GitHub push 延迟：远端 commit 与本机 package source 已一致，错误位于发行身份治理。
- 不是 exclusive-create 失效：publisher 没有覆盖同一目标文件，但不同目录仍可生成同 identity 的不同二进制。

## 根因与破坏机制

最初的 `scripts/verify-release-trial-version` 只证明 `release/VERSION` 指向 ledger 最后一条最高 `candidate`，并检查同名 tag 不存在。首版 source identity 又只比较最近 identity commit 与直接 parent，缺少完整历史的单调 build 不变量，也在历史缺失时 fail-open；fingerprint 排除所有 docs，却忽略 App 内嵌的 `HEAD` 仍会改变。package／install manifest 能证明“这次打了什么”与内部版本一致，却不能独立证明“这个 build 是否已属于另一份源码”。

## 根因修复

- 新增 `release/CURRENT-BUILD-SOURCE`，把 current marketing version、build 与 tracked release source fingerprint 绑定。
- fingerprint 使用 Git index 的 mode、blob OID、stage 与路径，覆盖除 identity 自身外的全部 tracked 输入，包括叙述文档、机器消费的 gate registry 与 workflow；只排除 identity 文件自身以避免自引用。
- 新增共享 `scripts/verify-release-source-identity`，由 trial 与 tagged verifier 在任何 App／DMG 副作用前共同调用。
- verifier 要求非 shallow repository，并逐个审计完整 first-parent commit tree 的 identity blob transition：首次绑定必须高于 parent VERSION，后续每次绑定必须高于所有历史 binding，移除／重新引入与回退复用都 fail-closed；未提交新 binding 可用于开发检查，但 clean committed candidate 的最后 identity commit 必须精确等于 `HEAD`。
- hosted `ci.yml` 固定 `fetch-depth: 0`；真实 `scripts/test-dmg-install` 在任何 runtime profile setup 前消费同一 source identity verifier，再继续安装 App 的版本／build／commit 与诊断闭环。
- build 32、33 与 34 标为 `retired`；按用户决定保持营销版本 `0.3.1`，建立 build 35 validation candidate。既有错误 trial 保留作证据但禁止分发，不覆盖、不重签。

## 验证结果

- Red：source-mutation fixture 在旧 verifier 上失败，精确证明相同版本／build 放行变化源码。
- Red：同 build 重新绑定后的即时检查判红，但追加无关文档 commit 后首版 verifier 错误转绿，精确证明相邻 commit 检查会遗忘违规历史。
- Red：新增 shallow、首次同 build introduction、exact HEAD、tracked docs fingerprint 与历史 build rollback／reuse fixture；旧实现分别报出接受浅历史、忽略 tracked docs 与复用旧 build。静态 contract 还证明 hosted CI 缺少 full-history checkout、真实 DMG install gate 未调用 source audit。
- Green（fast）：完整历史 verifier 实现后，`scripts/test-release-trial-contract` 已覆盖上述全部反例并退出 0；其余 fast 与真实 `dmg-validation` 安装路径待 build 35 clean commit 完成后回填，在此之前案例保持处理中。
- 真实发行仍必须在精确 pushed clean commit 上完成同一 evidence run 的 `make check`、完整签名 App E2E、writer lease 与 `0.3.1 (35)` validation package；这些是交付门禁，不以静态 contract 结果替代。

## 永久门禁

- fast：`scripts/test-release-version-contract` 对账 VERSION、ledger、CURRENT-BUILD-SOURCE、full-history CI 与真实 install gate wiring；`scripts/test-release-trial-contract` 在隔离 Git fixture 证明 shallow、首次同 build binding、历史回退复用、docs／empty follow-up 与 source mutation 全部判红，只有更大 build 的 exact HEAD 可转绿；两者均由 `scripts/check` 强制执行。
- symptom：`scripts/test-dmg-install` 先用完整历史证明该 build 从未绑定另一 source，再对精确 DMG 受控派生并签名为 `dmg-validation`，真实安装后读取 App identity，要求营销版本与 build 都等于 current binding；由 `scripts/release-private-dmg` 强制执行。
- release：同一 `scripts/test-dmg-install` 继续走真实交互、退出、重启、持久化与诊断闭环，并在诊断 identity 中对账版本／build／commit；最终 publisher 只能在该复合门禁全绿后暴露 canonical trial output。

## 发行与回滚

风险等级为 P。`0.3.0 (32)` 与 `0.3.1 (33)`、`(34)` 已退役，不删除现有文件但禁止分发。`0.3.1 (35)` 只有在 full-history exact-HEAD binding、完整 `make check`、真实签名 App E2E、writer lease、DMG 静态门禁与受控 `dmg-validation` 全绿后才可作为修复验证依据。任一失败即停止候选并使用更大 build；不覆盖旧 DMG，不建立或移动 tag，不操作 production 资料或 iCloud 对象。灰度仍为第一台 Mac、第二台实体 Mac 与连续 72 小时 soak；监控只使用 CI、版本／commit／SHA evidence、typed state 与用户主动导出的有界诊断。

## 教训与永久约束

“ledger tip 正确”不等于“candidate source 未变化”，package 内部自洽也不等于 build 从未被另一 source 使用。发行身份必须在打包副作用前同时绑定完整历史、精确 `HEAD`、严格递增 build 与全部 tracked 输入；exclusive output 只能防覆盖，不能防同 identity 的第二份不同二进制。任何源码、资源、文档、版本资料、门禁或 follow-up commit 变化都必须迫使下一候选使用全新发行身份。

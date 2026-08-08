# FAIL-2026-08-07-14：GitHub Release notes 错误发布为中文

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T20:32:00Z 至用户报告时间
- 影响版本／构建：v0.2.4 build 21，source commit `a1a06490053245ec3b6d678709b9c2bbdf24d4b2`
- 引入提交：`d10a9b2e4f53aedb7da57437d42cfc3dbf95b159`（`ci(release): publish tag-triggered GitHub Releases from the self-hosted runner`）
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

公开 v0.2.4 GitHub Release 的三条用户变化为中文，而项目的公开仓库首页、commit message 与外部介绍以英文为主。DMG、checksum、签名与 tag 身份正确；问题只影响公开发行信息的语言一致性与可读性。

## 时间线

- 2026-08-06：workflow 加入从内部中文版 `docs/releases/vX.Y.Z.md` 的「用户可见变化」段落抽取 Release notes 的逻辑。
- 2026-08-07T19:57:31Z：v0.2.4 Release 成功发布，正文继承三条中文变化。
- 2026-08-07：用户明确要求删除误导性的 `v1.0` tag、把 Release 发布信息改为英文，并补充 GitHub 项目简介。

## 复现与证据

GitHub API 回读 v0.2.4 Release body，确认三条变化包含 Han 字符；源码 `release-publish.yml` 明确匹配 `## 用户可见变化` 并原样写入 `RELEASE_NOTES.md`。仓库 commit message 强制使用英文，但 GitHub 原生 generated notes 对当前直接提交历史只产生 Full Changelog，没有摘要，因此不能单独满足简要发行信息需求。

## 排除的假设

- 不是 GitHub 自动翻译：正文与内部中文发行文档逐条一致，来源是 workflow 的显式 awk 抽取。
- 不是 Release 标题或资产错误：标题为 `Noonmark 0.2.4 (21)`，DMG 与 checksum 各一份且 digest 正确。
- 不是 GitHub 原生 generated notes 足以替代：对 v0.2.4 的真实 API 结果只有 Full Changelog。

## 根因与破坏机制

内部发行记录按项目规则使用新加坡中文，公开 GitHub Release 却直接复用这份内部文档，没有独立的外部语言边界，也没有发布后正文语言验证。只手工编辑当前 Release 会在下一版由同一 workflow 复发。

## 根因修复

新增 release notes generator，从上一个稳定 semver tag 到当前 tag 的英文 conventional commits 中提取 `feat`／`fix`／`perf`，过滤 CI、release、test、docs、e2e 等非用户作用域，生成简短英文变更、Full Changelog 与英文 provenance。新增独立语言 verifier，以固定 Han scalar 范围同时校验生成文件和真实 GitHub Release；publication verifier 将其纳入正式发行闭环。内部发行记录继续保持新加坡中文。

## 验证结果

- Red（真实 symptom）：v0.2.4 API body 含三条中文用户变化。
- Red（fast）：新 readiness contract 在旧实现上报告缺少英文 notes generator。
- Green（verifier self-test）：完整英文正文通过，含 Han 正文与缺失 provenance 正文均失败。
- 待 Green（fast）：英文 generator、过滤结果、workflow 调用顺序与 failure-case registry 必须全部通过。
- 待 Green（symptom）：编辑后的真实 v0.2.4 Release 必须通过 live language verifier，且资产 digest 不变。

## 永久门禁

- fast：`scripts/test-github-release-readiness-contract`，由 `scripts/check` 强制调用；验证 generator、语言 self-test、workflow 英文来源和过滤结果。
- symptom：`scripts/verify-github-release-language`，由 `scripts/verify-github-release-publication` 强制调用；回读真实 Release 标题与正文。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；英文正文与唯一 DMG／checksum 未同时成立时不得报告发布成功。

## 发行与回滚

当前 v0.2.4 只编辑正文，不替换 tag 或资产。若英文摘要有事实错误，可恢复 API 回读保存的旧正文；workflow 修复可普通 revert，但不得恢复直接抽取中文内部文档的路径。下一版通过正常 tag 灰度，监控 generator 输出、Han verifier 与真实 Release body。

## 教训与永久约束

内部发行记录语言与公开发行渠道语言是两个明确边界；两者不可通过原样抽取偶然耦合。自动摘要必须先用真实仓库历史验证信息量，再决定使用 GitHub generated notes 或 conventional commit 投影。

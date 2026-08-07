# FAIL-2026-08-07-10：GitHub CI 与本地全集自测边界混同

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-07T17:13:00Z
- 影响版本／构建：v0.2.4 build 17，source commit `92c92fdc0415ff3780cb1e9fc0812122bb0908e7`
- 引入提交：`d0c3f5285812d12d0b95b02788c230496cf73541`（`fix(ui): Close the loop on the Mac native release review`）把 main E2E 改为 GitHub `self-hosted` runner；后续提交又把腾讯输入法与发行 evidence 持续挂到该 job
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`1c4d48fbb6ab2326f7f76697120609f3beddf18a`（`fix(ci): separate hosted release from local self-tests`）

## 用户症状与影响

用户明确本地在 push 前已跑全集，GitHub 只应运行 GitHub-hosted 环境能完成的子集。但普通 `ci.yml` 在 hosted `scripts/check` 后仍调度用户 Mac 的 self-hosted E2E，tag publisher 同时强制消费本地 E2E、腾讯输入法与 DMG evidence。这令本地自测与线上 CI 不再是两套清晰门禁，也在 push 后重复已完成的本地长链。

## 时间线

- 2026-07-15：main E2E job 改为持久 self-hosted Mac，开始把 GitHub 编排与本地交互能力绑定。
- 2026-08-02：腾讯输入法 release smoke 加入同一 self-hosted job。
- 2026-08-07：build 17 的 hosted check 运行时，用户指出 push 前本地全集已运行，不允许 GitHub 再调度本机。
- 2026-08-07T17:14:41Z：run `31199688018` 被主动取消；self-hosted job 虽已建立，但零 step 执行，本机 App 与资料未被触碰。

## 复现与证据

source commit `92c92fdc` 的 `.github/workflows/ci.yml` 明确声明 `runs-on: [self-hosted, macOS, noonmark-ui-e2e]`，并在 hosted check 后运行 writer lease、完整 App E2E 和腾讯输入法 smoke。`scripts/push-release-tag` 同时读取 `artifacts/e2e-runtime` 与 writer-lease manifest，把本地 evidence 设为 tag 副作用的机器前置。GitHub run `31199688018` 最终记录两个 job：hosted check 与 `Mac App E2E · Interactive WindowServer`；后者因及时取消没有执行任何 step。

## 排除的假设

- 不是 GitHub-hosted 无法运行全集时必须 self-hosted 补齐；用户要求的边界是 GitHub 只跑子集，本地全集是 push 前独立自测。
- 不是应删除真实 E2E 与腾讯输入测试能力；这些脚本仍保留为本地全集入口。
- 不是 tag workflow 应重跑 main CI 子集；精确 commit 的 main hosted CI 已有结果，tag workflow 只需 fail-closed 消费该远程结果。

## 根因与破坏机制

仓库把「覆盖用户真实路径」误等于「所有路径必须由 GitHub Actions 编排」，没有区分本地 push 前全集自测与 GitHub-hosted 线上子集。随后 evidence 与发布逻辑围绕该错误边界增长，造成重复 job、本地证据耦合与发布责任混乱。

## 根因修复

删除普通 CI 的 self-hosted E2E job，删除两条 self-hosted 专用 workflow 与无用 runner label 配置，但保留所有本地全集脚本。`push-release-tag` 不再读取本地 evidence。GitHub 只保留三条职责单一的 hosted workflow，每条恰好一个 job：main CI 跑子集，nightly 跑深度仿真，tag release 验证精确 main CI 结果后打包发布。tag release 不再重跑 `scripts/check`。

## 验证结果

- Red：run `31199688018` 建立了 hosted check 与 self-hosted E2E 两个 job；后者在执行 step 前被取消。
- Green（fast）：3 份 workflow 的 actionlint、hosted-only／单 job 边界、live CI 正反 fixture、90 分钟 hosted budget、Xcode 26.2、release readiness、build 18 version contract、63 个 failure-case registry、修改脚本的 Bash syntax 与 warning-level ShellCheck 全绿。没有重跑本地产品全集或 DMG 大矩阵。
- 待 Green（symptom）：新 main run 必须只建立一个 `macos-15` CI job 并成功，不得建立 self-hosted job。
- 待 Green（release）：tag workflow 必须消费上述精确 CI 结果，只建立一个 hosted package job，并发布 DMG 与 checksum。

## 永久门禁

- fast：`scripts/test-github-hosted-workflow-boundary`，由 `scripts/check` 强制调用；拒绝任何 workflow 出现 `self-hosted`，固定三条单职责 workflow 和单 job 边界，并禁止 tag release 重跑 `scripts/check`。
- symptom：`scripts/verify-github-hosted-ci`，由 `scripts/push-release-tag` 强制调用；精确 commit 必须只有一次 main push CI，且唯一 job 必须是首次成功的 `macos-15` hosted job。
- release：`scripts/verify-github-release-publication`，由 `scripts/push-release-tag` 强制调用；tag run 必须只有一个 `macos-15` package job，并建立唯一 DMG 与 checksum asset。

## 发行与回滚

build 17 的 main run 已取消，不用于 tag 发布。根修后以新 build 形成新 candidate，只运行 GitHub-hosted main CI 子集；经 live job 清单验证后才允许 tag。回滚可撤回本次 workflow 边界 commit，但不得恢复 self-hosted 调度；若 hosted 子集不足，应扩展 GitHub-hosted 可执行的子集，不得回调用户 Mac。

## 教训与永久约束

测试覆盖与编排位置是两个不同决策。本地全集可以比线上子集更强，但 GitHub 不应因此拥有调度本机的能力。同一 commit 的 hosted 子集只运行一次；tag publisher 消费结果，不重做工作。

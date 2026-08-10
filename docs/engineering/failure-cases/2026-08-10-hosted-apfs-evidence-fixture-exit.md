# FAIL-2026-08-10-05：hosted APFS evidence fixture 静默退出

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-10T16:09:00Z
- 影响版本／构建：v0.2.6 build 27，source commit `764f781076f72a80ccdefb976617ebb54b66bcda`
- 引入提交：`038e4e71f72b2d808e3327aae7b7f23f570f3850` `fix(evidence): harden evidence paths and session lifecycle`
- Git author／committer：quboliu <38942505+quboliu@users.noreply.github.com>／quboliu <38942505+quboliu@users.noreply.github.com>
- 实际修改者：未知；现有 Git 与 session 证据不能证明实际操作者
- 修复提交：`a4af2c44a8849d5a8c370fe252067e99407707d1` `fix(ci): stabilize the hosted mount boundary fixture`；cleanup 审查修复提交待回填

## 用户症状与影响

用户批准 push 与发布后，build 27 的唯一首次 GitHub-hosted CI 在 `scripts/check` 尾段以状态 16 失败，阻止 tag 与 GitHub Release。1514 项 Swift 测试、年度 Demo、确定性仿真及此前门禁均已通过；production App、远端 tag、Release 与公开 DMG 均未触发。

## 时间线

- 2026-08-01：evidence helper lifecycle 加入独立 APFS disk image，验证 helper 不可跨 mounted filesystem boundary。
- 2026-08-10T15:59:45Z：build 27 精确提交首次推到远端 `main`，触发 CI run `31406579094`。
- 2026-08-10T16:06:26Z：同一 run 的 runtime profile isolation 以 HFS+ disk image 完成真实跨设备拒绝并通过。
- 2026-08-10T16:07:56Z：CI 进入 evidence helper lifecycle。
- 2026-08-10T16:09:00Z：第二套 APFS fixture 以原始状态 16 静默退出；job cleanup 随后终止遗留的 `diskimages-help`。

## 复现与证据

GitHub run `31406579094`／job `93514291832` 是 commit `764f781076f72a80ccdefb976617ebb54b66bcda` 唯一、首次、`main` push、`macos-15` job。日志证明 1514 项测试以 0 failure 完成，随后 `scripts/test-runtime-profile-isolation` 的 HFS+ 跨设备 fixture 返回 0。evidence helper lifecycle 进入最终 disk image 段后没有输出其成功终态，`scripts/check` 保留子进程原始状态 16；GitHub cleanup 明确报告 orphan `diskimages-help`。

本机同一提交与同一脚本返回 0，证明产品功能与 helper 语义没有普遍失败；差异只存在于 hosted runner 的第二套 APFS image lifecycle。原脚本对 create、attach、detach 全部使用 `-quiet` 且没有阶段化状态，导致 CI 只能看见裸状态 16。既有日志无法继续区分三个阶段，因此实际返回 16 的精确 `hdiutil` 子命令为未知；不得把 APFS format 本身写成已经证明的唯一原因。

## 排除的假设

- 不是同步修复或 App 功能回归：全部 1514 项 Swift 测试为 0 failure，本机完整真实 App E2E 与 private DMG 已全绿。
- 不是 hosted runner 完全不支持真实跨设备测试：同一 job 更早的 HFS+ image 已完成 create、attach、跨界拒绝与 detach。
- 不是 workflow 重跑或缓存污染：这是该 commit 唯一的首次 push run，checkout 与 Xcode 26.2 均已对账。
- 不是应该跳过 mount 测试：跨设备 fail-closed 是 evidence path 的安全边界，必须继续使用真实 mounted filesystem 验证。

## 根因与破坏机制

同一聚合 check 内存在两套语义相同但 filesystem format 不同的 disk image fixture。evidence helper lifecycle 额外选择 APFS，并把三个 `hdiutil` 阶段设为 quiet、无具名状态；hosted runner 的该 image lifecycle 退出时，Bash 只能把原始状态 16 传给聚合入口，既没有说明失败阶段，也遗留 DiskImages helper。旧 cleanup 又在 detach 失败后静默重试并继续递归删除 fixture，无法证明 mount 已释放。已证实的根因是测试把核心的“不同 device identity”安全需求耦合到重复且不可诊断、cleanup 不闭合的外部生命周期；现有证据不足以把状态 16 进一步归因到某个子命令或 APFS 实现。

## 根因修复

evidence helper fixture 统一采用同一个 hosted run 已证明可建立真实跨设备边界的 HFS+ fixture 语义，移除与安全需求无关的第二种 filesystem format，但仍真实 create、attach 与 detach。挂载后显式比较 repository 与 mountpoint 的 device identity，只有确实跨设备才继续执行 prepare／inventory 拒绝；三个 image 阶段分别保存输出并在失败时报告具名状态。正常 detach 失败时，EXIT cleanup 保存错误、执行 force detach 并再次按 device identity 验证；若 mount 仍存在，保留 fixture、返回失败且绝不递归删除 mounted tree。没有 skip、mock、超时放宽或跨设备检查降级。

## 验证结果

修复后的本机 targeted lifecycle、完整 `make check` 与 build 28 唯一首次 hosted CI 待回填。原始 hosted 症状由红转绿前，案例保持「处理中」。

## 永久门禁

- fast：`scripts/test-evidence-helper-lifecycle` 真实建立 HFS+ mount、对账不同 device identity、验证 helper 拒绝跨界并安全 detach。
- symptom：同一入口由唯一 `macos-15` hosted `scripts/check` 执行；任何 image 阶段失败必须输出具名状态并阻断。
- release：`scripts/verify-github-release-publication` 只接受精确提交首次 hosted CI 成功及唯一 DMG／checksum 全部建立。

## 发行与回滚

风险等级为 P：故障发生在唯一发行门禁。build 27 永久退役，不 rerun、不复用、不推 tag；build 28 必须重新完成本机同源全集、唯一首次 hosted CI 与 tag publisher。若 HFS+ fixture 不能建立不同 device identity，则门禁 fail-closed 并退役新 build；不得恢复 APFS 静默路径、删除 mount 检查或伪造跨设备结果。production 资料与 App 不参与修复验证。

## 教训与永久约束

测试 fixture 的实现细节不得比被验证的安全语义更窄。跨设备测试的 ground truth 是不同 device identity 与真实拒绝，不是特定 filesystem format；所有外部生命周期阶段必须保留可定位的退出状态。

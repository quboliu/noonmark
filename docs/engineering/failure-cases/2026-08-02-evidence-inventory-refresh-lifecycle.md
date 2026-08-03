# FAIL-2026-08-02-09：证据盘点刷新生命周期与新鲜输出契约漂移

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-08-02（本轮合入后的首次 `make check`；精确秒级时间未保留）
- 影响版本／构建：source commit `29d38c68d61725a681efd713358e4f4a8f7d18db` 的本地验证基础设施
- 引入提交：`29d38c68d61725a681efd713358e4f4a8f7d18db`（`fix(evidence): 加固证据路径与会话生命周期`）
- Git author／committer：quboliu `<38942505+quboliu@users.noreply.github.com>`／quboliu `<38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git author／committer identity 不能单独证明实际操作者
- 修复提交：待回填

## 用户症状与影响

合入 descriptor-bound evidence helper 后，`make check` 在 `scripts/test-dmg-evidence-contract` 的 release diagnostic closure fixture 失败。输出为 `artifact inventory output must not already exist`，导致发行验证门禁中止。

这不是 production App、production 资料或用户任务资料故障。失败仅发生在临时 fixture；本轮没有启动、读取、定位、探测或 reset production identity 与资料。

## 时间线

- 2026-08-02：`29d38c6` 将 artifact inventory 的输出策略收紧为只接受尚不存在的目标，防止既有文件被替换。
- 2026-08-02：完整 `make check` 的 DMG evidence contract 判红。
- 2026-08-02：以 `bash -x scripts/test-dmg-evidence-contract` 复现，确认首次 closure inventory 创建成功，后续 mutation fixture 的刷新调用尝试复用同一输出路径。

## 复现与证据

症状命令：

```bash
scripts/test-dmg-evidence-contract
```

合入提交后的首次完整门禁与带 trace 的复现均在 `refresh_closure_fixture_bindings` 调用 `evidence_inventory` 时失败；trace 显示目标 `artifacts/release-diagnostic-closure-gate/artifact-inventory.sha256` 在首次生成后仍存在。

## 排除的假设

- inventory 输出被错误纳入自身的输入：首次相同输入集的创建成功，失败发生在随后刷新已有目标时。
- helper 会话残留导致任意 inventory 失败：同一会话在该失败前已经成功处理多个独立 inventory 请求。
- 放宽 helper 的新鲜输出约束即可恢复：这会重新允许已有目标被替换，违背 descriptor-bound helper 的 fail-closed 安全边界。

## 根因与破坏机制

`refresh_closure_fixture_bindings` 是 mutation fixture 的重建路径，旧实现依赖 shell inventory writer 覆盖已有目标。新 helper 有意在目标已存在时拒绝 publish；调用方没有先移除自己上一轮创建的临时 inventory，因而把正确的 fail-closed 行为误当成验证失败。

## 根因修复

- 在 closure fixture 每次重新盘点前，只删除该 fixture 自己的旧 inventory 输出。
- 删除后再次确认该路径不存在，再请求 helper 创建新文件。
- 不改变 helper 对已有输出、符号链接、特殊文件或跨边界路径的拒绝规则。

## 验证结果

- 症状红：合入后的 `make check` 与 `bash -x scripts/test-dmg-evidence-contract` 均稳定得到 `artifact inventory output must not already exist`。
- Fast／symptom／release 回归结果：待本次修复提交与完整门禁完成后回填。

## 永久门禁

- Fast：`scripts/test-dmg-evidence-contract` 由 `scripts/check` 强制执行，覆盖 closure fixture 多次刷新及新鲜 inventory 输出约束。
- Symptom：`scripts/test-dmg-install` 由 `scripts/release-private-dmg` 强制执行，从 exact package 的受控 `dmg-validation` 路径生成和绑定真实 artifact inventory；不得启动 production App。
- Release：`scripts/test-dmg-install` 由 `scripts/release-private-dmg` 作为私有 DMG 动态验收执行，任何 evidence inventory 无法安全生成或绑定均阻断发行。
- 映射登记：`docs/engineering/failure-cases/gates.tsv`。

## 发行与回滚

- 风险：修复仅改变临时测试 fixture 的输出生命周期；helper 的安全拒绝条件不变。
- 回滚：若重建逻辑错误，回滚该 fixture 的清理逻辑并继续阻断门禁；不得恢复 helper 的覆盖写入或放宽已有输出检查。
- 灰度：专项 DMG evidence contract → `make check` → 私有 DMG 的受控 `dmg-validation` 安装验收。
- 监控：继续记录 inventory 输出是否新鲜、helper 请求结果、cross-manifest digest 与 `production_app_executed=false`。

## 教训与永久约束

1. 安全 helper 将「输出必须新鲜」提升为契约后，所有 fixture 刷新路径都必须显式拥有并清理自己的旧输出。
2. 不能把测试 fixture 的兼容性问题通过放宽 production-adjacent evidence 边界解决。
3. 重新生成证据前后的文件生命周期必须同时纳入 fast contract 与真实 DMG 验收。

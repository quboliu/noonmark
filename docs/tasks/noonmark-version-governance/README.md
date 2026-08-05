# noonmark-version-governance

- Task-ID：`noonmark-version-governance`
- 风险等级：P
- 状态：实施与完整门禁已完成，待双轴审查、提交、推送与建立历史基线 tag。

## 目标

把晷迹的营销版本、build、资料兼容矩阵与私有 DMG 发行流程收敛为可追溯的单一体系。

## 交付

- `release/VERSION` 成为唯一版本来源。
- 构建拒绝版本环境覆写；私有发行要求精确 `v<marketing_version>` tag。
- 版本、兼容、风险、回滚、灰度和监控规则见 `docs/engineering/versioning-and-private-release.md`。
- 已为 `0.2.1 (6)` 补私有发行记录，待建立 `v0.2.1` 历史基线 tag。

## 验证

- `scripts/test-release-version-contract` 通过。
- `scripts/test-release-gate-contract` 通过。
- `make check` 审计清单为 `suite_exit_status=0`。

## 边界

不改变既有 SQLite v15 → v17 升级与 JSON v6 → v7 导入支持范围。任何后续兼容范围变化必须在版本设计阶段由用户明确审核。


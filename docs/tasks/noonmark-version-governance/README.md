# noonmark-version-governance

- Task-ID：`noonmark-version-governance`
- 风险等级：P
- 状态：已完成；待推送 `main` 与历史基线 tag。

## 目标

把晷迹的营销版本、build、资料兼容矩阵与私有 DMG 发行流程收敛为可追溯的单一体系。

## 交付

- `release/VERSION` 成为唯一版本来源。
- 构建拒绝版本环境覆写；私有发行要求精确 `v<marketing_version>` tag。
- 版本、兼容、风险、回滚、灰度和监控规则见 `docs/engineering/versioning-and-private-release.md`。
- 已为 `0.2.1 (6)` 补私有发行记录；注释 tag `v0.2.1` 已精确指向实际发行提交 `5f4d6cdcf0d39e38a47ee128a9e6102e13b58d80`。

## 验证

- `scripts/test-release-version-contract` 通过。
- `scripts/test-release-gate-contract` 通过。
- `make check` 审计清单为 `suite_exit_status=0`。

## 边界

2026-08-11 用户已明确审核并批准开发期 clean cut：移除 SQLite v15／v17／v18 自动迁移与 JSON v6 导入。当前只允许空库创建 schema 19、exact schema 19 打开，以及 canonical JSON format 7 导入；其余旧格式全部 fail-closed 且不得改写。未来任何兼容范围变化仍必须在版本设计阶段再次由用户明确审核。

# FAIL-2026-08-06-02：子任务难度入口不可见并挤压标题

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-06T22:43:06-04:00
- 影响版本／构建：`73e2c597499359f05093b0beb40894a4ab4cba4f` 上尚未提交的工作树构建
- 引入提交：无；故障来自当前任务中尚未提交的工作树变更
- Git author／committer：无；故障变更尚未形成 Git commit
- 实际修改者：当前 Codex agent；由本次 agent session 与工作树 diff 确认
- 修复提交：`2b2bd75d22ae3ff6d74fe8c5760201646a7eb293` `feat(ui): simplify flylight and subtask surfaces`

## 用户症状与影响

难度文字按钮取消后，用户仍看不到待办方框右侧的难度圆点；标题右侧保留过多空档，导致子任务正文在仍有可回收横向空间时提前换行。问题同时影响 Day Todo、任务池、重复计划及共用难度入口的烛龙任务草稿。

## 时间线

- 首版工作树把行尾难度胶囊替换为 `Menu` 内的自定义 `Circle`，并移到待办方框右侧。
- 用户在真实 App 中发现圆点不可见，且标题仍在删除按钮前留下明显空档。
- E2E 先把圆点像素、控件几何、原生菜单、标题编辑、SQLite 与重启写成红灯门禁，再重构共享难度入口和标题布局。
- 用户进一步确认应把标题到删除按钮的 `8 pt` 空档减少一半；收紧门禁后，旧布局在真实 App 中以精确 `8 pt` 判红。

## 复现与证据

- 初始真实 App 截图在难度锚点区域量得最小亮度 `1.0000`，说明该区域为纯白而不是颜色过浅。
- 初始真实视图树量得子任务行 `252 pt`、难度锚点 `6 pt`、标题编辑器 `150 pt`，标题编辑器到删除按钮间隙 `24 pt`，编辑器另有 `5 pt` text-container inset 与 `5 pt` line-fragment padding。
- 第一轮根因修复后，收紧后的真实 App 门禁量得难度入口 `(12 × 28) pt`、标题编辑器 `160 pt`，但标题右边缘到删除按钮仍为精确 `8 pt`，按用户要求判红。
- 复现只使用 `e2e` profile 与仓库 fixture；没有读取或启动 production。

## 排除的假设

- 不是圆点颜色仅仅太浅：截图中的目标像素全部为白色，证明圆点没有被绘制。
- 不是难度数据丢失：模型、SQLite 字段和难度更新 API 均保持原值，物理菜单选择后可回读 `hard`。
- 不是只有某个调用页局部留白：Day Todo、任务池和重复计划都复用了同一种行尾布局结构。
- 不是标题内容本身必然换行：移除固定占位、编辑器水平 inset 与多余间距后，相同宽度下可显示更多文字。

## 根因与破坏机制

SwiftUI `Menu` 在当前 macOS 原生 `SwiftUIPopupButton` 路径中没有绘制自定义 `Circle` label，导致语义锚点存在而可见像素缺失。与此同时，旧行尾 `Spacer`、HStack 间距、编辑器 text-container inset 与 line-fragment padding叠加，持续吞掉标题宽度；第一轮修复后剩余的默认 `8 pt` HStack 间距仍位于标题与删除按钮之间，继续造成提前换行。

## 根因修复

- 共享 `SubtaskDifficultyDotMenu` 在菜单外独立绘制 `10 pt` 圆点，以透明的原生 `Menu` 命中层覆盖同一 `12 pt` 列；完整命名选项、键盘与 VoiceOver 语义仍由原生菜单承担。
- Day Todo、任务池、重复计划与烛龙草稿统一使用共享入口，删除行尾难度文字、胶囊和固定宽度 Picker；底层 `SubtaskDifficulty` 数据模型及写入 API 不变。
- 删除标题后的 `Spacer`，把可伸缩优先级交给标题；子任务编辑器水平 inset 与 line-fragment padding 归零。
- 共享子任务控件间距固定为 `4 pt`，将标题到删除按钮的空档减半并把空间还给正文。

## 验证结果

- 收紧门禁前，真实 App 在标题到删除按钮为 `8 pt` 时按预期判红。
- 修复后 `NOONMARK_E2E_SUBTASK_LAYOUT_ONLY=1 scripts/test-e2e` 通过：截图像素证明简、中、难三颗圆点逐级加深，难度列不超过 `14.5 pt`，标题取得至少 `63%` 行宽，标题到删除按钮保持 `4 ± 0.5 pt`，水平 inset 与 line-fragment padding 均不超过 `0.5 pt`。
- 同一路径经 WindowServer 物理点击圆点，观察原生菜单开始 tracking，选择「难」后对账领域模型、SQLite `difficulty = 3` 与重启回读仍为 `.hard`；随后完成标题行内编辑。
- `make run-demo-app` 已基于精确修复提交重建并打开隔离 Demo，fixture manifest 生成成功。
- 完整 `make check` 通过；证据清单 `artifacts/audit-final/make-check/manifest.txt` 记录 `suite_exit_status=0`，fast gate、真实 App symptom gate、故障案例聚合、DMG、签名、诊断边界与格式门禁全部完成。

## 永久门禁

- fast：`scripts/test-subtask-difficulty-ui-contract`，由 `scripts/check` 强制调用，固定共享圆点、`12 pt` 列、`4 ± 0.5 pt` 间距、三档深浅、零水平编辑器 inset、SQLite／重启难度回读、四个调用面和真实 App 断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，在真实 Mac App 中检查圆点像素、布局几何、原生菜单交互、标题编辑、SQLite 与重启。

## 发行与回滚

本次只运行 `e2e` 与 `demo` profile，不触碰 production。若圆点命中、标题编辑或难度持久化回归，停止交付并整体回退共享难度入口、行布局和编辑器 style 变更；数据模型无迁移，不需要资料回滚。不得恢复宽难度胶囊作为替代方案。

## 教训与永久约束

语义树中存在控件不等于 WindowServer 产物可见；紧凑入口必须同时以截图像素和真实物理交互证明。移除一项行尾控件时，必须量测完整宽度预算，包括 `Spacer`、容器间距、text-container inset 与 line-fragment padding；用户指出仍有空档后，应直接把最终可见几何写进症状门禁。

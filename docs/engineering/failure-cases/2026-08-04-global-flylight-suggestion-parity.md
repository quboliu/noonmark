# FAIL-2026-08-04-09：全局飞光缺少分类建议能力

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:04 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至 `0d62105`
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由工作会话、Git 记录与 K3 review 确认
- 修复提交：待回填

## 用户症状与影响

页面 Composer 与行内 editor 输入 `@`／`#` 会出现分类建议，但快捷键或菜单打开的全局飞光面板没有建议。三处虽然外观看似共用 Composer，实际能力不对等；用户在最强调快速捕获的入口反而必须记住并完整输入分类名。

## 时间线

- K3 review 指出共享 surface 只共用外壳，建议逻辑仍留在页面调用层。
- 真实 App E2E 从全局面板输入 `@工`，修复前返回 `global Flylight did not expose category suggestions`。
- active token、候选查询、列表、补全与焦点恢复移入 `FlylightComposerSurface`；全局面板同步根据候选数调整高度。

## 复现与证据

运行飞光专项 E2E。它通过真实菜单打开面板、输入 `@工`、等待 `idea-capture.field.suggestions`、物理点击唯一候选并验证文本成为 `@工程 `，随后发布、重启及 SQLite 分类身份对账。修复前建议锚点不存在，路径稳定判红。

## 排除的假设

- 不是面板空间不足：面板模型可依据候选数扩大高度。
- 不是 parser 不支持：同一文本在页面入口已能返回 active token。
- 不是只需复制页面代码：那会继续造成三种场景漂移；能力必须归共享 surface 所有。

## 根因与破坏机制

首轮重构把 Markdown editor 与按钮抽到共享 View，但分类 token 推导和 suggestion list 留在 `IdeasPage`。全局面板只实例化 surface，因此天生缺少该能力，所谓共享 Composer 是浅层共用。

## 根因修复

共享 surface 统一计算 active token 与最多六个候选，渲染同一 suggestion list，并通过同一 completion encoder 更新 binding、恢复 editor focus。页面与行内重复实现删除；面板高度随候选和错误状态更新。

## 验证结果

- 修复前真实 App 症状判红，修复后完整专项 E2E 转绿。
- 页面、行内与全局面板均编译并使用同一共享建议逻辑。
- 完整 `make check` 尚待最终执行。

## 永久门禁

- fast：`scripts/test-notes-ui-contract`，由 `scripts/check` 强制调用，要求建议列表属于共享 surface，并保留全局建议 E2E 断言。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，在真实 `NSPanel` 输入、显示、物理选择、发布及回读分类。

## 发行与回滚

只运行 `e2e` profile。若回归，停止交付共享 Composer；不得在全局面板另复制一套候选状态。

## 教训与永久约束

共用一个 View 名称不等于能力共用。输入解析、建议、补全、焦点恢复与错误状态必须一起归属同一个 Composer 边界。

# FAIL-2026-08-04-08：飞光分类名在再次编辑时不可逆

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 09:02 -04:00
- 影响版本／构建：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` 至 `0d62105`
- 引入提交：`1e2f45ad68a821e24d76a0d6442418f3d338aed9` `feat(flylight): 重构飞光输入与编辑体验`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／同一 identity
- 实际修改者：当前 Codex agent；由该提交对应工作会话、Git 记录与 K3 review 确认
- 修复提交：`9a60f1094a8c9802aa0d45768bb25d9cded1bcec`

## 用户症状与影响

旧飞光若属于带空格的分类，例如 `Client Work`，双击编辑时原实现生成 `@Client Work`。再次保存时 parser 只把 `@Client` 当分类，`Work` 混入正文，并报告分类无法解析。用户只是打开旧内容编辑，也可能破坏正文与分类身份。

## 时间线

- K3 review 以 `Client Work` 指出 display name 与 editable token 不是同一可逆编码。
- 新增 parser round-trip 测试后，旧 API 缺失并判红。
- `IdeaDraftParser.editableText` 统一使用与建议补全相同的引号／转义编码；真实 App fixture 新建 `Client Work` 分类，检查行内 editor 精确显示 `@"Client Work"`，再物理修改正文并保存。

## 复现与证据

`swift test --filter NewTaskDraftParserTests` 覆盖空格、引号与反斜线的编码后再 parse。真实 App E2E 创建带分类的飞光、物理双击进入 editor，逐字断言正文后为 `@"Client Work" #SwiftUI`，修改正文后物理保存，并对账 Engine／SQLite 的原 category ID 与 label ID；旧直接拼接实现无法满足该路径。

## 排除的假设

- 不是只影响英文：任何含空白或需要转义的分类名均受影响。
- 不是展示 badge 的问题：浏览态 display name 正确，故障发生在重新构造可编辑文本时。
- 不是 parser 应吞掉剩余文字：那会进一步扩大正文误删；应由 producer 输出合法可逆 token。

## 根因与破坏机制

浏览态 `displayName` 是面向 UI 的 `@名称`，重构却直接把它拼回 parser 输入。显示字符串没有 token 边界保证，因而不是持久分类身份的序列化格式。

## 根因修复

新增单一 `IdeaDraftParser.editableText`，由原始正文、分类名及标签名生成草稿；所有需要引号的名称使用 parser 共用 encoder。Store 不再复用浏览 badge 文案构造编辑值。

## 验证结果

- `NewTaskDraftParserTests` 14／14 通过。
- 真实 App 的 `Client Work` 创建、双击编辑、分类身份、重启与 SQLite 对账通过。
- `make test-demo-fixture` 与完整 `make check` 均通过；全量报告为 1500 项测试、0 失败。

## 永久门禁

- fast：`scripts/test-unit`，由 `scripts/check` 强制调用，钉死带空格分类名的 encode → parse round-trip。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，真实 App 物理双击带空格分类的飞光，并检查 editor、保存与 SQLite 身份。

## 发行与回滚

验证只使用 `e2e` profile。若回归，停止交付并回退新的编辑 reconstruction；不得禁止空格分类名或用正文清理补丁掩盖。

## 教训与永久约束

展示文案不是可编辑序列化格式。任何从持久身份回到 token editor 的路径，都必须由 parser 所有的可逆 encoder 生成。

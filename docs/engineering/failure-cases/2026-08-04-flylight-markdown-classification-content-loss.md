# FAIL-2026-08-04-03：飞光 Markdown 分类误删转义与 URL 正文

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 02:29 -04:00
- 影响版本／构建：2026-08-04 未提交工作树所构建的隔离测试 App
- 引入提交：无；故障在本轮尚未提交的 Markdown 分类 scanner 扩展中引入
- Git author／committer：不适用；故障改动尚未提交
- 实际修改者：Codex 当前 agent session
- 修复提交：`3ab199ec94e5de9e2bf6b0143a11f173e2fa63c6`

## 用户症状与影响

飞光正文包含反斜线转义的 `#`／`@` 字面量，或包含带 `#`／`@` 的裸 URL 时，保存会把这些片段误当分组／标签 token 并从正文移除。该故障会静默损坏用户刚输入的 Markdown 内容，并可能建立错误分类。

## 时间线

- 2026-08-04：实现飞光 Markdown 分类保护时覆盖 heading、代码与显式链接目标，但遗漏转义标记和裸 URL。
- 2026-08-04 02:29：Standards 审查指出边界 scanner 会接受反斜线与 URL 斜线后的分类标记。
- 2026-08-04 02:29：新增最小解析回归；13 项聚焦测试中新增两例产生 5 个精确断言失败。
- 2026-08-04：统一扩展 Markdown 保护范围后，同一测试转绿。

## 复现与证据

运行 `swift test --filter NewTaskDraftParserTests`。修复前，转义字面量被剥离为只剩反斜线，裸 URL 的用户片段被截断，原本唯一的显式分组因误识别第二个 `@` 而变成冲突；active-token 同时错误返回建议上下文。

## 排除的假设

- 不是正文空白归并扩大删除范围：误识别在 token occurrence 产生时已经发生。
- 不是 active-token 与保存解析使用不同规则：两条路径都会读取同一个 Markdown 保护范围，新增断言同步判红。
- 不是显式 Markdown 链接解析失效：既有 `](...)` 链接目标测试始终通过，遗漏只发生于转义标记与裸 URL。

## 根因与破坏机制

`IdeaDraftParser` 先从通用任务 token scanner 收集 occurrence，再排除 Markdown 保护范围。首版保护范围只包含 backtick code、行首 heading marker 与显式链接目标；通用 scanner 又把反斜线、斜线等非字母数字字符视为合法 token 边界，因此 `\#literal` 与 URL 路径中的 `@user` 都会穿过过滤并进入正文删除阶段。

## 根因修复

- Markdown 保护范围新增奇数反斜线转义的 `#`／`@` 标记。
- 识别带合法 scheme 的 `://` URL span，把其 user-info、路径、查询和 fragment 作为正文保护。
- 保存解析与 active-token 继续复用同一保护函数，避免两套规则漂移。
- 真实 App 飞光草稿加入裸 URL，保存、SQLite 与重启回读必须逐字保持；反斜线转义由同一真实 parser seam 的快速测试锁定。

## 验证结果

- `swift test --filter NewTaskDraftParserTests`：13／13 通过；修复前同一命令稳定产生 5 个精确断言失败。
- `scripts/test-notes-ui-contract`：通过。
- `NOONMARK_E2E_IDEA_CAPTURE_ONLY=1 scripts/test-e2e`：通过；带 `@` 的裸 URL 经真实输入、保存、SQLite 与第二个 App process 回读后逐字一致，Sticky Note 返回飞光的源条目定位同时通过。
- `make test-demo-fixture`：通过；Sticky Note 清单流与便签墙分别生成真实 App 截图并纳入尺寸门禁。
- `make check`：通过，1493 项测试无失败；两项 live iCloud 测试按既有环境约束跳过，其余 lint、format、真实 App、仿真、DMG 与故障案例门禁全部通过。

## 永久门禁

- fast：`scripts/test-unit`，由 `scripts/check` 强制调用，解析测试固定转义标记、裸 URL、显式分类与 active-token 的共享保护语义。
- symptom：`scripts/test-e2e`，由 `scripts/test-all` 强制调用，以真实飞光 composer 物理输入带 `@` 的裸 URL，并经保存、SQLite 与第二个 App process 回读验证正文不变。

## 发行与回滚

故障只存在于未提交非生产构建，未触碰 production App 或资料。若真实路径仍会损坏正文，应停止本轮交付并回退 Markdown 分类 scanner，不得通过隐藏建议或吞掉解析错误绕过。

## 教训与永久约束

分类 scanner 处理 Markdown 正文时，合法 token 边界不能单独决定语义；必须先建立代码、heading、链接、URL 与转义的共享保护范围。任何会从用户正文移除字符的 parser 都要同时具备最小单元红绿循环和真实持久化症状门禁。

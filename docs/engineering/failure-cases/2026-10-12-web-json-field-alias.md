# FAIL-2026-10-12-01：Web JSON 字段别名绕过重复字段拒绝

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-10-12 23:16 至 23:20，America/New_York；UTC 为翌日。
- 影响版本／构建：个人自部署 Web 首轮未提交实现，CLI 版本 `0.1.0-dev`；此前仓库尚无本次 Web 服务，不影响原生 Mac。
- 引入提交：不存在；故障在本轮未提交源码首次运行时发现，不能归因给已有 commit。
- Git author／committer：引入故障时尚无 Git 提交，因此无对应 Git identity。
- 实际修改者：可由本次协作 session 确认，HTTP 首次实现由 root Codex agent 编写；build_tools agent 添加独立运行测试后发现。没有证据将该代码归因给具体自然人。
- 修复提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`

## 用户症状与影响

登录请求同时包含 `password` 与 `Password` 时，共享 JSON 校验器没有认定为重复字段。Go 解码器随后把后一个字段映射到同一个密码槽位。第一项为错误口令、后一项为正确合成口令的测试请求返回 HTTP 200 并签发会话，违反含歧义输入必须拒绝的 API 契约。

Unicode long-s 别名 `pa\u017fsword` 也会映射到 `password`。这不是无凭证登录：成功请求仍提供正确合成口令；故障是不同校验层对同一输入的字段身份产生分歧，不能以最终口令校验通过为理由接受它。其他固定 schema API 共用相同解码边界，因此一起修复。

## 时间线

1. 首次实现用 `uniqueJSON` 拒绝完全相同的 JSON key，再用 `encoding/json` 解码到 typed struct。
2. 独立 Go 测试以真实 SQLite、owner、key 和实际 HTTP handler 复现 ASCII 别名返回 200，预期 400；普通重复字段与转义后的完全相同 key 已被拒绝。
3. 将嫌疑扩展到 Unicode case folding，long-s 别名同样返回 200，排除只转小写即可补齐语义的假设。
4. root agent 将协议字段限定为 ASCII snake_case，拒绝大小写及 Unicode 别名。HTTP／CLI 的 `go test -race -count=1` 通过。
5. 真实隔离部署的同组症状测试及完整聚合门禁通过，修复已进入首个实现提交。

## 复现与证据

入口：`scripts/web/test-http-boundary`。原始症状用例为 `TestLoginRejectsAmbiguousJSONBeforeAuthentication/case_folded_duplicate` 与 `unicode_folded_duplicate`。

测试使用本轮自动生成的实例目录，只通过真实 `store.Init`、`InitializeOwner` 和 `InitializeKey` 初始化；不读取正式实例。源码位于 `services/noonmark/internal/httpapi/server_test.go`，测试报告外置。失败断言只保留状态与 typed code，不输出口令、会话或响应正文。

修复前，两项分别产生「status = 200, want 400」；修复后，两项返回 400、`INVALID_REQUEST`。其他门禁包括真实 TCP 登录／读取／退出、Origin／Host／代理 TLS 边界、请求体大小及深度限制、未知字段和静态文件越界。

## 排除的假设

- 不是 SQLite 或 Argon2 验证失败；同一真实实例的错误口令返回 401，正确口令返回正常会话。
- 不是所有重复字段都被接受；完全相同 key 和 Unicode escape 解码后完全相同 key 的测试已拒绝。
- 不能只用 ASCII 大小写归一化修复；Go 字段匹配也接受 Unicode case-fold 别名。
- 不涉及浏览器 cookie 或离线数据回放；症状直接发生在服务端请求解码阶段。

## 根因与破坏机制

`uniqueJSON` 使用原始字符串作为 map key；`encoding/json` 对 struct 字段则允许大小写折叠匹配。两层 key 等价关系不同，校验通过后的解码仍可覆盖已赋值字段。

## 根因修复

所有当前输入 schema 的协议字段都是固定 ASCII snake_case。共享 `uniqueJSON` 先拒绝非 `a-z`、`0-9`、`_` 字段名，再拒绝重复字段；typed decoder 继续拒绝未知字段、尾随 JSON 和类型错误。校验与解码使用同一份有界 byte buffer，不引入另一条宽松路径。

## 验证结果

原始 ASCII／Unicode 歧义字段请求在真实 HTTP 测试和实际容器 endpoint 均返回 400／INVALID_REQUEST，未签发 token；正常认证与来源边界回归通过。

上述修复已进入首个实现提交；完整运行证据见[预览验证记录](../../tasks/noonmark-web-self-hosted/verification.md)。

## 永久门禁

- fast：`scripts/web/test-http-boundary`，由 `make check` 及 `scripts/web/check` 强制执行真实 Go HTTP／SQLite 测试；不以静态字符串检查代替运行。
- symptom：`scripts/web/test-e2e`，由 `scripts/web/check` 强制启动隔离实例，并向其真实 endpoint 提交同组歧义请求。
- 登记位置：`docs/engineering/failure-cases/gates.tsv`。缺少任何启用入口或依赖时失败，不跳过。

## 发行与回滚

该服务尚未发行，故障没有引入提交，也没有公开受影响版本。新实现未替换原生 Mac 路径。修复门禁及症状验证完成前不发布 Web 发行物；后续如需回滚，revert 对应 Web 提交并保留用户实例数据，不靠清空数据处理请求解码问题。

## 教训与永久约束

输入校验器与 typed decoder 必须采用相同字段身份规则。设计 strict JSON 门禁时同时覆盖原字节重复、escape 后重复、ASCII 大小写和 Unicode folding；不得用「反序列化成功」证明协议输入唯一。

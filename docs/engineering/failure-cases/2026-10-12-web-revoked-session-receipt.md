# FAIL-2026-10-12-04：已撤销会话仍可通过 Store 读取命令收据

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-10-12，Web 初始实现的独立权限复核。
- 影响版本／构建：尚未提交、尚未发行的 Web 初始实现，开发基线 `83e9aedd6003632b26b26b80808e132e1187ebc5`。
- 引入提交：不存在；错误产生于本轮未提交工作区，基线尚无该 Go 实现。
- Git author／committer：引入故障时尚无对应 Git identity。
- 实际修改者：Codex `domain_store` agent 编写 `Receipt` 时遗漏事务内复核，可由当前会话和文件创建记录确认；人类操作者身份未知。
- 修复提交：待回填。

## 用户症状与影响

HTTP 入口认证完成后，请求可能等待 Store 的 writer mutex。若期间会话被撤销，随后取得锁的 `Receipt` 原本仍可读取命令 ID、sequence 和结果实体 ID。该收据不包含任务正文；本次没有发现无凭证创建会话或修改任务的路径。

## 时间线

1. 普通命令和日结已在事务内重新验证认证 context；receipt 查询仅依赖入口认证。
2. 新增真实 owner／SQLite 测试：登录、提交、读取收据、退出，再用原认证 context 读取。
3. 原始运行报错 `revoked session receipt access: <nil>`，证明 Store 接受了已失效 context。
4. 在 receipt 事务内调用共享 `validateSessionTx`，原始测试及相关 race 回归转绿。

## 复现与证据

`TestRevokedSessionCannotReadReceipt` 使用真实 SQLite、Argon2id owner 和实际 session 表。测试先证明有效会话能读取收据，再调用 `Logout` 撤销同一 token，最后经相同 Store 入口检查拒绝结果。调用顺序复现“已取得认证 context，随后被撤销，再进入数据事务”的边界。

## 排除的假设

- token 没有更换，错误不是请求拿错身份。
- session 删除已经真实提交，错误不是退出仅修改了浏览器状态。
- 此问题影响 receipt 查询；普通 command 的事务内验权已有保护。

## 根因与破坏机制

入口认证与数据读取发生在不同时间。`Receipt` 在等待 mutex 后开启事务，却没有重新确认 session 的当前有效性，令已撤销的认证结果继续生效。

## 根因修复

取得 mutex 并开启读事务后、查询 dataset 或 receipt 之前，执行共享 session 复核。CLI 和内部测试的显式可信调用仍沿用已有 context 契约。

## 验证结果

原始测试从接受已撤销 context 转为返回 `AUTH_REQUIRED`；有效会话读取继续通过。目标测试与相关 `-race` 回归通过，修复提交待回填。

## 永久门禁

`scripts/web/test-domain-boundary` 强制运行真实 SQLite receipt 撤销测试，纳入 `scripts/web/check` 和顶层 `make check`。这项较短的集成运行同时提供 fast 与 symptom 证据，两个登记引用同一实际测试，不宣称额外的浏览器覆盖。

## 发行与回滚

故障代码未发行；保持非生产隔离 run。回滚须保持事务内 session 复核，不得恢复仅入口验权的读取路径。

## 教训与永久约束

会话撤销必须在实际读取／修改的事务边界生效。新增 Store 入口时须检查等待锁之后的权限状态，而不能只依赖 HTTP handler 已做过认证。

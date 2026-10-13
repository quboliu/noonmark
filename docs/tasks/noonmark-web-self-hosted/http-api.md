# Web 个人实例 HTTP 契约

- Task-ID：`noonmark-web-self-hosted`
- 版本：`/api/v1`，Web schema 1。
- 事实来源：`services/noonmark/internal/httpapi`、`internal/core/types.go` 与真实 HTTP 测试。

所有 API 与 UI 同源。公开访问需要 HTTPS；开发用 HTTP 只接受 loopback origin 与本地 peer，容器或代理来源必须显式信任。Host、Origin 和代理来源均受检查，不开启跨站 CORS，也不用 credential cookie。认证接口接受 JSON，随后用 `Authorization: Bearer …`；token 只在客户端内存保存，服务端只保存其摘要。

| 方法和路径 | 行为 |
| --- | --- |
| `GET /healthz` | 最小 SQLite 活性，不输出实例资料 |
| `GET /api/v1/info` | 已初始化状态和服务版本 |
| `POST /api/v1/auth/login` | `{password}`；返回 12 小时会话 token 和到期时间；实例级限速 |
| `POST /api/v1/auth/logout` | 立即撤销当前会话 |
| `GET /api/v1/snapshot` | 读取当前 owner 的完整事实集合、时区、today、sequence 与控制身份 |
| `POST /api/v1/commands` | 提交一个领域命令，成功返回 durable receipt |
| `GET /api/v1/commands/{command_id}` | 查已提交 receipt；不存在不等于可以确认前一请求未提交 |
| `GET /api/v1/events` | Bearer fetch SSE，只有 sequence 通知和 heartbeat；事实仍从 snapshot 读取 |
| `POST /api/v1/backups` | `{password,passphrase}`；重新验证 owner，返回 age 加密实例包 |

从 `snapshot` 获取 `instance_id`、`instance_epoch`、`dataset_id` 后，命令提交：

```json
{
  "instance_id": "<snapshot instance>",
  "instance_epoch": "<snapshot epoch>",
  "dataset_id": "<snapshot dataset>",
  "command_id": "<new random UUID>",
  "schema_version": 1,
  "type": "CreateTask",
  "expected_revision": "0",
  "payload": {"title": "准备今天的工作", "date": "2026-10-12"}
}
```

数字 sequence、revision 与 exact-clock bit pattern 用十进制字符串传输，避免 JavaScript 精度损失。clock 的业务排序不依赖 UUID。修改已有 chain／idea／day 时必须传读取到的 revision；旧 revision 返回 `VERSION_CONFLICT`，不能自动把旧输入覆盖到新版本。

服务端拒绝重复字段、未知字段、大小写和 Unicode 字段别名、过深 JSON、超限 body 和非 JSON Content-Type。协议字段固定为 ASCII snake_case；用户正文仍接受 Unicode。成功响应为 `{command_id,status:"committed",sequence,entity_id,mutation_bits}`。相同 ID 和内容返回原 receipt；不同内容返回 `IDEMPOTENCY_MISMATCH`。receipts 暂不清理，避免任意过期窗口使重试变成重复写入。

错误正文仅为 `{code}`，不返回原始数据库错误、路径、正文或凭证。未认证为 401，控制身份／版本冲突为 409，明确输入错误为 400，服务繁忙或存储故障为 503。网络中断和 5xx 必须作为结果不明处理，客户端不能换一个 ID 自动重提。恢复实例会更换 epoch，旧请求不得写入恢复后的资料。

调用者不提供主机时钟或权威 today；时区在初始化时指定，服务端负责跨日结算。当前接口没有修改 owner 时区、批量命令、分页、账号多租户或原生同步能力，不能据此假设已经实现。

# 任务分类换代采用无兼容 clean cut

**Status**: Accepted

晷迹尚无用户，仓库与开发机中的既有数据全部是可重新生成的测试数据。任务分类换代不承担旧分类数据的保留义务，因此当前实现只定义一套领域模型、一套 SQLite schema 和一种数据包格式。空白数据库直接安装当前 schema；结构不匹配的非空数据库与非当前数据包一律 fail-closed，由开发者清理测试数据后重新建立。

**Consequences**

- 删除上一代分类类型、写 API、表、column、decoder、fixture、来源 variant 和 UI，不保留 adapter、双写、fallback 或 converter。
- SQLite schema 与数据包在本代均从 version 1 开始；版本字段必需，缺失或不匹配不会触发推断或升级。
- 普通 sync wire payload 同样从 canonical version 1 开始；只接受当前 envelope 的精确 bytes，未版本化 raw model、未知字段及上一代分类字段不会被 Swift `Decodable` 静默忽略。
- `DayTrace` wire payload 只携带轨迹事实。每条历史分类快照以 UUID 标识的 immutable `traceClassificationEvent` 独立传输，并携带 typed revision 与前驱事件；它不是旧字段兼容，也不建立第二套分类事实源。
- `classificationCommit` 只接受统一 version 1 typed delta，覆盖当前关系与所有分类管理操作；不保留 set-current 专用 initializer、投影或 decoder。相关事实的真正前驱 change record ID 必须显式传输并可持久等待。
- classification state revision 等于会推进状态的 change record 数量与历史快照事件数量之和；远端 payload 不得直接声明或放大全局 revision。
- 精确 rename no-op 只留下 immutable audit／receipt，不改变分类事实、不推进 revision、不成为后续事实的前驱；它在真实改名或 hard delete 之后到达时也不得覆盖或复活对象。
- hard delete 释放名称所有权后，复用当前名称或任何历史别名的新建提交必须依赖释放所有权的 hard-delete commit；乱序到达时先 durable waiting，不能靠时间戳猜测胜者。
- 同链后继关系提交携带其 before state 观察到的完整 causal frontier；并发 heads 不得被 canonical 数组中的单个 `last` 记录代替。merge source／target 是 exact-item causal barrier，rename 仅可与普通 `setCurrent` 关系写按稳定身份交换。
- immutable journal 日期使用 `Date.timeIntervalSinceReferenceDate.bitPattern` 作为 exact-match CAS 事实；文字日期只作可读且必须一致的投影。
- SQLite audit sequence 是可重建投影；并发事实 canonical 前插时按 immutable ID／内容校验，并在同一事务内无删除重排。
- 下载合并以单一事务原子写入 snapshot、冲突的完整 remote record 证据、durable pending、审计与同步 metadata；其中任何写入失败都保持下载前状态。
- Local Folder、iCloud 复用路径与 InMemory 仿真都以 create-or-exact-match 保护 immutable record；不同 canonical bytes 不作旧格式兼容。
- App 不静默删除不匹配的数据库，必须报告拒绝原因；测试数据清理由开发者显式执行。
- 代码回滚只依赖 Git。保存事务仍必须 SQLite rollback，但产品不提供旧数据恢复或反向投影。
- 测试只由当前领域行为建立 ground truth，验证空库安装、当前格式 round-trip 与非当前格式零改动拒绝。

**Rejected alternatives**

- 一次性迁移后再删除兼容层：没有用户价值，却扩大 schema、审计、测试和回滚表面积。
- 启动时自动清空不匹配数据库：实现简单，但会掩盖结构错误，也违反白盒原则。
- 保留只读旧表或旧数据包 decoder：仍会形成第二套事实解释路径，使 clean cut 名存实亡。

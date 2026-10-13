# FAIL-2026-10-12-07：可变小数位的时间字符串让飞光顺序倒置

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-10-12，Web mutation clock 修复后的展示排序复核。
- 影响版本／构建：尚未提交、尚未发行的 Web 初始实现；开发基线 `83e9aedd6003632b26b26b80808e132e1187ebc5`。
- 引入提交：不存在；基线不含该 Go／Web 实现，问题来自本轮未提交工作区。
- Git author／committer：故障代码尚无对应 Git identity。
- 实际修改者：当前会话证明 `domain_store` agent 使用 `RFC3339Nano` 生成并比较可变精度时间字符串，`web_ui` agent 在飞光视图使用相同文本排序假设；无法据此确认人类操作者身份。
- 修复提交：待回填。

## 用户症状与影响

相同或回拨的墙钟下连续创建飞光，后一条虽有较新的 exact mutation instant，却可能出现在前一条之后。例如整秒文本以 `Z` 结尾，而较新的小数秒文本在同一位置出现 `.`；直接比较字符串会认为旧记录更大。

## 时间线

1. 共享 stamp 采用 `RFC3339Nano`，自动省略小数尾零及整秒小数部分。
2. Go 时间线与 Web 飞光视图按文本倒序排序。
3. `TestMutationStampCanonicalOrdering` 和真实 SQLite `TestSameWallClockIdeasSortNewestFirst` 同时判红，后者报错 `variable-width timestamp projection sorts older capture ahead of newer capture`。
4. 统一改为 UTC 固定九位小数投影，两个门禁转绿，并以 JavaScript 的实际 `localeCompare` 对 Store 输出再次对账。

## 复现与证据

真实 SQLite 测试在整秒墙钟下连续调用两次 `CreateIdea`，再通过 `Snapshot` 读取排序；原实现返回较早的身份在前。独立 Node 执行结果同样显示小数秒文本的 `localeCompare` 小于整秒文本，证明 Web 比较器共享此问题。

## 排除的假设

- exact bits 已严格递增，根因不是时钟 allocator。
- 数据库没有漏写第二条记录，两个身份均持久存在。
- 与时区无关：两个字符串均为 UTC；差异来自小数位宽及字符串顺序。

## 根因与破坏机制

可变精度 RFC 3339 能解析为正确时刻，但它不保证普通文本顺序等于时间顺序。共享生产者和两个展示消费者没有约定稳定的文本编码，令合法时间值产生错误列表顺序。

## 根因修复

共享 `MutationTimeLayout` 固定 UTC 九位小数，所有领域 stamp 及其派生完成、结算、精选和删除时间都使用该编码；读取校验拒绝不符合 canonical 文本格式的 stamp。精确因果身份继续由原始 UInt64 bits 承载，展示文本不用于 CAS 或恢复身份。

## 验证结果

原始纯核心与真实 SQLite 用例由红转绿；JavaScript 用 `Notes.tsx` 相同的比较表达式读取实际 Store 投影，结果与服务端时间顺序一致。相关时钟、日结、延续及重启回归通过，提交待回填。

## 永久门禁

- `scripts/web/test-clock`：捕获相邻 Double instant 跨整秒时的文本顺序错误。
- `scripts/web/test-clock-storage`：真实领域捕获、SQLite 回读以及 ECMAScript 比较器对账。
- 两入口由 `scripts/web/check` 强制调用，fast 同时进入顶层 `make check`。

## 发行与回滚

Web schema 1 尚未发行，所有测试使用全新隔离 run。不得只在某一个页面补排序规则而保留不一致的其他生产者或消费者；回滚须同时恢复相匹配的投影与校验契约。

## 教训与永久约束

选择时间字符串作为展示排序键时，必须验证编码在边界值上的排序性质。普通日期样例不能替代整秒、小数尾零、相邻 exact instant 和相同墙钟的回归。

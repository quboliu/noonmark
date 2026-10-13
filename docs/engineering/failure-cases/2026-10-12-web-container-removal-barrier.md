# FAIL-2026-10-12-08：容器停止后过早复用名称使恢复门禁失败

- 状态：已修复
- 必需门禁：fast,symptom
- 首次发现：2026-10-12 晚间，America/New_York；隔离 E2E run `259c64b4-9dc2-41bb-b9ce-f4e15e7e5b41`。
- 影响版本／构建：Web 首轮未提交实现；source hash 前缀 `f2ff205b` 的测试编排。
- 引入提交：不存在；在未提交的首次测试编排中发现。
- Git author／committer：尚未形成引入提交，没有对应 Git identity。
- 实际修改者：协作 session 可确认 `scripts/web/test-e2e.py` 初始编排由 root Codex agent 编写。
- 修复提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`

## 用户症状与影响

主浏览器流程通过后，重启验收试图用原名称重新创建容器。Docker 返回名称仍被占用，套件在重启阶段失败；没有向用户正式实例写入，也没有证据表明已提交任务丢失。

## 时间线

1. 首次编排使用 `docker run --rm`，以 `docker stop` 成功作为下一轮创建的条件。
2. 完整真实浏览器流程通过；紧接着的 start 得到 Docker 名称冲突。
3. 核对本轮资源，随后该容器及网络已经自动删除；排除另一个长期运行服务占用相同随机名称。
4. 增加以实际删除为条件的生命周期屏障；单元门禁与真实恢复门禁均通过。

## 复现与证据

入口为 `scripts/web/test-e2e`。真实输出先报告 primary browser 通过，再由 Docker 报告同一 run 的容器名称冲突。容器使用唯一 UUID、`--rm`、独立数据目录和 loopback 端口；停止的是本轮实例。

## 排除的假设

- 不是任务请求失败：primary browser 包含真实读写、双设备、草稿、丢失响应后的回执查询和加密备份下载，已成功。
- 不是共享生产容器名称：名称含独占 run UUID，后续核查该资源已消失。
- 不是需要扩大停止超时：`stop` 已返回成功，缺少的是异步 removal 完成条件。

## 根因与破坏机制

`stop` 的完成与 `--rm` 自动删除的完成不是同一个事件。退出后的 Docker metadata、名称和网络端点仍可能短暂存在；仅凭停止返回便重用名称形成竞态。

## 根因修复

捕获 `docker run` 返回的确切 container ID，日志读取和停止均针对该 ID。停止后查询 daemon 中该 ID 是否仍存在，只有成功查询为空才返回；daemon 请求失败、其他身份或删除超时全部失败。等待的是实际生命周期条件，不加入固定宽限 sleep、不改容器名掩盖旧资源，也不执行全局清理。

## 验证结果

删除屏障的停止后仍存在、daemon 故障、异常身份及未完成条件均通过。真实 daemon 上 primary browser、停止重建、原资料回读、备份恢复及恢复后回读全部通过，容器与网络均已清理。

上述修复已进入首个实现提交；完整运行证据见[预览验证记录](../../tasks/noonmark-web-self-hosted/verification.md)。

## 永久门禁

- fast：`scripts/web/test-container-lifecycle`，验证删除屏障和失败条件。
- symptom：`scripts/web/test-e2e`，在真实 daemon 上执行停止、重新创建、浏览器回读和加密恢复。
- 两者由 Linux `make check` 的 `scripts/web/check` 强制调用，并登记于 `gates.tsv`。

## 发行与回滚

仅影响尚未发行的测试编排；应用仍保留本轮事实。修复不能删除其他容器或资料。后续若回退，撤回该编排提交并保持恢复门禁失败可见。

## 教训与永久约束

生命周期协调以资源状态完成为边界，不能把停止进程当成释放全部容器资源；清理和重用都必须绑定本轮精确身份。

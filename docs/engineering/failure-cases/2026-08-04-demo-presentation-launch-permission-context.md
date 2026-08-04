# FAIL-2026-08-04-20：Demo 展示进程错误承载自动化权限

- 状态：处理中
- 必需门禁：fast,symptom
- 首次发现：2026-08-04 11:21 -04:00
- 影响版本／构建：`20d12b5373471b5980be0f9c9234c40106e9e9ef` 构建的隔离 Demo App
- 引入提交：`f36bd7d894ea6dc87f41d6af2becc0557f7e4587 feat(demo): 固化十天交互验收基线`
- Git author／committer：`quboliu <38942505+quboliu@users.noreply.github.com>`／`quboliu <38942505+quboliu@users.noreply.github.com>`
- 实际修改者：未知；Git identity 不能证明实际操作者
- 修复提交：待回填

## 用户症状与影响

`make test-demo-fixture` 通过后，用户入口 `make run-demo-app` 重建同一个稳定签名 Demo，却在 fixture 就绪前返回 `eventAccessUnavailable` 并退出，无法留下可体验 App。测试入口的绿色结果因此没有覆盖真实的 LaunchServices 启动权限上下文。

## 时间线

- 2026-07-24：`f36bd7d8` 让 `run-demo-app` 通过 LaunchServices 打开 App，同时把 `--interactive-demo-fixture` 自动化参数交给最终展示进程。
- 2026-08-04：Demo 改为稳定 Apple Development 签名并加入 CG event-posting 权限请求；直接执行的验收入口转绿。
- 2026-08-04 11:21：最终交付尝试运行 `make run-demo-app`，LaunchServices 进程返回 `eventAccessUnavailable`；相同源码和签名的直接执行验收此前通过。
- 2026-08-04：对比两个脚本，确认唯一关键差异是 fixture 自动化由测试宿主直接启动，还是由 LaunchServices 最终展示进程承担。

## 复现与证据

先运行 `make test-demo-fixture`，真实鼠标键盘路径、SQLite 与 sidecar 对账通过。随后运行 `make run-demo-app`，入口返回：

```text
interactive demo fixture did not become ready
{"error":"eventAccessUnavailable","status":"failed"}
```

失败构建的签名仍为 `app.noonmark.mac.demo`、Team ID `7436PPJ79X`，designated requirement 绑定稳定 Apple Development 证书，排除再次退回 ad-hoc 签名。

## 排除的假设

- 不是 fixture 数据错误：自动化尚未开始领域重放，失败发生在 WindowServer input driver 初始化。
- 不是签名漂移：失败 App 的 identifier、Team ID、Authority 与已通过验收的 Demo 一致。
- 不是 production 身份或资料：两个入口都固定 reset 并使用 `demo` profile 与仓库内隔离数据根。
- 不是产品交互代码回归：同一提交的直接执行验收完整转绿。

## 根因与破坏机制

直接执行的测试进程与 LaunchServices 启动的 App 不处于同一 TCC 事件投递上下文。旧入口把“安装、物理验收 fixture”和“留给用户浏览”塞进同一个 LaunchServices 进程，迫使最终展示 App 自己取得自动化权限；测试入口却由已有权限的测试宿主直接启动，因此形成假绿色。

## 根因修复

- `run-demo-app` 先直接启动固定 `demo` installer，完成真实领域重放、WindowServer 交互、截图、manifest、SQLite 与 sidecar 对账。
- installer 就绪后明确终止并释放数据 lease；随后由 LaunchServices 重新打开同一稳定签名 App，但不传 `--interactive-demo-fixture` 或 result URL，只读取已验证资料并进入飞光。
- `test-interactive-demo-fixture` 在原有对账后执行相同的终止与 LaunchServices 纯展示重开，并要求进程稳定存活。

## 验证结果

- 待重跑 `scripts/test-runtime-profile-isolation`。
- 待重跑 `make test-demo-fixture` 与 `make run-demo-app`。
- 待重跑完整 `make check`。

## 永久门禁

- fast：`scripts/test-runtime-profile-isolation`，由 `scripts/check` 强制调用，要求 installer PID 生命周期、LaunchServices 展示入口及唯一 fixture 参数边界。
- symptom：`scripts/test-interactive-demo-fixture`，由 `scripts/test-all` 强制调用，真实安装年度 fixture 后终止 installer，再以 LaunchServices 无自动化参数重开并检查稳定存活。

## 发行与回滚

故障只发生在隔离 Demo，production App 未启动，production 资料未读取。若两阶段启动不能通过，停止开放 Demo 体验入口并回退本次脚本变更；不得把 fixture 自动化塞回展示进程，也不得要求用户为日常浏览授予自动化权限。

## 教训与永久约束

自动化 installer 与用户展示进程属于不同职责和权限边界。测试宿主能投递事件，不等于 LaunchServices 打开的 App 也能；绿色门禁必须覆盖最终启动方式，展示进程不得携带只为验收服务的自动化参数。

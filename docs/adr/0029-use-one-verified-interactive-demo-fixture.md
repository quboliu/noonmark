# ADR 0029：以单一可验证 fixture 驱动交互式演示

- 状态：已接受
- 日期：2026-07-24

## 背景

功能快速迭代时，开发者过去会打开空库、`--ephemeral` 截图数据或临时手工灌数给用户体验。三种状态都不能代表普通用户持续使用后的真实中段形态：页面可能是空的，跨日轨迹不足，烛龙没有历史产物，手工数据也无法证明经过领域约束和持久化。

现有 `NoonmarkStore.seed()` 主要服务局部截图与 E2E。直接扩大它会改变大量既有场景的视觉和数量基线，也会继续把“测试数据”和“交互体验数据”混成同一个职责。

## 决策

1. 新增 `NoonmarkDemoSupport` 深模块，作为十天任务用户故事、领域重放和语义覆盖报告的唯一事实源。
2. fixture 只调用 `NoonmarkEngine` 的公开领域 mutation，不直接拼装 snapshot。这样延期、延续、回池、变更、废弃、置顶、子任务、分类与复盘都必须通过生产约束。
3. 真实 App 通过内部专用自动化安装 fixture：
   - 使用固定自然日、locale 和时区；
   - 使用显式隔离 SQLite 数据根；
   - 完整 snapshot 安装走 SQLite repository，不伪装成一次用户同步 mutation；
   - 烛龙会话写入加密 sidecar；
   - 写入后从两个 repository 精确回读。
4. `NoonmarkDemo.app` 与 E2E 共用内部 bundle 身份，只为复用已经封闭的内部参数策略。生产 `Noonmark.app` 不接受演示参数。
5. `make run-demo-app` 成为快速迭代期间的默认人工体验入口；`make test-demo-fixture` 成为无外部凭证的真实 App 自动探针。
6. 覆盖报告以页面数量、状态集合和能力事实等语义为准，不以随机领域 UUID 或数据库字节为准。
7. fixture 中的烛龙历史会话必须使用本次 App 运行时生效的 Provider 身份授权，不得制造一个与运行配置无关的固定身份。演示安装只有在领域判定的非预期重授权数量为零，并且真实会话视图中阅读范围确认操作区不可见后，才可返回 `ready`。

## 后果

- 用户每次体验都从相同的十天中段故事开始，同时仍可自由修改真实数据。
- fixture 生成、自动断言和真实 App 写入共享同一任务事实源，减少脚本与产品状态漂移。
- 烛龙历史会话与它创建的任务可以同时出现，不再靠互不关联的 UI 假数据。
- 演示历史不会因 fixture 接收方与当前 Provider 不一致而阻塞；用户真实改变远程 endpoint、本地／远程性质或扩大范围时仍遵循生产重授权规则。
- 原有 `seed()` 和截图 E2E 保持稳定；新增产品状态时需要显式更新演示覆盖契约。
- 演示安装不会生成逐 mutation 的同步变更日志，因此该数据根只可用于隔离交互体验，不能当成同步测试输入。同步继续由专用 live／E2E 验证。

## 被否决的替代方案

- 扩大原有 `--ephemeral` seed：会破坏既有视觉基线，也没有 SQLite 与 sidecar 重启证据。
- 在 shell 中直接写 SQLite：绕过领域规则和 schema repository。
- 每次手工创建任务：不可重放、不可审查，也无法强制后续功能维护覆盖。
- 把 demo 参数开放给生产 bundle：扩大了内部数据替换能力的攻击面。

## 验证

- `NoonmarkDemoSupportTests` 验证十天连续日期、五大页面、任务／子任务边界状态和语义报告确定性。
- `scripts/test-interactive-demo-fixture` 构建并启动真实 `NoonmarkDemo.app`，验证 ready manifest、SQLite 文件、四份加密会话，并自动打开延期模式复盘会话确认阅读范围操作区不可见。
- App 自动化在返回 ready 前精确回读 SQLite snapshot 与全部 sidecar session。
- 人工验收通过 `make run-demo-app` 打开同一产物，直接体验 Day Todo、各任务池、未来计划、日历和烛龙。

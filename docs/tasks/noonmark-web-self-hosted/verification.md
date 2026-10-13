# 首个个人实例预览验证记录

- Task-ID：`noonmark-web-self-hosted`
- 日期：2026-10-13。
- 实现提交：`23f80d91daf2ed5dfb6d74afe761c1f7d967d9d7`。
- 被测源码内容指纹：`b4badff1da59ced8c2c2a6b0189f1d48b2b4d9572b8fa6522b5c9aa1b5c2a110`。
- 实际结果：Linux `make check` 完整执行，退出码 **0**；不是仅把分段结果拼成成功。

## 已完成的运行证据

| 门禁 | 实际结果 |
| --- | --- |
| 外置路径与只读源码 | 11 项 workspace 测试通过；源码无真实产物目录，构建通过只读挂载执行 |
| 文件系统 | 当前 virtiofs 的跨进程 flock、目录 fsync、未提交事务崩溃回滚及已提交 WAL 进程崩溃存活通过 |
| Go | `go vet` 与四个 package 的完整 `go test -race -count=1` 通过；包括 365 天重放、并发幂等、原子回滚、锁、时区与恢复 |
| 前端 | TypeScript 与 Vite 构建通过；应用 JS 243.55 kB，gzip 76.77 kB；未据此宣称满足完整性能 SLO |
| 真实镜像 | 构建 `noonmark-local:b4badff1da59-14b09dc8`，镜像 ID `sha256:fe912b55a2220b132f120f7393ef29cb9e208252e3ea4263b04d20b28a146a77` |
| 焦点 | 真实 Chromium 验证异步草稿就绪、首次聚焦、提交失败后不抢焦点及编辑记录路径 |
| 操作与网络 | 真实登录、中文 composition 事件、父子任务、飞光、精选、复盘、双设备刷新、断线草稿、丢失响应后的 receipt 核对通过 |
| 持久化与恢复 | 服务停止重建后回读通过；浏览器下载的 age 备份由真实 CLI 恢复，再通过浏览器读取并对账 SQLite；旧 epoch 与会话被隔离 |
| 一年交互演示 | 365 天、365 篇复盘、364 个锁定日、24 种命令每季度至少 3 次；60 条今日待完成、12 条池内任务、3 条精选；长页面速记实际新增一条并回读 |
| 故障闭环 | 本轮 9 个故障的原始运行症状转绿；故障门禁登记校验共 120 案例通过 |

一年演示初始化 sequence 为 `2397`；浏览器真实新增后为 `2398`，chain 数从 `519` 到 `520`。演示报告的 `creation_days=365` 同时对账创建时间覆盖，不能只靠显式 date 字段伪装一年历史。

## 证据索引

本机证据全部位于 `.work` 指向的外置根；以下为其下的相对位置，不提交数据库、密码、备份或截图到源码树：

- 总入口：`runs/audit/01766d45-8dcb-4085-a368-c5fd8ddfb566/reports/final-check.log`，同目录 `final-check.exit` 为 `0`。
- Go／镜像：`runs/audit/14b09dc8-6702-4024-bf8b-df69f65e83c6/reports/`；build manifest 位于 `builds/<上述源码指纹>/14b09dc8-6702-4024-bf8b-df69f65e83c6/manifest.json`。
- 焦点：`runs/e2e/ba0af969-ae2b-4397-a9fc-7fe8154c6c7f/reports/playwright-focus.json`。
- 容器及恢复：`runs/e2e/6b4093a8-29bd-4862-8aae-7c59b34179c7/reports/e2e.json`，以及分阶段 Playwright 报告、截图与 typed 服务日志。
- 一年演示：`runs/demo/31d922e3-2912-4757-a068-bb6bf49dafd4/reports/demo.json`、`demo-browser.json`、`demo-browser-evidence.json` 与 `screenshots/`。

本轮临时容器、网络及演示服务均已退出；成功和失败证据按独立 run 保留。本次没有启动或读取原生 production，也没有访问 iCloud。

## 证据边界与下一步

环境为 Linux arm64、Go 1.27.0、Node 22.22.3、rootless Docker 与真实 Chromium。镜像默认 UID 为 65532；本机容器验收使用 namespace UID 0 映射宿主普通用户，并启用只读 rootfs、cap-drop 与 no-new-privileges，不能把它描述为容器内非零 UID 验证。

上述文件系统结果不证明物理断电持久性或任意 NAS 挂载兼容。尚未执行 macOS App、Swift 跨引擎对账、Mac format 7 互通、多架构发行、负载 SLO、渗透测试或正式升级迁移验证。

UI 功能路径通过不等于原生还原完成。[UI 还原审查](ui-parity-review.md)仍判定差距明显；下一轮优先落实当前原生契约的工作区栏位、日期 strip、行内新增、复盘与任务行层级。重复计划、分类、附言、ChangeTrace、AI 和数据包互通继续按能力对等门禁推进，本预览不标记为商业 GA。

# FAIL-2026-10-31-01：原生构建入口没有落实外置产物边界

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-10-31
- 影响版本／构建：源码提交 `83e9aedd6003632b26b26b80808e132e1187ebc5`
- 引入提交：`48624929578bf67a9478f160680bc2845c1fb2a5`，`chore(workspace): align generated-state boundaries`；该提交确立外置规则，但既有原生脚本未同步迁移。裸 SwiftPM 构建语句可追溯至 `72d22c770e637888d43ebd2e0393eee0bb6c71a5`。
- Git author／committer：上述提交记录均为 quboliu；Git identity 不证明实际操作者。
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

在新的 macOS 开发环境核对完整编译时，发现 `make build`、三个 builder 与打包调用链仍使用源码内 `.build`、`dist`、`artifacts`。这与已经声明的外置产物规则冲突；仅修改 App builder 会进一步导致调用方无法定位产物。

## 时间线

- 初始源码经显式外置参数完成 Debug（含测试目标）与 Release 编译，证明问题在脚本路径契约而非 Swift 源码无法编译。
- 核对 Makefile、builder、运行调用方和证据约束，确认硬编码路径与源码／产物根混用。
- 在隔离 macOS VM 中实施公共目录配置、调用链和回归门禁。

## 复现与证据

原始 `scripts/build-mac-app` 使用裸 `swift build`，随后从 `.build/arm64-apple-macosx` 猜测二进制位置，并写入 `dist`。原始 Makefile 的 build target 同样不传 scratch path。新 fast gate 对这些旧语句判红；修复后的实际 builder 门禁要求所有可执行产物位于外置根且源码目录无新增产物。

## 排除的假设

- 原始 Swift 源码可以在有效工具链上编译，不需要修改 App 业务逻辑。
- 修改 `.gitignore` 或创建兼容软链接不能满足真实内容外置要求。
- 只修改 builder 返回值不足以修复丢弃 stdout、自己拼接路径的调用方。

## 根因与破坏机制

目录规则只更新到文档，没有形成统一可执行边界。编译路径、bundle 路径与证据根各自硬编码；将外置产物继续按源码根验证又会触发合法的路径拒绝。

## 根因修复

统一外置目录初始化和 SwiftPM 包装器；builder 查询实际 bin path；调用方消费同一组路径；产物校验保持原有严格物理边界并使用 BUILD 根，Git 源码证据仍使用源码根。同步 CI 上传和发布路径，不降低签名、身份隔离或清单校验要求。

## 验证结果

实际外置 Debug 构建（含测试目标）、开发版 App、安装测试程序及窗口探针全部通过，源码目录没有新增产物；严格签名与系统图标校验通过。原始 Release 编译通过。38 项诊断 fixture／锁测试、路径守卫、OCR 绝对／相对含空格路径、runtime isolation、完整 DMG 证据矩阵与 3 个 workflow 语法验证通过。完整检查复验中；修复提交待确定后回填。无 production App 执行、无真实 iCloud 写入。

## 永久门禁

- fast：`scripts/test-build-workspace`，由 `scripts/check` 强制执行。
- symptom：`scripts/test-build-workspace-build`，由 `scripts/test-all` 强制执行真实构建。
- release：`scripts/test-build-workspace`，由 `scripts/package-dmg` 在打包前强制执行，拒绝回到旧 builder 路径。

## 发行与回滚

本次不发行 App。提交前验证精确工作树；后续发行继续执行原有稳定签名、DMG 静态与受控派生验证。回滚必须同步回滚生产者、消费者、CI 路径和清单约束，不能只回滚一个 builder。

## 教训与永久约束

源码根和产物根分别表达，不能为了迁移目录扩大安全约束根。路径策略变更必须覆盖真实构建、所有直接消费者及可移植清单语义。

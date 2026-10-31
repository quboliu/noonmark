# noonmark-native-build-workspace

- Task-ID：`noonmark-native-build-workspace`
- 风险等级：A
- 状态：编译与针对性回归通过，完整检查及提交进行中

## 需求与范围

在现有 macOS Tart VM 验证 Noonmark 完整编译，修复与仓库外置产物规则冲突的原生构建入口，并按用户指示 commit 和 push。此任务不发行 App，不建立 release tag，不更改业务逻辑或用户资料。

## 方案与影响

统一 `NOONMARK_BUILD_ROOT`、SwiftPM 输出目录和产物消费路径，保持源码身份与产物清单各自的约束根。同步 builder、运行及测试脚本、DMG 清单与 GitHub Actions 路径。修复 XCTest 辅助程序定位和系统图标呈现门禁。细节见 `docs/engineering/native-build-workspace.md` 与失败案例 FAIL-2026-10-31-01、FAIL-2026-10-31-02。

## 验证与边界

原始源码的 Debug（包含测试目标）与 Release 编译通过。实际开发版 App、安装测试程序、窗口探针均在外置目录生成，源码目录未新增产物；开发版 App 严格 ad-hoc 签名与图标门禁通过。锁与诊断相关 38 项测试通过。完整 `scripts/check` 运行中，最终结果在提交前回填。

VM 无 Apple Development 签名证书，稳定签名预检明确失败，因此不宣称真实 UI E2E、腾讯输入法、受控 DMG 安装或发行全集已通过。不降低签名门槛、不建立伪造证据。编译及脚本修复按用户明确授权提交；分发验证需具备对应证书与交互环境后另行执行。

## 回滚

路径迁移应整体回滚生产者、消费者、CI 与清单约束，不能只回滚 builder。图标回滚会恢复该系统上的误报；不得以删除门禁或增加容差作为替代。

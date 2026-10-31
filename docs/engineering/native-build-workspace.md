# 原生构建目录

所有原生编译、App bundle、DMG、辅助工具及验证证据使用 `NOONMARK_BUILD_ROOT`。默认值为当前账号的 `$HOME/BUILD/projs/noonmark`，其他机器可显式指定绝对路径。源码 checkout 必须与该目录完全分离；不建立 `.build`、`dist` 或 `artifacts` 兼容软链接。

```bash
export NOONMARK_BUILD_ROOT="$HOME/BUILD/projs/noonmark"
make build
make build-app
scripts/swiftpm build -c release
make test
```

目录布局：

| 子目录 | 用途 |
| --- | --- |
| `swiftpm` | SwiftPM scratch 与编译后的二进制 |
| `cache`、`config`、`security` | SwiftPM 共享状态 |
| `module-cache` | Swift / Clang 模块缓存 |
| `tmp` | 工具和测试的临时文件 |
| `tools` | 固定版本的开发工具 |
| `dist` | App、DMG、dSYM 和发布静态证据 |
| `artifacts` | 辅助工具、测试结果与运行证据 |

`scripts/build-workspace-common` 在任何构建前验证根路径，拒绝相对路径、根目录、路径穿越、符号链接祖先，以及与源码目录的包含关系。SwiftPM 命令统一经过 `scripts/swiftpm` 或 `noonmark_swift`，显式传入 scratch/cache/config/security 路径；不得用额外 SwiftPM 路径参数覆盖约束。多个并发 checkout 应分别指定独立构建根，避免共享证据或清理彼此的产物。

构建脚本使用 `--show-bin-path` 定位编译器实际输出，不假设 CPU 架构或 SwiftPM 的内部目录布局。构建与打包不会启动 App，也不会 reset 运行数据。开发和测试 profile 的资料、iCloud append-only 规则及稳定签名要求保持原有约束。

源码证据继续从真实 Git checkout 获取。产物 inventory 与符号文件的约束根改为 BUILD；清单中的 `dist/...`、`artifacts/...` 是相对于 BUILD 的逻辑路径，不能拼回源码目录。校验不得通过扩大到整个 home 或文件系统根来接受外置文件。DMG checksum 使用 basename，与下载的 DMG 放在同一目录即可校验；发布 workflow 不得在清单生成后重新写入 checksum。

GitHub-hosted CI 使用 runner 临时目录中的独立构建根，上传步骤与发布步骤使用同一配置。签名资料仍由原有发布流程提供，不把开发者凭证写入 VM 母机或仓库。

## 回归入口

- `scripts/test-build-workspace`：路径拒绝、带空格参数边界、SwiftPM 路径覆盖拒绝及 builder 接入检查。
- `scripts/test-build-workspace-build`：实际构建源码、测试目标、development App、DMG harness 与 WindowProbe；验证签名、产物位置与源码目录未被修改。
- `scripts/check`：既有静态、Swift 测试和工具门禁。
- `scripts/test-dmg-evidence-contract`：打包、清单与篡改拒绝 fixture；不执行 production App。

专用 E2E 的 preferences-clock 与 diagnostic-closure 同步 fixture 继续使用原有 `/private/tmp/noonmark-e2e-…` 协议及严格所有权／路径守卫；它们属于隔离运行资料，非构建产物。不要只移动脚本路径而破坏 App 与清理守卫的共同协议。

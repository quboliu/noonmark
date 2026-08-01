# 以签名运行身份隔离数据并拆分 DMG 验证

**Status**: Accepted

晷迹的旧开发入口、测试入口和 DMG 安装验收会在构建阶段隐式执行同一个 `reset-dev-data`，而该脚本拥有正式 `Application Support/noonmark`、iCloud Drive `Noonmark/SyncRepository`、正式 bundle preferences 和烛龙 sidecar Keychain service。E2E 与 Demo 虽可用启动参数重定向 SQLite，App 内的 iCloud Drive transport 仍会解析正式默认仓库；开发构建也继续使用正式 bundle identity。这使“构建或验证”本身可能停止正式 App、清除正式数据或把测试记录写入正式同步端点。

当前发布只面向指定用户自行下载和安装的 Apple Development 签名私有 DMG，不进行公开分发，也不把 Developer ID、notarization 或 staple 作为本轮门禁。开发与测试在任何环境都不得启动 production 身份，也不得读取、定位、探测或 reset production 数据；production App 只由用户在明确安装后的日常使用中启动，不属于自动化验证范围。

## Decision

- 新建唯一的强类型 **运行时数据范围**。签入 bundle 的 exact identifier 是唯一权限来源，并同时决定 executable identity、Application Support 根、iCloud Drive repository name、Provider Keychain service、sidecar Keychain service、UserDefaults／cache／saved state identity 和内部启动参数权限。build configuration、环境变量和启动参数都不能把未知或非正式身份提升为 production；缺失、未知和 lookalike bundle identity 必须 fail-closed。
- 固定六个互不重叠的 profile：`production`、`development`、`e2e`、`demo`、`audit` 与 `dmg-validation`。production 唯一保留 `app.noonmark.mac`、`noonmark`、`Noonmark/SyncRepository` 和现有正式 Keychain services；其他五个 profile 分别使用 `noonmark-development`／`Noonmark-Development`、`noonmark-e2e`／`Noonmark-E2E`、`noonmark-demo`／`Noonmark-Demo`、`noonmark-audit`／`Noonmark-Audit` 和 `noonmark-dmg-validation`／`Noonmark-DMGValidation` 独立本地及 iCloud 顶层范围，并拥有唯一 bundle、process、UserDefaults／cache／saved state 与 Keychain services。Demo 不再借用 E2E identity；只有 E2E 与 Demo 可见其 fixture 所需的内部启动参数。
- shell 与 Swift 各有一个 profile 映射深模块，并以契约测试逐字段对账。调用方只能传固定 profile 名，不能提供任意待删除路径。映射更新必须同时通过 exact literal、pairwise distinct、production preservation 和 bundle `Info.plist` contract；不能以约定或代码评审代替可执行对账。
- `scripts/reset-dev-data` 必须显式接收一个非正式 profile。缺参数、production、别名、未知 profile、目标与 production 相等或互为祖先／后代、任一目标或祖先为 symlink、HOME 不是当前账户 canonical home，以及对应进程无法确认终止时全部在任何删除前 fail-closed。它只终止所选 profile 的 exact process，只删除该 profile 固定拥有的数据、整个 iCloud 顶层根、preferences、cache、saved state 和 Keychain services；因此上轮异常退出的 live test sibling repository 也不会残留。production 常量只参与纯字符串边界判定；需要 canary 时只能在 `mktemp` HOME 建立 synthetic fixture，真实 production 目标永不进入探测、终止或删除计划。
- build 与 package 是纯产物操作，不 reset、不启动 App、不读取用户数据。会运行 App 的开发、E2E、Demo、Audit 和 DMG validation 入口必须在运行前显式 reset 自己的非正式 profile。每个测试套件只能保留本轮在其独立根内创建的 fixture；下一轮由同 profile reset 重建。
- 正式 DMG 门禁只执行 checksum、只读挂载、strict code-sign、Info／Version／Build／Commit／Build Date、Mach-O UUID、dSYM、binary SHA 和 source-linked SHA 对账，并明确证明 `production_app_executed=false`。当前账户不启动 mounted、copied 或 installed production App，也不定位正式数据库或 iCloud root。
- 需要 WindowServer、SQLite 写入与重启的交互验收只运行 `app.noonmark.mac.dmg-validation`。validation App 必须从刚完成静态验证的精确 packaged production App 受控派生，而不是重新编译另一份源码；先证明派生前 package 与 mounted production bundle 完全一致，再只允许 bundle／executable display identity 和重签名造成的声明 delta。manifest 绑定 package manifest SHA、DMG SHA、派生前 executable SHA、Version／Build／Commit／Build Date、Mach-O UUID、dSYM 和 source-linked SHA，并证明 validation bundle 启动前后稳定。
- 不同 bundle identifier 的重签会改变 CodeDirectory、CMS 和 designated requirement。因此交互证据只能声明“精确 packaged code 的受控 validation 派生在隔离 profile 通过真实交互”，不得声明“精确 production signed bundle 已运行”。production LaunchServices、TCC、默认数据根和 iCloud 既有资料路径不进入开发／测试验证；它们只在用户自行安装并明确启动后的日常使用中自然覆盖，自动化不得为取得更强结论而触碰。
- 本 ADR 取代 ADR 0025 中“install evidence 必须启动并对账 copied production App”的部分，也取代 ADR 0042 旧版“真实 DMG 安装验收必须主动产生受控 `.ips`”的门禁：production DMG 保留静态可追溯证据，重启交互和 DiagnosticReports 差分只来自 `dmg-validation` 派生；真实 `.ips` 只接受用户日常使用中自然产生并主动提供的原件，不由测试伪造或强制 production crash。其余 source、binary、dSYM 和诊断证据约束继续有效。

## Considered Options

- 只修改 reset 的本地目录：不能阻止 App 内默认 iCloud transport、Keychain、UserDefaults 或 DMG harness 继续使用正式身份。
- 继续以 `--data-url` 隔离测试：参数只重定向 SQLite，不能成为 iCloud、Keychain、cache 或 saved state 的权限边界，也不能保护遗漏参数的启动。
- 在当前账户启动 production DMG，但先导出或备份数据：备份不能消除误停止、误删 Keychain、iCloud 回灌和同步端点改写风险，也违反不触碰真实资料的约束。
- 重新编译一个 validation App：可以隔离数据，但不能把交互证据绑定到已经封装进 DMG 的 exact Mach-O；受控派生保留更强的 package-to-runtime 证据边。
- 暂停全部 DMG 交互验证：风险最低，但会失去真实 AppKit／WindowServer／SQLite 重启证据。隔离 validation profile 在不接触 production 的前提下保留这条能力，并准确披露证据边界。

## Consequences

- 开发、测试、演示、审计和 DMG 验收即使遗漏 `--data-url`，也只能进入自己的固定本地与 iCloud 范围；测试不能再通过普通构建或 reset 影响用户正在使用的正式 App。
- production 常量仍存在，但只能由 exact production bundle profile 选择。新 profile 需要同时维护 Swift、shell、bundle metadata 和契约矩阵；这是把删除权限与同步写入权限收敛到可审计边界的必要成本。
- 当前发布可生成供用户自行安装的 Apple Development 签名 DMG，但不会宣称公开分发、Developer ID、notarization、Gatekeeper 或 production runtime 自动验收已经完成。
- 用户可按既定计划自行删除正式同步目录并导入已导出的 canonical JSON；开发与测试工具既不代替用户执行，也不读取、备份或迁移该正式资料。

## Risk And Rollout

- 风险等级：P。主要风险是 profile 漏接某个数据资源、shell／Swift 映射漂移、reset 越过目录所有权、symlink 竞态、非正式 App 继续写正式 iCloud，以及把 validation 派生误报为 production runtime。
- 灰度：先让纯 Swift 与纯 shell fixture 证明 exact mapping、互斥、synthetic production canary、symlink／process failure；再 build 隔离 development／E2E／Demo／Audit bundle；随后运行隔离 App E2E 与 `dmg-validation` 交互；最后只读生成、挂载和验证 production DMG。开发与测试永不执行 production runtime 阶段。
- 监控：每份 evidence manifest 记录 runtime profile、bundle identifier、local／iCloud logical scope、reset target、source tree、binary SHA、UUID、签名 identity 和 `production_app_executed`。纯 fixture 测试只在 `mktemp` HOME 内建立 synthetic production canary，绝不读取真实 production 目录；profile 不一致、默认 production literal 出现在非正式调用链、synthetic canary 改变、reset 无显式 profile、`production_app_executed` 非 false 或 validation manifest 缺派生绑定均阻断发布。
- 回滚：可回退 App 与脚本并停止发布候选，但不得恢复旧的 production-owning reset，也不得用 production identity 继续开发验证。必要时只关闭非正式 App 运行和 DMG 交互，保留纯构建、正式静态验证及用户数据原状；不迁移、不清除、不重写任何 production SQLite、iCloud 或 Keychain 资料。

## Verification

- Swift 测试逐字验证六个 bundle identifier、Application Support 目录、iCloud repository 和两类 Keychain service；所有集合 pairwise distinct，production 唯一不可 reset，未知／缺失／lookalike identity 拒绝，只有 E2E 与 Demo 获得内部参数。
- shell 故障注入矩阵在 `mktemp` HOME 与 stub 系统命令中验证：缺失／production／未知 profile、目录重叠、leaf 或祖先 symlink、非 canonical HOME、进程无法终止、defaults／Keychain 命令失败全部 fail-closed；每次只清选中 profile，production 与其余 profile canary byte-for-byte 保留。
- 静态门禁证明 build、package 和正式 DMG verification 不含无参数 reset、production App launch 或正式数据库解析；每个运行入口显式声明自己的非正式 profile，live iCloud E2E 只使用 `Noonmark-E2E/LiveTests/<UUID>`，下一轮 E2E reset 会删除整个 `Noonmark-E2E` 根。
- 隔离真实 `.app` 验证必须以 SQLite、日志、进程身份与 iCloud logical path 探针证明实际使用声明的非生产 profile，并在重启后回读；只有 `mktemp` HOME 内的 synthetic production canary 可以在 suite 前后对账，真实 production 根不得被 probe。
- DMG contract 拒绝 production runtime manifest、未声明的 derivation delta、错误 bundle／UUID／dSYM／release identity、缺 package／DMG binding、启动前后 binary 变化及 `production_app_executed` 非 false。最终 production DMG 只读挂载验证与 `dmg-validation` 交互证据分别报告，不合并成更强结论。

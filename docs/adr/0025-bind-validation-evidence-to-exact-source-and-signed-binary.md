# 把验收证据绑定到精确源码与签名二进制

**Status**: Accepted

晷迹的真实 App E2E、data-root writer lease、DMG 打包与安装验收会跨多个脚本、进程和产物目录运行。若 targeted run 保留旧截图，或 manifest 只记录最终 exit 0，后续就可能把旧 binary 的产物误归给当前源码。验证结论因此不能只依赖文件存在、截图时间或单一成功状态，而必须把源码、签名 binary、场景和本轮新鲜产物连接为可对账的证据链。

ADR 0043 已取代本 ADR 原先要求安装验收直接运行 copied production App 的部分。开发与测试不得启动 production 身份，也不得读取、定位、探测或 reset 用户的 production 数据范围；当前证据链把 production DMG 静态验证与受控派生的 `dmg-validation` 动态验证明确分开。

## Decision

- `scripts/evidence-common` 是 validation evidence 的唯一深模块。调用方只声明 suite、run ID、configuration、mode、filter、scenario set、bundle 与允许的 artifact root；Git tree、签名解析、digest、原子 manifest、fresh inventory 和一致性检查全部封装在该 interface 内，不允许 E2E、lease、package 或 install 各自复制浅实现。
- 每个 suite 在任何 build 或旧产物可能失败前先清理自己拥有的 evidence root，再开始 manifest。manifest 只可经同目录临时文件写完并 rename 发布；缺 required field、半写文件、重复 key、路径越界、文件名包含换行或 finish 前验证失败都必须 fail-closed，不能留下 status 0。
- source snapshot 同时记录 `HEAD` commit、HEAD tree、工作区 tree 与 dirty 状态。工作区 tree 使用独立临时 `GIT_INDEX_FILE` 加 `git add -A`／`git write-tree`，必须包含 tracked、deleted 与 untracked 文件，且不得修改真实 index。suite 开始与结束的工作区 tree 不一致时不得通过。
- signed bundle snapshot 记录 bundle identifier、主 executable SHA-256、公开 leaf certificate SHA-1／SHA-256、TeamIdentifier、designated requirement digest 与 strict code-sign result。要求稳定交互签名的 suite 必须拒绝 ad-hoc、空 Team、缺 leaf certificate、可执行文件不唯一或中途被替换的 bundle；证据只能保存公开证书 fingerprint，不接触或输出私钥。
- full E2E 必须显式记录无 `ONLY`／filter 的 full mode、exact scenario set 和逐场景 ledger。10 个 populated English 场景必须全部来自同一 App executable SHA；Settings／Zhulong 只能声明其实际完成的截图、OCR 或页面 oracle，不能被描述为跨进程 AX 通过。targeted 与 screenshots-only run 可用于调试，但受保护 CI／发行验收一律拒绝把它们当 full evidence。
- runtime evidence 永久保留 DiagnosticReports baseline、final 与 diff，即使 diff 为空也不能删除；空 diff 是可复核的零新增证据，不是无证据。unified log 的默认 clean pattern 不因测试需要故意终止进程而放宽。
- intentional termination 使用独立 allowlist。允许项必须同时匹配 exact process／binary、PID、phase、signal 与 wait status；wrong PID、wrong signal、缺少预期退出或任何额外 crash report／failure log 都必须失败。data-root lease 的 `SIGKILL` 只能由这个窄接口声明，不能加入全局 regex 豁免。
- package manifest 绑定 release configuration、source tree、稳定签名 App、DMG SHA 与 checksum；verification 对只读挂载 App 执行 `codesign --verify --deep --strict` 并反查 identity、Team、designated requirement 与 executable SHA，但不得启动 production App 或解析其运行数据。动态 install evidence 只能运行从已经静态验证的 exact mounted package 受控派生并重新签名的 `app.noonmark.mac.dmg-validation`；manifest 必须绑定派生前 executable SHA、允许的 metadata delta、重签后 SHA、UUID／dSYM／release identity，并固定记录 `production_app_executed=false`。
- protected CI 与开发签名发行验收使用同一 `NOONMARK_EVIDENCE_RUN_ID`。cross-manifest validator 要求 writer lease、full E2E、package、verify 与 install 的 source tree、签名身份、Team、suite status 和二进制关系一致；关键 artifact 缺失时 workflow 使用 error，不得 ignore。
- evidence 只证明当前 Apple Development 签名的私有 DMG 路径。当前交付由指定用户自行下载和安装，不公开分发；VoiceOver 等人工辅助功能组合、CloudKit entitlement／两台物理设备 live 及任何未来公开发行能力都不能由同一 manifest 冒充完成。

## Considered Options

- 只在 manifest 增加 commit SHA：未提交与未追踪源码仍可改变 binary，不能证明实际工作区。
- 只比较截图修改时间：系统时间、复制和 targeted run 都能制造看似新鲜的文件，且无法绑定签名 executable。
- 每个脚本分别记录 checksum：字段与错误语义会漂移，无法证明跨 suite 的同一 run，也会把安全复杂度散落到多个调用方。
- full E2E 前统一删除整个 `artifacts/`：会破坏并行专项证据，且没有解决 source／binary／scenario 的归因问题。每个 suite 只能清理自己声明的 root。

## Consequences

- 任何最终绿灯都能回溯到精确工作区 tree、稳定签名 executable、exact scenario set 与 fresh artifact inventory；targeted 成功不能再借用旧截图。
- 工作区有大量未提交改动时，计算临时 tree 会增加少量 Git I/O；这是证明实际 build 输入的必要成本，不得退回 `git status` 文本或 HEAD-only 近似。
- manifest 与 cross-suite 校验会让 build 后修改源码、重签名、替换 binary 或残留旧 checksum 更早失败。调试 run 仍可执行，但必须准确标记为 filtered／targeted，不能被提升为 release evidence。

## Risk And Rollout

- 风险等级：P。主要风险是 manifest 自身半写、临时 index 污染真实 index、签名解析对多证书输出取错 leaf、调用方漏清旧产物，以及 intentional termination allowlist 过宽后吞掉真实崩溃。
- 灰度：先以纯 shell fixture 覆盖 dirty／untracked tree、真实 index 不变、missing field、binary replacement、ad-hoc／空 Team、stale artifact、空 diagnostic diff 与 exact termination tuple；再依次运行 `make check`、writer lease、full E2E、production package 静态 verify 和 `dmg-validation` 动态 install evidence，最后才启用 cross-manifest 私有 DMG gate。整个过程不运行或读取 production 数据范围。
- 监控：记录不含凭证的 suite／run ID、source tree、binary digest、identity fingerprint、Team、scenario count、artifact inventory digest、DiagnosticReports diff、派生绑定、`production_app_executed` 和最终 status。任何 tree／binary 变化、重复 evidence key、10 个 English 场景多于一个 SHA、额外 diagnostic、未声明 derivation delta、package 绑定不一致或 `production_app_executed` 非 false 都是阻断信号。
- 回滚：evidence-common、所有调用方与 cross-validator 必须整体 revert；不得只关闭 finish 校验、只保留 status 0 manifest，或让 workflow 在证据缺失时继续上传。回滚只影响验收基础设施，不回退已验证的领域／UI 根修，也不能恢复使用旧 artifacts 宣告完成。

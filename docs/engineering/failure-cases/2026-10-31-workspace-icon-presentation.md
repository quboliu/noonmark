# FAIL-2026-10-31-02：把系统呈现图标与原始 PNG 直接比较

- 状态：处理中
- 必需门禁：fast,symptom,release
- 首次发现：2026-10-31
- 影响版本／构建：源码提交 `83e9aedd6003632b26b26b80808e132e1187ebc5`，macOS 26.6.2（25G83），Xcode 27.1
- 引入提交：`74d7ea357388339760e2ec01afa46437c3a5b417`，`feat(brand): Use the final 01 logo as the app icon`
- Git author／committer：quboliu <38942505+quboliu@users.noreply.github.com>；Git identity 不证明实际操作者。
- 实际修改者：未知
- 修复提交：待回填

## 用户症状与影响

Debug／Release 编译成功，development App 完成严格签名后，`scripts/test-app-icon-bundle` 仍报 `images differ after RGBA normalization: 204962 pixels, max channel delta 255`，导致 App builder 失败。源图标素材门禁及 bundle 内 ICNS 字节校验均通过。

## 时间线与复现

在隔离 macOS VM 中构建 `NoonmarkDevelopment.app`，执行真实 `NSWorkspace.iconForFile` 解析并转存 PNG。随后独立创建最小、临时 ad-hoc 签名 App，只复制标准 ICNS、系统 `/usr/bin/true` 和最小 Info.plist，经相同 API 取图；从未执行该 App。

原始 master PNG SHA-256 为 `41fe772f396c4b5965a65257af1124a551df2dbd6158faf63ed112897dc28ada`；development App 与独立参考 App 的 NSWorkspace PNG SHA-256 均为 `3513370142fbf8cc50c20e8d919ee86dc33757310cc690492d240b9457443b1a`。目视确认原始标志主体一致，系统呈现包含不同的圆角／边缘效果。证据保存在外置 BUILD 日志及审计共享目录的 `icon-debug/{master,workspace,reference}.png`，不作为仓库资源。

## 排除的假设

- ICNS 损坏或打包遗漏：源素材门禁、精确字节比较、严格签名均通过。
- 返回通用图标或单个 App 的陈旧缓存：新建、独立身份的参考 App 与实际 App 返回 PNG 完全一致；参考 App 每次使用新 UUID。
- 色彩空间转换误差：原门禁已统一为 sRGB、预乘 RGBA；实际差异与系统边缘呈现相符。

## 根因与破坏机制

原门禁把未经系统呈现的 master PNG 当作 NSWorkspace 的逐像素 oracle。NSWorkspace 返回文件关联的图标，不承诺保留素材原始像素；本次机器上的系统呈现改变了边缘。Apple API 文档：<https://developer.apple.com/documentation/appkit/nsworkspace/icon%28forfile%3A%29>。边缘变换是本次实测结果，不是对所有 macOS 版本行为的假定。

## 根因修复

继续独立验证标准素材、Info.plist、bundle ICNS 字节和严格签名。在临时目录从标准 ICNS 创建独立签名参考 App，经同一系统 API 呈现后与目标 App 比较；仍要求零个不同像素，不提高容差。参考 App 不执行，结束时注销并清理。

## 验证结果

修复后真实 development App 的 `scripts/test-app-icon-bundle` 通过。回归脚本创建独立签名 App，正例执行完整 bundle 门禁；反例通过与正式门禁共享的真实 NSWorkspace 渲染和精确 RGBA 比较函数，对比标准签名 App 与普通文件夹图标，要求在像素比较时被拒绝。反例不能因读取图像或其它步骤失败而误通过。无 production App 执行、无真实 iCloud 写入。

## 永久门禁

- fast：`scripts/test-app-icon-presentation`，接入 `scripts/check`。
- symptom：`scripts/test-app-icon-bundle`，由 `scripts/build-mac-app` 对实际生成的 bundle 强制执行。
- release：`scripts/test-app-icon-bundle`，由 `scripts/verify-dmg` 对挂载镜像内的 bundle 强制执行。

## 发行与回滚

本次不发行 App。回滚会恢复合法图标在该系统上的误报，不应以删去门禁、跳过签名或增加像素容差应对。

## 教训与永久约束

素材正确性与系统呈现正确性需要独立 oracle；系统输出应与通过相同 API 的独立标准参考比较，同时保留精确素材与签名校验。反例必须真的走到呈现检查，避免测试只有正例。

---
status: superseded by ADR-0003
---

# Mac 首发采用 Flutter 本地优先架构

晷迹第一期先发布 Mac 端，但产品明确保留 iOS、Android、Windows 等跨平台路线，因此采用 Flutter + Dart 作为客户端主技术栈，而不是 SwiftUI、Electron 或 Tauri。核心领域规则应放在纯 Dart 领域层中，UI 层使用 Flutter Desktop，状态管理优先使用 Riverpod，本地持久化优先使用 SQLite/Drift，以便先验证 Mac 端核心体验，同时降低后续跨平台重写成本。

**Considered Options**

- SwiftUI：Mac 体验最原生，但后续 Android 和 Windows 基本需要重写。
- Electron：桌面生态成熟，但移动端路线不成立。
- Tauri：桌面体积和系统集成有优势，但移动端、Flutter 风格 UI 复用和后续小组件路线更绕。
- Flutter：跨平台路线最直接，适合把领域规则和 UI 分层后长期复用。

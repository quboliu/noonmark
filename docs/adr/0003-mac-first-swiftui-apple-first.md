# Mac 首发改用 SwiftUI

晷迹第一期改为使用 SwiftUI 开发 Mac 端，以优先获得更原生的 macOS 体验、系统集成能力和 Apple 平台设计一致性。SwiftUI 是第一期不可变技术约束；其他实现路线可以继续讨论，但不能推翻 Mac 端 SwiftUI 这个前提。这个决定替代 ADR-0001 的 Flutter 路线：后续跨平台不再默认依赖共享 UI 代码，而是先走 Apple-first 路线，未来非 Apple 平台需要另建客户端、通过共享同步协议衔接，或在产品验证后重新评估跨平台技术栈。

**Consequences**

- Mac 端技术栈优先为 SwiftUI + Swift，并以 Swift Package 承载核心领域规则。
- 后续 iPhone、iPad、Apple Watch 和 WidgetKit 路线更顺，但 Android、Windows 不能直接复用 UI。
- 本地数据和数据包格式必须保持平台无关，避免未来非 Apple 客户端被 SwiftUI 选择锁死。

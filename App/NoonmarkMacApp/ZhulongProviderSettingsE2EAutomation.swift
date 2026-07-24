import AppKit
import Foundation

struct ZhulongProviderSettingsE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-zhulong-provider-settings-ui"),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-zhulong-provider-settings-result-url"
              ), resultPath.isEmpty == false
        else { return nil }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        ZhulongProviderSettingsE2EUIInteractionDriver.start(
            store: store,
            resultURL: resultURL
        )
    }
}

/// Exercises the real Settings controls. The driver only reads the Store after
/// physical WindowServer events have passed through the visible native fields
/// and buttons; it never calls Provider-setting mutations itself.
@MainActor
enum ZhulongProviderSettingsE2EUIInteractionDriver {
    private static let model = "noonmark-e2e-mask-model"
    private static let syntheticAPIKey = "noonmark-e2e-mask-key"
    private static let maskedPlaceholder = "••••••••••••"

    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start() {
            Task { @MainActor [self] in
                do {
                    try await exerciseVisibleSettings()
                    finish("ok")
                } catch {
                    finish("failed: \(error.localizedDescription)")
                }
            }
        }

        private func exerciseVisibleSettings() async throws {
            let window = try await settingsWindow()
            try await activate(window)
            let input = try WindowServerInputDriver()

            try await selectSegment(
                1,
                input: input,
                in: window,
                identifier: "settings.zhulong.permission.data-reading",
                step: "任务数据读取改为每次询问"
            )
            try await waitUntil("任务数据读取权限没有改为每次询问") { [self] in
                store.zhulongFeaturePreferences
                    .conversationPermissionCeiling.dataReading == .ask
            }

            try await selectSegment(
                2,
                input: input,
                in: window,
                identifier: "settings.zhulong.permission.remote-sending",
                step: "远程发送改为禁止"
            )
            try await waitUntil("远程发送权限没有改为禁止") { [self] in
                store.zhulongFeaturePreferences
                    .conversationPermissionCeiling.remoteSending == .deny
            }

            try await click(
                input,
                in: window,
                step: "清空已有 Provider"
            ) { [self] in
                button(
                    identifier: "settings.zhulong.provider.clear",
                    title: store.copy.clear,
                    in: window
                )
            }
            try await waitUntil("Provider 没有被清空") { [self] in
                store.zhulongProviderDraft.enabled == false
                    && store.zhulongProviderDraft.hasStoredAPIKey == false
                    && store.zhulongProviderDraft.apiKeyInput.isEmpty
            }

            try await click(
                input,
                in: window,
                step: "启用 Provider"
            ) { [self] in
                control(
                    identifier: "settings.zhulong.provider.enabled",
                    in: window
                )
            }
            try await waitUntil("Provider 开关没有响应") { [self] in
                store.zhulongProviderDraft.enabled
            }

            try await replaceText(
                in: field(
                    identifier: "settings.zhulong.provider.model",
                    in: window
                ),
                with: ZhulongProviderSettingsE2EUIInteractionDriver.model,
                input: input,
                window: window,
                label: "Provider 模型"
            )

            try await replaceText(
                in: secureField(
                    identifier: "settings.zhulong.provider.api-key",
                    in: window
                ),
                with: ZhulongProviderSettingsE2EUIInteractionDriver.syntheticAPIKey,
                input: input,
                window: window,
                label: "Provider API Key"
            )

            try await click(
                input,
                in: window,
                step: "保存 Provider"
            ) { [self] in
                button(
                    identifier: "settings.zhulong.provider.save",
                    title: store.copy.save,
                    in: window
                )
            }
            try await waitUntil("保存后 API Key 没有以掩码留在输入框") { [self] in
                guard let apiKeyField = secureField(
                    identifier: "settings.zhulong.provider.api-key",
                    in: window
                ) else { return false }
                return store.zhulongProviderDraft.hasStoredAPIKey
                    && store.zhulongProviderDraft.apiKeyInput.isEmpty
                    && apiKeyField.stringValue.isEmpty
                    && apiKeyField.placeholderString
                    == ZhulongProviderSettingsE2EUIInteractionDriver.maskedPlaceholder
            }

            try await click(
                input,
                in: window,
                step: "清空已保存的 Provider"
            ) { [self] in
                button(
                    identifier: "settings.zhulong.provider.clear",
                    title: store.copy.clear,
                    in: window
                )
            }
            try await waitUntil("清空后 Provider Key 仍然存在") { [self] in
                store.zhulongProviderDraft.enabled == false
                    && store.zhulongProviderDraft.hasStoredAPIKey == false
                    && store.zhulongProviderDraft.apiKeyInput.isEmpty
            }
        }

        private func settingsWindow() async throws -> NSWindow {
            var resolved: NSWindow?
            try await waitUntil("原生 Settings 窗口") {
                let windows = NSApp.windows.filter {
                    $0.identifier == NoonmarkSettingsWindowController.windowIdentifier
                        && $0.isVisible
                        && $0.isMiniaturized == false
                        && $0 is NSPanel == false
                        && $0.parent == nil
                        && $0.attachedSheet == nil
                }
                guard windows.count == 1 else { return false }
                resolved = windows[0]
                return true
            }
            guard let resolved else {
                throw Failure.missing("原生 Settings 窗口")
            }
            return resolved
        }

        private func activate(_ window: NSWindow) async throws {
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            try await waitUntil("原生 Settings 窗口获得焦点") {
                NSApp.isActive
                    && NSApp.keyWindow === window
                    && window.isKeyWindow
                    && window.isVisible
            }
        }

        private func replaceText(
            in field: NSTextField?,
            with value: String,
            input: WindowServerInputDriver,
            window: NSWindow,
            label: String
        ) async throws {
            guard let field else { throw Failure.missing(label) }
            try await click(input, in: window, step: "聚焦\(label)") { [weak field] in
                field
            }
            try await waitUntil("\(label) 没有获得输入焦点") {
                guard let editor = field.currentEditor() else { return false }
                return window.firstResponder === editor
            }
            await settleTextInputFocus()
            try await waitUntil("\(label) 在下一事件循环失去输入焦点") {
                guard let editor = field.currentEditor() else { return false }
                return window.firstResponder === editor
            }
            let existingText = field.stringValue
            if existingText.isEmpty == false {
                try input.postKey(keyCode: 0, modifiers: .command)
                try await waitUntil("\(label) 没有完成全选") {
                    guard let editor = field.currentEditor() else { return false }
                    return editor.selectedRange == NSRange(
                        location: 0,
                        length: existingText.utf16.count
                    )
                }
            }
            try await typeText(
                value,
                into: field,
                window: window,
                label: label
            )
        }

        /// A physical key cannot arrive in the same AppKit event-loop turn as
        /// the click that focused its field. Yield one main-queue turn before
        /// posting WindowServer keystrokes so the E2E driver preserves that
        /// ordering without relying on a clock-based delay.
        private func settleTextInputFocus() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }

        /// The pointer enters the window through WindowServer. Text is then
        /// queued through AppKit one key at a time so the test remains neutral
        /// to the developer's active keyboard layout while exercising the
        /// field editor, binding, save, masking, and clear paths in the real
        /// app window.
        private func typeText(
            _ value: String,
            into field: NSTextField,
            window: NSWindow,
            label: String
        ) async throws {
            var expected = ""
            for character in value {
                try postAppKitText(String(character), to: window)
                expected.append(character)
                try await waitUntil("AppKit 键盘事件没有写入\(label)的字符") {
                    field.stringValue == expected
                }
            }
        }

        private func postAppKitText(_ text: String, to window: NSWindow) throws {
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let keyDown = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                characters: text,
                charactersIgnoringModifiers: text,
                isARepeat: false,
                keyCode: 0
            ), let keyUp = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp + 0.001,
                windowNumber: window.windowNumber,
                context: nil,
                characters: text,
                charactersIgnoringModifiers: text,
                isARepeat: false,
                keyCode: 0
            ) else {
                throw Failure.missing("无法构造 AppKit 文本键盘事件")
            }
            NSApp.postEvent(keyDown, atStart: false)
            NSApp.postEvent(keyUp, atStart: false)
        }

        private func click(
            _ input: WindowServerInputDriver,
            in window: NSWindow,
            step: String,
            target: @escaping @MainActor () -> NSView?
        ) async throws {
            try await waitUntil("\(step) 控件") {
                guard let target = target() else { return false }
                return isUsable(target, in: window)
            }
            let coordinate: @MainActor () throws
                -> WindowServerInputDriver.PointerCoordinate = {
                guard let view = target(), self.isUsable(view, in: window) else {
                    throw Failure.missing("\(step) 控件在点击前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: view)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            try await input.postClick(
                at: try coordinate(),
                modifiers: [],
                resolveTarget: coordinate
            )
        }

        private func selectSegment(
            _ segment: Int,
            input: WindowServerInputDriver,
            in window: NSWindow,
            identifier: String,
            step: String
        ) async throws {
            try await waitUntil("\(step)控件") {
                guard let target = self.segmentedControl(
                    identifier: identifier,
                    in: window
                ) else { return false }
                return segment >= 0
                    && segment < target.segmentCount
                    && self.isUsable(target, in: window)
            }
            let coordinate: @MainActor () throws
                -> WindowServerInputDriver.PointerCoordinate = {
                guard let target = self.segmentedControl(
                    identifier: identifier,
                    in: window
                ),
                    segment >= 0,
                    segment < target.segmentCount,
                    self.isUsable(target, in: window)
                else {
                    throw Failure.missing("\(step)控件在点击前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: target)
                let width = frame.width / CGFloat(target.segmentCount)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(
                        x: frame.minX + width * (CGFloat(segment) + 0.5),
                        y: frame.midY
                    ),
                    in: window
                )
            }
            try await input.postClick(
                at: try coordinate(),
                modifiers: [],
                resolveTarget: coordinate
            )
        }

        private func field(identifier: String, in window: NSWindow) -> NSTextField? {
            let matches = allViews(in: window).compactMap { $0 as? NSTextField }
                .filter { view in
                    view.identifier?.rawValue == identifier
                        && isUsable(view, in: window)
                }
            guard matches.count == 1 else { return nil }
            return matches[0]
        }

        private func secureField(
            identifier: String,
            in window: NSWindow
        ) -> NSSecureTextField? {
            let matches = allViews(in: window).compactMap { $0 as? NSSecureTextField }
                .filter { view in
                    view.identifier?.rawValue == identifier
                        && isUsable(view, in: window)
                }
            guard matches.count == 1 else { return nil }
            return matches[0]
        }

        private func button(
            identifier: String,
            title: String,
            in window: NSWindow
        ) -> NSButton? {
            let visibleButtons = allViews(in: window).compactMap { $0 as? NSButton }
                .filter { isUsable($0, in: window) }
            let identified = visibleButtons.filter {
                $0.identifier?.rawValue == identifier
            }
            if identified.count == 1 { return identified[0] }
            let titled = visibleButtons.filter { $0.title == title }
            guard titled.count == 1 else { return nil }
            return titled[0]
        }

        private func control(
            identifier: String,
            in window: NSWindow
        ) -> NSControl? {
            let matches = allViews(in: window).compactMap { $0 as? NSControl }
                .filter { control in
                    control.identifier?.rawValue == identifier
                        && isUsable(control, in: window)
                }
            guard matches.count == 1 else { return nil }
            return matches[0]
        }

        private func segmentedControl(
            identifier: String,
            in window: NSWindow
        ) -> NSSegmentedControl? {
            let controls = allViews(in: window)
                .compactMap { $0 as? NSSegmentedControl }
                .filter {
                    isUsable($0, in: window)
                }
            let identified = controls.filter { control in
                    control.identifier?.rawValue == identifier
            }
            if identified.count == 1 {
                return identified[0]
            }
            guard let anchor = AppViewTreeE2E.view(
                identifier: "\(identifier).anchor"
            ),
                anchor.window === window,
                isUsable(anchor, in: window)
            else {
                return nil
            }
            let anchorFrame = AppViewTreeE2E.frameInWindow(for: anchor)
            let aligned = controls.filter { control in
                let frame = AppViewTreeE2E.frameInWindow(for: control)
                return abs(frame.midX - anchorFrame.midX) <= 3
                    && abs(frame.midY - anchorFrame.midY) <= 3
            }
            guard aligned.count == 1 else { return nil }
            return aligned[0]
        }

        private func allViews(in window: NSWindow) -> [NSView] {
            guard let root = window.contentView?.superview ?? window.contentView else {
                return []
            }
            var result: [NSView] = []
            var pending = [root]
            var visited: Set<ObjectIdentifier> = []
            while let view = pending.popLast(), result.count < 5000 {
                guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
                result.append(view)
                pending.append(contentsOf: view.subviews)
            }
            return result
        }

        private func isUsable(_ view: NSView, in window: NSWindow) -> Bool {
            view.window === window
                && view.isHiddenOrHasHiddenAncestor == false
                && view.alphaValue > 0
                && view.bounds.width >= 2
                && view.bounds.height >= 2
                && view.visibleRect.width >= 2
                && view.visibleRect.height >= 2
        }

        private func waitUntil(
            _ step: String,
            attempts: Int = 180,
            condition: @MainActor () -> Bool
        ) async throws {
            for _ in 0 ..< attempts {
                if condition() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw Failure.missing("等待真实 UI 超时：\(step)")
        }

        private func finish(_ result: String) {
            if result.hasPrefix("failed:") {
                AppViewTreeE2E.writeDump(beside: resultURL)
            }
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark Zhulong Provider settings UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            E2EApplicationTermination.schedule()
        }
    }

    private enum Failure: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .missing(message): message
            }
        }
    }
}

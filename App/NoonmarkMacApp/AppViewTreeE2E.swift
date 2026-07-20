import AppKit
import CoreGraphics
import Foundation

/// In-process query and pointer surface for real-App E2E runs.
///
/// Queries are limited to the current visible main-window tree. Actions are
/// delivered as mouse events to the owning window; this type never invokes a
/// control action or reaches into application state.
@MainActor
enum AppViewTreeE2E {
    struct PresentationWindowIdentity: Equatable {
        let mainWindowNumber: Int
        let presentationWindowNumber: Int
    }

    static func view(identifier: String) -> NSView? {
        let matches = visibleViews(identifier: identifier)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func view(identifier: String, in window: NSWindow) -> NSView? {
        guard window.isVisible,
              window.isMiniaturized == false,
              window.alphaValue > 0,
              let rootView = window.contentView?.superview ?? window.contentView
        else {
            return nil
        }
        let matches = allViews(from: rootView).filter {
            $0.identifier?.rawValue == identifier
                && isVisible($0, in: [window])
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func hasNoVisibleView(identifier: String) -> Bool {
        guard currentWindowTree().isEmpty == false else { return false }
        return visibleViews(identifier: identifier).isEmpty
    }

    static func hasNoAttachedSheets() -> Bool {
        guard let mainWindow = currentMainWindow() else { return false }
        return mainWindow.attachedSheet == nil
            && mainWindow.sheets.isEmpty
            && NSApp.modalWindow == nil
            && NSApp.windows.allSatisfy { $0.sheetParent !== mainWindow }
    }

    static func hasNoAttachedPresentationWindows() -> Bool {
        guard let mainWindow = currentMainWindow() else { return false }
        return mainWindow.attachedSheet == nil
            && mainWindow.sheets.isEmpty
            && (mainWindow.childWindows ?? []).isEmpty
            && NSApp.modalWindow == nil
            && NSApp.windows.allSatisfy {
                $0.parent !== mainWindow && $0.sheetParent !== mainWindow
            }
    }

    static func requestMainWindowActivation() -> Bool {
        guard let mainWindow = currentMainWindow() else { return false }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        return true
    }

    static func mainWindowHasInteractionIdentity() -> Bool {
        guard let mainWindow = currentMainWindow() else { return false }
        return NSApp.isActive
            && NSApp.keyWindow === mainWindow
            && NSApp.mainWindow === mainWindow
            && mainWindow.isKeyWindow
            && mainWindow.isMainWindow
    }

    static func activateMainWindow() -> Bool {
        requestMainWindowActivation()
            && mainWindowHasInteractionIdentity()
    }

    static func mappedPresentationWindow(
        identifier: String
    ) -> PresentationWindowIdentity? {
        guard NSApp.isActive,
              let mainWindow = currentMainWindow(),
              let presentationView = view(identifier: identifier),
              let presentationWindow = presentationView.window,
              presentationWindow !== mainWindow,
              presentationWindow.isVisible,
              presentationWindow.isMiniaturized == false,
              presentationWindow.alphaValue > 0,
              presentationWindow.parent === mainWindow
                  || presentationWindow.sheetParent === mainWindow
                  || (mainWindow.childWindows ?? []).contains(where: {
                      $0 === presentationWindow
                  }),
              NSApp.keyWindow === mainWindow || NSApp.keyWindow === presentationWindow,
              isWindowServerMapped(presentationWindow)
        else {
            return nil
        }
        return PresentationWindowIdentity(
            mainWindowNumber: mainWindow.windowNumber,
            presentationWindowNumber: presentationWindow.windowNumber
        )
    }

    static func isPresentationWindowOpen(
        _ identity: PresentationWindowIdentity
    ) -> Bool {
        guard let mainWindow = currentMainWindow(),
              mainWindow.windowNumber == identity.mainWindowNumber,
              let presentationWindow = NSApp.windows.first(where: {
                  $0.windowNumber == identity.presentationWindowNumber
              }),
              presentationWindow.isVisible,
              presentationWindow.isMiniaturized == false,
              presentationWindow.alphaValue > 0,
              presentationWindow.parent === mainWindow
                  || presentationWindow.sheetParent === mainWindow
                  || (mainWindow.childWindows ?? []).contains(where: {
                      $0 === presentationWindow
                  })
        else {
            return false
        }
        return isWindowServerMapped(presentationWindow)
    }

    static func identifiers(withPrefix prefix: String) -> Set<String>? {
        let matches = currentVisibleViews().compactMap { view -> (String, NSView)? in
            guard let identifier = view.identifier?.rawValue,
                  identifier.hasPrefix(prefix)
            else {
                return nil
            }
            return (identifier, view)
        }
        let groups = Dictionary(grouping: matches) { $0.0 }
        guard groups.values.allSatisfy({ $0.count == 1 }) else { return nil }
        return Set(groups.keys)
    }

    static func verificationText(for view: NSView) -> String? {
        if let anchor = view as? AppE2EAnchorView {
            return anchor.verificationText
        }
        if let button = view as? NSButton {
            if let toolTip = button.toolTip, toolTip.isEmpty == false {
                return toolTip
            }
            return button.title
        }
        if let textView = view as? NSTextView {
            return textView.string
        }
        if let textField = view as? NSTextField {
            return textField.stringValue
        }
        return nil
    }

    static func visibleButtonLabels() -> Set<String> {
        Set(currentVisibleViews().compactMap { view in
            guard let button = view as? NSButton else { return nil }
            let candidates = [button.title, button.toolTip, button.accessibilityLabel()]
            return candidates.compactMap { $0 }.first { $0.isEmpty == false }
        })
    }

    static func button(overlapping anchor: NSView) -> NSButton? {
        let anchorFrame = frameInWindow(for: anchor)
        let anchorArea = anchorFrame.width * anchorFrame.height
        guard anchorArea > 0 else { return nil }
        let matches = currentVisibleViews().compactMap { view -> NSButton? in
            guard let button = view as? NSButton else { return nil }
            let intersection = anchorFrame.intersection(frameInWindow(for: button))
            let intersectionArea = intersection.width * intersection.height
            return intersectionArea >= anchorArea * 0.8 ? button : nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func frameInWindow(for view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    static func click(_ view: NSView) -> Bool {
        guard isVisible(view), let window = view.window else { return false }
        let point = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        if view is NSControl {
            let windowRoot = window.contentView?.superview ?? window.contentView
            let hitView = windowRoot?.hitTest(point)
            guard let hitView,
                  hitView === view || hitView.isDescendant(of: view)
            else {
                return false
            }
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return false
        }

        // Queue the complete pair before AppKit starts NSButton's tracking loop;
        // sending mouseDown synchronously would block while it waits for mouseUp.
        NSApp.postEvent(mouseDown, atStart: false)
        NSApp.postEvent(mouseUp, atStart: false)
        return true
    }

    static func click(identifier: String) -> Bool {
        guard let view = view(identifier: identifier) else { return false }
        return click(view)
    }

    static func sendKey(_ navigationKey: DateNavigationKey) -> Bool {
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0 is NoonmarkWindow })
        else {
            return false
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: navigationKey.characters,
            charactersIgnoringModifiers: navigationKey.characters,
            isARepeat: false,
            keyCode: navigationKey.rawValue
        ), let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            characters: navigationKey.characters,
            charactersIgnoringModifiers: navigationKey.characters,
            isARepeat: false,
            keyCode: navigationKey.rawValue
        ) else {
            return false
        }

        window.sendEvent(keyDown)
        window.sendEvent(keyUp)
        return true
    }

    static func sendEscapeKey() -> Bool {
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0 is NoonmarkWindow })
        else {
            return false
        }
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ), let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ) else {
            return false
        }

        window.sendEvent(keyDown)
        window.sendEvent(keyUp)
        return true
    }

    static func rightClick(_ view: NSView) -> Bool {
        guard let events = rightClickEvents(for: view),
              let window = view.window
        else { return false }
        // Deliver mouseDown synchronously so SwiftUI enters the native menu
        // tracking loop before the queued mouseUp is consumed. Posting both
        // events was racy whenever the E2E bundle could not become frontmost.
        NSApp.postEvent(events.mouseUp, atStart: false)
        window.sendEvent(events.mouseDown)
        return true
    }

    static func selectFirstContextMenuItem(of view: NSView) -> Bool {
        guard let events = rightClickEvents(for: view),
              let window = view.window,
              let downArrow = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime + 0.04,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                  charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                  isARepeat: false,
                  keyCode: 125
              ), let confirm = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime + 0.05,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: "\r",
                  charactersIgnoringModifiers: "\r",
                  isARepeat: false,
                  keyCode: 36
              )
        else {
            return false
        }
        for event in [events.mouseUp, downArrow, confirm] {
            NSApp.postEvent(event, atStart: false)
        }
        window.sendEvent(events.mouseDown)
        return true
    }

    private static func rightClickEvents(
        for view: NSView
    ) -> (mouseDown: NSEvent, mouseUp: NSEvent)? {
        guard isVisible(view), let window = view.window else { return nil }
        let point = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let mouseDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return nil
        }
        return (mouseDown, mouseUp)
    }

    static func writeDump(beside resultURL: URL) {
        var lines: [String] = []
        if let mainWindow = currentMainWindow() {
            let attachedSheet = mainWindow.attachedSheet?.windowNumber.description ?? "nil"
            let modalWindow = NSApp.modalWindow?.windowNumber.description ?? "nil"
            lines.append(
                "main-window-lifecycle window=\(mainWindow.windowNumber) " +
                    "attachedSheet=\(attachedSheet) " +
                    "sheets=\(mainWindow.sheets.map(\.windowNumber)) " +
                    "children=\((mainWindow.childWindows ?? []).map(\.windowNumber)) " +
                    "modal=\(modalWindow)"
            )
            for window in NSApp.windows {
                let parent = window.parent?.windowNumber.description ?? "nil"
                let sheetParent = window.sheetParent?.windowNumber.description ?? "nil"
                lines.append(
                    "app-window=\(window.windowNumber) " +
                        "type=\(String(describing: type(of: window))) " +
                        "visible=\(window.isVisible) alpha=\(window.alphaValue) " +
                        "parent=\(parent) sheetParent=\(sheetParent)"
                )
            }
        }
        for window in currentWindowTree() {
            lines.append(
                "window=\(window.windowNumber) type=\(String(describing: type(of: window))) " +
                    "visible=\(window.isVisible) main=\(window.isMainWindow) key=\(window.isKeyWindow)"
            )
            guard let rootView = window.contentView?.superview ?? window.contentView else { continue }
            appendDump(for: rootView, depth: 1, to: &lines)
        }

        let dumpURL = resultURL
            .deletingPathExtension()
            .appendingPathExtension("view-tree.txt")
        try? lines.joined(separator: "\n").write(
            to: dumpURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func visibleViews(identifier: String) -> [NSView] {
        currentVisibleViews().filter {
            $0.identifier?.rawValue == identifier
        }
    }

    private static func currentVisibleViews() -> [NSView] {
        let windows = currentWindowTree()
        return windows.flatMap { window -> [NSView] in
            guard let rootView = window.contentView?.superview ?? window.contentView else { return [] }
            return allViews(from: rootView).filter {
                isVisible($0, in: windows)
            }
        }
    }

    private static func currentWindowTree() -> [NSWindow] {
        guard let root = currentMainWindow() else { return [] }
        var result: [NSWindow] = []
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []

        while let window = pending.popLast() {
            guard visited.insert(ObjectIdentifier(window)).inserted else { continue }
            guard window.isVisible, window.isMiniaturized == false, window.alphaValue > 0 else {
                continue
            }
            result.append(window)
            pending.append(contentsOf: window.childWindows ?? [])
            pending.append(contentsOf: NSApp.windows.filter { $0.sheetParent === window })
        }
        return result
    }

    private static func isWindowServerMapped(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0,
              let windows = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else {
            return false
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { description in
            description[kCGWindowNumber as String] as? Int == window.windowNumber
                && description[kCGWindowOwnerPID as String] as? Int32 == processID
        }
    }

    private static func currentMainWindow() -> NSWindow? {
        let visibleWindow: (NSWindow) -> Bool = {
            $0.isVisible && $0.isMiniaturized == false && $0.alphaValue > 0
        }
        if let mainWindow = NSApp.mainWindow, visibleWindow(mainWindow) {
            return mainWindow
        }
        if let mainWindow = NSApp.windows.first(where: {
            $0.isMainWindow && visibleWindow($0)
        }) {
            return mainWindow
        }
        if let keyWindow = NSApp.keyWindow, visibleWindow(keyWindow) {
            return keyWindow
        }
        let noonmarkWindows = NSApp.windows.filter {
            $0 is NoonmarkWindow && visibleWindow($0)
        }
        guard noonmarkWindows.count == 1 else { return nil }
        return noonmarkWindows[0]
    }

    private static func allViews(from root: NSView) -> [NSView] {
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

    private static func isVisible(_ view: NSView) -> Bool {
        isVisible(view, in: currentWindowTree())
    }

    private static func isVisible(_ view: NSView, in windows: [NSWindow]) -> Bool {
        guard let window = view.window,
              windows.contains(where: { $0 === window }),
              view.isHiddenOrHasHiddenAncestor == false,
              view.bounds.width > 0,
              view.bounds.height > 0,
              view.visibleRect.width > 0,
              view.visibleRect.height > 0
        else {
            return false
        }

        var ancestor: NSView? = view
        while let current = ancestor {
            guard current.alphaValue > 0 else { return false }
            ancestor = current.superview
        }
        return true
    }

    private static func appendDump(
        for view: NSView,
        depth: Int,
        to lines: inout [String]
    ) {
        let identifier = view.identifier?.rawValue ?? ""
        let text = verificationText(for: view) ?? ""
        let frame = view.convert(view.bounds, to: nil)
        lines.append(
            "\(String(repeating: "  ", count: depth))" +
                "type=\(String(describing: type(of: view))) id=\(identifier) " +
                "hidden=\(view.isHiddenOrHasHiddenAncestor) alpha=\(view.alphaValue) " +
                "frame=\(NSStringFromRect(frame)) text=\(text)"
        )
        for subview in view.subviews {
            appendDump(for: subview, depth: depth + 1, to: &lines)
        }
    }
}

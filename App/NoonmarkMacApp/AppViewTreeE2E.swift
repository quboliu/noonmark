import AppKit
import Foundation

/// In-process query and pointer surface for real-App E2E runs.
///
/// Queries are limited to the current visible main-window tree. Actions are
/// delivered as mouse events to the owning window; this type never invokes a
/// control action or reaches into application state.
@MainActor
enum AppViewTreeE2E {
    static func view(identifier: String) -> NSView? {
        let matches = visibleViews(identifier: identifier)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func hasNoVisibleView(identifier: String) -> Bool {
        guard currentWindowTree().isEmpty == false else { return false }
        return visibleViews(identifier: identifier).isEmpty
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

    static func frameInWindow(for view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    static func click(_ view: NSView) -> Bool {
        guard isVisible(view), let window = view.window else { return false }
        let point = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
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

    static func writeDump(beside resultURL: URL) {
        var lines: [String] = []
        for window in currentWindowTree() {
            lines.append(
                "window=\(window.windowNumber) type=\(String(describing: type(of: window))) " +
                    "visible=\(window.isVisible) main=\(window.isMainWindow) key=\(window.isKeyWindow)"
            )
            guard let contentView = window.contentView else { continue }
            appendDump(for: contentView, depth: 1, to: &lines)
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
            guard let contentView = window.contentView else { return [] }
            return allViews(from: contentView).filter {
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
        }
        return result
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

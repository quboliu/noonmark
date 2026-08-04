import AppKit
import CoreGraphics
import Foundation
import NoonmarkMacE2ESupport

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

    struct ButtonInteractionTarget {
        let coordinateView: NSView
        let window: NSWindow
        let windowPoint: NSPoint
    }

    static func view(identifier: String) -> NSView? {
        let matches = visibleViews(identifier: identifier)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// Resolves an attached view even when it is currently clipped by a
    /// scroll view. E2E drivers can use this to scroll a real user surface
    /// into view before delivering pointer or keyboard events.
    static func attachedView(identifier: String) -> NSView? {
        let windows = NSApp.windows.filter {
            $0.isVisible
                && $0.isMiniaturized == false
                && $0.alphaValue > 0
        }
        let matches = windows.flatMap { window -> [NSView] in
            guard let root = window.contentView?.superview
                ?? window.contentView
            else {
                return []
            }
            return allViews(from: root).filter {
                $0.identifier?.rawValue == identifier
                    && $0.isHiddenOrHasHiddenAncestor == false
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func view(identifier: String, in window: NSWindow) -> NSView? {
        let matches = visibleViews(identifier: identifier, in: window)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func visibleViews(
        identifier: String,
        in window: NSWindow
    ) -> [NSView] {
        guard window.isVisible,
              window.isMiniaturized == false,
              window.alphaValue > 0,
              let rootView = window.contentView?.superview ?? window.contentView
        else {
            return []
        }
        return allViews(from: rootView).filter {
            $0.identifier?.rawValue == identifier
                && isVisible($0, in: [window])
        }
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

    /// Requests activation only for the exact externally observed main window.
    /// AppKit completes foreground activation asynchronously; the UI driver
    /// retains responsibility for observing the active/key/main readiness event.
    static func activateMainWindow(expectedWindowNumber: Int) -> Bool {
        guard expectedWindowNumber > 0,
              let mainWindow = currentMainWindow(),
              mainWindow.windowNumber == expectedWindowNumber
        else {
            return false
        }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        guard let activatedWindow = currentMainWindow(),
              activatedWindow === mainWindow,
              activatedWindow.windowNumber == expectedWindowNumber
        else {
            return false
        }
        return true
    }

    static func activateWindow(containing identifier: String) -> Bool {
        guard let window = view(identifier: identifier)?.window else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        return NSApp.isActive && window.isKeyWindow
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

    static func button(label: String) -> NSButton? {
        let matches = currentVisibleViews().compactMap { view -> NSButton? in
            guard let button = view as? NSButton else { return nil }
            let labels = [
                button.title,
                button.toolTip,
                button.accessibilityLabel()
            ].compactMap { $0 }
            return labels.contains(label) ? button : nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
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

    /// Resolves the pointer geometry for a button identified by a passive E2E
    /// anchor.
    ///
    /// AppKit-backed buttons expose an `NSButton`, while SwiftUI's plain button
    /// style exposes only an internal hit-testing surface. In the latter case
    /// a candidate point is accepted only when it hits the anchor's own scroll
    /// document. Sampling multiple points preserves a real clickable sliver
    /// while rejecting coordinates covered by a fixed sibling overlay.
    static func buttonInteractionTarget(
        overlapping anchor: NSView
    ) -> ButtonInteractionTarget? {
        let nativeButton = button(overlapping: anchor)
        guard nativeButton != nil || anchor is AppE2EAnchorView,
              isVisible(anchor),
              let window = anchor.window,
              let root = window.contentView?.superview ?? window.contentView
        else {
            return nil
        }
        let visibleBounds = anchor.bounds.intersection(anchor.visibleRect)
        guard visibleBounds.isNull == false,
              visibleBounds.width >= 2,
              visibleBounds.height >= 2
        else {
            return nil
        }
        let anchorFrame = frameInWindow(for: anchor)
        let anchorArea = anchorFrame.width * anchorFrame.height
        guard anchorArea > 0 else { return nil }
        let candidateUnitPoints: [(x: CGFloat, y: CGFloat)] = [
            (0.5, 0.5),
            (0.5, 0.75),
            (0.5, 0.25),
            (0.5, 0.9),
            (0.5, 0.1),
            (0.75, 0.5),
            (0.25, 0.5)
        ]
        for candidate in candidateUnitPoints {
            let point = anchor.convert(
                NSPoint(
                    x: visibleBounds.minX
                        + visibleBounds.width * candidate.x,
                    y: visibleBounds.minY
                        + visibleBounds.height * candidate.y
                ),
                to: nil
            )
            let rootPoint = root.convert(point, from: nil)
            guard let hitView = root.hitTest(rootPoint),
                  hitView !== anchor,
                  hitView.isDescendant(of: anchor) == false,
                  isVisible(hitView, in: [window])
            else {
                continue
            }
            if let nativeButton {
                guard hitView === nativeButton
                        || hitView.isDescendant(of: nativeButton)
                else {
                    continue
                }
                return ButtonInteractionTarget(
                    coordinateView: nativeButton,
                    window: window,
                    windowPoint: point
                )
            }
            if let documentView = anchor.enclosingScrollView?.documentView,
               hitView !== documentView,
               hitView.isDescendant(of: documentView) == false
            {
                continue
            }
            let hitFrame = frameInWindow(for: hitView)
            let hitArea = hitFrame.width * hitFrame.height
            let intersection = anchorFrame.intersection(hitFrame)
            let intersectionArea =
                intersection.width * intersection.height
            let hitIsInsideAnchor =
                hitArea <= anchorArea * 1.5
                    && intersectionArea >= hitArea * 0.8
            let anchorIsInsideHit =
                intersectionArea >= anchorArea * 0.8
            guard hitArea > 0,
                  hitIsInsideAnchor || anchorIsInsideHit
            else {
                continue
            }
            return ButtonInteractionTarget(
                coordinateView: anchor,
                window: window,
                windowPoint: point
            )
        }
        return nil
    }

    static func textField(overlapping anchor: NSView) -> NSTextField? {
        let anchorFrame = frameInWindow(for: anchor)
        let anchorArea = anchorFrame.width * anchorFrame.height
        guard anchorArea > 0 else { return nil }
        let matches = currentVisibleViews().compactMap {
            view -> NSTextField? in
            guard let textField = view as? NSTextField else {
                return nil
            }
            let intersection = anchorFrame.intersection(
                frameInWindow(for: textField)
            )
            let intersectionArea = intersection.width * intersection.height
            let textFieldFrame = frameInWindow(for: textField)
            let textFieldArea =
                textFieldFrame.width * textFieldFrame.height
            return intersectionArea
                >= min(anchorArea, textFieldArea) * 0.7
                ? textField
                : nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func frameInWindow(for view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    static func click(_ view: NSView) -> Bool {
        click(
            view,
            normalizedX: 0.5,
            normalizedY: 0.5
        )
    }

    static func click(
        _ view: NSView,
        normalizedX: CGFloat,
        normalizedY: CGFloat
    ) -> Bool {
        guard (0 ... 1).contains(normalizedX),
              (0 ... 1).contains(normalizedY)
        else {
            return false
        }
        guard isVisible(view), let window = view.window else { return false }
        let point = view.convert(
            NSPoint(
                x: view.bounds.minX
                    + (view.bounds.width * normalizedX),
                y: view.bounds.minY
                    + (view.bounds.height * normalizedY)
            ),
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

    static func selectMenuItem(
        identifier: String,
        downArrowCount: Int
    ) -> Bool {
        guard downArrowCount > 0,
              let view = view(identifier: identifier),
              let window = view.window,
              click(view)
        else {
            return false
        }
        let timestamp = ProcessInfo.processInfo.systemUptime + 0.04
        let keyCodes = Array(
            repeating: UInt16(125),
            count: downArrowCount
        ) + [UInt16(36)]
        for (index, keyCode) in keyCodes.enumerated() {
            let characters = keyCode == 125
                ? String(UnicodeScalar(NSDownArrowFunctionKey)!)
                : "\r"
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp + (Double(index) * 0.01),
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                return false
            }
            NSApp.postEvent(event, atStart: false)
        }
        return true
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

    static func typeUnicode(_ text: String) -> Bool {
        guard text.isEmpty == false,
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else {
            return false
        }
        var timestamp = ProcessInfo.processInfo.systemUptime
        for character in text {
            let characters = String(character)
            guard let keyDown = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ), let keyUp = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp + 0.005,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else {
                return false
            }
            window.sendEvent(keyDown)
            window.sendEvent(keyUp)
            timestamp += 0.01
        }
        return true
    }

    static func sendReturnKey() -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
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
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ), let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.005,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
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
        selectContextMenuItem(of: view, downArrowCount: 1)
    }

    static func selectContextMenuItem(
        of view: NSView,
        downArrowCount: Int
    ) -> Bool {
        guard downArrowCount > 0 else { return false }
        guard let events = rightClickEvents(for: view),
              let window = view.window
        else {
            return false
        }
        let timestamp = ProcessInfo.processInfo.systemUptime + 0.04
        let keyCodes = Array(
            repeating: UInt16(125),
            count: downArrowCount
        ) + [UInt16(36)]
        var selectionEvents: [NSEvent] = []
        for (index, keyCode) in keyCodes.enumerated() {
            let characters = keyCode == 125
                ? String(UnicodeScalar(NSDownArrowFunctionKey)!)
                : "\r"
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: timestamp + (Double(index) * 0.01),
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                return false
            }
            selectionEvents.append(event)
        }
        for event in [events.mouseUp] + selectionEvents {
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
        guard let windowNumber = CGWindowID(exactly: window.windowNumber),
              windowNumber > 0,
              let snapshot = ScopedWindowServerLookup.snapshot(
                  windowNumber: windowNumber
              )
        else {
            return false
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        return snapshot.windowNumber == windowNumber
            && snapshot.ownerProcessID == processID
            && snapshot.isOnscreen
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

import AppKit
import ApplicationServices
import Foundation
import NoonmarkMacE2ESupport

/// Reads system Accessibility state for E2E synchronization and geometry.
///
/// This type deliberately exposes no AX action or value-mutation API. All
/// interactions continue through `WindowServerInputDriver`.
@MainActor
enum ReadOnlyAccessibilityTarget {
    private struct WindowRoot {
        let windowNumber: Int
        let element: AXUIElement
    }

    private struct WindowQuery {
        let windowNumber: Int
        let keyWindowNumber: Int?
        let focusedWindowNumber: Int?
        let matches: [Match]
    }

    struct Match: Equatable {
        let role: String
        let title: String?
        let description: String?
        let value: String?
        let identifier: String?
        let enabled: Bool?
        let hidden: Bool?
        let frame: CGRect?
    }

    /// Returns one stable, visible snapshot of the matching identifiers in the
    /// expected key/focused window. The duplicate entries are intentionally
    /// preserved so callers can prove identifier uniqueness instead of hiding
    /// collisions behind a dictionary or `Set`.
    static func stableVisibleElements(
        identifierPrefix: String,
        in expectedWindow: NSWindow
    ) -> [Match]? {
        guard identifierPrefix.isEmpty == false else { return nil }
        return stableVisibleElementsSnapshot(
            identifierPrefix: identifierPrefix,
            in: expectedWindow
        )
    }

    static func stableVisibleElements(
        in expectedWindow: NSWindow
    ) -> [Match]? {
        stableVisibleElementsSnapshot(identifierPrefix: nil, in: expectedWindow)
    }

    private static func stableVisibleElementsSnapshot(
        identifierPrefix: String?,
        in expectedWindow: NSWindow
    ) -> [Match]? {
        guard let initialQuery = windowDescendants(in: expectedWindow),
              let currentQuery = windowDescendants(in: expectedWindow),
              initialQuery.windowNumber == currentQuery.windowNumber,
              initialQuery.keyWindowNumber == currentQuery.keyWindowNumber,
              initialQuery.focusedWindowNumber
              == currentQuery.focusedWindowNumber
        else {
            return nil
        }
        let initial = visibleElements(
            identifierPrefix: identifierPrefix,
            in: initialQuery
        )
        let current = visibleElements(
            identifierPrefix: identifierPrefix,
            in: currentQuery
        )
        guard initial == current else { return nil }
        return current
    }

    static func focusedTextEntry(
        in expectedWindow: NSWindow
    ) -> AXUIElement? {
        guard let focused = stableFocusedElement(
            in: expectedWindow
        ),
              let role = string(focused, kAXRoleAttribute),
              Set([
                  kAXTextFieldRole as String,
                  kAXTextAreaRole as String,
                  kAXComboBoxRole as String
              ]).contains(role)
        else {
            return nil
        }
        return focused
    }

    static func focusedElementMatches(
        _ expected: AXUIElement,
        in expectedWindow: NSWindow
    ) -> Bool {
        guard let focused = stableFocusedElement(
            in: expectedWindow
        ) else {
            return false
        }
        return CFEqual(focused, expected)
    }

    static func uniqueButton(
        identifier: String,
        label: String,
        enabled: Bool,
        in expectedWindow: NSWindow
    ) -> Match? {
        guard let button = uniqueElement(
            identifier: identifier,
            enabled: enabled,
            in: expectedWindow
        ),
              button.role == kAXButtonRole as String,
              button.title == label || button.description == label
        else {
            return nil
        }
        return button
    }

    static func uniqueMenuBarItem(title: String) -> Match? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(getpid())
        guard let menuBar = element(root, kAXMenuBarAttribute),
              let initial = uniqueDirectMenuBarEntry(title: title, below: menuBar),
              let currentMenuBar = element(root, kAXMenuBarAttribute),
              let current = uniqueDirectMenuBarEntry(
                  title: title,
                  below: currentMenuBar
              ),
              initial.role == current.role,
              initial.title == current.title,
              initial.enabled == current.enabled,
              initial.hidden == current.hidden,
              initial.frame == current.frame
        else {
            return nil
        }
        return current
    }

    private static func uniqueDirectMenuBarEntry(
        title: String,
        below menuBar: AXUIElement
    ) -> Match? {
        guard let element = uniqueDirectMenuBarElement(
            title: title,
            below: menuBar
        ) else {
            return nil
        }
        return match(element)
    }

    private static func uniqueDirectMenuBarElement(
        title: String,
        below menuBar: AXUIElement
    ) -> AXUIElement? {
        let matches = elements(menuBar, kAXChildrenAttribute)
            .compactMap { element -> (AXUIElement, Match)? in
                let candidate = match(element)
                guard candidate.role == kAXMenuBarItemRole as String,
                      candidate.title == title,
                      validatedUniqueMenuEntry([candidate]) != nil
                else {
                    return nil
                }
                return (element, candidate)
            }
        guard matches.count == 1 else { return nil }
        return matches[0].0
    }

    static func uniqueElement(
        identifier: String,
        enabled: Bool? = nil,
        in expectedWindow: NSWindow
    ) -> Match? {
        guard let query = windowDescendants(in: expectedWindow),
              let index =
              AccessibilityWindowScopeContract.uniqueCandidateIndex(
                  identifier: identifier,
                  expectedWindowNumber: query.windowNumber,
                  keyWindowNumber: query.keyWindowNumber,
                  focusedWindowNumber: query.focusedWindowNumber,
                  candidates: query.matches.map {
                      AccessibilityWindowCandidate(
                          windowNumber: query.windowNumber,
                          identifier: $0.identifier
                      )
                  }
              )
        else {
            return nil
        }
        let element = query.matches[index]
        guard
              enabled.map({ element.enabled == $0 }) ?? true,
              element.hidden != true,
              let frame = element.frame,
              frame.isNull == false,
              frame.isInfinite == false,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width >= 2,
              frame.height >= 2
        else {
            return nil
        }
        return element
    }

    static func uniqueElement(
        identifier: String,
        enabled: Bool? = nil
    ) -> Match? {
        guard let expectedWindow = NSApp.keyWindow else { return nil }
        return uniqueElement(
            identifier: identifier,
            enabled: enabled,
            in: expectedWindow
        )
    }

    static func buttonDiagnostics(
        identifier: String,
        title: String,
        in expectedWindow: NSWindow
    ) -> String {
        let shallow = windowDescendants(in: expectedWindow)
        let deep = windowDescendants(
            in: expectedWindow,
            maximumDepth: 40
        )
        let shallowMatches = shallow?.matches ?? []
        let deepMatches = deep?.matches ?? []
        let shallowExact = shallowMatches.filter {
            $0.identifier == identifier
        }
        let deepExact = deepMatches.filter { $0.identifier == identifier }
        let deepTitled = deepMatches.filter {
            $0.title == title || $0.description == title
        }
        return [
            "trusted=\(AXIsProcessTrusted())",
            scopeSummary(expectedWindow, query: deep),
            "shallow=\(shallowMatches.count)",
            "deep=\(deepMatches.count)",
            "shallowExact=\(summarize(shallowExact))",
            "deepExact=\(summarize(deepExact))",
            "deepTitled=\(summarize(deepTitled))"
        ].joined(separator: " ")
    }

    static func elementDiagnostics(
        identifier: String,
        in expectedWindow: NSWindow
    ) -> String {
        let shallow = windowDescendants(in: expectedWindow)
        let deep = windowDescendants(
            in: expectedWindow,
            maximumDepth: 40
        )
        let shallowMatches = shallow?.matches ?? []
        let deepMatches = deep?.matches ?? []
        let shallowExact = shallowMatches.filter {
            $0.identifier == identifier
        }
        let deepExact = deepMatches.filter { $0.identifier == identifier }
        return [
            "trusted=\(AXIsProcessTrusted())",
            scopeSummary(expectedWindow, query: deep),
            "shallow=\(shallowMatches.count)",
            "deep=\(deepMatches.count)",
            "shallowExact=\(summarize(shallowExact))",
            "deepExact=\(summarize(deepExact))"
        ].joined(separator: " ")
    }

    static func elementDiagnostics(identifier: String) -> String {
        guard let expectedWindow = NSApp.keyWindow else {
            return "trusted=\(AXIsProcessTrusted()) expectedWindow=nil scoped=false"
        }
        return elementDiagnostics(
            identifier: identifier,
            in: expectedWindow
        )
    }

    static func string(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        value(element, attribute) as? String
    }

    private static func windowDescendants(
        in expectedWindow: NSWindow,
        maximumDepth: Int = 16,
        maximumCount: Int = 20000
    ) -> WindowQuery? {
        guard let initialRoot = accessibilityWindowRoot(
            for: expectedWindow
        ) else {
            return nil
        }
        var queue = [(initialRoot.element, 0)]
        var result: [Match] = []
        var index = 0

        while index < queue.count, result.count < maximumCount {
            let (current, depth) = queue[index]
            index += 1
            result.append(match(current))
            guard depth < maximumDepth else { continue }
            queue.append(
                contentsOf: elements(current, kAXChildrenAttribute)
                    .map { ($0, depth + 1) }
            )
        }
        guard let currentRoot = accessibilityWindowRoot(
            for: expectedWindow
        ), currentRoot.windowNumber == initialRoot.windowNumber,
            CFEqual(currentRoot.element, initialRoot.element)
        else {
            return nil
        }
        return WindowQuery(
            windowNumber: currentRoot.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber,
            focusedWindowNumber: focusedWindow()?.windowNumber,
            matches: result
        )
    }

    private static func visibleElements(
        identifierPrefix: String?,
        in query: WindowQuery
    ) -> [Match] {
        query.matches.filter { match in
            let identifierMatches = identifierPrefix.map {
                match.identifier?.hasPrefix($0) == true
            } ?? true
            guard identifierMatches, match.hidden != true,
                  let frame = match.frame,
                  frame.isNull == false,
                  frame.isInfinite == false,
                  frame.origin.x.isFinite,
                  frame.origin.y.isFinite,
                  frame.width.isFinite,
                  frame.height.isFinite,
                  frame.width >= 2,
                  frame.height >= 2
            else {
                return false
            }
            return true
        }.sorted(by: matchOrder)
    }

    private static func matchOrder(_ lhs: Match, _ rhs: Match) -> Bool {
        let lhsKey = [
            lhs.identifier ?? "",
            lhs.role,
            lhs.title ?? "",
            lhs.description ?? "",
            lhs.value ?? "",
            String(describing: lhs.enabled),
            String(describing: lhs.hidden),
            String(describing: lhs.frame)
        ].joined(separator: "\u{0}")
        let rhsKey = [
            rhs.identifier ?? "",
            rhs.role,
            rhs.title ?? "",
            rhs.description ?? "",
            rhs.value ?? "",
            String(describing: rhs.enabled),
            String(describing: rhs.hidden),
            String(describing: rhs.frame)
        ].joined(separator: "\u{0}")
        return lhsKey < rhsKey
    }

    private static func validatedUniqueMenuEntry(
        _ matches: [Match]
    ) -> Match? {
        guard matches.count == 1,
              let item = matches.first,
              item.enabled == true,
              item.hidden != true,
              let frame = item.frame,
              frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            return nil
        }
        return item
    }

    private static func accessibilityWindowRoot(
        for expectedWindow: NSWindow
    ) -> WindowRoot? {
        guard AXIsProcessTrusted(),
              expectedWindow.windowNumber > 0,
              NSApp.keyWindow === expectedWindow,
              focusedWindow() === expectedWindow,
              let root = element(
                  AXUIElementCreateApplication(getpid()),
                  kAXFocusedWindowAttribute
              )
        else {
            return nil
        }
        return WindowRoot(
            windowNumber: expectedWindow.windowNumber,
            element: root
        )
    }

    private static func stableFocusedElement(
        in expectedWindow: NSWindow
    ) -> AXUIElement? {
        guard let initialRoot = accessibilityWindowRoot(
            for: expectedWindow
        ), let initialFocused = element(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute
        ) else {
            return nil
        }
        let initialBelongsToRoot = element(
            initialFocused,
            belongsTo: initialRoot.element
        )
        let initialScope = focusedElementScope(
            expectedWindow: expectedWindow,
            elementBelongsToRoot: initialBelongsToRoot
        )

        guard let currentRoot = accessibilityWindowRoot(
            for: expectedWindow
        ), let currentFocused = element(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute
        ) else {
            return nil
        }
        let currentBelongsToRoot = element(
            currentFocused,
            belongsTo: currentRoot.element
        )
        let currentScope = focusedElementScope(
            expectedWindow: expectedWindow,
            elementBelongsToRoot: currentBelongsToRoot
        )
        guard AccessibilityWindowScopeContract
            .acceptsStableFocusedElement(
                initial: initialScope,
                current: currentScope,
                windowRootIsStable: CFEqual(
                    initialRoot.element,
                    currentRoot.element
                ),
                focusedElementIsStable: CFEqual(
                    initialFocused,
                    currentFocused
                )
            )
        else {
            return nil
        }
        return currentFocused
    }

    private static func focusedElementScope(
        expectedWindow: NSWindow,
        elementBelongsToRoot: Bool
    ) -> AccessibilityFocusedElementScopeSnapshot {
        AccessibilityFocusedElementScopeSnapshot(
            expectedWindowNumber: expectedWindow.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber,
            focusedWindowNumber: focusedWindow()?.windowNumber,
            elementBelongsToExpectedWindowRoot: elementBelongsToRoot
        )
    }

    private static func element(
        _ candidate: AXUIElement,
        belongsTo windowRoot: AXUIElement
    ) -> Bool {
        if let window = element(candidate, kAXWindowAttribute), CFEqual(window, windowRoot) == false {
            return false
        }
        if let topLevel = element(
            candidate,
            kAXTopLevelUIElementAttribute
        ), CFEqual(topLevel, windowRoot) == false {
            return false
        }

        var current = candidate
        var visited: [AXUIElement] = []
        for _ in 0 ..< 80 {
            if CFEqual(current, windowRoot) {
                return true
            }
            guard visited.contains(where: { CFEqual($0, current) }) == false,
                  let parent = element(current, kAXParentAttribute)
            else {
                return false
            }
            visited.append(current)
            current = parent
        }
        return false
    }

    private static func focusedWindow() -> NSWindow? {
        NSApp.accessibilityFocusedWindow() as? NSWindow
    }

    private static func scopeSummary(
        _ expectedWindow: NSWindow,
        query: WindowQuery?
    ) -> String {
        "expectedWindow=\(expectedWindow.windowNumber),"
            + "keyWindow=\(NSApp.keyWindow?.windowNumber.description ?? "nil"),"
            + "focusedWindow=\(focusedWindow()?.windowNumber.description ?? "nil"),"
            + "scoped=\(query != nil)"
    }

    private static func match(_ element: AXUIElement) -> Match {
        Match(
            role: string(element, kAXRoleAttribute) ?? "",
            title: string(element, kAXTitleAttribute),
            description: string(element, kAXDescriptionAttribute),
            value: string(element, kAXValueAttribute),
            identifier: string(element, kAXIdentifierAttribute),
            enabled: boolean(element, kAXEnabledAttribute),
            hidden: boolean(element, kAXHiddenAttribute),
            frame: frame(element)
        )
    }

    private static func summarize(
        _ matches: [Match],
        limit: Int = 4
    ) -> String {
        guard matches.isEmpty == false else { return "[]" }
        return matches.prefix(limit).map { match in
            "[role=\(match.role),id=\(match.identifier ?? "nil"),"
                + "title=\(match.title ?? "nil"),"
                + "description=\(match.description ?? "nil"),"
                + "value=\(match.value ?? "nil"),"
                + "enabled=\(String(describing: match.enabled)),"
                + "hidden=\(String(describing: match.hidden)),"
                + "frame=\(String(describing: match.frame))]"
        }.joined(separator: ",")
    }

    private static func boolean(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    private static func element(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        guard let value = value(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elements(
        _ element: AXUIElement,
        _ attribute: String
    ) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAX) == .cgPoint,
              AXValueGetType(sizeAX) == .cgSize,
              AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func value(
        _ element: AXUIElement,
        _ attribute: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value
    }
}

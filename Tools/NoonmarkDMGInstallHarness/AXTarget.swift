import ApplicationServices
import Darwin
import Foundation

typealias AXWindowNumberResolver = (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

private enum AXWindowNumberSPI {
    private typealias Function = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    static func resolver() -> AXWindowNumberResolver? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "_AXUIElementGetWindow") else {
            return nil
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        return { element, output in
            function(element, output)
        }
    }
}

/// Read-only Accessibility view of the validation process. This type exposes
/// no AX action or value-mutation API by design.
final class AXTarget {
    typealias WindowNumberResolver = AXWindowNumberResolver

    struct Match {
        let element: AXUIElement
        let role: String
        let title: String?
        let description: String?
        let identifier: String?
        let enabled: Bool?
        let hidden: Bool?
        let frame: CGRect?
    }

    enum Failure: LocalizedError {
        case invalidFrame(String)
        case invalidTraversal(String)
        case waitTimedOut(String)

        var errorDescription: String? {
            switch self {
            case let .invalidFrame(description):
                "AX element has no usable frame: \(description)"
            case let .invalidTraversal(description):
                "AX traversal was incomplete: \(description)"
            case let .waitTimedOut(description):
                "Timed out waiting for \(description)"
            }
        }
    }

    let application: AXUIElement

    init(pid: pid_t) {
        application = AXUIElementCreateApplication(pid)
    }

    func waitUntilFrontmost() throws {
        _ = try wait(description: "the validation app to be AX-frontmost") {
            boolean(application, kAXFrontmostAttribute as String) == true
                ? true
                : nil
        }
    }

    func menuBar() throws -> AXUIElement {
        guard let menuBar = element(application, kAXMenuBarAttribute as String) else {
            throw Failure.waitTimedOut("the validation app menu bar")
        }
        return menuBar
    }

    func windows() -> [AXUIElement] {
        elements(application, kAXWindowsAttribute as String)
    }

    func descendants(
        of root: AXUIElement,
        maximumDepth: Int = 16,
        maximumCount: Int = 20000
    ) -> [Match] {
        var result: [Match] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0

        while index < queue.count, result.count < maximumCount {
            let (current, depth) = queue[index]
            index += 1
            result.append(match(current))
            guard depth < maximumDepth else { continue }
            for child in elements(current, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    func strictDescendants(
        of root: AXUIElement,
        maximumDepth: Int = 40,
        maximumCount: Int = 20000
    ) throws -> [Match] {
        var result: [Match] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var index = 0

        while index < queue.count {
            guard result.count < maximumCount else {
                throw Failure.invalidTraversal(
                    "element count reached \(maximumCount)"
                )
            }
            let (current, depth) = queue[index]
            index += 1
            let hash = CFHash(current)
            if visited[hash, default: []].contains(where: {
                CFEqual($0, current)
            }) {
                continue
            }
            visited[hash, default: []].append(current)

            let children = elements(current, kAXChildrenAttribute as String)
            guard depth < maximumDepth || children.isEmpty else {
                throw Failure.invalidTraversal(
                    "depth reached \(maximumDepth) with \(children.count) children"
                )
            }
            guard queue.count + children.count <= maximumCount else {
                throw Failure.invalidTraversal(
                    "pending element count exceeded \(maximumCount)"
                )
            }
            result.append(match(current))
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }

    func matches(
        in root: AXUIElement,
        roles: Set<String>? = nil,
        titles: Set<String>? = nil,
        identifier: String? = nil
    ) -> [Match] {
        filteredMatches(
            descendants(of: root),
            roles: roles,
            titles: titles,
            identifier: identifier
        )
    }

    func strictMatches(
        in root: AXUIElement,
        roles: Set<String>? = nil,
        titles: Set<String>? = nil,
        identifier: String? = nil
    ) throws -> [Match] {
        filteredMatches(
            try strictDescendants(of: root),
            roles: roles,
            titles: titles,
            identifier: identifier
        )
    }

    func directMatches(
        in root: AXUIElement,
        roles: Set<String>? = nil,
        titles: Set<String>? = nil,
        identifier: String? = nil
    ) -> [Match] {
        filteredMatches(
            elements(root, kAXChildrenAttribute as String).map(match),
            roles: roles,
            titles: titles,
            identifier: identifier
        )
    }

    func wait<T>(
        seconds: TimeInterval = 8,
        description: String,
        probe: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let value = try probe() { return value }
            usleep(50000)
        } while Date() < deadline
        throw Failure.waitTimedOut(description)
    }

    func requiredFrame(_ match: Match, description: String) throws -> CGRect {
        guard let frame = match.frame,
              frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            throw Failure.invalidFrame(description)
        }
        return frame
    }

    func requiredFrame(_ element: AXUIElement, description: String) throws -> CGRect {
        guard let frame = frame(element),
              frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2
        else {
            throw Failure.invalidFrame(description)
        }
        return frame
    }

    func string(_ target: AXUIElement, _ attribute: String) -> String? {
        value(target, attribute) as? String
    }

    func integer(_ target: AXUIElement, _ attribute: String) -> Int? {
        (value(target, attribute) as? NSNumber)?.intValue
    }

    func boolean(_ target: AXUIElement, _ attribute: String) -> Bool? {
        (value(target, attribute) as? NSNumber)?.boolValue
    }

    func windowNumber(
        _ target: AXUIElement
    ) -> CGWindowID? {
        windowNumber(
            target,
            resolver: AXWindowNumberSPI.resolver()
        )
    }

    func windowNumber(
        _ target: AXUIElement,
        resolver: WindowNumberResolver?
    ) -> CGWindowID? {
        var windowNumber = kCGNullWindowID
        guard let resolver,
              resolver(target, &windowNumber) == .success,
              windowNumber != kCGNullWindowID
        else {
            return nil
        }
        return windowNumber
    }

    func element(_ target: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(target, attribute),
              CFGetTypeID(result) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (result as! AXUIElement)
    }

    func elements(_ target: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(target, attribute) as? [AXUIElement] ?? []
    }

    func frame(_ target: AXUIElement) -> CGRect? {
        guard let positionValue = value(target, kAXPositionAttribute as String),
              let sizeValue = value(target, kAXSizeAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
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

    private func match(_ element: AXUIElement) -> Match {
        Match(
            element: element,
            role: string(element, kAXRoleAttribute as String) ?? "",
            title: string(element, kAXTitleAttribute as String),
            description: string(element, kAXDescriptionAttribute as String),
            identifier: string(element, kAXIdentifierAttribute as String),
            enabled: boolean(element, kAXEnabledAttribute as String),
            hidden: boolean(element, kAXHiddenAttribute as String),
            frame: frame(element)
        )
    }

    private func filteredMatches(
        _ candidates: [Match],
        roles: Set<String>?,
        titles: Set<String>?,
        identifier: String?
    ) -> [Match] {
        candidates.filter { match in
            if let roles, roles.contains(match.role) == false { return false }
            if let titles, titles.contains(match.title ?? "") == false { return false }
            if let identifier, match.identifier != identifier { return false }
            return true
        }
    }

    private func value(_ target: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            target,
            attribute as CFString,
            &result
        )
        switch error {
        case .success:
            return result
        case .noValue, .attributeUnsupported, .cannotComplete, .invalidUIElement:
            return nil
        default:
            return nil
        }
    }
}

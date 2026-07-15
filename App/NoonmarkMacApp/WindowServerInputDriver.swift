import AppKit
import CoreGraphics
import Foundation

/// Posts E2E-only input through WindowServer so native AppKit and SwiftUI
/// interaction machinery observes the same event stream as real hardware.
@MainActor
final class WindowServerInputDriver {
    struct PointerCoordinate {
        let windowPoint: NSPoint
        let appKitScreenPoint: NSPoint
        let quartzPoint: CGPoint

        var report: String {
            "window=\(windowPoint),appkit=\(appKitScreenPoint),quartz=\(quartzPoint)"
        }
    }

    enum Failure: LocalizedError {
        case eventAccessUnavailable
        case eventSourceUnavailable
        case eventConstructionFailed(String)
        case coordinateRoundTripFailed(expected: NSPoint, actual: NSPoint)
        case pointerDidNotSettle(CGPoint)
        case buttonStateDidNotChange(expectedDown: Bool)

        var errorDescription: String? {
            switch self {
            case .eventAccessUnavailable:
                "WindowServer event-posting access is unavailable"
            case .eventSourceUnavailable:
                "WindowServer combined-session event source is unavailable"
            case let .eventConstructionFailed(kind):
                "WindowServer could not construct \(kind)"
            case let .coordinateRoundTripFailed(expected, actual):
                "WindowServer coordinate round trip differed: expected "
                    + "\(expected), actual \(actual)"
            case let .pointerDidNotSettle(point):
                "WindowServer pointer did not settle at \(point)"
            case let .buttonStateDidNotChange(expectedDown):
                "WindowServer left button did not become "
                    + (expectedDown ? "down" : "up")
            }
        }
    }

    private static var nextGestureNumber = Int64(
        ProcessInfo.processInfo.systemUptime * 1000
    )

    private let source: CGEventSource
    private let userData: Int64

    init() throws {
        guard CGPreflightPostEventAccess() else {
            throw Failure.eventAccessUnavailable
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw Failure.eventSourceUnavailable
        }
        self.source = source
        userData = Int64.random(in: 1 ... Int64.max)
    }

    var isLeftButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    var currentPointerLocation: CGPoint? {
        CGEvent(source: nil)?.location
    }

    func nextMouseGestureNumber() -> Int64 {
        Self.nextGestureNumber &+= 1
        return Self.nextGestureNumber
    }

    func pointerCoordinate(
        windowPoint: NSPoint,
        in window: NSWindow
    ) throws -> PointerCoordinate {
        let appKitScreenPoint = window.convertPoint(toScreen: windowPoint)
        let quartzPoint = CGPoint(
            x: appKitScreenPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - appKitScreenPoint.y
        )
        guard let probe = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else {
            throw Failure.eventConstructionFailed("coordinate probe")
        }
        let roundTrip = probe.unflippedLocation
        guard abs(roundTrip.x - appKitScreenPoint.x) <= 0.5,
              abs(roundTrip.y - appKitScreenPoint.y) <= 0.5
        else {
            throw Failure.coordinateRoundTripFailed(
                expected: appKitScreenPoint,
                actual: roundTrip
            )
        }
        return PointerCoordinate(
            windowPoint: windowPoint,
            appKitScreenPoint: appKitScreenPoint,
            quartzPoint: quartzPoint
        )
    }

    func postMouse(
        type: CGEventType,
        at point: CGPoint,
        gestureNumber: Int64,
        modifiers: NSEvent.ModifierFlags = [],
        pressure: Double
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw Failure.eventConstructionFailed("mouse event \(type.rawValue)")
        }
        event.flags = Self.cgFlags(for: modifiers)
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventNumber, value: gestureNumber)
        event.setIntegerValueField(
            .mouseEventClickState,
            value: type == .mouseMoved ? 0 : 1
        )
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.post(tap: .cghidEventTap)
    }

    func postClick(
        at coordinate: PointerCoordinate,
        modifiers: NSEvent.ModifierFlags
    ) async throws {
        guard isLeftButtonDown == false else {
            throw Failure.eventConstructionFailed(
                "click while the combined-session left button was already down"
            )
        }
        let gestureNumber = nextMouseGestureNumber()
        try postMouse(
            type: .mouseMoved,
            at: coordinate.quartzPoint,
            gestureNumber: gestureNumber,
            modifiers: modifiers,
            pressure: 0
        )
        guard await waitForPointer(at: coordinate.quartzPoint) else {
            throw Failure.pointerDidNotSettle(coordinate.quartzPoint)
        }

        do {
            try postMouse(
                type: .leftMouseDown,
                at: coordinate.quartzPoint,
                gestureNumber: gestureNumber,
                modifiers: modifiers,
                pressure: 1
            )
            try await releaseLeftButton(
                at: coordinate.quartzPoint,
                gestureNumber: gestureNumber,
                modifiers: modifiers
            )
        } catch {
            if isLeftButtonDown {
                try? await releaseLeftButton(
                    at: coordinate.quartzPoint,
                    gestureNumber: gestureNumber,
                    modifiers: modifiers
                )
            }
            throw error
        }
    }

    func postKey(keyCode: CGKeyCode) throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            throw Failure.eventConstructionFailed("keyboard event")
        }
        keyDown.setIntegerValueField(.eventSourceUserData, value: userData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: userData)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func waitForPointer(at point: CGPoint) async -> Bool {
        for _ in 0 ..< 30 {
            if let currentPointerLocation {
                let pointerSettled = abs(currentPointerLocation.x - point.x) <= 2
                    && abs(currentPointerLocation.y - point.y) <= 2
                if pointerSettled { return true }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func releaseLeftButton(
        at point: CGPoint,
        gestureNumber: Int64,
        modifiers: NSEvent.ModifierFlags
    ) async throws {
        try postMouse(
            type: .leftMouseUp,
            at: point,
            gestureNumber: gestureNumber,
            modifiers: modifiers,
            pressure: 0
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        for attempt in 0 ..< 30 {
            if isLeftButtonDown == false { return }
            if attempt > 0, attempt.isMultiple(of: 10) {
                try postMouse(
                    type: .leftMouseUp,
                    at: point,
                    gestureNumber: gestureNumber,
                    modifiers: modifiers,
                    pressure: 0
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.buttonStateDidNotChange(expectedDown: false)
    }

    private static func cgFlags(
        for modifiers: NSEvent.ModifierFlags
    ) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

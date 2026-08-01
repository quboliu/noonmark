import ApplicationServices
import CoreGraphics
import Foundation

/// Posts every harness interaction through WindowServer. AX is deliberately
/// excluded from this type so it cannot become an alternate action surface.
final class WindowServerInputDriver {
    enum Failure: LocalizedError {
        case requiredPermissionsUnavailable(
            accessibility: Bool,
            eventPosting: Bool
        )
        case eventSourceUnavailable
        case eventConstructionFailed(String)
        case pointerDidNotSettle(CGPoint)
        case buttonStateDidNotChange(expectedDown: Bool)
        case clickStartedWhileButtonDown
        case releaseCleanupFailed(original: String, cleanup: String)

        var errorDescription: String? {
            switch self {
            case let .requiredPermissionsUnavailable(accessibility, eventPosting):
                "DMG install harness permissions are unavailable: "
                    + "AXIsProcessTrusted=\(accessibility) "
                    + "CGPreflightPostEventAccess=\(eventPosting)"
            case .eventSourceUnavailable:
                "WindowServer combined-session event source is unavailable"
            case let .eventConstructionFailed(kind):
                "WindowServer could not construct \(kind)"
            case let .pointerDidNotSettle(point):
                "WindowServer pointer did not settle at \(point)"
            case let .buttonStateDidNotChange(expectedDown):
                "WindowServer left button did not become "
                    + (expectedDown ? "down" : "up")
            case .clickStartedWhileButtonDown:
                "WindowServer click started while the combined-session left button was down"
            case let .releaseCleanupFailed(original, cleanup):
                "WindowServer click failed (\(original)); left-button cleanup also failed "
                    + "(\(cleanup))"
            }
        }
    }

    private var nextGestureNumber = Int64(
        ProcessInfo.processInfo.systemUptime * 1000
    )

    private let source: CGEventSource
    private let userData: Int64

    init() throws {
        let accessibility = AXIsProcessTrusted()
        let eventPosting = CGPreflightPostEventAccess()
        guard accessibility, eventPosting else {
            throw Failure.requiredPermissionsUnavailable(
                accessibility: accessibility,
                eventPosting: eventPosting
            )
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw Failure.eventSourceUnavailable
        }
        self.source = source
        userData = Int64.random(in: 1 ... Int64.max)
    }

    func click(frame: CGRect, clickCount: Int = 1) throws {
        guard frame.isNull == false,
              frame.isInfinite == false,
              frame.width >= 2,
              frame.height >= 2,
              (1 ... 3).contains(clickCount)
        else {
            throw Failure.eventConstructionFailed("click for invalid AX frame \(frame)")
        }
        guard isLeftButtonDown == false else {
            throw Failure.clickStartedWhileButtonDown
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        nextGestureNumber &+= 1
        let gestureNumber = nextGestureNumber
        try postMouse(
            type: .mouseMoved,
            at: point,
            gestureNumber: gestureNumber,
            pressure: 0,
            clickCount: 0
        )
        guard waitForPointer(at: point) else {
            throw Failure.pointerDidNotSettle(point)
        }

        for clickIndex in 1 ... clickCount {
            var mouseDownWasPosted = false
            do {
                try postMouse(
                    type: .leftMouseDown,
                    at: point,
                    gestureNumber: gestureNumber,
                    pressure: 1,
                    clickCount: Int64(clickIndex)
                )
                mouseDownWasPosted = true
                guard waitForButtonState(expectedDown: true) else {
                    throw Failure.buttonStateDidNotChange(expectedDown: true)
                }
                try postMouse(
                    type: .leftMouseUp,
                    at: point,
                    gestureNumber: gestureNumber,
                    pressure: 0,
                    clickCount: Int64(clickIndex)
                )
                guard waitForButtonState(expectedDown: false) else {
                    throw Failure.buttonStateDidNotChange(expectedDown: false)
                }
                if clickIndex < clickCount { usleep(30000) }
            } catch {
                let originalError = error
                guard mouseDownWasPosted else { throw originalError }
                do {
                    try postMouse(
                        type: .leftMouseUp,
                        at: point,
                        gestureNumber: gestureNumber,
                        pressure: 0,
                        clickCount: Int64(clickIndex)
                    )
                    guard waitForButtonState(expectedDown: false) else {
                        throw Failure.buttonStateDidNotChange(expectedDown: false)
                    }
                } catch {
                    throw Failure.releaseCleanupFailed(
                        original: originalError.localizedDescription,
                        cleanup: error.localizedDescription
                    )
                }
                throw originalError
            }
        }
    }

    func typeUnicode(_ text: String) throws {
        guard text.isEmpty == false else { return }
        for character in text {
            let units = Array(String(character).utf16)
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            ) else {
                throw Failure.eventConstructionFailed("Unicode keyboard event")
            }
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            // A combined-session source inherits shortcut modifier flags.
            // Text entry must explicitly clear them after Command/Shift keys.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.setIntegerValueField(.eventSourceUserData, value: userData)
            keyUp.setIntegerValueField(.eventSourceUserData, value: userData)
            keyDown.post(tap: .cghidEventTap)
            usleep(8000)
            keyUp.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }

    func keyStroke(
        virtualKey: CGKeyCode,
        flags: CGEventFlags = []
    ) throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: virtualKey,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: virtualKey,
            keyDown: false
        ) else {
            throw Failure.eventConstructionFailed("keyboard shortcut")
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: userData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: userData)
        keyDown.post(tap: .cghidEventTap)
        usleep(25000)
        keyUp.post(tap: .cghidEventTap)
        usleep(25000)
    }

    private var isLeftButtonDown: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    private var pointerLocation: CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func postMouse(
        type: CGEventType,
        at point: CGPoint,
        gestureNumber: Int64,
        pressure: Double,
        clickCount: Int64
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw Failure.eventConstructionFailed("mouse event \(type.rawValue)")
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventNumber, value: gestureNumber)
        event.setIntegerValueField(
            .mouseEventClickState,
            value: type == .mouseMoved ? 0 : clickCount
        )
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.post(tap: .cghidEventTap)
    }

    private func waitForPointer(at point: CGPoint) -> Bool {
        for _ in 0 ..< 40 {
            if let pointerLocation,
               abs(pointerLocation.x - point.x) <= 2,
               abs(pointerLocation.y - point.y) <= 2
            {
                return true
            }
            usleep(10000)
        }
        return false
    }

    private func waitForButtonState(expectedDown: Bool) -> Bool {
        for _ in 0 ..< 30 {
            if isLeftButtonDown == expectedDown { return true }
            usleep(10000)
        }
        return false
    }
}

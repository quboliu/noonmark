import AppKit
import CoreGraphics
import Foundation
import NoonmarkMacE2ESupport
import NoonmarkMacRuntime

/// Posts E2E-only input through WindowServer so native AppKit and SwiftUI
/// interaction machinery observes the same event stream as real hardware.
@MainActor
final class WindowServerInputDriver {
    enum HorizontalTrackpadSwipeDirection {
        case left
        case right
    }

    struct MenuKeyboardSelection {
        fileprivate let highlightEvents: [CGEvent]
        fileprivate let confirmationEvents: [CGEvent]
    }

    struct MenuBarGesture {
        fileprivate let mouseDown: CGEvent
        fileprivate let mouseUp: CGEvent
    }

    struct PointerCoordinate {
        let window: NSWindow
        let windowNumber: Int
        let windowPoint: NSPoint
        let appKitScreenPoint: NSPoint
        let quartzPoint: CGPoint
        let topology: WindowServerInputTopology

        var report: String {
            "windowNumber=\(windowNumber),windowPoint=\(windowPoint),"
                + "appkit=\(appKitScreenPoint),quartz=\(quartzPoint),"
                + "topology={\(Self.describe(topology))}"
        }

        private static func describe(
            _ topology: WindowServerInputTopology
        ) -> String {
            [
                "window=\(topology.windowNumber)",
                "role=\(topology.accessibilityRole ?? "nil")",
                "subrole=\(topology.accessibilitySubrole ?? "nil")",
                "attachedSheet=\(topology.attachedSheetWindowNumber?.description ?? "nil")",
                "sheetParent=\(topology.sheetParentWindowNumber?.description ?? "nil")",
                "parentAttachedSheet="
                    + "\(topology.sheetParentAttachedSheetWindowNumber?.description ?? "nil")",
                "modal=\(topology.modalWindowNumber?.description ?? "nil")"
            ].joined(separator: ",")
        }
    }

    struct InputContextReport {
        let appActive: Bool
        let expectedWindowIsKey: Bool
        let expectedWindowVisible: Bool
        let expectedWindowMiniaturized: Bool
        let leftButtonDown: Bool
        let expectedWindow: String
        let currentKeyWindow: String
        let expectedAttachedSheet: String
        let currentKeyWindowSheetParent: String
        let modalWindow: String
        let violation: String

        var report: String {
            [
                "appActive=\(appActive)",
                "expectedWindowIsKey=\(expectedWindowIsKey)",
                "expectedWindowVisible=\(expectedWindowVisible)",
                "expectedWindowMiniaturized=\(expectedWindowMiniaturized)",
                "leftButtonDown=\(leftButtonDown)",
                "expectedWindow=\(expectedWindow)",
                "currentKeyWindow=\(currentKeyWindow)",
                "expectedAttachedSheet=\(expectedAttachedSheet)",
                "currentKeyWindowSheetParent=\(currentKeyWindowSheetParent)",
                "modalWindow=\(modalWindow)",
                "violation=\(violation)"
            ].joined(separator: ",")
        }
    }

    struct PointerSettlementReport {
        let expected: CGPoint
        let initial: CGPoint?
        let last: CGPoint?
        let sampleCount: Int
        let postCount: Int
        let inputContext: InputContextReport

        var report: String {
            [
                "expected=\(expected)",
                "initial=\(Self.describe(initial))",
                "last=\(Self.describe(last))",
                "samples=\(sampleCount)",
                "posts=\(postCount)",
                inputContext.report
            ].joined(separator: ",")
        }

        private static func describe(_ point: CGPoint?) -> String {
            point.map { String(describing: $0) } ?? "unavailable"
        }
    }

    enum Failure: LocalizedError {
        case eventAccessUnavailable
        case eventSourceUnavailable
        case eventConstructionFailed(String)
        case coordinateRoundTripFailed(expected: NSPoint, actual: NSPoint)
        case inputContextUnavailable(InputContextReport)
        case targetBecameUnavailable(point: CGPoint, InputContextReport)
        case pointerDidNotSettle(PointerSettlementReport)
        case buttonStateDidNotChange(expectedDown: Bool)
        case releaseCleanupFailed(original: String, cleanup: String)
        case menuBarTargetUnavailable(expected: CGPoint, actual: CGPoint?)
        case menuBarInputContextUnavailable(appActive: Bool, leftButtonDown: Bool)

        var errorDescription: String? {
            switch self {
            case .eventAccessUnavailable:
                return "WindowServer event-posting access is unavailable"
            case .eventSourceUnavailable:
                return "WindowServer combined-session event source is unavailable"
            case let .eventConstructionFailed(kind):
                return "WindowServer could not construct \(kind)"
            case let .coordinateRoundTripFailed(expected, actual):
                return "WindowServer coordinate round trip differed: expected "
                    + "\(expected), actual \(actual)"
            case let .inputContextUnavailable(context):
                return "WindowServer input context unavailable: \(context.report)"
            case let .targetBecameUnavailable(point, context):
                return "WindowServer click target moved or disappeared before mouseDown: "
                    + "point=\(point),\(context.report)"
            case let .pointerDidNotSettle(report):
                return "WindowServer pointer did not settle: \(report.report)"
            case let .buttonStateDidNotChange(expectedDown):
                return "WindowServer left button did not become "
                    + (expectedDown ? "down" : "up")
            case let .releaseCleanupFailed(original, cleanup):
                return "WindowServer click failed (\(original)); left-button cleanup "
                    + "also failed (\(cleanup))"
            case let .menuBarTargetUnavailable(expected, actual):
                return "WindowServer menu-bar target moved or disappeared: expected "
                    + "\(expected), actual \(String(describing: actual))"
            case let .menuBarInputContextUnavailable(appActive, leftButtonDown):
                return "WindowServer menu-bar input context unavailable: "
                    + "appActive=\(appActive),leftButtonDown=\(leftButtonDown)"
            }
        }
    }

    private static var nextGestureNumber = Int64(
        ProcessInfo.processInfo.systemUptime * 1000
    )

    private let source: CGEventSource
    private let userData: Int64

    init(requestEventAccessIfNeeded: Bool = false) throws {
        let hasEventAccess = CGPreflightPostEventAccess()
            || (requestEventAccessIfNeeded && CGRequestPostEventAccess())
        guard hasEventAccess else {
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
            window: window,
            windowNumber: window.windowNumber,
            windowPoint: windowPoint,
            appKitScreenPoint: appKitScreenPoint,
            quartzPoint: quartzPoint,
            topology: inputTopology(for: window)
        )
    }

    func pointerCoordinate(
        quartzPoint: CGPoint,
        in window: NSWindow
    ) throws -> PointerCoordinate {
        let appKitScreenPoint = NSPoint(
            x: quartzPoint.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - quartzPoint.y
        )
        let windowPoint = window.convertPoint(fromScreen: appKitScreenPoint)
        let coordinate = try pointerCoordinate(
            windowPoint: windowPoint,
            in: window
        )
        guard pointsAreNear(coordinate.quartzPoint, quartzPoint) else {
            throw Failure.coordinateRoundTripFailed(
                expected: appKitScreenPoint,
                actual: coordinate.appKitScreenPoint
            )
        }
        return coordinate
    }

    func postMouse(
        type: CGEventType,
        at point: CGPoint,
        gestureNumber: Int64,
        modifiers: NSEvent.ModifierFlags = [],
        pressure: Double,
        clickCount: Int64 = 1
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
            value: type == .mouseMoved ? 0 : clickCount
        )
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.post(tap: .cghidEventTap)
    }

    func postClick(
        at initialCoordinate: PointerCoordinate,
        modifiers: NSEvent.ModifierFlags,
        resolveTarget: () throws -> PointerCoordinate
    ) async throws {
        try await postClickGesture(
            at: initialCoordinate,
            modifiers: modifiers,
            clickCount: 1,
            resolveTarget: resolveTarget
        )
    }

    func postDoubleClick(
        at initialCoordinate: PointerCoordinate,
        modifiers: NSEvent.ModifierFlags,
        resolveTarget: () throws -> PointerCoordinate
    ) async throws {
        try await postClickGesture(
            at: initialCoordinate,
            modifiers: modifiers,
            clickCount: 1,
            resolveTarget: resolveTarget
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        try await postClickGesture(
            at: initialCoordinate,
            modifiers: modifiers,
            clickCount: 2,
            resolveTarget: resolveTarget
        )
    }

    func postHorizontalTrackpadSwipe(
        at initialCoordinate: PointerCoordinate,
        toward direction: HorizontalTrackpadSwipeDirection,
        resolveTarget: () throws -> PointerCoordinate
    ) async throws {
        try Task.checkCancellation()
        try requireResolvedTarget(
            initialCoordinate,
            matching: initialCoordinate,
            expectedButtonState: .up
        )
        let settledCoordinate = try await positionPointer(
            initialCoordinate: initialCoordinate,
            expectedCoordinate: initialCoordinate,
            gestureNumber: nextMouseGestureNumber(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
        let deviceSign: Int32 = direction == .left ? 1 : -1
        let eventSign = syntheticScrollDirectionIsInverted()
            ? -deviceSign
            : deviceSign
        let samples: [(
            delta: Int32,
            scrollPhase: Int64,
            momentumPhase: Int64
        )] = [
            (2 * eventSign, 1, 0),
            (0, 2, 0),
            (0, 4, 0),
            (73 * eventSign, 0, 1),
            (660 * eventSign, 0, 2),
            (0, 0, 3)
        ]

        for sample in samples {
            try Task.checkCancellation()
            let resolvedCoordinate = try resolveTarget()
            try requireResolvedTarget(
                resolvedCoordinate,
                matching: settledCoordinate,
                expectedButtonState: .up
            )
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: sample.delta,
                wheel3: 0
            ) else {
                throw Failure.eventConstructionFailed(
                    "horizontal trackpad scroll event"
                )
            }
            event.location = resolvedCoordinate.quartzPoint
            event.flags = []
            event.setIntegerValueField(
                .eventSourceUserData,
                value: userData
            )
            event.setIntegerValueField(
                .scrollWheelEventIsContinuous,
                value: 1
            )
            event.setIntegerValueField(
                .scrollWheelEventScrollPhase,
                value: sample.scrollPhase
            )
            event.setIntegerValueField(
                .scrollWheelEventMomentumPhase,
                value: sample.momentumPhase
            )
            event.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func syntheticScrollDirectionIsInverted() -> Bool {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 1,
            wheel3: 0
        ), let appKitEvent = NSEvent(cgEvent: event)
        else {
            return false
        }
        return appKitEvent.isDirectionInvertedFromDevice
    }

    private func postClickGesture(
        at initialCoordinate: PointerCoordinate,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int64,
        resolveTarget: () throws -> PointerCoordinate
    ) async throws {
        try Task.checkCancellation()
        try requireResolvedTarget(
            initialCoordinate,
            matching: initialCoordinate,
            expectedButtonState: .up
        )
        let gestureNumber = nextMouseGestureNumber()
        let settledCoordinate = try await positionPointer(
            initialCoordinate: initialCoordinate,
            expectedCoordinate: initialCoordinate,
            gestureNumber: gestureNumber,
            modifiers: modifiers,
            resolveTarget: resolveTarget
        )
        try Task.checkCancellation()
        let finalCoordinate = try resolveTarget()
        try requireResolvedTarget(
            finalCoordinate,
            matching: initialCoordinate,
            expectedButtonState: .up
        )
        guard pointsAreNear(
            settledCoordinate.quartzPoint,
            finalCoordinate.quartzPoint
        ), currentPointerLocation.map({
            pointsAreNear($0, finalCoordinate.quartzPoint)
        }) == true else {
            throw Failure.targetBecameUnavailable(
                point: finalCoordinate.quartzPoint,
                inputContext(
                    expectedCoordinate: initialCoordinate,
                    expectedButtonState: .up
                )
            )
        }
        try Task.checkCancellation()
        try requireResolvedTarget(
            finalCoordinate,
            matching: initialCoordinate,
            expectedButtonState: .up
        )

        var mouseDownWasPosted = false
        do {
            try postMouse(
                type: .leftMouseDown,
                at: finalCoordinate.quartzPoint,
                gestureNumber: gestureNumber,
                modifiers: modifiers,
                pressure: 1,
                clickCount: clickCount
            )
            mouseDownWasPosted = true
            try Task.checkCancellation()
            guard try await waitForButtonState(
                expectedDown: true,
                validateContext: {
                    try self.requireResolvedTarget(
                        finalCoordinate,
                        matching: initialCoordinate,
                        expectedButtonState: .any
                    )
                }
            ) else {
                throw Failure.buttonStateDidNotChange(expectedDown: true)
            }
            try await releaseLeftButton(
                at: finalCoordinate.quartzPoint,
                gestureNumber: gestureNumber,
                modifiers: modifiers,
                clickCount: clickCount
            )
            try Task.checkCancellation()
        } catch {
            let originalError = error
            guard mouseDownWasPosted else { throw originalError }
            do {
                try await releaseLeftButton(
                    at: finalCoordinate.quartzPoint,
                    gestureNumber: gestureNumber,
                    modifiers: modifiers,
                    clickCount: clickCount
                )
            } catch {
                throw Failure.releaseCleanupFailed(
                    original: originalError.localizedDescription,
                    cleanup: error.localizedDescription
                )
            }
            throw originalError
        }
    }

    func prepareMenuKeyboardSelection() throws -> MenuKeyboardSelection {
        guard let downArrowDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 125,
            keyDown: true
        ), let downArrowUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 125,
            keyDown: false
        ), let confirmDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 36,
            keyDown: true
        ), let confirmUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 36,
            keyDown: false
        ) else {
            throw Failure.eventConstructionFailed("native menu keyboard selection")
        }
        let highlightEvents = [downArrowDown, downArrowUp]
        let confirmationEvents = [confirmDown, confirmUp]
        let inheritedModifierFlags = Self.cgFlags(
            for: [.command, .shift, .control, .option]
        )
        for event in highlightEvents + confirmationEvents {
            event.flags.subtract(inheritedModifierFlags)
            event.setIntegerValueField(.eventSourceUserData, value: userData)
        }
        return MenuKeyboardSelection(
            highlightEvents: highlightEvents,
            confirmationEvents: confirmationEvents
        )
    }

    /// Prepares a menu-bar gesture without posting mouse-up before AppKit has
    /// reported that the menu entered its modal tracking loop.
    func prepareMenuBarGesture(
        at initialPoint: CGPoint,
        resolveSource: () -> CGPoint?
    ) async throws -> MenuBarGesture {
        try Task.checkCancellation()
        try requireMenuBarTarget(
            initialPoint,
            resolved: resolveSource(),
            expectedButtonDown: false
        )
        let gestureNumber = nextMouseGestureNumber()
        var pointerSettled = false
        for attempt in 0 ..< 30 {
            try Task.checkCancellation()
            let resolved = resolveSource()
            try requireMenuBarTarget(
                initialPoint,
                resolved: resolved,
                expectedButtonDown: false
            )
            if attempt.isMultiple(of: 6) || currentPointerLocation.map({
                pointsAreNear($0, initialPoint)
            }) != true {
                try postMouse(
                    type: .mouseMoved,
                    at: initialPoint,
                    gestureNumber: gestureNumber,
                    pressure: 0
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            if currentPointerLocation.map({
                pointsAreNear($0, initialPoint)
            }) == true {
                pointerSettled = true
                break
            }
        }
        guard pointerSettled else {
            throw Failure.pointerDidNotSettle(
                PointerSettlementReport(
                    expected: initialPoint,
                    initial: nil,
                    last: currentPointerLocation,
                    sampleCount: 30,
                    postCount: 5,
                    inputContext: InputContextReport(
                        appActive: NSApp.isActive,
                        expectedWindowIsKey: false,
                        expectedWindowVisible: false,
                        expectedWindowMiniaturized: false,
                        leftButtonDown: isLeftButtonDown,
                        expectedWindow: "menu-bar",
                        currentKeyWindow: Self.describeWindow(NSApp.keyWindow),
                        expectedAttachedSheet: "nil",
                        currentKeyWindowSheetParent: "nil",
                        modalWindow: Self.describeWindow(NSApp.modalWindow),
                        violation: "menu-bar pointer did not settle"
                    )
                )
            )
        }
        try requireMenuBarTarget(
            initialPoint,
            resolved: resolveSource(),
            expectedButtonDown: false
        )

        guard let mouseDown = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: initialPoint,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: initialPoint,
            mouseButton: .left
        ) else {
            throw Failure.eventConstructionFailed("native menu-bar click")
        }
        for event in [mouseDown, mouseUp] {
            event.setIntegerValueField(.eventSourceUserData, value: userData)
            event.setIntegerValueField(.mouseEventNumber, value: gestureNumber)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        mouseDown.setDoubleValueField(.mouseEventPressure, value: 1)
        mouseUp.setDoubleValueField(.mouseEventPressure, value: 0)
        return MenuBarGesture(mouseDown: mouseDown, mouseUp: mouseUp)
    }

    func postMenuBarKeyboardSelection(
        _ gesture: MenuBarGesture,
        selection: MenuKeyboardSelection
    ) {
        let events = [gesture.mouseDown, gesture.mouseUp]
            + selection.highlightEvents
            + selection.confirmationEvents
        let baseTimestamp = DispatchTime.now().uptimeNanoseconds
        for (offset, event) in events.enumerated() {
            event.timestamp = baseTimestamp + UInt64(offset)
            event.post(tap: .cghidEventTap)
        }
    }

    func postMenuBarMouseUp(_ gesture: MenuBarGesture) {
        gesture.mouseUp.post(tap: .cghidEventTap)
    }

    func waitForMenuBarMouseUp() async throws {
        await cancellationInsensitivePause()
        for _ in 0 ..< 60 {
            if isLeftButtonDown == false {
                try Task.checkCancellation()
                return
            }
            await cancellationInsensitivePause()
        }
        throw Failure.buttonStateDidNotChange(expectedDown: false)
    }

    func postKey(
        keyCode: CGKeyCode,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
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
        let flags = Self.cgFlags(for: modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.setIntegerValueField(.eventSourceUserData, value: userData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: userData)
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
        keyUp.post(tap: .cghidEventTap)
    }

    func typeUnicode(_ text: String) throws {
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
            // A combined-session source inherits the previous shortcut flags.
            // Unicode typing must explicitly release them after e.g. Command-A.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.setIntegerValueField(.eventSourceUserData, value: userData)
            keyUp.setIntegerValueField(.eventSourceUserData, value: userData)
            keyDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
            keyUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
        }
    }

    private func positionPointer(
        initialCoordinate: PointerCoordinate,
        expectedCoordinate: PointerCoordinate,
        gestureNumber: Int64,
        modifiers: NSEvent.ModifierFlags,
        resolveTarget: () throws -> PointerCoordinate
    ) async throws -> PointerCoordinate {
        let initial = currentPointerLocation
        var last = initial
        var lastTarget = initialCoordinate.quartzPoint
        var sampleCount = 0
        var postCount = 0
        var consecutiveSettledSamples = 0

        for attempt in 0 ..< 30 {
            try Task.checkCancellation()
            let resolvedCoordinate = try resolveTarget()
            try requireResolvedTarget(
                resolvedCoordinate,
                matching: expectedCoordinate,
                expectedButtonState: .up
            )
            if pointsAreNear(
                resolvedCoordinate.quartzPoint,
                lastTarget
            ) == false {
                consecutiveSettledSamples = 0
            }
            lastTarget = resolvedCoordinate.quartzPoint
            let pointerNeedsRepost = currentPointerLocation.map {
                pointsAreNear($0, resolvedCoordinate.quartzPoint)
            } != true
            if attempt.isMultiple(of: 6) || pointerNeedsRepost {
                try requireResolvedTarget(
                    resolvedCoordinate,
                    matching: expectedCoordinate,
                    expectedButtonState: .up
                )
                try postMouse(
                    type: .mouseMoved,
                    at: resolvedCoordinate.quartzPoint,
                    gestureNumber: gestureNumber,
                    modifiers: modifiers,
                    pressure: 0
                )
                postCount += 1
                try requireResolvedTarget(
                    resolvedCoordinate,
                    matching: expectedCoordinate,
                    expectedButtonState: .up
                )
            }
            last = currentPointerLocation
            sampleCount += 1
            let pointerIsSettled = last.map {
                pointsAreNear($0, resolvedCoordinate.quartzPoint)
            } == true
            if pointerIsSettled {
                consecutiveSettledSamples += 1
                if consecutiveSettledSamples >= 2 {
                    return resolvedCoordinate
                }
            } else {
                consecutiveSettledSamples = 0
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        throw Failure.pointerDidNotSettle(
            PointerSettlementReport(
                expected: lastTarget,
                initial: initial,
                last: last,
                sampleCount: sampleCount,
                postCount: postCount,
                inputContext: inputContext(
                    expectedCoordinate: expectedCoordinate,
                    expectedButtonState: .up
                )
            )
        )
    }

    private func waitForButtonState(
        expectedDown: Bool,
        validateContext: () throws -> Void
    ) async throws -> Bool {
        for _ in 0 ..< 30 {
            try validateContext()
            if isLeftButtonDown == expectedDown { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func releaseLeftButton(
        at point: CGPoint,
        gestureNumber: Int64,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int64 = 1
    ) async throws {
        try postMouse(
            type: .leftMouseUp,
            at: point,
            gestureNumber: gestureNumber,
            modifiers: modifiers,
            pressure: 0,
            clickCount: clickCount
        )
        await cancellationInsensitivePause()
        for attempt in 0 ..< 30 {
            if isLeftButtonDown == false { return }
            if attempt > 0, attempt.isMultiple(of: 10) {
                try postMouse(
                    type: .leftMouseUp,
                    at: point,
                    gestureNumber: gestureNumber,
                    modifiers: modifiers,
                    pressure: 0,
                    clickCount: clickCount
                )
            }
            await cancellationInsensitivePause()
        }
        throw Failure.buttonStateDidNotChange(expectedDown: false)
    }

    private func cancellationInsensitivePause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                continuation.resume()
            }
        }
    }

    private func requireMenuBarTarget(
        _ expected: CGPoint,
        resolved: CGPoint?,
        expectedButtonDown: Bool
    ) throws {
        guard NSApp.isActive,
              isLeftButtonDown == expectedButtonDown
        else {
            throw Failure.menuBarInputContextUnavailable(
                appActive: NSApp.isActive,
                leftButtonDown: isLeftButtonDown
            )
        }
        guard expected.x.isFinite,
              expected.y.isFinite,
              CGDisplayBounds(CGMainDisplayID()).contains(expected),
              let resolved,
              pointsAreNear(resolved, expected)
        else {
            throw Failure.menuBarTargetUnavailable(
                expected: expected,
                actual: resolved
            )
        }
    }

    private func inputContext(
        expectedCoordinate: PointerCoordinate,
        expectedButtonState: WindowServerExpectedButtonState
    ) -> InputContextReport {
        let expectedWindow = expectedCoordinate.window
        let currentKeyWindow = NSApp.keyWindow
        let currentSnapshot = inputContextSnapshot(for: expectedWindow)
        let violation = WindowServerInputContextContract.violation(
            expectedTopology: expectedCoordinate.topology,
            current: currentSnapshot,
            expectedButtonState: expectedButtonState
        )
        return InputContextReport(
            appActive: NSApp.isActive,
            expectedWindowIsKey: currentKeyWindow === expectedWindow,
            expectedWindowVisible: expectedWindow.isVisible,
            expectedWindowMiniaturized: expectedWindow.isMiniaturized,
            leftButtonDown: isLeftButtonDown,
            expectedWindow: Self.describeWindow(expectedWindow),
            currentKeyWindow: Self.describeWindow(currentKeyWindow),
            expectedAttachedSheet: Self.describeWindow(
                expectedWindow.attachedSheet
            ),
            currentKeyWindowSheetParent: Self.describeWindow(
                currentKeyWindow?.sheetParent
            ),
            modalWindow: Self.describeWindow(NSApp.modalWindow),
            violation: violation.map { String(describing: $0) } ?? "nil"
        )
    }

    func requireResolvedTarget(
        _ coordinate: PointerCoordinate,
        matching expectedCoordinate: PointerCoordinate,
        expectedButtonState: WindowServerExpectedButtonState
    ) throws {
        guard coordinate.window === expectedCoordinate.window,
              coordinate.windowNumber == expectedCoordinate.windowNumber
        else {
            throw Failure.targetBecameUnavailable(
                point: coordinate.quartzPoint,
                inputContext(
                    expectedCoordinate: expectedCoordinate,
                    expectedButtonState: expectedButtonState
                )
            )
        }
        let snapshot = inputContextSnapshot(for: expectedCoordinate.window)
        guard WindowServerInputContextContract.violation(
            expectedTopology: expectedCoordinate.topology,
            current: snapshot,
            expectedButtonState: expectedButtonState
        ) == nil else {
            let context = inputContext(
                expectedCoordinate: expectedCoordinate,
                expectedButtonState: expectedButtonState
            )
            throw Failure.inputContextUnavailable(context)
        }
    }

    private func inputContextSnapshot(
        for expectedWindow: NSWindow
    ) -> WindowServerInputContextSnapshot {
        WindowServerInputContextSnapshot(
            topology: inputTopology(for: expectedWindow),
            appIsActive: NSApp.isActive,
            keyWindowNumber: NSApp.keyWindow?.windowNumber,
            targetIsVisible: expectedWindow.isVisible,
            targetIsMiniaturized: expectedWindow.isMiniaturized,
            leftButtonIsDown: isLeftButtonDown
        )
    }

    private func inputTopology(
        for window: NSWindow
    ) -> WindowServerInputTopology {
        WindowServerInputTopology(
            windowNumber: window.windowNumber,
            accessibilityRole: window.accessibilityRole()?.rawValue,
            accessibilitySubrole: window.accessibilitySubrole()?.rawValue,
            attachedSheetWindowNumber: window.attachedSheet?.windowNumber,
            sheetParentWindowNumber: window.sheetParent?.windowNumber,
            sheetParentAttachedSheetWindowNumber:
                window.sheetParent?.attachedSheet?.windowNumber,
            modalWindowNumber: NSApp.modalWindow?.windowNumber
        )
    }

    private func pointsAreNear(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }

    private static func describeWindow(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(String(describing: type(of: window)))"
            + "[number=\(window.windowNumber),title=\(window.title),"
            + "visible=\(window.isVisible),mini=\(window.isMiniaturized),"
            + "key=\(window.isKeyWindow),main=\(window.isMainWindow),"
            + "sheetParent=\(window.sheetParent?.windowNumber.description ?? "nil"),"
            + "attachedSheet=\(window.attachedSheet?.windowNumber.description ?? "nil")]"
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

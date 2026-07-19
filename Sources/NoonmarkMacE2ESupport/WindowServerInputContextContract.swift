import Foundation

public struct WindowServerInputTopology: Equatable, Sendable {
    public let windowNumber: Int
    public let accessibilityRole: String?
    public let accessibilitySubrole: String?
    public let attachedSheetWindowNumber: Int?
    public let sheetParentWindowNumber: Int?
    public let sheetParentAttachedSheetWindowNumber: Int?
    public let modalWindowNumber: Int?

    public init(
        windowNumber: Int,
        accessibilityRole: String?,
        accessibilitySubrole: String?,
        attachedSheetWindowNumber: Int?,
        sheetParentWindowNumber: Int?,
        sheetParentAttachedSheetWindowNumber: Int?,
        modalWindowNumber: Int?
    ) {
        self.windowNumber = windowNumber
        self.accessibilityRole = accessibilityRole
        self.accessibilitySubrole = accessibilitySubrole
        self.attachedSheetWindowNumber = attachedSheetWindowNumber
        self.sheetParentWindowNumber = sheetParentWindowNumber
        self.sheetParentAttachedSheetWindowNumber =
            sheetParentAttachedSheetWindowNumber
        self.modalWindowNumber = modalWindowNumber
    }
}

public struct WindowServerInputContextSnapshot: Equatable, Sendable {
    public let topology: WindowServerInputTopology
    public let appIsActive: Bool
    public let keyWindowNumber: Int?
    public let targetIsVisible: Bool
    public let targetIsMiniaturized: Bool
    public let leftButtonIsDown: Bool

    public init(
        topology: WindowServerInputTopology,
        appIsActive: Bool,
        keyWindowNumber: Int?,
        targetIsVisible: Bool,
        targetIsMiniaturized: Bool,
        leftButtonIsDown: Bool
    ) {
        self.topology = topology
        self.appIsActive = appIsActive
        self.keyWindowNumber = keyWindowNumber
        self.targetIsVisible = targetIsVisible
        self.targetIsMiniaturized = targetIsMiniaturized
        self.leftButtonIsDown = leftButtonIsDown
    }
}

public enum WindowServerExpectedButtonState: Equatable, Sendable {
    case up
    case down
    case any
}

public enum WindowServerInputContextViolation: Equatable, Sendable {
    case appInactive
    case keyWindowChanged(expected: Int, actual: Int?)
    case targetHidden
    case targetMiniaturized
    case leftButtonStateChanged(expected: WindowServerExpectedButtonState)
    case targetTopologyChanged(
        expected: WindowServerInputTopology,
        actual: WindowServerInputTopology
    )
}

public enum WindowServerInputContextContract {
    public static func violation(
        expectedTopology: WindowServerInputTopology,
        current: WindowServerInputContextSnapshot,
        expectedButtonState: WindowServerExpectedButtonState
    ) -> WindowServerInputContextViolation? {
        guard current.topology == expectedTopology else {
            return .targetTopologyChanged(
                expected: expectedTopology,
                actual: current.topology
            )
        }
        guard current.appIsActive else {
            return .appInactive
        }
        guard current.keyWindowNumber == expectedTopology.windowNumber else {
            return .keyWindowChanged(
                expected: expectedTopology.windowNumber,
                actual: current.keyWindowNumber
            )
        }
        guard current.targetIsVisible else {
            return .targetHidden
        }
        guard current.targetIsMiniaturized == false else {
            return .targetMiniaturized
        }
        switch expectedButtonState {
        case .up where current.leftButtonIsDown:
            return .leftButtonStateChanged(expected: .up)
        case .down where current.leftButtonIsDown == false:
            return .leftButtonStateChanged(expected: .down)
        case .up, .down, .any:
            break
        }
        return nil
    }
}

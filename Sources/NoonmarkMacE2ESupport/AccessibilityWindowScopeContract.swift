import Foundation

public struct AccessibilityWindowCandidate: Equatable, Sendable {
    public let windowNumber: Int
    public let identifier: String?

    public init(windowNumber: Int, identifier: String?) {
        self.windowNumber = windowNumber
        self.identifier = identifier
    }
}

public struct AccessibilityFocusedElementScopeSnapshot: Equatable, Sendable {
    public let expectedWindowNumber: Int
    public let keyWindowNumber: Int?
    public let focusedWindowNumber: Int?
    public let elementBelongsToExpectedWindowRoot: Bool

    public init(
        expectedWindowNumber: Int,
        keyWindowNumber: Int?,
        focusedWindowNumber: Int?,
        elementBelongsToExpectedWindowRoot: Bool
    ) {
        self.expectedWindowNumber = expectedWindowNumber
        self.keyWindowNumber = keyWindowNumber
        self.focusedWindowNumber = focusedWindowNumber
        self.elementBelongsToExpectedWindowRoot =
            elementBelongsToExpectedWindowRoot
    }
}

public enum AccessibilityWindowScopeContract {
    public static func uniqueCandidateIndex(
        identifier: String,
        expectedWindowNumber: Int,
        keyWindowNumber: Int?,
        focusedWindowNumber: Int?,
        candidates: [AccessibilityWindowCandidate]
    ) -> Int? {
        guard expectedWindowNumber > 0,
              keyWindowNumber == expectedWindowNumber,
              focusedWindowNumber == expectedWindowNumber
        else {
            return nil
        }
        let matchingIndices = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.windowNumber == expectedWindowNumber
                && candidate.identifier == identifier
        }
        guard matchingIndices.count == 1 else { return nil }
        return matchingIndices[0]
    }

    public static func acceptsStableFocusedElement(
        initial: AccessibilityFocusedElementScopeSnapshot,
        current: AccessibilityFocusedElementScopeSnapshot,
        windowRootIsStable: Bool,
        focusedElementIsStable: Bool
    ) -> Bool {
        guard initial.expectedWindowNumber > 0,
              initial.expectedWindowNumber == current.expectedWindowNumber,
              initial.keyWindowNumber == initial.expectedWindowNumber,
              initial.focusedWindowNumber == initial.expectedWindowNumber,
              current.keyWindowNumber == current.expectedWindowNumber,
              current.focusedWindowNumber == current.expectedWindowNumber,
              initial.elementBelongsToExpectedWindowRoot,
              current.elementBelongsToExpectedWindowRoot,
              windowRootIsStable,
              focusedElementIsStable
        else {
            return false
        }
        return true
    }
}

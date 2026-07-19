import NoonmarkMacE2ESupport
import XCTest

final class AccessibilityWindowScopeContractTests: XCTestCase {
    func testSelectsUniqueIdentifierOnlyInsideExpectedWindow() {
        let candidates = [
            AccessibilityWindowCandidate(
                windowNumber: 7,
                identifier: "completion.button"
            ),
            AccessibilityWindowCandidate(
                windowNumber: 42,
                identifier: "completion.button"
            )
        ]

        XCTAssertEqual(
            AccessibilityWindowScopeContract.uniqueCandidateIndex(
                identifier: "completion.button",
                expectedWindowNumber: 7,
                keyWindowNumber: 7,
                focusedWindowNumber: 7,
                candidates: candidates
            ),
            0
        )
    }

    func testRejectsDuplicateIdentifierInsideExpectedWindow() {
        let candidates = [
            AccessibilityWindowCandidate(
                windowNumber: 7,
                identifier: "completion.button"
            ),
            AccessibilityWindowCandidate(
                windowNumber: 7,
                identifier: "completion.button"
            )
        ]

        XCTAssertNil(
            AccessibilityWindowScopeContract.uniqueCandidateIndex(
                identifier: "completion.button",
                expectedWindowNumber: 7,
                keyWindowNumber: 7,
                focusedWindowNumber: 7,
                candidates: candidates
            )
        )
    }

    func testRejectsKeyOrFocusedWindowMismatch() {
        let candidates = [
            AccessibilityWindowCandidate(
                windowNumber: 7,
                identifier: "completion.button"
            )
        ]

        XCTAssertNil(
            AccessibilityWindowScopeContract.uniqueCandidateIndex(
                identifier: "completion.button",
                expectedWindowNumber: 7,
                keyWindowNumber: 42,
                focusedWindowNumber: 7,
                candidates: candidates
            )
        )
        XCTAssertNil(
            AccessibilityWindowScopeContract.uniqueCandidateIndex(
                identifier: "completion.button",
                expectedWindowNumber: 7,
                keyWindowNumber: 7,
                focusedWindowNumber: 42,
                candidates: candidates
            )
        )
    }

    func testRejectsFocusedElementFromAnotherWindowRoot() {
        let initial = AccessibilityFocusedElementScopeSnapshot(
            expectedWindowNumber: 7,
            keyWindowNumber: 7,
            focusedWindowNumber: 7,
            elementBelongsToExpectedWindowRoot: false
        )

        XCTAssertFalse(
            AccessibilityWindowScopeContract.acceptsStableFocusedElement(
                initial: initial,
                current: initial,
                windowRootIsStable: true,
                focusedElementIsStable: true
            )
        )
    }

    func testRejectsFocusedElementOrWindowDriftDuringQuery() {
        let initial = focusedElementScope()

        XCTAssertFalse(
            AccessibilityWindowScopeContract.acceptsStableFocusedElement(
                initial: initial,
                current: focusedElementScope(focusedWindowNumber: 42),
                windowRootIsStable: true,
                focusedElementIsStable: true
            )
        )
        XCTAssertFalse(
            AccessibilityWindowScopeContract.acceptsStableFocusedElement(
                initial: initial,
                current: initial,
                windowRootIsStable: true,
                focusedElementIsStable: false
            )
        )
        XCTAssertFalse(
            AccessibilityWindowScopeContract.acceptsStableFocusedElement(
                initial: initial,
                current: initial,
                windowRootIsStable: false,
                focusedElementIsStable: true
            )
        )
    }

    func testAcceptsStableFocusedElementInsideExpectedWindowRoot() {
        let scope = focusedElementScope()

        XCTAssertTrue(
            AccessibilityWindowScopeContract.acceptsStableFocusedElement(
                initial: scope,
                current: scope,
                windowRootIsStable: true,
                focusedElementIsStable: true
            )
        )
    }

    private func focusedElementScope(
        keyWindowNumber: Int? = 7,
        focusedWindowNumber: Int? = 7,
        elementBelongsToExpectedWindowRoot: Bool = true
    ) -> AccessibilityFocusedElementScopeSnapshot {
        AccessibilityFocusedElementScopeSnapshot(
            expectedWindowNumber: 7,
            keyWindowNumber: keyWindowNumber,
            focusedWindowNumber: focusedWindowNumber,
            elementBelongsToExpectedWindowRoot:
                elementBelongsToExpectedWindowRoot
        )
    }
}

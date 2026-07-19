import NoonmarkMacE2ESupport
import XCTest

final class WindowServerInputContextContractTests: XCTestCase {
    func testRejectsAttachedSheetThatAppearsAfterTargetResolution() {
        let expected = topology()
        let current = context(
            topology: topology(attachedSheetWindowNumber: 42)
        )

        XCTAssertEqual(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: current,
                expectedButtonState: .up
            ),
            .targetTopologyChanged(
                expected: expected,
                actual: current.topology
            )
        )
    }

    func testRejectsModalWindowThatAppearsAfterTargetResolution() {
        let expected = topology()
        let current = context(topology: topology(modalWindowNumber: 84))

        XCTAssertEqual(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: current,
                expectedButtonState: .up
            ),
            .targetTopologyChanged(
                expected: expected,
                actual: current.topology
            )
        )
    }

    func testRejectsSheetWhoseParentRelationshipChanges() {
        let expected = topology(
            windowNumber: 42,
            sheetParentWindowNumber: 7,
            sheetParentAttachedSheetWindowNumber: 42
        )
        let current = context(
            topology: topology(
                windowNumber: 42,
                sheetParentWindowNumber: 8,
                sheetParentAttachedSheetWindowNumber: 42
            ),
            keyWindowNumber: 42
        )

        XCTAssertEqual(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: current,
                expectedButtonState: .down
            ),
            .targetTopologyChanged(
                expected: expected,
                actual: current.topology
            )
        )
    }

    func testRejectsAccessibilityRoleChangeOnReusedWindowNumber() {
        let expected = topology()
        let current = context(
            topology: topology(
                accessibilityRole: "AXSheet",
                accessibilitySubrole: nil
            )
        )

        XCTAssertEqual(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: current,
                expectedButtonState: .up
            ),
            .targetTopologyChanged(
                expected: expected,
                actual: current.topology
            )
        )
    }

    func testAcceptsStableContextForClickAndDragButtonPhases() {
        let expected = topology()

        XCTAssertNil(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: context(topology: expected),
                expectedButtonState: .up
            )
        )
        XCTAssertNil(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: context(
                    topology: expected,
                    leftButtonIsDown: true
                ),
                expectedButtonState: .down
            )
        )
        XCTAssertNil(
            WindowServerInputContextContract.violation(
                expectedTopology: expected,
                current: context(
                    topology: expected,
                    leftButtonIsDown: true
                ),
                expectedButtonState: .any
            )
        )
    }

    private func topology(
        windowNumber: Int = 7,
        accessibilityRole: String? = "AXWindow",
        accessibilitySubrole: String? = "AXStandardWindow",
        attachedSheetWindowNumber: Int? = nil,
        sheetParentWindowNumber: Int? = nil,
        sheetParentAttachedSheetWindowNumber: Int? = nil,
        modalWindowNumber: Int? = nil
    ) -> WindowServerInputTopology {
        WindowServerInputTopology(
            windowNumber: windowNumber,
            accessibilityRole: accessibilityRole,
            accessibilitySubrole: accessibilitySubrole,
            attachedSheetWindowNumber: attachedSheetWindowNumber,
            sheetParentWindowNumber: sheetParentWindowNumber,
            sheetParentAttachedSheetWindowNumber:
                sheetParentAttachedSheetWindowNumber,
            modalWindowNumber: modalWindowNumber
        )
    }

    private func context(
        topology: WindowServerInputTopology,
        keyWindowNumber: Int? = 7,
        leftButtonIsDown: Bool = false
    ) -> WindowServerInputContextSnapshot {
        WindowServerInputContextSnapshot(
            topology: topology,
            appIsActive: true,
            keyWindowNumber: keyWindowNumber,
            targetIsVisible: true,
            targetIsMiniaturized: false,
            leftButtonIsDown: leftButtonIsDown
        )
    }
}

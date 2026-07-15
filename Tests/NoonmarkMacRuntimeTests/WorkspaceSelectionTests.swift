import NoonmarkMacRuntime
import XCTest

final class WorkspaceSelectionTests: XCTestCase {
    private let items = ["a", "b", "c", "d", "e"]

    func testPlainSelectionReplacesExistingSelectionAndMovesAnchor() {
        var selection = WorkspaceSelection<String>()
        selection.select("b", in: items)
        selection.select("d", in: items)

        XCTAssertEqual(selection.selectedIDs, ["d"])
        XCTAssertEqual(selection.anchorID, "d")
        XCTAssertEqual(selection.focusedID, "d")
    }

    func testAdditiveSelectionTogglesWithoutDiscardingOtherItems() {
        var selection = WorkspaceSelection<String>()
        selection.select("b", in: items)
        selection.select("d", in: items, modifiers: .additive)
        selection.select("b", in: items, modifiers: .additive)

        XCTAssertEqual(selection.selectedIDs, ["d"])
        XCTAssertEqual(selection.anchorID, "b")
        XCTAssertEqual(selection.focusedID, "b")
    }

    func testRangeSelectionUsesStableAnchorInBothDirections() {
        var selection = WorkspaceSelection<String>()
        selection.select("d", in: items)
        selection.select("b", in: items, modifiers: .range)

        XCTAssertEqual(selection.selectedIDs, ["b", "c", "d"])
        XCTAssertEqual(selection.anchorID, "d")
        XCTAssertEqual(selection.focusedID, "b")
    }

    func testCommandShiftUnionsRangeWithExistingSelection() {
        var selection = WorkspaceSelection<String>()
        selection.select("a", in: items)
        selection.select("e", in: items, modifiers: .additive)
        selection.select("c", in: items, modifiers: [.range, .additive])

        XCTAssertEqual(selection.selectedIDs, ["a", "c", "d", "e"])
    }

    func testKeyboardMovementSupportsRangeExtensionAndClampsAtEdges() {
        var selection = WorkspaceSelection<String>()
        selection.select("b", in: items)
        selection.moveFocus(by: 1, in: items, extendingRange: true)
        selection.moveFocus(by: 10, in: items, extendingRange: true)

        XCTAssertEqual(selection.selectedIDs, ["b", "c", "d", "e"])
        XCTAssertEqual(selection.focusedID, "e")
    }

    func testSelectAllAndRetainOnlyKeepSelectionInternallyConsistent() {
        var selection = WorkspaceSelection<String>()
        selection.selectAll(in: items)
        selection.retainOnly(["b", "d"])

        XCTAssertEqual(selection.selectedIDs, ["b", "d"])
        XCTAssertTrue(selection.anchorID.map(selection.selectedIDs.contains) ?? false)
        XCTAssertTrue(selection.focusedID.map(selection.selectedIDs.contains) ?? false)

        selection.retainOnly([])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchorID)
        XCTAssertNil(selection.focusedID)
    }
}

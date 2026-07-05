import XCTest
@testable import SuntraceMacUIContract

final class MacUIDesignContractTests: XCTestCase {
    func testClaudeMacPrototypeContractCoversAllTopLevelPages() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertEqual(
            contract.pages,
            [.dayTodo, .taskPool, .futurePlans, .unfinishedPool, .completedPool, .calendar, .settings]
        )
    }

    func testContractKeepsPrototypeActionsAndModalsExplicit() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertEqual(contract.taskActions.count, 11)
        XCTAssertTrue(contract.taskActions.contains(.continueToDate))
        XCTAssertTrue(contract.taskActions.contains(.changeIntoNewTask))
        XCTAssertTrue(contract.taskActions.contains(.returnToPool))
        XCTAssertTrue(contract.taskActions.contains(.copyAsNewTask))

        XCTAssertEqual(contract.modals.count, 8)
        XCTAssertTrue(contract.modals.contains(.changeTaskDialog))
        XCTAssertTrue(contract.modals.contains(.contextMenu))
        XCTAssertTrue(contract.modals.contains(.toast))
    }

    func testContractPreservesNewBackendCapabilitiesFromPrototype() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertTrue(contract.backendCapabilities.contains(.taskDescription))
        XCTAssertTrue(contract.backendCapabilities.contains(.taskNote))
        XCTAssertTrue(contract.backendCapabilities.contains(.manualProgress))
        XCTAssertTrue(contract.backendCapabilities.contains(.subtaskDifficultyWeight))
        XCTAssertTrue(contract.backendCapabilities.contains(.weightedSubtaskProgress))
        XCTAssertTrue(contract.backendCapabilities.contains(.progressFloor))
        XCTAssertTrue(contract.backendCapabilities.contains(.calendarDaySummary))
    }

    func testDetailAndReviewSectionsAreNotOptional() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertTrue(contract.detailElements.contains(.progressSection))
        XCTAssertTrue(contract.detailElements.contains(.descriptionSection))
        XCTAssertTrue(contract.detailElements.contains(.noteSection))
        XCTAssertTrue(contract.detailElements.contains(.subtaskSection))
        XCTAssertTrue(contract.detailElements.contains(.traceTimeline))

        XCTAssertTrue(contract.reviewElements.contains(.statsCard))
        XCTAssertTrue(contract.reviewElements.contains(.segmentedStatusBar))
        XCTAssertTrue(contract.reviewElements.contains(.summaryInput))
        XCTAssertTrue(contract.reviewElements.contains(.unfinishedReasonInput))
        XCTAssertTrue(contract.reviewElements.contains(.tomorrowNoteInput))
    }
}

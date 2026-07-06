@testable import SuntraceMacUIContract
import XCTest

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

        XCTAssertEqual(contract.taskActions.count, 24)
        XCTAssertTrue(contract.taskActions.contains(.continueToDate))
        XCTAssertTrue(contract.taskActions.contains(.changeIntoNewTask))
        XCTAssertTrue(contract.taskActions.contains(.returnToPool))
        XCTAssertTrue(contract.taskActions.contains(.copyAsNewTask))
        XCTAssertTrue(contract.taskActions.contains(.addSubtask))
        XCTAssertTrue(contract.taskActions.contains(.cycleSubtaskDifficulty))
        XCTAssertTrue(contract.taskActions.contains(.dragManualProgress))
        XCTAssertTrue(contract.taskActions.contains(.editDailyReview))
        XCTAssertTrue(contract.taskActions.contains(.undo))

        XCTAssertEqual(contract.modals.count, 12)
        XCTAssertTrue(contract.modals.contains(.changeTaskDialog))
        XCTAssertTrue(contract.modals.contains(.changeDialogOldTaskStrikethroughPreview))
        XCTAssertTrue(contract.modals.contains(.changeDialogNewTaskTitleInput))
        XCTAssertTrue(contract.modals.contains(.changeDialogConfirmButton))
        XCTAssertTrue(contract.modals.contains(.contextMenu))
        XCTAssertTrue(contract.modals.contains(.toast))
        XCTAssertTrue(contract.modals.contains(.undoUnavailableToast))
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
        XCTAssertTrue(contract.backendCapabilities.contains(.completedSubtaskRecords))
        XCTAssertTrue(contract.backendCapabilities.contains(.returnedToPoolTaskPoolView))
        XCTAssertTrue(contract.backendCapabilities.contains(.changePointer))
        XCTAssertTrue(contract.backendCapabilities.contains(.syncEndpointOptions))
    }

    func testContractCoversEachPrototypePageElements() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertTrue(contract.globalElements.contains(.macWindowChrome))
        XCTAssertTrue(contract.globalElements.contains(.pageDerivedWindowTitle))
        XCTAssertTrue(contract.globalElements.contains(.appClockLogo))
        XCTAssertTrue(contract.globalElements.contains(.dateStripSelectionAnimation))
        XCTAssertTrue(contract.globalElements.contains(.semanticStatusStyles))
        XCTAssertTrue(contract.globalElements.contains(.protectedActionButtonLabels))
        XCTAssertTrue(contract.windowMetrics.contains(.prototypePreview1440x900))
        XCTAssertTrue(contract.windowMetrics.contains(.maxContent1400x880))
        XCTAssertTrue(contract.colorTokens.contains(.accent))
        XCTAssertTrue(contract.colorTokens.contains(.ok))
        XCTAssertTrue(contract.colorTokens.contains(.warn))
        XCTAssertTrue(contract.colorTokens.contains(.chip))
        XCTAssertTrue(contract.colorTokens.contains(.panel))
        XCTAssertTrue(contract.colorTokens.contains(.line))
        XCTAssertTrue(contract.colorTokens.contains(.t1))
        XCTAssertTrue(contract.colorTokens.contains(.t2))
        XCTAssertTrue(contract.colorTokens.contains(.t3))
        XCTAssertTrue(contract.navigationElements.contains(.semanticIconColors))
        XCTAssertTrue(contract.navigationElements.contains(.countBadges))
        XCTAssertEqual(
            Set(contract.navigationIconColorTokens),
            Set(MacUINavigationIconColorToken.allCases)
        )
        XCTAssertEqual(MacUINavigationIconColorToken.dayTodo.hexValue, "#2A6FDB")
        XCTAssertEqual(MacUINavigationIconColorToken.taskPool.hexValue, "#0E9488")
        XCTAssertEqual(MacUINavigationIconColorToken.futurePlans.hexValue, "#7C5CFF")
        XCTAssertEqual(MacUINavigationIconColorToken.unfinishedPool.hexValue, "#E0851B")
        XCTAssertEqual(MacUINavigationIconColorToken.completedPool.hexValue, "#1F8A5B")
        XCTAssertEqual(MacUINavigationIconColorToken.calendar.hexValue, "#D1477A")
        XCTAssertEqual(MacUINavigationIconColorToken.zhulongAI.hexValue, "#7C5CFF")
        XCTAssertEqual(MacUINavigationIconColorToken.settings.hexValue, "#64748B")

        XCTAssertTrue(contract.dayTodoElements.contains(.fourteenDayStrip))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripSelectedPill))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTodayOutline))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripSelectedDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTaskPresenceDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowSelectedState))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowStatusDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTitle))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTrajectoryMetadata))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowMoveButtons))
        XCTAssertTrue(contract.taskPoolElements.contains(.scheduleTomorrowButton))
        XCTAssertTrue(contract.futurePlanElements.contains(.groupedByDate))
        XCTAssertTrue(contract.futurePlanElements.contains(.selectTaskAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.contextMenuAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.openDetailAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.taskRowMoveButtons))
        XCTAssertTrue(contract.unfinishedPoolElements.contains(.detailsExpansion))
        XCTAssertTrue(contract.completedPoolElements.contains(.subtaskCompletionRecord))
        XCTAssertTrue(contract.calendarElements.contains(.completionHeatBlock))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayDetail))
        XCTAssertTrue(contract.settingsElements.contains(.customSyncEndpoint))
        XCTAssertTrue(contract.settingsElements.contains(.iCloudSync))
        XCTAssertTrue(contract.emptyStateElements.contains(.illustration))
        XCTAssertTrue(contract.emptyStateElements.contains(.copy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.dayTodoIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.dayTodoCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.taskPoolIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.taskPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.futurePlansIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.futurePlansCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.unfinishedPoolIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.unfinishedPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.completedPoolIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.completedPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.calendarIllustration))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.calendarCopy))
    }

    func testDetailAndReviewSectionsAreNotOptional() {
        let contract = MacUIDesignContract.claudeMacPrototype20260705

        XCTAssertTrue(contract.detailElements.contains(.unselectedDayReviewRail))
        XCTAssertTrue(contract.detailElements.contains(.unselectedPageHint))
        XCTAssertTrue(contract.detailElements.contains(.unselectedRailHint))
        XCTAssertTrue(contract.detailElements.contains(.calendarNoGenericDetailRail))
        XCTAssertTrue(contract.detailElements.contains(.calendarOwnDetailPanel))
        XCTAssertTrue(contract.detailElements.contains(.settingsNoDetailRail))
        XCTAssertTrue(contract.detailElements.contains(.detailPanelTitle))
        XCTAssertTrue(contract.detailElements.contains(.iconOnlyOverflowMenu))
        XCTAssertTrue(contract.detailElements.contains(.progressSection))
        XCTAssertTrue(contract.detailElements.contains(.descriptionSection))
        XCTAssertTrue(contract.detailElements.contains(.noteSection))
        XCTAssertTrue(contract.detailElements.contains(.subtaskSection))
        XCTAssertTrue(contract.detailElements.contains(.subtaskCompletionDate))
        XCTAssertTrue(contract.detailElements.contains(.subtaskLockedIcon))
        XCTAssertTrue(contract.detailElements.contains(.subtaskDifficultyWeight))
        XCTAssertTrue(contract.detailElements.contains(.traceTimeline))

        XCTAssertTrue(contract.reviewElements.contains(.statsCard))
        XCTAssertTrue(contract.reviewElements.contains(.segmentedStatusBar))
        XCTAssertTrue(contract.reviewElements.contains(.summaryInput))
        XCTAssertTrue(contract.reviewElements.contains(.unfinishedReasonInput))
        XCTAssertTrue(contract.reviewElements.contains(.tomorrowNoteInput))
    }
}

@testable import NoonmarkMacUIContract
import XCTest

final class MacUIDesignContractTests: XCTestCase {
    func testCurrentWindowLayoutMatchesCompactReference() {
        XCTAssertEqual(MacUIWindowLayout.defaultWidth, 1000)
        XCTAssertEqual(MacUIWindowLayout.defaultHeight, 768)
        XCTAssertEqual(MacUIWindowLayout.minimumWidth, 960)
        XCTAssertEqual(MacUIWindowLayout.minimumHeight, 720)
        XCTAssertEqual(
            Set(MacUIDesignContract.current.windowMetrics),
            [.defaultLaunch1000x768, .minimum960x720]
        )
    }

    func testCurrentShellLayoutMatchesCompactReference() {
        XCTAssertEqual(MacUIShellLayout.sidebarWidth, 220)
        XCTAssertEqual(MacUIShellLayout.detailRailWidth, 280)
        XCTAssertEqual(MacUIShellLayout.calendarRailWidth, 248)
        XCTAssertEqual(MacUIShellLayout.pageHorizontalPadding, 20)
        XCTAssertEqual(MacUIShellLayout.taskRowVerticalPadding, 8)
        XCTAssertEqual(MacUIShellLayout.detailPadding, 14)
        XCTAssertEqual(MacUIIconMetrics.trafficLightDiameter, 12)
        XCTAssertEqual(MacUIIconMetrics.trafficLightHitTarget, 20)
        XCTAssertEqual(MacUIIconMetrics.clockLogoSize, 22)
        XCTAssertEqual(MacUIIconMetrics.navigationSize, 14)
        XCTAssertEqual(MacUIShellLayout.navigationRowHeight, 34)
    }

    func testTypographyCompactsReadableTextWithoutShrinkingMicrocopy() {
        XCTAssertEqual(MacUITypographyMetrics.scale, 0.92)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(21), 19.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(17), 15.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(14.5), 13.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(13), 12)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(12), 11)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(10.5), 9.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(10), 10)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(9), 9)
    }

    func testCurrentContractCoversAllTopLevelPages() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(
            contract.pages,
            [.dayTodo, .taskPool, .futurePlans, .unfinishedPool, .completedPool, .calendar, .zhulong, .settings]
        )
    }

    func testContractKeepsActionsAndModalsExplicit() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(contract.taskActions.count, 28)
        XCTAssertTrue(contract.taskActions.contains(.continueToDate))
        XCTAssertTrue(contract.taskActions.contains(.changeIntoNewTask))
        XCTAssertTrue(contract.taskActions.contains(.returnToPool))
        XCTAssertTrue(contract.taskActions.contains(.reactivateAbandonedChain))
        XCTAssertTrue(contract.taskActions.contains(.copyAsNewTask))
        XCTAssertTrue(contract.taskActions.contains(.deleteTask))
        XCTAssertTrue(contract.taskActions.contains(.addSubtask))
        XCTAssertTrue(contract.taskActions.contains(.cycleSubtaskDifficulty))
        XCTAssertTrue(contract.taskActions.contains(.dragManualProgress))
        XCTAssertTrue(contract.taskActions.contains(.editDailyReview))
        XCTAssertTrue(contract.taskActions.contains(.undo))

        XCTAssertEqual(contract.modals.count, 13)
        XCTAssertTrue(contract.modals.contains(.centeredClassificationManager))
        XCTAssertTrue(contract.modals.contains(.changeTaskDialog))
        XCTAssertTrue(contract.modals.contains(.changeDialogOldTaskStrikethroughPreview))
        XCTAssertTrue(contract.modals.contains(.changeDialogNewTaskTitleInput))
        XCTAssertTrue(contract.modals.contains(.changeDialogConfirmButton))
        XCTAssertTrue(contract.modals.contains(.contextMenu))
        XCTAssertTrue(contract.modals.contains(.toast))
        XCTAssertTrue(contract.modals.contains(.undoUnavailableToast))
    }

    func testContractPreservesRequiredBackendCapabilities() {
        let contract = MacUIDesignContract.current

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

    func testContractCoversEachCurrentPageElement() {
        let contract = MacUIDesignContract.current

        XCTAssertTrue(contract.globalElements.contains(.macWindowChrome))
        XCTAssertTrue(contract.globalElements.contains(.trafficLights))
        XCTAssertTrue(contract.globalElements.contains(.operableTrafficLights))
        XCTAssertTrue(contract.globalElements.contains(.resizableWindow))
        XCTAssertTrue(contract.globalElements.contains(.closeWindowKeepsAppRunning))
        XCTAssertTrue(contract.globalElements.contains(.visibleWindowBoundary))
        XCTAssertTrue(contract.globalElements.contains(.integratedWindowControls))
        XCTAssertTrue(contract.globalElements.contains(.pageDerivedWindowTitle))
        XCTAssertTrue(contract.globalElements.contains(.appClockLogo))
        XCTAssertTrue(contract.globalElements.contains(.dateStripSelectionAnimation))
        XCTAssertTrue(contract.globalElements.contains(.semanticStatusStyles))
        XCTAssertTrue(contract.globalElements.contains(.protectedActionButtonLabels))
        XCTAssertTrue(contract.globalElements.contains(.todoistInspiredUnifiedShell))
        XCTAssertTrue(contract.globalElements.contains(.quietSidebarSurface))
        XCTAssertTrue(contract.globalElements.contains(.lowContrastControlSurfaces))
        XCTAssertTrue(contract.globalElements.contains(.borderlessListRows))
        XCTAssertTrue(contract.windowMetrics.contains(.defaultLaunch1000x768))
        XCTAssertTrue(contract.windowMetrics.contains(.minimum960x720))
        XCTAssertTrue(contract.colorTokens.contains(.accent))
        XCTAssertTrue(contract.colorTokens.contains(.ok))
        XCTAssertTrue(contract.colorTokens.contains(.warn))
        XCTAssertTrue(contract.colorTokens.contains(.chip))
        XCTAssertTrue(contract.colorTokens.contains(.panel))
        XCTAssertTrue(contract.colorTokens.contains(.line))
        XCTAssertTrue(contract.colorTokens.contains(.windowBoundary))
        XCTAssertTrue(contract.colorTokens.contains(.t1))
        XCTAssertTrue(contract.colorTokens.contains(.t2))
        XCTAssertTrue(contract.colorTokens.contains(.t3))
        XCTAssertTrue(contract.navigationElements.contains(.semanticIconColors))
        XCTAssertTrue(contract.navigationElements.contains(.quietSelectedPill))
        XCTAssertTrue(contract.navigationElements.contains(.countBadges))
        XCTAssertTrue(contract.navigationElements.contains(.zhulongEntryVisibilityFollowsSettings))
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
        XCTAssertEqual(MacUINavigationIconColorToken.zhulong.hexValue, "#7C5CFF")
        XCTAssertEqual(MacUINavigationIconColorToken.settings.hexValue, "#64748B")

        XCTAssertTrue(contract.dayTodoElements.contains(.fourteenDayStrip))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripSelectedPill))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTodayOutline))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripSelectedDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTaskPresenceDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.keyboardDateNavigation))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowSelectedState))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowStatusDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTitle))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTrajectoryMetadata))
        XCTAssertTrue(contract.dayTodoElements.contains(.changedTraceTargetJump))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowMoveButtons))
        XCTAssertTrue(contract.taskPoolElements.contains(.rowContextMenu))
        XCTAssertTrue(contract.taskPoolElements.contains(.scheduleTomorrowContextMenuAction))
        XCTAssertTrue(contract.taskPoolElements.contains(.sharedRowAndDetailActions))
        XCTAssertTrue(contract.futurePlanElements.contains(.groupedByDate))
        XCTAssertTrue(contract.futurePlanElements.contains(.selectTaskAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.contextMenuAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.openDetailAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.taskRowMoveButtons))
        XCTAssertTrue(contract.unfinishedPoolElements.contains(.detailsExpansion))
        XCTAssertTrue(contract.unfinishedPoolElements.contains(.reenableAbandonedContextMenuAction))
        XCTAssertTrue(contract.completedPoolElements.contains(.subtaskCompletionRecord))
        XCTAssertTrue(contract.completedPoolElements.contains(.copyAsNewTaskContextMenuAction))
        XCTAssertTrue(contract.calendarElements.contains(.completionHeatBlock))
        XCTAssertTrue(contract.calendarElements.contains(.keyboardDateNavigation))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayDetail))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayStatusDistribution))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayCompletionRate))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayContinuationSummary))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayChangeSummary))
        XCTAssertTrue(contract.calendarElements.contains(.selectedDayRiskSummary))
        XCTAssertTrue(contract.calendarElements.contains(.compactSelectedDayTaskRows))
        XCTAssertTrue(contract.calendarElements.contains(.changedTraceTargetJump))
        XCTAssertTrue(contract.settingsElements.contains(.customSyncEndpoint))
        XCTAssertTrue(contract.settingsElements.contains(.zhulongEnabledToggle))
        XCTAssertTrue(contract.settingsElements.contains(.zhulongProviderConfiguration))
        XCTAssertTrue(contract.settingsElements.contains(.balancedSettingsLayout))
        XCTAssertTrue(contract.settingsElements.contains(.compactClassificationSummary))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerTypeSwitcher))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerSearch))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerInlineCreation))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerLifecycleSections))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerLifecycleActions))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerReferenceCounts))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerHistoryNotice))
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

    func testLowFrequencyTaskActionsUseContextMenusWithoutInlineDuplicates() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(
            Set(contract.taskPoolElements),
            [
                .title,
                .description,
                .newTaskInput,
                .taskRows,
                .unscheduledPlaceholder,
                .rowContextMenu,
                .scheduleTodayContextMenuAction,
                .scheduleTomorrowContextMenuAction,
                .scheduleToDateContextMenuAction,
                .deleteContextMenuAction,
                .sharedRowAndDetailActions,
                .emptyState
            ]
        )
        XCTAssertEqual(
            Set(contract.unfinishedPoolElements),
            [
                .title,
                .description,
                .dedupedChainRows,
                .missedCount,
                .continuationCount,
                .lastMissedDate,
                .rowContextMenu,
                .activeTraceJumpAction,
                .continueContextMenuAction,
                .abandonContextMenuAction,
                .reenableAbandonedContextMenuAction,
                .detailsExpansion,
                .emptyState
            ]
        )
        XCTAssertEqual(
            Set(contract.completedPoolElements),
            [
                .title,
                .description,
                .groupedByCompletionDate,
                .parentCompletionRecord,
                .subtaskCompletionRecord,
                .trajectoryNodes,
                .rowContextMenu,
                .jumpDayContextMenuAction,
                .copyAsNewTaskContextMenuAction,
                .emptyState
            ]
        )
    }

    func testDetailEditorUsesCompactBorderlessMarkdownContract() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(MacUIDetailEditorLayout.titleDescriptionSpacing, 6)
        XCTAssertEqual(MacUIDetailEditorLayout.titleHeight, 22 ... 72)
        XCTAssertEqual(MacUIDetailEditorLayout.descriptionHeight, 32 ... 132)
        XCTAssertEqual(MacUIDetailEditorLayout.textInset, 3)
        XCTAssertTrue(contract.detailElements.contains(.compactTitleDescriptionLayout))
        XCTAssertTrue(contract.detailElements.contains(.borderlessDescriptionEditor))
        XCTAssertTrue(contract.detailElements.contains(.markdownDescriptionEditing))
        XCTAssertTrue(contract.detailElements.contains(.nativeDescriptionEditingCommands))
        XCTAssertTrue(contract.detailElements.contains(.sharedRowAndOverflowMenuActions))

        XCTAssertEqual(
            Set(contract.markdownEditingCommands),
            [
                .selectAll,
                .cut,
                .copy,
                .paste,
                .undo,
                .redo,
                .bold,
                .italic,
                .inlineCode,
                .link,
                .indent,
                .hardLineBreak
            ]
        )
    }

    func testClassificationCurrentValueIsTheOnlyChangePicker() {
        let contract = MacUIDesignContract.current

        XCTAssertTrue(contract.detailElements.contains(.classificationValuePicker))
    }

    func testClassificationManagementUsesCompactVerifiedMetrics() {
        XCTAssertLessThanOrEqual(MacUIClassificationLayout.settingsSummaryHeight, 120)
        XCTAssertEqual(MacUIClassificationLayout.settingsSummaryHeight, 112)
        XCTAssertEqual(MacUIClassificationLayout.managerWidth, 560)
        XCTAssertEqual(MacUIClassificationLayout.managerHeight, 460)
        XCTAssertEqual(MacUIClassificationLayout.managerRowHeight, 42)
        XCTAssertEqual(MacUIClassificationAccessibility.renameActionPrefix, "classification.manager.lifecycle.rename")
        XCTAssertEqual(MacUIClassificationAccessibility.archiveActionPrefix, "classification.manager.lifecycle.archive")
        XCTAssertEqual(MacUIClassificationAccessibility.restoreActionPrefix, "classification.manager.lifecycle.restore")
        XCTAssertEqual(MacUIClassificationAccessibility.discardActionPrefix, "classification.manager.lifecycle.discard")
    }

    func testZhulongHomeExposesFixedWorkflowsWithoutDecorativeComposerActions() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(Set(contract.zhulongHomeElements), Set(MacUIZhulongHomeElement.allCases))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.freeformIntentComposer))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.verticallyCenteredComposerContent))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.singleVisualAxis))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.capsuleIntentComposer))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.flatWorkflowList))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.quietSuggestionModeLabel))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.collapsedEmptyPendingSection))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.collapsedHomeDetailRail))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.coreWorkflowEntrances))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.specialistAssistantEntrances))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.directWorkflowStart))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.noDecorativeComposerAction))
    }

    func testZhulongHomeUsesOneSparseVisualAxis() {
        XCTAssertEqual(MacUIZhulongHomeLayout.contentMaxWidth, 780)
        XCTAssertEqual(MacUIZhulongHomeLayout.headerOuterMaxWidth, 828)
        XCTAssertEqual(MacUIZhulongHomeLayout.composerHeight, 54)
        XCTAssertEqual(MacUIZhulongHomeLayout.composerCornerRadius, 27)
        XCTAssertEqual(MacUIZhulongHomeLayout.workflowRowHeight, 62)
        XCTAssertEqual(MacUIZhulongHomeLayout.workflowListCount, 1)
        XCTAssertEqual(MacUIZhulongHomeLayout.composerActionCount, 1)
        XCTAssertTrue(MacUIZhulongHomeLayout.collapsesEmptyPendingSection)
        XCTAssertTrue(MacUIZhulongHomeLayout.collapsesHomeDetailRail)
    }

    func testDetailAndReviewSectionsAreNotOptional() {
        let contract = MacUIDesignContract.current

        XCTAssertTrue(contract.detailElements.contains(.unselectedDayReviewRail))
        XCTAssertTrue(contract.detailElements.contains(.unselectedPageHint))
        XCTAssertTrue(contract.detailElements.contains(.unselectedRailHint))
        XCTAssertTrue(contract.detailElements.contains(.unselectedPageSummaryRail))
        XCTAssertTrue(contract.detailElements.contains(.unselectedLocalStats))
        XCTAssertTrue(contract.detailElements.contains(.unselectedAlgorithmicSuggestions))
        XCTAssertTrue(contract.detailElements.contains(.unselectedZhulongPlaceholder))
        XCTAssertTrue(contract.detailElements.contains(.calendarNoGenericDetailRail))
        XCTAssertTrue(contract.detailElements.contains(.calendarOwnDetailPanel))
        XCTAssertTrue(contract.detailElements.contains(.settingsNoDetailRail))
        XCTAssertTrue(contract.detailElements.contains(.detailPanelTitle))
        XCTAssertTrue(contract.detailElements.contains(.iconOnlyOverflowMenu))
        XCTAssertTrue(contract.detailElements.contains(.progressSection))
        XCTAssertTrue(contract.detailElements.contains(.compactClassificationEditor))
        XCTAssertTrue(contract.detailElements.contains(.onDemandClassificationLabelInput))
        XCTAssertTrue(contract.detailElements.contains(.descriptionEditor))
        XCTAssertTrue(contract.detailElements.contains(.descriptionImmediatelyUnderTitle))
        XCTAssertTrue(contract.detailElements.contains(.descriptionWithoutSectionTitle))
        XCTAssertTrue(contract.detailElements.contains(.noteSection))
        XCTAssertTrue(contract.detailElements.contains(.timestampedNoteEntries))
        XCTAssertTrue(contract.detailElements.contains(.subtaskSection))
        XCTAssertTrue(contract.detailElements.contains(.subtaskCompletionDate))
        XCTAssertTrue(contract.detailElements.contains(.subtaskLockedIcon))
        XCTAssertTrue(contract.detailElements.contains(.subtaskDifficultyWeight))
        XCTAssertTrue(contract.detailElements.contains(.traceTimeline))
        XCTAssertTrue(contract.detailElements.contains(.changedTraceTargetJump))

        XCTAssertTrue(contract.reviewElements.contains(.statsCard))
        XCTAssertTrue(contract.reviewElements.contains(.segmentedStatusBar))
        XCTAssertTrue(contract.reviewElements.contains(.zhulongAnalysisButton))
        XCTAssertTrue(contract.reviewElements.contains(.summaryInput))
        XCTAssertTrue(contract.reviewElements.contains(.unfinishedReasonInput))
        XCTAssertTrue(contract.reviewElements.contains(.tomorrowNoteInput))
        XCTAssertTrue(contract.reviewElements.contains(.autosavedIndicator))
    }

    func testTaskNotesExposeCurrentComposeEditAndDeleteCapabilities() {
        let contract = MacUIDesignContract.current

        XCTAssertTrue(contract.detailElements.contains(.noteComposerInput))
        XCTAssertTrue(contract.detailElements.contains(.singleLineNoteComposer))
        XCTAssertTrue(contract.detailElements.contains(.singleNoteSurface))
        XCTAssertTrue(contract.detailElements.contains(.noteEntryOverflowMenu))
        XCTAssertTrue(contract.detailElements.contains(.editableNoteEntries))
        XCTAssertTrue(contract.detailElements.contains(.deletableNoteEntries))
        XCTAssertTrue(contract.taskActions.contains(.addNote))
        XCTAssertTrue(contract.taskActions.contains(.editNote))
        XCTAssertTrue(contract.taskActions.contains(.deleteNote))
    }
}

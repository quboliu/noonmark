@testable import NoonmarkMacUIContract
import XCTest

final class MacUIDesignContractTests: XCTestCase {
    func testCurrentWindowLayoutMatchesCompactReference() {
        XCTAssertEqual(MacUIWindowLayout.defaultWidth, 1200)
        XCTAssertEqual(MacUIWindowLayout.defaultHeight, 768)
        XCTAssertEqual(MacUIWindowLayout.minimumWidth, 960)
        XCTAssertEqual(MacUIWindowLayout.minimumHeight, 720)
        XCTAssertEqual(
            Set(MacUIDesignContract.current.windowMetrics),
            [.defaultLaunch1200x768, .minimum960x720]
        )
    }

    func testCurrentShellLayoutMatchesCompactReference() {
        XCTAssertEqual(MacUIShellLayout.sidebarWidth, 220)
        XCTAssertEqual(MacUIShellLayout.compactSidebarWidth, 72)
        XCTAssertEqual(MacUIShellLayout.detailRailWidth, 280)
        XCTAssertEqual(MacUIShellLayout.calendarRailWidth, 248)
        XCTAssertEqual(MacUICalendarInsightRowLayout.labelLineLimit, 1)
        XCTAssertTrue(MacUICalendarInsightRowLayout.usesSharedIntrinsicLabelColumn)
        XCTAssertEqual(MacUIShellLayout.paneToggleButtonSize, 28)
        XCTAssertEqual(MacUIShellLayout.pageHorizontalPadding, 20)
        XCTAssertEqual(MacUIShellLayout.taskRowVerticalPadding, 8)
        XCTAssertEqual(MacUIShellLayout.detailPadding, 14)
        XCTAssertTrue(MacUIShellLayout.sidebarExpandedByDefault)
        XCTAssertTrue(MacUIShellLayout.detailRailCollapsedByDefault)
        XCTAssertEqual(MacUIIconMetrics.paneToggleChevronSize, 8.5)
        XCTAssertEqual(MacUIIconMetrics.navigationSize, 14)
        XCTAssertEqual(MacUIAccessibilityLayout.minimumInteractiveTargetSize, 28)
        XCTAssertEqual(MacUIShellLayout.navigationRowHeight, 34)
        XCTAssertEqual(MacUICalendarGridLayout.columnCount, 7)
        XCTAssertEqual(MacUICalendarGridLayout.minimumRowCount, 5)
        XCTAssertTrue(MacUICalendarGridLayout.completesTrailingBlankSlots)
        XCTAssertTrue(MacUICalendarGridLayout.blankSlotsRenderGridBoundaries)
    }

    func testSettingsWindowSidebarKeepsLocalizedSectionTitlesReadable() {
        XCTAssertEqual(MacUISettingsWindowLayout.minimumContentWidth, 700)
        XCTAssertEqual(MacUISettingsWindowLayout.minimumContentHeight, 520)
        XCTAssertEqual(MacUISettingsWindowLayout.initialContentWidth, 860)
        XCTAssertEqual(MacUISettingsWindowLayout.initialContentHeight, 660)
        XCTAssertEqual(MacUISettingsWindowLayout.sidebarMinimumWidth, 220)
        XCTAssertEqual(MacUISettingsWindowLayout.sidebarIdealWidth, 230)
        XCTAssertEqual(MacUISettingsWindowLayout.sidebarMaximumWidth, 240)
        XCTAssertLessThanOrEqual(
            MacUISettingsWindowLayout.sidebarMinimumWidth,
            MacUISettingsWindowLayout.sidebarIdealWidth
        )
        XCTAssertLessThanOrEqual(
            MacUISettingsWindowLayout.sidebarIdealWidth,
            MacUISettingsWindowLayout.sidebarMaximumWidth
        )
    }

    func testGlobalMotionContractIncludesToastRiseAndDateStripSelection() {
        let globalElements = MacUIDesignContract.current.globalElements

        XCTAssertTrue(globalElements.contains(.riseToastAnimation))
        XCTAssertTrue(globalElements.contains(.dateStripSelectionAnimation))
        XCTAssertTrue(globalElements.contains(.reduceMotion))
        XCTAssertEqual(MacUIAnimationMetrics.toastRiseDuration, 0.20)
        XCTAssertEqual(MacUIAnimationMetrics.dateStripSpringResponse, 0.24)
        XCTAssertEqual(MacUIAnimationMetrics.dateStripSpringDampingFraction, 0.74)
    }

    func testDatePickerUsesOneCompactLocalDateGridContract() {
        XCTAssertEqual(MacUIDatePickerLayout.sheetWidth, 340)
        XCTAssertEqual(MacUIDatePickerLayout.outerPadding, 18)
        XCTAssertEqual(MacUIDatePickerLayout.contentWidth, 304)
        XCTAssertEqual(
            MacUIDatePickerLayout.contentWidth,
            MacUIDatePickerLayout.sheetWidth - (MacUIDatePickerLayout.outerPadding * 2)
        )
        XCTAssertEqual(MacUIDatePickerLayout.columnCount, 7)
        XCTAssertEqual(MacUIDatePickerLayout.rowCount, 6)
        XCTAssertEqual(MacUIDatePickerLayout.columnSpacing, 4)
        XCTAssertEqual(MacUIDatePickerLayout.rowSpacing, 2)
        XCTAssertEqual(MacUIDatePickerLayout.dayCellHeight, 30)
        XCTAssertEqual(MacUIDatePickerLayout.selectionDiameter, 24)
        XCTAssertTrue(MacUIDatePickerLayout.fullCellHitTarget)
        XCTAssertTrue(MacUIDatePickerLayout.localDateOnlyDraft)
        XCTAssertTrue(MacUIDatePickerLayout.stablePresentationIdentity)
        XCTAssertTrue(MacUIDatePickerLayout.showsAdjacentDates)
        XCTAssertTrue(MacUIDatePickerLayout.omitsUnconstrainedHint)
        XCTAssertTrue(MacUIDatePickerLayout.purposeSpecificConfirmation)
        XCTAssertTrue(MacUIDatePickerLayout.supportsKeyboardArrows)
    }

    func testDayTaskRowKeepsIdentityFirstAndCompletionAtTheTrailingEdge() {
        XCTAssertEqual(MacUITaskRowLayout.completionControlSize, 28)
        XCTAssertEqual(MacUITaskRowLayout.accessorySpacing, 12)
        XCTAssertTrue((12 ... 16).contains(MacUITaskRowLayout.accessorySpacing))
        XCTAssertTrue(MacUITaskRowLayout.identityPrecedesAccessories)
        XCTAssertTrue(MacUITaskRowLayout.completionFollowsAccessories)
        XCTAssertTrue(MacUITaskRowLayout.flexibleSpaceFollowsAccessories)
    }

    func testCalendarRailRowsKeepOneReadableStatusAndExposeFullTitles() {
        XCTAssertEqual(MacUICalendarDetailRowLayout.titlePointSize, 12.5)
        XCTAssertEqual(MacUICalendarDetailRowLayout.titleLineLimit, 2)
        XCTAssertEqual(MacUICalendarDetailRowLayout.metadataPointSize, 10.5)
        XCTAssertEqual(MacUICalendarDetailRowLayout.horizontalPadding, 10)
        XCTAssertEqual(MacUICalendarDetailRowLayout.verticalPadding, 8)
        XCTAssertEqual(MacUICalendarDetailRowLayout.statusRepresentationCount, 1)
        XCTAssertTrue(MacUICalendarDetailRowLayout.exposesFullTitleToAccessibility)
    }

    func testTaskLabelPatchesUseQuietSolidBoundaries() {
        XCTAssertEqual(MacUITaskLabelPatchLayout.semanticFillOpacity, 0.10)
        XCTAssertEqual(MacUITaskLabelPatchLayout.borderLineWidth, 1)
        XCTAssertFalse(MacUITaskLabelPatchLayout.usesDashedBorder)
        XCTAssertFalse(MacUITaskLabelPatchLayout.overflowUsesDashedBorder)
    }

    func testAutomaticClassificationStatusRemainsReachableAcrossTaskSurfaces() {
        let contract = MacUIDesignContract.current

        XCTAssertTrue(
            contract.unfinishedPoolElements.contains(.automaticClassificationStatus)
        )
        XCTAssertTrue(
            contract.completedPoolElements.contains(.automaticClassificationStatus)
        )

        let instanceID = "chain-1"
        let statusIdentifiers = MacUIAutomaticClassificationSurface.allCases.map {
            MacUIAutomaticClassificationAccessibility.statusIdentifier(
                surface: $0,
                instanceID: instanceID
            )
        }
        XCTAssertEqual(Set(statusIdentifiers).count, statusIdentifiers.count)
        XCTAssertEqual(
            MacUIAutomaticClassificationAccessibility.statusIdentifier(
                surface: .unfinishedRow,
                instanceID: instanceID
            ),
            "automatic-classification.status.unfinished-row.chain-1"
        )
        XCTAssertNotEqual(
            MacUIAutomaticClassificationAccessibility.retryIdentifier(
                surface: .completedRow,
                instanceID: instanceID,
                kind: .job
            ),
            MacUIAutomaticClassificationAccessibility.retryIdentifier(
                surface: .completedRow,
                instanceID: instanceID,
                kind: .providerCircuit
            )
        )
    }

    func testFuturePlanDetailUsesOneCompactMetadataLine() {
        XCTAssertEqual(MacUIFuturePlanDetailLayout.metadataSpacing, 8)
        XCTAssertEqual(MacUIFuturePlanDetailLayout.summaryCardCount, 0)
        XCTAssertEqual(MacUIFuturePlanDetailLayout.noticeCount, 1)
    }

    func testTypographyCompactsReadableTextWithoutShrinkingMicrocopy() {
        XCTAssertEqual(MacUITypographyMetrics.scale, 1.0)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(21), 21)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(17), 17)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(14.5), 14.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(13), 13)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(12), 12)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(10.5), 10.5)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(10), 10)
        XCTAssertEqual(MacUITypographyMetrics.compactPointSize(9), 9)
        XCTAssertEqual(MacUITypographyMetrics.compactEditorBasePointSize, 12.5)
        XCTAssertEqual(MacUITypographyMetrics.compactEditorPointSize, 12.5)
        XCTAssertEqual(MacUITypographyMetrics.compactEditorVerticalInset, 8.5)
    }

    func testSmallTextAndSemanticSuccessColorsMeetContrastContract() {
        let white = MacUISRGBColor(red: 1, green: 1, blue: 1)
        XCTAssertGreaterThanOrEqual(
            MacUIAccessibleColorMetrics.success.contrastRatio(against: white),
            MacUIAccessibleColorMetrics.minimumSmallTextContrast
        )
        XCTAssertGreaterThanOrEqual(
            MacUIAccessibleColorMetrics.coolGrayTertiaryText.contrastRatio(
                against: MacUIAccessibleColorMetrics.coolGrayBackground
            ),
            MacUIAccessibleColorMetrics.minimumSmallTextContrast
        )
        XCTAssertGreaterThanOrEqual(
            MacUIAccessibleColorMetrics.warmPaperTertiaryText.contrastRatio(
                against: MacUIAccessibleColorMetrics.warmPaperBackground
            ),
            MacUIAccessibleColorMetrics.minimumSmallTextContrast
        )
        XCTAssertGreaterThan(
            MacUIAccessibleColorMetrics.coolGrayPlaceholderText.red,
            MacUIAccessibleColorMetrics.coolGrayTertiaryText.red
        )
        XCTAssertGreaterThan(
            MacUIAccessibleColorMetrics.warmPaperPlaceholderText.red,
            MacUIAccessibleColorMetrics.warmPaperTertiaryText.red
        )
    }

    func testCurrentContractCoversAllTopLevelPages() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(
            contract.pages,
            [.dayTodo, .taskPool, .futurePlans, .unfinishedPool, .completedPool, .calendar, .zhulong]
        )
    }

    func testContractKeepsActionsAndModalsExplicit() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(contract.taskActions.count, 33)
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
        XCTAssertTrue(contract.globalElements.contains(.nativeFullSizeContentTitlebar))
        XCTAssertTrue(contract.globalElements.contains(.workspaceExtendsIntoTitlebar))
        XCTAssertTrue(contract.globalElements.contains(.trafficLights))
        XCTAssertTrue(contract.globalElements.contains(.systemTrafficLights))
        XCTAssertTrue(contract.globalElements.contains(.operableTrafficLights))
        XCTAssertTrue(contract.globalElements.contains(.resizableWindow))
        XCTAssertTrue(contract.globalElements.contains(.closeWindowKeepsAppRunning))
        XCTAssertTrue(contract.globalElements.contains(.visibleWindowBoundary))
        XCTAssertTrue(contract.globalElements.contains(.integratedWindowControls))
        XCTAssertTrue(contract.globalElements.contains(.pageDerivedWindowTitle))
        XCTAssertTrue(contract.globalElements.contains(.dateStripSelectionAnimation))
        XCTAssertTrue(contract.globalElements.contains(.semanticStatusStyles))
        XCTAssertTrue(contract.globalElements.contains(.protectedActionButtonLabels))
        XCTAssertTrue(contract.globalElements.contains(.nativeProductivityWorkspace))
        XCTAssertTrue(contract.globalElements.contains(.quietSidebarSurface))
        XCTAssertTrue(contract.globalElements.contains(.lowContrastControlSurfaces))
        XCTAssertTrue(contract.globalElements.contains(.borderlessListRows))
        XCTAssertTrue(contract.globalElements.contains(.collapsibleSidebar))
        XCTAssertTrue(contract.globalElements.contains(.sidebarExpandedByDefault))
        XCTAssertTrue(contract.globalElements.contains(.sidebarCompactsToIconRail))
        XCTAssertTrue(contract.globalElements.contains(.stableWindowFrameDuringSidebarToggle))
        XCTAssertTrue(contract.windowMetrics.contains(.defaultLaunch1200x768))
        XCTAssertTrue(contract.windowMetrics.contains(.minimum960x720))
        XCTAssertTrue(contract.globalElements.contains(.collapsibleDetailRail))
        XCTAssertTrue(contract.globalElements.contains(.detailRailCollapsedByDefault))
        XCTAssertTrue(contract.globalElements.contains(.calendarUsesCollapsibleDetailRail))
        XCTAssertTrue(contract.globalElements.contains(.stableWindowFrameDuringDetailRailToggle))
        XCTAssertTrue(contract.globalElements.contains(.spatiallySeparatedRailControls))
        XCTAssertTrue(contract.globalElements.contains(.completePaneToggleHitTarget))
        XCTAssertTrue(contract.globalElements.contains(.completeHeaderNavigationHitTarget))
        XCTAssertTrue(contract.globalElements.contains(.paneSafeAreaHandledAtHostingBoundary))
        XCTAssertTrue(contract.globalElements.contains(.calendarGridSlotsOwnBoundaries))
        XCTAssertTrue(contract.globalElements.contains(.viewMenuRailCommands))
        XCTAssertTrue(contract.globalElements.contains(.adaptiveMainSurfaceWidth))
        XCTAssertTrue(contract.globalElements.contains(.nativeMainMenu))
        XCTAssertTrue(contract.globalElements.contains(.nativeSettingsWindow))
        XCTAssertTrue(contract.globalElements.contains(.restorableWindow))
        XCTAssertTrue(contract.globalElements.contains(.adjustableSplitView))
        XCTAssertTrue(contract.globalElements.contains(.workspaceKeyboardSelection))
        XCTAssertTrue(contract.globalElements.contains(.workspaceMultipleSelection))
        XCTAssertTrue(contract.globalElements.contains(.globalSearchCommand))
        XCTAssertTrue(contract.globalElements.contains(.quickEntryCommand))
        XCTAssertTrue(contract.globalElements.contains(.semanticErrorPresentation))
        XCTAssertTrue(contract.globalElements.contains(.increaseContrast))
        XCTAssertTrue(contract.globalElements.contains(.differentiateWithoutColor))
        XCTAssertTrue(contract.globalElements.contains(.reduceMotion))
        XCTAssertTrue(contract.globalElements.contains(.reduceTransparency))
        XCTAssertTrue(contract.colorTokens.contains(.accent))
        XCTAssertTrue(contract.colorTokens.contains(.ok))
        XCTAssertTrue(contract.colorTokens.contains(.warn))
        XCTAssertTrue(contract.colorTokens.contains(.chip))
        XCTAssertTrue(contract.colorTokens.contains(.panel))
        XCTAssertTrue(contract.colorTokens.contains(.line))
        XCTAssertTrue(contract.colorTokens.contains(.t1))
        XCTAssertTrue(contract.colorTokens.contains(.t2))
        XCTAssertTrue(contract.colorTokens.contains(.t3))
        XCTAssertTrue(contract.navigationElements.contains(.unifiedNavigationIcons))
        XCTAssertTrue(contract.navigationElements.contains(.semanticNavigationIconColors))
        XCTAssertTrue(contract.navigationElements.contains(.quietSelectedPill))
        XCTAssertTrue(contract.navigationElements.contains(.countBadges))
        XCTAssertTrue(contract.navigationElements.contains(.zhulongEntryVisibilityFollowsSettings))
        XCTAssertTrue(contract.dayTodoElements.contains(.fourteenDayStrip))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripSelectedPill))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTodayOutline))
        XCTAssertTrue(contract.dayTodoElements.contains(.accessibleDateCellState))
        XCTAssertTrue(contract.dayTodoElements.contains(.dateStripTaskPresenceDot))
        XCTAssertTrue(contract.dayTodoElements.contains(.keyboardDateNavigation))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowSelectedState))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTitle))
        XCTAssertTrue(contract.dayTodoElements.contains(.taskRowTrajectoryMetadata))
        XCTAssertTrue(contract.dayTodoElements.contains(.changedTraceTargetJump))
        XCTAssertTrue(contract.dayTodoElements.contains(.singleStatusGlyph))
        XCTAssertTrue(contract.dayTodoElements.contains(.dragReordering))
        XCTAssertTrue(contract.dayTodoElements.contains(.selectedReorderControls))
        XCTAssertTrue(contract.taskPoolElements.contains(.rowContextMenu))
        XCTAssertTrue(contract.taskPoolElements.contains(.scheduleTomorrowContextMenuAction))
        XCTAssertTrue(contract.taskPoolElements.contains(.sharedRowAndDetailActions))
        XCTAssertTrue(contract.futurePlanElements.contains(.groupedByDate))
        XCTAssertTrue(contract.futurePlanElements.contains(.selectTaskAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.contextMenuAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.openDetailAction))
        XCTAssertTrue(contract.futurePlanElements.contains(.dragReordering))
        XCTAssertTrue(contract.futurePlanElements.contains(.selectedReorderControls))
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
        XCTAssertTrue(contract.settingsElements.contains(.nativeSettingsWindow))
        XCTAssertTrue(contract.settingsElements.contains(.nativeSidebarSelection))
        XCTAssertTrue(contract.settingsElements.contains(.flatFormSections))
        XCTAssertTrue(contract.settingsElements.contains(.poemInAboutPanel))
        XCTAssertTrue(contract.settingsElements.contains(.compactClassificationSummary))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerTypeSwitcher))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerSearch))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerInlineCreation))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerLifecycleSections))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerLifecycleActions))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerReferenceCounts))
        XCTAssertTrue(contract.settingsElements.contains(.classificationManagerHistoryNotice))
        XCTAssertTrue(contract.settingsElements.contains(.iCloudSync))
        XCTAssertTrue(contract.emptyStateElements.contains(.semanticSymbol))
        XCTAssertTrue(contract.emptyStateElements.contains(.copy))
        XCTAssertTrue(contract.emptyStateElements.contains(.contextualPrimaryAction))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.dayTodoSymbol))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.dayTodoCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.dayTodoPrimaryAction))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.taskPoolSymbol))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.taskPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.taskPoolPrimaryAction))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.futurePlansSymbol))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.futurePlansCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.futurePlansPrimaryAction))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.unfinishedPoolSymbol))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.unfinishedPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.completedPoolSymbol))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.completedPoolCopy))
        XCTAssertTrue(contract.pageEmptyStateElements.contains(.calendarSymbol))
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
                .automaticClassificationStatus,
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
                .automaticClassificationStatus,
                .emptyState
            ]
        )
    }

    func testDetailEditorUsesCompactBorderlessMarkdownContract() {
        let contract = MacUIDesignContract.current

        XCTAssertEqual(MacUIDetailEditorLayout.titleDescriptionSpacing, 6)
        XCTAssertEqual(MacUIDetailEditorLayout.titleHeight, 22 ... 72)
        XCTAssertEqual(MacUIDetailEditorLayout.descriptionHeight, 32 ... 132)
        XCTAssertEqual(MacUIDetailEditorLayout.horizontalTextInset, 0)
        XCTAssertEqual(MacUIDetailEditorLayout.verticalTextInset, 3)
        XCTAssertEqual(MacUIDetailEditorLayout.lineFragmentPadding, 0)
        XCTAssertTrue(contract.detailElements.contains(.compactTitleDescriptionLayout))
        XCTAssertTrue(contract.detailElements.contains(.primaryTextSharesDetailAxis))
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
        XCTAssertTrue(contract.zhulongHomeElements.contains(.verticallyCenteredHomeContent))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.singleVisualAxis))
        XCTAssertTrue(contract.zhulongHomeElements.contains(.roundedRectIntentComposer))
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
        XCTAssertEqual(MacUIZhulongHomeLayout.headerOuterMaxWidth, 820)
        XCTAssertEqual(
            MacUIZhulongHomeLayout.headerOuterMaxWidth,
            MacUIZhulongHomeLayout.contentMaxWidth + (MacUIShellLayout.pageHorizontalPadding * 2)
        )
        XCTAssertEqual(MacUIZhulongHomeLayout.composerHeight, 54)
        XCTAssertEqual(MacUIZhulongHomeLayout.composerCornerRadius, 14)
        XCTAssertEqual(MacUIZhulongHomeLayout.workflowRowHeight, 62)
        XCTAssertEqual(MacUIZhulongHomeLayout.workflowListCount, 1)
        XCTAssertEqual(MacUIZhulongHomeLayout.composerActionCount, 1)
        XCTAssertTrue(MacUIZhulongHomeLayout.collapsesEmptyPendingSection)
        XCTAssertTrue(MacUIZhulongHomeLayout.collapsesHomeDetailRail)
        XCTAssertEqual(
            MacUIZhulongHomeLayout.contentPlacement(hasPendingSessions: false),
            .centered
        )
        XCTAssertEqual(
            MacUIZhulongHomeLayout.contentPlacement(hasPendingSessions: true),
            .topAligned
        )
    }

    func testZhulongConversationUsesOneReadableChatAxis() {
        XCTAssertEqual(MacUIZhulongConversationLayout.contentMaxWidth, 840)
        XCTAssertEqual(MacUIZhulongConversationLayout.messageSpacing, 32)
        XCTAssertEqual(MacUIZhulongConversationLayout.assistantBodyPointSize, 15.5)
        XCTAssertEqual(MacUIZhulongConversationLayout.userBodyPointSize, 14.5)
        XCTAssertEqual(MacUIZhulongConversationLayout.userBubbleMaxWidth, 570)
        XCTAssertEqual(MacUIZhulongConversationLayout.userBubbleCornerRadius, 20)
        XCTAssertEqual(MacUIZhulongConversationLayout.composerMinimumHeight, 106)
        XCTAssertEqual(MacUIZhulongConversationLayout.composerEditorHeight, 62)
        XCTAssertEqual(MacUIZhulongConversationLayout.composerCornerRadius, 20)
        XCTAssertTrue(MacUIZhulongConversationLayout.hasPersistentBottomComposer)
        XCTAssertFalse(MacUIZhulongConversationLayout.showsAssistantAvatar)
        XCTAssertFalse(MacUIZhulongConversationLayout.showsMessageTimestamps)
        XCTAssertTrue(MacUIZhulongConversationLayout.sharesComposerAcrossProjections)
    }

    func testZhulongTitleCentersWithoutChangingSharedPageHeaderDefault() {
        XCTAssertEqual(MacUIPageHeaderLayout.defaultTitlePlacement, .leading)
        XCTAssertEqual(
            MacUIZhulongHomeLayout.titlePlacement,
            .centeredInMainSurface
        )
        XCTAssertTrue(
            MacUIDesignContract.current.zhulongHomeElements.contains(
                .centeredPageTitle
            )
        )
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

import Foundation

public enum MacUINavigationGroup: String, CaseIterable, Sendable {
    case plan = "计划"
    case trace = "轨迹"
    case footer = "底部"
}

public enum MacUIGlobalElement: String, CaseIterable, Sendable {
    case macWindowChrome
    case nativeFullSizeContentTitlebar
    case workspaceExtendsIntoTitlebar
    case trafficLights
    case systemTrafficLights
    case operableTrafficLights
    case resizableWindow
    case closeWindowKeepsAppRunning
    case visibleWindowBoundary
    case integratedWindowControls
    case pageDerivedWindowTitle
    case lightDeskBackground
    case coolGrayTheme
    case warmPaperTheme
    case chineseCopy
    case englishCopy
    case hoverFeedback
    case riseToastAnimation
    case dateStripSelectionAnimation
    case semanticStatusStyles
    case protectedActionButtonLabels
    case nativeProductivityWorkspace
    case quietSidebarSurface
    case lowContrastControlSurfaces
    case borderlessListRows
    case collapsibleSidebar
    case sidebarExpandedByDefault
    case sidebarCompactsToIconRail
    case stableWindowFrameDuringSidebarToggle
    case collapsibleDetailRail
    case detailRailCollapsedByDefault
    case calendarUsesCollapsibleDetailRail
    case stableWindowFrameDuringDetailRailToggle
    case spatiallySeparatedRailControls
    case completePaneToggleHitTarget
    case completeHeaderNavigationHitTarget
    case paneSafeAreaHandledAtHostingBoundary
    case calendarGridSlotsOwnBoundaries
    case viewMenuRailCommands
    case adaptiveMainSurfaceWidth
    case nativeMainMenu
    case nativeSettingsWindow
    case restorableWindow
    case adjustableSplitView
    case workspaceKeyboardSelection
    case workspaceMultipleSelection
    case globalSearchCommand
    case quickEntryCommand
    case semanticErrorPresentation
    case increaseContrast
    case differentiateWithoutColor
    case reduceMotion
    case reduceTransparency
}

public enum MacUIWindowMetric: String, CaseIterable, Sendable {
    case defaultLaunch1200x768
    case minimum960x720
}

public enum MacUIWindowLayout {
    public static let defaultWidth = 1200.0
    public static let defaultHeight = 768.0
    public static let minimumWidth = 960.0
    public static let minimumHeight = 720.0
}

public enum MacUISettingsWindowLayout {
    public static let minimumContentWidth = 700.0
    public static let minimumContentHeight = 520.0
    public static let initialContentWidth = 860.0
    public static let initialContentHeight = 660.0
    public static let sidebarMinimumWidth = 220.0
    public static let sidebarIdealWidth = 230.0
    public static let sidebarMaximumWidth = 240.0
}

public enum MacUIShellLayout {
    public static let sidebarWidth = 220.0
    public static let compactSidebarWidth = 72.0
    public static let detailRailWidth = 280.0
    public static let calendarRailWidth = 248.0
    public static let paneToggleButtonSize = 28.0
    public static let pageHorizontalPadding = 20.0
    public static let taskRowVerticalPadding = 8.0
    public static let detailPadding = 14.0
    public static let navigationRowHeight = 34.0
    public static let sidebarExpandedByDefault = true
    public static let detailRailCollapsedByDefault = true
}

public enum MacUIPageHeaderTitlePlacement: Equatable, Sendable {
    case leading
    case centeredInMainSurface
}

public enum MacUIPageHeaderLayout {
    public static let defaultTitlePlacement = MacUIPageHeaderTitlePlacement.leading
}

public enum MacUICalendarGridLayout {
    public static let columnCount = 7
    public static let minimumRowCount = 5
    public static let completesTrailingBlankSlots = true
    public static let blankSlotsRenderGridBoundaries = true
}

public enum MacUIDatePickerLayout {
    public static let sheetWidth = 340.0
    public static let outerPadding = 18.0
    public static let contentWidth = 304.0
    public static let columnCount = 7
    public static let rowCount = 6
    public static let columnSpacing = 4.0
    public static let rowSpacing = 2.0
    public static let dayCellHeight = 30.0
    public static let selectionDiameter = 24.0
    public static let fullCellHitTarget = true
    public static let localDateOnlyDraft = true
    public static let stablePresentationIdentity = true
    public static let showsAdjacentDates = true
    public static let omitsUnconstrainedHint = true
    public static let purposeSpecificConfirmation = true
    public static let supportsKeyboardArrows = true
}

public enum MacUITaskRowLayout {
    public static let completionControlSize = 28.0
    public static let accessorySpacing = 12.0
    public static let identityPrecedesAccessories = true
    public static let completionFollowsAccessories = true
    public static let flexibleSpaceFollowsAccessories = true
}

public enum MacUICalendarDetailRowLayout {
    public static let titlePointSize = 12.5
    public static let titleLineLimit = 2
    public static let metadataPointSize = 10.5
    public static let horizontalPadding = 10.0
    public static let verticalPadding = 8.0
    public static let statusRepresentationCount = 1
    public static let exposesFullTitleToAccessibility = true
}

public enum MacUICalendarInsightRowLayout {
    public static let labelLineLimit = 1
    public static let usesSharedIntrinsicLabelColumn = true
}

public enum MacUITaskLabelPatchLayout {
    public static let semanticFillOpacity = 0.10
    public static let borderLineWidth = 1.0
    public static let usesDashedBorder = false
    public static let overflowUsesDashedBorder = false
}

public enum MacUIFuturePlanDetailLayout {
    public static let metadataSpacing = 8.0
    public static let summaryCardCount = 0
    public static let noticeCount = 1
}

public enum MacUIIconMetrics {
    public static let paneToggleChevronSize = 8.5
    public static let navigationSize = 14.0
}

public enum MacUIAccessibilityLayout {
    public static let minimumInteractiveTargetSize = 28.0
}

public enum MacUIAnimationMetrics {
    public static let toastRiseDuration = 0.20
    public static let dateStripSpringResponse = 0.24
    public static let dateStripSpringDampingFraction = 0.74
}

public struct MacUISRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func contrastRatio(against other: MacUISRGBColor) -> Double {
        let brighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (brighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        let linear = [red, green, blue].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}

public enum MacUIAccessibleColorMetrics {
    public static let minimumSmallTextContrast = 4.5
    public static let success = MacUISRGBColor(red: 0.04, green: 0.45, blue: 0.30)
    public static let coolGrayTertiaryText = MacUISRGBColor(red: 0.455, green: 0.455, blue: 0.495)
    public static let coolGrayBackground = MacUISRGBColor(red: 0.994, green: 0.993, blue: 0.991)
    public static let warmPaperTertiaryText = MacUISRGBColor(red: 0.47, green: 0.405, blue: 0.335)
    public static let warmPaperBackground = MacUISRGBColor(red: 0.997, green: 0.992, blue: 0.982)
}

public enum MacUITypographyMetrics {
    public static let scale = 1.0
    public static let compactThreshold = 10.5
    public static let compactEditorBasePointSize = 12.5
    public static let compactEditorPointSize = compactPointSize(compactEditorBasePointSize)
    public static let compactEditorVerticalInset = 8.5

    public static func compactPointSize(_ baseSize: Double) -> Double {
        guard baseSize >= compactThreshold else { return baseSize }
        return (baseSize * scale * 2).rounded() / 2
    }
}

public enum MacUIColorToken: String, CaseIterable, Sendable {
    case accent
    case ok
    case warn
    case chip
    case panel
    case line
    case t1
    case t2
    case t3
}

public enum MacUINavigationElement: String, CaseIterable, Sendable {
    case planGroupHeader
    case traceGroupHeader
    case pageIcons
    case unifiedNavigationIcons
    case semanticNavigationIconColors
    case quietSelectedPill
    case countBadges
    case zhulongEntryVisibilityFollowsSettings
}

public enum MacUIPage: String, CaseIterable, Sendable {
    case dayTodo
    case taskPool
    case futurePlans
    case unfinishedPool
    case completedPool
    case calendar
    case zhulong
}

public enum MacUIZhulongHomeElement: String, CaseIterable, Sendable {
    case freeformIntentComposer
    case verticallyCenteredHomeContent
    case centeredPageTitle
    case singleVisualAxis
    case roundedRectIntentComposer
    case flatWorkflowList
    case quietSuggestionModeLabel
    case collapsedEmptyPendingSection
    case collapsedHomeDetailRail
    case coreWorkflowEntrances
    case specialistAssistantEntrances
    case directWorkflowStart
    case noDecorativeComposerAction
}

public enum MacUIDayTodoElement: String, CaseIterable, Sendable {
    case dateTitle
    case weekday
    case dayKindBadge
    case previousDayButton
    case todayButton
    case nextDayButton
    case pickDateButton
    case fourteenDayStrip
    case dateStripSelectedPill
    case dateStripTodayOutline
    case accessibleDateCellState
    case dateStripTaskPresenceDot
    case keyboardDateNavigation
    case historyLockNotice
    case futureDayNotice
    case quickAddInput
    case fromPoolButton
    case taskRows
    case taskRowSelectedState
    case taskRowTitle
    case taskRowProgress
    case taskRowTrajectoryMetadata
    case changedTraceTargetJump
    case taskRowSubtaskExpansion
    case singleStatusGlyph
    case dragReordering
    case selectedReorderControls
    case emptyState
}

public enum MacUITaskPoolElement: String, CaseIterable, Sendable {
    case title
    case description
    case newTaskInput
    case taskRows
    case unscheduledPlaceholder
    case rowContextMenu
    case scheduleTodayContextMenuAction
    case scheduleTomorrowContextMenuAction
    case scheduleToDateContextMenuAction
    case deleteContextMenuAction
    case sharedRowAndDetailActions
    case emptyState
}

public enum MacUIFuturePlanElement: String, CaseIterable, Sendable {
    case title
    case description
    case groupedByDate
    case jumpDayLink
    case taskRows
    case selectTaskAction
    case contextMenuAction
    case openDetailAction
    case rescheduleAction
    case returnToPoolAction
    case dragReordering
    case selectedReorderControls
    case emptyState
}

public enum MacUIUnfinishedPoolElement: String, CaseIterable, Sendable {
    case title
    case description
    case dedupedChainRows
    case missedCount
    case continuationCount
    case lastMissedDate
    case rowContextMenu
    case activeTraceJumpAction
    case continueContextMenuAction
    case abandonContextMenuAction
    case reenableAbandonedContextMenuAction
    case detailsExpansion
    case automaticClassificationStatus
    case emptyState
}

public enum MacUICompletedPoolElement: String, CaseIterable, Sendable {
    case title
    case description
    case groupedByCompletionDate
    case parentCompletionRecord
    case subtaskCompletionRecord
    case trajectoryNodes
    case rowContextMenu
    case jumpDayContextMenuAction
    case copyAsNewTaskContextMenuAction
    case automaticClassificationStatus
    case emptyState
}

public enum MacUICalendarElement: String, CaseIterable, Sendable {
    case monthTitle
    case previousMonthButton
    case todayButton
    case nextMonthButton
    case mondayFirstWeekHeader
    case monthGrid
    case dateCells
    case keyboardDateNavigation
    case todayMarker
    case completionHeatBlock
    case taskSummaries
    case moreCount
    case selectedDayDetail
    case selectedDayBadge
    case selectedDayTaskCount
    case openDayTodoLink
    case selectedDayStatusDistribution
    case selectedDayCompletionRate
    case selectedDayContinuationSummary
    case selectedDayChangeSummary
    case selectedDayRiskSummary
    case selectedDayTaskList
    case compactSelectedDayTaskRows
    case changedTraceTargetJump
    case emptyState
}

public enum MacUIDetailElement: String, CaseIterable, Sendable {
    case unselectedDayReviewRail
    case unselectedPageHint
    case unselectedRailHint
    case unselectedPageSummaryRail
    case unselectedLocalStats
    case unselectedAlgorithmicSuggestions
    case unselectedZhulongPlaceholder
    case calendarNoGenericDetailRail
    case calendarOwnDetailPanel
    case settingsNoDetailRail
    case detailPanelTitle
    case closeButton
    case taskTitle
    case overflowMenu
    case iconOnlyOverflowMenu
    case statusChip
    case dateOrPoolLocation
    case traceMetadataCard
    case historyReadonlyNotice
    case progressSection
    case compactClassificationEditor
    case classificationValuePicker
    case onDemandClassificationLabelInput
    case descriptionEditor
    case descriptionImmediatelyUnderTitle
    case descriptionWithoutSectionTitle
    case compactTitleDescriptionLayout
    case primaryTextSharesDetailAxis
    case borderlessDescriptionEditor
    case markdownDescriptionEditing
    case nativeDescriptionEditingCommands
    case sharedRowAndOverflowMenuActions
    case noteSection
    case timestampedNoteEntries
    case noteComposerInput
    case singleLineNoteComposer
    case singleNoteSurface
    case noteEntryOverflowMenu
    case editableNoteEntries
    case deletableNoteEntries
    case subtaskSection
    case subtaskCompletionDate
    case subtaskLockedIcon
    case subtaskDifficultyWeight
    case traceTimeline
    case changedTraceTargetJump
}

public enum MacUIDetailEditorLayout {
    public static let titleDescriptionSpacing = 6.0
    public static let titleHeight: ClosedRange<Double> = 22 ... 72
    public static let descriptionHeight: ClosedRange<Double> = 32 ... 132
    public static let horizontalTextInset = 0.0
    public static let verticalTextInset = 3.0
    public static let lineFragmentPadding = 0.0
}

public enum MacUIMarkdownEditingCommand: String, CaseIterable, Sendable {
    case selectAll
    case cut
    case copy
    case paste
    case undo
    case redo
    case bold
    case italic
    case inlineCode
    case link
    case indent
    case hardLineBreak
}

public enum MacUIReviewElement: String, CaseIterable, Sendable {
    case reviewHeader
    case zhulongAnalysisButton
    case autosavedIndicator
    case historyReviewNotice
    case futureNoReviewState
    case statsCard
    case segmentedStatusBar
    case statusLegend
    case summaryInput
    case unfinishedReasonInput
    case tomorrowNoteInput
}

public enum MacUIEmptyStateElement: String, CaseIterable, Sendable {
    case semanticSymbol
    case copy
    case contextualPrimaryAction
}

public enum MacUIPageEmptyStateElement: String, CaseIterable, Sendable {
    case dayTodoSymbol
    case dayTodoCopy
    case dayTodoPrimaryAction
    case taskPoolSymbol
    case taskPoolCopy
    case taskPoolPrimaryAction
    case futurePlansSymbol
    case futurePlansCopy
    case futurePlansPrimaryAction
    case unfinishedPoolSymbol
    case unfinishedPoolCopy
    case completedPoolSymbol
    case completedPoolCopy
    case calendarSymbol
    case calendarCopy
}

public enum MacUITaskAction: String, CaseIterable, Sendable {
    case markDone
    case undoDone
    case continueToDate
    case changeIntoNewTask
    case returnToPool
    case abandonChain
    case reactivateAbandonedChain
    case reschedule
    case copyAsNewTask
    case scheduleToday
    case scheduleTomorrow
    case scheduleToDate
    case deleteTask
    case addTask
    case addSubtask
    case toggleSubtask
    case cycleSubtaskDifficulty
    case editDescription
    case addNote
    case editNote
    case deleteNote
    case dragManualProgress
    case editDailyReview
    case changeTheme
    case changeLanguage
    case exportData
    case importData
    case undo
    case redo
    case bulkComplete
    case bulkScheduleToday
    case bulkReturnToPool
    case reorderTask
}

public enum MacUIModal: String, CaseIterable, Sendable {
    case centeredClassificationManager
    case continueDatePicker
    case scheduleDatePicker
    case moveFutureDatePicker
    case gotoDatePicker
    case scheduleFromPoolPicker
    case changeTaskDialog
    case changeDialogOldTaskStrikethroughPreview
    case changeDialogNewTaskTitleInput
    case changeDialogConfirmButton
    case contextMenu
    case toast
    case undoUnavailableToast
}

public enum MacUISettingsElement: String, CaseIterable, Sendable {
    case coolGrayTheme
    case warmPaperTheme
    case chineseLanguage
    case englishLanguage
    case exportJSON
    case importData
    case localFirstDataMode
    case onlineFirstDataMode
    case localFirstCloudSync
    case cloudSyncEndpoint
    case syncTriggerMode
    case syncSnapshotRetention
    case syncConflictCopy
    case scheduledBackupPolicy
    case backupDestination
    case customSyncEndpoint
    case iCloudSync
    case s3Sync
    case webDAVSync
    case localFolderSync
    case zhulongEnabledToggle
    case zhulongProviderConfiguration
    case nativeSettingsWindow
    case nativeSidebarSelection
    case flatFormSections
    case poemInAboutPanel
    case compactClassificationSummary
    case classificationManagerTypeSwitcher
    case classificationManagerSearch
    case classificationManagerInlineCreation
    case classificationManagerLifecycleSections
    case classificationManagerLifecycleActions
    case classificationManagerReferenceCounts
    case classificationManagerHistoryNotice
}

public enum MacUIClassificationLayout {
    public static let settingsSummaryHeight = 112.0
    public static let managerWidth = 560.0
    public static let managerHeight = 460.0
    public static let managerRowHeight = 42.0
}

public enum MacUIZhulongHomeContentPlacement: Equatable, Sendable {
    case centered
    case topAligned
}

public enum MacUIZhulongHomeLayout {
    public static let contentMaxWidth = 780.0
    public static let headerOuterMaxWidth = contentMaxWidth + (MacUIShellLayout.pageHorizontalPadding * 2)
    public static let composerHeight = 54.0
    public static let composerCornerRadius = 14.0
    public static let workflowRowHeight = 62.0
    public static let workflowListCount = 1
    public static let composerActionCount = 1
    public static let collapsesEmptyPendingSection = true
    public static let collapsesHomeDetailRail = true
    public static let titlePlacement = MacUIPageHeaderTitlePlacement.centeredInMainSurface

    public static func contentPlacement(hasPendingSessions: Bool) -> MacUIZhulongHomeContentPlacement {
        hasPendingSessions ? .topAligned : .centered
    }
}

public enum MacUIZhulongConversationLayout {
    public static let contentMaxWidth = 840.0
    public static let messageSpacing = 32.0
    public static let assistantBodyPointSize = 15.5
    public static let userBodyPointSize = 14.5
    public static let userBubbleMaxWidth = 570.0
    public static let userBubbleCornerRadius = 20.0
    public static let composerMinimumHeight = 106.0
    public static let composerEditorHeight = 62.0
    public static let composerCornerRadius = 20.0
    public static let composerBodyPointSize = 14.5
    public static let composerHorizontalInset = 16.0
    public static let composerVerticalInset = 10.0
    public static let hasPersistentBottomComposer = true
    public static let showsAssistantAvatar = false
    public static let showsMessageTimestamps = false
    public static let sharesComposerAcrossProjections = true
}

public enum MacUIClassificationAccessibility {
    public static let renameActionPrefix = "classification.manager.lifecycle.rename"
    public static let archiveActionPrefix = "classification.manager.lifecycle.archive"
    public static let restoreActionPrefix = "classification.manager.lifecycle.restore"
    public static let discardActionPrefix = "classification.manager.lifecycle.discard"
}

public enum MacUIAutomaticClassificationSurface: String, CaseIterable, Sendable {
    case dayRow = "day-row"
    case taskPoolRow = "task-pool-row"
    case futureRow = "future-row"
    case unfinishedRow = "unfinished-row"
    case completedRow = "completed-row"
    case completedSubtaskRow = "completed-subtask-row"
}

public enum MacUIAutomaticClassificationRetryKind: String, Sendable {
    case job
    case providerCircuit = "provider-circuit"
}

public enum MacUIAutomaticClassificationAccessibility {
    public static func statusIdentifier(
        surface: MacUIAutomaticClassificationSurface,
        instanceID: String
    ) -> String {
        "automatic-classification.status.\(surface.rawValue).\(instanceID)"
    }

    public static func retryIdentifier(
        surface: MacUIAutomaticClassificationSurface,
        instanceID: String,
        kind: MacUIAutomaticClassificationRetryKind
    ) -> String {
        "\(statusIdentifier(surface: surface, instanceID: instanceID)).retry.\(kind.rawValue)"
    }
}

public enum MacUIBackendCapability: String, CaseIterable, Sendable {
    case taskDescription
    case taskNote
    case manualProgress
    case subtaskDifficultyWeight
    case weightedSubtaskProgress
    case progressFloor
    case completedSubtaskRecords
    case calendarDaySummary
    case returnedToPoolTaskPoolView
    case changePointer
    case undoRedo
    case atomicMutationHistory
    case themeSetting
    case languageSetting
    case dataModeSelection
    case localFirstCloudSync
    case syncRepositorySnapshots
    case syncSnapshotRetention
    case scheduledBackup
    case syncEndpointOptions
    case exportImport
    case syncPlaceholders
}

public struct MacUIDesignContract: Sendable {
    public let globalElements: [MacUIGlobalElement]
    public let windowMetrics: [MacUIWindowMetric]
    public let colorTokens: [MacUIColorToken]
    public let navigationElements: [MacUINavigationElement]
    public let pages: [MacUIPage]
    public let zhulongHomeElements: [MacUIZhulongHomeElement]
    public let dayTodoElements: [MacUIDayTodoElement]
    public let taskPoolElements: [MacUITaskPoolElement]
    public let futurePlanElements: [MacUIFuturePlanElement]
    public let unfinishedPoolElements: [MacUIUnfinishedPoolElement]
    public let completedPoolElements: [MacUICompletedPoolElement]
    public let calendarElements: [MacUICalendarElement]
    public let detailElements: [MacUIDetailElement]
    public let reviewElements: [MacUIReviewElement]
    public let emptyStateElements: [MacUIEmptyStateElement]
    public let pageEmptyStateElements: [MacUIPageEmptyStateElement]
    public let markdownEditingCommands: [MacUIMarkdownEditingCommand]
    public let taskActions: [MacUITaskAction]
    public let modals: [MacUIModal]
    public let settingsElements: [MacUISettingsElement]
    public let backendCapabilities: [MacUIBackendCapability]

    public init(
        globalElements: [MacUIGlobalElement] = MacUIGlobalElement.allCases,
        windowMetrics: [MacUIWindowMetric] = MacUIWindowMetric.allCases,
        colorTokens: [MacUIColorToken] = MacUIColorToken.allCases,
        navigationElements: [MacUINavigationElement] = MacUINavigationElement.allCases,
        pages: [MacUIPage] = MacUIPage.allCases,
        zhulongHomeElements: [MacUIZhulongHomeElement] = MacUIZhulongHomeElement.allCases,
        dayTodoElements: [MacUIDayTodoElement] = MacUIDayTodoElement.allCases,
        taskPoolElements: [MacUITaskPoolElement] = MacUITaskPoolElement.allCases,
        futurePlanElements: [MacUIFuturePlanElement] = MacUIFuturePlanElement.allCases,
        unfinishedPoolElements: [MacUIUnfinishedPoolElement] = MacUIUnfinishedPoolElement.allCases,
        completedPoolElements: [MacUICompletedPoolElement] = MacUICompletedPoolElement.allCases,
        calendarElements: [MacUICalendarElement] = MacUICalendarElement.allCases,
        detailElements: [MacUIDetailElement] = MacUIDetailElement.allCases,
        reviewElements: [MacUIReviewElement] = MacUIReviewElement.allCases,
        emptyStateElements: [MacUIEmptyStateElement] = MacUIEmptyStateElement.allCases,
        pageEmptyStateElements: [MacUIPageEmptyStateElement] = MacUIPageEmptyStateElement.allCases,
        markdownEditingCommands: [MacUIMarkdownEditingCommand] = MacUIMarkdownEditingCommand.allCases,
        taskActions: [MacUITaskAction] = MacUITaskAction.allCases,
        modals: [MacUIModal] = MacUIModal.allCases,
        settingsElements: [MacUISettingsElement] = MacUISettingsElement.allCases,
        backendCapabilities: [MacUIBackendCapability] = MacUIBackendCapability.allCases
    ) {
        self.globalElements = globalElements
        self.windowMetrics = windowMetrics
        self.colorTokens = colorTokens
        self.navigationElements = navigationElements
        self.pages = pages
        self.zhulongHomeElements = zhulongHomeElements
        self.dayTodoElements = dayTodoElements
        self.taskPoolElements = taskPoolElements
        self.futurePlanElements = futurePlanElements
        self.unfinishedPoolElements = unfinishedPoolElements
        self.completedPoolElements = completedPoolElements
        self.calendarElements = calendarElements
        self.detailElements = detailElements
        self.reviewElements = reviewElements
        self.emptyStateElements = emptyStateElements
        self.pageEmptyStateElements = pageEmptyStateElements
        self.markdownEditingCommands = markdownEditingCommands
        self.taskActions = taskActions
        self.modals = modals
        self.settingsElements = settingsElements
        self.backendCapabilities = backendCapabilities
    }

    public static let current = MacUIDesignContract()
}

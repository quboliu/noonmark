public enum MacUINavigationGroup: String, CaseIterable, Sendable {
    case plan = "计划"
    case trace = "轨迹"
    case footer = "底部"
}

public enum MacUIGlobalElement: String, CaseIterable, Sendable {
    case macWindowChrome
    case trafficLights
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
    case todoistInspiredUnifiedShell
    case quietSidebarSurface
    case lowContrastControlSurfaces
    case borderlessListRows
    case collapsibleSidebar
    case sidebarExpandedByDefault
    case stableWindowFrameDuringSidebarToggle
    case collapsibleDetailRail
    case detailRailCollapsedByDefault
    case calendarUsesCollapsibleDetailRail
    case stableWindowFrameDuringDetailRailToggle
    case adaptiveMainSurfaceWidth
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

public enum MacUIShellLayout {
    public static let sidebarWidth = 220.0
    public static let collapsedSidebarWidth = 76.0
    public static let detailRailWidth = 280.0
    public static let calendarRailWidth = 248.0
    public static let pageHorizontalPadding = 20.0
    public static let taskRowVerticalPadding = 8.0
    public static let detailPadding = 14.0
    public static let navigationRowHeight = 34.0
    public static let sidebarExpandedByDefault = true
    public static let detailRailCollapsedByDefault = true
}

public enum MacUIIconMetrics {
    public static let trafficLightDiameter = 12.0
    public static let trafficLightHitTarget = 20.0
    public static let navigationSize = 14.0
}

public enum MacUITypographyMetrics {
    public static let scale = 0.92
    public static let compactThreshold = 10.5
    public static let compactEditorBasePointSize = 12.5
    public static let compactEditorPointSize = compactPointSize(compactEditorBasePointSize)

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
    case windowBoundary
    case t1
    case t2
    case t3
}

public enum MacUINavigationElement: String, CaseIterable, Sendable {
    case planGroupHeader
    case traceGroupHeader
    case pageIcons
    case semanticIconColors
    case selectedBackground
    case selectedLeadingBar
    case quietSelectedPill
    case countBadges
    case zhulongEntryVisibilityFollowsSettings
    case settingsFooterItem
}

public enum MacUINavigationIconColorToken: CaseIterable, Sendable {
    case dayTodo
    case taskPool
    case futurePlans
    case unfinishedPool
    case completedPool
    case calendar
    case zhulong
    case settings

    public var hexValue: String {
        switch self {
        case .dayTodo:
            return "#2A6FDB"
        case .taskPool:
            return "#0E9488"
        case .futurePlans:
            return "#7C5CFF"
        case .unfinishedPool:
            return "#E0851B"
        case .completedPool:
            return "#1F8A5B"
        case .calendar:
            return "#D1477A"
        case .zhulong:
            return "#7C5CFF"
        case .settings:
            return "#64748B"
        }
    }
}

public enum MacUIPage: String, CaseIterable, Sendable {
    case dayTodo
    case taskPool
    case futurePlans
    case unfinishedPool
    case completedPool
    case calendar
    case zhulong
    case settings
}

public enum MacUIZhulongHomeElement: String, CaseIterable, Sendable {
    case freeformIntentComposer
    case verticallyCenteredHomeContent
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
    case dateStripSelectedDot
    case dateStripTaskPresenceDot
    case keyboardDateNavigation
    case historyLockNotice
    case futureDayNotice
    case quickAddInput
    case fromPoolButton
    case taskRows
    case taskRowSelectedState
    case taskRowStatusDot
    case taskRowTitle
    case taskRowProgress
    case taskRowTrajectoryMetadata
    case changedTraceTargetJump
    case taskRowSubtaskExpansion
    case statusChips
    case priorityStepper
    case taskRowMoveButtons
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
    /// Domain priority adjustment; taskRowMoveButtons is the row-level visual entry for the same ordering operation.
    case priorityStepper
    /// Row-level visual entry for priorityStepper ordering in future plans.
    case taskRowMoveButtons
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
    public static let textInset = 3.0
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
    case illustration
    case copy
}

public enum MacUIPageEmptyStateElement: String, CaseIterable, Sendable {
    case dayTodoIllustration
    case dayTodoCopy
    case taskPoolIllustration
    case taskPoolCopy
    case futurePlansIllustration
    case futurePlansCopy
    case unfinishedPoolIllustration
    case unfinishedPoolCopy
    case completedPoolIllustration
    case completedPoolCopy
    case calendarIllustration
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
    case balancedSettingsLayout
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

    public static func contentPlacement(hasPendingSessions: Bool) -> MacUIZhulongHomeContentPlacement {
        hasPendingSessions ? .topAligned : .centered
    }
}

public enum MacUIClassificationAccessibility {
    public static let renameActionPrefix = "classification.manager.lifecycle.rename"
    public static let archiveActionPrefix = "classification.manager.lifecycle.archive"
    public static let restoreActionPrefix = "classification.manager.lifecycle.restore"
    public static let discardActionPrefix = "classification.manager.lifecycle.discard"
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
    case limitedUndo
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
    public let navigationIconColorTokens: [MacUINavigationIconColorToken]
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
        navigationIconColorTokens: [MacUINavigationIconColorToken] = MacUINavigationIconColorToken.allCases,
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
        self.navigationIconColorTokens = navigationIconColorTokens
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

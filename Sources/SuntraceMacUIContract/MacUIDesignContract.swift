public enum MacUINavigationGroup: String, CaseIterable, Sendable {
    case plan = "计划"
    case trace = "轨迹"
    case footer = "底部"
}

public enum MacUIGlobalElement: String, CaseIterable, Sendable {
    case macWindowChrome
    case trafficLights
    case centeredWindowTitle
    case pageDerivedWindowTitle
    case appClockLogo
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
}

public enum MacUIWindowMetric: String, CaseIterable, Sendable {
    case prototypePreview1440x900
    case maxContent1400x880
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
    case semanticIconColors
    case selectedBackground
    case selectedLeadingBar
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
    case scheduleTodayButton
    case scheduleTomorrowButton
    case pickDateButton
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
    case activeTraceJump
    case continueButton
    case abandonButton
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
    case jumpDayButton
    case copyAsNewTaskButton
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
    case descriptionSection
    case descriptionImmediatelyUnderTitle
    case descriptionWithoutSectionTitle
    case noteSection
    case timestampedNoteEntries
    case appendOnlyNoteInput
    case subtaskSection
    case subtaskCompletionDate
    case subtaskLockedIcon
    case subtaskDifficultyWeight
    case traceTimeline
    case changedTraceTargetJump
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
    case reschedule
    case copyAsNewTask
    case scheduleToday
    case scheduleTomorrow
    case scheduleToDate
    case addTask
    case addSubtask
    case toggleSubtask
    case cycleSubtaskDifficulty
    case editDescription
    case editNote
    case dragManualProgress
    case editDailyReview
    case changeTheme
    case changeLanguage
    case exportData
    case importData
    case undo
}

public enum MacUIModal: String, CaseIterable, Sendable {
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
    case customSyncEndpoint
    case iCloudSync
    case zhulongEnabledToggle
    case zhulongProviderConfiguration
    case balancedSettingsLayout
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
        self.taskActions = taskActions
        self.modals = modals
        self.settingsElements = settingsElements
        self.backendCapabilities = backendCapabilities
    }

    public static let claudeMacPrototype20260705 = MacUIDesignContract()
}

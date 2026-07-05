public enum MacUINavigationGroup: String, CaseIterable, Sendable {
    case plan = "计划"
    case trace = "轨迹"
    case footer = "底部"
}

public enum MacUIPage: String, CaseIterable, Sendable {
    case dayTodo
    case taskPool
    case futurePlans
    case unfinishedPool
    case completedPool
    case calendar
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
    case historyLockNotice
    case futureDayNotice
    case quickAddInput
    case fromPoolButton
    case taskRows
    case taskRowProgress
    case taskRowSubtaskExpansion
    case statusChips
    case priorityStepper
    case emptyState
}

public enum MacUIDetailElement: String, CaseIterable, Sendable {
    case closeButton
    case taskTitle
    case overflowMenu
    case statusChip
    case dateOrPoolLocation
    case traceMetadataCard
    case historyReadonlyNotice
    case progressSection
    case descriptionSection
    case noteSection
    case subtaskSection
    case traceTimeline
}

public enum MacUIReviewElement: String, CaseIterable, Sendable {
    case reviewHeader
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
}

public enum MacUIModal: String, CaseIterable, Sendable {
    case continueDatePicker
    case scheduleDatePicker
    case moveFutureDatePicker
    case gotoDatePicker
    case scheduleFromPoolPicker
    case changeTaskDialog
    case contextMenu
    case toast
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
    case limitedUndo
    case themeSetting
    case languageSetting
    case exportImport
    case syncPlaceholders
}

public struct MacUIDesignContract: Sendable {
    public let pages: [MacUIPage]
    public let dayTodoElements: [MacUIDayTodoElement]
    public let detailElements: [MacUIDetailElement]
    public let reviewElements: [MacUIReviewElement]
    public let taskActions: [MacUITaskAction]
    public let modals: [MacUIModal]
    public let settingsElements: [MacUISettingsElement]
    public let backendCapabilities: [MacUIBackendCapability]

    public init(
        pages: [MacUIPage] = MacUIPage.allCases,
        dayTodoElements: [MacUIDayTodoElement] = MacUIDayTodoElement.allCases,
        detailElements: [MacUIDetailElement] = MacUIDetailElement.allCases,
        reviewElements: [MacUIReviewElement] = MacUIReviewElement.allCases,
        taskActions: [MacUITaskAction] = MacUITaskAction.allCases,
        modals: [MacUIModal] = MacUIModal.allCases,
        settingsElements: [MacUISettingsElement] = MacUISettingsElement.allCases,
        backendCapabilities: [MacUIBackendCapability] = MacUIBackendCapability.allCases
    ) {
        self.pages = pages
        self.dayTodoElements = dayTodoElements
        self.detailElements = detailElements
        self.reviewElements = reviewElements
        self.taskActions = taskActions
        self.modals = modals
        self.settingsElements = settingsElements
        self.backendCapabilities = backendCapabilities
    }

    public static let claudeMacPrototype20260705 = MacUIDesignContract()
}

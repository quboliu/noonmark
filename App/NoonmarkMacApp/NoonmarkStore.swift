import AppKit
import Combine
import CryptoKit
import Foundation
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

enum PersistenceFailureE2EError: LocalizedError {
    case injectedSaveFailure
    case unsafeFailpointRequest

    var errorDescription: String? {
        switch self {
        case .injectedSaveFailure:
            "E2E injected isolated persistence save failure"
        case .unsafeFailpointRequest:
            "save failpoint requires the E2E app, an explicit data URL, and its automation flag"
        }
    }
}

enum DataPackageImportError: LocalizedError {
    case syncInProgress

    var errorDescription: String? {
        switch self {
        case .syncInProgress:
            "同步正在进行，完成后才能导入数据包。"
        }
    }
}

enum DataImportCommitE2EError: LocalizedError {
    case unsafePauseRequest
    case pauseAlreadyArmed

    var errorDescription: String? {
        switch self {
        case .unsafePauseRequest:
            "data-import pause requires the isolated E2E data-package workflow"
        case .pauseAlreadyArmed:
            "data-import pause is already armed or active"
        }
    }
}

struct EnginePersistenceCommitError: LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        "保存失败：\(underlying.localizedDescription)"
    }
}

enum StoreMutationGateError: LocalizedError {
    case exclusiveOperationInProgress
    case pendingZhulongApplication

    var errorDescription: String? {
        switch self {
        case .exclusiveOperationInProgress:
            "数据替换正在进行，请完成后再修改任务。"
        case .pendingZhulongApplication:
            "烛龙应用仍待恢复，请先完成恢复再修改任务。"
        }
    }

    var isPendingZhulongApplication: Bool {
        if case .pendingZhulongApplication = self { return true }
        return false
    }
}

enum NaturalDayMutationError: LocalizedError {
    case boundaryNotApplied

    var errorDescription: String? {
        "The current day has not been safely applied to local data."
    }
}

struct AppOperationFailureNotice: Equatable, Identifiable {
    let id: UUID
    let context: AppOperationFailureContext
    let message: String

    init(context: AppOperationFailureContext, message: String) {
        id = UUID()
        self.context = context
        self.message = message
    }
}

@MainActor
final class NoonmarkStore: ObservableObject {
    static let undoHistoryLimit = 100

    struct DomainEditAction {
        private let nameResolver: @Sendable (AppCopy) -> String

        private init(nameResolver: @escaping @Sendable (AppCopy) -> String) {
            self.nameResolver = nameResolver
        }

        func actionName(copy: AppCopy) -> String {
            nameResolver(copy)
        }

        static let addTask = Self { $0.addTaskAction }
        static let addPoolTask = Self { $0.addPoolTaskAction }
        static let scheduleTask = Self { $0.scheduleTaskAction }
        static let completeTask = Self { $0.completeTaskAction }
        static let updateSubtask = Self { $0.updateSubtaskAction }
        static let continueTask = Self { $0.continueTaskAction }
        static let returnTaskToPool = Self { $0.returnTaskToPoolAction }
        static let abandonTask = Self { $0.abandonTaskAction }
        static let reactivateTask = Self { $0.reactivateTaskAction }
        static let rescheduleTask = Self { $0.rescheduleTaskAction }
        static let reorderTask = Self { $0.reorderTaskAction }
        static let editTaskText = Self { $0.editTaskTextAction }
        static let renameTask = Self { $0.renameTaskAction }
        static let updateProgress = Self { $0.updateProgressAction }
        static let addSubtask = Self { $0.addSubtaskAction }
        static let removeSubtask = Self { $0.removeSubtaskAction }

        static func completeTasks(_ count: Int) -> Self {
            Self { $0.completeTasksAction(count) }
        }

        static func scheduleTasks(_ count: Int) -> Self {
            Self { $0.scheduleTasksAction(count) }
        }

        static func returnTasksToPool(_ count: Int) -> Self {
            Self { $0.returnTasksToPoolAction(count) }
        }
    }

    enum EngineMutationUndoPolicy {
        case preserve
        case snapshot(DomainEditAction)
        case snapshotIfAllowed(on: LocalDate, action: DomainEditAction)
        case invalidate
    }

    enum EngineMutationAutomaticClassificationPolicy {
        case none
        case newlyCreatedTaskChains
        case userClassificationWins(TaskChainID)
    }

    enum QuickTaskTarget {
        case selectedDate
        case today
    }

    enum WorkspaceSelectionItem: Hashable {
        case dayTrace(DayTraceID)
        case poolTask(TaskChainID)
        case futureTrace(DayTraceID)
        case unfinishedTask(TaskChainID)
        case completedTrace(DayTraceID)
        case completedSubtask(SubtaskID)
    }

    enum ExclusiveEngineOperation: Equatable {
        case dataImport(UUID)
    }

    enum DayBoundaryState: Equatable {
        case reconciling(candidate: LocalDate)
        case ready(appliedThrough: LocalDate)
        case blocked(
            appliedThrough: LocalDate,
            candidate: LocalDate,
            message: String
        )

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var appliedThrough: LocalDate? {
            switch self {
            case .reconciling:
                nil
            case let .ready(appliedThrough),
                 let .blocked(appliedThrough, _, _):
                appliedThrough
            }
        }

        var failureMessage: String? {
            guard case let .blocked(_, _, message) = self else { return nil }
            return message
        }

        var candidate: LocalDate {
            switch self {
            case let .reconciling(candidate),
                 let .blocked(_, candidate, _):
                candidate
            case let .ready(appliedThrough):
                appliedThrough
            }
        }
    }

    var onLanguageChange: (() -> Void)?

    enum NoteUndoOwner: Equatable {
        case trace(DayTraceID)
        case pool(TaskChainID)
    }

    struct NoteIdentityRemap {
        let owner: NoteUndoOwner
        let oldID: TaskNoteEntryID
        let newID: TaskNoteEntryID
    }

    enum UndoEntry {
        case snapshot(NoonmarkSnapshot, action: DomainEditAction)
        case copiedTask(snapshot: NoonmarkSnapshot, chainID: TaskChainID)
        case traceNoteAppend(traceID: DayTraceID, noteID: TaskNoteEntryID)
        case traceNoteEdit(
            traceID: DayTraceID,
            noteID: TaskNoteEntryID,
            previousBody: String
        )
        case traceNoteDelete(
            traceID: DayTraceID,
            noteID: TaskNoteEntryID,
            deletedBody: String
        )
        case poolNoteAppend(chainID: TaskChainID, noteID: TaskNoteEntryID)
        case poolNoteEdit(
            chainID: TaskChainID,
            noteID: TaskNoteEntryID,
            previousBody: String
        )
        case poolNoteDelete(
            chainID: TaskChainID,
            noteID: TaskNoteEntryID,
            deletedBody: String
        )

        func actionName(copy: AppCopy) -> String {
            switch self {
            case let .snapshot(_, action):
                action.actionName(copy: copy)
            case .copiedTask:
                copy.copyTaskAction
            case .traceNoteAppend, .poolNoteAppend:
                copy.addNoteAction
            case .traceNoteEdit, .poolNoteEdit:
                copy.editNoteMenuAction
            case .traceNoteDelete, .poolNoteDelete:
                copy.deleteNoteMenuAction
            }
        }

        func remappingNoteIdentity(
            _ remap: NoteIdentityRemap
        ) -> UndoEntry {
            switch (remap.owner, self) {
            case let (.trace(expectedTraceID), .traceNoteAppend(traceID, noteID))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteAppend(traceID: traceID, noteID: remap.newID)
            case let (.trace(expectedTraceID), .traceNoteEdit(traceID, noteID, previousBody))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteEdit(
                    traceID: traceID,
                    noteID: remap.newID,
                    previousBody: previousBody
                )
            case let (.trace(expectedTraceID), .traceNoteDelete(traceID, noteID, deletedBody))
                where traceID == expectedTraceID && noteID == remap.oldID:
                .traceNoteDelete(
                    traceID: traceID,
                    noteID: remap.newID,
                    deletedBody: deletedBody
                )
            case let (.pool(expectedChainID), .poolNoteAppend(chainID, noteID))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteAppend(chainID: chainID, noteID: remap.newID)
            case let (.pool(expectedChainID), .poolNoteEdit(chainID, noteID, previousBody))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteEdit(
                    chainID: chainID,
                    noteID: remap.newID,
                    previousBody: previousBody
                )
            case let (.pool(expectedChainID), .poolNoteDelete(chainID, noteID, deletedBody))
                where chainID == expectedChainID && noteID == remap.oldID:
                .poolNoteDelete(
                    chainID: chainID,
                    noteID: remap.newID,
                    deletedBody: deletedBody
                )
            default:
                self
            }
        }
    }

    enum RedoEntry {
        case snapshot(NoonmarkSnapshot, undoEntry: UndoEntry)
        case traceNoteAppend(traceID: DayTraceID, body: String)
        case traceNoteEdit(traceID: DayTraceID, noteID: TaskNoteEntryID, body: String)
        case traceNoteDelete(traceID: DayTraceID, noteID: TaskNoteEntryID)
        case poolNoteAppend(chainID: TaskChainID, body: String)
        case poolNoteEdit(chainID: TaskChainID, noteID: TaskNoteEntryID, body: String)
        case poolNoteDelete(chainID: TaskChainID, noteID: TaskNoteEntryID)

        func actionName(copy: AppCopy) -> String {
            switch self {
            case let .snapshot(_, undoEntry):
                undoEntry.actionName(copy: copy)
            case .traceNoteAppend, .poolNoteAppend:
                copy.addNoteAction
            case .traceNoteEdit, .poolNoteEdit:
                copy.editNoteMenuAction
            case .traceNoteDelete, .poolNoteDelete:
                copy.deleteNoteMenuAction
            }
        }
    }

    struct RedoReplay {
        let engine: NoonmarkEngine
        let undoEntry: UndoEntry
        let snapshotUndoOutcome: SnapshotUndoOutcome
    }

    struct ZhulongWorkflowRoute {
        let task: ZhulongTask
        let purpose: ZhulongSessionPurpose
    }

    static let zhulongWorkflowRoutes = [
        ZhulongWorkflowRoute(task: .dailyReview, purpose: .dailyClose),
        ZhulongWorkflowRoute(task: .taskDecomposition, purpose: .taskShaping),
        ZhulongWorkflowRoute(task: .scheduling, purpose: .schedulingAssistance),
        ZhulongWorkflowRoute(task: .classification, purpose: .classificationAssistance),
        ZhulongWorkflowRoute(task: .habitInsight, purpose: .habitInsight),
        ZhulongWorkflowRoute(task: .theoryAnalysis, purpose: .theoryAnalysis)
    ]

    enum TraceContextAction: String, Equatable {
        case markComplete
        case undoComplete
        case continueTo
        case changeToNewTask
        case returnToPool
        case reschedule
        case copyAsNewTask
        case abandonChain
    }

    enum Page: String, CaseIterable, Identifiable {
        case day
        case pool
        case future
        case unfinished
        case completed
        case calendar
        case zhulong
        case settings

        var id: String { rawValue }

        var navigationSystemImage: String {
            switch self {
            case .day:
                return "clock"
            case .pool:
                return "tray"
            case .future:
                return "calendar.badge.clock"
            case .unfinished:
                return "exclamationmark.circle"
            case .completed:
                return "checkmark.seal"
            case .calendar:
                return "calendar"
            case .zhulong:
                return "sparkles"
            case .settings:
                return "gearshape"
            }
        }

        var navigationIconColor: Color {
            switch self {
            case .day:
                return Theme.navDay
            case .pool:
                return Theme.navPool
            case .future:
                return Theme.navFuture
            case .unfinished:
                return Theme.navUnfinished
            case .completed:
                return Theme.navCompleted
            case .calendar:
                return Theme.navCalendar
            case .zhulong:
                return Theme.navZhulong
            case .settings:
                return Theme.navSettings
            }
        }

        var detailRailWidth: CGFloat {
            self == .calendar
                ? NoonmarkVisualMetrics.calendarRailWidth
                : NoonmarkVisualMetrics.detailRailWidth
        }

        init?(commandLineValue: String) {
            switch commandLineValue {
            case "day":
                self = .day
            case "pool":
                self = .pool
            case "future":
                self = .future
            case "unfinished":
                self = .unfinished
            case "completed":
                self = .completed
            case "calendar":
                self = .calendar
            case "zhulong":
                self = .zhulong
            case "settings":
                self = .settings
            default:
                return nil
            }
        }
    }

    enum DatePickerPurpose: Identifiable {
        case gotoDay
        case schedulePool(TaskChainID)
        case continueTrace(DayTraceID)
        case reschedule(DayTraceID)

        var id: String {
            switch self {
            case .gotoDay:
                "goto-day"
            case let .schedulePool(chainID):
                "schedule-pool-\(chainID.description)"
            case let .continueTrace(traceID):
                "continue-trace-\(traceID.description)"
            case let .reschedule(traceID):
                "reschedule-trace-\(traceID.description)"
            }
        }

        func title(copy: AppCopy) -> String {
            switch self {
            case .gotoDay:
                return copy.jumpToDateTitle
            case .schedulePool:
                return copy.scheduleDateTitle
            case .continueTrace:
                return copy.continueDateTitle
            case .reschedule:
                return copy.rescheduleDateTitle
            }
        }

        var allowsPastDates: Bool {
            if case .gotoDay = self { return true }
            return false
        }

        var futureOnly: Bool {
            if case .reschedule = self { return true }
            return false
        }

        func rangeHint(copy: AppCopy) -> String {
            switch self {
            case .gotoDay:
                return copy.anyDateHint
            case .schedulePool, .continueTrace:
                return copy.todayOrFutureDateHint
            case .reschedule:
                return copy.futureDateHint
            }
        }

        var hasRangeConstraint: Bool {
            allowsPastDates == false
        }

        @MainActor
        func minimumDate(today: LocalDate) -> LocalDate? {
            guard allowsPastDates == false else { return nil }
            return futureOnly
                ? NoonmarkStore.offset(today, by: 1)
                : today
        }

        @MainActor
        func allows(_ date: LocalDate, today: LocalDate) -> Bool {
            guard let minimumDate = minimumDate(today: today) else {
                return true
            }
            return date >= minimumDate
        }

        func confirmationTitle(copy: AppCopy) -> String {
            switch self {
            case .gotoDay:
                copy.jumpToDateAction
            case .schedulePool:
                copy.scheduleDateAction
            case .continueTrace:
                copy.continueDateAction
            case .reschedule:
                copy.rescheduleDateAction
            }
        }
    }

    @Published var engine = NoonmarkEngine() {
        didSet {
            engineRevision &+= 1
        }
    }

    @Published var page: Page = .day {
        didSet {
            if oldValue != page {
                clearSelection()
            }
        }
    }

    @Published var selectedDate: LocalDate {
        didSet {
            if oldValue != selectedDate, page == .day {
                clearSelection()
            }
        }
    }

    @Published var selectedCalendarDate: LocalDate
    @Published var selectedTraceID: DayTraceID?
    @Published var selectedPoolChainID: TaskChainID?
    @Published var selectedUnfinishedChainID: TaskChainID?
    @Published var selectedCompletedTraceID: DayTraceID?
    @Published var selectedCompletedSubtaskID: SubtaskID?
    @Published var workspaceSelection = WorkspaceSelection<WorkspaceSelectionItem>()
    @Published var expandedTraceIDs: Set<DayTraceID> = []
    @Published var expandedUnfinishedChainIDs: Set<TaskChainID> = []
    @Published var quickText = ""
    @Published var poolText = ""
    @Published var showingPicker: DatePickerPurpose?
    @Published var showingFromPoolPicker = false
    @Published var showingChangeDialog = false
    @Published var preparedDataImport: PreparedDataImport?
    @Published var showingClassificationManager = false
    @Published var isSidebarExpanded = MacUIShellLayout.sidebarExpandedByDefault
    @Published var isDetailRailExpanded = !MacUIShellLayout.detailRailCollapsedByDefault
    @Published var changeText = ""
    @Published var detailSubtaskText = ""
    @Published var detailNoteText = ""
    @Published var toast: String?
    @Published var operationFailureNotice: AppOperationFailureNotice?
    @Published var automaticClassificationStatusByChainID: [
        TaskChainID: AutomaticClassificationPresentationStatus
    ] = [:]
    @Published var automaticClassificationBacklogPrompt:
        AutomaticClassificationBacklogPrompt?
    @Published var automaticClassificationCircuitPresentation:
        AutomaticClassificationCircuitPresentation?
    @Published var zhulongProviderDraft = ZhulongProviderSettingsStore.load()
    @Published var reviewAutosaveMessage: String?
    @Published var isLocalFirstSyncing = false
    @Published var localFirstSyncMessage: String?
    @Published var cloudKitAccountAvailability: CloudKitAccountAvailability?
    @Published var today: LocalDate
    @Published var naturalDayState: NaturalDayState
    @Published var dayBoundaryState: DayBoundaryState

    var operationFailure: String? {
        operationFailureNotice?.message
    }

    let dayContext: NaturalDayContext
    let dayRolloverCoordinator = DayRolloverCoordinator()
    let dataRootProcessLease: NoonmarkDataRootProcessLease?
    let repository: SQLiteEngineRepository?
    let automaticClassificationJobRepository: SQLiteAutomaticClassificationJobRepository?
    let automaticClassificationOperationalClock: AutomaticClassificationOperationalClock
    let databaseURL: URL?
    let syncDeviceIdentity: SyncDeviceIdentity?
    let permitsPersistenceFailureE2E: Bool
    lazy var zhulongWorkspace = ZhulongWorkspaceStore(
        directoryURL: zhulongSidecarDirectoryURL,
        keySource: zhulongSidecarKeySource
    )
    let toastScheduler = LatestTransientMessageScheduler()
    var localFirstSyncAutomationTask: Task<Void, Never>?
    var automaticClassificationWorkerTask: Task<Void, Never>?
    var automaticClassificationWorkerRestartRequested = false
    var pendingAutomaticClassificationProviderReconciliation:
        AutomaticClassificationProviderExecution?
    var automaticClassificationProviderExecution:
        AutomaticClassificationProviderExecution = .unconfigured
    var automaticClassificationBacklogSnapshot:
        AutomaticClassificationBacklogSnapshot?
    var automaticClassificationBacklogDeferredForSession = false
    var automaticClassificationBacklogDecisionTask: Task<Void, Never>?
    var automaticClassificationCircuitRetryTask: Task<Void, Never>?
    var cloudKitAccountCheckTask: Task<Void, Never>?
    var naturalDayObservation: NaturalDayObservation?
    var accessibilityDisplayObservation: AnyCancellable?
    var retainedCloudKitSyncTransport: CloudKitSyncEngineTransport?
    var retainedCloudKitSyncLease: CloudKitSyncPersistenceLease?
    var undoStack: [UndoEntry] = []
    var redoStack: [RedoEntry] = []
    var engineRevision: UInt64 = 0
    var exclusiveEngineOperation: ExclusiveEngineOperation?
    var persistenceFailuresRemainingForE2E = 0
    var shouldPauseNextDataImportCommitForE2E = false
    var dataImportCommitContinuationForE2E: CheckedContinuation<Void, Never>?
    var isDataImportCommitPausedForE2E = false
    var pendingZhulongEngineWriteAuthorized = false

    init(
        dayContext: NaturalDayContext,
        automaticClassificationOperationalClock: AutomaticClassificationOperationalClock = .system
    ) throws {
        let initialMoment = try dayContext.moment()
        self.dayContext = dayContext
        self.automaticClassificationOperationalClock = automaticClassificationOperationalClock
        if let executionRevision = ZhulongProviderSettingsStore
            .persistedReadyExecutionRevision()
        {
            automaticClassificationProviderExecution = .configured(
                executionRevision: executionRevision
            )
        }
        _today = Published(initialValue: initialMoment.today)
        _naturalDayState = Published(initialValue: initialMoment.state)
        _selectedDate = Published(initialValue: initialMoment.today)
        _selectedCalendarDate = Published(initialValue: initialMoment.today)
        _dayBoundaryState = Published(
            initialValue: .reconciling(candidate: initialMoment.today)
        )
        permitsPersistenceFailureE2E = AppLaunchArguments.contains(
            "--e2e-persistence-failure-automation"
        )
            && AppLaunchArguments.value(after: "--data-url") != nil
            && Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e"
        if AppLaunchArguments.contains("--ephemeral") {
            dataRootProcessLease = nil
            repository = nil
            automaticClassificationJobRepository = nil
            databaseURL = nil
            syncDeviceIdentity = nil
            try seed()
        } else {
            let configuredDatabaseURL = Self.configuredDatabaseURL()
            dataRootProcessLease = try NoonmarkDataRootProcessLease.acquire(
                dataRootURL: configuredDatabaseURL.deletingLastPathComponent()
            )
            databaseURL = configuredDatabaseURL
            repository = SQLiteEngineRepository(databaseURL: configuredDatabaseURL)
            automaticClassificationJobRepository = SQLiteAutomaticClassificationJobRepository(
                databaseURL: configuredDatabaseURL
            )
            syncDeviceIdentity = Self.loadOrCreateSyncDeviceIdentity(
                databaseURL: configuredDatabaseURL
            )
            try loadOrSeed()
        }
        recoverPendingZhulongApplication()
        try reconcileNaturalDayAtLaunch(initialMoment)
        Theme.apply(engine.preferences.theme)
        restoreLocalFirstSyncStatus()
        restartLocalFirstSyncAutomation()
        restoreAutomaticClassificationWork()
        naturalDayObservation = dayContext.observe { [weak self] event in
            self?.handleNaturalDayEvent(event)
        }
        accessibilityDisplayObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
    }

    deinit {
        localFirstSyncAutomationTask?.cancel()
        automaticClassificationWorkerRestartRequested = false
        automaticClassificationWorkerTask?.cancel()
        automaticClassificationBacklogDecisionTask?.cancel()
        automaticClassificationCircuitRetryTask?.cancel()
        cloudKitAccountCheckTask?.cancel()
    }
}

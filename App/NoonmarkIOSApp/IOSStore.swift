import Combine
import Foundation
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import Security
import SwiftUI

private enum IOSSyncConfigurationError: LocalizedError {
    case endpointUnavailable(CloudSyncEndpointKind)

    var errorDescription: String? {
        switch self {
        case let .endpointUnavailable(endpoint):
            "iOS 当前不支持所选同步端点：\(endpoint.rawValue)。"
        }
    }
}

struct IOSDataPackagePickerRequest: Identifiable {
    let id = UUID()
    let mode: IOSDataPackagePickerMode
}

@MainActor
final class IOSStore: ObservableObject {
    enum Page: String, CaseIterable, Hashable, Identifiable {
        case day
        case pool
        case future
        case recurring
        case unfinished
        case completed
        case calendar
        case zhulong
        case stickyNotes
        case flylight
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .day: "今日"
            case .pool: "任务池"
            case .future: "未来计划"
            case .recurring: "重复计划"
            case .unfinished: "未完成"
            case .completed: "已完成"
            case .calendar: "日历"
            case .zhulong: "烛龙"
            case .stickyNotes: "Sticky Note"
            case .flylight: "飞光"
            case .settings: "设置"
            }
        }

        var symbol: String {
            switch self {
            case .day: "sun.max"
            case .pool: "tray"
            case .future: "calendar.badge.clock"
            case .recurring: "repeat"
            case .unfinished: "arrow.uturn.forward"
            case .completed: "checkmark.circle"
            case .calendar: "calendar"
            case .zhulong: "sparkles"
            case .stickyNotes: "pin"
            case .flylight: "wind"
            case .settings: "gearshape"
            }
        }
    }

    @Published var page: Page = .day
    @Published var selectedDate: LocalDate
    @Published private(set) var engine: NoonmarkEngine
    @Published var quickTaskText = ""
    @Published var poolTaskText = ""
    @Published var flylightDraft = ""
    @Published var selectedTraceID: DayTraceID?
    @Published var selectedPoolChainID: TaskChainID?
    @Published var selectedIdeaID: IdeaID?
    @Published var dataPackagePickerRequest: IOSDataPackagePickerRequest?
    @Published var dataPackageStatusMessage: String?
    @Published var isExportingDiagnostics = false
    @Published var diagnosticDocument: IOSDiagnosticDocument?
    @Published var syncMessage: String?
    @Published var isSyncing = false
    @Published var errorMessage: String?
    @Published private(set) var isWorkspaceReadOnly = false
    @Published private(set) var zhulongSessions: [ZhulongSession] = []
    @Published var selectedZhulongSessionID: ZhulongSessionID?
    @Published var zhulongIntent = ""
    @Published var zhulongTask: ZhulongTask = .habitInsight
    @Published var zhulongMessage = ""
    @Published var zhulongLiveResponse = ""
    @Published var zhulongProviderBaseURL = ""
    @Published var zhulongProviderModel = ""
    @Published var zhulongProviderAPIKey = ""
    @Published var zhulongMessageStatus: String?

    let databaseURL: URL
    private let repository: SQLiteEngineRepository
    private let zhulongSessionRepository: EncryptedFileZhulongSessionRepository
    private let zhulongApplicationJournal: EncryptedFileZhulongApplicationJournal
    private let zhulongProviderOrchestrator: ZhulongProviderOrchestrator
    private let zhulongSessionIDsKey = "noonmark.ios.zhulong.sessionIDs"
    private let zhulongProviderService = "app.noonmark.ios.development.zhulong.provider"
    private var diagnosticRecording: (any DiagnosticRecording)?
    private var localDiagnosticRecorder: LocalDiagnosticRecorder?
    private var metricKitSubscriber: MetricKitDiagnosticSubscriber?

    init(fileManager: FileManager = .default) {
        let today = Self.currentLocalDate(calendar: .current)
        selectedDate = today

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let dataRootParent = applicationSupport ?? fileManager.temporaryDirectory
        let dataRoot = dataRootParent.appendingPathComponent(
            "NoonmarkIOS",
            isDirectory: true
        )
        if applicationSupport == nil {
            isWorkspaceReadOnly = true
            errorMessage = "本地数据目录不可用，当前工作区只读。"
        } else {
            do {
                try fileManager.createDirectory(
                    at: dataRoot,
                    withIntermediateDirectories: true
                )
            } catch {
                isWorkspaceReadOnly = true
                errorMessage = "本地数据目录无法建立，当前工作区只读。"
            }
        }
        databaseURL = dataRoot.appendingPathComponent("noonmark.sqlite")
        repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let zhulongDirectory = dataRoot.appendingPathComponent(
            "ZhulongSidecar",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: zhulongDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            isWorkspaceReadOnly = true
            errorMessage = "烛龙本地加密目录无法建立，已阻断写入。"
        }
        let sidecarKeySource = KeychainZhulongSidecarKeySource(
            service: "app.noonmark.ios.development.zhulong.sidecar"
        )
        let sessionRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: zhulongDirectory,
            keySource: sidecarKeySource,
            fileManager: fileManager
        )
        zhulongSessionRepository = sessionRepository
        zhulongApplicationJournal = EncryptedFileZhulongApplicationJournal(
            directoryURL: zhulongDirectory,
            keySource: sidecarKeySource,
            fileManager: fileManager
        )
        zhulongProviderOrchestrator = ZhulongProviderOrchestrator(
            repository: sessionRepository
        )

        do {
            engine = try repository.load()
        } catch {
            engine = NoonmarkEngine()
            isWorkspaceReadOnly = true
            errorMessage = "本地数据无法读取，已阻断写入；请先修复本地存储。"
        }
        IOSTheme.apply(engine.preferences.theme)
        recoverPendingZhulongApplication()
        loadZhulongProviderSettings()
        reloadZhulongSessions()
    }

    var today: LocalDate {
        Self.currentLocalDate(calendar: .current)
    }

    var dayTodo: DayTodoView {
        engine.getDayTodo(date: selectedDate)
    }

    var poolTasks: [PoolTask] {
        engine.taskPool()
    }

    var futurePlans: [FuturePlanItem] {
        engine.futurePlans(today: today)
    }

    var unfinishedTasks: [UnfinishedPoolItem] {
        engine.unfinishedPool()
    }

    var completedHierarchies: [CompletedTaskHierarchy] {
        engine.completedTaskHierarchies()
    }

    var flylightEntries: [IdeaEntry] {
        engine.ideaTimeline()
    }

    var stickyEntries: [IdeaEntry] {
        engine.pinnedIdeas()
    }

    var dayReviewStats: DailyReviewStats {
        engine.dailyReviewStats(date: selectedDate)
    }

    var selectedDay: Day? {
        engine.days[selectedDate]
    }

    var taskCycleTracks: [TaskCycleTrack] {
        engine.taskCycleTracks(today: today)
    }

    var selectedTrace: DayTrace? {
        guard let selectedTraceID else { return nil }
        return engine.traces[selectedTraceID]
    }

    var selectedPoolTask: PoolTask? {
        guard let selectedPoolChainID else { return nil }
        return poolTasks.first { $0.chain.id == selectedPoolChainID }
    }

    var selectedIdea: IdeaEntry? {
        guard let selectedIdeaID else { return nil }
        return engine.ideas[selectedIdeaID]
    }

    var selectedZhulongSession: ZhulongSession? {
        guard let selectedZhulongSessionID else { return nil }
        return zhulongSessions.first { $0.id == selectedZhulongSessionID }
    }

    var isZhulongProviderConfigured: Bool {
        zhulongProviderIdentity != nil && loadZhulongAPIKey() != nil
    }

    func subtasks(for trace: DayTrace) -> [Subtask] {
        engine.subtasks.values
            .filter { $0.traceID == trace.id && $0.isUserPresentable }
            .sorted {
                if $0.position != $1.position {
                    return $0.position < $1.position
                }
                return $0.id.description < $1.id.description
            }
    }

    func addTaskToSelectedDay() {
        let draft = NewTaskDraftParser.parse(quickTaskText)
        guard draft.issue == nil, draft.title.isEmpty == false else {
            errorMessage = draft.issue == nil
                ? "任务标题不能为空。"
                : "只能设置一个主分类。"
            return
        }
        if commit({ candidate in
            let chainID = try candidate.createPoolTask(title: draft.title)
            _ = try candidate.scheduleFromPool(
                chainID: chainID,
                date: selectedDate,
                today: today
            )
            try applyTaskDraftClassification(
                to: candidate,
                chainID: chainID,
                categoryName: draft.categoryName,
                labelNames: draft.labelNames,
                now: Date()
            )
        }) {
            quickTaskText = ""
        }
    }

    func addTaskToPool() {
        let draft = NewTaskDraftParser.parse(poolTaskText)
        guard draft.issue == nil, draft.title.isEmpty == false else {
            errorMessage = draft.issue == nil
                ? "任务标题不能为空。"
                : "只能设置一个主分类。"
            return
        }
        if commit({ candidate in
            let chainID = try candidate.createPoolTask(title: draft.title)
            try applyTaskDraftClassification(
                to: candidate,
                chainID: chainID,
                categoryName: draft.categoryName,
                labelNames: draft.labelNames,
                now: Date()
            )
        }) {
            poolTaskText = ""
        }
    }

    func schedule(_ task: PoolTask, on date: LocalDate) {
        commit { candidate in
            _ = try candidate.scheduleFromPool(
                chainID: task.chain.id,
                date: date,
                today: today
            )
        }
    }

    func toggleCompletion(for trace: DayTrace) {
        commit { candidate in
            if trace.status == .completed {
                try candidate.undoCompleted(traceID: trace.id, today: today)
            } else {
                try candidate.markCompleted(traceID: trace.id, today: today)
            }
        }
    }

    func setTraceTitle(_ trace: DayTrace, title: String) {
        commit { candidate in
            try candidate.renameTaskTitle(
                chainID: trace.chainID,
                title: title,
                today: today
            )
        }
    }

    func setTraceDescription(_ trace: DayTrace, text: String) {
        commit { candidate in
            try candidate.updateTraceText(
                traceID: trace.id,
                descriptionText: text,
                today: today
            )
        }
    }

    func addSubtask(to trace: DayTrace, title: String, difficulty: SubtaskDifficulty = .simple) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            _ = try candidate.addSubtask(
                traceID: trace.id,
                title: trimmed,
                difficulty: difficulty
            )
        }
    }

    func toggleSubtask(_ subtask: Subtask) {
        commit { candidate in
            if subtask.status == .completed {
                try candidate.undoCompletedSubtask(subtask.id, today: today, now: Date())
            } else {
                try candidate.completeSubtask(subtask.id, today: today)
            }
        }
    }

    func deleteSubtask(_ subtask: Subtask) {
        commit { candidate in
            try candidate.deleteSubtask(subtask.id, today: today)
        }
    }

    func renameSubtask(_ subtask: Subtask, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            try candidate.updateSubtaskTitle(
                subtask.id,
                title: trimmed,
                today: today
            )
        }
    }

    func abandonSubtask(_ subtask: Subtask) {
        commit { candidate in
            try candidate.abandonSubtask(subtask.id, today: today)
        }
    }

    func setSubtaskDifficulty(
        _ subtask: Subtask,
        difficulty: SubtaskDifficulty
    ) {
        commit { candidate in
            try candidate.updateSubtaskDifficulty(
                subtask.id,
                difficulty: difficulty,
                today: today,
                now: Date()
            )
        }
    }

    func setManualProgress(for trace: DayTrace, percent: Int) {
        commit { candidate in
            try candidate.setManualProgress(
                traceID: trace.id,
                percent: percent,
                today: today
            )
        }
    }

    func pin(_ trace: DayTrace) {
        commit { candidate in
            try candidate.pinDayTrace(trace.id, today: today)
        }
    }

    func unpin(_ trace: DayTrace) {
        commit { candidate in
            try candidate.unpinDayTrace(trace.id, today: today)
        }
    }

    func movePriority(_ trace: DayTrace, by offset: Int) {
        let pending = dayTodo.traces
            .filter { $0.status == .pending }
            .sorted { $0.priority < $1.priority }
        guard let currentIndex = pending.firstIndex(where: { $0.id == trace.id }) else {
            return
        }
        let targetIndex = currentIndex + offset
        guard pending.indices.contains(targetIndex) else { return }
        commit { candidate in
            try candidate.updatePriority(
                traceID: trace.id,
                newPriority: pending[targetIndex].priority,
                today: today
            )
        }
    }

    func reschedule(_ trace: DayTrace, to date: LocalDate) {
        commit { candidate in
            try candidate.rescheduleFuturePlan(
                traceID: trace.id,
                targetDate: date,
                today: today
            )
        }
    }

    func withdrawDeferral(_ trace: DayTrace) {
        commit { candidate in
            try candidate.withdrawDeferral(sourceTraceID: trace.id, today: today)
        }
    }

    func copyAsNewTask(_ trace: DayTrace) {
        commit { candidate in
            _ = try candidate.copyAsNewTask(
                from: trace.id,
                target: .taskPool,
                today: today
            )
        }
    }

    func deleteNewCurrentDayTask(_ trace: DayTrace) {
        commit { candidate in
            try candidate.deleteNewCurrentDayTask(traceID: trace.id, today: today)
        }
    }

    func appendTraceNote(_ trace: DayTrace, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            _ = try candidate.appendTraceNote(
                traceID: trace.id,
                body: trimmed,
                today: today
            )
        }
    }

    func editTraceNote(_ trace: DayTrace, note: TaskNoteEntry, body: String) {
        commit { candidate in
            try candidate.editTraceNote(
                traceID: trace.id,
                noteID: note.id,
                body: body,
                today: today
            )
        }
    }

    func deleteTraceNote(_ trace: DayTrace, note: TaskNoteEntry) {
        commit { candidate in
            try candidate.deleteTraceNote(
                traceID: trace.id,
                noteID: note.id,
                today: today
            )
        }
    }

    func returnToPool(_ trace: DayTrace) {
        commit { candidate in
            try candidate.returnToPool(traceID: trace.id, today: today)
        }
    }

    func deferTrace(_ trace: DayTrace, to date: LocalDate) {
        commit { candidate in
            _ = try candidate.deferCurrentTrace(
                traceID: trace.id,
                targetDate: date,
                today: today
            )
        }
    }

    func continueTrace(_ trace: DayTrace, to date: LocalDate) {
        commit { candidate in
            _ = try candidate.continueUnfinishedTrace(
                traceID: trace.id,
                targetDate: date,
                today: today
            )
        }
    }

    func abandon(_ trace: DayTrace) {
        commit { candidate in
            try candidate.abandonChain(from: trace.id)
        }
    }

    func reactivate(_ trace: DayTrace) {
        commit { candidate in
            try candidate.reactivateAbandonedChain(
                from: trace.id,
                today: today
            )
        }
    }

    func addFlylight(
        categoryID: TaskCategoryID? = nil,
        labelIDs: [TaskLabelID] = []
    ) {
        let body = flylightDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return }
        commit { candidate in
            _ = try candidate.appendIdea(
                body: body,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        }
        flylightDraft = ""
    }

    func editFlylight(
        _ idea: IdeaEntry,
        body: String,
        categoryID: TaskCategoryID? = nil,
        labelIDs: [TaskLabelID] = []
    ) {
        commit { candidate in
            try candidate.editIdea(
                id: idea.id,
                body: body,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        }
    }

    func restoreFlylight(
        _ idea: IdeaEntry,
        body: String,
        categoryID: TaskCategoryID? = nil,
        labelIDs: [TaskLabelID] = []
    ) {
        commit { candidate in
            try candidate.restoreIdea(id: idea.id, body: body)
            try candidate.setIdeaClassification(
                id: idea.id,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        }
    }

    var deletedFlylightEntries: [IdeaEntry] {
        engine.ideaTrash()
    }

    func setFlylightClassification(
        _ idea: IdeaEntry,
        categoryID: TaskCategoryID?,
        labelIDs: [TaskLabelID]
    ) {
        commit { candidate in
            try candidate.setIdeaClassification(
                id: idea.id,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        }
    }

    var classificationCatalog: ClassificationCatalogProjection? {
        guard case let .catalog(projection) = try? engine.classification(.catalog) else {
            return nil
        }
        return projection
    }

    func taskClassification(for chainID: TaskChainID) -> TaskClassificationProjection? {
        guard case let .task(projection) = try? engine.classification(.task(chainID)) else {
            return nil
        }
        return projection
    }

    func taskCycleClassification(for seriesID: TaskCycleSeriesID) -> TaskClassificationProjection? {
        try? engine.taskCycleTemplateClassification(seriesID: seriesID)
    }

    func deleteFlylight(_ idea: IdeaEntry) {
        commit { candidate in
            try candidate.deleteIdea(id: idea.id)
        }
    }

    @discardableResult
    func applyClassification(_ intent: ClassificationIntent) -> Bool {
        let interactionID = UUID()
        return commit { candidate in
            let plan = try candidate.prepareClassification(
                intent,
                source: .userDirect,
                interactionID: interactionID,
                now: Date()
            )
            guard plan.blockers.isEmpty else {
                throw NoonmarkError.invalidTransition(
                    "这个分类仍被任务或历史引用；请先归档，或确认所有引用后再删除。"
                )
            }
            _ = try candidate.commitClassification(
                plan,
                confirmation: .confirmedByUser(
                    confirming: plan,
                    decisionID: interactionID
                ),
                now: Date()
            )
        }
    }

    func setTaskClassification(
        chainID: TaskChainID,
        categoryID: String?,
        labelIDs: Set<String>
    ) {
        let category = categoryID.flatMap(Self.taskCategoryChoice)
        let labels = labelIDs.compactMap(Self.taskLabelChoice)
        guard categoryID == nil || category != nil,
              labels.count == labelIDs.count
        else { return }
        applyClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            )
        )
    }

    func setTaskCycleClassification(
        seriesID: TaskCycleSeriesID,
        categoryID: String?,
        labelIDs: Set<String>
    ) {
        let category = categoryID.flatMap(Self.taskCategoryID)
        guard categoryID == nil || category != nil else { return }
        let labels = Set(labelIDs.compactMap(Self.taskLabelID))
        guard labels.count == labelIDs.count else { return }
        commit { candidate in
            try candidate.setTaskCycleTemplateClassification(
                seriesID: seriesID,
                categoryID: category,
                labelIDs: labels,
                source: .userDirect,
                interactionID: UUID(),
                now: Date()
            )
        }
    }

    func createCategory(name: String, colorHex: String) {
        applyClassification(.createCategory(name: name, colorHex: colorHex))
    }

    func createLabel(name: String, colorHex: String) {
        applyClassification(.createLabel(name: name, colorHex: colorHex))
    }

    func renameCategory(id: String, name: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.renameCategory(TaskCategoryID(rawID), to: name))
    }

    func renameLabel(id: String, name: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.renameLabel(TaskLabelID(rawID), to: name))
    }

    func archiveCategory(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.archiveCategory(TaskCategoryID(rawID)))
    }

    func restoreCategory(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.restoreCategory(TaskCategoryID(rawID)))
    }

    func archiveLabel(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.archiveLabel(TaskLabelID(rawID)))
    }

    func restoreLabel(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.restoreLabel(TaskLabelID(rawID)))
    }

    func approveCategoryPresentation(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.approveCategoryPresentation(TaskCategoryID(rawID)))
    }

    func deleteCategoryFromToday(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        commit { candidate in
            _ = try candidate.deleteTaskCategoryFromToday(
                TaskCategoryID(rawID),
                today: today,
                decisionID: UUID(),
                now: Date()
            )
        }
    }

    func hardDeleteCategory(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.hardDeleteCategory(TaskCategoryID(rawID)))
    }

    func hardDeleteLabel(id: String) {
        guard let rawID = UUID(uuidString: id) else { return }
        applyClassification(.hardDeleteLabel(TaskLabelID(rawID)))
    }

    func classificationMergeImpact(
        sourceID: String,
        targetID: String,
        isCategory: Bool
    ) -> ClassificationMergeImpact? {
        guard let sourceUUID = UUID(uuidString: sourceID),
              let targetUUID = UUID(uuidString: targetID)
        else { return nil }
        let intent: ClassificationIntent = if isCategory {
            .mergeCategory(
                source: TaskCategoryID(sourceUUID),
                into: TaskCategoryID(targetUUID)
            )
        } else {
            .mergeLabel(
                source: TaskLabelID(sourceUUID),
                into: TaskLabelID(targetUUID)
            )
        }
        guard let plan = try? engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(),
            now: Date()
        ) else { return nil }
        for change in plan.changes {
            if case let .merge(_, _, _, _, _, _, impact) = change {
                return impact
            }
        }
        return nil
    }

    func mergeClassification(
        sourceID: String,
        targetID: String,
        isCategory: Bool
    ) {
        guard let sourceUUID = UUID(uuidString: sourceID),
              let targetUUID = UUID(uuidString: targetID)
        else { return }
        if isCategory {
            applyClassification(
                .mergeCategory(
                    source: TaskCategoryID(sourceUUID),
                    into: TaskCategoryID(targetUUID)
                )
            )
        } else {
            applyClassification(
                .mergeLabel(
                    source: TaskLabelID(sourceUUID),
                    into: TaskLabelID(targetUUID)
                )
            )
        }
    }

    func toggleSticky(_ idea: IdeaEntry) {
        commit { candidate in
            if idea.pinnedAt == nil {
                try candidate.pinIdea(id: idea.id)
            } else {
                try candidate.unpinIdea(id: idea.id)
            }
        }
    }

    func addPoolTaskDescription(_ task: PoolTask, description: String) {
        commit { candidate in
            try candidate.updatePoolTask(
                chainID: task.chain.id,
                title: task.definition.title,
                descriptionText: description
            )
        }
    }

    func setPoolTask(_ task: PoolTask, title: String, description: String) {
        commit { candidate in
            try candidate.updatePoolTask(
                chainID: task.chain.id,
                title: title,
                descriptionText: description
            )
        }
    }

    func appendPoolNote(_ task: PoolTask, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            _ = try candidate.appendPoolNote(chainID: task.chain.id, body: trimmed)
        }
    }

    func editPoolNote(_ task: PoolTask, note: TaskNoteEntry, body: String) {
        commit { candidate in
            try candidate.editPoolNote(
                chainID: task.chain.id,
                noteID: note.id,
                body: body
            )
        }
    }

    func deletePoolNote(_ task: PoolTask, note: TaskNoteEntry) {
        commit { candidate in
            try candidate.deletePoolNote(
                chainID: task.chain.id,
                noteID: note.id
            )
        }
    }

    func addPlannedSubtask(to task: PoolTask, title: String, difficulty: SubtaskDifficulty = .simple) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            _ = try candidate.addPlannedSubtask(
                chainID: task.chain.id,
                title: trimmed,
                difficulty: difficulty
            )
        }
    }

    func renamePlannedSubtask(
        _ subtask: PlannedSubtask,
        on task: PoolTask,
        title: String
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        commit { candidate in
            try candidate.updatePlannedSubtaskTitle(
                chainID: task.chain.id,
                plannedSubtaskID: subtask.id,
                title: trimmed
            )
        }
    }

    func deletePlannedSubtask(_ subtask: PlannedSubtask, from task: PoolTask) {
        commit { candidate in
            try candidate.removePlannedSubtask(
                chainID: task.chain.id,
                plannedSubtaskID: subtask.id
            )
        }
    }

    func setPlannedSubtaskDifficulty(
        _ subtask: PlannedSubtask,
        on task: PoolTask,
        difficulty: SubtaskDifficulty
    ) {
        commit { candidate in
            try candidate.updatePlannedSubtaskDifficulty(
                chainID: task.chain.id,
                plannedSubtaskID: subtask.id,
                difficulty: difficulty
            )
        }
    }

    func deletePoolTask(_ task: PoolTask) {
        commit { candidate in
            _ = try candidate.deleteUnscheduledTask(chainID: task.chain.id)
        }
    }

    func updateDailyReview(summary: String, unfinishedReason: String, tomorrowNote: String) {
        commit { candidate in
            candidate.updateDailyReview(
                date: selectedDate,
                summary: summary,
                unfinishedReason: unfinishedReason,
                tomorrowNote: tomorrowNote
            )
        }
    }

    func createTaskCycle(
        title: String,
        description: String,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        endCondition: TaskCycleEndCondition? = nil,
        plannedSubtasks: [PlannedSubtask] = []
    ) {
        commit { candidate in
            _ = try candidate.createTaskCycleSeries(
                title: title,
                descriptionText: description.isEmpty ? nil : description,
                plannedSubtasks: plannedSubtasks,
                startDate: startDate,
                schedule: schedule,
                endCondition: endCondition ?? .onDate(endDate),
                today: today
            )
        }
    }

    func updateTaskCycleContent(
        seriesID: TaskCycleSeriesID,
        title: String,
        description: String,
        plannedSubtasks: [PlannedSubtask]
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else { return }
        commit { candidate in
            try candidate.updateTaskCycleTemplateContent(
                seriesID: seriesID,
                title: normalizedTitle,
                descriptionText: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
                plannedSubtasks: plannedSubtasks,
                today: today,
                now: Date()
            )
        }
    }

    func reviseTaskCycle(
        _ track: TaskCycleTrack,
        startDate: LocalDate? = nil,
        endDate: LocalDate,
        schedule: TaskCycleSchedule,
        endCondition: TaskCycleEndCondition? = nil
    ) {
        commit { candidate in
            _ = try candidate.reviseTaskCycleSeries(
                seriesID: track.id,
                startDate: startDate,
                schedule: schedule,
                endCondition: endCondition ?? .onDate(endDate),
                today: today
            )
        }
    }

    func skipTaskCycleOccurrence(_ track: TaskCycleTrack, on date: LocalDate) {
        commit { candidate in
            try candidate.skipTaskCycleOccurrence(
                seriesID: track.id,
                occurrenceDate: date,
                today: today
            )
        }
    }

    func stopTaskCycle(_ track: TaskCycleTrack) {
        commit { candidate in
            _ = try candidate.stopTaskCycleSeries(
                seriesID: track.id,
                today: today
            )
        }
    }

    func setTheme(_ theme: AppTheme) {
        if commit({ candidate in
            try candidate.updateTheme(theme, now: Date())
        }) {
            IOSTheme.apply(theme)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        commit { candidate in
            try candidate.updateLanguage(language, now: Date())
        }
    }

    func setDataMode(_ mode: AppDataMode) {
        commit { candidate in candidate.updateDataMode(mode) }
    }

    func setBackupPolicy(_ policy: ScheduledBackupPolicy) {
        commit { candidate in candidate.updateBackupPolicy(policy) }
    }

    func setSyncPolicy(_ policy: LocalFirstCloudSyncPolicy) {
        commit { candidate in candidate.updateLocalFirstSyncPolicy(policy) }
    }

    func setPoemPolicy(_ policy: SettingsPoemDisplayPolicy) {
        commit { candidate in candidate.updateSettingsPoemDisplayPolicy(policy) }
    }

    func exportDataPackage() {
        do {
            let cacheDirectory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("NoonmarkDataPackageExports", isDirectory: true)
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let exportURL = cacheDirectory.appendingPathComponent(
                "Noonmark-data-\(UUID().uuidString).json"
            )
            _ = try NoonmarkDataPackage.write(engine.snapshot(), to: exportURL)
            dataPackageStatusMessage = nil
            dataPackagePickerRequest = IOSDataPackagePickerRequest(
                mode: .exporting(exportURL)
            )
            errorMessage = nil
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func beginDataPackageImport() {
        dataPackagePickerRequest = IOSDataPackagePickerRequest(mode: .importing)
        errorMessage = nil
    }

    func startDiagnostics() async {
        guard diagnosticRecording == nil else { return }
        let rootURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Diagnostics", isDirectory: true)
        let bootstrap = await DiagnosticRecordingBootstrap.prepare(
            rootURL: rootURL,
            configuration: .production
        )
        diagnosticRecording = bootstrap.recorder
        localDiagnosticRecorder = bootstrap.localRecorder
        bootstrap.recorder.record(.sessionStarted())
        if let local = bootstrap.localRecorder {
            let subscriber = MetricKitDiagnosticSubscriber(recorder: local)
            subscriber.start()
            metricKitSubscriber = subscriber
        }
    }

    func exportDiagnostics() {
        guard let local = localDiagnosticRecorder else {
            errorMessage = "诊断记录当前不可导出；本地有界存储未成功建立。"
            return
        }
        Task { @MainActor [weak self] in
            do {
                let package = try await local.snapshotPackage()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                self?.diagnosticDocument = try IOSDiagnosticDocument(
                    data: encoder.encode(package)
                )
                self?.isExportingDiagnostics = true
            } catch {
                self?.errorMessage = Self.userFacingError(error)
            }
        }
    }

    func flushDiagnostics() async {
        await localDiagnosticRecorder?.flush()
    }

    func importDataPackage(from url: URL) {
        guard isSyncing == false else {
            errorMessage = "同步进行中，暂不能导入数据包。"
            return
        }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            var snapshot = try NoonmarkDataPackage.read(from: url)
            try snapshot.validateIntegrity()
            var importedSyncPolicy = snapshot.preferences.localFirstSyncPolicy
            importedSyncPolicy.enabled = false
            snapshot.preferences.localFirstSyncPolicy = importedSyncPolicy
            let deviceIdentity = try SQLiteSyncRepository(
                databaseURL: databaseURL
            ).loadDeviceIdentity()
            try repository.replaceForDataImport(
                snapshot,
                preserving: deviceIdentity
            )
            engine = try NoonmarkEngine(snapshot: snapshot)
            IOSTheme.apply(engine.preferences.theme)
            dataPackageStatusMessage = Self.dataPackageSummary(snapshot)
            errorMessage = nil
        } catch {
            dataPackageStatusMessage = nil
            errorMessage = Self.userFacingError(error)
        }
    }

    func handleDataPackageExportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success:
            dataPackageStatusMessage = "数据包已导出。"
            errorMessage = nil
        case let .failure(error) where Self.isDocumentPickerCancellation(error):
            break
        case let .failure(error):
            errorMessage = Self.userFacingError(error)
        }
    }

    func handleDataPackagePickerError(_ error: Error) {
        guard Self.isDocumentPickerCancellation(error) == false else { return }
        errorMessage = Self.userFacingError(error)
    }

    func finishDataPackagePicker() {
        if case let .exporting(url)? = dataPackagePickerRequest?.mode {
            try? FileManager.default.removeItem(at: url)
        }
        dataPackagePickerRequest = nil
    }

    private static func dataPackageSummary(_ snapshot: NoonmarkSnapshot) -> String {
        "已导入数据包：\(snapshot.days.count) 个日期、\(snapshot.chains.count) 条任务链、\(snapshot.traces.count) 条轨迹、\(snapshot.ideas.count) 条飞光。"
    }

    private static func isDocumentPickerCancellation(_ error: Error) -> Bool {
        error is IOSDocumentPickerError
    }

    func requestSync() {
        guard isSyncing == false else { return }
        guard isWorkspaceReadOnly == false else {
            syncMessage = "同步未执行：本地工作区只读。"
            return
        }
        let syncPolicy = engine.preferences.localFirstSyncPolicy
        guard syncPolicy.enabled else {
            syncMessage = "同步未启用；请先明确打开本地优先同步。"
            return
        }
        isSyncing = true
        syncMessage = "正在验证 iCloud 账户与同步边界……"
        let config = try? CloudKitSyncLaunchConfiguration.resolve(arguments: CommandLine.arguments)
        let currentDatabaseURL = self.databaseURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let producerEpochID = try SQLiteSyncRepository(
                    databaseURL: currentDatabaseURL
                ).loadOrCreateTransportProducerEpochID()
                let transport: any SyncRecordTransport
                if let config, syncPolicy.endpoint == .iCloud {
                    _ = try CloudKitEntitlementProbe.validateCurrentProcess(
                        containerIdentifier: config.containerIdentifier
                    )
                    let lease = CloudKitSyncPersistenceLease()
                    transport = try CloudKitSyncEngineTransport(
                        containerIdentifier: config.containerIdentifier,
                        persistence: SQLiteCloudKitSyncPersistence(
                            databaseURL: currentDatabaseURL,
                            lease: lease
                        ),
                        zoneName: config.zoneName
                    )
                } else if syncPolicy.endpoint == .iCloud {
                    transport = try ICloudDriveSyncTransport(
                        repositoryName: "Noonmark-iOS-Development/SyncRepository",
                        producerEpochID: producerEpochID
                    )
                } else {
                    throw IOSSyncConfigurationError.endpointUnavailable(
                        syncPolicy.endpoint
                    )
                }
                let result = try await SQLiteLocalFirstSyncCoordinator(
                    databaseURL: currentDatabaseURL,
                    transport: transport
                ).sync()
                self.syncMessage = "同步完成：上传 \(result.upload.uploadedCount)，下载 \(result.download.appliedCount)。"
            } catch {
                self.syncMessage = Self.syncFailureMessage(error)
            }
            self.isSyncing = false
        }
    }

    func createZhulongSession() {
        let intent = zhulongIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard intent.isEmpty == false else { return }
        do {
            let session = try ZhulongSession(
                primaryIntent: intent,
                purpose: zhulongPurpose(for: zhulongTask),
                proposedScopes: zhulongScopes(for: zhulongTask)
            )
            try zhulongSessionRepository.save(session)
            persistZhulongSessionID(session.id)
            zhulongSessions.insert(session, at: 0)
            selectedZhulongSessionID = session.id
            zhulongIntent = ""
            zhulongMessageStatus = "会话已建立，发送前请先完成范围授权。"
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func authorizeZhulongSession() {
        guard let session = selectedZhulongSession,
              let identity = zhulongProviderIdentity
        else {
            zhulongMessageStatus = "请先在烛龙页填写有效的 Provider 配置。"
            return
        }
        updateZhulongSession(session.id) { candidate in
            try candidate.authorizeScope(
                candidate.proposedScopes,
                providerIdentity: identity
            )
        }
        zhulongMessageStatus = "范围已授权：仅限当前日 Todo。"
    }

    func publishZhulongPlanningBrief(
        goal: String,
        successCriteria: [String],
        hardConstraints: [String],
        delegatedActivities: Set<ZhulongPlanningActivity>
    ) {
        guard let session = selectedZhulongSession else { return }
        do {
            let sourceEntryIDs = Set(
                session.entries
                    .filter { $0.correctsEntryID == nil }
                    .map(\.id)
            )
            let draft = try ZhulongPlanningBriefDraft(
                goal: goal,
                successCriteria: successCriteria,
                hardConstraints: hardConstraints,
                userDecisions: [],
                delegatedActivities: delegatedActivities,
                assumptions: [],
                openQuestions: [],
                dataScopes: session.proposedScopes,
                sourceEntryIDs: sourceEntryIDs
            )
            updateZhulongSession(session.id) { candidate in
                _ = try candidate.publishPlanningBrief(draft)
            }
            zhulongMessageStatus = "规划简报已发布，请先审查后再建立一次性委托。"
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func reviewZhulongPlanningBrief() {
        guard let session = selectedZhulongSession,
              let brief = session.currentPlanningBrief
        else { return }
        updateZhulongSession(session.id) { candidate in
            try candidate.reviewPlanningBrief(brief.id)
        }
        zhulongMessageStatus = "规划简报已审查。"
    }

    func delegateZhulongPlanningBrief() {
        guard let session = selectedZhulongSession,
              let brief = session.currentPlanningBrief
        else { return }
        updateZhulongSession(session.id) { candidate in
            _ = try candidate.delegatePlanning(for: brief.id)
        }
        zhulongMessageStatus = "一次性规划委托已建立，不包含 Todo 写入权限。"
    }

    func runZhulongPlanning() {
        guard let session = selectedZhulongSession,
              let delegation = session.activePlanningDelegation,
              let provider = makeZhulongProvider()
        else {
            zhulongMessageStatus = "请先完成 Provider 配置、范围授权、简报审查和一次性委托。"
            return
        }
        do {
            let payload = try makeZhulongPlanningPayload(for: session)
            let sessionID = session.id
            let delegationID = delegation.id
            zhulongMessageStatus = "烛龙正在执行一次性规划委托……"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.zhulongProviderOrchestrator.runPlanning(
                        sessionID: sessionID,
                        delegationID: delegationID,
                        payload: payload,
                        provider: provider
                    )
                    self.replaceZhulongSession(result)
                    self.zhulongMessageStatus = "规划产物已返回，请审阅结构化结果。"
                } catch {
                    self.zhulongMessageStatus = "规划委托失败，原始会话仍已保存。"
                    self.errorMessage = Self.userFacingError(error)
                }
            }
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func resolveZhulongDecisionGate(optionID: String) {
        guard let session = selectedZhulongSession,
              let gate = session.currentDecisionGate
        else { return }
        updateZhulongSession(session.id) { candidate in
            _ = try candidate.resolveDecisionGate(
                gate.id,
                selectedOptionID: optionID
            )
        }
        zhulongMessageStatus = "决策门已记录；请把决定纳入新的规划简报后再继续。"
    }

    func incorporateZhulongDecisionGateResolution() {
        guard let session = selectedZhulongSession,
              let brief = session.currentPlanningBrief,
              let resolution = session.latestDecisionGateResolutionRequiringBriefRevision,
              let decision = session.entries.first(where: { $0.id == resolution.decisionEntryID })?.content
        else { return }
        updateZhulongSession(session.id) { candidate in
            var sourceEntryIDs = brief.sourceEntryIDs
            sourceEntryIDs.insert(resolution.decisionEntryID)
            var userDecisions = brief.userDecisions
            if userDecisions.contains(decision) == false {
                userDecisions.append(decision)
            }
            let revision = try ZhulongPlanningBriefDraft(
                goal: brief.goal,
                successCriteria: brief.successCriteria,
                hardConstraints: brief.hardConstraints,
                userDecisions: userDecisions,
                delegatedActivities: brief.delegatedActivities,
                assumptions: brief.assumptions,
                openQuestions: brief.openQuestions,
                dataScopes: brief.dataScopes,
                sourceEntryIDs: sourceEntryIDs
            )
            _ = try candidate.publishPlanningBrief(revision)
        }
        zhulongMessageStatus = "已发布包含用户决定的规划简报修订。"
    }

    func appendZhulongMessageAndRun() {
        let message = zhulongMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false,
              let session = selectedZhulongSession
        else { return }
        guard let identity = zhulongProviderIdentity,
              let provider = makeZhulongProvider()
        else {
            zhulongMessageStatus = "Provider 未配置或 API Key 不可用，已阻断发送。"
            return
        }
        guard session.authorization?.providerIdentity.dataRecipient == identity.dataRecipient else {
            zhulongMessageStatus = "当前会话尚未授权这个 Provider；请先重新授权范围。"
            return
        }

        do {
            var candidate = session
            try candidate.appendEntry(
                author: .user,
                kind: .statement,
                content: message
            )
            try zhulongSessionRepository.save(candidate, replacing: session)
            replaceZhulongSession(candidate)
            zhulongMessage = ""
            zhulongLiveResponse = ""
            zhulongMessageStatus = "烛龙正在响应……"
            let payload = try makeZhulongPayload(for: candidate, message: message)
            let sessionID = candidate.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.zhulongProviderOrchestrator.runStreaming(
                        sessionID: sessionID,
                        payload: payload,
                        provider: provider,
                        onDelta: { [weak self] delta in
                            await MainActor.run {
                                self?.zhulongLiveResponse += delta
                            }
                        }
                    )
                    self.replaceZhulongSession(result)
                    self.materializeZhulongArtifacts(for: result)
                    self.zhulongMessageStatus = "响应已保存，可继续审阅。"
                } catch {
                    self.zhulongMessageStatus = "Provider 响应失败，原始会话仍已保存。"
                    self.errorMessage = Self.userFacingError(error)
                }
            }
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func saveZhulongProvider() {
        guard let baseURL = URL(string: zhulongProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme != nil,
              zhulongProviderModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            zhulongMessageStatus = "Provider 地址和 model 必须有效。"
            return
        }
        do {
            let key = zhulongProviderAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty == false {
                try saveZhulongAPIKey(key)
            }
            UserDefaults.standard.set(baseURL.absoluteString, forKey: "noonmark.ios.zhulong.baseURL")
            UserDefaults.standard.set(zhulongProviderModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "noonmark.ios.zhulong.model")
            zhulongProviderAPIKey = ""
            zhulongMessageStatus = loadZhulongAPIKey() == nil
                ? "Provider 设置已保存，但 API Key 缺失。"
                : "Provider 设置已保存。"
        } catch {
            zhulongMessageStatus = "Provider 凭证保存失败，未启用远端请求。"
            errorMessage = Self.userFacingError(error)
        }
    }

    private var zhulongProviderIdentity: ZhulongProviderConfigurationIdentity? {
        guard let url = URL(string: zhulongProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil,
              zhulongProviderModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        return try? ZhulongProviderConfigurationIdentity(
            providerID: "ios-provider",
            kind: .openAICompatible,
            baseURL: url,
            location: .remote,
            model: zhulongProviderModel.trimmingCharacters(in: .whitespacesAndNewlines),
            dataCapabilities: [.structuredOutput, .taskContext, .sessionSummary]
        )
    }

    private func makeZhulongProvider() -> ZhulongAIProviderAdapter? {
        guard let identity = zhulongProviderIdentity,
              let apiKey = loadZhulongAPIKey()
        else { return nil }
        let config = AIProviderConfig(
            providerID: AIProviderID(identity.providerID),
            displayName: "iOS Provider",
            kind: .openAICompatible,
            baseURL: identity.baseURL,
            model: identity.model,
            apiKeyRef: "ios-provider-api-key",
            enabled: true,
            capabilities: AIProviderCapabilities(supportsStreaming: true)
        )
        let upstream = OpenAICompatibleProvider(
            config: config,
            apiKeyResolver: { _ in apiKey }
        )
        return ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: upstream
        )
    }

    private func makeZhulongPayload(
        for session: ZhulongSession,
        message: String
    ) throws -> ZhulongProviderPayload {
        let scopeContent = Dictionary(
            uniqueKeysWithValues: session.proposedScopes.map { scope in
                (scope, zhulongScopeText(scope))
            }
        )
        let transcript = session.entries.map { entry in
            "\(entry.author.rawValue)：\(entry.content)"
        }.joined(separator: "\n")
        let responseContract: ZhulongProviderResponseContract = if session.purpose == .taskPoolAnalysis {
            .taskPoolAnalysis(evidence: try poolTasks.map { task in
                try ZhulongTaskPoolAnalysisEvidence(
                    taskID: task.chain.id.description,
                    title: task.definition.title.isEmpty ? nil : task.definition.title
                )
            })
        } else {
            .generalConversation
        }
        return try ZhulongProviderPayload(
            systemPrompt: "你是晷迹 iOS 中的烛龙。只能使用会话列出的已授权范围；清楚区分事实、推断和建议，不要声称已经写入 Todo。",
            userPrompt: "会话记录：\n\(transcript)\n\n用户最后消息：\n\(message)",
            contextVersion: "ios-\(engine.mutationEpoch)-\(session.events.count)",
            scopeContent: scopeContent,
            responseContract: responseContract
        )
    }

    private func makeZhulongPlanningPayload(
        for session: ZhulongSession
    ) throws -> ZhulongProviderPayload {
        guard let brief = session.currentPlanningBrief,
              let delegation = session.activePlanningDelegation
        else {
            throw ZhulongPlanningBriefError.briefNotCurrent
        }
        let scopeContent = Dictionary(
            uniqueKeysWithValues: delegation.dataScopes.map { scope in
                (scope, zhulongScopeText(scope))
            }
        )
        let briefText = """
        规划简报 v\(brief.version)
        目标：\(brief.goal)
        成功标准：\(brief.successCriteria.joined(separator: "；"))
        硬约束：\(brief.hardConstraints.joined(separator: "；"))
        授权活动：\(brief.delegatedActivities.map(\.rawValue).sorted().joined(separator: "、"))
        """
        return try ZhulongProviderPayload(
            systemPrompt: """
            你是晷迹 iOS 中的烛龙，正在执行用户对当前规划简报授予的一次性规划委托。
            只能使用授权数据，不得声称已经写入 Todo，不得改写历史事实。
            只返回一个符合 planning-output.v1 的 JSON 对象，不要 Markdown。
            缺少关键决定时返回 decisionGate，否则返回 planArtifact。
            """,
            userPrompt: briefText,
            contextVersion: "ios-planning-\(engine.mutationEpoch)-\(session.events.count)",
            scopeContent: scopeContent,
            responseContract: .generalConversation
        )
    }

    var selectedZhulongTodoDiff: ZhulongTodoDiffDraft? {
        selectedZhulongSession?.currentTodoDiff
    }

    var selectedZhulongDailyReviewDraft: ZhulongDailyReviewDraft? {
        guard let session = selectedZhulongSession,
              let draft = session.dailyReviewDrafts.last,
              session.dailyReviewReceipts.contains(where: { $0.draftID == draft.id }) == false
        else { return nil }
        return draft
    }

    var selectedZhulongTaskPoolAnalysis: ZhulongTaskPoolAnalysisReport? {
        guard let response = selectedZhulongSession?.providerSends.reversed().compactMap(\.response).first
        else { return nil }
        return response.artifacts.compactMap { artifact -> ZhulongTaskPoolAnalysisReport? in
            guard case let .taskPoolAnalysis(report) = artifact else { return nil }
            return report
        }.last
    }

    var selectedZhulongPlanningBrief: ZhulongPlanningBrief? {
        selectedZhulongSession?.currentPlanningBrief
    }

    var selectedZhulongPlanArtifact: ZhulongPlanArtifact? {
        selectedZhulongSession?.effectivePlanArtifact
    }

    var selectedZhulongDecisionGate: ZhulongDecisionGate? {
        selectedZhulongSession?.currentDecisionGate
    }

    var selectedZhulongTodoDiffHasAuthorization: Bool {
        guard let draft = selectedZhulongTodoDiff else { return false }
        return selectedZhulongSession?.todoWriteAuthorizations.contains {
            $0.draftID == draft.id && $0.status == .active
        } == true
    }

    var selectedZhulongDailyReviewHasAuthorization: Bool {
        guard let draft = selectedZhulongDailyReviewDraft else { return false }
        return selectedZhulongSession?.dailyReviewAuthorizations.contains {
            $0.draftID == draft.id && $0.status == .active
        } == true
    }

    func authorizeZhulongTodoDiff() {
        guard let session = selectedZhulongSession else { return }
        updateZhulongSession(session.id) { candidate in
            _ = try candidate.authorizeTodoWrite(against: engine, today: today)
        }
    }

    func applyZhulongTodoDiff() {
        guard canMutateWorkspace(), let existing = selectedZhulongSession else { return }
        let beforeSnapshot = engine.snapshot()
        var candidateEngine = NoonmarkEngine(copying: engine)
        var candidateSession = existing
        do {
            let timeline = try ZhulongApplicationMutationTimeline(
                reference: Date(),
                engine: engine,
                selectedSession: existing,
                pendingApplication: nil,
                requiresAuthorization: false
            )
            let receipt = try candidateSession.applyAuthorizedTodoDiff(
                to: &candidateEngine,
                today: today,
                now: timeline.applyAt
            )
            let pending = try ZhulongPendingApplication(
                kind: .todoDiff(receipt.draftID),
                sessionID: existing.id,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: candidateEngine.snapshot(),
                beforeSession: existing,
                afterSession: candidateSession,
                createdAt: timeline.applyAt
            )
            let prepareJournal = try zhulongApplicationJournal.save(pending)
            let outcome = finishZhulongApplication(
                pending: pending,
                prepareJournal: prepareJournal,
                beforeSnapshot: beforeSnapshot,
                afterEngine: candidateEngine
            )
            if outcome.durableEngineIsAfter {
                engine = candidateEngine
                replaceZhulongSession(candidateSession)
            }
            guard outcome.commitCompleted else {
                errorMessage = "Todo 变更未完成原子保存，待恢复事务已保留。"
                return
            }
            zhulongMessageStatus = "Todo 变更已确认并保存。"
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    func authorizeZhulongDailyReview() {
        guard let session = selectedZhulongSession,
              let draft = selectedZhulongDailyReviewDraft
        else { return }
        updateZhulongSession(session.id) { candidate in
            _ = try candidate.authorizeDailyReview(
                draft.id,
                against: engine,
                now: Date()
            )
        }
    }

    func applyZhulongDailyReview() {
        guard canMutateWorkspace(), let existing = selectedZhulongSession,
              let draft = selectedZhulongDailyReviewDraft,
              existing.dailyCloseSnapshots.contains(where: { $0.id == draft.dailyCloseID })
        else { return }
        let beforeSnapshot = engine.snapshot()
        var candidateEngine = NoonmarkEngine(copying: engine)
        var candidateSession = existing
        do {
            let timeline = try ZhulongApplicationMutationTimeline(
                reference: Date(),
                engine: engine,
                selectedSession: existing,
                pendingApplication: nil,
                requiresAuthorization: false
            )
            let receipt = try candidateSession.applyAuthorizedDailyReview(
                draft.id,
                to: &candidateEngine,
                now: timeline.applyAt
            )
            let pending = try ZhulongPendingApplication(
                kind: .dailyReview(receipt.draftID),
                sessionID: existing.id,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: candidateEngine.snapshot(),
                beforeSession: existing,
                afterSession: candidateSession,
                createdAt: timeline.applyAt
            )
            let prepareJournal = try zhulongApplicationJournal.save(pending)
            let outcome = finishZhulongApplication(
                pending: pending,
                prepareJournal: prepareJournal,
                beforeSnapshot: beforeSnapshot,
                afterEngine: candidateEngine
            )
            if outcome.durableEngineIsAfter {
                engine = candidateEngine
                replaceZhulongSession(candidateSession)
            }
            guard outcome.commitCompleted else {
                errorMessage = "每日复盘未完成原子保存，待恢复事务已保留。"
                return
            }
            zhulongMessageStatus = "每日复盘已确认并保存。"
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    private func materializeZhulongArtifacts(for session: ZhulongSession) {
        guard session.phase == .draftReview,
              let send = session.providerSends.reversed().first(where: { $0.response != nil }),
              let response = send.response
        else { return }
        let runID = send.runID
        do {
            var replacement = session
            let now = Date()
            if let plan = response.artifacts.compactMap({ artifact -> ZhulongConversationTaskPlan? in
                guard case let .taskPlan(value) = artifact else { return nil }
                return value
            }).last,
            replacement.todoDiffDrafts.contains(where: { $0.conversationRunID == runID }) == false {
                let draft = try ZhulongTodoDiffDraft(
                    sessionID: replacement.id,
                    conversationRunID: runID,
                    planningDate: today,
                    sourceSnapshot: engine.snapshot(),
                    createdAt: now,
                    items: plan.todoDiffItems(planningDate: today)
                )
                try replacement.publishConversationTodoDiff(draft, now: now)
            }
            if let review = response.artifacts.compactMap({ artifact -> ZhulongConversationDailyReview? in
                guard case let .dailyReview(value) = artifact else { return nil }
                return value
            }).last,
            replacement.dailyReviewDrafts.last == nil {
                let snapshotAt = Date()
                let snapshot = try replacement.captureDailyClose(
                    date: today,
                    from: engine,
                    now: snapshotAt
                )
                let draftAt = Date()
                _ = try replacement.publishDailyReviewDraft(
                    dailyCloseID: snapshot.id,
                    summary: review.summary,
                    tomorrowNote: review.tomorrowNote,
                    causeResolutionIDs: [],
                    now: draftAt
                )
            }
            guard replacement != session else { return }
            try zhulongSessionRepository.save(replacement, replacing: session)
            replaceZhulongSession(replacement)
        } catch {
            errorMessage = "烛龙产物已返回，但无法建立本地审阅草稿。"
        }
    }

    private func finishZhulongApplication(
        pending: ZhulongPendingApplication,
        prepareJournal: ZhulongApplicationJournalCommitOutcome,
        beforeSnapshot: NoonmarkSnapshot,
        afterEngine: NoonmarkEngine
    ) -> ZhulongApplicationCommitOutcome {
        ZhulongApplicationCommitCoordinator.finish(
            prepareJournal: prepareJournal,
            engineAlreadyPersisted: false,
            persistEngine: {
                try repository.save(
                    afterEngine.snapshot(),
                    changedFrom: beforeSnapshot
                )
            },
            reconcileEnginePersistenceFailure: {
                try ZhulongEnginePersistenceInspector.resolve(
                    persistedEngine: repository.load(),
                    pendingApplication: pending
                )
            },
            persistSession: {
                try ZhulongPendingSessionReconciler.reconcile(
                    pendingApplication: pending,
                    loadPersistedSession: {
                        try zhulongSessionRepository.load(pending.sessionID)
                    },
                    replaceExpectedSession: { replacement, expected in
                        try zhulongSessionRepository.save(
                            replacement,
                            replacing: expected,
                            authorizedBy: pending
                        )
                    }
                )
            },
            clearJournal: { requirement in
                try zhulongApplicationJournal.clear(
                    pending,
                    requiring: requirement
                )
            }
        )
    }

    private func recoverPendingZhulongApplication() {
        do {
            guard let pending = try zhulongApplicationJournal.load() else {
                return
            }
            let currentSnapshot = engine.snapshot()
            let plan = try ZhulongPendingApplicationRecoveryPlan(
                currentEngine: engine,
                pendingApplication: pending
            )
            let recoveredEngine = try NoonmarkEngine(
                snapshot: plan.recoveredSnapshot
            )
            if plan.persistenceChangedAt != nil {
                try repository.save(
                    recoveredEngine.snapshot(),
                    changedFrom: currentSnapshot
                )
            }
            _ = try ZhulongPendingSessionReconciler.reconcile(
                pendingApplication: pending,
                loadPersistedSession: {
                    try zhulongSessionRepository.load(pending.sessionID)
                },
                replaceExpectedSession: { replacement, expected in
                    try zhulongSessionRepository.save(
                        replacement,
                        replacing: expected,
                        authorizedBy: pending
                    )
                }
            )
            try zhulongApplicationJournal.clear(
                pending,
                requiring: .afterSession
            )
            engine = recoveredEngine
        } catch {
            errorMessage = "烛龙待确认变更恢复失败，已阻断本地写入。"
        }
    }

    private func canMutateWorkspace() -> Bool {
        guard isWorkspaceReadOnly == false else {
            errorMessage = "本地工作区只读，当前写入已阻断。"
            return false
        }
        do {
            guard try zhulongApplicationJournal.load() == nil else {
                errorMessage = "烛龙待确认变更正在恢复，当前写入已暂时阻断。"
                return false
            }
            return true
        } catch {
            errorMessage = "烛龙事务状态无法验证，当前写入已阻断。"
            return false
        }
    }

    private func zhulongPurpose(for task: ZhulongTask) -> ZhulongSessionPurpose {
        switch task {
        case .dailyReview: .dailyClose
        case .habitInsight: .habitInsight
        case .taskDecomposition: .taskShaping
        case .scheduling: .schedulingAssistance
        case .classification: .classificationAssistance
        case .taskPoolAnalysis: .taskPoolAnalysis
        case .theoryAnalysis: .theoryAnalysis
        }
    }

    private func zhulongScopes(for task: ZhulongTask) -> Set<ZhulongDataScope> {
        switch task {
        case .dailyReview, .habitInsight, .taskDecomposition:
            [.currentDayTodo]
        case .scheduling:
            [.currentDayTodo, .taskPool, .unfinishedPool]
        case .taskPoolAnalysis:
            [.taskPool]
        case .classification, .theoryAnalysis:
            [.currentDayTodo, .taskPool, .unfinishedPool, .completedPool, .taskClassifications]
        }
    }

    private func zhulongScopeText(_ scope: ZhulongDataScope) -> String {
        switch scope {
        case .currentDayTodo:
            let text = dayTodo.traces.map { trace in
                let title = engine.definitions[trace.definitionID]?.title ?? "无标题"
                return "- \(title)（\(trace.status.rawValue)）"
            }.joined(separator: "\n")
            return text.isEmpty ? "当前没有 Todo。" : text
        case .taskPool:
            let text = poolTasks.map { task in
                "- \(task.definition.title)：\(task.definition.descriptionText ?? "无说明")"
            }.joined(separator: "\n")
            return text.isEmpty ? "当前任务池为空。" : text
        case .unfinishedPool:
            let text = unfinishedTasks.map { item in
                "- \(item.definition.title)：未完成轨迹 \(item.unfinishedTraces.count) 条"
            }.joined(separator: "\n")
            return text.isEmpty ? "当前没有未完成任务。" : text
        case .completedPool:
            let text = completedHierarchies.map { hierarchy in
                "- \(hierarchy.definition.title)"
            }.joined(separator: "\n")
            return text.isEmpty ? "当前没有已完成任务。" : text
        case .taskClassifications:
            guard let catalog = classificationCatalog else { return "当前没有分类目录。" }
            let categories = catalog.categories.map { "@\($0.name)" }
            let labels = catalog.labels.map { "#\($0.name)" }
            return (categories + labels).joined(separator: "、")
        }
    }

    private func reloadZhulongSessions() {
        let ids = UserDefaults.standard.stringArray(forKey: zhulongSessionIDsKey) ?? []
        zhulongSessions = ids.compactMap { raw in
            guard let uuid = UUID(uuidString: raw) else { return nil }
            return try? zhulongSessionRepository.load(ZhulongSessionID(uuid))
        }
        selectedZhulongSessionID = zhulongSessions.first?.id
    }

    private func persistZhulongSessionID(_ id: ZhulongSessionID) {
        var ids = UserDefaults.standard.stringArray(forKey: zhulongSessionIDsKey) ?? []
        ids.removeAll { $0 == id.description }
        ids.insert(id.description, at: 0)
        UserDefaults.standard.set(ids, forKey: zhulongSessionIDsKey)
    }

    private func updateZhulongSession(
        _ id: ZhulongSessionID,
        mutation: (inout ZhulongSession) throws -> Void
    ) {
        guard canMutateWorkspace(),
              let existing = zhulongSessions.first(where: { $0.id == id })
        else { return }
        do {
            var replacement = existing
            try mutation(&replacement)
            try zhulongSessionRepository.save(replacement, replacing: existing)
            replaceZhulongSession(replacement)
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    private func replaceZhulongSession(_ session: ZhulongSession) {
        if let index = zhulongSessions.firstIndex(where: { $0.id == session.id }) {
            zhulongSessions[index] = session
        } else {
            zhulongSessions.insert(session, at: 0)
        }
        selectedZhulongSessionID = session.id
    }

    private func loadZhulongProviderSettings() {
        zhulongProviderBaseURL = UserDefaults.standard.string(forKey: "noonmark.ios.zhulong.baseURL") ?? ""
        zhulongProviderModel = UserDefaults.standard.string(forKey: "noonmark.ios.zhulong.model") ?? ""
    }

    private func saveZhulongAPIKey(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: zhulongProviderService,
            kSecAttrAccount as String: "api-key",
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: "NoonmarkIOSProvider", code: Int(status))
        }
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: zhulongProviderService,
                kSecAttrAccount as String: "api-key"
            ]
            let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: "NoonmarkIOSProvider", code: Int(updateStatus))
            }
        }
    }

    private func loadZhulongAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: zhulongProviderService,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func moveSelectedDate(by offset: Int) {
        let calendar = Calendar.current
        guard let date = calendar.date(
            from: DateComponents(
                year: selectedDate.year,
                month: selectedDate.month,
                day: selectedDate.day
            )
        ), let next = calendar.date(byAdding: .day, value: offset, to: date)
        else { return }
        selectedDate = Self.currentLocalDate(from: next, calendar: calendar)
    }

    func moveSelectedMonth(by offset: Int) {
        let calendar = Calendar.current
        guard let date = calendar.date(
            from: DateComponents(
                year: selectedDate.year,
                month: selectedDate.month,
                day: 1
            )
        ), let next = calendar.date(byAdding: .month, value: offset, to: date)
        else { return }
        selectedDate = Self.currentLocalDate(from: next, calendar: calendar)
    }

    func reloadFromDisk() {
        do {
            engine = try repository.load()
            IOSTheme.apply(engine.preferences.theme)
            isWorkspaceReadOnly = false
            errorMessage = nil
        } catch {
            errorMessage = "本地数据重新读取失败。"
        }
    }

    @discardableResult
    private func commit(_ mutation: (NoonmarkEngine) throws -> Void) -> Bool {
        guard canMutateWorkspace() else { return false }
        let sourceSnapshot = engine.snapshot()
        let candidate = NoonmarkEngine(copying: engine)
        do {
            try mutation(candidate)
            try repository.save(
                candidate.snapshot(),
                changedFrom: sourceSnapshot
            )
            engine = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.userFacingError(error)
            return false
        }
    }

    private func applyTaskDraftClassification(
        to candidate: NoonmarkEngine,
        chainID: TaskChainID,
        categoryName: String?,
        labelNames: [String],
        now: Date
    ) throws {
        let category = taskCategoryChoice(for: categoryName, in: candidate)
        let labels = taskLabelChoices(for: labelNames, in: candidate)
        guard category != nil || labels.isEmpty == false else { return }
        let interactionID = UUID()
        let plan = try candidate.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try candidate.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: interactionID
            ),
            now: now
        )
    }

    private func taskCategoryChoice(
        for rawName: String?,
        in candidate: NoonmarkEngine
    ) -> TaskCategoryChoice? {
        guard let rawName else { return nil }
        let name = ClassificationNameCanonicalizer.displayName(
            rawName.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        )
        guard name.isEmpty == false else { return nil }
        let key = ClassificationNameCanonicalizer.canonicalKey(name)
        let catalog: ClassificationCatalogProjection? = if case let .catalog(projection) = try? candidate.classification(.catalog) {
            projection
        } else {
            nil
        }
        if let existing = catalog?.categories.first(where: {
            $0.lifecycle == .active
                && ClassificationNameCanonicalizer.canonicalKey($0.name) == key
        }), let id = UUID(uuidString: existing.id) {
            return .existing(TaskCategoryID(id))
        }
        return .new(name: name, colorHex: "#2A6FDB")
    }

    private func taskLabelChoices(
        for rawNames: [String],
        in candidate: NoonmarkEngine
    ) -> [TaskLabelChoice] {
        let catalog: ClassificationCatalogProjection? = if case let .catalog(projection) = try? candidate.classification(.catalog) {
            projection
        } else {
            nil
        }
        let activeLabels = (catalog?.labels ?? []).filter { $0.lifecycle == .active }
        var seenKeys = Set<String>()
        return rawNames.compactMap { rawName in
            let name = ClassificationNameCanonicalizer.displayName(
                rawName.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            )
            let key = ClassificationNameCanonicalizer.canonicalKey(name)
            guard name.isEmpty == false, seenKeys.insert(key).inserted else { return nil }
            if let existing = activeLabels.first(where: {
                ClassificationNameCanonicalizer.canonicalKey($0.name) == key
            }), let id = UUID(uuidString: existing.id) {
                return .existing(TaskLabelID(id))
            }
            return .new(name: name, colorHex: "#0E9488")
        }
    }

    private static func currentLocalDate(calendar: Calendar) -> LocalDate {
        currentLocalDate(from: Date(), calendar: calendar)
    }

    private static func taskCategoryID(_ value: String) -> TaskCategoryID? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        return TaskCategoryID(uuid)
    }

    private static func taskLabelID(_ value: String) -> TaskLabelID? {
        guard let uuid = UUID(uuidString: value) else { return nil }
        return TaskLabelID(uuid)
    }

    private static func taskCategoryChoice(_ value: String) -> TaskCategoryChoice? {
        taskCategoryID(value).map(TaskCategoryChoice.existing)
    }

    private static func taskLabelChoice(_ value: String) -> TaskLabelChoice? {
        taskLabelID(value).map(TaskLabelChoice.existing)
    }

    private static func currentLocalDate(
        from date: Date,
        calendar: Calendar
    ) -> LocalDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    private static func userFacingError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false
        {
            return description
        }
        return "操作未能保存，请稍后再试。"
    }

    private static func syncFailureMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false
        {
            return "同步未执行：\(description)"
        }
        return "同步未执行：iCloud entitlement、账户或 transport 校验失败；本地数据未被远端覆盖。"
    }
}

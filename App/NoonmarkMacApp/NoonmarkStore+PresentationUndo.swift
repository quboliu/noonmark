import AppKit
import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import NoonmarkStorage
import SwiftUI

extension SQLiteLocalFirstSyncFailureReason {
    var appPresentationReason: AppSyncFailureReason? {
        switch self {
        case .baselineUnavailable:
            .baselineUnavailable
        case .baselineInvalid:
            .baselineInvalid
        case .baselineNotUploaded:
            .baselineNotUploaded
        case .localRecordsUnpreparable:
            .localRecordsUnpreparable
        case .localChangesPending:
            .localChangesPending
        case .remoteChangesPending:
            .remoteChangesPending
        case .transportOrStorage, .operationInterrupted:
            nil
        }
    }
}

extension NoonmarkStore {
    enum DetailRailRoute: Equatable {
        case calendar
        case flylight
        case selection
        case zhulong
        case dayReview
        case pageSummary(Page)
    }

    var isHistory: Bool {
        selectedDate < today || engine.days[selectedDate]?.lockedAt != nil
    }

    var isFuture: Bool {
        selectedDate > today && engine.days[selectedDate]?.lockedAt == nil
    }

    var selectedTrace: DayTrace? {
        guard let selectedTraceID,
              let trace = engine.traces[selectedTraceID],
              trace.formsDayHistory
        else {
            return nil
        }
        return trace
    }

    var selectedTaskCycleSeries: TaskCycleSeries? {
        selectedTaskCycleSeriesID.flatMap {
            engine.taskCycleSeries[$0]
        }
    }

    var selectedDefinition: TaskDefinition? {
        guard let selectedTrace else { return nil }
        return engine.definitions[selectedTrace.definitionID]
    }

    var selectedPoolTask: PoolTask? {
        guard let selectedPoolChainID else { return nil }
        return engine.taskPool().first { $0.chain.id == selectedPoolChainID }
    }

    func currentDefinition(for chainID: TaskChainID) -> TaskDefinition? {
        engine.definitions.values.first {
            $0.chainID == chainID && $0.supersededAt == nil
        }
    }

    var selectedCompletedItem: CompletedPoolItem? {
        guard let selectedCompletedTraceID else { return nil }
        return engine.completedPool().first { $0.trace.id == selectedCompletedTraceID }
    }

    var selectedCompletedSubtaskRecord: CompletedSubtaskRecord? {
        guard let selectedCompletedSubtaskID else { return nil }
        return engine.completedSubtaskRecords().first { $0.subtask.id == selectedCompletedSubtaskID }
    }

    var selectedUnfinishedItem: UnfinishedPoolItem? {
        guard let selectedUnfinishedChainID else { return nil }
        return engine.unfinishedPool().first { $0.chain.id == selectedUnfinishedChainID }
    }

    var zhulongFeatureAvailability: ZhulongFeatureAvailability {
        ZhulongFeatureAvailability(
            providerEnabled: zhulongProviderDraft.enabled,
            preferences: zhulongFeaturePreferences
        )
    }

    var isZhulongEnabled: Bool {
        zhulongFeatureAvailability.pageIsAvailable
    }

    var isZhulongProviderReady: Bool {
        zhulongProviderDraft.isConfigured
            && zhulongProviderDraft.hasStoredAPIKey
            && ZhulongProviderSettingsStore
                .persistedReadyExecutionRevision() != nil
    }

    var isAutomaticClassificationEnabled: Bool {
        zhulongFeatureAvailability.shouldEnqueueAutomaticClassification
    }

    func setZhulongPageEnabled(_ enabled: Bool) {
        guard zhulongFeaturePreferences.pageEnabled != enabled else { return }
        zhulongFeaturePreferences.pageEnabled = enabled
        zhulongFeaturePreferencesRepository.save(zhulongFeaturePreferences)
        if enabled == false, page == .zhulong {
            page = .day
        }
    }

    func setAutomaticClassificationEnabled(_ enabled: Bool) {
        guard zhulongFeaturePreferences.automaticClassificationEnabled != enabled else {
            return
        }
        zhulongFeaturePreferences.automaticClassificationEnabled = enabled
        zhulongFeaturePreferencesRepository.save(zhulongFeaturePreferences)
        automaticClassificationBacklogPrompt = nil
        automaticClassificationWorkerRestartRequested = false
        if enabled {
            restoreAutomaticClassificationWork()
        } else {
            automaticClassificationWorkerTask?.cancel()
            automaticClassificationBacklogDecisionTask?.cancel()
            automaticClassificationCircuitRetryTask?.cancel()
            refreshAutomaticClassificationStatusesForFeatureChange()
        }
    }

    func setZhulongDataReadingPolicy(
        _ policy: ZhulongPermissionPolicy
    ) {
        guard zhulongFeaturePreferences
            .conversationPermissionCeiling.dataReading != policy
        else {
            return
        }
        zhulongFeaturePreferences
            .conversationPermissionCeiling.dataReading = policy
        zhulongFeaturePreferencesRepository.save(
            zhulongFeaturePreferences
        )
    }

    func setZhulongRemoteSendingPolicy(
        _ policy: ZhulongPermissionPolicy
    ) {
        guard zhulongFeaturePreferences
            .conversationPermissionCeiling.remoteSending != policy
        else {
            return
        }
        zhulongFeaturePreferences
            .conversationPermissionCeiling.remoteSending = policy
        zhulongFeaturePreferencesRepository.save(
            zhulongFeaturePreferences
        )
    }

    func setHorizontalPageNavigationSwipeDirection(
        _ direction: HorizontalPageNavigationSwipeDirection
    ) {
        guard horizontalPageNavigationSwipeDirection != direction else {
            return
        }
        horizontalPageNavigationSwipeDirection = direction
        horizontalPageNavigationPreferenceRepository.save(direction)
    }

    var hasActiveDetailSelection: Bool {
        if selectedTaskCycleSeries != nil {
            return true
        }
        if selectedPoolTask != nil || selectedUnfinishedItem != nil || selectedCompletedItem != nil || selectedCompletedSubtaskRecord != nil {
            return true
        }
        return selectedTrace != nil && selectedDefinition != nil
    }

    var detailRailRoute: DetailRailRoute? {
        guard page != .settings else { return nil }
        if page == .calendar {
            return .calendar
        }
        if page == .zhulong {
            return zhulongWorkspace.selectedSession == nil ? nil : .zhulong
        }
        if page == .ideas {
            return .flylight
        }
        if hasActiveDetailSelection {
            return .selection
        }
        if page == .day {
            return .dayReview
        }
        if [.pool, .future, .unfinished, .completed].contains(page) {
            return .pageSummary(page)
        }
        return nil
    }

    var hasDetailRailContent: Bool {
        detailRailRoute != nil
    }

    var shouldShowDetailRail: Bool {
        isDetailRailExpanded && hasDetailRailContent
    }

    var canPerformEngineMutation: Bool {
        dayBoundaryState.isReady && exclusiveEngineOperation == nil
    }

    var canBeginDataImport: Bool {
        canPerformEngineMutation && isLocalFirstSyncing == false
    }

    var canUndoDomainAction: Bool {
        canPerformEngineMutation
            && showingClassificationManager == false
            && undoStack.isEmpty == false
    }

    var canRedoDomainAction: Bool {
        canPerformEngineMutation
            && showingClassificationManager == false
            && redoStack.isEmpty == false
    }

    var domainUndoMenuTitle: String {
        guard let entry = undoStack.last else { return copy.undo }
        return copy.undoNamed(entry.actionName(copy: copy))
    }

    var domainRedoMenuTitle: String {
        guard let entry = redoStack.last else { return copy.redo }
        return copy.redoNamed(entry.actionName(copy: copy))
    }

    func toggleDetailRail() {
        guard hasDetailRailContent else { return }
        isDetailRailExpanded.toggle()
    }

    func toggleSidebar() {
        isSidebarExpanded.toggle()
    }

    var visibleNavigationPages: [Page] {
        var pages: [Page] = [
            .day,
            .pool,
            .future,
            .recurring,
            .unfinished,
            .completed,
            .calendar,
            .stickyNotes,
            .ideas
        ]
        if isZhulongEnabled {
            pages.append(.zhulong)
        }
        return pages
    }

    var copy: AppCopy {
        AppCopy(language: engine.preferences.language)
    }

    var windowTitle: String {
        switch page {
        case .day:
            return "\(copy.appName) · \(copy.navDay) — \(displayDate(selectedDate))"
        case .calendar:
            return "\(copy.appName) · \(copy.navCalendar) — \(displayDate(selectedCalendarDate))"
        default:
            return "\(copy.appName) · \(navigationLabel(for: page))"
        }
    }

    func navigationLabel(for page: Page) -> String {
        switch page {
        case .day:
            return copy.navDay
        case .stickyNotes:
            return copy.navStickyNotes
        case .ideas:
            return copy.navIdeas
        case .pool:
            return copy.navPool
        case .future:
            return copy.navFuture
        case .recurring:
            return copy.navRecurring
        case .unfinished:
            return copy.navUnfinished
        case .completed:
            return copy.navCompleted
        case .calendar:
            return copy.navCalendar
        case .zhulong:
            return copy.navZhulong
        case .settings:
            return copy.navSettings
        }
    }

    func navigationCount(for page: Page) -> Int {
        switch page {
        case .day:
            return engine.getDayTodo(date: today).traces.filter { $0.status == .pending }.count
        case .pool:
            return engine.taskPoolCount()
        case .future:
            return visibleFuturePlanItems().count
        case .recurring:
            return engine.taskCycleSeries.count
        case .unfinished:
            return engine.unfinishedPoolCount()
        case .completed:
            return engine.completedTaskHierarchyCount()
        case .calendar, .zhulong, .settings, .stickyNotes, .ideas:
            return 0
        }
    }

    func definition(for trace: DayTrace) -> TaskDefinition? {
        engine.definitions[trace.definitionID]
    }

    func subtasks(for traceID: DayTraceID) -> [Subtask] {
        engine.subtasks.values
            .filter {
                $0.traceID == traceID && $0.isUserPresentable
            }
            .sorted { $0.position < $1.position }
    }

    func dayTodoPresentationSections(
        date: LocalDate,
        preference: TaskCollectionPresentationPreference
    ) -> [TaskCollectionPresentationSection] {
        let items = engine.getDayTodo(date: date).traces.map { trace in
            TaskCollectionPresentationItem(
                id: trace.id.description,
                title: copy.displayTaskTitle(definition(for: trace)?.title),
                time: trace.createdAt,
                category: displayableClassification(for: trace)?
                    .category?.taskCollectionCategoryPresentation,
                precedence: trace.status == .pending ? 0 : 1,
                fixedOrder: trace.status == .pending ? trace.pinOrder : nil
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: items,
            preference: preference,
            ungroupedTitle: copy.ungrouped
        )
    }

    func contextMenuActions(for trace: DayTrace) -> [TraceContextAction] {
        let isLocked = engine.days[trace.date]?.lockedAt != nil
        let isRecurringOccurrence =
            engine.isRecurringTaskChain(trace.chainID)
        let completionCapability = try? engine.completionCapability(
            for: trace.id,
            today: today
        )
        if isLocked == false, trace.date == today, trace.status == .pending {
            var actions: [TraceContextAction] = []
            if completionCapability == .available(.complete) {
                actions.append(.markComplete)
            }
            actions.append(trace.pinOrder == nil ? .pinToTop : .unpin)
            actions.append(contentsOf: [.deferTo, .changeToNewTask])
            if isRecurringOccurrence == false {
                actions.append(.returnToPool)
            }
            actions.append(.abandonChain)
            if engine.canDeleteNewCurrentDayTask(traceID: trace.id, today: today) {
                actions.append(.deleteNewCurrentDayTask)
            }
            return actions
        }

        if engine.canWithdrawDeferral(
            sourceTraceID: trace.id,
            today: today
        ) {
            return [.withdrawDeferral]
        }

        if isLocked == false, trace.date == today, trace.status == .completed {
            return completionCapability == .available(.undo) ? [.undoComplete] : []
        }

        let canContinueHistoricalUnfinished = (trace.date < today || isLocked)
            && trace.status == .unfinished
            && chainIsActive(trace.chainID)
            && activeTrace(for: trace.chainID) == nil
        if canContinueHistoricalUnfinished {
            return [.continueTo, .abandonChain]
        }

        if trace.date < today || isLocked, trace.status == .completed {
            return [.copyAsNewTask]
        }

        if trace.date > today, trace.status == .pending {
            var actions: [TraceContextAction] = [
                trace.pinOrder == nil ? .pinToTop : .unpin,
                .reschedule
            ]
            if isRecurringOccurrence == false {
                actions.append(.returnToPool)
            }
            return actions
        }

        return []
    }

    private func chainIsActive(_ chainID: TaskChainID) -> Bool {
        engine.chains[chainID]?.state == .active
    }

    private func activeTrace(for chainID: TaskChainID) -> DayTrace? {
        engine.traces.values.first { $0.chainID == chainID && $0.status == .pending }
    }

    func dateStripDates() -> [LocalDate] {
        let blockSize = 14
        let initialStart = Self.offset(today, by: -6)
        let selectedOffset = Self.dayDistance(
            from: initialStart,
            to: selectedDate
        )
        let truncatedBlock = selectedOffset / blockSize
        let block = selectedOffset % blockSize < 0
            ? truncatedBlock - 1
            : truncatedBlock
        let start = Self.offset(initialStart, by: block * blockSize)
        return (0..<blockSize).map { Self.offset(start, by: $0) }
    }

    var selectedDateStripIndex: Int? {
        dateStripDates().firstIndex(of: selectedDate)
    }

    var canNavigateDatePage: Bool {
        showingPicker == nil
            && showingFromPoolPicker == false
            && showingChangeDialog == false
            && showingClassificationManager == false
            && preparedDataImport == nil
    }

    func moveSelectedPage(
        _ direction: HorizontalPageNavigationDirection
    ) {
        guard canNavigateDatePage else { return }
        let offset = direction == .next ? 1 : -1
        switch page {
        case .day:
            selectedDate = Self.offset(selectedDate, by: offset)
        case .calendar:
            selectedCalendarDate = Self.shiftedMonth(
                from: selectedCalendarDate,
                by: offset
            )
        case .stickyNotes, .ideas, .pool, .future, .recurring, .unfinished, .completed, .zhulong,
             .settings:
            return
        }
    }

    func moveSelectedPageFromSwipe(
        _ recognizedDirection: HorizontalPageNavigationDirection
    ) {
        moveSelectedPage(
            horizontalPageNavigationSwipeDirection.resolve(
                recognizedDirection
            )
        )
    }

    func moveSelectedDate(_ direction: MoveCommandDirection) {
        guard canNavigateDatePage else { return }

        let days: Int
        switch direction {
        case .left:
            days = -1
        case .right:
            days = 1
        case .up:
            days = -7
        case .down:
            days = 7
        @unknown default:
            return
        }

        switch page {
        case .day:
            selectedDate = Self.offset(selectedDate, by: days)
        case .calendar:
            selectedCalendarDate = Self.offset(selectedCalendarDate, by: days)
        case .stickyNotes, .ideas, .pool, .future, .recurring, .unfinished, .completed, .zhulong,
             .settings:
            return
        }
    }

    func continuationDurationDays(for trace: DayTrace) -> Int {
        let chainDates = engine.traces.values
            .filter {
                $0.chainID == trace.chainID && $0.formsDayHistory
            }
            .map(\.date)
        guard let startDate = chainDates.min() else { return 1 }
        let days = Self.dayDistance(from: startDate, to: trace.date)
        return max(1, days + 1)
    }

    func performDateChoice(
        _ date: LocalDate,
        for purpose: DatePickerPurpose
    ) {
        guard showingPicker?.id == purpose.id else { return }
        switch purpose {
        case .gotoDay:
            selectedDate = date
            selectedCalendarDate = date
            page = .day
        case let .schedulePool(chainID):
            schedulePoolTask(chainID, date: date)
        case let .deferTrace(traceID):
            deferTrace(traceID, to: date)
        case let .continueTrace(traceID):
            continueUnfinishedTrace(traceID, to: date)
        case let .reschedule(traceID):
            reschedule(traceID, to: date)
        }
        self.showingPicker = nil
    }

    func undo() {
        guard let moment = prepareStoreMutationForUser() else { return }
        guard let entry = undoStack.last else {
            showToast(copy.nothingToUndo)
            return
        }
        let currentSnapshot = engine.snapshot()
        let candidate: NoonmarkEngine
        var snapshotUndoOutcome = SnapshotUndoOutcome()
        var noteIdentityRemap: NoteIdentityRemap?
        let redoEntry: RedoEntry
        let automaticClassificationJobsChanged: Bool
        do {
            switch entry {
            case let .snapshot(snapshot, _):
                candidate = try NoonmarkEngine(snapshot: snapshot)
                snapshotUndoOutcome = try candidate.prepareSnapshotUndo(
                    replacing: currentSnapshot,
                    now: moment.instant
                )
            case let .copiedTask(_, copiedChainID):
                candidate = try NoonmarkEngine(snapshot: currentSnapshot)
                _ = try candidate.removeTaskFromPool(
                    chainID: copiedChainID,
                    now: moment.instant
                )
            case .traceNoteAppend, .traceNoteEdit, .traceNoteDelete,
                 .poolNoteAppend, .poolNoteEdit, .poolNoteDelete:
                candidate = try NoonmarkEngine(snapshot: currentSnapshot)
                noteIdentityRemap = try applyNoteUndo(
                    entry,
                    to: candidate,
                    moment: moment
                )
            }
            redoEntry = try makeRedoEntry(
                for: entry,
                snapshotBeforeUndo: currentSnapshot,
                noteIdentityRemap: noteIdentityRemap
            )
            automaticClassificationJobsChanged = try saveSnapshotUndo(
                candidate,
                outcome: snapshotUndoOutcome,
                mutationAt: moment.instant
            )
        } catch {
            showOperationFailure(.undo, error: error)
            return
        }
        undoStack.removeLast()
        pushRedoEntry(redoEntry)
        if let noteIdentityRemap {
            undoStack = undoStack.map {
                $0.remappingNoteIdentity(noteIdentityRemap)
            }
        }
        engine = candidate
        if automaticClassificationJobsChanged {
            automaticClassificationJobsDidChange()
        }
        Theme.apply(engine.preferences.theme)
        normalizeSelection()
        showToast(copy.undoCompleted)
    }

    func redo() {
        guard let moment = prepareStoreMutationForUser() else { return }
        guard let entry = redoStack.last else {
            showToast(copy.nothingToRedo)
            return
        }
        let currentSnapshot = engine.snapshot()
        let replay: RedoReplay
        let automaticClassificationJobsChanged: Bool
        do {
            replay = try replayRedoEntry(
                entry,
                snapshotBeforeRedo: currentSnapshot,
                moment: moment
            )
            let automaticClassificationRedoJob = try automaticClassificationRedo(
                for: replay.snapshotUndoOutcome,
                candidate: replay.engine
            )
            automaticClassificationJobsChanged = try saveSnapshotRedo(
                replay.engine,
                outcome: replay.snapshotUndoOutcome,
                redo: automaticClassificationRedoJob,
                mutationAt: moment.instant
            )
        } catch {
            showOperationFailure(.redo, error: error)
            return
        }
        redoStack.removeLast()
        undoStack.append(replay.undoEntry)
        if undoStack.count > Self.undoHistoryLimit {
            undoStack.removeFirst(undoStack.count - Self.undoHistoryLimit)
        }
        engine = replay.engine
        if automaticClassificationJobsChanged {
            automaticClassificationJobsDidChange()
        }
        Theme.apply(engine.preferences.theme)
        normalizeSelection()
        showToast(copy.redoCompleted)
    }

    private func replayRedoEntry(
        _ entry: RedoEntry,
        snapshotBeforeRedo: NoonmarkSnapshot,
        moment: StoreMutationMoment
    ) throws -> RedoReplay {
        let candidate: NoonmarkEngine
        let undoEntry: UndoEntry
        var snapshotUndoOutcome = SnapshotUndoOutcome()
        switch entry {
        case let .snapshot(snapshot, previousUndoEntry):
            candidate = try NoonmarkEngine(snapshot: snapshot)
            snapshotUndoOutcome = try candidate.prepareSnapshotUndo(
                replacing: snapshotBeforeRedo,
                now: moment.instant
            )
            undoEntry = previousUndoEntry
        case let .traceNoteAppend(traceID, body):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let noteID = try candidate.appendTraceNote(
                traceID: traceID,
                body: body,
                today: moment.today,
                now: moment.instant
            )
            undoEntry = .traceNoteAppend(
                traceID: traceID,
                noteID: noteID
            )
        case let .traceNoteEdit(traceID, noteID, body):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let trace = try noteUndoTrace(traceID, in: candidate)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.editTraceNote(
                traceID: traceID,
                noteID: noteID,
                body: body,
                today: moment.today,
                now: moment.instant
            )
            undoEntry = .traceNoteEdit(
                traceID: traceID,
                noteID: noteID,
                previousBody: note.body
            )
        case let .traceNoteDelete(traceID, noteID):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let trace = try noteUndoTrace(traceID, in: candidate)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.deleteTraceNote(
                traceID: traceID,
                noteID: noteID,
                today: moment.today,
                now: moment.instant
            )
            undoEntry = .traceNoteDelete(
                traceID: traceID,
                noteID: noteID,
                deletedBody: note.body
            )
        case let .poolNoteAppend(chainID, body):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let noteID = try candidate.appendPoolNote(
                chainID: chainID,
                body: body,
                now: moment.instant
            )
            undoEntry = .poolNoteAppend(
                chainID: chainID,
                noteID: noteID
            )
        case let .poolNoteEdit(chainID, noteID, body):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let chain = try noteUndoChain(chainID, in: candidate)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.editPoolNote(
                chainID: chainID,
                noteID: noteID,
                body: body,
                now: moment.instant
            )
            undoEntry = .poolNoteEdit(
                chainID: chainID,
                noteID: noteID,
                previousBody: note.body
            )
        case let .poolNoteDelete(chainID, noteID):
            candidate = try NoonmarkEngine(snapshot: snapshotBeforeRedo)
            let chain = try noteUndoChain(chainID, in: candidate)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.deletePoolNote(
                chainID: chainID,
                noteID: noteID,
                now: moment.instant
            )
            undoEntry = .poolNoteDelete(
                chainID: chainID,
                noteID: noteID,
                deletedBody: note.body
            )
        }
        return RedoReplay(
            engine: candidate,
            undoEntry: undoEntry,
            snapshotUndoOutcome: snapshotUndoOutcome
        )
    }

    private func applyNoteUndo(
        _ entry: UndoEntry,
        to candidate: NoonmarkEngine,
        moment: StoreMutationMoment
    ) throws -> NoteIdentityRemap? {
        switch entry {
        case .snapshot, .copiedTask:
            throw NoonmarkError.invalidTransition("snapshot is not a note undo action")
        case let .traceNoteAppend(traceID, noteID):
            let trace = try noteUndoTrace(traceID, in: candidate)
            _ = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.deleteTraceNote(
                traceID: traceID,
                noteID: noteID,
                today: moment.today,
                now: moment.instant
            )
            return nil
        case let .traceNoteEdit(traceID, noteID, previousBody):
            let trace = try noteUndoTrace(traceID, in: candidate)
            _ = try noteUndoEntry(noteID, in: trace.noteEntries)
            try candidate.editTraceNote(
                traceID: traceID,
                noteID: noteID,
                body: previousBody,
                today: moment.today,
                now: moment.instant
            )
            return nil
        case let .traceNoteDelete(traceID, noteID, deletedBody):
            let newID = try candidate.appendTraceNote(
                traceID: traceID,
                body: deletedBody,
                today: moment.today,
                now: moment.instant
            )
            return NoteIdentityRemap(
                owner: .trace(traceID),
                oldID: noteID,
                newID: newID
            )
        case let .poolNoteAppend(chainID, noteID):
            let chain = try noteUndoChain(chainID, in: candidate)
            _ = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.deletePoolNote(
                chainID: chainID,
                noteID: noteID,
                now: moment.instant
            )
            return nil
        case let .poolNoteEdit(chainID, noteID, previousBody):
            let chain = try noteUndoChain(chainID, in: candidate)
            _ = try noteUndoEntry(noteID, in: chain.noteEntries)
            try candidate.editPoolNote(
                chainID: chainID,
                noteID: noteID,
                body: previousBody,
                now: moment.instant
            )
            return nil
        case let .poolNoteDelete(chainID, noteID, deletedBody):
            let newID = try candidate.appendPoolNote(
                chainID: chainID,
                body: deletedBody,
                now: moment.instant
            )
            return NoteIdentityRemap(
                owner: .pool(chainID),
                oldID: noteID,
                newID: newID
            )
        }
    }

    private func makeRedoEntry(
        for undoEntry: UndoEntry,
        snapshotBeforeUndo: NoonmarkSnapshot,
        noteIdentityRemap: NoteIdentityRemap?
    ) throws -> RedoEntry {
        switch undoEntry {
        case .snapshot, .copiedTask:
            return .snapshot(snapshotBeforeUndo, undoEntry: undoEntry)
        case let .traceNoteAppend(traceID, noteID):
            let trace = try snapshotTrace(traceID, in: snapshotBeforeUndo)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            return .traceNoteAppend(traceID: traceID, body: note.body)
        case let .traceNoteEdit(traceID, noteID, _):
            let trace = try snapshotTrace(traceID, in: snapshotBeforeUndo)
            let note = try noteUndoEntry(noteID, in: trace.noteEntries)
            return .traceNoteEdit(
                traceID: traceID,
                noteID: noteID,
                body: note.body
            )
        case let .traceNoteDelete(traceID, _, _):
            guard let noteIdentityRemap,
                  noteIdentityRemap.owner == .trace(traceID)
            else {
                throw NoonmarkError.invalidTransition(
                    "trace note delete undo did not create a redo identity"
                )
            }
            return .traceNoteDelete(
                traceID: traceID,
                noteID: noteIdentityRemap.newID
            )
        case let .poolNoteAppend(chainID, noteID):
            let chain = try snapshotChain(chainID, in: snapshotBeforeUndo)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            return .poolNoteAppend(chainID: chainID, body: note.body)
        case let .poolNoteEdit(chainID, noteID, _):
            let chain = try snapshotChain(chainID, in: snapshotBeforeUndo)
            let note = try noteUndoEntry(noteID, in: chain.noteEntries)
            return .poolNoteEdit(
                chainID: chainID,
                noteID: noteID,
                body: note.body
            )
        case let .poolNoteDelete(chainID, _, _):
            guard let noteIdentityRemap,
                  noteIdentityRemap.owner == .pool(chainID)
            else {
                throw NoonmarkError.invalidTransition(
                    "pool note delete undo did not create a redo identity"
                )
            }
            return .poolNoteDelete(
                chainID: chainID,
                noteID: noteIdentityRemap.newID
            )
        }
    }

    private func snapshotTrace(
        _ traceID: DayTraceID,
        in snapshot: NoonmarkSnapshot
    ) throws -> DayTrace {
        guard let trace = snapshot.traces.first(where: { $0.id == traceID }) else {
            throw NoonmarkError.notFound("day trace")
        }
        return trace
    }

    private func snapshotChain(
        _ chainID: TaskChainID,
        in snapshot: NoonmarkSnapshot
    ) throws -> TaskChain {
        guard let chain = snapshot.chains.first(where: { $0.id == chainID }) else {
            throw NoonmarkError.notFound("task chain")
        }
        return chain
    }

    private func noteUndoTrace(
        _ traceID: DayTraceID,
        in candidate: NoonmarkEngine
    ) throws -> DayTrace {
        guard let trace = candidate.traces[traceID] else {
            throw NoonmarkError.notFound("day trace")
        }
        return trace
    }

    private func noteUndoChain(
        _ chainID: TaskChainID,
        in candidate: NoonmarkEngine
    ) throws -> TaskChain {
        guard let chain = candidate.chains[chainID] else {
            throw NoonmarkError.notFound("task chain")
        }
        return chain
    }

    private func noteUndoEntry(
        _ noteID: TaskNoteEntryID,
        in entries: [TaskNoteEntry]
    ) throws -> TaskNoteEntry {
        guard let note = entries.first(where: {
            $0.id == noteID && !$0.isDeleted
        }) else {
            throw NoonmarkError.notFound("task note")
        }
        return note
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func showToast(_ message: String) {
        toast = message
        toastScheduler.replace(after: .milliseconds(2200)) { [weak self] in
            self?.toast = nil
        }
    }

    func showOperationFailure(
        _ context: AppOperationFailureContext,
        error: Error,
        diagnosticIncidentID existingIncidentID: DiagnosticIncidentID? = nil,
        diagnosticOperationID: DiagnosticOperationID? = nil
    ) {
        let incidentID = recordOperationFailureEvidence(
            context,
            error: error,
            operationID: diagnosticOperationID,
            incidentID: existingIncidentID
        )
        let pendingApplicationIsBlocking = (error as? StoreMutationGateError)?
            .isPendingZhulongApplication == true
        if pendingApplicationIsBlocking {
            showToast(
                AppPresentation(
                    language: engine.preferences.language
                ).zhulong.pendingApplicationMutationBlocked
            )
            return
        }
        let presentation = AppPresentation(
            language: engine.preferences.language
        )
        let message: String = if context == .sync,
           let reason = (error as? SQLiteLocalFirstSyncError)?
           .failureReason.appPresentationReason
        {
            presentation.syncFailureMessage(for: reason)
        } else {
            presentation.failureMessage(for: context)
        }
        showPersistentFailureMessage(
            message,
            context: context,
            diagnosticIncidentID: incidentID
        )
    }

    func showPersistentFailureMessage(
        _ message: String,
        context: AppOperationFailureContext,
        diagnosticIncidentID: DiagnosticIncidentID? = nil
    ) {
        toastScheduler.cancel()
        toast = nil
        operationFailureNotice = AppOperationFailureNotice(
            context: context,
            message: message,
            diagnosticIncidentID: diagnosticIncidentID
        )
    }

    func resolveOperationFailure(_ context: AppOperationFailureContext) {
        guard operationFailureNotice?.context == context else { return }
        operationFailureNotice = nil
    }

    func dismissOperationFailure() {
        operationFailureNotice = nil
    }

    static func offset(_ date: LocalDate, by days: Int) -> LocalDate {
        requireCivilDate {
            try WorkspaceCivilCalendar.offset(date, byDays: days)
        }
    }

    private var dateTimeFormatter: AppDateTimeFormatter {
        AppDateTimeFormatter(
            language: engine.preferences.language,
            timeZone: TimeZone(identifier: naturalDayState.timeZoneIdentifier)
                ?? .autoupdatingCurrent
        )
    }

    func displayDate(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .monthDay))
            ?? date.description
    }

    func displayFullDate(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .fullDate))
            ?? date.description
    }

    func displayMonthYear(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .monthYear))
            ?? date.description
    }

    func displayAccessibilityDate(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .accessibilityFull))
            ?? date.description
    }

    func displayTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        return dateTimeFormatter.string(from: date, style: .shortTime)
    }

    func displayDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date, style: .dateAndTime)
    }

    func displayExactDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date, style: .exactDateAndTime)
    }

    func weekday(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .weekday))
            ?? date.description
    }

    func weekdayNarrow(_ date: LocalDate) -> String {
        (try? dateTimeFormatter.string(from: date, style: .weekdayNarrow))
            ?? date.description
    }

    func calendarWeekdayLabels() -> [String] {
        dateTimeFormatter.narrowWeekdaySymbolsStartingMonday()
    }

    static func dayDistance(from start: LocalDate, to end: LocalDate) -> Int {
        requireCivilDate {
            try WorkspaceCivilCalendar.dayDistance(from: start, to: end)
        }
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        requireCivilDate {
            try WorkspaceCivilCalendar.daysInMonth(year: year, month: month)
        }
    }

    static func mondayLeadBlankCount(year: Int, month: Int) -> Int {
        requireCivilDate {
            try WorkspaceCivilCalendar.mondayLeadBlankCount(
                year: year,
                month: month
            )
        }
    }

    static func shiftedMonth(from date: LocalDate, by delta: Int) -> LocalDate {
        requireCivilDate {
            try WorkspaceCivilCalendar.shiftedMonth(from: date, by: delta)
        }
    }

    static func monthGrid(
        containing date: LocalDate,
        rowCount: WorkspaceMonthGrid.RowCount,
        outsideMonth: WorkspaceMonthGrid.OutsideMonth
    ) -> WorkspaceMonthGrid {
        requireCivilDate {
            try WorkspaceMonthGrid(
                monthContaining: date,
                rowCount: rowCount,
                outsideMonth: outsideMonth
            )
        }
    }

    private static func requireCivilDate<Value>(
        _ operation: () throws -> Value
    ) -> Value {
        do {
            return try operation()
        } catch {
            preconditionFailure("Invalid civil-date operation: \(error)")
        }
    }

    func pushUndoEntry(with entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > Self.undoHistoryLimit {
            undoStack.removeFirst(undoStack.count - Self.undoHistoryLimit)
        }
    }

    private func pushRedoEntry(_ entry: RedoEntry) {
        redoStack.append(entry)
        if redoStack.count > Self.undoHistoryLimit {
            redoStack.removeFirst(redoStack.count - Self.undoHistoryLimit)
        }
    }
}

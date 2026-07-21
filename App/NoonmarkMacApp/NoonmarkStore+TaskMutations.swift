import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore

private enum TaskNoteMutationTargetError: LocalizedError {
    case unavailable
    case changedSinceEditing

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The note is no longer available for editing."
        case .changedSinceEditing:
            "The note changed after this edit session began."
        }
    }
}

extension NoonmarkStore {
    func addQuickTask() {
        let submittedText = quickText
        guard addQuickTask(submittedText, target: .selectedDate) else { return }
        quickText = ""
    }

    @discardableResult
    func addQuickTaskForToday(_ text: String) -> Bool {
        addQuickTask(text, target: .today)
    }

    @discardableResult
    private func addQuickTask(
        _ text: String,
        target: QuickTaskTarget
    ) -> Bool {
        let draft = parsedTaskDraft(text)
        guard draft.title.isEmpty == false else { return false }
        let originDescription = copy.quickTaskOriginDescription
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.addTask),
                automaticClassificationPolicy: .newlyCreatedTaskChains
            ) { candidate, moment in
                let targetDate = switch target {
                case .selectedDate:
                    selectedDate
                case .today:
                    moment.today
                }
                let chainID = try candidate.createPoolTask(
                    title: draft.title,
                    descriptionText: originDescription,
                    now: moment.instant
                )
                _ = try candidate.scheduleFromPool(
                    chainID: chainID,
                    date: targetDate,
                    today: moment.today,
                    now: moment.instant
                )
                _ = try applyTaskDraftLabels(
                    to: candidate,
                    chainID: chainID,
                    labelNames: draft.labelNames,
                    now: moment.instant
                )
            }
            showToast(copy.taskAdded(draft.title))
            return true
        } catch {
            showOperationFailure(.taskMutation, error: error)
            return false
        }
    }

    func addPoolTask() {
        let draft = parsedTaskDraft(poolText)
        guard draft.title.isEmpty == false else { return }
        let description = copy.unscheduledPoolTaskDescription
        let initialNote = copy.unscheduledPoolTaskInitialNote
        do {
            let chainID = try commitEngineMutation(
                undoPolicy: .snapshot(.addPoolTask),
                automaticClassificationPolicy: .newlyCreatedTaskChains
            ) { candidate, moment in
                let chainID = try candidate.createPoolTask(
                    title: draft.title,
                    descriptionText: description,
                    initialNoteBody: initialNote,
                    now: moment.instant
                )
                _ = try applyTaskDraftLabels(
                    to: candidate,
                    chainID: chainID,
                    labelNames: draft.labelNames,
                    now: moment.instant
                )
                return chainID
            }
            selectPool(chainID)
            poolText = ""
            showToast(copy.poolTaskAdded)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func parsedTaskDraft(_ rawText: String) -> (title: String, labelNames: [String]) {
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return ("", []) }
        let pattern = #"#([^\s#]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (raw, [])
        }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, range: range)
        let labelNames = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: raw) else { return nil }
            let labelName = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return labelName.isEmpty ? nil : labelName
        }
        let title = regex.stringByReplacingMatches(
            in: raw,
            range: range,
            withTemplate: " "
        )
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        return (title, labelNames)
    }

    func lastHashQuery(in text: String) -> String? {
        guard let hashIndex = text.lastIndex(of: "#") else { return nil }
        let tail = text[text.index(after: hashIndex)...]
        return tail.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    func schedulePoolTask(_ chainID: TaskChainID, date: LocalDate) {
        guard date >= today else {
            showToast(copy.poolCannotScheduleInPast)
            return
        }
        do {
            let traceID = try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: date,
                    action: .scheduleTask
                )
            ) { candidate, moment in
                try candidate.scheduleFromPool(
                    chainID: chainID,
                    date: date,
                    today: moment.today,
                    now: moment.instant
                )
            }
            selectedDate = date
            page = .day
            selectTrace(traceID)
            showToast(copy.scheduledTo(displayDate(date)))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func toggleComplete(_ traceID: DayTraceID) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            let capability = try engine.completionCapability(
                for: traceID,
                today: today
            )
            if capability == .unavailable(.openSubtasks) {
                showToast(copy.openSubtasksPreventCompletion)
                return
            }
            guard case let .available(action) = capability else { return }
            let didComplete = try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .completeTask
                )
            ) { candidate, moment in
                switch action {
                case .undo:
                    try candidate.undoCompleted(
                        traceID: traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                    return false
                case .complete:
                    try candidate.markCompleted(
                        traceID: traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                    return true
                }
            }
            showToast(copy.taskCompletionChanged(completed: didComplete))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func toggleSubtask(_ subtaskID: SubtaskID) {
        guard let subtask = engine.subtasks[subtaskID] else { return }
        guard let trace = engine.traces[subtask.traceID] else { return }
        guard canMutateSubtask(subtask) else {
            showToast(subtaskMutationUnavailableMessage(for: trace))
            return
        }
        do {
            let didComplete = try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .updateSubtask
                )
            ) { candidate, moment in
                guard let currentSubtask = candidate.subtasks[subtaskID] else {
                    throw NoonmarkError.notFound("subtask")
                }
                if currentSubtask.status == .pending {
                    try candidate.completeSubtask(
                        subtaskID,
                        today: moment.today,
                        now: moment.instant
                    )
                    return true
                }
                if currentSubtask.status == .completed {
                    try candidate.undoCompletedSubtask(
                        subtaskID,
                        today: moment.today,
                        now: moment.instant
                    )
                    return false
                }
                throw NoonmarkError.invalidTransition(
                    "只有待完成或已完成子任务可切换"
                )
            }
            showToast(copy.subtaskCompletionChanged(completed: didComplete))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func canMutateSubtask(_ subtask: Subtask) -> Bool {
        guard let trace = engine.traces[subtask.traceID] else { return false }
        return subtask.isUserPresentable
            && trace.date == today
            && trace.status == .pending
            && engine.days[trace.date]?.lockedAt == nil
    }

    private func subtaskMutationUnavailableMessage(for trace: DayTrace) -> String {
        if trace.date < today || engine.days[trace.date]?.lockedAt != nil {
            return copy.historicalSubtaskUnavailable
        }
        if trace.date > today {
            return copy.futureSubtaskUnavailable
        }
        return copy.inactiveParentSubtaskUnavailable
    }

    func cycleSubtaskDifficulty(_ subtaskID: SubtaskID) {
        guard let current = engine.subtasks[subtaskID]?.difficulty else { return }
        let next: SubtaskDifficulty = switch current {
        case .simple: .medium
        case .medium: .hard
        case .hard: .simple
        }
        setSubtaskDifficulty(subtaskID, difficulty: next)
    }

    func setSubtaskDifficulty(_ subtaskID: SubtaskID, difficulty: SubtaskDifficulty) {
        guard let subtask = engine.subtasks[subtaskID] else { return }
        guard let trace = engine.traces[subtask.traceID] else { return }
        guard canMutateSubtask(subtask) else {
            showToast(subtaskMutationUnavailableMessage(for: trace))
            return
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .updateSubtask
                )
            ) { candidate, moment in
                try candidate.updateSubtaskDifficulty(
                    subtaskID,
                    difficulty: difficulty,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showToast(copy.subtaskDifficultyUpdated)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func continueTrace(_ traceID: DayTraceID, to date: LocalDate) {
        guard let trace = engine.traces[traceID] else { return }
        let undoPolicy: EngineMutationUndoPolicy = trace.date >= today
            && engine.days[trace.date]?.lockedAt == nil
            ? .snapshotIfAllowed(on: trace.date, action: .continueTask)
            : .invalidate
        do {
            let nextID = try commitEngineMutation(
                undoPolicy: undoPolicy
            ) { candidate, moment in
                try candidate.continueTrace(
                    traceID: traceID,
                    targetDate: date,
                    today: moment.today,
                    now: moment.instant
                )
            }
            selectedDate = date
            page = .day
            selectTrace(nextID)
            showToast(copy.continuedTo(displayDate(date)))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func returnToPool(_ traceID: DayTraceID) {
        guard let trace = engine.traces[traceID] else { return }
        let undoPolicy: EngineMutationUndoPolicy = trace.date > today
            ? .snapshotIfAllowed(on: trace.date, action: .returnTaskToPool)
            : .invalidate
        do {
            try commitEngineMutation(undoPolicy: undoPolicy) { candidate, moment in
                try candidate.returnToPool(
                    traceID: traceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            page = .pool
            clearSelection()
            showToast(copy.returnedToPool)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func deleteNewCurrentDayTask(_ traceID: DayTraceID) {
        guard let trace = engine.traces[traceID],
              engine.canDeleteNewCurrentDayTask(traceID: traceID, today: today)
        else {
            return
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .deleteTask
                ),
                automaticClassificationPolicy: .taskBecameIneligible(
                    trace.chainID
                )
            ) { candidate, moment in
                try candidate.deleteNewCurrentDayTask(
                    traceID: traceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            if selectedTraceID == traceID {
                clearSelection()
            }
            showToast(copy.newCurrentDayTaskDeleted)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func abandon(_ traceID: DayTraceID) {
        guard let trace = engine.traces[traceID] else { return }
        let undoPolicy: EngineMutationUndoPolicy = trace.date >= today
            && engine.days[trace.date]?.lockedAt == nil
            ? .snapshotIfAllowed(on: trace.date, action: .abandonTask)
            : .invalidate
        do {
            try commitEngineMutation(
                undoPolicy: undoPolicy,
                automaticClassificationPolicy: .taskBecameIneligible(
                    trace.chainID
                )
            ) { candidate, moment in
                try candidate.abandonChain(from: traceID, now: moment.instant)
            }
            showToast(copy.taskChainAbandoned)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    @discardableResult
    func reactivateAbandonedChain(from traceID: DayTraceID) -> Bool {
        do {
            guard let chainID = engine.traces[traceID]?.chainID else {
                throw NoonmarkError.notFound("day trace")
            }
            _ = try commitEngineMutation(
                undoPolicy: .snapshot(.reactivateTask),
                automaticClassificationPolicy: .taskBecameEligible(chainID)
            ) { candidate, moment in
                try candidate.reactivateAbandonedChain(
                    from: traceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showToast(copy.taskChainReactivated)
            return true
        } catch {
            showOperationFailure(.taskMutation, error: error)
            return false
        }
    }

    func copyAsNewTask(_ traceID: DayTraceID) {
        do {
            var undoSnapshot: NoonmarkSnapshot?
            let copiedChainID = try commitEngineMutation { candidate, moment in
                undoSnapshot = candidate.snapshot()
                return try candidate.copyAsNewTask(
                    from: traceID,
                    target: .taskPool,
                    today: moment.today,
                    now: moment.instant
                )
            }
            guard let undoSnapshot else {
                throw NoonmarkError.invalidTransition(
                    "copy operation did not capture an undo snapshot"
                )
            }
            pushUndoEntry(
                with: .copiedTask(
                    snapshot: undoSnapshot,
                    chainID: copiedChainID
                )
            )
            page = .pool
            showToast(copy.copiedToPool)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func reschedule(_ traceID: DayTraceID, to date: LocalDate) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .rescheduleTask
                )
            ) { candidate, moment in
                try candidate.rescheduleFuturePlan(
                    traceID: traceID,
                    targetDate: date,
                    today: moment.today,
                    now: moment.instant
                )
            }
            selectedDate = date
            showToast(copy.rescheduledTo(displayDate(date)))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func changeSelectedTrace() {
        guard let selectedTraceID,
              let selectedTrace = engine.traces[selectedTraceID]
        else { return }
        let title = changeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            let newID = try commitEngineMutation(
                undoPolicy: .invalidate,
                automaticClassificationPolicy: .taskBecameIneligible(
                    selectedTrace.chainID
                )
            ) { candidate, moment in
                try candidate.changeTrace(
                    traceID: selectedTraceID,
                    newTitle: title,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showingChangeDialog = false
            changeText = ""
            selectTrace(newID)
            showToast(copy.traceChangedIrreversibly)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func canMovePriority(_ traceID: DayTraceID, delta: Int) -> Bool {
        guard let trace = engine.traces[traceID], trace.status == .pending else { return false }
        let orderedTraceIDs = pendingPriorityTraceIDs(on: trace.date)
        guard let currentIndex = orderedTraceIDs.firstIndex(of: traceID) else { return false }
        if delta < 0 {
            return currentIndex > 0
        }
        if delta > 0 {
            return currentIndex < orderedTraceIDs.count - 1
        }
        return false
    }

    func movePriority(_ traceID: DayTraceID, delta: Int) {
        guard let trace = engine.traces[traceID], trace.status == .pending else { return }
        let orderedTraceIDs = pendingPriorityTraceIDs(on: trace.date)
        guard let currentIndex = orderedTraceIDs.firstIndex(of: traceID) else { return }
        let targetTraceID: DayTraceID?
        if delta < 0 {
            guard currentIndex > 0 else { return }
            targetTraceID = orderedTraceIDs[currentIndex - 1]
        } else {
            guard currentIndex < orderedTraceIDs.count - 1 else { return }
            let followingIndex = currentIndex + 2
            targetTraceID = orderedTraceIDs.indices.contains(followingIndex)
                ? orderedTraceIDs[followingIndex]
                : nil
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .reorderTask
                )
            ) { candidate, moment in
                try candidate.reorderDayTrace(
                    traceID,
                    before: targetTraceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    private func pendingPriorityTraceIDs(on date: LocalDate) -> [DayTraceID] {
        engine.getDayTodo(date: date).traces
            .filter { $0.status == .pending }
            .map(\.id)
    }

    @discardableResult
    func reorderTrace(
        _ movingTraceID: DayTraceID,
        before targetTraceID: DayTraceID
    ) -> Bool {
        guard let date = reorderableTraceDate(
            movingTraceID,
            before: targetTraceID
        ) else {
            return false
        }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: date,
                    action: .reorderTask
                )
            ) { candidate, moment in
                try candidate.reorderDayTrace(
                    movingTraceID,
                    before: targetTraceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            return true
        } catch {
            showOperationFailure(.taskMutation, error: error)
            return false
        }
    }

    /// SwiftUI invokes drop actions inside its own view-update transaction.
    /// Accept the drop synchronously, then publish the persisted reorder from
    /// the next main-queue transaction.
    @discardableResult
    func enqueueTraceReorder(
        _ movingTraceID: DayTraceID,
        before targetTraceID: DayTraceID,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Bool {
        guard reorderableTraceDate(
            movingTraceID,
            before: targetTraceID
        ) != nil else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            completion(
                self.reorderTrace(
                    movingTraceID,
                    before: targetTraceID
                )
            )
        }
        return true
    }

    private func reorderableTraceDate(
        _ movingTraceID: DayTraceID,
        before targetTraceID: DayTraceID
    ) -> LocalDate? {
        guard movingTraceID != targetTraceID,
              let movingTrace = engine.traces[movingTraceID],
              let targetTrace = engine.traces[targetTraceID],
              movingTrace.date == targetTrace.date,
              movingTrace.status == .pending,
              targetTrace.status == .pending
        else {
            return nil
        }
        return movingTrace.date
    }

    func updateTraceText(
        traceID: DayTraceID,
        descriptionText: String,
        immediately: Bool = false
    ) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately
                    ? .preserve
                    : .snapshotIfAllowed(
                        on: trace.date,
                        action: .editTaskText
                    )
            ) { candidate, moment in
                try candidate.updateTraceText(
                    traceID: traceID,
                    descriptionText: descriptionText,
                    today: moment.today,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func renameTraceTitle(
        traceID: DayTraceID,
        title: String,
        immediately: Bool = false,
        reportsSuccess: Bool = true
    ) {
        guard let trace = engine.traces[traceID] else { return }
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately
                    ? .preserve
                    : .snapshotIfAllowed(on: trace.date, action: .renameTask),
                automaticClassificationPolicy: .taskDefinitionChanged(
                    trace.chainID
                )
            ) { candidate, moment in
                if immediately {
                    try candidate.saveTaskTitleInput(
                        chainID: trace.chainID,
                        title: nextTitle,
                        today: moment.today,
                        now: moment.instant
                    )
                } else {
                    try candidate.renameTaskTitle(
                        chainID: trace.chainID,
                        title: nextTitle,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            if reportsSuccess {
                showToast(copy.taskTitleUpdated)
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func renamePoolTask(
        chainID: TaskChainID,
        title: String,
        immediately: Bool = false,
        reportsSuccess: Bool = true
    ) {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately ? .preserve : .snapshot(.renameTask),
                automaticClassificationPolicy: .taskDefinitionChanged(chainID)
            ) { candidate, moment in
                if immediately {
                    try candidate.saveTaskTitleInput(
                        chainID: chainID,
                        title: nextTitle,
                        today: moment.today,
                        now: moment.instant
                    )
                } else {
                    try candidate.renameTaskTitle(
                        chainID: chainID,
                        title: nextTitle,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            if reportsSuccess {
                showToast(copy.taskTitleUpdated)
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func updatePoolTaskText(
        chainID: TaskChainID,
        descriptionText: String,
        immediately: Bool = false
    ) {
        guard let definition = currentDefinition(for: chainID) else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately ? .preserve : .snapshot(.editTaskText),
                automaticClassificationPolicy: .taskDefinitionChanged(chainID)
            ) { candidate, moment in
                try candidate.updatePoolTask(
                    chainID: chainID,
                    title: definition.title,
                    descriptionText: descriptionText,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func deletePoolTask(_ chainID: TaskChainID) {
        do {
            let outcome = try commitEngineMutation(
                undoPolicy: .invalidate,
                automaticClassificationPolicy: .taskBecameIneligible(chainID)
            ) { candidate, moment in
                try candidate.removeTaskFromPool(
                    chainID: chainID,
                    now: moment.instant
                )
            }
            if selectedPoolChainID == chainID {
                clearSelection()
            }
            let message = switch outcome {
            case .deleted:
                copy.poolRemovalMessage(keptHistory: false)
            case .removedKeepingHistory:
                copy.poolRemovalMessage(keptHistory: true)
            }
            showToast(message)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    @discardableResult
    func appendTraceNote(traceID: DayTraceID) -> Bool {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return false }
        guard engine.traces[traceID] != nil else {
            return rejectNoteMutation(.unavailable)
        }
        do {
            let noteID = try commitEngineMutation { candidate, moment in
                try candidate.appendTraceNote(
                    traceID: traceID,
                    body: body,
                    today: moment.today,
                    now: moment.instant
                )
            }
            pushUndoEntry(
                with: .traceNoteAppend(traceID: traceID, noteID: noteID)
            )
            detailNoteText = ""
            resolveOperationFailure(.noteMutation)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    @discardableResult
    func appendPoolNote(chainID: TaskChainID) -> Bool {
        let body = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { return false }
        do {
            let noteID = try commitEngineMutation { candidate, moment in
                try candidate.appendPoolNote(
                    chainID: chainID,
                    body: body,
                    now: moment.instant
                )
            }
            pushUndoEntry(
                with: .poolNoteAppend(chainID: chainID, noteID: noteID)
            )
            detailNoteText = ""
            resolveOperationFailure(.noteMutation)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    @discardableResult
    func editTraceNote(
        traceID: DayTraceID,
        noteID: TaskNoteEntryID,
        body: String,
        expectedUpdatedAt: Date? = nil,
        immediately: Bool = false
    ) -> Bool {
        guard let trace = engine.traces[traceID],
              let previousEntry = trace.activeNoteEntries.first(where: {
                  $0.id == noteID
              })
        else {
            return rejectNoteMutation(.unavailable)
        }
        guard expectedUpdatedAt == nil || previousEntry.updatedAt == expectedUpdatedAt else {
            return rejectNoteMutation(.changedSinceEditing)
        }
        do {
            try commitEngineMutation(undoPolicy: .preserve) { candidate, moment in
                try candidate.editTraceNote(
                    traceID: traceID,
                    noteID: noteID,
                    body: body,
                    today: moment.today,
                    now: moment.instant
                )
            }
            if immediately == false {
                pushUndoEntry(
                    with: .traceNoteEdit(
                        traceID: traceID,
                        noteID: noteID,
                        previousBody: previousEntry.body
                    )
                )
            }
            resolveOperationFailure(.noteMutation)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    @discardableResult
    func deleteTraceNote(traceID: DayTraceID, noteID: TaskNoteEntryID) -> Bool {
        guard let trace = engine.traces[traceID],
              let deletedBody = trace.activeNoteEntries.first(where: {
                  $0.id == noteID
              })?.body
        else {
            return rejectNoteMutation(.unavailable)
        }
        do {
            try commitEngineMutation { candidate, moment in
                try candidate.deleteTraceNote(
                    traceID: traceID,
                    noteID: noteID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            pushUndoEntry(
                with: .traceNoteDelete(
                    traceID: traceID,
                    noteID: noteID,
                    deletedBody: deletedBody
                )
            )
            resolveOperationFailure(.noteMutation)
            showToast(copy.noteDeletedToast)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    @discardableResult
    func editPoolNote(
        chainID: TaskChainID,
        noteID: TaskNoteEntryID,
        body: String,
        expectedUpdatedAt: Date? = nil,
        immediately: Bool = false
    ) -> Bool {
        guard let previousEntry = engine.taskPool().first(where: {
            $0.chain.id == chainID
        })?.chain.activeNoteEntries.first(where: {
            $0.id == noteID
        }) else {
            return rejectNoteMutation(.unavailable)
        }
        guard expectedUpdatedAt == nil || previousEntry.updatedAt == expectedUpdatedAt else {
            return rejectNoteMutation(.changedSinceEditing)
        }
        do {
            try commitEngineMutation(undoPolicy: .preserve) { candidate, moment in
                try candidate.editPoolNote(
                    chainID: chainID,
                    noteID: noteID,
                    body: body,
                    now: moment.instant
                )
            }
            if immediately == false {
                pushUndoEntry(
                    with: .poolNoteEdit(
                        chainID: chainID,
                        noteID: noteID,
                        previousBody: previousEntry.body
                    )
                )
            }
            resolveOperationFailure(.noteMutation)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    @discardableResult
    func deletePoolNote(chainID: TaskChainID, noteID: TaskNoteEntryID) -> Bool {
        guard let deletedBody = engine.taskPool().first(where: {
            $0.chain.id == chainID
        })?.chain.activeNoteEntries.first(where: {
            $0.id == noteID
        })?.body else {
            return rejectNoteMutation(.unavailable)
        }
        do {
            try commitEngineMutation { candidate, moment in
                try candidate.deletePoolNote(
                    chainID: chainID,
                    noteID: noteID,
                    now: moment.instant
                )
            }
            pushUndoEntry(
                with: .poolNoteDelete(
                    chainID: chainID,
                    noteID: noteID,
                    deletedBody: deletedBody
                )
            )
            resolveOperationFailure(.noteMutation)
            showToast(copy.noteDeletedToast)
            return true
        } catch {
            showOperationFailure(.noteMutation, error: error)
            return false
        }
    }

    private func rejectNoteMutation(_ error: TaskNoteMutationTargetError) -> Bool {
        showOperationFailure(.noteMutation, error: error)
        return false
    }

    func setManualProgress(traceID: DayTraceID, percent: Double) {
        guard let trace = engine.traces[traceID] else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .updateProgress
                )
            ) { candidate, moment in
                try candidate.setManualProgress(
                    traceID: traceID,
                    percent: Int(percent.rounded()),
                    today: moment.today,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func addDetailSubtask(traceID: DayTraceID) {
        guard let trace = engine.traces[traceID] else { return }
        let title = detailSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            _ = try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .addSubtask
                )
            ) { candidate, moment in
                try candidate.addSubtask(
                    traceID: traceID,
                    title: title,
                    now: moment.instant
                )
            }
            detailSubtaskText = ""
            showToast(copy.subtaskAdded)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func addPoolPlannedSubtask(chainID: TaskChainID) {
        let title = detailSubtaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return }
        do {
            _ = try commitEngineMutation(
                undoPolicy: .snapshot(.addSubtask)
            ) { candidate, moment in
                try candidate.addPlannedSubtask(
                    chainID: chainID,
                    title: title,
                    now: moment.instant
                )
            }
            detailSubtaskText = ""
            showToast(copy.subtaskAdded)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func removePoolPlannedSubtask(chainID: TaskChainID, plannedSubtaskID: PlannedSubtaskID) {
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.removeSubtask)
            ) { candidate, moment in
                try candidate.removePlannedSubtask(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtaskID,
                    now: moment.instant
                )
            }
            showToast(copy.subtaskUpdated)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func setPoolPlannedSubtaskDifficulty(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        difficulty: SubtaskDifficulty
    ) {
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.updateSubtask)
            ) { candidate, moment in
                try candidate.updatePlannedSubtaskDifficulty(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtaskID,
                    difficulty: difficulty,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }
}

import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime

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

private struct TaskCycleCreationMutation {
    let seriesID: TaskCycleSeriesID
    let classificationCommitBoundaries: [NoonmarkSnapshot]
}

extension NoonmarkStore {
    func beginTaskCycleCreation(
        draft: NewTaskDraft? = nil,
        startDate: LocalDate? = nil
    ) {
        taskCycleCreationRequest = TaskCycleCreationRequest(
            origin: .newTask,
            title: draft?.title ?? "",
            descriptionText: nil,
            plannedSubtasks: [],
            categoryName: draft?.categoryName,
            labelNames: draft?.labelNames ?? [],
            startDate: startDate ?? today,
            locksStartDate: false
        )
        showingTaskCycleCreation = true
    }

    func beginTaskCycleConversion(
        chainID: TaskChainID,
        traceID: DayTraceID? = nil
    ) {
        guard engine.isRecurringTaskChain(chainID) == false,
              let definition = engine.definitions.values
              .filter({
                  $0.chainID == chainID
                      && $0.supersededAt == nil
              })
              .max(by: { $0.sequence < $1.sequence })
        else {
            return
        }
        let sourceTrace = traceID.flatMap { engine.traces[$0] }
        let pendingSource = sourceTrace.flatMap {
            $0.status == .pending && $0.date >= today ? $0 : nil
        }
        let isPooled = engine.taskPool().contains {
            $0.chain.id == chainID
        }
        let classification = currentClassification(for: chainID)
        taskCycleCreationRequest = TaskCycleCreationRequest(
            origin: .existingTask(
                sourceChainID: chainID,
                adoptsSourceChain: pendingSource != nil || isPooled
            ),
            title: definition.title,
            descriptionText:
            sourceTrace?.descriptionText
                ?? definition.descriptionText,
            plannedSubtasks: definition.plannedSubtasks,
            categoryName: classification?.category?.name,
            labelNames: classification?.labels.map(\.name) ?? [],
            startDate: pendingSource?.date ?? today,
            locksStartDate: pendingSource != nil
        )
        showingTaskCycleCreation = true
    }

    func cancelTaskCycleCreation() {
        showingTaskCycleCreation = false
        taskCycleCreationRequest = nil
    }

    @discardableResult
    func createTaskCycleSeries(
        title: String,
        startDate: LocalDate,
        endDate: LocalDate,
        schedule: TaskCycleSchedule
    ) -> Bool {
        createTaskCycleSeries(
            title: title,
            startDate: startDate,
            schedule: schedule,
            endCondition: .onDate(endDate)
        )
    }

    @discardableResult
    func createTaskCycleSeries(
        title: String,
        startDate: LocalDate,
        schedule: TaskCycleSchedule,
        endCondition: TaskCycleEndCondition
    ) -> Bool {
        let request = taskCycleCreationRequest
            ?? TaskCycleCreationRequest(
                origin: .newTask,
                title: title,
                descriptionText: nil,
                plannedSubtasks: [],
                categoryName: nil,
                labelNames: [],
                startDate: startDate,
                locksStartDate: false
            )
        do {
            let mutation = try commitEngineMutation(
                undoPolicy: .invalidate,
                automaticClassificationPolicy:
                .newlyCreatedTaskChains,
                classificationCommitBoundaries: {
                    (mutation: TaskCycleCreationMutation) in
                    mutation.classificationCommitBoundaries.isEmpty
                        ? nil
                        : mutation.classificationCommitBoundaries
                }
            ) { candidate, moment in
                let seriesID: TaskCycleSeriesID
                switch request.origin {
                case .newTask:
                    seriesID = try candidate.createTaskCycleSeries(
                        title: title,
                        descriptionText:
                        request.descriptionText,
                        plannedSubtasks:
                        request.plannedSubtasks,
                        startDate: startDate,
                        schedule: schedule,
                        endCondition: endCondition,
                        today: moment.today,
                        now: moment.instant
                    )
                case let .existingTask(
                    sourceChainID,
                    adoptsSourceChain
                ):
                    if adoptsSourceChain {
                        if request.title.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty {
                            try candidate.renameTaskTitle(
                                chainID: sourceChainID,
                                title: title,
                                today: moment.today,
                                now: moment.instant
                            )
                        }
                        seriesID = try candidate
                            .convertTaskToCycleSeries(
                                chainID: sourceChainID,
                                startDate: startDate,
                                schedule: schedule,
                                endCondition: endCondition,
                                today: moment.today,
                                now: moment.instant
                            )
                    } else {
                        seriesID = try candidate
                            .createTaskCycleSeries(
                                title: title,
                                descriptionText:
                            request.descriptionText,
                                plannedSubtasks:
                            request.plannedSubtasks,
                                startDate: startDate,
                                schedule: schedule,
                                endCondition: endCondition,
                                today: moment.today,
                                now: moment.instant
                            )
                    }
                }
                let adoptedSourceID: TaskChainID? =
                    if case let .existingTask(
                        sourceChainID,
                        true
                    ) = request.origin {
                        sourceChainID
                    } else {
                        nil
                    }
                let targetChainIDs = candidate.chains.values
                    .filter {
                        $0.cycleMembership?.seriesID == seriesID
                            && $0.id != adoptedSourceID
                    }
                    .sorted {
                        guard let lhs = $0.cycleMembership,
                              let rhs = $1.cycleMembership
                        else {
                            return $0.id.description
                                < $1.id.description
                        }
                        return lhs.occurrenceDate
                            < rhs.occurrenceDate
                    }
                    .map(\.id)
                let classificationSourceChainID: TaskChainID? =
                    if case let .existingTask(
                        sourceChainID,
                        _
                    ) = request.origin {
                        sourceChainID
                    } else {
                        nil
                    }
                var boundaries: [NoonmarkSnapshot] = []
                for chainID in targetChainIDs {
                    let didClassify = if let classificationSourceChainID {
                        try candidate.inheritCurrentClassification(
                            from: classificationSourceChainID,
                            to: chainID,
                            now: moment.instant
                        )
                    } else {
                        try applyTaskDraftClassification(
                            to: candidate,
                            chainID: chainID,
                            categoryName: request.categoryName,
                            labelNames: request.labelNames,
                            now: moment.instant
                        )
                    }
                    if didClassify {
                        boundaries.append(candidate.snapshot())
                    }
                }
                let templateClassificationChainID =
                    classificationSourceChainID ?? targetChainIDs.first
                let templateClassification = templateClassificationChainID
                    .flatMap {
                        candidate.snapshot().classifications
                            .currentByChainID[$0]
                    }
                try candidate.setTaskCycleTemplateClassification(
                    seriesID: seriesID,
                    categoryID: templateClassification?.categoryID,
                    labelIDs: templateClassification?.labelIDs ?? [],
                    now: moment.instant
                )
                if boundaries.isEmpty == false {
                    boundaries[boundaries.index(before: boundaries.endIndex)] =
                        candidate.snapshot()
                }
                return TaskCycleCreationMutation(
                    seriesID: seriesID,
                    classificationCommitBoundaries: boundaries
                )
            }
            showingTaskCycleCreation = false
            taskCycleCreationRequest = nil
            if case .existingTask = request.origin {
                showToast(copy.taskConvertedToCycle)
            } else {
                showToast(copy.taskCycleCreated)
            }
            _ = mutation.seriesID
            return true
        } catch {
            showOperationFailure(.taskMutation, error: error)
            return false
        }
    }

    func skipTaskCycleOccurrence(
        seriesID: TaskCycleSeriesID,
        occurrenceDate: LocalDate
    ) {
        do {
            try commitEngineMutation(undoPolicy: .invalidate) {
                candidate,
                moment in
                try candidate.skipTaskCycleOccurrence(
                    seriesID: seriesID,
                    occurrenceDate: occurrenceDate,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showToast(copy.taskCycleOccurrenceSkipped)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func stopTaskCycleSeries(_ seriesID: TaskCycleSeriesID) {
        do {
            let count = try commitEngineMutation(
                undoPolicy: .invalidate
            ) { candidate, moment in
                try candidate.stopTaskCycleSeries(
                    seriesID: seriesID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showToast(copy.taskCycleStopped(count))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func updateTaskCycleTitle(
        seriesID: TaskCycleSeriesID,
        title: String
    ) {
        guard let series = engine.taskCycleSeries[seriesID] else { return }
        updateTaskCycleContent(
            seriesID: seriesID,
            title: title,
            descriptionText: series.descriptionText,
            plannedSubtasks: series.plannedSubtasks
        )
    }

    func updateTaskCycleDescription(
        seriesID: TaskCycleSeriesID,
        descriptionText: String
    ) {
        guard let series = engine.taskCycleSeries[seriesID] else { return }
        updateTaskCycleContent(
            seriesID: seriesID,
            title: series.title,
            descriptionText: descriptionText,
            plannedSubtasks: series.plannedSubtasks
        )
    }

    func addTaskCyclePlannedSubtask(
        seriesID: TaskCycleSeriesID,
        title: String
    ) {
        let normalized = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.isEmpty == false else { return }
        do {
            try commitEngineMutation(undoPolicy: .invalidate) {
                candidate,
                moment in
                guard let series = candidate.taskCycleSeries[seriesID]
                else {
                    throw NoonmarkError.notFound("task cycle series")
                }
                let subtask = PlannedSubtask(
                    title: normalized,
                    position: series.plannedSubtasks.count + 1,
                    now: moment.instant
                )
                try candidate.updateTaskCycleTemplateContent(
                    seriesID: seriesID,
                    title: series.title,
                    descriptionText: series.descriptionText,
                    plannedSubtasks: series.plannedSubtasks + [subtask],
                    today: moment.today,
                    now: moment.instant
                )
            }
            detailSubtaskText = ""
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func removeTaskCyclePlannedSubtask(
        seriesID: TaskCycleSeriesID,
        subtaskID: PlannedSubtaskID
    ) {
        mutateTaskCyclePlannedSubtasks(seriesID: seriesID) {
            $0.removeAll { $0.id == subtaskID }
        }
    }

    func renameTaskCyclePlannedSubtask(
        seriesID: TaskCycleSeriesID,
        subtaskID: PlannedSubtaskID,
        title: String
    ) {
        let normalized = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalized.isEmpty == false else { return }
        mutateTaskCyclePlannedSubtasks(seriesID: seriesID) {
            guard let index = $0.firstIndex(where: {
                $0.id == subtaskID
            }) else {
                return
            }
            $0[index].title = normalized
        }
    }

    func setTaskCyclePlannedSubtaskDifficulty(
        seriesID: TaskCycleSeriesID,
        subtaskID: PlannedSubtaskID,
        difficulty: SubtaskDifficulty
    ) {
        mutateTaskCyclePlannedSubtasks(seriesID: seriesID) {
            guard let index = $0.firstIndex(where: {
                $0.id == subtaskID
            }) else {
                return
            }
            $0[index].difficulty = difficulty
        }
    }

    func reviseTaskCycleSeries(
        seriesID: TaskCycleSeriesID,
        startDate: LocalDate? = nil,
        schedule: TaskCycleSchedule,
        endCondition: TaskCycleEndCondition
    ) -> Bool {
        do {
            _ = try commitEngineMutation(
                undoPolicy: .invalidate,
                classificationCommitBoundaries: {
                    (outcome: TaskCycleRevisionOutcome) in
                    outcome.classificationCommitBoundaries.isEmpty
                        ? nil
                        : outcome.classificationCommitBoundaries
                }
            ) { candidate, moment in
                try candidate.reviseTaskCycleSeries(
                    seriesID: seriesID,
                    startDate: startDate,
                    schedule: schedule,
                    endCondition: endCondition,
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

    private func updateTaskCycleContent(
        seriesID: TaskCycleSeriesID,
        title: String,
        descriptionText: String?,
        plannedSubtasks: [PlannedSubtask]
    ) {
        do {
            try commitEngineMutation(undoPolicy: .invalidate) {
                candidate,
                moment in
                try candidate.updateTaskCycleTemplateContent(
                    seriesID: seriesID,
                    title: title,
                    descriptionText: descriptionText,
                    plannedSubtasks: plannedSubtasks,
                    today: moment.today,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    private func mutateTaskCyclePlannedSubtasks(
        seriesID: TaskCycleSeriesID,
        mutation: (inout [PlannedSubtask]) -> Void
    ) {
        guard let series = engine.taskCycleSeries[seriesID] else { return }
        var subtasks = series.plannedSubtasks
        mutation(&subtasks)
        updateTaskCycleContent(
            seriesID: seriesID,
            title: series.title,
            descriptionText: series.descriptionText,
            plannedSubtasks: subtasks
        )
    }

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
        guard draft.issue == nil else {
            showToast(copy.newTaskMultipleCategories)
            return false
        }
        if draft.command == .recurring {
            let targetDate = switch target {
            case .selectedDate:
                selectedDate
            case .today:
                today
            }
            beginTaskCycleCreation(
                draft: draft,
                startDate: targetDate
            )
            return true
        }
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
                _ = try applyTaskDraftClassification(
                    to: candidate,
                    chainID: chainID,
                    categoryName: draft.categoryName,
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
        guard draft.issue == nil else {
            showToast(copy.newTaskMultipleCategories)
            return
        }
        if draft.command == .recurring {
            beginTaskCycleCreation(draft: draft)
            poolText = ""
            return
        }
        guard draft.title.isEmpty == false else { return }
        do {
            let chainID = try commitEngineMutation(
                undoPolicy: .snapshot(.addPoolTask),
                automaticClassificationPolicy: .newlyCreatedTaskChains
            ) { candidate, moment in
                let chainID = try candidate.createPoolTask(
                    title: draft.title,
                    now: moment.instant
                )
                _ = try applyTaskDraftClassification(
                    to: candidate,
                    chainID: chainID,
                    categoryName: draft.categoryName,
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

    func parsedTaskDraft(_ rawText: String) -> NewTaskDraft {
        NewTaskDraftParser.parse(rawText)
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
        guard canToggleSubtask(subtask) else {
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
        canToggleSubtask(subtask)
    }

    func canToggleSubtask(_ subtask: Subtask) -> Bool {
        guard let trace = engine.traces[subtask.traceID] else { return false }
        return subtask.isUserPresentable
            && trace.date == today
            && trace.status == .pending
            && engine.days[trace.date]?.lockedAt == nil
    }

    func canEditSubtask(_ subtask: Subtask) -> Bool {
        guard let trace = engine.traces[subtask.traceID] else { return false }
        return subtask.isUserPresentable
            && trace.date >= today
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
        guard canEditSubtask(subtask) else {
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

    func renameSubtask(
        _ subtaskID: SubtaskID,
        title: String,
        immediately: Bool = false
    ) {
        guard let subtask = engine.subtasks[subtaskID],
              let trace = engine.traces[subtask.traceID],
              canEditSubtask(subtask)
        else { return }
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately
                    ? .preserve
                    : .snapshotIfAllowed(on: trace.date, action: .updateSubtask)
            ) { candidate, moment in
                try candidate.updateSubtaskTitle(
                    subtaskID,
                    title: nextTitle,
                    today: moment.today,
                    now: moment.instant
                )
            }
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func deleteSubtask(_ subtaskID: SubtaskID) {
        guard let subtask = engine.subtasks[subtaskID],
              let trace = engine.traces[subtask.traceID],
              canEditSubtask(subtask)
        else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: trace.date,
                    action: .removeSubtask
                )
            ) { candidate, moment in
                try candidate.deleteSubtask(
                    subtaskID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            showToast(copy.subtaskUpdated)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func deferTrace(_ traceID: DayTraceID, to date: LocalDate) {
        do {
            let nextID = try commitEngineMutation(
                undoPolicy: .snapshotIfAllowed(
                    on: today,
                    action: .deferTask
                )
            ) { candidate, moment in
                try candidate.deferCurrentTrace(
                    traceID: traceID,
                    targetDate: date,
                    today: moment.today,
                    now: moment.instant
                )
            }
            selectedDate = date
            page = .day
            selectTrace(nextID)
            showToast(copy.deferredTo(displayDate(date)))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func continueUnfinishedTrace(_ traceID: DayTraceID, to date: LocalDate) {
        do {
            let nextID = try commitEngineMutation(
                undoPolicy: .invalidate
            ) { candidate, moment in
                try candidate.continueUnfinishedTrace(
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
            clearSelection()
            showToast(copy.returnedToPool)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func withdrawDeferral(_ sourceTraceID: DayTraceID) {
        do {
            try commitEngineMutation(undoPolicy: .invalidate) { candidate, moment in
                try candidate.withdrawDeferral(
                    sourceTraceID: sourceTraceID,
                    today: moment.today,
                    now: moment.instant
                )
            }
            page = .day
            selectedDate = today
            selectTrace(sourceTraceID)
            showToast(copy.deferralWithdrawn)
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func setTracePinned(_ traceID: DayTraceID, pinned: Bool) {
        do {
            try commitEngineMutation(undoPolicy: .preserve) { candidate, moment in
                if pinned {
                    try candidate.pinDayTrace(
                        traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                } else {
                    try candidate.unpinDayTrace(
                        traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            showToast(pinned ? copy.taskPinned : copy.taskUnpinned)
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
        let classificationPolicy = automaticClassificationPolicyForTitleEdit(
            chainID: trace.chainID,
            nextTitle: nextTitle
        )
        do {
            try commitEngineMutation(
                undoPolicy: immediately
                    ? .preserve
                    : .snapshotIfAllowed(on: trace.date, action: .renameTask),
                automaticClassificationPolicy: classificationPolicy
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
        let classificationPolicy = automaticClassificationPolicyForTitleEdit(
            chainID: chainID,
            nextTitle: nextTitle
        )
        do {
            try commitEngineMutation(
                undoPolicy: immediately ? .preserve : .snapshot(.renameTask),
                automaticClassificationPolicy: classificationPolicy
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

    private func automaticClassificationPolicyForTitleEdit(
        chainID: TaskChainID,
        nextTitle: String
    ) -> EngineMutationAutomaticClassificationPolicy {
        if nextTitle.isEmpty {
            return .taskBecameIneligible(chainID)
        }
        if currentDefinition(for: chainID)?.title.isEmpty == true {
            return .taskBecameEligible(chainID)
        }
        return .taskDefinitionChanged(chainID)
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

    func renamePoolPlannedSubtask(
        chainID: TaskChainID,
        plannedSubtaskID: PlannedSubtaskID,
        title: String,
        immediately: Bool = false
    ) {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextTitle.isEmpty == false else { return }
        do {
            try commitEngineMutation(
                undoPolicy: immediately ? .preserve : .snapshot(.updateSubtask)
            ) { candidate, moment in
                try candidate.updatePlannedSubtaskTitle(
                    chainID: chainID,
                    plannedSubtaskID: plannedSubtaskID,
                    title: nextTitle,
                    now: moment.instant
                )
            }
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

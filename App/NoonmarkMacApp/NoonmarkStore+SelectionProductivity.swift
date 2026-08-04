import AppKit
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime

extension NoonmarkStore {
    func selectPage(_ next: Page) {
        let nextPage = visiblePage(for: next)
        if nextPage == .calendar, page != .calendar {
            isDetailRailExpanded = false
        }
        page = nextPage
        clearSelection()
    }

    func ensureVisiblePage(preferredFallback: Page = .day) {
        let next = visiblePage(for: page, preferredFallback: preferredFallback)
        guard next != page else { return }
        page = next
        clearSelection()
    }

    private func visiblePage(for requested: Page, preferredFallback: Page = .day) -> Page {
        guard requested != .settings else { return .day }
        guard requested != .zhulong || isZhulongEnabled else {
            return [.zhulong, .settings].contains(preferredFallback)
                ? .day
                : preferredFallback
        }
        return requested
    }

    func selectTrace(_ traceID: DayTraceID) {
        selectWorkspaceItem(
            page == .future ? .futureTrace(traceID) : .dayTrace(traceID),
            modifiers: []
        )
    }

    func selectTaskCycleSeries(_ seriesID: TaskCycleSeriesID) {
        selectWorkspaceItem(.taskCycleSeries(seriesID), modifiers: [])
    }

    func userSelectTaskCycleSeries(_ seriesID: TaskCycleSeriesID) {
        selectWorkspaceItem(
            .taskCycleSeries(seriesID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    func userSelectTrace(_ traceID: DayTraceID) {
        selectWorkspaceItem(
            page == .future ? .futureTrace(traceID) : .dayTrace(traceID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    private func prepareDetailRailForSelection(expand: Bool = true) {
        detailSubtaskText = ""
        if expand {
            isDetailRailExpanded = true
        }
    }

    func changedTarget(for trace: DayTrace) -> (trace: DayTrace, definition: TaskDefinition)? {
        guard let targetTraceID = trace.changedToTraceID,
              let targetTrace = engine.traces[targetTraceID],
              let targetDefinition = engine.definitions[targetTrace.definitionID]
        else {
            return nil
        }
        return (targetTrace, targetDefinition)
    }

    func changedSource(for trace: DayTrace) -> (trace: DayTrace, definition: TaskDefinition)? {
        guard let sourceTrace = engine.traces.values.first(where: {
            $0.changedToTraceID == trace.id
        }),
        let sourceDefinition = engine.definitions[sourceTrace.definitionID]
        else {
            return nil
        }
        return (sourceTrace, sourceDefinition)
    }

    func openChangedTarget(from trace: DayTrace) {
        guard let target = changedTarget(for: trace) else { return }
        page = .day
        selectedDate = target.trace.date
        selectedCalendarDate = target.trace.date
        selectTrace(target.trace.id)
    }

    func openChangedSource(from trace: DayTrace) {
        guard let source = changedSource(for: trace) else { return }
        openTaskTrailTrace(source.trace)
    }

    func carryoverSource(for trace: DayTrace) -> DayTrace? {
        trace.carriedFromTraceID.flatMap { engine.traces[$0] }
    }

    func carryoverTarget(for trace: DayTrace) -> DayTrace? {
        engine.carryoverTarget(for: trace.id)
    }

    func openCarryoverSource(from trace: DayTrace) {
        guard let source = carryoverSource(for: trace) else { return }
        openTaskTrailTrace(source)
    }

    func openCarryoverTarget(from trace: DayTrace) {
        guard let target = carryoverTarget(for: trace) else { return }
        openTaskTrailTrace(target)
    }

    func openTaskTrailTrace(_ trace: DayTrace) {
        page = .day
        selectedDate = trace.date
        selectedCalendarDate = trace.date
        clearSelection()
        selectedTraceID = trace.id
        isDetailRailExpanded = true
    }

    func selectPool(_ chainID: TaskChainID) {
        selectWorkspaceItem(.poolTask(chainID), modifiers: [])
    }

    func userSelectPool(_ chainID: TaskChainID) {
        selectWorkspaceItem(
            .poolTask(chainID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    func selectUnfinished(_ chainID: TaskChainID) {
        selectWorkspaceItem(.unfinishedTask(chainID), modifiers: [])
    }

    func userSelectUnfinished(_ chainID: TaskChainID) {
        selectWorkspaceItem(
            .unfinishedTask(chainID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    func selectCompleted(_ traceID: DayTraceID) {
        selectWorkspaceItem(.completedTrace(traceID), modifiers: [])
    }

    func userSelectCompleted(_ traceID: DayTraceID) {
        selectWorkspaceItem(
            .completedTrace(traceID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    func selectCompletedSubtask(_ subtaskID: SubtaskID) {
        selectWorkspaceItem(.completedSubtask(subtaskID), modifiers: [])
    }

    func userSelectCompletedSubtask(_ subtaskID: SubtaskID) {
        selectWorkspaceItem(
            .completedSubtask(subtaskID),
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    func toggleCompletedHierarchyChildren(
        _ hierarchy: CompletedTaskHierarchy
    ) {
        let chainID = hierarchy.chain.id
        if collapsedCompletedHierarchyIDs.remove(chainID) != nil {
            return
        }

        let hiddenSelections = Set(
            hierarchy.completedChildren.map {
                WorkspaceSelectionItem.completedSubtask($0.subtask.id)
            }
        )
        let selectedChildWillBeHidden =
            workspaceSelection.selectedIDs.isDisjoint(
                with: hiddenSelections
            ) == false
        collapsedCompletedHierarchyIDs.insert(chainID)

        guard selectedChildWillBeHidden else { return }
        if let parent = completedHierarchyParentSelection(hierarchy) {
            selectWorkspaceItem(parent, modifiers: [])
        } else {
            clearSelection()
        }
    }

    func isWorkspaceItemSelected(_ item: WorkspaceSelectionItem) -> Bool {
        workspaceSelection.contains(item)
    }

    func userSelectWorkspaceItem(_ item: WorkspaceSelectionItem) {
        selectWorkspaceItem(
            item,
            modifiers: currentWorkspaceSelectionModifiers
        )
    }

    var selectedWorkspaceItemCount: Int {
        workspaceSelection.count
    }

    var canSelectAllWorkspaceItems: Bool {
        showingPicker == nil
            && showingFromPoolPicker == false
            && showingChangeDialog == false
            && showingClassificationManager == false
            && orderedWorkspaceSelectionItems.isEmpty == false
    }

    var canBulkCompleteSelection: Bool {
        let traceIDs = selectedDayTraceIDs
        return traceIDs.count > 1 && traceIDs.allSatisfy { traceID in
            (try? engine.completionCapability(
                for: traceID,
                today: today
            )) == .available(.complete)
        }
    }

    var canBulkScheduleSelectionToday: Bool {
        selectedPoolChainIDs.count > 1
    }

    var canBulkReturnSelectionToPool: Bool {
        let traceIDs = selectedFutureTraceIDs
        return traceIDs.count > 1 && traceIDs.allSatisfy { traceID in
            guard let trace = engine.traces[traceID],
                  engine.isRecurringTaskChain(trace.chainID) == false
            else {
                return false
            }
            return trace.date > today
                && trace.status == .pending
        }
    }

    func completeSelectedTasks() {
        let traceIDs = selectedDayTraceIDs
        guard canBulkCompleteSelection else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.completeTasks(traceIDs.count))
            ) { candidate, moment in
                for traceID in traceIDs {
                    try candidate.markCompleted(
                        traceID: traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            clearSelection()
            showToast(copy.completedSelectedTasksToast(traceIDs.count))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func scheduleSelectedPoolTasksForToday() {
        let chainIDs = selectedPoolChainIDs
        guard canBulkScheduleSelectionToday else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.scheduleTasks(chainIDs.count))
            ) { candidate, moment in
                for chainID in chainIDs {
                    _ = try candidate.scheduleFromPool(
                        chainID: chainID,
                        date: moment.today,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            page = .day
            selectedDate = today
            clearSelection()
            showToast(copy.scheduledSelectedTasksToast(chainIDs.count))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func returnSelectedFutureTasksToPool() {
        let traceIDs = selectedFutureTraceIDs
        guard canBulkReturnSelectionToPool else { return }
        do {
            try commitEngineMutation(
                undoPolicy: .snapshot(.returnTasksToPool(traceIDs.count))
            ) { candidate, moment in
                for traceID in traceIDs {
                    try candidate.returnToPool(
                        traceID: traceID,
                        today: moment.today,
                        now: moment.instant
                    )
                }
            }
            page = .pool
            clearSelection()
            showToast(copy.returnedSelectedTasksToast(traceIDs.count))
        } catch {
            showOperationFailure(.taskMutation, error: error)
        }
    }

    func selectAllWorkspaceItems() {
        workspaceSelection.selectAll(in: orderedWorkspaceSelectionItems)
        applyPrimaryWorkspaceSelection(preferred: workspaceSelection.focusedID)
    }

    func moveWorkspaceSelection(by offset: Int, extendingRange: Bool) {
        workspaceSelection.moveFocus(
            by: offset,
            in: orderedWorkspaceSelectionItems,
            extendingRange: extendingRange
        )
        applyPrimaryWorkspaceSelection(preferred: workspaceSelection.focusedID)
    }

    private var selectedDayTraceIDs: [DayTraceID] {
        orderedWorkspaceSelectionItems.compactMap { item in
            guard case let .dayTrace(traceID) = item,
                  workspaceSelection.contains(item)
            else {
                return nil
            }
            return traceID
        }
    }

    private var selectedFutureTraceIDs: [DayTraceID] {
        orderedWorkspaceSelectionItems.compactMap { item in
            guard case let .futureTrace(traceID) = item,
                  workspaceSelection.contains(item)
            else {
                return nil
            }
            return traceID
        }
    }

    private var selectedPoolChainIDs: [TaskChainID] {
        orderedWorkspaceSelectionItems.compactMap { item in
            guard case let .poolTask(chainID) = item,
                  workspaceSelection.contains(item)
            else {
                return nil
            }
            return chainID
        }
    }

    private var currentWorkspaceSelectionModifiers: WorkspaceSelectionModifiers {
        let eventModifiers = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        var modifiers: WorkspaceSelectionModifiers = []
        if eventModifiers.contains(.command) {
            modifiers.insert(.additive)
        }
        if eventModifiers.contains(.shift) {
            modifiers.insert(.range)
        }
        return modifiers
    }

    private func selectWorkspaceItem(
        _ item: WorkspaceSelectionItem,
        modifiers: WorkspaceSelectionModifiers
    ) {
        let availableItems = orderedWorkspaceSelectionItems
        guard availableItems.contains(item) else {
            clearSelection()
            return
        }
        workspaceSelection.select(
            item,
            in: availableItems,
            modifiers: modifiers
        )
        applyPrimaryWorkspaceSelection(preferred: item)
    }

    private var orderedWorkspaceSelectionItems: [WorkspaceSelectionItem] {
        switch page {
        case .day:
            let preference = TaskCollectionPresentationPreferenceRepository()
                .load(for: .dayTodo)
            let tracesByDescription = Dictionary(
                uniqueKeysWithValues: engine.traces.values.map {
                    ($0.id.description, $0.id)
                }
            )
            return dayTodoPresentationSections(
                date: selectedDate,
                preference: preference
            ).flatMap(\.items).compactMap {
                tracesByDescription[$0.id].map(WorkspaceSelectionItem.dayTrace)
            }
        case .pool:
            return engine.taskPool().map { .poolTask($0.chain.id) }
        case .future:
            return visibleFuturePlanItems().map {
                .futureTrace($0.trace.id)
            }
        case .recurring:
            return engine.taskCycleTracks(today: today)
                .map { .taskCycleSeries($0.id) }
        case .unfinished:
            return engine.unfinishedPool().map {
                .unfinishedTask($0.chain.id)
            }
        case .completed:
            return engine.completedTaskHierarchies()
                .flatMap { hierarchy in
                let parent = completedHierarchyParentSelection(
                    hierarchy
                ).map { [$0] } ?? []
                let children: [WorkspaceSelectionItem] =
                    collapsedCompletedHierarchyIDs.contains(
                        hierarchy.chain.id
                    )
                    ? []
                    : hierarchy.completedChildren.map {
                        WorkspaceSelectionItem.completedSubtask(
                            $0.subtask.id
                        )
                    }
                return parent + children
            }
        case .calendar, .zhulong, .settings, .stickyNotes, .ideas:
            return []
        }
    }

    private func applyPrimaryWorkspaceSelection(
        preferred: WorkspaceSelectionItem?
    ) {
        let preferredSelection = preferred.flatMap { candidate in
            workspaceSelection.contains(candidate) ? candidate : nil
        }
        let primary = preferredSelection ?? orderedWorkspaceSelectionItems.first {
            workspaceSelection.contains($0)
        }
        clearLegacySelection()
        guard let primary else {
            prepareDetailRailForSelection(expand: false)
            return
        }
        switch primary {
        case let .taskCycleSeries(seriesID):
            selectedTaskCycleSeriesID = seriesID
        case let .dayTrace(traceID), let .futureTrace(traceID):
            selectedTraceID = traceID
        case let .poolTask(chainID):
            selectedPoolChainID = chainID
        case let .unfinishedTask(chainID):
            selectedUnfinishedChainID = chainID
        case let .completedTrace(traceID):
            selectedCompletedTraceID = traceID
            selectedTraceID = traceID
        case let .completedSubtask(subtaskID):
            selectedCompletedSubtaskID = subtaskID
            selectedTraceID = engine.completedSubtaskRecords()
                .first { $0.subtask.id == subtaskID }?
                .parentTrace.id
        }
        prepareDetailRailForSelection()
    }

    private func clearLegacySelection() {
        selectedTaskCycleSeriesID = nil
        selectedTraceID = nil
        selectedPoolChainID = nil
        selectedUnfinishedChainID = nil
        selectedCompletedTraceID = nil
        selectedCompletedSubtaskID = nil
        detailSubtaskText = ""
        detailNoteText = ""
    }

    func selectItemForLaunch(_ selectionName: String) {
        switch page {
        case .day:
            selectLaunchDayItem(selectionName)
        case .future:
            selectLaunchFutureItem()
        case .recurring:
            if let seriesID = engine.taskCycleTracks(today: today).first?.id {
                selectTaskCycleSeries(seriesID)
            }
        case .pool:
            selectLaunchPoolItem()
        case .unfinished:
            selectLaunchUnfinishedItem()
        case .completed:
            selectLaunchCompletedItem()
        case .calendar, .zhulong, .settings, .stickyNotes, .ideas:
            break
        }
    }

    private func selectLaunchDayItem(_ selectionName: String) {
        let latestChangedTrace = engine.traces.values
            .filter { $0.status == .changed && $0.changedToTraceID != nil }
            .sorted { $0.date > $1.date }
            .first
        if selectionName == "changed", let changedTrace = latestChangedTrace {
            selectedDate = changedTrace.date
            selectTrace(changedTrace.id)
            return
        }

        let traces = engine.getDayTodo(date: selectedDate).traces
        let trace = selectionName == "manual"
            ? traces.first { subtasks(for: $0.id).isEmpty && $0.status == .pending }
            : traces.first
        if let trace {
            selectTrace(trace.id)
        }
    }

    private func selectLaunchFutureItem() {
        if let trace = visibleFuturePlanItems().first?.trace {
            selectTrace(trace.id)
        }
    }

    private func selectLaunchPoolItem() {
        if let task = engine.taskPool().first {
            selectPool(task.chain.id)
        }
    }

    private func selectLaunchUnfinishedItem() {
        if let item = engine.unfinishedPool().first {
            selectUnfinished(item.chain.id)
        }
    }

    private func selectLaunchCompletedItem() {
        if let item = engine.completedPool().first {
            selectCompleted(item.trace.id)
        }
    }

    func clearSelection() {
        workspaceSelection.clear()
        clearLegacySelection()
    }

    func resetLaunchSelection() {
        selectedDate = today
        selectedCalendarDate = today
        clearSelection()
    }

    func normalizeSelection() {
        workspaceSelection.retainOnly(orderedWorkspaceSelectionItems)
        applyPrimaryWorkspaceSelection(preferred: workspaceSelection.focusedID)
    }
}

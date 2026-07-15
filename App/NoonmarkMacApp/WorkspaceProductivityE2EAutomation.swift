import AppKit
import CoreGraphics
import Foundation
import NoonmarkCore
import NoonmarkStorage

@MainActor
enum WorkspaceDragE2EDiagnostics {
    private enum Event {
        case target(DayTraceID, Bool)
        case drop(DayTraceID, [DayTraceID], Bool)

        var report: String {
            switch self {
            case let .target(traceID, isTargeted):
                "target=\(traceID.description):\(isTargeted)"
            case let .drop(targetTraceID, itemTraceIDs, accepted):
                "drop=\(targetTraceID.description)"
                    + "<-[\(itemTraceIDs.map(\.description).joined(separator: ","))]"
                    + ":\(accepted)"
            }
        }
    }

    private static var events: [Event] = []
    private(set) static var pointerEvidence: [String] = []

    static var isEnabled: Bool {
        AppLaunchArguments.contains("--e2e-workspace-productivity-exercise")
    }

    static func reset() {
        events = []
        pointerEvidence = []
    }

    static func recordTarget(traceID: DayTraceID, isTargeted: Bool) {
        guard isEnabled else { return }
        events.append(.target(traceID, isTargeted))
    }

    static func recordDrop(
        targetTraceID: DayTraceID,
        items: [TaskPriorityDragItem],
        accepted: Bool
    ) {
        guard isEnabled else { return }
        events.append(
            .drop(
                targetTraceID,
                items.map(\.traceID),
                accepted
            )
        )
    }

    static func recordPointerEvidence(_ evidence: String) {
        guard isEnabled else { return }
        pointerEvidence.append(evidence)
    }

    static var report: String {
        [
            "events=[\(events.map(\.report).joined(separator: ";"))]",
            "pointer=[\(pointerEvidence.joined(separator: ";"))]"
        ].joined(separator: " ")
    }

    static var hasNativePathActivity: Bool {
        events.isEmpty == false
    }

    static func completedNativePath(
        sourceTraceID: DayTraceID,
        targetTraceID: DayTraceID
    ) -> Bool {
        guard let targetIndex = events.firstIndex(where: {
            if case .target(targetTraceID, true) = $0 { return true }
            return false
        }), let dropIndex = events[targetIndex...].firstIndex(where: {
            if case .drop(targetTraceID, [sourceTraceID], true) = $0 {
                return true
            }
            return false
        }) else {
            return false
        }
        return targetIndex < dropIndex
    }
}

@MainActor
private final class WorkspaceDragEventPump: NSObject {
    private let window: NSWindow
    private let points: [NSPoint]
    private let targetPoint: NSPoint
    private let originalCursorPoint: CGPoint?
    private let eventNumberBase: Int
    private var index = 0
    private var lastLocation: NSPoint
    private var postedMouseDown = false
    private var postedMouseUp = false
    private var isFinishing = false
    private var motionTimer: Timer?
    private var finalizationTimer: Timer?

    private(set) var failure: String?
    private(set) var isFinalized = false

    init(window: NSWindow, sourcePoint: NSPoint, targetPoint: NSPoint) {
        self.window = window
        self.targetPoint = targetPoint
        lastLocation = sourcePoint
        points = (1 ... 24).map { step in
            let progress = CGFloat(step) / 24
            return NSPoint(
                x: sourcePoint.x + (targetPoint.x - sourcePoint.x) * progress,
                y: sourcePoint.y + (targetPoint.y - sourcePoint.y) * progress
            )
        } + Array(repeating: targetPoint, count: 6)
        originalCursorPoint = CGEvent(source: nil)?.location
        eventNumberBase = Int(ProcessInfo.processInfo.systemUptime * 1000)
        super.init()
    }

    func start(with mouseDown: NSEvent) throws {
        guard let sourceCursorPoint = mouseDown.cgEvent?.location else {
            throw WorkspaceProductivityE2EAutomation.Failure.failed(
                "drag start event did not expose a WindowServer cursor location"
            )
        }
        let error = CGWarpMouseCursorPosition(sourceCursorPoint)
        guard error == .success else {
            throw WorkspaceProductivityE2EAutomation.Failure.failed(
                "could not place the WindowServer cursor at the drag source: \(error.rawValue)"
            )
        }
        guard let targetEvent = makeEvent(
            type: .leftMouseDragged,
            location: targetPoint,
            pressure: 1,
            eventNumber: eventNumberBase
        ), let targetCursorPoint = targetEvent.cgEvent?.location else {
            restoreCursor()
            throw WorkspaceProductivityE2EAutomation.Failure.failed(
                "drag target did not expose a WindowServer cursor location"
            )
        }
        WorkspaceDragE2EDiagnostics.recordPointerEvidence(
            "cursor-source=\(sourceCursorPoint),cursor-target=\(targetCursorPoint)"
        )
        window.postEvent(mouseDown, atStart: false)
        postedMouseDown = true

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(postNextEvent(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func postNextEvent(_ timer: Timer) {
        guard isFinishing == false else {
            timer.invalidate()
            return
        }
        if index < points.count {
            postDragEvent(timer)
        } else {
            postMouseUpAndFinish(timer)
        }
    }

    func cancel() {
        guard isFinalized == false else { return }
        beginFinishing(
            motionTimer,
            failure: failure ?? "drag event pump was cancelled before completion"
        )
    }

    private func postDragEvent(_ timer: Timer) {
        let location = points[index]
        let eventNumber = eventNumberBase + index + 1
        guard let event = makeEvent(
            type: .leftMouseDragged,
            location: location,
            pressure: 1,
            eventNumber: eventNumber
        ), let cursorPoint = event.cgEvent?.location else {
            beginFinishing(
                timer,
                failure: "drag movement \(index) could not form a WindowServer event"
            )
            return
        }
        let error = CGWarpMouseCursorPosition(cursorPoint)
        guard error == .success else {
            beginFinishing(
                timer,
                failure: "drag movement \(index) could not move the WindowServer cursor: \(error.rawValue)"
            )
            return
        }
        lastLocation = location
        index += 1
        window.postEvent(event, atStart: false)
    }

    private func postMouseUpAndFinish(_ timer: Timer) {
        let eventNumber = eventNumberBase + index + 1
        guard let event = makeEvent(
            type: .leftMouseUp,
            location: targetPoint,
            pressure: 0,
            eventNumber: eventNumber
        ), let cursorPoint = event.cgEvent?.location else {
            beginFinishing(
                timer,
                failure: "drag completion could not form a WindowServer event"
            )
            return
        }
        let error = CGWarpMouseCursorPosition(cursorPoint)
        guard error == .success else {
            beginFinishing(
                timer,
                failure: "drag completion could not move the WindowServer cursor: \(error.rawValue)"
            )
            return
        }
        lastLocation = targetPoint
        postedMouseUp = true
        window.postEvent(event, atStart: false)
        beginFinishing(timer, failure: nil)
    }

    private func beginFinishing(_ timer: Timer?, failure: String?) {
        guard isFinishing == false else { return }
        isFinishing = true
        timer?.invalidate()
        motionTimer?.invalidate()
        motionTimer = nil
        if let failure {
            self.failure = failure
            WorkspaceDragE2EDiagnostics.recordPointerEvidence(
                "event-pump-failure=\(failure)"
            )
        }
        postBestEffortMouseUpIfNeeded()

        let finalizationTimer = Timer(
            timeInterval: 0,
            target: self,
            selector: #selector(finalizeAfterEventTracking(_:)),
            userInfo: nil,
            repeats: false
        )
        finalizationTimer.tolerance = 0
        self.finalizationTimer = finalizationTimer
        RunLoop.main.add(finalizationTimer, forMode: .default)
    }

    private func postBestEffortMouseUpIfNeeded() {
        guard postedMouseDown, postedMouseUp == false else { return }
        let eventNumber = eventNumberBase + index + 1
        guard let event = makeEvent(
            type: .leftMouseUp,
            location: lastLocation,
            pressure: 0,
            eventNumber: eventNumber
        ) else {
            self.failure = failure
                ?? "drag cleanup could not form a mouse-up event"
            return
        }
        if let cursorPoint = event.cgEvent?.location {
            let error = CGWarpMouseCursorPosition(cursorPoint)
            if error != .success {
                self.failure = failure
                    ?? "drag cleanup could not move the WindowServer cursor: \(error.rawValue)"
                WorkspaceDragE2EDiagnostics.recordPointerEvidence(
                    "cursor-cleanup-failed=\(error.rawValue)"
                )
            }
        }
        postedMouseUp = true
        window.postEvent(event, atStart: false)
    }

    @objc private func finalizeAfterEventTracking(_ timer: Timer) {
        timer.invalidate()
        finalizationTimer = nil
        if let originalCursorPoint {
            let error = CGWarpMouseCursorPosition(originalCursorPoint)
            if error != .success, failure == nil {
                failure = "drag cleanup could not restore the original cursor: \(error.rawValue)"
            }
        }
        isFinalized = true
        WorkspaceDragE2EDiagnostics.recordPointerEvidence("event-pump-finalized=true")
    }

    private func makeEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        pressure: Float,
        eventNumber: Int
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: pressure
        )
    }

    private func restoreCursor() {
        guard let originalCursorPoint else { return }
        let error = CGWarpMouseCursorPosition(originalCursorPoint)
        if error != .success {
            WorkspaceDragE2EDiagnostics.recordPointerEvidence(
                "cursor-restore-failed=\(error.rawValue)"
            )
        }
    }
}

/// Drives workspace selection, bulk actions, and priority drag/drop through the
/// real app window. Direct Store access is limited to fixture setup, failpoint
/// control, and assertions that cannot be observed through accessibility.
@MainActor
struct WorkspaceProductivityE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let reorderedDayTraceIDs: [String]
        let scheduledPoolChainIDs: [String]
        let returnedFutureChainIDs: [String]
    }

    private struct Fixture {
        let engine: NoonmarkEngine
        let dayTraceIDs: [DayTraceID]
        let poolChainIDs: [TaskChainID]
        let futureTraceIDs: [DayTraceID]
        let futureChainIDs: [TaskChainID]
    }

    fileprivate enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private static let dayTitles = [
        "E2E workspace drag A",
        "E2E workspace drag B",
        "E2E workspace drag C",
        "E2E workspace drag D"
    ]
    private static let poolTitles = [
        "E2E workspace pool A",
        "E2E workspace pool B",
        "E2E workspace pool C"
    ]
    private static let futureTitles = [
        "E2E workspace future A",
        "E2E workspace future B",
        "E2E workspace future C"
    ]

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains("--e2e-workspace-productivity-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-workspace-productivity-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-workspace-productivity-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-workspace-productivity-result-url"
        ) else {
            return nil
        }
        return Self(
            mode: mode,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .exercise:
                    try await exercise(on: store)
                case .verifyRestart:
                    try await verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let window = try await visibleMainWindow()
        let fixture = try makeFixture(today: store.today)
        store.engine = fixture.engine
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.persist()

        guard try persistedSnapshot() == fixture.engine.snapshot() else {
            throw Failure.failed("workspace fixture was not committed to SQLite")
        }
        try await waitForRows(
            fixture.dayTraceIDs.map(dayIdentifier),
            failure: "day workspace rows did not render"
        )

        try await exercisePointerSelection(
            store: store,
            traceIDs: fixture.dayTraceIDs
        )
        try await exerciseKeyboardSelection(
            store: store,
            window: window,
            traceIDs: fixture.dayTraceIDs
        )
        try await exerciseSelectAllCommand(
            store: store,
            window: window,
            traceIDs: fixture.dayTraceIDs
        )

        try await ensureMainWindowActive(window)
        WorkspaceDragE2EDiagnostics.reset()
        let dragPump = try drag(
            from: dayIdentifier(fixture.dayTraceIDs[3]),
            to: dayIdentifier(fixture.dayTraceIDs[0])
        )
        defer { dragPump.cancel() }
        try await waitUntil("drag event pump did not finalize") {
            dragPump.isFinalized
        }
        if let failure = dragPump.failure {
            throw Failure.failed(
                "drag event pump failed: \(failure); "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        let reorderedDayTraceIDs = [fixture.dayTraceIDs[3]]
            + Array(fixture.dayTraceIDs[0 ... 2])
        do {
            try await waitUntil("drag/drop did not reorder the day workspace") {
                store.engine.getDayTodo(date: store.today).traces
                    .filter { fixture.dayTraceIDs.contains($0.id) }
                    .map(\.id) == reorderedDayTraceIDs
            }
        } catch {
            throw Failure.failed(
                "drag/drop did not reorder the day workspace; "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        guard WorkspaceDragE2EDiagnostics.completedNativePath(
            sourceTraceID: fixture.dayTraceIDs[3],
            targetTraceID: fixture.dayTraceIDs[0]
        ) else {
            throw Failure.failed(
                "drag/drop reordered without completing the native path; "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        guard try persistedSnapshot() == store.engine.snapshot() else {
            throw Failure.failed(
                "drag/drop did not commit its exact reordered snapshot to SQLite"
            )
        }
        try assertContiguousPriorities(
            reorderedDayTraceIDs,
            in: store.engine
        )

        try await exerciseAtomicBulkCompletion(
            store: store,
            traceIDs: fixture.dayTraceIDs
        )
        try await exerciseTerminalPriorityDragRejection(
            store: store,
            window: window,
            traceIDs: fixture.dayTraceIDs
        )
        try await exercisePoolScheduling(
            store: store,
            chainIDs: fixture.poolChainIDs
        )
        try await exerciseFutureReturn(
            store: store,
            traceIDs: fixture.futureTraceIDs,
            chainIDs: fixture.futureChainIDs
        )

        try writeState(
            ProbeState(
                reorderedDayTraceIDs: reorderedDayTraceIDs.map(\.description),
                scheduledPoolChainIDs: fixture.poolChainIDs.map(\.description),
                returnedFutureChainIDs: fixture.futureChainIDs.map(\.description)
            )
        )
    }

    private func exercisePointerSelection(
        store: NoonmarkStore,
        traceIDs: [DayTraceID]
    ) async throws {
        try click(dayIdentifier(traceIDs[0]))
        try await waitForSelection(
            store,
            expected: [.dayTrace(traceIDs[0])]
        )

        try click(dayIdentifier(traceIDs[2]), modifiers: .shift)
        try await waitForSelection(
            store,
            expected: traceIDs[0 ... 2].map { .dayTrace($0) },
            visibleCount: 3
        )

        try click(dayIdentifier(traceIDs[1]), modifiers: .command)
        try await waitForSelection(
            store,
            expected: [.dayTrace(traceIDs[0]), .dayTrace(traceIDs[2])],
            visibleCount: 2
        )
    }

    private func exerciseKeyboardSelection(
        store: NoonmarkStore,
        window: NSWindow,
        traceIDs: [DayTraceID]
    ) async throws {
        try click(dayIdentifier(traceIDs[1]))
        try await waitForSelection(
            store,
            expected: [.dayTrace(traceIDs[1])]
        )
        try await waitUntil("workspace row did not become the non-text responder") {
            self.activeTextResponder(in: window) == nil
        }

        try sendArrow(keyCode: 125, window: window)
        try await waitForSelection(
            store,
            expected: [.dayTrace(traceIDs[2])]
        )
        guard store.workspaceSelection.focusedID == .dayTrace(traceIDs[2]) else {
            throw Failure.failed("Down Arrow did not move workspace focus")
        }

        try sendArrow(keyCode: 126, window: window)
        try await waitForSelection(
            store,
            expected: [.dayTrace(traceIDs[1])]
        )
        guard store.workspaceSelection.focusedID == .dayTrace(traceIDs[1]) else {
            throw Failure.failed("Up Arrow did not move workspace focus")
        }
    }

    private func exerciseSelectAllCommand(
        store: NoonmarkStore,
        window: NSWindow,
        traceIDs: [DayTraceID]
    ) async throws {
        try await ensureMainWindowActive(window)
        guard activeTextResponder(in: window) == nil else {
            throw Failure.failed("Command-A probe still had a text responder")
        }
        try performMenuShortcut(key: "a", keyCode: 0, modifiers: .command)
        try await waitForSelection(
            store,
            expected: traceIDs.map { .dayTrace($0) },
            visibleCount: traceIDs.count
        )
    }

    private func exerciseAtomicBulkCompletion(
        store: NoonmarkStore,
        traceIDs: [DayTraceID]
    ) async throws {
        guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
            throw Failure.failed("main window disappeared before bulk completion")
        }
        try await ensureMainWindowActive(window)
        try performMenuShortcut(key: "a", keyCode: 0, modifiers: .command)
        try await waitForSelection(
            store,
            expected: traceIDs.map { .dayTrace($0) },
            visibleCount: traceIDs.count
        )

        let baseline = store.engine.snapshot()
        let baselineSelection = store.workspaceSelection
        try store.armPersistenceFailureForE2E()
        do {
            try click("workspace.bulk.complete.e2e")
            try await waitUntil("failed bulk completion did not publish its failure") {
                store.operationFailure != nil
            }
            guard store.engine.snapshot() == baseline,
                  store.workspaceSelection == baselineSelection,
                  try persistedSnapshot() == baseline,
                  selectionCountVerification() == traceIDs.count
            else {
                throw Failure.failed(
                    "save failure changed the engine, SQLite, or selection"
                )
            }
        } catch {
            store.disarmPersistenceFailureForE2E()
            throw error
        }
        store.disarmPersistenceFailureForE2E()

        try click("workspace.bulk.complete.e2e")
        try await waitUntil("bulk completion did not complete every selected task") {
            traceIDs.allSatisfy { store.engine.traces[$0]?.status == .completed }
                && store.workspaceSelection.isEmpty
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "workspace.selection.count.e2e"
                )
        }
    }

    private func exerciseTerminalPriorityDragRejection(
        store: NoonmarkStore,
        window: NSWindow,
        traceIDs: [DayTraceID]
    ) async throws {
        try await ensureMainWindowActive(window)
        try await waitForRows(
            traceIDs.map(dayIdentifier),
            failure: "completed day rows did not remain visible for drag rejection"
        )
        let baseline = store.engine.snapshot()
        guard traceIDs.allSatisfy({ store.engine.traces[$0]?.status == .completed }),
              try persistedSnapshot() == baseline
        else {
            throw Failure.failed(
                "terminal drag rejection did not start from persisted completed facts"
            )
        }

        WorkspaceDragE2EDiagnostics.reset()
        let dragPump = try drag(
            from: dayIdentifier(traceIDs[0]),
            to: dayIdentifier(traceIDs[1])
        )
        defer { dragPump.cancel() }
        try await waitUntil("terminal drag event pump did not finalize") {
            dragPump.isFinalized
        }
        if let failure = dragPump.failure {
            throw Failure.failed(
                "terminal drag rejection pump failed: \(failure); "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        guard WorkspaceDragE2EDiagnostics.hasNativePathActivity == false else {
            throw Failure.failed(
                "completed day rows still exposed a native priority drag path; "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        guard store.engine.snapshot() == baseline,
              try persistedSnapshot() == baseline
        else {
            throw Failure.failed(
                "completed-row drag attempt changed memory or SQLite"
            )
        }
    }

    private func exercisePoolScheduling(
        store: NoonmarkStore,
        chainIDs: [TaskChainID]
    ) async throws {
        try click("sidebar.nav.pool")
        try await waitUntil("Task Pool navigation did not complete") {
            store.page == .pool
        }
        try await waitForRows(
            chainIDs.map(poolIdentifier),
            failure: "pool workspace rows did not render"
        )

        try click(poolIdentifier(chainIDs[0]))
        try click(poolIdentifier(chainIDs[2]), modifiers: .shift)
        try await waitForSelection(
            store,
            expected: chainIDs.map { .poolTask($0) },
            visibleCount: chainIDs.count
        )
        try click("workspace.bulk.schedule-today.e2e")
        try await waitUntil("bulk Task Pool scheduling did not reach today") {
            store.page == .day
                && chainIDs.allSatisfy { chainID in
                    store.engine.traces.values.contains {
                        $0.chainID == chainID
                            && $0.date == store.today
                            && $0.status == .pending
                    }
                }
                && store.workspaceSelection.isEmpty
        }
    }

    private func exerciseFutureReturn(
        store: NoonmarkStore,
        traceIDs: [DayTraceID],
        chainIDs: [TaskChainID]
    ) async throws {
        try click("sidebar.nav.future")
        try await waitUntil("Future navigation did not complete") {
            store.page == .future
        }
        try await waitForRows(
            traceIDs.map(futureIdentifier),
            failure: "future workspace rows did not render"
        )

        try click(futureIdentifier(traceIDs[0]))
        try click(futureIdentifier(traceIDs[2]), modifiers: .shift)
        try await waitForSelection(
            store,
            expected: traceIDs.map { .futureTrace($0) },
            visibleCount: traceIDs.count
        )
        try click("workspace.bulk.return-pool.e2e")
        try await waitUntil("bulk future return did not reach the Task Pool") {
            store.page == .pool
                && traceIDs.allSatisfy {
                    store.engine.traces[$0]?.status == .returnedToPool
                }
                && chainIDs.allSatisfy { chainID in
                    store.engine.taskPool().contains { $0.chain.id == chainID }
                }
                && store.workspaceSelection.isEmpty
        }
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        let state = try readState()
        let reorderedIDs = try state.reorderedDayTraceIDs.map(dayTraceID)
        let scheduledPoolIDs = try state.scheduledPoolChainIDs.map(taskChainID)
        let returnedFutureIDs = try state.returnedFutureChainIDs.map(taskChainID)
        let returnedFutureTasksArePooled = returnedFutureIDs.allSatisfy { chainID in
            store.engine.taskPool().contains { $0.chain.id == chainID }
        }
        let completedTasksWereRetained = reorderedIDs.allSatisfy {
            store.engine.traces[$0]?.status == .completed
        }
        let scheduledTasksWereRetained = scheduledPoolIDs.allSatisfy { chainID in
            store.engine.traces.values.contains {
                $0.chainID == chainID
                    && $0.date == store.today
                    && $0.status == .pending
            }
        }
        let restartStateIsValid = try persistedSnapshot() == store.engine.snapshot()
            && completedTasksWereRetained
            && scheduledTasksWereRetained
            && returnedFutureTasksArePooled
        guard restartStateIsValid else {
            throw Failure.failed("restarted engine did not retain bulk operations")
        }

        let persistedOrder = store.engine.getDayTodo(date: store.today).traces
            .filter { reorderedIDs.contains($0.id) }
            .map(\.id)
        guard persistedOrder == reorderedIDs else {
            throw Failure.failed("restarted engine did not retain drag order")
        }

        store.page = .day
        store.selectedDate = store.today
        store.clearSelection()
        let rowIdentifiers = reorderedIDs.map(dayIdentifier)
        try await waitForRows(
            rowIdentifiers,
            failure: "restarted day rows did not render"
        )
        let rowFrames = try rowIdentifiers.map { identifier -> NSRect in
            guard let row = AppViewTreeE2E.view(identifier: identifier) else {
                throw Failure.failed("missing restarted row \(identifier)")
            }
            return AppViewTreeE2E.frameInWindow(for: row)
        }
        guard zip(rowFrames, rowFrames.dropFirst()).allSatisfy({ pair in
            pair.0.midY > pair.1.midY
        }) else {
            throw Failure.failed("restarted visible rows did not retain drag order")
        }
    }

    private func makeFixture(today: LocalDate) throws -> Fixture {
        let engine = NoonmarkEngine()
        let futureDate = NoonmarkStore.offset(today, by: 1)
        var timestamp = Date(timeIntervalSince1970: 1_783_267_200)
        func nextInstant() -> Date {
            defer { timestamp = timestamp.addingTimeInterval(1) }
            return timestamp
        }

        var dayTraceIDs: [DayTraceID] = []
        for title in Self.dayTitles {
            let chainID = try engine.createPoolTask(title: title, now: nextInstant())
            dayTraceIDs.append(
                try engine.scheduleFromPool(
                    chainID: chainID,
                    date: today,
                    today: today,
                    now: nextInstant()
                )
            )
        }

        let poolChainIDs = try Self.poolTitles.map { title in
            try engine.createPoolTask(title: title, now: nextInstant())
        }

        var futureTraceIDs: [DayTraceID] = []
        var futureChainIDs: [TaskChainID] = []
        for title in Self.futureTitles {
            let chainID = try engine.createPoolTask(title: title, now: nextInstant())
            let traceID = try engine.scheduleFromPool(
                chainID: chainID,
                date: futureDate,
                today: today,
                now: nextInstant()
            )
            futureChainIDs.append(chainID)
            futureTraceIDs.append(traceID)
        }

        return Fixture(
            engine: engine,
            dayTraceIDs: dayTraceIDs,
            poolChainIDs: poolChainIDs,
            futureTraceIDs: futureTraceIDs,
            futureChainIDs: futureChainIDs
        )
    }

    private func waitForSelection(
        _ store: NoonmarkStore,
        expected: [NoonmarkStore.WorkspaceSelectionItem],
        visibleCount: Int? = nil
    ) async throws {
        let expectedIDs = Set(expected)
        try await waitUntil("workspace selection did not settle") {
            guard store.workspaceSelection.selectedIDs == expectedIDs else {
                return false
            }
            guard let visibleCount else { return true }
            return self.selectionCountVerification() == visibleCount
        }
    }

    private func waitForRows(
        _ identifiers: [String],
        failure: String
    ) async throws {
        try await waitUntil(failure) {
            identifiers.allSatisfy { AppViewTreeE2E.view(identifier: $0) != nil }
        }
    }

    private func selectionCountVerification() -> Int? {
        guard let anchor = AppViewTreeE2E.view(
            identifier: "workspace.selection.count.e2e"
        ), let text = AppViewTreeE2E.verificationText(for: anchor)
        else {
            return nil
        }
        return Int(text)
    }

    private func click(
        _ identifier: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws {
        guard let view = AppViewTreeE2E.view(identifier: identifier),
              let window = view.window
        else {
            throw Failure.failed("missing visible click target \(identifier)")
        }
        let point = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: modifiers,
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            throw Failure.failed("could not create click events for \(identifier)")
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    private func drag(
        from sourceIdentifier: String,
        to targetIdentifier: String
    ) throws -> WorkspaceDragEventPump {
        guard let source = AppViewTreeE2E.view(identifier: sourceIdentifier),
              let target = AppViewTreeE2E.view(identifier: targetIdentifier),
              let window = source.window,
              target.window === window,
              window.isVisible,
              window.isMiniaturized == false,
              window.isKeyWindow,
              NSApp.isActive
        else {
            throw Failure.failed("drag source or destination was unavailable")
        }
        let sourcePoint = source.convert(
            NSPoint(x: source.bounds.midX, y: source.bounds.midY),
            to: nil
        )
        let targetPoint = target.convert(
            NSPoint(x: target.bounds.midX, y: target.bounds.midY),
            to: nil
        )
        let root = window.contentView?.superview ?? window.contentView
        let sourceHit = root?.hitTest(sourcePoint)
        let targetHit = root?.hitTest(targetPoint)
        guard sourceHit != nil, targetHit != nil else {
            throw Failure.failed("drag source or destination was outside the window hit-test tree")
        }
        WorkspaceDragE2EDiagnostics.recordPointerEvidence(
            "source=\(sourcePoint),hit=\(sourceHit.map { String(describing: type(of: $0)) } ?? "nil")"
        )
        WorkspaceDragE2EDiagnostics.recordPointerEvidence(
            "target=\(targetPoint),hit=\(targetHit.map { String(describing: type(of: $0)) } ?? "nil")"
        )
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: sourcePoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: Int(timestamp * 1000),
            clickCount: 1,
            pressure: 1
        ) else {
            throw Failure.failed("could not create drag start event")
        }

        let eventPump = WorkspaceDragEventPump(
            window: window,
            sourcePoint: sourcePoint,
            targetPoint: targetPoint
        )
        try eventPump.start(with: down)
        return eventPump
    }

    private func sendArrow(keyCode: UInt16, window: NSWindow) throws {
        guard let scalar = UnicodeScalar(
            keyCode == 125 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        ) else {
            throw Failure.failed("could not create arrow character")
        }
        let characters = String(scalar)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ), let up = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw Failure.failed("could not create arrow key events")
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func performMenuShortcut(
        key: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) throws {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: modifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: key,
                  charactersIgnoringModifiers: key,
                  isARepeat: false,
                  keyCode: keyCode
              ), NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        else {
            throw Failure.failed("native menu rejected \(modifiers)+\(key)")
        }
    }

    private func activeTextResponder(in window: NSWindow) -> NSTextView? {
        (NSApp.keyWindow?.firstResponder as? NSTextView)
            ?? (window.firstResponder as? NSTextView)
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var window: NSWindow?
        try await waitUntil("main window was not visible") {
            window = NSApp.windows.first {
                $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
            }
            return window != nil
        }
        guard let window else {
            throw Failure.failed("main window disappeared")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func ensureMainWindowActive(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not become active and key") {
            NSApp.isActive && window.isMainWindow && window.isKeyWindow
        }
    }

    private func assertContiguousPriorities(
        _ traceIDs: [DayTraceID],
        in engine: NoonmarkEngine
    ) throws {
        let priorities = traceIDs.compactMap { engine.traces[$0]?.priority }
        guard priorities == Array(1 ... traceIDs.count) else {
            throw Failure.failed("drag/drop did not normalize contiguous priorities")
        }
    }

    private func persistedSnapshot() throws -> NoonmarkSnapshot {
        guard let path = AppLaunchArguments.value(after: "--data-url") else {
            throw Failure.failed("workspace productivity E2E requires --data-url")
        }
        return try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: path)
        ).load().snapshot()
    }

    private func dayTraceID(_ value: String) throws -> DayTraceID {
        guard let uuid = UUID(uuidString: value) else {
            throw Failure.failed("invalid persisted day trace ID \(value)")
        }
        return DayTraceID(uuid)
    }

    private func taskChainID(_ value: String) throws -> TaskChainID {
        guard let uuid = UUID(uuidString: value) else {
            throw Failure.failed("invalid persisted task chain ID \(value)")
        }
        return TaskChainID(uuid)
    }

    private func dayIdentifier(_ traceID: DayTraceID) -> String {
        "workspace.item.day.\(traceID.description)"
    }

    private func poolIdentifier(_ chainID: TaskChainID) -> String {
        "workspace.item.pool.\(chainID.description)"
    }

    private func futureIdentifier(_ traceID: DayTraceID) -> String {
        "workspace.item.future.\(traceID.description)"
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeState(_ state: ProbeState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> ProbeState {
        try JSONDecoder().decode(ProbeState.self, from: Data(contentsOf: stateURL))
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

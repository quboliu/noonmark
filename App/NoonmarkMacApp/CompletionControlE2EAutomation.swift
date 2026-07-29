import AppKit
import ApplicationServices
import Foundation
import NoonmarkCore
import NoonmarkStorage

/// Exercises the parent completion control and its subtask gate through the
/// real signed app window. Store access is limited to fixture setup and
/// assertions; every user mutation is delivered through WindowServer input.
@MainActor
struct CompletionControlE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let traceID: UUID
        let subtaskID: UUID
        let title: String
        let date: LocalDate
        let parentCompletedAt: Date
        let subtaskCompletedAt: Date
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

    private static let taskTitle = "E2E parent completion control"
    private static let subtaskTitle = "E2E final open subtask"

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains("--e2e-completion-control-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-completion-control-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-completion-control-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-completion-control-result-url"
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
        let input = try WindowServerInputDriver()
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 3
        )
        let today = timeline.today

        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: Self.taskTitle,
            now: try timeline.nextInstant()
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let subtaskID = try engine.addSubtask(
            traceID: traceID,
            title: Self.subtaskTitle,
            now: try timeline.nextInstant()
        )
        _ = try timeline.finish()

        store.engine = engine
        store.page = .day
        store.selectedDate = today
        store.selectedCalendarDate = today
        store.clearSelection()
        store.expandedTraceIDs = [traceID]
        store.persist()

        guard let initialTrace = store.engine.traces[traceID],
              let initialSubtask = store.engine.subtasks[subtaskID],
              initialTrace.date == today,
              initialTrace.status == .pending,
              initialTrace.completedAt == nil,
              initialSubtask.traceID == traceID,
              initialSubtask.status == .pending,
              initialSubtask.completedAt == nil,
              try persistedSnapshot() == engine.snapshot()
        else {
            throw Failure.failed("completion fixture was not committed to SQLite")
        }
        try await activate(window)

        let parentIdentifier = completionIdentifier(traceID)
        let subtaskIdentifier = subtaskCompletionIdentifier(subtaskID)
        try await assertButton(
            identifier: parentIdentifier,
            label: store.copy.openSubtasksPreventCompletion,
            in: window
        )

        let baseline = store.engine.snapshot()
        let baselineUndoCount = store.undoStack.count
        let baselineRedoCount = store.redoStack.count
        let baselineEngineRevision = store.engineRevision
        let baselineFailure = store.operationFailureNotice
        try await click(
            parentIdentifier,
            label: store.copy.openSubtasksPreventCompletion,
            in: window,
            input: input
        )
        try await waitForToast(
            store.copy.openSubtasksPreventCompletion,
            in: store
        )
        guard let blockedTrace = store.engine.traces[traceID],
              let blockedSubtask = store.engine.subtasks[subtaskID],
              blockedTrace.status == .pending,
              blockedTrace.completedAt == nil,
              blockedSubtask.traceID == traceID,
              blockedSubtask.status == .pending,
              blockedSubtask.completedAt == nil,
              store.engine.snapshot() == baseline,
              store.undoStack.count == baselineUndoCount,
              store.redoStack.count == baselineRedoCount,
              store.engineRevision == baselineEngineRevision,
              store.operationFailureNotice == baselineFailure,
              try persistedSnapshot() == baseline
        else {
            throw Failure.failed("blocked parent completion mutated task facts")
        }

        try await assertButton(
            identifier: subtaskIdentifier,
            label: store.copy.markComplete,
            in: window
        )
        try await click(
            subtaskIdentifier,
            label: store.copy.markComplete,
            in: window,
            input: input
        )
        try await waitUntil("last open subtask did not complete through its button") {
            guard let trace = store.engine.traces[traceID],
                  let subtask = store.engine.subtasks[subtaskID]
            else {
                return false
            }
            return trace.status == .pending
                && trace.completedAt == nil
                && subtask.traceID == traceID
                && subtask.status == .completed
                && subtask.completedAt != nil
        }
        guard let completedSubtask = store.engine.subtasks[subtaskID],
              let subtaskCompletedAt = completedSubtask.completedAt,
              try persistedSnapshot() == store.engine.snapshot()
        else {
            throw Failure.failed(
                "completed subtask state or parent relationship was not committed"
            )
        }
        try await assertButton(
            identifier: parentIdentifier,
            label: store.copy.markComplete,
            in: window
        )

        try await click(
            parentIdentifier,
            label: store.copy.markComplete,
            in: window,
            input: input
        )
        try await waitUntil("resolved parent did not complete through its button") {
            guard let trace = store.engine.traces[traceID],
                  let subtask = store.engine.subtasks[subtaskID]
            else {
                return false
            }
            return trace.status == .completed
                && trace.completedAt != nil
                && subtask.traceID == traceID
                && subtask.status == .completed
                && subtask.completedAt == subtaskCompletedAt
        }
        try await waitForToast(
            store.copy.taskCompletionChanged(completed: true),
            in: store
        )
        try await assertButton(
            identifier: parentIdentifier,
            label: store.copy.undoComplete,
            in: window
        )
        try await assertButton(
            identifier: subtaskIdentifier,
            label: store.copy.undoComplete,
            enabled: false,
            in: window
        )
        guard let completedTrace = store.engine.traces[traceID],
              let parentCompletedAt = completedTrace.completedAt,
              try persistedSnapshot() == store.engine.snapshot()
        else {
            throw Failure.failed("completed parent was not committed to SQLite")
        }

        try writeState(
            ProbeState(
                traceID: traceID.rawValue,
                subtaskID: subtaskID.rawValue,
                title: Self.taskTitle,
                date: today,
                parentCompletedAt: parentCompletedAt,
                subtaskCompletedAt: subtaskCompletedAt
            )
        )
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        let state = try readState()
        let traceID = DayTraceID(state.traceID)
        let subtaskID = SubtaskID(state.subtaskID)
        guard store.today == state.date else {
            throw Failure.failed(
                "completion control natural day changed from \(state.date) "
                    + "to \(store.today)"
            )
        }
        guard let trace = store.engine.traces[traceID],
              let subtask = store.engine.subtasks[subtaskID],
              store.engine.definitions[trace.definitionID]?.title == state.title,
              trace.date == state.date,
              trace.status == .completed,
              trace.completedAt == state.parentCompletedAt,
              subtask.traceID == traceID,
              subtask.status == .completed,
              subtask.completedAt == state.subtaskCompletedAt,
              try persistedSnapshot() == store.engine.snapshot()
        else {
            throw Failure.failed("completed parent and subtask did not survive restart")
        }

        let window = try await visibleMainWindow()
        let input = try WindowServerInputDriver()
        store.page = .day
        store.selectedDate = state.date
        store.selectedCalendarDate = state.date
        store.clearSelection()
        store.expandedTraceIDs = [traceID]
        try await activate(window)

        let parentIdentifier = completionIdentifier(traceID)
        try await assertButton(
            identifier: parentIdentifier,
            label: store.copy.undoComplete,
            in: window
        )
        try await assertButton(
            identifier: subtaskCompletionIdentifier(subtaskID),
            label: store.copy.undoComplete,
            enabled: false,
            in: window
        )
        try await click(
            parentIdentifier,
            label: store.copy.undoComplete,
            in: window,
            input: input
        )
        try await waitUntil("parent completion was not undone through its button") {
            guard let currentTrace = store.engine.traces[traceID],
                  let currentSubtask = store.engine.subtasks[subtaskID]
            else {
                return false
            }
            return currentTrace.date == state.date
                && currentTrace.status == .pending
                && currentTrace.completedAt == nil
                && currentSubtask.traceID == traceID
                && currentSubtask.status == .completed
                && currentSubtask.completedAt == state.subtaskCompletedAt
        }
        try await waitForToast(
            store.copy.taskCompletionChanged(completed: false),
            in: store
        )
        try await assertButton(
            identifier: parentIdentifier,
            label: store.copy.markComplete,
            in: window
        )
        try await assertButton(
            identifier: subtaskCompletionIdentifier(subtaskID),
            label: store.copy.undoComplete,
            in: window
        )
        guard try persistedSnapshot() == store.engine.snapshot() else {
            throw Failure.failed("undone parent completion was not committed to SQLite")
        }
    }

    private func assertButton(
        identifier: String,
        label: String,
        enabled: Bool = true,
        in expectedWindow: NSWindow
    ) async throws {
        guard AXIsProcessTrusted() else {
            throw Failure.failed(
                "Accessibility access is unavailable for \(identifier)"
            )
        }
        var matchedButton: ReadOnlyAccessibilityTarget.Match?
        do {
            try await waitUntil("missing completion button \(identifier)") {
                guard let button = completionButton(
                    identifier: identifier,
                    label: label,
                    enabled: enabled,
                    in: expectedWindow
                ) else { return false }
                matchedButton = button
                return true
            }
        } catch {
            throw Failure.failed(
                "missing completion button \(identifier): "
                    + ReadOnlyAccessibilityTarget.buttonDiagnostics(
                        identifier: identifier,
                        title: label,
                        in: expectedWindow
                    )
            )
        }
        guard matchedButton != nil else {
            throw Failure.failed("completion button disappeared: \(identifier)")
        }
    }

    private func waitForToast(
        _ expected: String,
        in store: NoonmarkStore
    ) async throws {
        try await waitUntil("expected toast was not visibly presented: \(expected)") {
            guard store.toast == expected,
                  let toast = AppViewTreeE2E.view(identifier: "app.toast")
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: toast) == expected
        }
    }

    private func click(
        _ identifier: String,
        label: String,
        in expectedWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        var point: CGPoint?
        try await waitUntil("missing visible AX click target \(identifier)") {
            guard NSApp.keyWindow === expectedWindow,
                  let frame = completionButton(
                      identifier: identifier,
                      label: label,
                      enabled: true,
                      in: expectedWindow
                  )?.frame
            else {
                return false
            }
            point = CGPoint(x: frame.midX, y: frame.midY)
            return true
        }
        guard let point else {
            throw Failure.failed("completion button frame disappeared: \(identifier)")
        }
        do {
            let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
                guard NSApp.keyWindow === expectedWindow,
                      let frame = completionButton(
                          identifier: identifier,
                          label: label,
                          enabled: true,
                          in: expectedWindow
                      )?.frame
                else {
                    throw Failure.failed(
                        "completion button changed before mouseDown: \(identifier)"
                    )
                }
                let currentPoint = CGPoint(x: frame.midX, y: frame.midY)
                return try input.pointerCoordinate(
                    quartzPoint: currentPoint,
                    in: expectedWindow
                )
            }
            let coordinate = try input.pointerCoordinate(
                quartzPoint: point,
                in: expectedWindow
            )
            try await input.postClick(
                at: coordinate,
                modifiers: [],
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "WindowServer click failed for \(identifier): "
                    + error.localizedDescription
            )
        }
    }

    private func completionButton(
        identifier: String,
        label: String,
        enabled: Bool,
        in expectedWindow: NSWindow
    ) -> ReadOnlyAccessibilityTarget.Match? {
        guard NSApp.isActive,
              NSApp.keyWindow === expectedWindow,
              expectedWindow.isVisible,
              expectedWindow.isMiniaturized == false,
              let button = ReadOnlyAccessibilityTarget.uniqueButton(
                  identifier: identifier,
                  label: label,
                  enabled: enabled,
                  in: expectedWindow
              ),
              button.frame != nil
        else {
            return nil
        }
        return button
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not become active and key") {
            NSApp.isActive && window.isMainWindow && window.isKeyWindow
        }
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var window: NSWindow?
        try await waitUntil("main window was not visible") {
            window = NSApp.windows.first {
                $0 is NoonmarkWindow
                    && $0.isVisible
                    && $0.isMiniaturized == false
            }
            return window != nil
        }
        guard let window else {
            throw Failure.failed("main window disappeared")
        }
        return window
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func persistedSnapshot() throws -> NoonmarkSnapshot {
        guard let path = AppLaunchArguments.value(after: "--data-url") else {
            throw Failure.failed("completion control E2E requires --data-url")
        }
        return try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: path)
        ).load().snapshot()
    }

    private func completionIdentifier(_ traceID: DayTraceID) -> String {
        "day.trace.\(traceID.description).completion"
    }

    private func subtaskCompletionIdentifier(_ subtaskID: SubtaskID) -> String {
        SubtaskRowSurface.dayList.completionIdentifier(for: subtaskID)
    }

    private func writeState(_ state: ProbeState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> ProbeState {
        try JSONDecoder().decode(
            ProbeState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

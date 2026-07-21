import AppKit
import Foundation
import NoonmarkCore
import NoonmarkStorage

/// Exercises the exact interaction that used to lose a task title: type into
/// the native title editor and immediately click another workspace row.
@MainActor
struct ImmediateTaskMutationE2EAutomation: LaunchAutomationRunnable {
    private static let dayInitialTitle = "E2E Day original title"
    private static let daySavedTitle = "E2E Day saved immediately"
    private static let daySavedDescription = "E2E Day description saved immediately"
    private static let daySiblingTitle = "E2E Day click-away target"
    private static let poolInitialTitle = "E2E Pool original title"
    private static let poolSavedTitle = "E2E Pool saved immediately"
    private static let poolSavedDescription = "E2E Pool description saved immediately"
    private static let poolSiblingTitle = "E2E Pool click-away target"
    private static let deletedTitle = "E2E Day delete immediately"

    let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-immediate-task-mutation-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try await exercise(on: store)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let fixture = try installFixture(on: store)
        let interactionMoment = try store.dayContext.moment()
        guard fixture.latestMutationAt <= interactionMoment.instant else {
            throw Failure.failed(
                "immediate task mutation fixture clock exceeded its UI interaction clock"
            )
        }
        let input = try WindowServerInputDriver()
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("main window could not become active")
        }

        try await editTitle(
            TitleEdit(
                initialTitle: Self.dayInitialTitle,
                savedTitle: Self.daySavedTitle,
                clickAwayIdentifier: dayIdentifier(fixture.daySiblingTraceID),
                selectedAfterClick: { store.selectedTraceID == fixture.daySiblingTraceID },
                readback: {
                guard let trace = store.engine.traces[fixture.dayTraceID] else {
                    return nil
                }
                return store.engine.definitions[trace.definitionID]?.title
            }
            ),
            input: input
        )

        store.selectTrace(fixture.dayTraceID)
        try await editDescription(
            TextEdit(
                initialText: "",
                savedText: Self.daySavedDescription,
                clickAwayIdentifier: dayIdentifier(fixture.daySiblingTraceID),
                selectedAfterClick: { store.selectedTraceID == fixture.daySiblingTraceID },
                readback: { store.engine.traces[fixture.dayTraceID]?.descriptionText }
            ),
            input: input
        )

        store.page = .pool
        store.clearSelection()
        store.selectPool(fixture.poolChainID)
        try await editTitle(
            TitleEdit(
                initialTitle: Self.poolInitialTitle,
                savedTitle: Self.poolSavedTitle,
                clickAwayIdentifier: poolIdentifier(fixture.poolSiblingChainID),
                selectedAfterClick: {
                store.selectedPoolChainID == fixture.poolSiblingChainID
            },
                readback: {
                store.currentDefinition(for: fixture.poolChainID)?.title
            }
            ),
            input: input
        )

        store.selectPool(fixture.poolChainID)
        try await editDescription(
            TextEdit(
                initialText: "",
                savedText: Self.poolSavedDescription,
                clickAwayIdentifier: poolIdentifier(fixture.poolSiblingChainID),
                selectedAfterClick: { store.selectedPoolChainID == fixture.poolSiblingChainID },
                readback: { store.currentDefinition(for: fixture.poolChainID)?.descriptionText }
            ),
            input: input
        )

        store.page = .day
        store.selectedDate = fixture.today
        store.selectedCalendarDate = fixture.today
        store.clearSelection()
        try await chooseDeleteMenuItem(
            from: dayIdentifier(fixture.deletedTraceID),
            input: input
        )
        try await waitUntil("today's newly added task was not deleted through its menu") {
            store.engine.traces[fixture.deletedTraceID]?.status == .cancelledDraft
                && store.engine.chains[fixture.deletedChainID]?.state == .abandoned
                && store.engine.getDayTodo(date: fixture.today).traces.contains(where: {
                    $0.id == fixture.deletedTraceID
                }) == false
                && store.engine.taskPool().contains(where: {
                    $0.chain.id == fixture.deletedChainID
                }) == false
        }
        try assertPersisted(fixture, store: store)
    }

    private func installFixture(on store: NoonmarkStore) throws -> Fixture {
        store.engine = NoonmarkEngine()
        store.setLanguage(.english)
        var timeline = try E2EFixtureTimeline(store: store, eventCount: 8)
        let today = timeline.today

        let dayChainID = try store.engine.createPoolTask(
            title: Self.dayInitialTitle,
            now: try timeline.nextInstant()
        )
        let dayTraceID = try store.engine.scheduleFromPool(
            chainID: dayChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let daySiblingChainID = try store.engine.createPoolTask(
            title: Self.daySiblingTitle,
            now: try timeline.nextInstant()
        )
        let daySiblingTraceID = try store.engine.scheduleFromPool(
            chainID: daySiblingChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let poolChainID = try store.engine.createPoolTask(
            title: Self.poolInitialTitle,
            now: try timeline.nextInstant()
        )
        let poolSiblingChainID = try store.engine.createPoolTask(
            title: Self.poolSiblingTitle,
            now: try timeline.nextInstant()
        )
        let deletedChainID = try store.engine.createPoolTask(
            title: Self.deletedTitle,
            now: try timeline.nextInstant()
        )
        let deletedTraceID = try store.engine.scheduleFromPool(
            chainID: deletedChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let latestMutationAt = try timeline.finish()

        guard store.engine.canDeleteNewCurrentDayTask(
            traceID: deletedTraceID,
            today: today
        ), store.contextMenuActions(
            for: try requiredTrace(deletedTraceID, in: store)
        ).last == .deleteNewCurrentDayTask
        else {
            throw Failure.failed(
                "current-day deletion fixture did not expose the delete menu action"
            )
        }

        store.page = .day
        store.selectedDate = today
        store.selectedCalendarDate = today
        store.selectTrace(dayTraceID)
        store.persist()
        return Fixture(
            today: today,
            dayChainID: dayChainID,
            dayTraceID: dayTraceID,
            daySiblingTraceID: daySiblingTraceID,
            poolChainID: poolChainID,
            poolSiblingChainID: poolSiblingChainID,
            deletedChainID: deletedChainID,
            deletedTraceID: deletedTraceID,
            latestMutationAt: latestMutationAt
        )
    }

    private func editTitle(
        _ edit: TitleEdit,
        input: WindowServerInputDriver
    ) async throws {
        var titleEditor: NSTextView?
        try await waitUntil("native title editor was not ready: \(edit.initialTitle)") {
            titleEditor = AppViewTreeE2E.view(identifier: "detail.title.input")
                as? NSTextView
            return titleEditor?.string == edit.initialTitle
        }
        guard let titleEditor else {
            throw Failure.failed("native title editor disappeared before editing")
        }

        try await click(identifier: "detail.title.input", modifiers: [], input: input)
        try await waitUntil("native title editor did not become first responder") {
            titleEditor.window?.firstResponder === titleEditor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(edit.savedTitle)
        try await waitUntil("typed title was not saved before focus changed") {
            titleEditor.string == edit.savedTitle && edit.readback() == edit.savedTitle
        }

        try await click(identifier: edit.clickAwayIdentifier, modifiers: [], input: input)
        try await waitUntil("clicking away did not keep the saved title") {
            edit.selectedAfterClick() && edit.readback() == edit.savedTitle
        }
    }

    private func chooseDeleteMenuItem(
        from identifier: String,
        input: WindowServerInputDriver
    ) async throws {
        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click(identifier: identifier, modifiers: [.control], input: input)
        try await waitUntil("new current-day task menu did not begin tracking") {
            probe.didBeginTracking
        }
        // Newly added current-day tasks retain the existing abandon action;
        // deletion is the sixth, destructive menu item.
        for _ in 0 ..< 6 {
            try input.postKey(keyCode: 125)
        }
        try input.postKey(keyCode: 36)
    }

    private func editDescription(
        _ edit: TextEdit,
        input: WindowServerInputDriver
    ) async throws {
        var editor: NSTextView?
        try await waitUntil("native description editor was not ready") {
            editor = AppViewTreeE2E.view(identifier: "detail.description.input")
                as? NSTextView
            return editor?.string == edit.initialText
        }
        guard let editor else {
            throw Failure.failed("native description editor disappeared before editing")
        }

        try await click(identifier: "detail.description.input", modifiers: [], input: input)
        try await waitUntil("native description editor did not become first responder") {
            editor.window?.firstResponder === editor
        }
        try input.postKey(keyCode: 0, modifiers: .command)
        try input.typeUnicode(edit.savedText)
        try await waitUntil("typed description was not saved before focus changed") {
            editor.string == edit.savedText && edit.readback() == edit.savedText
        }

        try await click(identifier: edit.clickAwayIdentifier, modifiers: [], input: input)
        try await waitUntil("clicking away did not keep the saved description") {
            edit.selectedAfterClick() && edit.readback() == edit.savedText
        }
    }

    private func click(
        identifier: String,
        modifiers: NSEvent.ModifierFlags,
        input: WindowServerInputDriver
    ) async throws {
        try await waitUntil("visible click target was missing: \(identifier)") {
            AppViewTreeE2E.view(identifier: identifier) != nil
        }
        guard let view = AppViewTreeE2E.view(identifier: identifier),
              let window = view.window,
              window.isKeyWindow,
              NSApp.isActive
        else {
            throw Failure.failed(
                "WindowServer click target was not in the active key window"
            )
        }
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let currentView = AppViewTreeE2E.view(identifier: identifier),
                  let currentWindow = currentView.window,
                  currentWindow === window,
                  currentWindow.isKeyWindow,
                  currentView.isHiddenOrHasHiddenAncestor == false,
                  currentView.bounds.width > 0,
                  currentView.bounds.height > 0
            else {
                throw Failure.failed(
                    "WindowServer click target changed before mouseDown: \(identifier)"
                )
            }
            let point = currentView.convert(
                NSPoint(
                    x: currentView.bounds.midX,
                    y: currentView.bounds.midY
                ),
                to: nil
            )
            return try input.pointerCoordinate(windowPoint: point, in: currentWindow)
        }
        let coordinate = try resolveTarget()
        try await input.postClick(
            at: coordinate,
            modifiers: modifiers,
            resolveTarget: resolveTarget
        )
    }

    private func assertPersisted(
        _ fixture: Fixture,
        store: NoonmarkStore
    ) throws {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed(
                "immediate task mutation persistence probe requires --data-url"
            )
        }
        let restored = try SQLiteEngineRepository(databaseURL: databaseURL).load()
        guard let dayTrace = restored.traces[fixture.dayTraceID],
              restored.definitions[dayTrace.definitionID]?.title == Self.daySavedTitle,
              dayTrace.descriptionText == Self.daySavedDescription,
              restored.definitions.values.contains(where: {
                  $0.chainID == fixture.poolChainID
                      && $0.supersededAt == nil
                      && $0.title == Self.poolSavedTitle
                      && $0.descriptionText == Self.poolSavedDescription
              }),
              let deletedTrace = restored.traces[fixture.deletedTraceID],
              deletedTrace.status == .cancelledDraft,
              deletedTrace.draftCancellationID != nil,
              deletedTrace.draftCancelledOn == fixture.today,
              restored.chains[fixture.deletedChainID]?.state == .abandoned,
              restored.getDayTodo(date: fixture.today).traces.contains(where: {
                  $0.id == fixture.deletedTraceID
              }) == false,
              restored.taskPool().contains(where: {
                  $0.chain.id == fixture.deletedChainID
              }) == false
        else {
            throw Failure.failed(
                "immediate title changes or current-day deletion did not persist exactly"
            )
        }
    }

    private func requiredTrace(
        _ traceID: DayTraceID,
        in store: NoonmarkStore
    ) throws -> DayTrace {
        guard let trace = store.engine.traces[traceID] else {
            throw Failure.failed("fixture trace was missing")
        }
        return trace
    }

    private func dayIdentifier(_ traceID: DayTraceID) -> String {
        "workspace.item.day.\(traceID.description)"
    }

    private func poolIdentifier(_ chainID: TaskChainID) -> String {
        "workspace.item.pool.\(chainID.description)"
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 80,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let today: LocalDate
        let dayChainID: TaskChainID
        let dayTraceID: DayTraceID
        let daySiblingTraceID: DayTraceID
        let poolChainID: TaskChainID
        let poolSiblingChainID: TaskChainID
        let deletedChainID: TaskChainID
        let deletedTraceID: DayTraceID
        let latestMutationAt: Date
    }

    private struct TitleEdit {
        let initialTitle: String
        let savedTitle: String
        let clickAwayIdentifier: String
        let selectedAfterClick: @MainActor () -> Bool
        let readback: @MainActor () -> String?
    }

    private struct TextEdit {
        let initialText: String
        let savedText: String
        let clickAwayIdentifier: String
        let selectedAfterClick: @MainActor () -> Bool
        let readback: @MainActor () -> String?
    }

    private final class MenuTrackingProbe: @unchecked Sendable {
        private(set) var didBeginTracking = false
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.didBeginTracking = true
                }
            }
        }

        func stop() {
            guard let observer else { return }
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }
}

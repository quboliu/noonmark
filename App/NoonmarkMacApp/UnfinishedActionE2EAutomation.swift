import AppKit
import Foundation
import NoonmarkCore
import NoonmarkStorage

struct UnfinishedActionE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exercise
        case restart
    }

    private static let rowTitle = "E2E 已延续列表废弃"
    private static let detailTitle = "E2E 已延续详情废弃"

    private let mode: Mode
    private let resultURL: URL

    @MainActor
    static func fromCommandLine() -> Self? {
        let mode: Mode? = if AppLaunchArguments.contains(
            "--e2e-unfinished-action-exercise"
        ) {
            .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-unfinished-action-restart"
        ) {
            .restart
        } else {
            nil
        }
        guard let mode,
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-unfinished-action-result-url"
              )
        else {
            return nil
        }
        return Self(
            mode: mode,
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .exercise:
                    try await exercise(on: store)
                case .restart:
                    try await verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func exercise(on store: NoonmarkStore) async throws {
        let fixture = try installFixture(on: store)
        let interactionMoment = try store.dayContext.moment()
        guard fixture.latestMutationAt <= interactionMoment.instant else {
            throw Failure.failed(
                "unfinished fixture clock exceeded its UI interaction clock"
            )
        }
        let input = try WindowServerInputDriver()
        store.page = .unfinished
        store.clearSelection()
        store.isDetailRailExpanded = false
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("main window could not become active")
        }

        try await chooseFirstMenuItem(
            from: "workspace.item.unfinished.\(fixture.row.chainID.description)",
            modifiers: [.control],
            input: input
        )
        try await assertAbandoned(fixture.row, in: store)

        store.page = .unfinished
        store.clearSelection()
        let detailRowIdentifier =
            "workspace.item.unfinished.\(fixture.detail.chainID.description)"
        try await click(
            identifier: detailRowIdentifier,
            modifiers: [],
            input: input
        )
        try await waitUntil("unfinished detail action menu was unavailable") {
            guard let actionAnchor = AppViewTreeE2E.view(
                identifier: "unfinished.detail.actions"
            ) else {
                return false
            }
            return store.selectedUnfinishedItem?.chain.id
                == fixture.detail.chainID
                && store.detailRailRoute == .selection
                && AppViewTreeE2E.verificationText(
                    for: actionAnchor
                ) == "1"
        }
        try await chooseFirstMenuItem(
            from: "unfinished.detail.actions",
            modifiers: [],
            input: input
        )
        try await assertAbandoned(fixture.detail, in: store)

        store.persist()
        try assertPersisted(fixture, store: store)
    }

    @MainActor
    private func verifyRestart(on store: NoonmarkStore) async throws {
        let targetTitles = Set([Self.rowTitle, Self.detailTitle])
        let items = store.engine.unfinishedPool().filter {
            targetTitles.contains($0.definition.title)
        }
        guard items.count == 2,
              items.allSatisfy({
                  $0.chain.state == .abandoned
                      && $0.activeTrace == nil
                      && $0.actionPlan.count == 1
              }),
              items.allSatisfy({
                  if case .reactivateChain = $0.actionPlan[0] {
                      return true
                  }
                  return false
              })
        else {
            throw Failure.failed(
                "persisted unfinished action state did not survive restart"
            )
        }

        store.page = .unfinished
        store.clearSelection()
        guard AppViewTreeE2E.activateMainWindow() else {
            throw Failure.failed("restart window could not become active")
        }
        let identifiers = items.map {
            "workspace.item.unfinished.\($0.chain.id.description)"
        }
        try await waitUntil("restarted abandoned rows were not visible") {
            identifiers.allSatisfy {
                AppViewTreeE2E.view(identifier: $0) != nil
            }
        }
    }

    @MainActor
    private func installFixture(on store: NoonmarkStore) throws -> Fixture {
        store.engine = NoonmarkEngine()
        store.setLanguage(.chinese)
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 7
        )
        let today = timeline.today
        let yesterday = NoonmarkStore.offset(today, by: -1)

        let rowChainID = try store.engine.createPoolTask(
            title: Self.rowTitle,
            now: try timeline.nextInstant()
        )
        let rowHistoricalTraceID = try store.engine.scheduleFromPool(
            chainID: rowChainID,
            date: yesterday,
            today: yesterday,
            now: try timeline.nextInstant()
        )
        let detailChainID = try store.engine.createPoolTask(
            title: Self.detailTitle,
            now: try timeline.nextInstant()
        )
        let detailHistoricalTraceID = try store.engine.scheduleFromPool(
            chainID: detailChainID,
            date: yesterday,
            today: yesterday,
            now: try timeline.nextInstant()
        )
        try store.engine.settleDays(
            upTo: today,
            now: try timeline.nextInstant()
        )
        let rowActiveTraceID = try store.engine.continueUnfinishedTrace(
            traceID: rowHistoricalTraceID,
            targetDate: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let detailActiveTraceID = try store.engine.continueUnfinishedTrace(
            traceID: detailHistoricalTraceID,
            targetDate: today,
            today: today,
            now: try timeline.nextInstant()
        )
        let latestMutationAt = try timeline.finish()

        let fixture = Fixture(
            row: ChainFixture(
                chainID: rowChainID,
                historicalTraceID: rowHistoricalTraceID,
                activeTraceID: rowActiveTraceID
            ),
            detail: ChainFixture(
                chainID: detailChainID,
                historicalTraceID: detailHistoricalTraceID,
                activeTraceID: detailActiveTraceID
            ),
            latestMutationAt: latestMutationAt
        )
        for chain in [fixture.row, fixture.detail] {
            guard store.engine.unfinishedPool()
                .first(where: { $0.chain.id == chain.chainID })?
                .actionPlan == [.abandonChain(chain.activeTraceID)]
            else {
                throw Failure.failed(
                    "continued unfinished fixture did not expose abandon only"
                )
            }
        }
        return fixture
    }

    @MainActor
    private func chooseFirstMenuItem(
        from identifier: String,
        modifiers: NSEvent.ModifierFlags,
        input: WindowServerInputDriver
    ) async throws {
        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click(
            identifier: identifier,
            modifiers: modifiers,
            input: input
        )
        try await waitUntil("native menu did not begin tracking") {
            probe.didBeginTracking
        }
        try input.postKey(keyCode: 125)
        try input.postKey(keyCode: 36)
    }

    @MainActor
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
            let currentPoint = currentView.convert(
                NSPoint(
                    x: currentView.bounds.midX,
                    y: currentView.bounds.midY
                ),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: currentPoint,
                in: currentWindow
            )
        }
        let coordinate = try resolveTarget()
        try await input.postClick(
            at: coordinate,
            modifiers: modifiers,
            resolveTarget: resolveTarget
        )
    }

    @MainActor
    private func assertAbandoned(
        _ fixture: ChainFixture,
        in store: NoonmarkStore
    ) async throws {
        try await waitUntil("unfinished menu did not abandon its active trace") {
            guard let item = store.engine.unfinishedPool().first(where: {
                $0.chain.id == fixture.chainID
            }) else {
                return false
            }
            return item.chain.state == .abandoned
                && item.activeTrace == nil
                && store.engine.traces[fixture.historicalTraceID]?.status
                == .unfinished
                && store.engine.traces[fixture.activeTraceID]?.status
                == .abandoned
                && item.actionPlan == [
                    .reactivateChain(fixture.activeTraceID)
                ]
        }
    }

    @MainActor
    private func assertPersisted(
        _ fixture: Fixture,
        store: NoonmarkStore
    ) throws {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed(
                "unfinished action persistence probe requires --data-url"
            )
        }
        let restored = try SQLiteEngineRepository(
            databaseURL: databaseURL
        ).load()
        for chain in [fixture.row, fixture.detail] {
            guard restored.chains[chain.chainID]?.state == .abandoned,
                  restored.traces[chain.historicalTraceID]?.status
                  == .unfinished,
                  restored.traces[chain.activeTraceID]?.status
                  == .abandoned,
                  restored.unfinishedPool()
                  .first(where: { $0.chain.id == chain.chainID })?
                  .activeTrace == nil
            else {
                throw Failure.failed(
                    "unfinished action did not persist exact chain facts"
                )
            }
        }
    }

    @MainActor
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
        try result.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private struct ChainFixture {
        let chainID: TaskChainID
        let historicalTraceID: DayTraceID
        let activeTraceID: DayTraceID
    }

    private struct Fixture {
        let row: ChainFixture
        let detail: ChainFixture
        let latestMutationAt: Date
    }

    @MainActor
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
            case let .failed(message):
                message
            }
        }
    }
}

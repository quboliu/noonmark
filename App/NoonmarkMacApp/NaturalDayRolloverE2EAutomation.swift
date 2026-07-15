import AppKit
import Foundation
import NoonmarkCore
import NoonmarkStorage

@MainActor
struct NaturalDayRolloverE2EAutomation {
    private enum Mode {
        case exercise
        case verifyRestart
    }

    private struct State: Codable {
        let title: String
        let traceID: UUID
        let sourceDate: LocalDate
        let targetDate: LocalDate
        let initialPriority: Int
        let settlementInstant: Date
    }

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let arguments = AppLaunchArguments.values
        let mode: Mode
        if arguments.contains("--e2e-natural-day-rollover-exercise") {
            mode = .exercise
        } else if arguments.contains(
            "--e2e-natural-day-rollover-restart-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-natural-day-rollover-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-natural-day-rollover-result-url"
        ) else {
            return nil
        }
        return Self(
            mode: mode,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    func run(
        on store: NoonmarkStore,
        environment: FixedNaturalDayEnvironment?
    ) {
        do {
            guard let environment else {
                throw Failure.failed(
                    "natural-day automation did not receive the fixed adapter"
                )
            }
            switch mode {
            case .exercise:
                try exercise(on: store, environment: environment)
            case .verifyRestart:
                try verifyRestart(on: store, environment: environment)
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func exercise(
        on store: NoonmarkStore,
        environment: FixedNaturalDayEnvironment
    ) throws {
        let sourceDate = LocalDate("2026-07-05")
        let targetDate = LocalDate("2026-07-06")
        let title = "E2E natural day atomic rollover"
        guard store.today == sourceDate,
              store.dayBoundaryState == .ready(appliedThrough: sourceDate)
        else {
            throw Failure.failed("exercise did not start on the fixed source day")
        }

        store.selectedDate = sourceDate
        store.selectedCalendarDate = sourceDate
        store.quickText = title
        store.addQuickTask()
        guard let definition = store.engine.definitions.values.first(where: {
            $0.title == title
        }), let trace = store.engine.traces.values.first(where: {
            $0.definitionID == definition.id && $0.date == sourceDate
        }), trace.status == .pending
        else {
            throw Failure.failed("exercise could not create its pending source trace")
        }
        store.selectTrace(trace.id)
        let baseline = store.engine.snapshot()
        try assertPersistedTrace(
            trace.id,
            status: .pending,
            settledAt: nil,
            dayLockedAt: nil,
            date: sourceDate
        )

        try store.armPersistenceFailureForE2E(count: 2)
        let forwardInstant = try instant("2026-07-06T04:30:00Z")
        environment.update(
            instant: forwardInstant,
            timeZoneIdentifier: "America/New_York",
            signal: .wake
        )
        guard case let .blocked(applied, candidate, _) = store.dayBoundaryState,
              applied == sourceDate,
              candidate == targetDate,
              store.today == sourceDate,
              store.engine.snapshot() == baseline
        else {
            throw Failure.failed(
                "failed wake rollover published partial in-memory state"
            )
        }
        try assertPersistedTrace(
            trace.id,
            status: .pending,
            settledAt: nil,
            dayLockedAt: nil,
            date: sourceDate
        )

        store.movePriority(trace.id, delta: 1)
        guard case let .blocked(applied, candidate, _) = store.dayBoundaryState,
              applied == sourceDate,
              candidate == targetDate,
              store.today == sourceDate,
              store.engine.snapshot() == baseline,
              store.engine.traces[trace.id]?.priority == trace.priority
        else {
            throw Failure.failed(
                "blocked mutation changed state or lost the candidate day"
            )
        }

        store.disarmPersistenceFailureForE2E()
        store.retryNaturalDay()
        try assertAdvancedState(
            store,
            traceID: trace.id,
            sourceDate: sourceDate,
            targetDate: targetDate,
            expectedSettlementInstant: forwardInstant
        )
        try assertPersistedTrace(
            trace.id,
            status: .unfinished,
            settledAt: forwardInstant,
            dayLockedAt: forwardInstant,
            date: sourceDate
        )
        let advancedSnapshot = store.engine.snapshot()

        environment.update(
            instant: try instant("2026-07-06T04:30:00Z"),
            signal: .midnight
        )
        guard store.engine.snapshot() == advancedSnapshot,
              store.today == targetDate,
              store.dayBoundaryState == .ready(appliedThrough: targetDate)
        else {
            throw Failure.failed("duplicate midnight signal was not idempotent")
        }

        environment.update(
            instant: try instant("2026-07-06T04:30:00Z"),
            timeZoneIdentifier: "America/Los_Angeles",
            signal: .timeZoneChanged
        )
        guard store.today == sourceDate,
              store.dayBoundaryState == .ready(appliedThrough: sourceDate),
              store.engine.snapshot() == advancedSnapshot,
              store.engine.days[sourceDate]?.lockedAt != nil,
              store.isHistory
        else {
            throw Failure.failed(
                "backward time-zone change reopened or rewrote the locked day"
            )
        }
        store.movePriority(trace.id, delta: 1)
        guard store.engine.snapshot() == advancedSnapshot else {
            throw Failure.failed("locked-day priority changed after time-zone rollback")
        }

        environment.update(
            instant: try instant("2026-07-06T04:30:00Z"),
            timeZoneIdentifier: "America/New_York",
            signal: .timeZoneChanged
        )
        try assertAdvancedState(
            store,
            traceID: trace.id,
            sourceDate: sourceDate,
            targetDate: targetDate,
            expectedSettlementInstant: forwardInstant
        )

        try writeState(
            State(
                title: title,
                traceID: trace.id.rawValue,
                sourceDate: sourceDate,
                targetDate: targetDate,
                initialPriority: trace.priority,
                settlementInstant: forwardInstant
            )
        )
    }

    private func verifyRestart(
        on store: NoonmarkStore,
        environment: FixedNaturalDayEnvironment
    ) throws {
        let state = try readState()
        let traceID = DayTraceID(state.traceID)
        guard try environment.sample().timeZoneIdentifier == "America/New_York",
              store.today == state.targetDate,
              store.dayBoundaryState == .ready(appliedThrough: state.targetDate),
              store.selectedDate == state.targetDate,
              store.selectedCalendarDate == state.targetDate,
              let trace = store.engine.traces[traceID],
              trace.status == .unfinished,
              trace.settledAt == state.settlementInstant,
              trace.priority == state.initialPriority,
              store.engine.days[state.sourceDate]?.lockedAt
                == state.settlementInstant,
              store.engine.definitions[trace.definitionID]?.title == state.title,
              store.contextMenuActions(for: trace) == [.continueTo, .abandonChain]
        else {
            throw Failure.failed(
                "restarted app did not preserve the committed rollover facts"
            )
        }
        try assertPersistedTrace(
            traceID,
            status: .unfinished,
            settledAt: state.settlementInstant,
            dayLockedAt: state.settlementInstant,
            date: state.sourceDate
        )
    }

    private func assertAdvancedState(
        _ store: NoonmarkStore,
        traceID: DayTraceID,
        sourceDate: LocalDate,
        targetDate: LocalDate,
        expectedSettlementInstant: Date
    ) throws {
        guard store.today == targetDate,
              store.dayBoundaryState == .ready(appliedThrough: targetDate),
              store.selectedDate == targetDate,
              store.selectedCalendarDate == targetDate,
              store.selectedTraceID == nil,
              store.engine.days[sourceDate]?.lockedAt == expectedSettlementInstant,
              let trace = store.engine.traces[traceID],
              trace.status == .unfinished,
              trace.settledAt == expectedSettlementInstant,
              store.contextMenuActions(for: trace) == [.continueTo, .abandonChain]
        else {
            throw Failure.failed("retry did not atomically apply the target day")
        }
    }

    private func assertPersistedTrace(
        _ traceID: DayTraceID,
        status: TraceStatus,
        settledAt: Date?,
        dayLockedAt: Date?,
        date: LocalDate
    ) throws {
        guard let path = AppLaunchArguments.value(after: "--data-url") else {
            throw Failure.failed("natural-day automation requires an isolated database")
        }
        let persisted = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: path)
        ).load()
        guard persisted.traces[traceID]?.status == status,
              persisted.traces[traceID]?.settledAt == settledAt,
              persisted.days[date]?.lockedAt == dayLockedAt
        else {
            throw Failure.failed("SQLite trace facts diverged from the atomic boundary")
        }
    }

    private func instant(_ text: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw Failure.failed("invalid automation instant: \(text)")
        }
        return date
    }

    private func writeState(_ state: State) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }

    private func writeResult(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: resultURL, atomically: true, encoding: .utf8)
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

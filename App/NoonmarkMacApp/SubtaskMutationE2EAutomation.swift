import Foundation
import NoonmarkCore
import NoonmarkStorage
import NoonmarkSync

@MainActor
struct SubtaskMutationE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exercise
        case verifyRestart
        case compatibility
    }

    private struct State: Codable {
        let date: LocalDate
        let traceID: UUID
        let subtaskID: UUID
        let createdBits: UInt64
        let mutationBits: [UInt64]
        let mapperModifiedBits: UInt64
    }

    private struct ExpectedSubtask {
        let status: SubtaskStatus
        let difficulty: SubtaskDifficulty
        let hasCompletedAt: Bool
    }

    private static let taskTitle = "E2E subtask updatedAt clock parent"
    private static let subtaskTitle = "E2E subtask updatedAt clock"
    private static let syncDeviceID = SyncDeviceID(
        "e2e-subtask-updated-at-clock"
    )

    private let mode: Mode
    private let stateURL: URL?
    private let resultURL: URL?

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains("--e2e-subtask-clock-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-subtask-clock-restart-verify"
        ) {
            mode = .verifyRestart
        } else if AppLaunchArguments.contains("--e2e-subtask-mutation") {
            mode = .compatibility
        } else {
            return nil
        }

        let stateURL = AppLaunchArguments.value(
            after: "--e2e-subtask-clock-state-url"
        ).map(URL.init(fileURLWithPath:))
        let resultPath = AppLaunchArguments.value(
            after: "--e2e-subtask-clock-result-url"
        ) ?? AppLaunchArguments.value(
            after: "--e2e-subtask-mutation-result-url"
        )
        return Self(
            mode: mode,
            stateURL: stateURL,
            resultURL: resultPath.map(URL.init(fileURLWithPath:))
        )
    }

    func run(on store: NoonmarkStore) {
        do {
            switch mode {
            case .exercise:
                try exercise(on: store)
            case .verifyRestart:
                try verifyRestart(on: store)
            case .compatibility:
                try runCompatibility(on: store)
            }
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func exercise(on store: NoonmarkStore) throws {
        guard let stateURL else {
            throw Failure.failed(
                "subtask clock exercise requires a state file"
            )
        }
        guard store.engine.days.isEmpty,
              store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty,
              store.engine.subtasks.isEmpty,
              try journalEntries().isEmpty
        else {
            throw Failure.failed(
                "subtask clock exercise did not start from an isolated database"
            )
        }

        store.page = .day
        store.selectedDate = store.today
        guard store.addQuickTaskForToday(Self.taskTitle),
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == Self.taskTitle
              }),
              let trace = store.engine.traces.values.first(where: {
                  $0.definitionID == definition.id && $0.date == store.today
              })
        else {
            throw Failure.failed(
                "subtask clock exercise could not create its parent task"
            )
        }

        store.selectTrace(trace.id)
        store.detailSubtaskText = Self.subtaskTitle
        store.addDetailSubtask(traceID: trace.id)
        guard let initial = store.subtasks(for: trace.id).first(where: {
            $0.title == Self.subtaskTitle
        }), initial.status == .pending,
            initial.difficulty == .simple,
            initial.completedAt == nil,
            initial.settledAt == nil,
            hasSameBits(initial.createdAt, initial.updatedAt)
        else {
            throw Failure.failed(
                "subtask clock fixture was not pending and simple"
            )
        }
        store.clearUndoHistory()

        let createdBits = exactBits(initial.createdAt)
        var mutationBits: [UInt64] = []
        try assertPersistence(
            subtaskID: initial.id,
            createdBits: createdBits,
            mutationBits: mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .simple,
                hasCompletedAt: false
            )
        )

        try performMutation(
            on: store,
            subtaskID: initial.id,
            mutationBits: &mutationBits,
            expected: ExpectedSubtask(
                status: .completed,
                difficulty: .simple,
                hasCompletedAt: true
            )
        ) {
            store.toggleSubtask(initial.id)
        }
        try performMutation(
            on: store,
            subtaskID: initial.id,
            mutationBits: &mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .simple,
                hasCompletedAt: false
            )
        ) {
            store.toggleSubtask(initial.id)
        }
        try performMutation(
            on: store,
            subtaskID: initial.id,
            mutationBits: &mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .hard,
                hasCompletedAt: false
            )
        ) {
            store.setSubtaskDifficulty(initial.id, difficulty: .hard)
        }
        guard store.canUndoDomainAction else {
            throw Failure.failed(
                "subtask difficulty mutation did not enter the Store undo stack"
            )
        }
        try performMutation(
            on: store,
            subtaskID: initial.id,
            mutationBits: &mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .simple,
                hasCompletedAt: false
            )
        ) {
            store.undo()
        }
        guard store.canRedoDomainAction else {
            throw Failure.failed(
                "subtask difficulty undo did not enter the Store redo stack"
            )
        }
        try performMutation(
            on: store,
            subtaskID: initial.id,
            mutationBits: &mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .hard,
                hasCompletedAt: false
            )
        ) {
            store.redo()
        }

        guard mutationBits.count == 5,
              strictlyIncreases([createdBits] + mutationBits),
              let finalSubtask = store.engine.subtasks[initial.id]
        else {
            throw Failure.failed(
                "subtask clock did not produce five increasing mutations"
            )
        }
        let mapperModifiedBits = try assertSyncMapping(finalSubtask)
        try writeState(
            State(
                date: store.today,
                traceID: trace.id.rawValue,
                subtaskID: initial.id.rawValue,
                createdBits: createdBits,
                mutationBits: mutationBits,
                mapperModifiedBits: mapperModifiedBits
            ),
            to: stateURL
        )
    }

    private func verifyRestart(on store: NoonmarkStore) throws {
        guard let stateURL else {
            throw Failure.failed(
                "subtask clock restart requires a state file"
            )
        }
        let state = try readState(from: stateURL)
        guard store.today == state.date,
              state.mutationBits.count == 5,
              strictlyIncreases([state.createdBits] + state.mutationBits),
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == Self.taskTitle
              }),
              let trace = store.engine.traces[DayTraceID(state.traceID)],
              trace.definitionID == definition.id,
              trace.date == state.date,
              let subtask = store.engine.subtasks[SubtaskID(state.subtaskID)],
              subtask.traceID == trace.id,
              subtask.title == Self.subtaskTitle,
              hasSameBits(subtask.updatedAt, state.mutationBits.last)
        else {
            throw Failure.failed(
                "subtask clock restart did not restore its exact state"
            )
        }
        try assertPersistence(
            subtaskID: subtask.id,
            createdBits: state.createdBits,
            mutationBits: state.mutationBits,
            expected: ExpectedSubtask(
                status: .pending,
                difficulty: .hard,
                hasCompletedAt: false
            )
        )
        guard try assertSyncMapping(subtask) == state.mapperModifiedBits else {
            throw Failure.failed(
                "restarted SyncRecord modifiedAt diverged from stored updatedAt"
            )
        }
    }

    private func runCompatibility(on store: NoonmarkStore) throws {
        store.page = .day
        store.selectedDate = store.today
        guard let trace = store.engine.getDayTodo(date: store.today)
            .traces.first(where: { trace in
                store.subtasks(for: trace.id).contains {
                    $0.status == .pending && $0.difficulty == .simple
                }
            }),
            let subtask = store.subtasks(for: trace.id).first(where: {
                $0.status == .pending && $0.difficulty == .simple
            })
        else {
            throw Failure.failed("missing current pending simple subtask")
        }
        store.selectTrace(trace.id)
        store.clearUndoHistory()

        var previous = subtask.updatedAt
        let expectations: [(
            ExpectedSubtask,
            () -> Void
        )] = [
            (
                ExpectedSubtask(
                    status: .completed,
                    difficulty: .simple,
                    hasCompletedAt: true
                ),
                { store.toggleSubtask(subtask.id) }
            ),
            (
                ExpectedSubtask(
                    status: .pending,
                    difficulty: .simple,
                    hasCompletedAt: false
                ),
                { store.toggleSubtask(subtask.id) }
            ),
            (
                ExpectedSubtask(
                    status: .pending,
                    difficulty: .hard,
                    hasCompletedAt: false
                ),
                {
                    store.setSubtaskDifficulty(
                        subtask.id,
                        difficulty: .hard
                    )
                }
            ),
            (
                ExpectedSubtask(
                    status: .pending,
                    difficulty: .simple,
                    hasCompletedAt: false
                ),
                { store.undo() }
            ),
            (
                ExpectedSubtask(
                    status: .pending,
                    difficulty: .hard,
                    hasCompletedAt: false
                ),
                { store.redo() }
            )
        ]
        for (expected, mutation) in expectations {
            store.operationFailureNotice = nil
            mutation()
            guard let current = store.engine.subtasks[subtask.id],
                  current.updatedAt > previous
            else {
                throw Failure.failed(
                    "compatibility subtask mutation clock did not advance"
                )
            }
            try expect(current, matches: expected)
            previous = current.updatedAt
        }
    }

    private func performMutation(
        on store: NoonmarkStore,
        subtaskID: SubtaskID,
        mutationBits: inout [UInt64],
        expected: ExpectedSubtask,
        _ mutation: () -> Void
    ) throws {
        guard let before = store.engine.subtasks[subtaskID] else {
            throw Failure.failed("subtask disappeared before mutation")
        }
        store.operationFailureNotice = nil
        mutation()
        guard store.operationFailureNotice == nil,
              let current = store.engine.subtasks[subtaskID],
              current.updatedAt > before.updatedAt
        else {
            throw Failure.failed(
                "real Store subtask mutation failed or did not advance updatedAt"
            )
        }
        try expect(current, matches: expected)
        mutationBits.append(exactBits(current.updatedAt))
        try assertPersistence(
            subtaskID: subtaskID,
            createdBits: exactBits(current.createdAt),
            mutationBits: mutationBits,
            expected: expected
        )
    }

    private func assertPersistence(
        subtaskID: SubtaskID,
        createdBits: UInt64,
        mutationBits: [UInt64],
        expected: ExpectedSubtask
    ) throws {
        guard let persisted = try persistedEngine().subtasks[subtaskID],
              exactBits(persisted.createdAt) == createdBits,
              hasSameBits(
                  persisted.updatedAt,
                  mutationBits.last ?? createdBits
              )
        else {
            throw Failure.failed(
                "SQLite subtask exact timestamps diverged from Store state"
            )
        }
        try expect(persisted, matches: expected)

        let targetEntries = try journalEntries().filter {
            $0.entityType == .subtask
                && $0.entityID == subtaskID.rawValue.uuidString
        }
        let expectedBits = [createdBits] + mutationBits
        guard targetEntries.count == expectedBits.count,
              targetEntries.allSatisfy({
                  $0.operation == .upsert && $0.recordPayload == nil
              }),
              targetEntries.map({
                  exactBits($0.changedAt)
              }) == expectedBits
        else {
            throw Failure.failed(
                "subtask journal did not preserve every exact mutation clock"
            )
        }
        _ = try assertSyncMapping(persisted)
    }

    private func assertSyncMapping(_ subtask: Subtask) throws -> UInt64 {
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: subtask,
            modifiedBy: Self.syncDeviceID
        )
        let decoded = try mapper.decodeSubtask(record)
        let updatedBits = exactBits(subtask.updatedAt)
        guard record.entityType == .subtask,
              record.entityID == subtask.id.rawValue.uuidString,
              exactBits(record.modifiedAt) == updatedBits,
              exactBits(decoded.updatedAt) == updatedBits,
              decoded == subtask
        else {
            throw Failure.failed(
                "SyncRecordMapper modifiedAt did not equal Subtask.updatedAt"
            )
        }
        return updatedBits
    }

    private func expect(
        _ subtask: Subtask,
        matches expected: ExpectedSubtask
    ) throws {
        guard subtask.status == expected.status,
              subtask.difficulty == expected.difficulty,
              (subtask.completedAt != nil) == expected.hasCompletedAt,
              subtask.settledAt == nil
        else {
            throw Failure.failed(
                "subtask status, completion, or difficulty did not match"
            )
        }
        if expected.hasCompletedAt {
            guard hasSameBits(subtask.completedAt, subtask.updatedAt) else {
                throw Failure.failed(
                    "completed subtask did not share one mutation clock"
                )
            }
        }
    }

    private func persistedEngine() throws -> NoonmarkEngine {
        try SQLiteEngineRepository(databaseURL: try databaseURL()).load()
    }

    private func journalEntries() throws -> [SyncJournalEntry] {
        try SQLiteSyncRepository(databaseURL: try databaseURL())
            .journalEntries()
    }

    private func databaseURL() throws -> URL {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              let path = AppLaunchArguments.value(after: "--data-url"),
              path.isEmpty == false
        else {
            throw Failure.failed(
                "subtask clock automation requires an isolated E2E database"
            )
        }
        return URL(fileURLWithPath: path)
    }

    private func exactBits(_ date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    private func hasSameBits(_ lhs: Date, _ rhs: Date) -> Bool {
        exactBits(lhs) == exactBits(rhs)
    }

    private func hasSameBits(_ lhs: Date?, _ rhs: Date) -> Bool {
        lhs.map(exactBits) == exactBits(rhs)
    }

    private func hasSameBits(_ date: Date, _ bits: UInt64?) -> Bool {
        bits.map { exactBits(date) == $0 } == true
    }

    private func strictlyIncreases(_ bits: [UInt64]) -> Bool {
        zip(bits, bits.dropFirst()).allSatisfy(<)
    }

    private func writeState(_ state: State, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> State {
        try JSONDecoder().decode(
            State.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
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

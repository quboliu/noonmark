import Foundation
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkStorage
import NoonmarkSync

@MainActor
struct MutationClockE2EAutomation {
    private enum Mode {
        case exercise
        case verifyRestart
    }

    private struct State: Codable {
        let sourceDate: LocalDate
        let targetDate: LocalDate
        let sourceChainID: UUID
        let sourceDefinitionID: UUID
        let sourceTraceID: UUID
        let classificationRecordID: UUID
        let rolloverEventID: UUID
        let futureFrontierBits: UInt64
        let traceMutationBits: UInt64
        let classificationBits: UInt64
        let rolloverBits: UInt64
        var followUpChainID: UUID?
        var followUpDefinitionID: UUID?
        var followUpTraceID: UUID?
        var followUpBits: UInt64?
    }

    private static let sourceTitle = "E2E mutation clock source"
    private static let sourceDescription = "E2E mutation clock trace edit"
    private static let classificationLabel = "E2E mutation clock"
    private static let followUpTitle = "E2E mutation clock restart follow-up"

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains("--e2e-mutation-clock-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-mutation-clock-restart-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-mutation-clock-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-mutation-clock-result-url"
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
                    "mutation-clock automation requires the fixed natural-day adapter"
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
        let futureFrontier = try instant("2027-07-05T16:00:00Z")
        let rolloverReference = try instant("2026-07-06T04:30:00Z")
        let initialSample = try environment.sample()
        guard store.today == sourceDate,
              store.dayBoundaryState == .ready(appliedThrough: sourceDate),
              initialSample.instant < futureFrontier,
              store.engine.days.isEmpty,
              store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty,
              store.engine.subtasks.isEmpty,
              try journalEntries().isEmpty
        else {
            throw Failure.failed(
                "mutation-clock exercise did not start from its isolated source day"
            )
        }

        let fixture = try installFutureFrontierFixture(
            on: store,
            date: sourceDate,
            frontier: futureFrontier
        )
        try assertFixturePersistence(
            fixture,
            date: sourceDate,
            frontier: futureFrontier
        )

        store.updateTraceText(
            traceID: fixture.traceID,
            descriptionText: Self.sourceDescription
        )
        guard store.operationFailureNotice == nil,
              let editedTrace = store.engine.traces[fixture.traceID],
              editedTrace.descriptionText == Self.sourceDescription,
              editedTrace.contentUpdatedAt > futureFrontier
        else {
            throw Failure.failed(
                "ordinary Store trace mutation did not advance beyond the future frontier"
            )
        }
        let traceMutation = editedTrace.contentUpdatedAt
        try assertPersistedTraceEdit(
            fixture.traceID,
            at: traceMutation
        )

        let receipt = try store.replaceTaskClassification(
            chainID: fixture.chainID,
            category: nil,
            labels: [
                .new(
                    name: Self.classificationLabel,
                    colorHex: "#0E9488"
                )
            ]
        )
        guard let classificationRecord = store.engine.snapshot()
            .classifications.changeRecords.first(where: {
                $0.id == receipt.changeRecordID
            }),
            classificationRecord.committedAt > traceMutation,
            store.currentClassification(for: fixture.chainID)?
            .labels.contains(where: {
                $0.name == Self.classificationLabel
            }) == true
        else {
            throw Failure.failed(
                "classification commit did not advance beyond the trace mutation"
            )
        }
        let classificationMoment = classificationRecord.committedAt
        try expectJournalTimes(
            try journalEntries(),
            type: .classificationCommit,
            entityID: classificationRecord.id.uuidString,
            dates: [classificationMoment]
        )

        environment.update(
            instant: rolloverReference,
            timeZoneIdentifier: "America/New_York",
            signal: .wake
        )
        let classificationState = store.engine.snapshot().classifications
        guard store.today == targetDate,
              store.dayBoundaryState == .ready(appliedThrough: targetDate),
              let rolledTrace = store.engine.traces[fixture.traceID],
              rolledTrace.status == .unfinished,
              rolledTrace.descriptionText == Self.sourceDescription,
              let rolloverMoment = rolledTrace.settledAt,
              rolloverMoment > classificationMoment,
              hasSameBits(rolledTrace.contentUpdatedAt, rolloverMoment),
              let rolledDay = store.engine.days[sourceDate],
              hasSameBits(rolledDay.lockedAt, rolloverMoment),
              hasSameBits(rolledDay.updatedAt, rolloverMoment),
              let rolloverEvents = classificationState
              .snapshotEventsByTraceID[fixture.traceID],
              rolloverEvents.count == 1,
              let rolloverEvent = rolloverEvents.first,
              rolloverEvent.status == .unfinished,
              hasSameBits(rolloverEvent.capturedAt, rolloverMoment)
        else {
            throw Failure.failed(
                "natural-day rollover did not use one logical transaction clock"
            )
        }

        let state = State(
            sourceDate: sourceDate,
            targetDate: targetDate,
            sourceChainID: fixture.chainID.rawValue,
            sourceDefinitionID: fixture.definitionID.rawValue,
            sourceTraceID: fixture.traceID.rawValue,
            classificationRecordID: classificationRecord.id,
            rolloverEventID: rolloverEvent.id,
            futureFrontierBits: exactBits(futureFrontier),
            traceMutationBits: exactBits(traceMutation),
            classificationBits: exactBits(classificationMoment),
            rolloverBits: exactBits(rolloverMoment),
            followUpChainID: nil,
            followUpDefinitionID: nil,
            followUpTraceID: nil,
            followUpBits: nil
        )
        try assertExercisePersistence(
            state,
            expectedJournalCount: 9
        )
        try writeState(state)
    }

    private func verifyRestart(
        on store: NoonmarkStore,
        environment: FixedNaturalDayEnvironment
    ) throws {
        var state = try readState()
        let sample = try environment.sample()
        guard store.today == state.targetDate,
              store.dayBoundaryState == .ready(appliedThrough: state.targetDate),
              sample.timeZoneIdentifier == "America/New_York",
              state.followUpBits == nil,
              store.engine.days[state.targetDate] == nil
        else {
            throw Failure.failed(
                "mutation-clock restart did not reopen on its fixed target day"
            )
        }
        try assertExercisePersistence(
            state,
            expectedJournalCount: 9
        )

        guard store.addQuickTaskForToday(Self.followUpTitle),
              store.operationFailureNotice == nil,
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == Self.followUpTitle
              }),
              let chain = store.engine.chains[definition.chainID],
              let trace = store.engine.traces.values.first(where: {
                  $0.definitionID == definition.id
                      && $0.date == state.targetDate
              }),
              let day = store.engine.days[state.targetDate]
        else {
            throw Failure.failed(
                "ordinary Store mutation after restart did not create its task"
            )
        }

        let followUpMoment = definition.createdAt
        guard followUpMoment > date(from: state.rolloverBits),
              hasSameBits(chain.createdAt, followUpMoment),
              hasSameBits(chain.updatedAt, followUpMoment),
              hasSameBits(definition.contentUpdatedAt, followUpMoment),
              hasSameBits(trace.createdAt, followUpMoment),
              hasSameBits(trace.contentUpdatedAt, followUpMoment),
              hasSameBits(day.createdAt, followUpMoment),
              hasSameBits(day.updatedAt, followUpMoment)
        else {
            throw Failure.failed(
                "post-restart Store mutation did not advance as one logical transaction"
            )
        }

        state.followUpChainID = chain.id.rawValue
        state.followUpDefinitionID = definition.id.rawValue
        state.followUpTraceID = trace.id.rawValue
        state.followUpBits = exactBits(followUpMoment)
        try assertFinalPersistence(state)
        try writeState(state)
    }

    private func installFutureFrontierFixture(
        on store: NoonmarkStore,
        date: LocalDate,
        frontier: Date
    ) throws -> (
        chainID: TaskChainID,
        definitionID: TaskDefinitionID,
        traceID: DayTraceID
    ) {
        let candidate = try NoonmarkEngine(snapshot: store.engine.snapshot())
        let chainID = try candidate.createPoolTask(
            title: Self.sourceTitle,
            descriptionText: "future-frontier fixture",
            now: frontier
        )
        let traceID = try candidate.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: frontier
        )
        guard let definitionID = candidate.traces[traceID]?.definitionID else {
            throw Failure.failed(
                "future-frontier fixture did not create a trace definition"
            )
        }
        try store.save(candidate, mutationAt: frontier)
        store.engine = candidate
        return (chainID, definitionID, traceID)
    }

    private func assertFixturePersistence(
        _ fixture: (
            chainID: TaskChainID,
            definitionID: TaskDefinitionID,
            traceID: DayTraceID
        ),
        date: LocalDate,
        frontier: Date
    ) throws {
        let persisted = try persistedEngine()
        guard let chain = persisted.chains[fixture.chainID],
              let definition = persisted.definitions[fixture.definitionID],
              let trace = persisted.traces[fixture.traceID],
              let day = persisted.days[date],
              hasSameBits(chain.createdAt, frontier),
              hasSameBits(chain.updatedAt, frontier),
              hasSameBits(definition.createdAt, frontier),
              hasSameBits(definition.contentUpdatedAt, frontier),
              hasSameBits(trace.createdAt, frontier),
              hasSameBits(trace.contentUpdatedAt, frontier),
              hasSameBits(day.createdAt, frontier),
              hasSameBits(day.updatedAt, frontier)
        else {
            throw Failure.failed(
                "future-frontier fixture lost exact timestamps in SQLite"
            )
        }

        let entries = try journalEntries()
        try expectJournalTimes(
            entries,
            type: .taskChain,
            entityID: fixture.chainID.rawValue.uuidString,
            dates: [frontier]
        )
        try expectJournalTimes(
            entries,
            type: .taskDefinition,
            entityID: fixture.definitionID.rawValue.uuidString,
            dates: [frontier]
        )
        try expectJournalTimes(
            entries,
            type: .day,
            entityID: date.description,
            dates: [frontier]
        )
        try expectJournalTimes(
            entries,
            type: .dayTrace,
            entityID: fixture.traceID.rawValue.uuidString,
            dates: [frontier]
        )
    }

    private func assertPersistedTraceEdit(
        _ traceID: DayTraceID,
        at mutationInstant: Date
    ) throws {
        guard let trace = try persistedEngine().traces[traceID],
              trace.descriptionText == Self.sourceDescription,
              hasSameBits(trace.contentUpdatedAt, mutationInstant)
        else {
            throw Failure.failed(
                "ordinary trace edit lost its logical clock in SQLite"
            )
        }
        let matching = try journalEntries().filter {
            $0.entityType == .dayTrace
                && $0.entityID == traceID.rawValue.uuidString
                && hasSameBits($0.changedAt, mutationInstant)
        }
        guard matching.count == 1 else {
            throw Failure.failed(
                "ordinary trace edit did not create one exact journal entry"
            )
        }
    }

    private func assertExercisePersistence(
        _ state: State,
        expectedJournalCount: Int
    ) throws {
        let chainID = TaskChainID(state.sourceChainID)
        let definitionID = TaskDefinitionID(state.sourceDefinitionID)
        let traceID = DayTraceID(state.sourceTraceID)
        let persisted = try persistedEngine()
        let rollover = date(from: state.rolloverBits)
        guard let chain = persisted.chains[chainID],
              let definition = persisted.definitions[definitionID],
              let trace = persisted.traces[traceID],
              let day = persisted.days[state.sourceDate],
              trace.status == .unfinished,
              trace.descriptionText == Self.sourceDescription,
              hasSameBits(chain.createdAt, state.futureFrontierBits),
              hasSameBits(definition.createdAt, state.futureFrontierBits),
              hasSameBits(trace.createdAt, state.futureFrontierBits),
              hasSameBits(trace.contentUpdatedAt, rollover),
              hasSameBits(trace.settledAt, rollover),
              hasSameBits(day.updatedAt, rollover),
              hasSameBits(day.lockedAt, rollover),
              let record = persisted.snapshot()
              .classifications.changeRecords.first(where: {
                  $0.id == state.classificationRecordID
              }),
              hasSameBits(record.committedAt, state.classificationBits),
              let events = persisted.snapshot().classifications
              .snapshotEventsByTraceID[traceID],
              events.count == 1,
              let event = events.first,
              event.id == state.rolloverEventID,
              hasSameBits(event.capturedAt, rollover)
        else {
            throw Failure.failed(
                "restart-loaded entity facts diverged from mutation-clock state"
            )
        }

        let entries = try journalEntries()
        try expectJournalTimes(
            entries,
            type: .taskChain,
            entityID: state.sourceChainID.uuidString,
            bits: [state.futureFrontierBits]
        )
        try expectJournalTimes(
            entries,
            type: .taskDefinition,
            entityID: state.sourceDefinitionID.uuidString,
            bits: [state.futureFrontierBits]
        )
        try expectJournalTimes(
            entries,
            type: .day,
            entityID: state.sourceDate.description,
            bits: [state.futureFrontierBits, state.rolloverBits]
        )
        try expectJournalTimes(
            entries,
            type: .dayTrace,
            entityID: state.sourceTraceID.uuidString,
            bits: [
                state.futureFrontierBits,
                state.traceMutationBits,
                state.rolloverBits
            ]
        )
        try expectJournalTimes(
            entries,
            type: .classificationCommit,
            entityID: state.classificationRecordID.uuidString,
            bits: [state.classificationBits]
        )
        try expectJournalTimes(
            entries,
            type: .traceClassificationEvent,
            entityID: state.rolloverEventID.uuidString,
            bits: [state.rolloverBits]
        )
        guard entries.count == expectedJournalCount,
              state.futureFrontierBits < state.traceMutationBits,
              state.traceMutationBits < state.classificationBits,
              state.classificationBits < state.rolloverBits
        else {
            throw Failure.failed(
                "mutation-clock exercise journal is incomplete or out of order"
            )
        }
    }

    private func assertFinalPersistence(_ state: State) throws {
        try assertExercisePersistence(
            state,
            expectedJournalCount: 13
        )
        guard let followUpChainID = state.followUpChainID,
              let followUpDefinitionID = state.followUpDefinitionID,
              let followUpTraceID = state.followUpTraceID,
              let followUpBits = state.followUpBits
        else {
            throw Failure.failed(
                "mutation-clock final state is missing follow-up identities"
            )
        }
        let persisted = try persistedEngine()
        guard let chain = persisted.chains[TaskChainID(followUpChainID)],
              let definition = persisted.definitions[
                  TaskDefinitionID(followUpDefinitionID)
              ],
              let trace = persisted.traces[DayTraceID(followUpTraceID)],
              let day = persisted.days[state.targetDate],
              definition.title == Self.followUpTitle,
              hasSameBits(chain.createdAt, followUpBits),
              hasSameBits(chain.updatedAt, followUpBits),
              hasSameBits(definition.createdAt, followUpBits),
              hasSameBits(definition.contentUpdatedAt, followUpBits),
              hasSameBits(trace.createdAt, followUpBits),
              hasSameBits(trace.contentUpdatedAt, followUpBits),
              hasSameBits(day.createdAt, followUpBits),
              hasSameBits(day.updatedAt, followUpBits)
        else {
            throw Failure.failed(
                "post-restart entity facts lost their exact logical clock"
            )
        }

        let entries = try journalEntries()
        try expectJournalTimes(
            entries,
            type: .taskChain,
            entityID: followUpChainID.uuidString,
            bits: [followUpBits]
        )
        try expectJournalTimes(
            entries,
            type: .taskDefinition,
            entityID: followUpDefinitionID.uuidString,
            bits: [followUpBits]
        )
        try expectJournalTimes(
            entries,
            type: .day,
            entityID: state.targetDate.description,
            bits: [followUpBits]
        )
        try expectJournalTimes(
            entries,
            type: .dayTrace,
            entityID: followUpTraceID.uuidString,
            bits: [followUpBits]
        )
        guard entries.count == 13, followUpBits > state.rolloverBits else {
            throw Failure.failed(
                "post-restart journal did not advance beyond rollover"
            )
        }
    }

    private func expectJournalTimes(
        _ entries: [SyncJournalEntry],
        type: SyncEntityType,
        entityID: String,
        dates: [Date]
    ) throws {
        try expectJournalTimes(
            entries,
            type: type,
            entityID: entityID,
            bits: dates.map(exactBits)
        )
    }

    private func expectJournalTimes(
        _ entries: [SyncJournalEntry],
        type: SyncEntityType,
        entityID: String,
        bits: [UInt64]
    ) throws {
        let matches = entries.filter {
            $0.entityType == type && $0.entityID == entityID
        }
        let actualBits = matches.map {
            exactBits($0.changedAt)
        }.sorted()
        let payloadsAreValid = matches.allSatisfy { entry in
            switch type {
            case .classificationCommit, .traceClassificationEvent:
                entry.recordPayload?.isEmpty == false
            case .day, .taskCycleSeries, .taskChain, .taskDefinition, .dayTrace, .subtask,
                 .appPreferences:
                entry.recordPayload == nil
            }
        }
        guard matches.allSatisfy({ $0.operation == .upsert }),
              payloadsAreValid,
              actualBits == bits.sorted()
        else {
            throw Failure.failed(
                "journal clock mismatch for \(type.rawValue):\(entityID)"
            )
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
                "mutation-clock automation requires an isolated E2E database"
            )
        }
        return URL(fileURLWithPath: path)
    }

    private func exactBits(_ date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    private func date(from bits: UInt64) -> Date {
        Date(
            timeIntervalSinceReferenceDate: Double(bitPattern: bits)
        )
    }

    private func hasSameBits(_ lhs: Date, _ rhs: Date) -> Bool {
        exactBits(lhs) == exactBits(rhs)
    }

    private func hasSameBits(_ lhs: Date?, _ rhs: Date) -> Bool {
        lhs.map(exactBits) == exactBits(rhs)
    }

    private func hasSameBits(_ date: Date, _ bits: UInt64) -> Bool {
        exactBits(date) == bits
    }

    private func instant(_ text: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw Failure.failed(
                "invalid mutation-clock automation instant: \(text)"
            )
        }
        return date
    }

    private func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> State {
        try JSONDecoder().decode(
            State.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeResult(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(
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

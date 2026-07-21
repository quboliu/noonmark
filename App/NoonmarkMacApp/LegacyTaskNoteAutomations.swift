import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct TaskNoteE2EState: Codable {
    let chainID: TaskChainID
    let definitionID: TaskDefinitionID
    let traceID: DayTraceID
    let editedNoteID: TaskNoteEntryID
    let deletedNoteID: TaskNoteEntryID
}

struct TaskNoteE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case mutate
        case verify
        case copyContract
    }

    private static let title = "E2E 附言编辑删除"
    private static let editedBody = "VISIBLE NOTE 7263"
    private static let deletedBody = "GHOST NOTE 9184"

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteE2EAutomation? {
        let shouldMutate = AppLaunchArguments.contains("--e2e-task-note-mutate")
        let shouldVerify = AppLaunchArguments.contains("--e2e-task-note-verify")
        let shouldVerifyCopy = AppLaunchArguments.contains("--e2e-task-note-copy-contract")
        guard shouldMutate || shouldVerify || shouldVerifyCopy else { return nil }

        let mode: Mode? = switch (shouldMutate, shouldVerify, shouldVerifyCopy) {
        case (true, false, false): .mutate
        case (false, true, false): .verify
        case (false, false, true): .copyContract
        default: nil
        }
        return TaskNoteE2EAutomation(
            mode: mode,
            stateURL: AppLaunchArguments.value(after: "--e2e-task-note-state-url")
                .map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(after: "--e2e-task-note-result-url")
                .map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw TaskNoteE2EAutomationError.failed("missing or conflicting task-note automation arguments")
            }
            switch mode {
            case .mutate:
                let state = try prepareUIInteraction(on: store, stateURL: stateURL)
                TaskNoteE2EUIInteractionDriver.start(
                    editedNoteID: state.editedNoteID,
                    deletedNoteID: state.deletedNoteID,
                    editedBody: Self.editedBody,
                    hasDurablyPersistedEditedBody: {
                        hasDurablyPersistedTraceNote(
                            on: store,
                            state: state,
                            expectedBody: Self.editedBody
                        )
                    },
                    resultURL: resultURL
                )
            case .verify:
                try verify(on: store, stateURL: stateURL)
                try writeResult("ok", to: resultURL)
            case .copyContract:
                try verify(on: store, stateURL: stateURL)
                store.setLanguage(.english)
                let state = try readState(from: stateURL)
                TaskNoteCopyE2EUIInteractionDriver.start(
                    state: state,
                    resultURL: resultURL
                )
            }
        } catch {
            try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            switch mode {
            case .mutate, .copyContract:
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            case .verify, nil:
                break
            }
        }
    }

    @MainActor
    private func prepareUIInteraction(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws -> TaskNoteE2EState {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw TaskNoteE2EAutomationError.failed("isolated task-note database was not empty")
        }

        store.page = .pool
        store.poolText = Self.title
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID,
              let initialChain = store.engine.chains[chainID],
              initialChain.activeNoteEntries.count == 1
        else {
            throw TaskNoteE2EAutomationError.failed("task-note fixture was not created in the task pool")
        }

        store.detailNoteText = Self.deletedBody
        store.appendPoolNote(chainID: chainID)
        guard let chain = store.engine.chains[chainID],
              let definition = store.currentDefinition(for: chainID),
              chain.activeNoteEntries.count == 2,
              let editedNoteID = chain.activeNoteEntries.first?.id,
              let deletedNoteID = chain.activeNoteEntries.last?.id,
              editedNoteID != deletedNoteID
        else {
            throw TaskNoteE2EAutomationError.failed("task-note fixture did not contain two stable entries")
        }

        store.schedulePoolTask(chainID, date: store.today)
        guard let traceID = store.selectedTraceID,
              let scheduledTrace = store.engine.traces[traceID],
              scheduledTrace.definitionID == definition.id,
              scheduledTrace.activeNoteEntries.map(\.id) == [editedNoteID, deletedNoteID]
        else {
            throw TaskNoteE2EAutomationError.failed("task-note entries were not snapshotted into the Day Todo")
        }

        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.selectTrace(traceID)
        store.persist()
        let state = TaskNoteE2EState(
            chainID: chainID,
            definitionID: definition.id,
            traceID: traceID,
            editedNoteID: editedNoteID,
            deletedNoteID: deletedNoteID
        )
        try writeState(state, to: stateURL)
        return state
    }

    @MainActor
    private func verify(on store: NoonmarkStore, stateURL: URL) throws {
        let state = try readState(from: stateURL)
        guard let chain = store.engine.chains[state.chainID],
              chain.state == .active,
              let definition = store.engine.definitions[state.definitionID],
              definition.chainID == state.chainID,
              let trace = store.engine.traces[state.traceID],
              trace.chainID == state.chainID,
              trace.definitionID == state.definitionID,
              trace.noteEntries.count == 2,
              let editedEntry = trace.noteEntries.first(where: { $0.id == state.editedNoteID }),
              editedEntry.body == Self.editedBody,
              editedEntry.deletedAt == nil,
              editedEntry.updatedAt >= editedEntry.createdAt,
              let deletedEntry = trace.noteEntries.first(where: { $0.id == state.deletedNoteID }),
              deletedEntry.body.isEmpty,
              deletedEntry.deletedAt != nil,
              deletedEntry.updatedAt == deletedEntry.deletedAt,
              deletedEntry.updatedAt >= deletedEntry.createdAt,
              trace.activeNoteEntries.map(\.id) == [state.editedNoteID],
              chain.activeNoteEntries.count == 2,
              chain.activeNoteEntries.contains(where: {
                  $0.id == state.deletedNoteID && $0.body == Self.deletedBody
              })
        else {
            throw TaskNoteE2EAutomationError.failed("task-note state did not survive restart exactly")
        }

        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.selectTrace(state.traceID)
    }

    private func writeState(_ state: TaskNoteE2EState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> TaskNoteE2EState {
        try JSONDecoder().decode(TaskNoteE2EState.self, from: Data(contentsOf: url))
    }

    private func hasDurablyPersistedTraceNote(
        on store: NoonmarkStore,
        state: TaskNoteE2EState,
        expectedBody: String
    ) -> Bool {
        guard let databaseURL = store.databaseURL,
              let restored = try? SQLiteEngineRepository(databaseURL: databaseURL).load()
        else {
            return false
        }
        return restored.traces[state.traceID]?.activeNoteEntries.first(where: {
            $0.id == state.editedNoteID
        })?.body == expectedBody
    }

    private func writeResult(_ result: String, to url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct TaskPoolNoteE2EState: Codable {
    let chainID: TaskChainID
    let definitionID: TaskDefinitionID
    let editedNoteID: TaskNoteEntryID
    let deletedNoteID: TaskNoteEntryID
}

struct TaskPoolNoteE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case mutate
        case verify
    }

    private static let title = "E2E 任务池附言编辑删除"
    private static let editedBody = "POOL VISIBLE NOTE 7263"
    private static let deletedBody = "POOL GHOST NOTE 9184"

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskPoolNoteE2EAutomation? {
        let shouldMutate = AppLaunchArguments.contains("--e2e-task-pool-note-mutate")
        let shouldVerify = AppLaunchArguments.contains("--e2e-task-pool-note-verify")
        guard shouldMutate || shouldVerify else { return nil }

        let mode: Mode? = switch (shouldMutate, shouldVerify) {
        case (true, false): .mutate
        case (false, true): .verify
        default: nil
        }
        return TaskPoolNoteE2EAutomation(
            mode: mode,
            stateURL: AppLaunchArguments.value(after: "--e2e-task-pool-note-state-url")
                .map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(after: "--e2e-task-pool-note-result-url")
                .map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw TaskPoolNoteE2EAutomationError.failed(
                    "missing task-pool note automation arguments"
                )
            }
            switch mode {
            case .mutate:
                let state = try prepareUIInteraction(on: store, stateURL: stateURL)
                TaskNoteE2EUIInteractionDriver.start(
                    editedNoteID: state.editedNoteID,
                    deletedNoteID: state.deletedNoteID,
                    editedBody: Self.editedBody,
                    hasDurablyPersistedEditedBody: {
                        hasDurablyPersistedPoolNote(
                            on: store,
                            state: state,
                            expectedBody: Self.editedBody
                        )
                    },
                    resultURL: resultURL
                )
            case .verify:
                try verify(on: store, stateURL: stateURL)
                try writeResult("ok", to: resultURL)
            }
        } catch {
            try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            if case .mutate = mode {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func prepareUIInteraction(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws -> TaskPoolNoteE2EState {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw TaskPoolNoteE2EAutomationError.failed(
                "isolated task-pool note database was not empty"
            )
        }

        store.page = .pool
        store.poolText = Self.title
        store.addPoolTask()
        guard let chainID = store.selectedPoolChainID,
              let initialChain = store.engine.chains[chainID],
              initialChain.activeNoteEntries.count == 1
        else {
            throw TaskPoolNoteE2EAutomationError.failed(
                "task-pool note fixture was not created"
            )
        }

        store.detailNoteText = Self.deletedBody
        store.appendPoolNote(chainID: chainID)
        guard let chain = store.engine.chains[chainID],
              let definition = store.currentDefinition(for: chainID),
              chain.activeNoteEntries.count == 2,
              let editedNoteID = chain.activeNoteEntries.first?.id,
              let deletedNoteID = chain.activeNoteEntries.last?.id,
              editedNoteID != deletedNoteID
        else {
            throw TaskPoolNoteE2EAutomationError.failed(
                "task-pool note fixture did not contain two stable entries"
            )
        }

        store.selectPool(chainID)
        store.persist()
        let state = TaskPoolNoteE2EState(
            chainID: chainID,
            definitionID: definition.id,
            editedNoteID: editedNoteID,
            deletedNoteID: deletedNoteID
        )
        try writeState(state, to: stateURL)
        return state
    }

    @MainActor
    private func verify(on store: NoonmarkStore, stateURL: URL) throws {
        let state = try readState(from: stateURL)
        guard let chain = store.engine.chains[state.chainID],
              chain.state == .active,
              let definition = store.engine.definitions[state.definitionID],
              definition.chainID == state.chainID,
              store.engine.taskPool().contains(where: { $0.chain.id == state.chainID }),
              chain.noteEntries.count == 2,
              let editedEntry = chain.noteEntries.first(where: { $0.id == state.editedNoteID }),
              editedEntry.body == Self.editedBody,
              editedEntry.deletedAt == nil,
              let deletedEntry = chain.noteEntries.first(where: { $0.id == state.deletedNoteID }),
              deletedEntry.body.isEmpty,
              deletedEntry.deletedAt != nil,
              deletedEntry.updatedAt == deletedEntry.deletedAt,
              chain.activeNoteEntries.map(\.id) == [state.editedNoteID]
        else {
            throw TaskPoolNoteE2EAutomationError.failed(
                "task-pool note state did not survive restart exactly"
            )
        }
        store.page = .pool
        store.selectPool(state.chainID)
    }

    private func hasDurablyPersistedPoolNote(
        on store: NoonmarkStore,
        state: TaskPoolNoteE2EState,
        expectedBody: String
    ) -> Bool {
        guard let databaseURL = store.databaseURL,
              let restored = try? SQLiteEngineRepository(databaseURL: databaseURL).load()
        else {
            return false
        }
        return restored.taskPool().first(where: { $0.chain.id == state.chainID })?
            .chain.activeNoteEntries.first(where: { $0.id == state.editedNoteID })?
            .body == expectedBody
    }

    private func writeState(_ state: TaskPoolNoteE2EState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> TaskPoolNoteE2EState {
        try JSONDecoder().decode(TaskPoolNoteE2EState.self, from: Data(contentsOf: url))
    }

    private func writeResult(_ result: String, to url: URL?) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum TaskPoolNoteE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}

private enum TaskNoteE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct TaskNoteMutationAtomicityE2EState: Codable {
    let baseline: NoonmarkSnapshot
    let poolChainID: TaskChainID
    let poolEditedNoteID: TaskNoteEntryID
    let poolDeletedNoteID: TaskNoteEntryID
    let traceID: DayTraceID
    let traceEditedNoteID: TaskNoteEntryID
    let traceDeletedNoteID: TaskNoteEntryID
}

private enum TaskNoteMutationAtomicityFixture {
    static let retriedUIBody = "RETRIED UI TRACE EDIT 4973"
}

struct TaskNoteMutationAtomicityUIE2EAutomation: LaunchAutomationRunnable {
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteMutationAtomicityUIE2EAutomation? {
        guard AppLaunchArguments.contains(
            "--e2e-task-note-atomicity-ui-edit"
        ) else { return nil }
        return TaskNoteMutationAtomicityUIE2EAutomation(
            stateURL: AppLaunchArguments.value(
                after: "--e2e-task-note-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(
                after: "--e2e-task-note-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let stateURL, let resultURL else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "missing task-note atomicity UI arguments"
                )
            }
            let state = try JSONDecoder().decode(
                TaskNoteMutationAtomicityE2EState.self,
                from: Data(contentsOf: stateURL)
            )
            guard store.engine.snapshot() == state.baseline else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "task-note atomicity UI fixture did not match the persisted baseline"
                )
            }
            store.page = .day
            store.selectedDate = store.today
            store.selectedCalendarDate = store.today
            store.selectTrace(state.traceID)
            try store.armPersistenceFailureForE2E()
            TaskNotePersistenceFailureUIE2EDriver.start(
                noteID: state.traceEditedNoteID,
                otherNoteID: state.traceDeletedNoteID,
                editedBody: TaskNoteMutationAtomicityFixture.retriedUIBody,
                expectedFailureMessage: AppPresentation(
                    language: store.engine.preferences.language
                ).failureMessage(for: .noteMutation),
                resultURL: resultURL
            )
        } catch {
            store.disarmPersistenceFailureForE2E()
            if let resultURL {
                try? FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? "failed: \(error.localizedDescription)".write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            NSApp.terminate(nil)
        }
    }
}

struct TaskNoteMutationAtomicityE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case exerciseFailures
        case verifyRestart
    }

    private static let poolOriginalBody = "POOL ORIGINAL NOTE 1832"
    private static let poolDeleteBody = "POOL DELETE TARGET 5471"
    private static let traceOriginalBody = "TRACE ORIGINAL NOTE 2604"
    private static let traceDeleteBody = "TRACE DELETE TARGET 8395"

    private let mode: Mode?
    let stateURL: URL?
    let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskNoteMutationAtomicityE2EAutomation? {
        let exercisesFailures = AppLaunchArguments.contains(
            "--e2e-task-note-atomicity-exercise"
        )
        let verifiesRestart = AppLaunchArguments.contains(
            "--e2e-task-note-atomicity-verify"
        )
        guard exercisesFailures || verifiesRestart else { return nil }

        let mode: Mode? = switch (exercisesFailures, verifiesRestart) {
        case (true, false): .exerciseFailures
        case (false, true): .verifyRestart
        default: nil
        }
        return TaskNoteMutationAtomicityE2EAutomation(
            mode: mode,
            stateURL: AppLaunchArguments.value(
                after: "--e2e-task-note-atomicity-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(
                after: "--e2e-task-note-atomicity-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw TaskNoteMutationAtomicityE2EError.failed(
                    "missing or conflicting task-note atomicity arguments"
                )
            }
            switch mode {
            case .exerciseFailures:
                try exerciseFailures(on: store, stateURL: stateURL)
            case .verifyRestart:
                try verifyRestart(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult("failed: \(error.localizedDescription)", to: resultURL)
            }
        }
    }

    @MainActor
    private func exerciseFailures(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "isolated task-note atomicity database was not empty"
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 804_600_000)
        let poolChainID = try store.engine.createPoolTask(
            title: "E2E 附言保存失败任务池",
            initialNoteBody: Self.poolOriginalBody,
            now: base
        )
        let poolEditedNoteID = try requiredNoteID(
            store.engine.chains[poolChainID]?.activeNoteEntries.first?.id,
            label: "pool edit target"
        )
        let poolDeletedNoteID = try store.engine.appendPoolNote(
            chainID: poolChainID,
            body: Self.poolDeleteBody,
            now: base.addingTimeInterval(1)
        )

        let traceChainID = try store.engine.createPoolTask(
            title: "E2E 附言保存失败日轨迹",
            initialNoteBody: Self.traceOriginalBody,
            now: base.addingTimeInterval(2)
        )
        let traceEditedNoteID = try requiredNoteID(
            store.engine.chains[traceChainID]?.activeNoteEntries.first?.id,
            label: "trace edit target"
        )
        let traceDeletedNoteID = try store.engine.appendPoolNote(
            chainID: traceChainID,
            body: Self.traceDeleteBody,
            now: base.addingTimeInterval(3)
        )
        let traceID = try store.engine.scheduleFromPool(
            chainID: traceChainID,
            date: store.today,
            today: store.today,
            now: base.addingTimeInterval(4)
        )
        store.persist()

        let baseline = store.engine.snapshot()
        try baseline.validateIntegrity()
        let state = TaskNoteMutationAtomicityE2EState(
            baseline: baseline,
            poolChainID: poolChainID,
            poolEditedNoteID: poolEditedNoteID,
            poolDeletedNoteID: poolDeletedNoteID,
            traceID: traceID,
            traceEditedNoteID: traceEditedNoteID,
            traceDeletedNoteID: traceDeletedNoteID
        )
        try writeState(state, to: stateURL)
        try verifyPersistedBaseline(baseline)

        var failures: [String] = []
        failures += rejectionFailures(
            label: "pool append",
            store: store,
            baseline: baseline,
            composerInput: "UNSAVED POOL APPEND 4136"
        ) {
            store.appendPoolNote(chainID: poolChainID)
        }
        failures += rejectionFailures(
            label: "pool edit",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED POOL COMPOSER 7870"
        ) {
            store.editPoolNote(
                chainID: poolChainID,
                noteID: poolEditedNoteID,
                body: "UNSAVED POOL EDIT 6218"
            )
        }
        failures += rejectionFailures(
            label: "pool delete",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED POOL DELETE COMPOSER 9465"
        ) {
            store.deletePoolNote(chainID: poolChainID, noteID: poolDeletedNoteID)
        }
        failures += rejectionFailures(
            label: "trace append",
            store: store,
            baseline: baseline,
            composerInput: "UNSAVED TRACE APPEND 3581"
        ) {
            store.appendTraceNote(traceID: traceID)
        }
        failures += rejectionFailures(
            label: "trace edit",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED TRACE COMPOSER 1049"
        ) {
            store.editTraceNote(
                traceID: traceID,
                noteID: traceEditedNoteID,
                body: "UNSAVED TRACE EDIT 5724"
            )
        }
        failures += rejectionFailures(
            label: "trace delete",
            store: store,
            baseline: baseline,
            composerInput: "UNCHANGED TRACE DELETE COMPOSER 8357"
        ) {
            store.deleteTraceNote(traceID: traceID, noteID: traceDeletedNoteID)
        }
        failures += versionConflictFailures(
            store: store,
            baseline: baseline,
            traceID: traceID,
            noteID: traceEditedNoteID
        )

        guard failures.isEmpty else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                failures.joined(separator: "; ")
            )
        }
        try verifyPersistedBaseline(baseline)
    }

    @MainActor
    private func rejectionFailures(
        label: String,
        store: NoonmarkStore,
        baseline: NoonmarkSnapshot,
        composerInput: String,
        mutation: () -> Void
    ) -> [String] {
        var failures: [String] = []
        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.dismissOperationFailure()
        store.detailNoteText = composerInput
        do {
            try store.armPersistenceFailureForE2E()
        } catch {
            return ["\(label) could not arm isolated save failure: \(error.localizedDescription)"]
        }

        mutation()
        store.disarmPersistenceFailureForE2E()
        if store.engine.snapshot() != baseline {
            failures.append("\(label) published an unpersisted engine mutation")
        }
        if store.detailNoteText != composerInput {
            failures.append("\(label) cleared user input after save failure")
        }
        let expectedFailure = AppPresentation(
            language: store.engine.preferences.language
        ).failureMessage(for: .noteMutation)
        let hasIncorrectFailurePresentation = store.toast != nil
            || store.operationFailure != expectedFailure
            || store.operationFailureNotice?.context != .noteMutation
        if hasIncorrectFailurePresentation {
            failures.append(
                "\(label) did not keep one persistent save-failure message: "
                    + "toast=\(store.toast ?? "none"), "
                    + "failure=\(store.operationFailure ?? "missing")"
            )
        }

        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        do {
            try store.armPersistenceFailureForE2E()
            store.undo()
            store.disarmPersistenceFailureForE2E()
            if store.toast != "没有可撤销的操作" {
                failures.append("\(label) changed the undo stack after save failure")
            }
        } catch {
            store.disarmPersistenceFailureForE2E()
            failures.append("\(label) undo-stack probe failed: \(error.localizedDescription)")
        }

        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.detailNoteText = composerInput
        return failures
    }

    @MainActor
    private func versionConflictFailures(
        store: NoonmarkStore,
        baseline: NoonmarkSnapshot,
        traceID: DayTraceID,
        noteID: TaskNoteEntryID
    ) -> [String] {
        var failures: [String] = []
        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.dismissOperationFailure()
        guard let originalEntry = store.engine.traces[traceID]?
            .activeNoteEntries.first(where: { $0.id == noteID })
        else {
            return ["version-conflict probe could not find its original note"]
        }

        do {
            try store.engine.editTraceNote(
                traceID: traceID,
                noteID: noteID,
                body: "CONCURRENT TRACE NOTE 6041",
                today: store.today,
                now: originalEntry.updatedAt.addingTimeInterval(1)
            )
        } catch {
            return ["version-conflict fixture failed: \(error.localizedDescription)"]
        }
        let concurrentSnapshot = store.engine.snapshot()
        let committed = store.editTraceNote(
            traceID: traceID,
            noteID: noteID,
            body: "STALE TRACE NOTE 9917",
            expectedUpdatedAt: originalEntry.updatedAt
        )
        if committed {
            failures.append("stale note edit was committed")
        }
        if store.engine.snapshot() != concurrentSnapshot {
            failures.append("stale note edit overwrote the concurrent note")
        }
        if store.operationFailureNotice?.context != .noteMutation {
            failures.append("stale note edit did not publish note-conflict feedback")
        }

        store.engine = (try? NoonmarkEngine(snapshot: baseline)) ?? NoonmarkEngine()
        store.clearUndoHistory()
        store.dismissOperationFailure()
        return failures
    }

    @MainActor
    private func verifyRestart(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        guard let retriedEntry = store.engine.traces[state.traceID]?
            .activeNoteEntries.first(where: { $0.id == state.traceEditedNoteID })
        else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "retried task-note edit was missing after restart"
            )
        }
        let expected = try NoonmarkEngine(snapshot: state.baseline)
        try expected.editTraceNote(
            traceID: state.traceID,
            noteID: state.traceEditedNoteID,
            body: TaskNoteMutationAtomicityFixture.retriedUIBody,
            today: store.today,
            now: retriedEntry.updatedAt
        )
        guard snapshot == expected.snapshot(),
              store.engine.chains[state.poolChainID]?.activeNoteEntries.map(\.id) == [
                  state.poolEditedNoteID,
                  state.poolDeletedNoteID
              ],
              store.engine.traces[state.traceID]?.activeNoteEntries.map(\.id) == [
                  state.traceEditedNoteID,
                  state.traceDeletedNoteID
              ]
        else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "failed task-note mutations changed restarted state"
            )
        }
    }

    @MainActor
    private func verifyPersistedBaseline(_ baseline: NoonmarkSnapshot) throws {
        guard let databasePath = AppLaunchArguments.value(after: "--data-url") else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "task-note atomicity E2E requires an explicit data URL"
            )
        }
        let persisted = try SQLiteEngineRepository(
            databaseURL: URL(fileURLWithPath: databasePath)
        ).load().snapshot()
        guard persisted == baseline else {
            throw TaskNoteMutationAtomicityE2EError.failed(
                "isolated SQLite state diverged from the in-memory baseline"
            )
        }
    }

    private func requiredNoteID(
        _ noteID: TaskNoteEntryID?,
        label: String
    ) throws -> TaskNoteEntryID {
        guard let noteID else {
            throw TaskNoteMutationAtomicityE2EError.failed("missing \(label)")
        }
        return noteID
    }

    private func writeState(
        _ state: TaskNoteMutationAtomicityE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> TaskNoteMutationAtomicityE2EState {
        try JSONDecoder().decode(
            TaskNoteMutationAtomicityE2EState.self,
            from: Data(contentsOf: url)
        )
    }

    private func writeResult(_ result: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum TaskNoteMutationAtomicityE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct TaskTitleDeleteE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> TaskTitleDeleteE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-task-title-delete-workflow") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-task-title-delete-result-url")
            .map { URL(fileURLWithPath: $0) }
        return TaskTitleDeleteE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.engine = NoonmarkEngine()
            let today = store.today
            let tomorrow = NoonmarkStore.offset(today, by: 1)
            let yesterday = NoonmarkStore.offset(today, by: -1)

            let poolChainID = try store.engine.createPoolTask(title: "E2E 任务池旧标题")
            let markdownTitle = "**E2E 任务池**\n软换行  \n硬换行"
            store.renamePoolTask(chainID: poolChainID, title: markdownTitle)
            try expect(store.engine.taskPool().first?.definition.title == markdownTitle, "pool title did not preserve Markdown lines")

            let deleteChainID = try store.engine.createPoolTask(title: "E2E 任务池删除")
            store.deletePoolTask(deleteChainID)
            try expect(
                store.engine.chains[deleteChainID]?.state == .abandoned,
                "unscheduled pool task did not retain its hidden chain fact"
            )
            try expect(
                store.engine.definitions.values.contains {
                    $0.chainID == deleteChainID
                },
                "unscheduled pool task did not retain its definition fact"
            )
            try expect(
                store.engine.taskPool().contains {
                    $0.chain.id == deleteChainID
                } == false,
                "unscheduled pool task remained user-visible"
            )

            let currentChainID = try store.engine.createPoolTask(title: "E2E 今日旧标题")
            let currentTraceID = try store.engine.scheduleFromPool(chainID: currentChainID, date: today, today: today)
            store.renameTraceTitle(traceID: currentTraceID, title: "E2E 今日新标题")
            let currentTrace = try trace(currentTraceID, in: store)
            try expect(currentTrace.status == .pending, "current rename changed trace status")
            try expect(store.definition(for: currentTrace)?.title == "E2E 今日新标题", "current title did not rename")
            try expect(store.engine.traces.values.allSatisfy { $0.status != .changed }, "rename created changed trace")

            let futureChainID = try store.engine.createPoolTask(title: "E2E 未来旧标题")
            let futureTraceID = try store.engine.scheduleFromPool(chainID: futureChainID, date: tomorrow, today: today)
            store.renameTraceTitle(traceID: futureTraceID, title: "E2E 未来新标题")
            try expect(store.definition(for: try trace(futureTraceID, in: store))?.title == "E2E 未来新标题", "future title did not rename")

            let returnedChainID = try store.engine.createPoolTask(title: "E2E 回池删除")
            let returnedTraceID = try store.engine.scheduleFromPool(chainID: returnedChainID, date: today, today: today)
            store.returnToPool(returnedTraceID)
            store.deletePoolTask(returnedChainID)
            try expect(store.engine.traces[returnedTraceID]?.status == .returnedToPool, "returned trace was deleted")
            try expect(store.engine.taskPool().contains { $0.chain.id == returnedChainID } == false, "returned chain remained in pool")

            let completedChainID = try store.engine.createPoolTask(title: "E2E 已完成旧标题")
            let completedTraceID = try store.engine.scheduleFromPool(chainID: completedChainID, date: today, today: today)
            try store.engine.markCompleted(traceID: completedTraceID, today: today)
            try expectThrows {
                try store.engine.renameTaskTitle(chainID: completedChainID, title: "E2E 已完成新标题", today: today)
            }

            let unfinishedChainID = try store.engine.createPoolTask(title: "E2E 未完成旧标题")
            _ = try store.engine.scheduleFromPool(chainID: unfinishedChainID, date: yesterday, today: yesterday)
            try store.engine.settleDays(upTo: today)
            try expectThrows {
                try store.engine.renameTaskTitle(chainID: unfinishedChainID, title: "E2E 未完成新标题", today: today)
            }

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func trace(_ id: DayTraceID, in store: NoonmarkStore) throws -> DayTrace {
        guard let trace = store.engine.traces[id] else {
            throw TaskTitleDeleteE2EAutomationError.failed("missing trace")
        }
        return trace
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TaskTitleDeleteE2EAutomationError.failed(message)
        }
    }

    private func expectThrows(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TaskTitleDeleteE2EAutomationError.failed("operation unexpectedly succeeded")
        } catch let error as TaskTitleDeleteE2EAutomationError {
            throw error
        } catch {}
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum TaskTitleDeleteE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

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

private struct NewTodayTaskUndoEvidence: Codable {
    let title: String
    let dateISO8601: String
    let chainID: UUID
    let definitionID: UUID
    let traceID: UUID
    let cancellationID: UUID
    let creationBits: UInt64
    let undoBits: UInt64
}

private struct ScheduledPoolTaskUndoEvidence: Codable {
    let title: String
    let dateISO8601: String
    let chainID: UUID
    let definitionID: UUID
    let traceID: UUID
    let cancellationID: UUID
    let poolCreationBits: UInt64
    let scheduleBits: UInt64
    let undoBits: UInt64
}

private struct AddedSubtaskUndoEvidence: Codable {
    let parentTitle: String
    let subtaskTitle: String
    let dateISO8601: String
    let chainID: UUID
    let definitionID: UUID
    let traceID: UUID
    let subtaskID: UUID
    let cancellationID: UUID
    let parentCreationBits: UInt64
    let subtaskCreationBits: UInt64
    let firstUndoBits: UInt64
    let redoBits: UInt64
    let finalUndoBits: UInt64
}

private struct CopiedTaskUndoEvidence: Codable {
    let title: String
    let chainID: UUID
    let definitionID: UUID
    let creationBits: UInt64
    let undoBits: UInt64
}

private struct ContinuationUndoEvidence: Codable {
    let title: String
    let sourceDateISO8601: String
    let targetDateISO8601: String
    let chainID: UUID
    let definitionID: UUID
    let sourceTraceID: UUID
    let targetTraceID: UUID
    let cancellationID: UUID
    let sourceCreationBits: UInt64
    let continuationBits: UInt64
    let undoBits: UInt64
}

private struct CopyUndoPersistenceE2EState: Codable {
    let sourceChainID: String
    let sourceTraceID: DayTraceID
    let copiedTask: CopiedTaskUndoEvidence
    let newTodayTask: NewTodayTaskUndoEvidence
    let scheduledPoolTask: ScheduledPoolTaskUndoEvidence
    let addedSubtask: AddedSubtaskUndoEvidence
    let continuation: ContinuationUndoEvidence
    let classificationRevision: UInt64
    let sourceHistoryEventCount: Int
}

struct CopyUndoPersistenceE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case verify
    }

    private let mode: Mode?
    private let stateURL: URL?
    private let resultURL: URL?

    @MainActor
    static func fromCommandLine() -> Self? {
        let shouldSetup = AppLaunchArguments.contains(
            "--e2e-copy-undo-persistence-setup"
        )
        let shouldVerify = AppLaunchArguments.contains(
            "--e2e-copy-undo-persistence-verify"
        )
        guard shouldSetup || shouldVerify else { return nil }
        let mode: Mode? = switch (shouldSetup, shouldVerify) {
        case (true, false): .setup
        case (false, true): .verify
        default: nil
        }
        return Self(
            mode: mode,
            stateURL: AppLaunchArguments.value(
                after: "--e2e-copy-undo-persistence-state-url"
            ).map { URL(fileURLWithPath: $0) },
            resultURL: AppLaunchArguments.value(
                after: "--e2e-copy-undo-persistence-result-url"
            ).map { URL(fileURLWithPath: $0) }
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let mode, let stateURL, let resultURL else {
                throw CopyUndoPersistenceE2EError.failed(
                    "missing or conflicting copy-undo persistence arguments"
                )
            }
            switch mode {
            case .setup:
                try setup(on: store, stateURL: stateURL)
            case .verify:
                try verify(on: store, stateURL: stateURL)
            }
            try writeResult("ok", to: resultURL)
        } catch {
            if let resultURL {
                try? writeResult(
                    "failed: \(error.localizedDescription)",
                    to: resultURL
                )
            }
        }
    }

    @MainActor
    private func setup(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        guard store.engine.chains.isEmpty,
              store.engine.definitions.isEmpty,
              store.engine.traces.isEmpty
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "isolated copy-undo database was not empty"
            )
        }

        let past = NoonmarkStore.offset(store.today, by: -1)
        let sourceChainID = try store.engine.createPoolTask(
            title: "E2E 持久化已分类复制来源"
        )
        let sourceTraceID = try store.engine.scheduleFromPool(
            chainID: sourceChainID,
            date: past,
            today: past
        )
        _ = try store.replaceTaskClassification(
            chainID: sourceChainID,
            category: .new(name: "E2E 持久化分类", colorHex: "#2A6FDB"),
            labels: [.new(name: "E2E 持久化标签", colorHex: "#0E9488")]
        )
        try store.engine.markCompleted(traceID: sourceTraceID, today: past)
        try store.engine.settleDays(upTo: store.today)
        let beforeCopy = store.engine.snapshot()
        let sourceChainBefore = store.engine.chains[sourceChainID]
        let sourceTraceBefore = store.engine.traces[sourceTraceID]
        let sourceHistoryBefore = try sourceHistory(
            in: store,
            traceID: sourceTraceID
        )

        store.clearUndoHistory()
        store.copyAsNewTask(sourceTraceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "persisted classified copy"
        )
        let copiedChainBeforeUndo = try unwrap(
            store.engine.chains[copiedChainID],
            "persisted classified copy chain"
        )
        let copiedDefinitionBeforeUndo = try currentDefinition(
            in: store,
            chainID: copiedChainID
        )
        let copiedBeforeUndo = try taskClassification(
            in: store,
            chainID: copiedChainID
        )
        guard copiedBeforeUndo.category?.name == "E2E 持久化分类",
              copiedBeforeUndo.labels.map(\.name) == ["E2E 持久化标签"]
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "persisted copy did not inherit source classification"
            )
        }

        store.undo()
        guard store.toast == "已撤销" else {
            throw CopyUndoPersistenceE2EError.failed(
                "persistent copy undo failed: \(store.toast ?? "missing toast")"
            )
        }
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        let copiedAfterUndo = try taskClassification(
            in: store,
            chainID: copiedChainID
        )
        let sourceAfterUndo = try taskClassification(
            in: store,
            chainID: sourceChainID
        )
        let sourceHistoryAfter = try sourceHistory(
            in: store,
            traceID: sourceTraceID
        )
        let copiedChainAfterUndo = try unwrap(
            store.engine.chains[copiedChainID],
            "hidden copied chain"
        )
        let copiedTask = CopiedTaskUndoEvidence(
            title: copiedDefinitionBeforeUndo.title,
            chainID: copiedChainID.rawValue,
            definitionID: copiedDefinitionBeforeUndo.id.rawValue,
            creationBits: exactBits(copiedChainBeforeUndo.createdAt),
            undoBits: exactBits(copiedChainAfterUndo.updatedAt)
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              copiedAfterUndo.category == nil,
              copiedAfterUndo.labels.isEmpty,
              store.engine.chains[sourceChainID] == sourceChainBefore,
              store.engine.traces[sourceTraceID] == sourceTraceBefore,
              sourceAfterUndo.category?.name == "E2E 持久化分类",
              sourceAfterUndo.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistoryAfter == sourceHistoryBefore,
              snapshot.classifications.changeRecords.starts(
                  with: beforeCopy.classifications.changeRecords
              ),
              snapshot.classifications.revision
                  == beforeCopy.classifications.revision + 2
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "copy undo did not append a compensating classification fact atomically"
            )
        }
        try assertCopiedTaskUndo(copiedTask, in: store)

        let newTodayTask = try exerciseNewTodayTaskUndo(on: store)
        let scheduledPoolTask = try exerciseScheduledPoolTaskUndo(on: store)
        let addedSubtask = try exerciseAddedSubtaskUndoRedoUndo(on: store)
        let continuation = try exerciseContinuationUndo(on: store)
        let persistedSnapshot = store.engine.snapshot()
        try persistedSnapshot.validateIntegrity()
        let state = CopyUndoPersistenceE2EState(
            sourceChainID: sourceChainID.rawValue.uuidString,
            sourceTraceID: sourceTraceID,
            copiedTask: copiedTask,
            newTodayTask: newTodayTask,
            scheduledPoolTask: scheduledPoolTask,
            addedSubtask: addedSubtask,
            continuation: continuation,
            classificationRevision:
            persistedSnapshot.classifications.revision,
            sourceHistoryEventCount: sourceHistoryAfter.events.count
        )
        try writeState(state, to: stateURL)
    }

    @MainActor
    private func verify(
        on store: NoonmarkStore,
        stateURL: URL
    ) throws {
        let state = try readState(from: stateURL)
        let snapshot = store.engine.snapshot()
        try snapshot.validateIntegrity()
        let sourceChainID = try parseTaskChainID(
            state.sourceChainID,
            field: "sourceChainID"
        )
        let source = try taskClassification(
            in: store,
            chainID: sourceChainID
        )
        let sourceHistory = try sourceHistory(
            in: store,
            traceID: state.sourceTraceID
        )
        let copiedChainID = TaskChainID(state.copiedTask.chainID)
        let copied = try taskClassification(
            in: store,
            chainID: copiedChainID
        )
        guard store.engine.traces[state.sourceTraceID]?.chainID
              == sourceChainID,
              store.engine.traces[state.sourceTraceID]?.status == .completed,
              source.category?.name == "E2E 持久化分类",
              source.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistory.category?.name == "E2E 持久化分类",
              sourceHistory.labels.map(\.name) == ["E2E 持久化标签"],
              sourceHistory.events.count == state.sourceHistoryEventCount,
              copied.category == nil,
              copied.labels.isEmpty,
              snapshot.classifications.revision == state.classificationRevision
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "classified copy undo state did not survive SQLite restart"
            )
        }
        try assertCopiedTaskUndo(state.copiedTask, in: store)
        try assertNewTodayTaskUndo(state.newTodayTask, in: store)
        try assertScheduledPoolTaskUndo(
            state.scheduledPoolTask,
            in: store
        )
        try assertAddedSubtaskUndo(state.addedSubtask, in: store)
        try assertContinuationUndo(state.continuation, in: store)
        try assertRestartProjectionMatrix(state, in: store)
    }

    @MainActor
    private func exerciseNewTodayTaskUndo(
        on store: NoonmarkStore
    ) throws -> NewTodayTaskUndoEvidence {
        let title = "E2E 撤销新增今日任务持久化"
        store.clearUndoHistory()
        guard store.addQuickTaskForToday(title),
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == title && $0.supersededAt == nil
              }),
              let chain = store.engine.chains[definition.chainID],
              let trace = store.engine.traces.values.first(where: {
                  $0.chainID == chain.id && $0.date == store.today
              }),
              store.canUndoDomainAction
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "new-today fixture did not enter the Store undo stack"
            )
        }
        let creationBits = exactBits(trace.createdAt)
        guard exactBits(chain.createdAt) == creationBits,
              exactBits(chain.updatedAt) == creationBits,
              exactBits(definition.createdAt) == creationBits,
              exactBits(definition.contentUpdatedAt) == creationBits
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "new-today fixture did not share one creation clock"
            )
        }

        store.undo()
        let cancelled = try unwrap(
            store.engine.traces[trace.id],
            "cancelled new-today trace"
        )
        let evidence = NewTodayTaskUndoEvidence(
            title: title,
            dateISO8601: store.today.description,
            chainID: chain.id.rawValue,
            definitionID: definition.id.rawValue,
            traceID: trace.id.rawValue,
            cancellationID: try unwrap(
                cancelled.draftCancellationID,
                "new-today cancellation identity"
            ),
            creationBits: creationBits,
            undoBits: exactBits(
                try unwrap(
                    cancelled.settledAt,
                    "new-today cancellation clock"
                )
            )
        )
        try assertNewTodayTaskUndo(evidence, in: store)
        return evidence
    }

    @MainActor
    private func exerciseScheduledPoolTaskUndo(
        on store: NoonmarkStore
    ) throws -> ScheduledPoolTaskUndoEvidence {
        let title = "E2E 撤销既有池任务排期持久化"
        let date = NoonmarkStore.offset(store.today, by: 2)
        store.clearUndoHistory()
        store.poolText = title
        store.addPoolTask()
        let definition = try unwrap(
            store.engine.definitions.values.first {
                $0.title == title && $0.supersededAt == nil
            },
            "scheduled-pool definition"
        )
        let chain = try unwrap(
            store.engine.chains[definition.chainID],
            "scheduled-pool chain"
        )
        let poolCreationBits = exactBits(chain.createdAt)
        guard store.engine.taskPool().contains(where: {
            $0.chain.id == chain.id
        }), exactBits(chain.updatedAt) == poolCreationBits,
            exactBits(definition.createdAt) == poolCreationBits,
            exactBits(definition.contentUpdatedAt) == poolCreationBits
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "scheduled-pool fixture was not a visible pool identity"
            )
        }

        store.clearUndoHistory()
        store.schedulePoolTask(chain.id, date: date)
        let trace = try unwrap(
            store.engine.traces.values.first {
                $0.chainID == chain.id && $0.date == date
            },
            "scheduled-pool target trace"
        )
        let scheduleBits = exactBits(trace.createdAt)
        guard store.canUndoDomainAction else {
            throw CopyUndoPersistenceE2EError.failed(
                "pool scheduling did not enter the Store undo stack"
            )
        }

        store.undo()
        let cancelled = try unwrap(
            store.engine.traces[trace.id],
            "cancelled scheduled-pool trace"
        )
        let evidence = ScheduledPoolTaskUndoEvidence(
            title: title,
            dateISO8601: date.description,
            chainID: chain.id.rawValue,
            definitionID: definition.id.rawValue,
            traceID: trace.id.rawValue,
            cancellationID: try unwrap(
                cancelled.draftCancellationID,
                "scheduled-pool cancellation identity"
            ),
            poolCreationBits: poolCreationBits,
            scheduleBits: scheduleBits,
            undoBits: exactBits(
                try unwrap(
                    cancelled.settledAt,
                    "scheduled-pool cancellation clock"
                )
            )
        )
        try assertScheduledPoolTaskUndo(evidence, in: store)
        return evidence
    }

    @MainActor
    private func exerciseAddedSubtaskUndoRedoUndo(
        on store: NoonmarkStore
    ) throws -> AddedSubtaskUndoEvidence {
        let parentTitle = "E2E 撤销直接新增子任务父任务"
        let subtaskTitle = "E2E 撤销直接新增子任务持久化"
        store.clearUndoHistory()
        guard store.addQuickTaskForToday(parentTitle),
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == parentTitle && $0.supersededAt == nil
              }),
              let chain = store.engine.chains[definition.chainID],
              let trace = store.engine.traces.values.first(where: {
                  $0.chainID == chain.id && $0.date == store.today
              })
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "added-subtask parent fixture could not be created"
            )
        }
        let parentCreationBits = exactBits(trace.createdAt)

        store.clearUndoHistory()
        store.selectTrace(trace.id)
        store.detailSubtaskText = subtaskTitle
        store.addDetailSubtask(traceID: trace.id)
        let created = try unwrap(
            store.engine.subtasks.values.first {
                $0.traceID == trace.id && $0.title == subtaskTitle
            },
            "added subtask"
        )
        let subtaskCreationBits = exactBits(created.createdAt)
        guard exactBits(created.updatedAt) == subtaskCreationBits,
              store.canUndoDomainAction
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "added subtask did not enter the Store undo stack"
            )
        }

        store.undo()
        let firstCancellation = try unwrap(
            store.engine.subtasks[created.id],
            "first cancelled subtask"
        )
        let cancellationID = try unwrap(
            firstCancellation.draftCancellationID,
            "subtask cancellation identity"
        )
        let firstUndoBits = exactBits(
            try unwrap(
                firstCancellation.settledAt,
                "first subtask cancellation clock"
            )
        )
        guard store.canRedoDomainAction else {
            throw CopyUndoPersistenceE2EError.failed(
                "added-subtask undo did not enter the Store redo stack"
            )
        }

        store.redo()
        let redone = try unwrap(
            store.engine.subtasks[created.id],
            "redone subtask"
        )
        let redoBits = exactBits(redone.updatedAt)
        guard redone.status == .pending,
              redone.draftCancellationID == cancellationID,
              store.canUndoDomainAction
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "added-subtask redo changed its identity or witness"
            )
        }

        store.undo()
        let finallyCancelled = try unwrap(
            store.engine.subtasks[created.id],
            "finally cancelled subtask"
        )
        let finalUndoBits = exactBits(
            try unwrap(
                finallyCancelled.settledAt,
                "final subtask cancellation clock"
            )
        )
        let evidence = AddedSubtaskUndoEvidence(
            parentTitle: parentTitle,
            subtaskTitle: subtaskTitle,
            dateISO8601: store.today.description,
            chainID: chain.id.rawValue,
            definitionID: definition.id.rawValue,
            traceID: trace.id.rawValue,
            subtaskID: created.id.rawValue,
            cancellationID: cancellationID,
            parentCreationBits: parentCreationBits,
            subtaskCreationBits: subtaskCreationBits,
            firstUndoBits: firstUndoBits,
            redoBits: redoBits,
            finalUndoBits: finalUndoBits
        )
        try assertAddedSubtaskUndo(evidence, in: store)
        return evidence
    }

    @MainActor
    private func exerciseContinuationUndo(
        on store: NoonmarkStore
    ) throws -> ContinuationUndoEvidence {
        let title = "E2E 持久化撤销延续隐藏目标"
        let targetDate = NoonmarkStore.offset(store.today, by: 1)
        store.clearUndoHistory()
        guard store.addQuickTaskForToday(title),
              let definition = store.engine.definitions.values.first(where: {
                  $0.title == title && $0.supersededAt == nil
              }),
              let chain = store.engine.chains[definition.chainID],
              let source = store.engine.traces.values.first(where: {
                  $0.chainID == chain.id && $0.date == store.today
              })
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "continuation fixture could not be created through Store"
            )
        }

        store.clearUndoHistory()
        store.deferTrace(source.id, to: targetDate)
        let target = try unwrap(
            store.engine.futurePlans(today: store.today).first {
                $0.trace.carriedFromTraceID == source.id
            }?.trace,
            "persisted continuation target"
        )
        let continuationBits = exactBits(target.createdAt)
        guard store.canUndoDomainAction else {
            throw CopyUndoPersistenceE2EError.failed(
                "continuation did not enter the Store undo stack"
            )
        }

        store.undo()
        let cancelledTarget = try unwrap(
            store.engine.traces[target.id],
            "cancelled continuation target"
        )
        let evidence = ContinuationUndoEvidence(
            title: title,
            sourceDateISO8601: store.today.description,
            targetDateISO8601: targetDate.description,
            chainID: chain.id.rawValue,
            definitionID: definition.id.rawValue,
            sourceTraceID: source.id.rawValue,
            targetTraceID: target.id.rawValue,
            cancellationID: try unwrap(
                cancelledTarget.draftCancellationID,
                "continuation cancellation identity"
            ),
            sourceCreationBits: exactBits(source.createdAt),
            continuationBits: continuationBits,
            undoBits: exactBits(
                try unwrap(
                    cancelledTarget.settledAt,
                    "continuation cancellation clock"
                )
            )
        )
        try assertContinuationUndo(evidence, in: store)
        return evidence
    }

    @MainActor
    private func assertCopiedTaskUndo(
        _ evidence: CopiedTaskUndoEvidence,
        in store: NoonmarkStore
    ) throws {
        let chainID = TaskChainID(evidence.chainID)
        let definitionID = TaskDefinitionID(evidence.definitionID)
        guard let chain = store.engine.chains[chainID],
              let definition = store.engine.definitions[definitionID],
              chain.state == .abandoned,
              definition.chainID == chainID,
              definition.title == evidence.title,
              definition.supersededAt == nil,
              exactBits(chain.createdAt) == evidence.creationBits,
              exactBits(chain.updatedAt) == evidence.undoBits,
              exactBits(definition.createdAt) == evidence.creationBits,
              exactBits(definition.contentUpdatedAt) == evidence.creationBits,
              strictlyIncreases([
                  evidence.creationBits,
                  evidence.undoBits
              ]),
              store.engine.traces.values.contains(where: {
                  $0.chainID == chainID
              }) == false,
              store.engine.taskPool().contains(where: {
                  $0.chain.id == chainID
              }) == false,
              workspaceSearchContainsChain(
                  chainID,
                  query: evidence.title,
                  engine: store.engine
              ) == false
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "copied task raw facts or hidden projections diverged"
            )
        }
    }

    @MainActor
    private func assertNewTodayTaskUndo(
        _ evidence: NewTodayTaskUndoEvidence,
        in store: NoonmarkStore
    ) throws {
        let chainID = TaskChainID(evidence.chainID)
        let definitionID = TaskDefinitionID(evidence.definitionID)
        let traceID = DayTraceID(evidence.traceID)
        let date = try parseEvidenceDate(
            evidence.dateISO8601,
            field: "newTodayTask.dateISO8601"
        )
        guard let day = store.engine.days[date],
              let chain = store.engine.chains[chainID],
              let definition = store.engine.definitions[definitionID],
              let trace = store.engine.traces[traceID],
              chain.state == .abandoned,
              definition.chainID == chainID,
              definition.title == evidence.title,
              definition.supersededAt == nil,
              trace.chainID == chainID,
              trace.definitionID == definitionID,
              trace.date == date,
              trace.status == .cancelledDraft,
              trace.draftCancellationID == evidence.cancellationID,
              trace.draftCancelledOn == date,
              exactBits(day.createdAt) == evidence.creationBits,
              exactBits(day.updatedAt) == evidence.creationBits,
              exactBits(chain.createdAt) == evidence.creationBits,
              exactBits(chain.updatedAt) == evidence.undoBits,
              exactBits(definition.createdAt) == evidence.creationBits,
              exactBits(definition.contentUpdatedAt) == evidence.creationBits,
              exactBits(trace.createdAt) == evidence.creationBits,
              exactBits(trace.contentUpdatedAt) == evidence.undoBits,
              exactBits(trace.settledAt) == evidence.undoBits,
              strictlyIncreases([
                  evidence.creationBits,
                  evidence.undoBits
              ]),
              store.engine.getDayTodo(date: date)
              .traces.contains(where: { $0.id == traceID }) == false,
              store.engine.futurePlans(today: store.today).contains(where: {
                  $0.trace.id == traceID
              }) == false,
              store.engine.taskPool().contains(where: {
                  $0.chain.id == chainID
              }) == false,
              workspaceSearchContainsTrace(
                  traceID,
                  query: evidence.title,
                  engine: store.engine
              ) == false,
              workspaceSearchContainsChain(
                  chainID,
                  query: evidence.title,
                  engine: store.engine
              ) == false
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "new-today undo raw facts or hidden projections diverged"
            )
        }
    }

    @MainActor
    private func assertScheduledPoolTaskUndo(
        _ evidence: ScheduledPoolTaskUndoEvidence,
        in store: NoonmarkStore
    ) throws {
        let chainID = TaskChainID(evidence.chainID)
        let definitionID = TaskDefinitionID(evidence.definitionID)
        let traceID = DayTraceID(evidence.traceID)
        let date = try parseEvidenceDate(
            evidence.dateISO8601,
            field: "scheduledPoolTask.dateISO8601"
        )
        guard let day = store.engine.days[date],
              let chain = store.engine.chains[chainID],
              let definition = store.engine.definitions[definitionID],
              let trace = store.engine.traces[traceID],
              chain.state == .active,
              definition.chainID == chainID,
              definition.title == evidence.title,
              definition.supersededAt == nil,
              trace.chainID == chainID,
              trace.definitionID == definitionID,
              trace.date == date,
              trace.status == .cancelledDraft,
              trace.draftCancellationID == evidence.cancellationID,
              trace.draftCancelledOn == date,
              exactBits(chain.createdAt) == evidence.poolCreationBits,
              exactBits(chain.updatedAt) == evidence.poolCreationBits,
              exactBits(definition.createdAt) == evidence.poolCreationBits,
              exactBits(definition.contentUpdatedAt)
                  == evidence.poolCreationBits,
              exactBits(day.createdAt) == evidence.scheduleBits,
              exactBits(day.updatedAt) == evidence.scheduleBits,
              exactBits(trace.createdAt) == evidence.scheduleBits,
              exactBits(trace.contentUpdatedAt) == evidence.undoBits,
              exactBits(trace.settledAt) == evidence.undoBits,
              strictlyIncreases([
                  evidence.poolCreationBits,
                  evidence.scheduleBits,
                  evidence.undoBits
              ]),
              store.engine.taskPool().contains(where: {
                  $0.chain.id == chainID
              }),
              store.engine.getDayTodo(date: date)
              .traces.contains(where: { $0.id == traceID }) == false,
              store.engine.futurePlans(today: store.today).contains(where: {
                  $0.trace.id == traceID
              }) == false,
              workspaceSearchContainsTrace(
                  traceID,
                  query: evidence.title,
                  engine: store.engine
              ) == false,
              workspaceSearchContainsChain(
                  chainID,
                  query: evidence.title,
                  engine: store.engine
              )
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "scheduled-pool undo raw facts or projections diverged"
            )
        }
    }

    @MainActor
    private func assertAddedSubtaskUndo(
        _ evidence: AddedSubtaskUndoEvidence,
        in store: NoonmarkStore
    ) throws {
        let chainID = TaskChainID(evidence.chainID)
        let definitionID = TaskDefinitionID(evidence.definitionID)
        let traceID = DayTraceID(evidence.traceID)
        let subtaskID = SubtaskID(evidence.subtaskID)
        let date = try parseEvidenceDate(
            evidence.dateISO8601,
            field: "addedSubtask.dateISO8601"
        )
        guard let chain = store.engine.chains[chainID],
              let definition = store.engine.definitions[definitionID],
              let trace = store.engine.traces[traceID],
              let subtask = store.engine.subtasks[subtaskID],
              chain.state == .active,
              definition.chainID == chainID,
              definition.title == evidence.parentTitle,
              definition.supersededAt == nil,
              trace.chainID == chainID,
              trace.definitionID == definitionID,
              trace.date == date,
              trace.status == .pending,
              subtask.traceID == traceID,
              subtask.title == evidence.subtaskTitle,
              subtask.status == .cancelledDraft,
              subtask.draftCancellationID == evidence.cancellationID,
              subtask.isUserPresentable == false,
              exactBits(chain.createdAt) == evidence.parentCreationBits,
              exactBits(chain.updatedAt) == evidence.parentCreationBits,
              exactBits(definition.createdAt) == evidence.parentCreationBits,
              exactBits(definition.contentUpdatedAt)
                  == evidence.parentCreationBits,
              exactBits(trace.createdAt) == evidence.parentCreationBits,
              exactBits(trace.contentUpdatedAt)
                  == evidence.parentCreationBits,
              exactBits(subtask.createdAt) == evidence.subtaskCreationBits,
              exactBits(subtask.updatedAt) == evidence.finalUndoBits,
              exactBits(subtask.settledAt) == evidence.finalUndoBits,
              strictlyIncreases([
                  evidence.parentCreationBits,
                  evidence.subtaskCreationBits,
                  evidence.firstUndoBits,
                  evidence.redoBits,
                  evidence.finalUndoBits
              ]),
              store.engine.getDayTodo(date: date)
              .traces.contains(where: { $0.id == traceID }),
              store.engine.taskPool().contains(where: {
                  $0.chain.id == chainID
              }) == false,
              store.engine.futurePlans(today: store.today).contains(where: {
                  $0.trace.id == traceID
              }) == false,
              store.engine.subtaskProgress(for: traceID).total == 0,
              store.engine.traceProgress(for: traceID).mode == .manual,
              workspaceSearchContainsSubtask(
                  subtaskID,
                  query: evidence.subtaskTitle,
                  engine: store.engine
              ) == false
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "added-subtask undo raw facts, witness, or progress diverged"
            )
        }
    }

    @MainActor
    private func assertContinuationUndo(
        _ evidence: ContinuationUndoEvidence,
        in store: NoonmarkStore
    ) throws {
        let chainID = TaskChainID(evidence.chainID)
        let definitionID = TaskDefinitionID(evidence.definitionID)
        let sourceTraceID = DayTraceID(evidence.sourceTraceID)
        let targetTraceID = DayTraceID(evidence.targetTraceID)
        let sourceDate = try parseEvidenceDate(
            evidence.sourceDateISO8601,
            field: "continuation.sourceDateISO8601"
        )
        let targetDate = try parseEvidenceDate(
            evidence.targetDateISO8601,
            field: "continuation.targetDateISO8601"
        )
        guard let targetDay = store.engine.days[targetDate],
              let chain = store.engine.chains[chainID],
              let definition = store.engine.definitions[definitionID],
              let source = store.engine.traces[sourceTraceID],
              let target = store.engine.traces[targetTraceID],
              chain.state == .active,
              definition.chainID == chainID,
              definition.title == evidence.title,
              definition.supersededAt == nil,
              source.chainID == chainID,
              source.definitionID == definitionID,
              source.date == sourceDate,
              source.status == .pending,
              target.chainID == chainID,
              target.definitionID == definitionID,
              target.date == targetDate,
              target.status == .cancelledDraft,
              target.carriedFromTraceID == sourceTraceID,
              target.draftCancellationID == evidence.cancellationID,
              target.draftCancelledOn == targetDate,
              exactBits(chain.createdAt) == evidence.sourceCreationBits,
              exactBits(chain.updatedAt) == evidence.continuationBits,
              exactBits(definition.createdAt) == evidence.sourceCreationBits,
              exactBits(definition.contentUpdatedAt)
                  == evidence.sourceCreationBits,
              exactBits(source.createdAt) == evidence.sourceCreationBits,
              exactBits(source.contentUpdatedAt) == evidence.undoBits,
              exactBits(targetDay.createdAt) == evidence.continuationBits,
              exactBits(targetDay.updatedAt) == evidence.continuationBits,
              exactBits(target.createdAt) == evidence.continuationBits,
              exactBits(target.contentUpdatedAt) == evidence.undoBits,
              exactBits(target.settledAt) == evidence.undoBits,
              strictlyIncreases([
                  evidence.sourceCreationBits,
                  evidence.continuationBits,
                  evidence.undoBits
              ]),
              store.engine.getDayTodo(date: sourceDate)
              .traces.contains(where: { $0.id == sourceTraceID }),
              store.engine.getDayTodo(date: targetDate)
              .traces.contains(where: { $0.id == targetTraceID }) == false,
              store.engine.futurePlans(today: store.today).contains(where: {
                  $0.trace.id == targetTraceID
              }) == false,
              store.engine.taskPool().contains(where: {
                  $0.chain.id == chainID
              }) == false,
              workspaceSearchContainsTrace(
                  targetTraceID,
                  query: evidence.title,
                  engine: store.engine
              ) == false,
              store.engine.subtaskProgress(for: sourceTraceID).total == 0,
              store.engine.traceProgress(for: sourceTraceID).mode == .manual
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "continuation undo raw facts or hidden projections diverged"
            )
        }
    }

    @MainActor
    private func assertRestartProjectionMatrix(
        _ state: CopyUndoPersistenceE2EState,
        in store: NoonmarkStore
    ) throws {
        let visiblePool = Set(store.engine.taskPool().map(\.chain.id))
        let expectedPool = Set([
            TaskChainID(state.scheduledPoolTask.chainID)
        ])
        let today = try parseEvidenceDate(
            state.newTodayTask.dateISO8601,
            field: "newTodayTask.dateISO8601"
        )
        let visibleToday = Set(
            store.engine.getDayTodo(date: today)
                .traces.map(\.id)
        )
        let expectedToday = Set([
            DayTraceID(state.addedSubtask.traceID),
            DayTraceID(state.continuation.sourceTraceID)
        ])
        guard visiblePool == expectedPool,
              visibleToday == expectedToday,
              store.engine.futurePlans(today: store.today).isEmpty,
              store.engine.subtaskProgress(
                  for: DayTraceID(state.addedSubtask.traceID)
              ).total == 0
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "restart projection matrix resurrected a hidden undo fact"
            )
        }
    }

    @MainActor
    private func currentDefinition(
        in store: NoonmarkStore,
        chainID: TaskChainID
    ) throws -> TaskDefinition {
        try unwrap(
            store.engine.definitions.values.first {
                $0.chainID == chainID && $0.supersededAt == nil
            },
            "current task definition"
        )
    }

    @MainActor
    private func taskClassification(
        in store: NoonmarkStore,
        chainID: TaskChainID
    ) throws -> TaskClassificationProjection {
        guard case let .task(projection) = try store.engine.classification(
            .task(chainID)
        ) else {
            throw CopyUndoPersistenceE2EError.failed(
                "missing task classification projection"
            )
        }
        return projection
    }

    private func exactBits(_ date: Date) -> UInt64 {
        date.timeIntervalSinceReferenceDate.bitPattern
    }

    private func exactBits(_ date: Date?) -> UInt64? {
        date.map(exactBits)
    }

    private func strictlyIncreases(_ bits: [UInt64]) -> Bool {
        zip(bits, bits.dropFirst()).allSatisfy(<)
    }

    private func parseEvidenceDate(
        _ rawValue: String,
        field: String
    ) throws -> LocalDate {
        let parts = rawValue.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts[0].utf8.count == 4,
              parts[1].utf8.count == 2,
              parts[2].utf8.count == 2,
              parts.allSatisfy({ part in
                  part.utf8.allSatisfy { (48...57).contains($0) }
              }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9999).contains(year),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "invalid ISO date in \(field): \(rawValue)"
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let instant = calendar.date(from: components) else {
            throw CopyUndoPersistenceE2EError.failed(
                "invalid Gregorian date in \(field): \(rawValue)"
            )
        }
        let resolved = calendar.dateComponents(
            [.year, .month, .day],
            from: instant
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "invalid Gregorian date in \(field): \(rawValue)"
            )
        }
        return LocalDate(year: year, month: month, day: day)
    }

    private func parseTaskChainID(
        _ rawValue: String,
        field: String
    ) throws -> TaskChainID {
        guard let id = UUID(uuidString: rawValue),
              id.uuidString == rawValue
        else {
            throw CopyUndoPersistenceE2EError.failed(
                "invalid UUID in \(field): \(rawValue)"
            )
        }
        return TaskChainID(id)
    }

    @MainActor
    private func sourceHistory(
        in store: NoonmarkStore,
        traceID: DayTraceID
    ) throws -> TraceClassificationProjection {
        guard case let .history(projection) = try store.engine.classification(
            .history(traceID)
        ) else {
            throw CopyUndoPersistenceE2EError.failed(
                "missing source classification history"
            )
        }
        return projection
    }

    private func unwrap<Value>(_ value: Value?, _ label: String) throws -> Value {
        guard let value else {
            throw CopyUndoPersistenceE2EError.failed("missing \(label)")
        }
        return value
    }

    private func writeState(
        _ state: CopyUndoPersistenceE2EState,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func readState(from url: URL) throws -> CopyUndoPersistenceE2EState {
        try JSONDecoder().decode(
            CopyUndoPersistenceE2EState.self,
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

private enum CopyUndoPersistenceE2EError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        }
    }
}

struct UndoE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> UndoE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-undo-workflow") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-undo-result-url")
            .map { URL(fileURLWithPath: $0) }
        return UndoE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            try verifyPoolAddUndo(on: store)
            try verifyPoolNoteAppendUndoUsesTombstone(on: store)
            try verifyPoolNoteEditUndoAdvancesVersion(on: store)
            try verifyPoolNoteDeleteUndoUsesNewIdentity(on: store)
            try verifyPoolNoteUndoCompositionKeepsLogicalIdentity(on: store)
            try verifyTraceNoteUndoCompositionKeepsLogicalIdentity(on: store)
            try verifyCurrentContinuationUndo(on: store)
            try verifyCurrentAbandonUndo(on: store)
            try verifyNoteUndoKeepsEarlierUndo(on: store)
            try verifyFutureRescheduleUndo(on: store)
            try verifyUnclassifiedCopyAsNewTaskUndo(on: store)
            try verifyCopyAsNewTaskUndo(on: store)
            try verifyHistoricalAbandonIsNotUndoable(on: store)
            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    @MainActor
    private func reset(_ store: NoonmarkStore) {
        store.engine = NoonmarkEngine()
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()
        store.clearUndoHistory()
    }

    @MainActor
    private func verifyPoolAddUndo(on store: NoonmarkStore) throws {
        reset(store)
        store.poolText = "E2E 撤销任务池新增"
        store.addPoolTask()
        guard store.engine.taskPool().count == 1 else {
            throw UndoE2EAutomationError.failed("pool add did not create one task")
        }
        store.undo()
        guard store.engine.taskPool().isEmpty else {
            throw UndoE2EAutomationError.failed("pool add undo did not restore empty pool")
        }
    }

    @MainActor
    private func verifyPoolNoteAppendUndoUsesTombstone(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(title: "E2E 撤销新增附言")
        store.detailNoteText = "刚新增的附言"
        store.appendPoolNote(chainID: chainID)
        let noteID = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first?.id,
            "appended note identity"
        )

        store.undo()

        let chain = try unwrap(
            store.engine.taskPool().first?.chain,
            "chain after append undo"
        )
        guard chain.activeNoteEntries.isEmpty,
              chain.noteEntries.first(where: { $0.id == noteID })?.isDeleted == true
        else {
            throw UndoE2EAutomationError.failed(
                "note append undo did not preserve a tombstone"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteEditUndoAdvancesVersion(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 撤销编辑附言",
            initialNoteBody: "编辑前"
        )
        let original = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "original note"
        )
        store.editPoolNote(
            chainID: chainID,
            noteID: original.id,
            body: "编辑后"
        )
        let editedAt = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first?.updatedAt,
            "edited note time"
        )

        store.undo()

        let restored = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "restored note"
        )
        guard restored.id == original.id,
              restored.body == original.body,
              restored.updatedAt > editedAt
        else {
            throw UndoE2EAutomationError.failed(
                "note edit undo did not create a forward version"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteDeleteUndoUsesNewIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 撤销删除附言",
            initialNoteBody: "删除前正文"
        )
        let original = try unwrap(
            store.engine.taskPool().first?.chain.activeNoteEntries.first,
            "note before delete"
        )
        store.deletePoolNote(chainID: chainID, noteID: original.id)

        store.undo()

        let chain = try unwrap(
            store.engine.taskPool().first?.chain,
            "chain after delete undo"
        )
        let restored = try unwrap(
            chain.activeNoteEntries.first,
            "new note after delete undo"
        )
        guard restored.id != original.id,
              restored.body == original.body,
              chain.noteEntries.first(where: {
                  $0.id == original.id
              })?.isDeleted == true
        else {
            throw UndoE2EAutomationError.failed(
                "note delete undo revived the tombstoned identity"
            )
        }
    }

    @MainActor
    private func verifyPoolNoteUndoCompositionKeepsLogicalIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let chainID = try store.engine.createPoolTask(
            title: "E2E 任务池附言连续撤销"
        )
        store.detailNoteText = "新增正文"
        store.appendPoolNote(chainID: chainID)
        let originalID = try unwrap(
            store.engine.chains[chainID]?.activeNoteEntries.first?.id,
            "pool note before edit and delete"
        )
        store.editPoolNote(
            chainID: chainID,
            noteID: originalID,
            body: "编辑后正文"
        )
        store.deletePoolNote(chainID: chainID, noteID: originalID)

        store.undo()
        let restoredID = try unwrap(
            store.engine.chains[chainID]?.activeNoteEntries.first?.id,
            "pool note restored after delete undo"
        )
        guard restoredID != originalID,
              store.engine.chains[chainID]?.activeNoteEntries.first?.body == "编辑后正文"
        else {
            throw UndoE2EAutomationError.failed(
                "pool delete undo did not restore edited note under a fresh storage identity"
            )
        }

        store.undo()
        guard store.engine.chains[chainID]?.activeNoteEntries.first?.id == restoredID,
              store.engine.chains[chainID]?.activeNoteEntries.first?.body == "新增正文",
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "pool delete undo lost the logical identity needed by the earlier edit undo"
            )
        }

        store.undo()
        guard let chain = store.engine.chains[chainID],
              chain.activeNoteEntries.isEmpty,
              chain.noteEntries.first(where: { $0.id == originalID })?.isDeleted == true,
              chain.noteEntries.first(where: { $0.id == restoredID })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "pool append undo did not compose after edit and delete undo"
            )
        }
    }

    @MainActor
    private func verifyTraceNoteUndoCompositionKeepsLogicalIdentity(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let traceID = try makeTrace(
            title: "E2E 日轨迹附言连续撤销",
            date: store.today,
            today: store.today,
            store: store
        )
        store.detailNoteText = "轨迹新增正文"
        store.appendTraceNote(traceID: traceID)
        let originalID = try unwrap(
            store.engine.traces[traceID]?.activeNoteEntries.first?.id,
            "trace note before edit and delete"
        )
        store.editTraceNote(
            traceID: traceID,
            noteID: originalID,
            body: "轨迹编辑后正文"
        )
        store.deleteTraceNote(traceID: traceID, noteID: originalID)

        store.undo()
        let restoredID = try unwrap(
            store.engine.traces[traceID]?.activeNoteEntries.first?.id,
            "trace note restored after delete undo"
        )
        guard restoredID != originalID,
              store.engine.traces[traceID]?.activeNoteEntries.first?.body == "轨迹编辑后正文"
        else {
            throw UndoE2EAutomationError.failed(
                "trace delete undo did not restore edited note under a fresh storage identity"
            )
        }

        store.undo()
        guard store.engine.traces[traceID]?.activeNoteEntries.first?.id == restoredID,
              store.engine.traces[traceID]?.activeNoteEntries.first?.body == "轨迹新增正文",
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "trace delete undo lost the logical identity needed by the earlier edit undo"
            )
        }

        store.undo()
        guard let trace = store.engine.traces[traceID],
              trace.activeNoteEntries.isEmpty,
              trace.noteEntries.first(where: { $0.id == originalID })?.isDeleted == true,
              trace.noteEntries.first(where: { $0.id == restoredID })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "trace append undo did not compose after edit and delete undo"
            )
        }
    }

    @MainActor
    private func verifyCurrentContinuationUndo(on store: NoonmarkStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前延续", date: store.today, today: store.today, store: store)
        let chainID = try unwrap(store.engine.traces[traceID]?.chainID, "continuation chain")
        _ = try store.replaceTaskClassification(
            chainID: chainID,
            category: .new(name: "E2E 撤销分类", colorHex: "#2A6FDB"),
            labels: []
        )
        store.clearUndoHistory()
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        store.deferTrace(traceID, to: tomorrow)
        let targetTraceID = try unwrap(
            store.engine.futurePlans(today: store.today).first {
                $0.trace.carriedFromTraceID == traceID
            }?.trace.id,
            "continuation target"
        )
        guard store.engine.traces[targetTraceID]?.status == .pending else {
            throw UndoE2EAutomationError.failed("continuation did not create tomorrow trace")
        }
        store.undo()
        guard let cancelledTarget = store.engine.traces[targetTraceID],
              store.engine.traces[traceID]?.status == .pending,
              cancelledTarget.status == .cancelledDraft,
              cancelledTarget.draftCancellationID != nil,
              cancelledTarget.draftCancelledOn == tomorrow,
              store.engine.futurePlans(today: store.today).contains(where: {
                  $0.trace.id == targetTraceID
              }) == false,
              store.engine.getDayTodo(date: tomorrow).traces.contains(where: {
                  $0.id == targetTraceID
              }) == false,
              workspaceSearchContainsTrace(
                  targetTraceID,
                  query: "E2E 撤销当前延续",
                  engine: store.engine
              ) == false,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "current continuation undo did not hide the retained target trace"
            )
        }
    }

    @MainActor
    private func verifyCurrentAbandonUndo(on store: NoonmarkStore) throws {
        reset(store)
        let traceID = try makeTrace(title: "E2E 撤销当前废弃", date: store.today, today: store.today, store: store)
        store.abandon(traceID)
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("current abandon did not abandon trace")
        }
        store.undo()
        guard let restoredTrace = store.engine.traces[traceID],
              restoredTrace.status == .pending,
              store.engine.chains[restoredTrace.chainID]?.state == .active,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("current abandon undo did not reactivate the chain")
        }
    }

    @MainActor
    private func verifyNoteUndoKeepsEarlierUndo(on store: NoonmarkStore) throws {
        reset(store)
        let noteChainID = try store.engine.createPoolTask(title: "E2E 附言所属任务")
        store.poolText = "E2E 较早的可撤销操作"
        store.addPoolTask()
        store.detailNoteText = "E2E 后发生的附言操作"
        store.appendPoolNote(chainID: noteChainID)
        let noteID = try unwrap(
            store.engine.chains[noteChainID]?.activeNoteEntries.first?.id,
            "note appended after earlier undoable action"
        )

        store.undo()
        guard store.engine.chains[noteChainID]?.noteEntries.first(where: {
            $0.id == noteID
        })?.isDeleted == true else {
            throw UndoE2EAutomationError.failed("first undo did not tombstone the later note")
        }

        store.undo()

        guard store.engine.taskPool().map(\.chain.id) == [noteChainID],
              store.engine.chains[noteChainID]?.noteEntries.first(where: {
                  $0.id == noteID
              })?.isDeleted == true,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("note undo discarded or poisoned the earlier undo entry")
        }
    }

    @MainActor
    private func verifyFutureRescheduleUndo(on store: NoonmarkStore) throws {
        reset(store)
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        let nextWeek = NoonmarkStore.offset(store.today, by: 7)
        let traceID = try makeTrace(title: "E2E 撤销未来改期", date: tomorrow, today: store.today, store: store)
        store.reschedule(traceID, to: nextWeek)
        guard store.engine.traces[traceID]?.date == nextWeek else {
            throw UndoE2EAutomationError.failed("future reschedule did not change date")
        }
        store.undo()
        guard store.engine.traces[traceID]?.date == tomorrow else {
            throw UndoE2EAutomationError.failed("future reschedule undo did not restore original date")
        }
    }

    @MainActor
    private func verifyCopyAsNewTaskUndo(on store: NoonmarkStore) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 撤销复制新任务", date: past, today: past, store: store)
        let sourceChainID = try unwrap(
            store.engine.traces[traceID]?.chainID,
            "classified copy source chain"
        )
        _ = try store.replaceTaskClassification(
            chainID: sourceChainID,
            category: .new(name: "E2E 已分类来源", colorHex: "#2A6FDB"),
            labels: [.new(name: "E2E 复制标签", colorHex: "#0E9488")]
        )
        try store.engine.markCompleted(traceID: traceID, today: past)
        try store.engine.settleDays(upTo: store.today)
        let beforeCopy = store.engine.snapshot()
        guard case let .task(sourceClassification) = try store.engine.classification(
            .task(sourceChainID)
        ),
            sourceClassification.category?.name == "E2E 已分类来源",
            sourceClassification.labels.map(\.name) == ["E2E 复制标签"],
            case let .history(sourceHistory) = try store.engine.classification(
                .history(traceID)
            ),
            sourceHistory.category?.name == "E2E 已分类来源",
            sourceHistory.labels.map(\.name) == ["E2E 复制标签"]
        else {
            throw UndoE2EAutomationError.failed(
                "copy source fixture did not contain faithful current and historical classification"
            )
        }

        store.clearUndoHistory()
        store.copyAsNewTask(traceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "classified copied pool task"
        )
        guard copiedChainID != sourceChainID,
              case let .task(copiedClassification) = try store.engine.classification(
                  .task(copiedChainID)
              ),
              copiedClassification.category?.name == "E2E 已分类来源",
              copiedClassification.labels.map(\.name) == ["E2E 复制标签"]
        else {
            throw UndoE2EAutomationError.failed(
                "copy as new task did not create a classified pool task"
            )
        }

        store.undo()
        let afterUndo = store.engine.snapshot()
        try afterUndo.validateIntegrity()
        let copiedAfterUndo = try taskProjection(
            store.engine.classification(.task(copiedChainID))
        )
        let sourceAfterUndo = try taskProjection(
            store.engine.classification(.task(sourceChainID))
        )
        let sourceHistoryAfter = try historyProjection(
            store.engine.classification(.history(traceID))
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              store.engine.traces[traceID]?.status == .completed,
              store.engine.chains[sourceChainID] == beforeCopy.chains.first(where: {
                  $0.id == sourceChainID
              }),
              copiedAfterUndo.category == nil,
              copiedAfterUndo.labels.isEmpty,
              sourceAfterUndo.category?.name == sourceClassification.category?.name,
              sourceAfterUndo.labels.map(\.name) == sourceClassification.labels.map(\.name),
              sourceHistoryAfter == sourceHistory,
              afterUndo.classifications.changeRecords.starts(
                  with: beforeCopy.classifications.changeRecords
              ),
              afterUndo.classifications.revision
                  == beforeCopy.classifications.revision + 2,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "classified copy undo did not hide the copy with an append-only compensation"
            )
        }
    }

    @MainActor
    private func verifyUnclassifiedCopyAsNewTaskUndo(
        on store: NoonmarkStore
    ) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(
            title: "E2E 撤销未分类复制新任务",
            date: past,
            today: past,
            store: store
        )
        try store.engine.markCompleted(traceID: traceID, today: past)
        store.copyAsNewTask(traceID)
        let copiedChainID = try unwrap(
            store.engine.taskPool().first?.chain.id,
            "unclassified copied pool task"
        )

        store.undo()
        guard store.engine.taskPool().isEmpty,
              store.engine.chains[copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }),
              store.engine.traces[traceID]?.status == .completed,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "unclassified copy undo did not retain a hidden identity"
            )
        }
    }

    private func taskProjection(
        _ projection: ClassificationProjection
    ) throws -> TaskClassificationProjection {
        guard case let .task(task) = projection else {
            throw UndoE2EAutomationError.failed(
                "missing task classification projection"
            )
        }
        return task
    }

    private func historyProjection(
        _ projection: ClassificationProjection
    ) throws -> TraceClassificationProjection {
        guard case let .history(history) = projection else {
            throw UndoE2EAutomationError.failed(
                "missing trace classification projection"
            )
        }
        return history
    }

    @MainActor
    private func verifyHistoricalAbandonIsNotUndoable(on store: NoonmarkStore) throws {
        reset(store)
        let past = NoonmarkStore.offset(store.today, by: -1)
        let traceID = try makeTrace(title: "E2E 历史废弃不可撤销", date: past, today: past, store: store)
        try store.engine.settleDays(
            upTo: store.today,
            now: try store.dayContext.moment().instant
        )
        store.abandon(traceID)
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("historical abandon did not abandon trace")
        }
        store.undo()
        guard store.engine.traces[traceID]?.status == .abandoned else {
            throw UndoE2EAutomationError.failed("historical abandon unexpectedly became undoable")
        }
    }

    @MainActor
    private func makeTrace(title: String, date: LocalDate, today: LocalDate, store: NoonmarkStore) throws -> DayTraceID {
        let now = try store.dayContext.moment().instant
        let chainID = try store.engine.createPoolTask(title: title, now: now)
        return try store.engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: today,
            now: now
        )
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private func unwrap<Value>(_ value: Value?, _ label: String) throws -> Value {
        guard let value else {
            throw UndoE2EAutomationError.failed("missing \(label)")
        }
        return value
    }
}

private func workspaceSearchContainsTrace(
    _ traceID: DayTraceID,
    query: String,
    engine: NoonmarkEngine
) -> Bool {
    WorkspaceSearchIndex(engine: engine).search(query).contains { result in
        switch result.destination {
        case let .trace(id, _, _):
            id == traceID
        case let .subtask(_, parentTraceID, _, _):
            parentTraceID == traceID
        case .pool:
            false
        }
    }
}

private func workspaceSearchContainsChain(
    _ chainID: TaskChainID,
    query: String,
    engine: NoonmarkEngine
) -> Bool {
    WorkspaceSearchIndex(engine: engine).search(query).contains { result in
        guard case let .pool(id) = result.destination else { return false }
        return id == chainID
    }
}

private func workspaceSearchContainsSubtask(
    _ subtaskID: SubtaskID,
    query: String,
    engine: NoonmarkEngine
) -> Bool {
    WorkspaceSearchIndex(engine: engine).search(query).contains { result in
        guard case let .subtask(id, _, _, _) = result.destination else {
            return false
        }
        return id == subtaskID
    }
}

private enum UndoE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

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

private struct CopyUndoPersistenceE2EState: Codable {
    let sourceChainID: TaskChainID
    let sourceTraceID: DayTraceID
    let copiedChainID: TaskChainID
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

        let state = CopyUndoPersistenceE2EState(
            sourceChainID: sourceChainID,
            sourceTraceID: sourceTraceID,
            copiedChainID: copiedChainID,
            classificationRevision: snapshot.classifications.revision,
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
        let source = try taskClassification(
            in: store,
            chainID: state.sourceChainID
        )
        let sourceHistory = try sourceHistory(
            in: store,
            traceID: state.sourceTraceID
        )
        let copied = try taskClassification(
            in: store,
            chainID: state.copiedChainID
        )
        guard store.engine.taskPool().isEmpty,
              store.engine.traces[state.sourceTraceID]?.status == .completed,
              store.engine.chains[state.copiedChainID]?.state == .abandoned,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == state.copiedChainID
              }),
              store.engine.traces.values.contains(where: {
                  $0.chainID == state.copiedChainID
              }) == false,
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
                "copy undo state did not survive SQLite restart"
            )
        }
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
        store.continueTrace(traceID, to: tomorrow)
        guard store.engine.traces.values.contains(where: { $0.date == tomorrow && $0.status == .pending }) else {
            throw UndoE2EAutomationError.failed("continuation did not create tomorrow trace")
        }
        store.undo()
        guard store.engine.traces[traceID]?.status == .pending,
              store.engine.traces.values.contains(where: { $0.date == tomorrow }) == false,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed("current continuation undo did not restore the source trace")
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
              store.engine.chains[copiedChainID] == nil,
              store.engine.definitions.values.contains(where: {
                  $0.chainID == copiedChainID
              }) == false,
              store.engine.traces[traceID]?.status == .completed,
              store.toast == "已撤销"
        else {
            throw UndoE2EAutomationError.failed(
                "unclassified copy undo did not delete the isolated copy"
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
        try store.engine.settleDays(upTo: store.today)
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
        let chainID = try store.engine.createPoolTask(title: title)
        return try store.engine.scheduleFromPool(chainID: chainID, date: date, today: today)
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

private enum UndoE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

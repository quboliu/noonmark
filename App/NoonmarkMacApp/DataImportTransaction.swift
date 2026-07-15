import Foundation
import NoonmarkCore

struct PreparedDataImport: Identifiable {
    struct Summary: Equatable {
        let dayCount: Int
        let taskCount: Int
        let traceCount: Int
        let subtaskCount: Int
        let completedTraceCount: Int
        let unfinishedTraceCount: Int
    }

    let id: UUID
    let sourceURL: URL
    let snapshot: NoonmarkSnapshot
    let summary: Summary

    init(sourceURL: URL, snapshot: NoonmarkSnapshot) {
        id = UUID()
        self.sourceURL = sourceURL
        self.snapshot = snapshot
        let completedTraceCount = snapshot.traces.reduce(into: 0) {
            if $1.status == .completed { $0 += 1 }
        }
        let unfinishedTraceCount = snapshot.traces.reduce(into: 0) {
            if $1.status == .unfinished || $1.status == .continued { $0 += 1 }
        }
        summary = Summary(
            dayCount: snapshot.days.count,
            taskCount: snapshot.definitions.count,
            traceCount: snapshot.traces.count,
            subtaskCount: snapshot.subtasks.count,
            completedTraceCount: completedTraceCount,
            unfinishedTraceCount: unfinishedTraceCount
        )
    }
}

enum DataImportConfirmation: Equatable {
    case confirmed(previewID: UUID)
}

enum DataImportTransactionError: LocalizedError, Equatable {
    case previewExpired
    case confirmationMismatch
    case anotherEngineOperationIsInProgress
    case engineChangedWhilePreparingCommit

    var errorDescription: String? {
        switch self {
        case .previewExpired:
            "The prepared import is no longer available. Inspect the file again."
        case .confirmationMismatch:
            "The import confirmation does not match the inspected file."
        case .anotherEngineOperationIsInProgress:
            "Another data operation is still in progress. Wait for it to finish before importing."
        case .engineChangedWhilePreparingCommit:
            "Current data changed while the import was being prepared. Inspect and confirm the file again."
        }
    }
}

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
        let visibleTraces = snapshot.traces.filter(\.formsDayHistory)
        let visibleTraceIDs = Set(visibleTraces.map(\.id))
        let visibleTraceChainIDs = Set(visibleTraces.map(\.chainID))
        let taskPoolChainIDs = Set(
            snapshot.chains.compactMap { chain -> TaskChainID? in
                guard chain.state == .active else { return nil }
                let chainTraces = snapshot.traces.filter {
                    $0.chainID == chain.id
                }
                return chainTraces.isEmpty || chainTraces.allSatisfy {
                    $0.status == .returnedToPool || $0.status == .cancelledDraft
                } ? chain.id : nil
            }
        )
        let visibleTraceDates = Set(visibleTraces.map(\.date))
        let meaningfulDayCount = snapshot.days.filter {
            visibleTraceDates.contains($0.date)
                || $0.lockedAt != nil
                || $0.reviewSummary != nil
                || $0.reviewUnfinishedReason != nil
                || $0.reviewTomorrowNote != nil
        }.count
        let completedTraceCount = visibleTraces.reduce(into: 0) {
            if $1.status == .completed { $0 += 1 }
        }
        let unfinishedTraceCount = visibleTraces.reduce(into: 0) {
            if $1.status == .unfinished || $1.status == .continued { $0 += 1 }
        }
        summary = Summary(
            dayCount: meaningfulDayCount,
            taskCount: visibleTraceChainIDs.union(taskPoolChainIDs).count,
            traceCount: visibleTraces.count,
            subtaskCount: snapshot.subtasks.filter {
                visibleTraceIDs.contains($0.traceID)
                    && $0.isUserPresentable
            }.count,
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

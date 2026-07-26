import CryptoKit
import Foundation
import NoonmarkCore

struct ZhulongApplicationSnapshotIdentity: Equatable {
    let canonicalData: Data

    init(_ snapshot: NoonmarkSnapshot) throws {
        try snapshot.validateIntegrity()
        do {
            canonicalData = try Self.encode(
                ApplicationSnapshotMaterial(snapshot)
            )
        } catch {
            throw ZhulongTodoDiffError.digestFailure
        }
    }

    var digest: String {
        SHA256.hash(data: canonicalData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func encode(
        _ material: ApplicationSnapshotMaterial
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw ZhulongTodoDiffError.invalidTime
            }
            var container = encoder.singleValueContainer()
            try container.encode(seconds.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(material)
    }
}

public enum ZhulongApplicationSnapshotDigest {
    public static func value(_ snapshot: NoonmarkSnapshot) throws -> String {
        try ZhulongApplicationSnapshotIdentity(snapshot).digest
    }
}

public enum ZhulongEnginePersistenceInspector {
    public static func resolve(
        persistedEngine: NoonmarkEngine,
        pendingApplication: ZhulongPendingApplication
    ) throws -> ZhulongEnginePersistenceResolution {
        let persistedIdentity = try ZhulongApplicationSnapshotIdentity(
            persistedEngine.snapshot()
        )
        let beforeIdentity = try ZhulongApplicationSnapshotIdentity(
            pendingApplication.beforeSnapshot
        )
        let afterIdentity = try ZhulongApplicationSnapshotIdentity(
            pendingApplication.afterSnapshot
        )
        if persistedIdentity == afterIdentity {
            return .after
        }
        if persistedIdentity == beforeIdentity {
            return .before
        }
        return .conflict
    }
}

private struct ApplicationSnapshotMaterial: Encodable {
    let formatVersion = 2
    let days: [Day]
    let taskCycleSeries: [TaskCycleSeries]
    let chains: [TaskChain]
    let definitions: [TaskDefinition]
    let traces: [DayTrace]
    let subtasks: [Subtask]
    let preferences: AppPreferences
    let classifications: ApplicationClassificationMaterial

    init(_ snapshot: NoonmarkSnapshot) {
        days = snapshot.days.sorted {
            $0.id.description < $1.id.description
        }
        taskCycleSeries = snapshot.taskCycleSeries.sorted {
            $0.id.description < $1.id.description
        }
        chains = snapshot.chains.sorted {
            $0.id.description < $1.id.description
        }
        definitions = snapshot.definitions.sorted {
            $0.id.description < $1.id.description
        }
        traces = snapshot.traces.sorted {
            $0.id.description < $1.id.description
        }
        subtasks = snapshot.subtasks.sorted {
            $0.id.description < $1.id.description
        }
        preferences = snapshot.preferences
        classifications = ApplicationClassificationMaterial(
            snapshot.classifications
        )
    }
}

private struct ApplicationClassificationMaterial: Encodable {
    let formatVersion = 1
    let revision: UInt64
    let categories: [ZhulongApplicationKeyedIdentity<TaskCategory>]
    let labels: [ZhulongApplicationKeyedIdentity<TaskLabel>]
    let currentByChainID: [
        ZhulongApplicationKeyedIdentity<CurrentTaskClassification>
    ]
    let relationHistory: [ClassificationRelationHistoryEntry]
    let categoryMerges: [
        ZhulongApplicationKeyedIdentity<TaskCategoryMerge>
    ]
    let labelMerges: [ZhulongApplicationKeyedIdentity<TaskLabelMerge>]
    let categoryDeletionTombstones: [
        ZhulongApplicationKeyedIdentity<TaskCategoryDeletionTombstone>
    ]
    let labelDeletionTombstones: [
        ZhulongApplicationKeyedIdentity<TaskLabelDeletionTombstone>
    ]
    let snapshotsByTraceID: [
        ZhulongApplicationKeyedIdentity<TraceClassificationSnapshot>
    ]
    let snapshotEventsByTraceID: [
        ZhulongApplicationKeyedIdentity<[TraceClassificationSnapshot]>
    ]
    let committedReceiptsByInteractionID: [
        ZhulongApplicationKeyedIdentity<ClassificationReceipt>
    ]
    let changeRecords: [ClassificationChangeRecord]

    init(_ state: TaskClassificationState) {
        revision = state.revision
        categories = canonicalEntries(state.categories)
        labels = canonicalEntries(state.labels)
        currentByChainID = canonicalEntries(state.currentByChainID)
        relationHistory = state.relationHistory
        categoryMerges = canonicalEntries(state.categoryMerges)
        labelMerges = canonicalEntries(state.labelMerges)
        categoryDeletionTombstones = canonicalEntries(
            state.categoryDeletionTombstones
        )
        labelDeletionTombstones = canonicalEntries(
            state.labelDeletionTombstones
        )
        snapshotsByTraceID = canonicalEntries(state.snapshotsByTraceID)
        snapshotEventsByTraceID = canonicalEntries(
            state.snapshotEventsByTraceID
        )
        committedReceiptsByInteractionID = canonicalEntries(
            state.committedReceiptsByInteractionID
        )
        changeRecords = state.changeRecords
    }
}

private struct ZhulongApplicationKeyedIdentity<Value: Encodable>: Encodable {
    let key: String
    let value: Value
}

private func canonicalEntries<Value: Encodable>(
    _ values: [some Hashable & CustomStringConvertible: Value]
) -> [ZhulongApplicationKeyedIdentity<Value>] {
    values.map {
        ZhulongApplicationKeyedIdentity(
            key: $0.key.description,
            value: $0.value
        )
    }
    .sorted { $0.key < $1.key }
}

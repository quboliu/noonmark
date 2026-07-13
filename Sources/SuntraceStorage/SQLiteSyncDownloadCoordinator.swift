import Foundation
import SuntraceCore
import SuntraceSync

public struct SQLiteSyncDownloadResult: Codable, Equatable, Sendable {
    public var fetchedCount: Int
    public var appliedCount: Int
    public var waitingCount: Int
    public var conflictCount: Int

    public init(
        fetchedCount: Int,
        appliedCount: Int,
        waitingCount: Int,
        conflictCount: Int
    ) {
        self.fetchedCount = fetchedCount
        self.appliedCount = appliedCount
        self.waitingCount = waitingCount
        self.conflictCount = conflictCount
    }
}

public final class SQLiteSyncDownloadCoordinator {
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let merger: SyncRecordMerger
    private let auditEntryIDGenerator: () -> UUID

    public convenience init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        merger: SyncRecordMerger = SyncRecordMerger()
    ) {
        self.init(
            databaseURL: databaseURL,
            transport: transport,
            merger: merger,
            auditEntryIDGenerator: UUID.init
        )
    }

    init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        merger: SyncRecordMerger = SyncRecordMerger(),
        auditEntryIDGenerator: @escaping () -> UUID
    ) {
        self.engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        self.syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        self.merger = merger
        self.auditEntryIDGenerator = auditEntryIDGenerator
    }

    public func downloadAndMerge(detectedAt: Date = Date()) async throws -> SQLiteSyncDownloadResult {
        let pending = try syncRepository.pendingDownloads()
        let terminalRejections = try syncRepository.terminalRejections()
        let fetchedRecords = try await transport.fetchAll()
        let records = try combinedRecords(
            pending: pending.map(\.record),
            fetched: fetchedRecords
        )
        guard records.isEmpty == false else {
            try syncRepository.saveMetadata(
                try downloadMetadata(fetchedCount: 0, detectedAt: detectedAt)
            )
            return SQLiteSyncDownloadResult(
                fetchedCount: 0,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 0
            )
        }

        let currentSnapshot = try engineRepository.load().snapshot()
        let mergeResult = mergeToFixedPoint(
            records: records,
            into: currentSnapshot,
            knownTerminalRejections: terminalRejections,
            detectedAt: detectedAt
        )

        let waitingIDs = Set(mergeResult.waitingRecords.map(\.remoteRecordID))
        let terminalPending = pending.filter {
            waitingIDs.contains($0.record.id) == false
        }
        let durableWaitingCount = try syncRepository.commitDownloadedMerge(
            SQLiteSyncDownloadCommit(
                snapshot: mergeResult.snapshot,
                conflicts: mergeResult.conflicts,
                waiting: mergeResult.waitingRecords,
                terminal: terminalPending,
                auditEntries: auditLogs(
                    records: records,
                    appliedRecordIDs: Set(mergeResult.appliedRecordIDs),
                    waitingRecords: mergeResult.waitingRecords,
                    conflicts: mergeResult.conflicts
                ),
                metadata: try downloadMetadata(
                    fetchedCount: fetchedRecords.count,
                    detectedAt: detectedAt
                ),
                attemptedAt: detectedAt
            )
        )

        return SQLiteSyncDownloadResult(
            fetchedCount: fetchedRecords.count,
            appliedCount: mergeResult.appliedRecordIDs.count,
            waitingCount: durableWaitingCount,
            conflictCount: mergeResult.conflicts.count
        )
    }

    private func combinedRecords(
        pending: [SyncRecord],
        fetched: [SyncRecord]
    ) throws -> [SyncRecord] {
        var byID: [SyncRecordID: SyncRecord] = [:]
        for record in pending + fetched {
            if let existing = byID[record.id], existing != record {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "sync record identity collision: \(record.id.rawValue)"
                )
            }
            byID[record.id] = record
        }
        return Array(byID.values)
    }

    private func mergeToFixedPoint(
        records: [SyncRecord],
        into snapshot: SuntraceSnapshot,
        knownTerminalRejections: [SyncTerminalRejection],
        detectedAt: Date
    ) -> SyncMergeResult {
        var terminalRejections = knownTerminalRejections
        var result = merger.merge(
            records: records,
            into: snapshot,
            knownTerminalRejections: terminalRejections,
            detectedAt: detectedAt
        )
        var appliedRecordIDs = result.appliedRecordIDs
        var conflicts = result.conflicts

        while result.waitingRecords.isEmpty == false && result.appliedRecordIDs.isEmpty == false {
            terminalRejections.append(contentsOf: result.conflicts.compactMap {
                SyncTerminalRejection(conflict: $0)
            })
            result = merger.merge(
                records: result.waitingRecords.map(\.record),
                into: result.snapshot,
                knownTerminalRejections: terminalRejections,
                detectedAt: detectedAt
            )
            appliedRecordIDs.append(contentsOf: result.appliedRecordIDs)
            conflicts.append(contentsOf: result.conflicts)
        }

        return SyncMergeResult(
            snapshot: result.snapshot,
            appliedRecordIDs: appliedRecordIDs,
            waitingRecords: result.waitingRecords,
            conflicts: conflicts
        )
    }

    private func auditLogs(
        records: [SyncRecord],
        appliedRecordIDs: Set<SyncRecordID>,
        waitingRecords: [SyncWaitingRecord],
        conflicts: [SyncConflict]
    ) -> [SyncAuditLogEntry] {
        let conflictRecordIDs = Set(conflicts.map(\.remoteRecordID))
        let waitingByRecordID = Dictionary(
            uniqueKeysWithValues: waitingRecords.map { ($0.remoteRecordID, $0) }
        )
        return records.map { record in
            if appliedRecordIDs.contains(record.id) {
                return auditLog(record: record, action: "merged", message: nil)
            } else if let waiting = waitingByRecordID[record.id] {
                return auditLog(
                    record: record,
                    action: "waiting",
                    message: waiting.dependencies.map(dependencyDescription).joined(separator: ", ")
                )
            } else if conflictRecordIDs.contains(record.id) {
                return auditLog(
                    record: record,
                    action: "conflict",
                    message: "remote record was not merged"
                )
            } else {
                return auditLog(
                    record: record,
                    action: "ignored",
                    message: "remote record did not change local snapshot"
                )
            }
        }
    }

    private func dependencyDescription(
        _ dependency: ClassificationCommitDependency
    ) -> String {
        switch dependency {
        case let .taskChain(id):
            "taskChain:\(id.description)"
        case let .dayTrace(id):
            "dayTrace:\(id.description)"
        case let .category(id):
            "category:\(id.description)"
        case let .label(id):
            "label:\(id.description)"
        case let .classificationEvent(id):
            "classificationEvent:\(id.uuidString)"
        case let .classificationCommit(id):
            "classificationCommit:\(id.uuidString)"
        case let .classificationRevision(revision):
            "classificationRevision:\(revision)"
        }
    }

    private func auditLog(
        record: SyncRecord,
        action: String,
        message: String?
    ) -> SyncAuditLogEntry {
        SyncAuditLogEntry(
            id: auditEntryIDGenerator(),
            direction: .download,
            entityType: record.entityType,
            entityID: record.entityID,
            action: action,
            message: message
        )
    }

    private func downloadMetadata(
        fetchedCount: Int,
        detectedAt: Date
    ) throws -> SyncMetadataEntry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = SyncDownloadMetadata(lastFetchedAt: detectedAt, fetchedCount: fetchedCount)
        return SyncMetadataEntry(
            key: "generic.download.lastFetch",
            value: try encoder.encode(metadata),
            updatedAt: detectedAt
        )
    }
}

private struct SyncDownloadMetadata: Codable {
    var lastFetchedAt: Date
    var fetchedCount: Int
}

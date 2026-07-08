import Foundation
import SuntraceSync

public struct SQLiteSyncDownloadResult: Codable, Equatable, Sendable {
    public var fetchedCount: Int
    public var appliedCount: Int
    public var conflictCount: Int

    public init(fetchedCount: Int, appliedCount: Int, conflictCount: Int) {
        self.fetchedCount = fetchedCount
        self.appliedCount = appliedCount
        self.conflictCount = conflictCount
    }
}

public final class SQLiteSyncDownloadCoordinator {
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let merger: SyncRecordMerger

    public init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        merger: SyncRecordMerger = SyncRecordMerger()
    ) {
        self.engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        self.syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        self.merger = merger
    }

    public func downloadAndMerge(detectedAt: Date = Date()) async throws -> SQLiteSyncDownloadResult {
        let records = try await transport.fetchAll()
        guard records.isEmpty == false else {
            try saveMetadata(fetchedCount: 0, detectedAt: detectedAt)
            return SQLiteSyncDownloadResult(fetchedCount: 0, appliedCount: 0, conflictCount: 0)
        }

        let currentSnapshot = try engineRepository.load().snapshot()
        let mergeResult = merger.merge(records: records, into: currentSnapshot, detectedAt: detectedAt)

        if mergeResult.snapshot != currentSnapshot {
            try engineRepository.save(mergeResult.snapshot)
        }
        try persistConflicts(mergeResult.conflicts)
        try appendAuditLogs(
            records: records,
            appliedRecordIDs: Set(mergeResult.appliedRecordIDs),
            conflicts: mergeResult.conflicts
        )
        try saveMetadata(fetchedCount: records.count, detectedAt: detectedAt)

        return SQLiteSyncDownloadResult(
            fetchedCount: records.count,
            appliedCount: mergeResult.appliedRecordIDs.count,
            conflictCount: mergeResult.conflicts.count
        )
    }

    private func persistConflicts(_ conflicts: [SyncConflict]) throws {
        for conflict in conflicts {
            try syncRepository.saveConflict(conflict)
        }
    }

    private func appendAuditLogs(
        records: [SyncRecord],
        appliedRecordIDs: Set<SyncRecordID>,
        conflicts: [SyncConflict]
    ) throws {
        let conflictRecordIDs = Set(conflicts.map(\.remoteRecordID))
        for record in records {
            if appliedRecordIDs.contains(record.id) {
                try appendAuditLog(record: record, action: "merged", message: nil)
            } else if conflictRecordIDs.contains(record.id) {
                try appendAuditLog(record: record, action: "conflict", message: "remote record was not merged")
            } else {
                try appendAuditLog(record: record, action: "ignored", message: "remote record did not change local snapshot")
            }
        }
    }

    private func appendAuditLog(record: SyncRecord, action: String, message: String?) throws {
        try syncRepository.appendAuditLog(
            SyncAuditLogEntry(
                direction: .download,
                entityType: record.entityType,
                entityID: record.entityID,
                action: action,
                message: message
            )
        )
    }

    private func saveMetadata(fetchedCount: Int, detectedAt: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = SyncDownloadMetadata(lastFetchedAt: detectedAt, fetchedCount: fetchedCount)
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: "generic.download.lastFetch",
                value: try encoder.encode(metadata),
                updatedAt: detectedAt
            )
        )
    }
}

private struct SyncDownloadMetadata: Codable {
    var lastFetchedAt: Date
    var fetchedCount: Int
}

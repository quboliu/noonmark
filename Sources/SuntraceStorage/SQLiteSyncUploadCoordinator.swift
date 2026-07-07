import Foundation
import SuntraceCore
import SuntraceSync

public struct SQLiteSyncUploadResult: Equatable, Sendable {
    public var pendingCount: Int
    public var uploadedCount: Int
    public var failedCount: Int

    public init(pendingCount: Int, uploadedCount: Int, failedCount: Int) {
        self.pendingCount = pendingCount
        self.uploadedCount = uploadedCount
        self.failedCount = failedCount
    }
}

public final class SQLiteSyncUploadCoordinator {
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let materializer: SyncRecordMaterializer

    public init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        materializer: SyncRecordMaterializer = SyncRecordMaterializer()
    ) {
        self.engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        self.syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        self.materializer = materializer
    }

    public func uploadPending(limit: Int = 100) async throws -> SQLiteSyncUploadResult {
        let pendingEntries = try syncRepository.journalEntries(state: .pendingUpload, limit: limit)
        guard pendingEntries.isEmpty == false else {
            return SQLiteSyncUploadResult(pendingCount: 0, uploadedCount: 0, failedCount: 0)
        }

        let snapshot = try engineRepository.load().snapshot()
        let materialized = try materialize(pendingEntries, snapshot: snapshot)
        guard materialized.records.isEmpty == false else {
            return SQLiteSyncUploadResult(
                pendingCount: pendingEntries.count,
                uploadedCount: 0,
                failedCount: materialized.failedCount
            )
        }

        do {
            try await transport.push(materialized.records)
            try syncRepository.markJournalEntriesUploaded(materialized.uploadedIDs)
            try appendAuditLogs(for: materialized.records, action: "uploaded")
            return SQLiteSyncUploadResult(
                pendingCount: pendingEntries.count,
                uploadedCount: materialized.records.count,
                failedCount: materialized.failedCount
            )
        } catch {
            try markFailed(materialized.uploadableEntries, action: "uploadFailed", error: error)
            throw error
        }
    }

    private func materialize(
        _ entries: [SyncJournalEntry],
        snapshot: SuntraceSnapshot
    ) throws -> MaterializedUploadBatch {
        var records: [SyncRecord] = []
        var uploadedIDs: [UUID] = []
        var uploadableEntries: [SyncJournalEntry] = []
        var failedCount = 0

        for entry in entries {
            do {
                records.append(try materializer.record(for: entry, in: snapshot))
                uploadedIDs.append(entry.id)
                uploadableEntries.append(entry)
            } catch {
                failedCount += 1
                try markFailed([entry], action: "materializationFailed", error: error)
            }
        }

        return MaterializedUploadBatch(
            records: records,
            uploadedIDs: uploadedIDs,
            uploadableEntries: uploadableEntries,
            failedCount: failedCount
        )
    }

    private func markFailed(_ entries: [SyncJournalEntry], action: String, error: Error) throws {
        for entry in entries {
            try syncRepository.markJournalEntryFailed(entry.id, error: message(for: error))
            try syncRepository.appendAuditLog(
                SyncAuditLogEntry(
                    direction: .upload,
                    entityType: entry.entityType,
                    entityID: entry.entityID,
                    action: action,
                    message: message(for: error)
                )
            )
        }
    }

    private func appendAuditLogs(for records: [SyncRecord], action: String) throws {
        for record in records {
            try syncRepository.appendAuditLog(
                SyncAuditLogEntry(
                    direction: .upload,
                    entityType: record.entityType,
                    entityID: record.entityID,
                    action: action,
                    message: nil
                )
            )
        }
    }

    private func message(for error: Error) -> String {
        String(describing: error)
    }
}

private struct MaterializedUploadBatch {
    var records: [SyncRecord]
    var uploadedIDs: [UUID]
    var uploadableEntries: [SyncJournalEntry]
    var failedCount: Int
}

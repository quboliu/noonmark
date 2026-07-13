import Foundation
import SuntraceCore
import SuntraceSync

public struct SQLiteSyncUploadResult: Codable, Equatable, Sendable {
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
        let pendingEntries = try uploadCandidates(limit: limit)
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

    private func uploadCandidates(limit: Int) throws -> [SyncJournalEntry] {
        guard limit > 0 else { return [] }
        var retryableEntries: [SyncJournalEntry] = []
        for state in [SyncChangeState.pendingUpload, .failed] {
            retryableEntries.append(
                contentsOf: try syncRepository.journalEntries(state: state)
            )
        }
        return Array(
            retryableEntries
                .sorted(by: uploadCandidateComesBefore)
                .prefix(limit)
        )
    }

    private func uploadCandidateComesBefore(
        _ lhs: SyncJournalEntry,
        _ rhs: SyncJournalEntry
    ) -> Bool {
        let lhsOrder = uploadDependencyOrder(lhs.entityType)
        let rhsOrder = uploadDependencyOrder(rhs.entityType)
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        let lhsSeconds = lhs.changedAt.timeIntervalSinceReferenceDate
        let rhsSeconds = rhs.changedAt.timeIntervalSinceReferenceDate
        if lhsSeconds != rhsSeconds {
            return lhsSeconds < rhsSeconds
        }
        let lhsBits = lhsSeconds.bitPattern
        let rhsBits = rhsSeconds.bitPattern
        if lhsBits != rhsBits {
            return lhsBits < rhsBits
        }
        if lhs.entityID != rhs.entityID {
            return lhs.entityID < rhs.entityID
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func uploadDependencyOrder(_ entityType: SyncEntityType) -> Int {
        switch entityType {
        case .taskChain:
            0
        case .taskDefinition:
            1
        case .day:
            2
        case .classificationCommit:
            3
        case .dayTrace:
            4
        case .traceClassificationEvent:
            5
        case .subtask:
            6
        case .appPreferences:
            7
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

import Foundation
import NoonmarkCore
import NoonmarkSync

public struct SQLiteSyncUploadResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case pendingCount
        case uploadedCount
        case failedCount
        case awaitingConfirmationCount
    }

    public var pendingCount: Int
    public var uploadedCount: Int
    public var failedCount: Int
    public var awaitingConfirmationCount: Int

    public init(
        pendingCount: Int,
        uploadedCount: Int,
        failedCount: Int,
        awaitingConfirmationCount: Int = 0
    ) {
        self.pendingCount = pendingCount
        self.uploadedCount = uploadedCount
        self.failedCount = failedCount
        self.awaitingConfirmationCount = awaitingConfirmationCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pendingCount = try container.decode(Int.self, forKey: .pendingCount)
        uploadedCount = try container.decode(Int.self, forKey: .uploadedCount)
        failedCount = try container.decode(Int.self, forKey: .failedCount)
        awaitingConfirmationCount = try container.decodeIfPresent(
            Int.self,
            forKey: .awaitingConfirmationCount
        ) ?? 0
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
        var confirmation = try await confirmPublishedEntries()
        let snapshot = try engineRepository.load().snapshot()
        let candidateUnits = try uploadCandidateUnits(
            limit: limit,
            snapshot: snapshot
        )
        let pendingEntries = candidateUnits.flatMap(\.entries)
        guard pendingEntries.isEmpty == false else {
            confirmation.failedCount = try blockedEntryCount()
            return confirmation
        }

        let materialized = try materialize(
            candidateUnits,
            snapshot: snapshot
        )
        guard materialized.records.isEmpty == false else {
            return SQLiteSyncUploadResult(
                pendingCount: pendingEntries.count,
                uploadedCount: 0,
                failedCount: try blockedEntryCount(),
                awaitingConfirmationCount:
                confirmation.awaitingConfirmationCount
            )
        }

        do {
            let receipt = try await transport.pushAccepting(
                materialized.records
            )
            let state = receipt.confirmation
            switch state {
            case .confirmed:
                try syncRepository.markJournalEntriesUploaded(
                    materialized.uploadedIDs
                )
                try appendAuditLogs(
                    for: materialized.records,
                    action: "uploaded"
                )
                confirmation.uploadedCount += materialized.uploadedIDs.count
            case .awaitingUploadConfirmation:
                try syncRepository.markJournalEntriesPublishedLocal(
                    materialized.uploadedIDs,
                    receipt: try encodedReceipt(receipt)
                )
                confirmation.awaitingConfirmationCount +=
                    materialized.uploadedIDs.count
                try appendAuditLogs(
                    for: materialized.records,
                    action: "publishedLocal"
                )
            case .blockedUserAttention:
                try markBlockedUserAttention(
                    materialized.uploadableEntries,
                    action: "uploadBlockedUserAttention",
                    message: "transport acceptance requires user attention"
                )
            case .blockedCorruption:
                try markBlockedCorruption(
                    materialized.uploadableEntries,
                    action: "uploadBlockedCorruption",
                    message: "transport acceptance failed integrity validation"
                )
            }
            return SQLiteSyncUploadResult(
                pendingCount: pendingEntries.count,
                uploadedCount: confirmation.uploadedCount,
                failedCount: try blockedEntryCount(),
                awaitingConfirmationCount:
                confirmation.awaitingConfirmationCount
            )
        } catch let error as SyncRecordTransportError {
            try markBlockedCorruption(
                materialized.uploadableEntries,
                action: "uploadBlockedCorruption",
                message: message(for: error)
            )
            // The outbox remains durably blocked, but callers must receive
            // the typed transport rejection. Collapsing it into a generic
            // failed-count result loses the protocol reason in diagnostics
            // and makes an integrity rejection indistinguishable from a
            // local materialization error.
            throw error
        } catch let error as ICloudDriveSyncTransportError {
            try markBlockedUserAttention(
                materialized.uploadableEntries,
                action: "uploadBlockedUserAttention",
                message: message(for: error)
            )
            return SQLiteSyncUploadResult(
                pendingCount: pendingEntries.count,
                uploadedCount: confirmation.uploadedCount,
                failedCount: try blockedEntryCount(),
                awaitingConfirmationCount:
                confirmation.awaitingConfirmationCount
            )
        } catch {
            try appendAuditLogs(
                for: materialized.records,
                action: "uploadRetryPending"
            )
            throw error
        }
    }

    private func uploadCandidateUnits(
        limit: Int,
        snapshot: NoonmarkSnapshot
    ) throws -> [UploadCandidateUnit] {
        guard limit > 0 else { return [] }
        let retryableEntries = try syncRepository.journalEntries(
            state: .pendingUpload
        )
        let orderedEntries = retryableEntries.sorted(
            by: uploadCandidateComesBefore
        )
        var selectedIDs: Set<UUID> = []
        var units: [UploadCandidateUnit] = []
        for entry in orderedEntries where selectedIDs.contains(entry.id) == false {
            let atomicIDs = recurringAtomicEntryIDs(
                anchoredBy: entry,
                entries: orderedEntries,
                snapshot: snapshot
            ).subtracting(selectedIDs)
            let unitEntries = orderedEntries.filter {
                atomicIDs.contains($0.id)
            }
            guard unitEntries.isEmpty == false else { continue }
            if selectedIDs.isEmpty == false,
               selectedIDs.count + unitEntries.count > limit
            {
                break
            }
            units.append(UploadCandidateUnit(entries: unitEntries))
            selectedIDs.formUnion(atomicIDs)
            if selectedIDs.count >= limit {
                break
            }
        }
        return units
    }

    private func recurringAtomicEntryIDs(
        anchoredBy entry: SyncJournalEntry,
        entries: [SyncJournalEntry],
        snapshot: NoonmarkSnapshot
    ) -> Set<UUID> {
        guard entry.entityType == .taskCycleSeries,
              let series = snapshot.taskCycleSeries.first(where: {
                  $0.id.description == entry.entityID
              })
        else {
            return [entry.id]
        }
        let entityKeys = taskCycleEntityKeys(
            seriesID: series.id,
            snapshot: snapshot
        )
        return Set(entries.compactMap { candidate in
            entityKeys.contains(
                UploadEntityKey(
                    type: candidate.entityType,
                    id: candidate.entityID
                )
            ) ? candidate.id : nil
        })
    }

    private func taskCycleEntityKeys(
        seriesID: TaskCycleSeriesID,
        snapshot: NoonmarkSnapshot
    ) -> Set<UploadEntityKey> {
        var keys: Set<UploadEntityKey> = [
            UploadEntityKey(
                type: .taskCycleSeries,
                id: seriesID.description
            )
        ]
        let chainIDs = Set(snapshot.chains.compactMap { chain in
            chain.cycleMembership?.seriesID == seriesID
                ? chain.id
                : nil
        })
        let definitionIDs = Set(snapshot.definitions.compactMap {
            definition in
            chainIDs.contains(definition.chainID)
                ? definition.id
                : nil
        })
        let traces = snapshot.traces.filter {
            chainIDs.contains($0.chainID)
        }
        let traceIDs = Set(traces.map(\.id))

        keys.formUnion(chainIDs.map {
            UploadEntityKey(
                type: .taskChain,
                id: $0.rawValue.uuidString
            )
        })
        keys.formUnion(definitionIDs.map {
            UploadEntityKey(
                type: .taskDefinition,
                id: $0.rawValue.uuidString
            )
        })
        keys.formUnion(traces.map {
            UploadEntityKey(
                type: .dayTrace,
                id: $0.id.rawValue.uuidString
            )
        })
        keys.formUnion(traces.map {
            UploadEntityKey(
                type: .day,
                id: $0.date.description
            )
        })
        keys.formUnion(snapshot.subtasks.compactMap { subtask in
            traceIDs.contains(subtask.traceID)
                ? UploadEntityKey(
                    type: .subtask,
                    id: subtask.id.rawValue.uuidString
                )
                : nil
        })
        return keys
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
        entityType.dependencyOrder
    }

    private func materialize(
        _ units: [UploadCandidateUnit],
        snapshot: NoonmarkSnapshot
    ) throws -> MaterializedUploadBatch {
        var records: [SyncRecord] = []
        var uploadedIDs: [UUID] = []
        var uploadableEntries: [SyncJournalEntry] = []

        for unit in units {
            do {
                records.append(
                    contentsOf: try materializer.records(
                        for: unit.entries,
                        in: snapshot
                    )
                )
                uploadedIDs.append(contentsOf: unit.entries.map(\.id))
                uploadableEntries.append(contentsOf: unit.entries)
            } catch {
                try markBlockedCorruption(
                    unit.entries,
                    action: "materializationFailed",
                    message: message(for: error)
                )
            }
        }

        return MaterializedUploadBatch(
            records: records,
            uploadedIDs: uploadedIDs,
            uploadableEntries: uploadableEntries
        )
    }

    private func markBlockedCorruption(
        _ entries: [SyncJournalEntry],
        action: String,
        message: String
    ) throws {
        for entry in entries {
            try syncRepository.markJournalEntryBlockedCorruption(
                entry.id,
                error: message
            )
            try syncRepository.appendAuditLog(
                SyncAuditLogEntry(
                    direction: .upload,
                    entityType: entry.entityType,
                    entityID: entry.entityID,
                    action: action,
                    message: message
                )
            )
        }
    }

    private func markBlockedUserAttention(
        _ entries: [SyncJournalEntry],
        action: String,
        message: String
    ) throws {
        for entry in entries {
            try syncRepository.markJournalEntriesBlockedUserAttention(
                [entry.id],
                error: message
            )
            try syncRepository.appendAuditLog(
                SyncAuditLogEntry(
                    direction: .upload,
                    entityType: entry.entityType,
                    entityID: entry.entityID,
                    action: action,
                    message: message
                )
            )
        }
    }

    private func confirmPublishedEntries() async throws -> SQLiteSyncUploadResult {
        let published = try syncRepository.journalEntries(
            state: .publishedLocal
        )
        let grouped = Dictionary(grouping: published, by: \.transportReceipt)
        var result = SQLiteSyncUploadResult(
            pendingCount: 0,
            uploadedCount: 0,
            failedCount: 0,
            awaitingConfirmationCount: 0
        )
        for (receiptData, entries) in grouped {
            guard let receiptData else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "published sync entry has no receipt"
                )
            }
            let receipt = try decodedReceipt(receiptData)
            switch try await transport.confirmationStatus(for: receipt) {
            case .confirmed:
                try syncRepository.markJournalEntriesUploaded(
                    entries.map(\.id)
                )
                try appendAuditLogs(
                    for: entries,
                    action: "uploadConfirmed"
                )
                result.uploadedCount += entries.count
            case .awaitingUploadConfirmation:
                result.awaitingConfirmationCount += entries.count
            case .blockedUserAttention:
                try syncRepository.markJournalEntriesBlockedUserAttention(
                    entries.map(\.id),
                    error: "transport upload confirmation requires user attention"
                )
                try appendAuditLogs(
                    for: entries,
                    action: "uploadConfirmationBlockedUserAttention"
                )
                result.failedCount += entries.count
            case .blockedCorruption:
                try markBlockedCorruption(
                    entries,
                    action: "uploadConfirmationCorrupt",
                    message: "transport upload confirmation failed integrity validation"
                )
                result.failedCount += entries.count
            }
        }
        return result
    }

    private func blockedEntryCount() throws -> Int {
        try syncRepository.journalEntries(
            state: .blockedUserAttention
        ).count + syncRepository.journalEntries(
            state: .blockedCorruption
        ).count
    }

    private func encodedReceipt(
        _ receipt: SyncTransportPushReceipt
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(receipt)
    }

    private func decodedReceipt(
        _ data: Data
    ) throws -> SyncTransportPushReceipt {
        do {
            return try JSONDecoder().decode(
                SyncTransportPushReceipt.self,
                from: data
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "sync transport receipt is invalid"
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

    private func appendAuditLogs(
        for entries: [SyncJournalEntry],
        action: String
    ) throws {
        for entry in entries {
            try syncRepository.appendAuditLog(
                SyncAuditLogEntry(
                    direction: .upload,
                    entityType: entry.entityType,
                    entityID: entry.entityID,
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

private struct UploadCandidateUnit {
    let entries: [SyncJournalEntry]
}

private struct UploadEntityKey: Hashable {
    let type: SyncEntityType
    let id: String
}

private struct MaterializedUploadBatch {
    var records: [SyncRecord]
    var uploadedIDs: [UUID]
    var uploadableEntries: [SyncJournalEntry]
}

import Foundation
import NoonmarkCore
import NoonmarkSync

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
        let snapshot = try engineRepository.load().snapshot()
        let candidateUnits = try uploadCandidateUnits(
            limit: limit,
            snapshot: snapshot
        )
        let pendingEntries = candidateUnits.flatMap(\.entries)
        guard pendingEntries.isEmpty == false else {
            return SQLiteSyncUploadResult(pendingCount: 0, uploadedCount: 0, failedCount: 0)
        }

        let materialized = try materialize(
            candidateUnits,
            snapshot: snapshot
        )
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

    private func uploadCandidateUnits(
        limit: Int,
        snapshot: NoonmarkSnapshot
    ) throws -> [UploadCandidateUnit] {
        guard limit > 0 else { return [] }
        var retryableEntries: [SyncJournalEntry] = []
        for state in [SyncChangeState.pendingUpload, .failed] {
            retryableEntries.append(
                contentsOf: try syncRepository.journalEntries(state: state)
            )
        }
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
        var failedCount = 0

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
                failedCount += unit.entries.count
                try markFailed(
                    unit.entries,
                    action: "materializationFailed",
                    error: error
                )
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
    var failedCount: Int
}

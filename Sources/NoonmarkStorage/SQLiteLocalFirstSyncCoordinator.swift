import Foundation
import NoonmarkDiagnostics
import NoonmarkSync

public enum SQLiteLocalFirstSyncError:
    LocalizedError,
    Equatable,
    Sendable
{
    case baselineDeviceIdentityUnavailable
    case baselinePreparationFailed
    case baselineManifestInvalid
    case baselineUploadIncomplete
    case uploadMaterializationFailed(count: Int)
    case uploadQueueNotDrained
    case remoteChangesPending

    public var errorDescription: String? {
        switch self {
        case .baselineDeviceIdentityUnavailable:
            "The complete local sync baseline could not be created because "
                + "this device has no sync identity."
        case .baselinePreparationFailed:
            "The complete local sync baseline could not be created."
        case .baselineManifestInvalid:
            "The persisted local sync baseline is incomplete or corrupted."
        case .baselineUploadIncomplete:
            "The complete local sync baseline has not been fully uploaded."
        case let .uploadMaterializationFailed(count):
            "\(count) local sync records could not be prepared for upload."
        case .uploadQueueNotDrained:
            "Local changes continued while synchronization was finishing."
        case .remoteChangesPending:
            "Remote changes continued while synchronization was finishing."
        }
    }

    public var failureReason: SQLiteLocalFirstSyncFailureReason {
        switch self {
        case .baselineDeviceIdentityUnavailable,
             .baselinePreparationFailed:
            .baselineUnavailable
        case .baselineManifestInvalid:
            .baselineInvalid
        case .baselineUploadIncomplete:
            .baselineNotUploaded
        case .uploadMaterializationFailed:
            .localRecordsUnpreparable
        case .uploadQueueNotDrained:
            .localChangesPending
        case .remoteChangesPending:
            .remoteChangesPending
        }
    }
}

public enum SQLiteLocalFirstSyncFailureReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    case baselineUnavailable
    case baselineInvalid
    case baselineNotUploaded
    case localRecordsUnpreparable
    case localChangesPending
    case remoteChangesPending
    case transportOrStorage
}

public struct SQLiteLocalFirstSyncResult: Codable, Equatable, Sendable {
    public var upload: SQLiteSyncUploadResult
    public var download: SQLiteSyncDownloadResult
    public var taskChanges: SQLiteSyncTaskChanges
    public var syncedAt: Date

    public init(
        upload: SQLiteSyncUploadResult,
        download: SQLiteSyncDownloadResult,
        taskChanges: SQLiteSyncTaskChanges,
        syncedAt: Date
    ) {
        self.upload = upload
        self.download = download
        self.taskChanges = taskChanges
        self.syncedAt = syncedAt
    }

    public var transferredData: Bool {
        upload.uploadedCount > 0 || download.appliedCount > 0
    }
}

public struct SQLiteLocalFirstSyncTimestamps: Codable, Equatable, Sendable {
    public let lastSyncedAt: Date
    public let lastEffectiveSyncedAt: Date?

    public init(
        lastSyncedAt: Date,
        lastEffectiveSyncedAt: Date?
    ) {
        self.lastSyncedAt = lastSyncedAt
        self.lastEffectiveSyncedAt = lastEffectiveSyncedAt
    }

    func recordingSuccessfulSync(
        at syncedAt: Date,
        transferredData: Bool
    ) -> Self {
        let lastSyncedAt = max(self.lastSyncedAt, syncedAt)
        let lastEffectiveSyncedAt = if transferredData {
            max(self.lastEffectiveSyncedAt ?? syncedAt, syncedAt)
        } else {
            self.lastEffectiveSyncedAt
        }
        return Self(
            lastSyncedAt: lastSyncedAt,
            lastEffectiveSyncedAt: lastEffectiveSyncedAt
        )
    }
}

public enum SQLiteLocalFirstSyncStatus: Codable, Equatable, Sendable {
    case idle(since: Date)
    case succeeded(SQLiteLocalFirstSyncResult)
    case failed(
        reason: SQLiteLocalFirstSyncFailureReason,
        message: String,
        failedAt: Date
    )

    public var updatedAt: Date {
        switch self {
        case let .idle(since):
            since
        case let .succeeded(result):
            result.syncedAt
        case let .failed(_, _, failedAt):
            failedAt
        }
    }
}

public final class SQLiteLocalFirstSyncCoordinator {
    public static let lastStatusMetadataKey = "localFirst.sync.lastStatus"
    public static let timestampsMetadataKey =
        "localFirst.sync.timestamps"
    public static let baselineManifestMetadataKey =
        "localFirst.sync.baselineManifest"

    private let uploadCoordinator: SQLiteSyncUploadCoordinator
    private let downloadCoordinator: SQLiteSyncDownloadCoordinator
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let taskChangeAnalyzer: SQLiteSyncTaskChangeAnalyzer
    private let diagnosticOperation: DiagnosticOperation?
    private let maximumFinalizationAttempts = 8

    public init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        diagnosticOperation: DiagnosticOperation? = nil
    ) {
        uploadCoordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        downloadCoordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        self.diagnosticOperation = diagnosticOperation
        taskChangeAnalyzer = SQLiteSyncTaskChangeAnalyzer()
    }

    public func sync(limit: Int = 100, now: Date = Date()) async throws -> SQLiteLocalFirstSyncResult {
        do {
            diagnosticOperation?.stage(.localLoad)
            let localBefore = try engineRepository.load().snapshot()
            diagnosticOperation?.stage(.transportFetch)
            let remoteBefore = try await transport.fetchAll()
            diagnosticOperation?.stage(
                .baselinePrepare,
                progress: DiagnosticProgress(
                    recordCount: remoteBefore.count
                )
            )
            var pendingBaseline = try prepareCompleteLocalBaseline(
                now: now,
                remoteRecords: remoteBefore
            )
            var observedRemoteRecords = remoteBefore
            var remoteAfter = remoteBefore
            var upload = SQLiteSyncUploadResult(
                pendingCount: 0,
                uploadedCount: 0,
                failedCount: 0
            )
            var download = SQLiteSyncDownloadResult(
                fetchedCount: 0,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 0
            )

            for finalizationAttempt in 1 ... maximumFinalizationAttempts {
                diagnosticOperation?.stage(
                    .upload,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt
                    )
                )
                let initialUpload = try await uploadAllPending(
                    limit: limit
                )
                accumulate(initialUpload, into: &upload)
                try requireSuccessfulUpload(initialUpload)
                if let pendingBaseline {
                    try requireBaselineUploaded(pendingBaseline)
                }
                diagnosticOperation?.stage(
                    .transportFetch,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt
                    )
                )
                let fetchedForDownload = try await transport.fetchAll()
                observedRemoteRecords = retainingRemoteRecoveryEvidence(
                    observedRemoteRecords,
                    plus: fetchedForDownload
                )
                diagnosticOperation?.stage(
                    .downloadMerge,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt,
                        recordCount: observedRemoteRecords.count
                    )
                )
                let downloadObservation = try downloadCoordinator
                    .downloadAndMergeObservingRecords(
                        fetchedRecords: observedRemoteRecords,
                        detectedAt: now
                    )
                accumulate(downloadObservation.result, into: &download)

                diagnosticOperation?.stage(
                    .catchUpUpload,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt,
                        pendingCount: download.waitingCount,
                        appliedCount: download.appliedCount,
                        conflictCount: download.conflictCount
                    )
                )
                let catchUpUpload = try await uploadAllPending(limit: limit)
                accumulate(catchUpUpload, into: &upload)
                try requireSuccessfulUpload(catchUpUpload)
                if let pendingBaseline {
                    try requireBaselineUploaded(pendingBaseline)
                }

                diagnosticOperation?.stage(
                    .finalFetch,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt
                    )
                )
                remoteAfter = try await transport.fetchAll()
                let remoteObservationIsStable =
                    hasSameExactRemoteEvidence(
                        fetchedForDownload,
                        remoteAfter
                    )
                observedRemoteRecords = retainingRemoteRecoveryEvidence(
                    observedRemoteRecords,
                    plus: remoteAfter
                )
                let localAfter = try engineRepository.load().snapshot()
                let journalEntries = try syncRepository.journalEntries()
                let endpointCoverageIsComplete =
                    SyncSnapshotBaselineCoverageAuditor().isComplete(
                        snapshot: localAfter,
                        journalEntries: journalEntries,
                        remoteRecords: remoteAfter
                    )
                diagnosticOperation?.stage(
                    .coverageAndStability,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt,
                        recordCount: remoteAfter.count,
                        pendingCount: journalEntries.filter {
                            $0.state == .pendingUpload
                        }.count,
                        conflictCount: download.conflictCount
                    )
                )
                guard remoteObservationIsStable,
                      endpointCoverageIsComplete
                else {
                    guard finalizationAttempt
                        < maximumFinalizationAttempts
                    else {
                        throw endpointCoverageIsComplete
                            ? SQLiteLocalFirstSyncError
                                .remoteChangesPending
                            : SQLiteLocalFirstSyncError
                                .baselineUploadIncomplete
                    }
                    if endpointCoverageIsComplete == false,
                       let recoveryBaseline =
                       try prepareCompleteLocalBaseline(
                           now: now,
                           remoteRecords: remoteAfter
                       )
                    {
                        pendingBaseline = recoveryBaseline
                    }
                    continue
                }

                let taskChanges = taskChangeAnalyzer.changes(
                    localBefore: localBefore,
                    localAfter: localAfter,
                    remoteBefore: remoteBefore,
                    remoteAfter: remoteAfter
                )
                let result = SQLiteLocalFirstSyncResult(
                    upload: upload,
                    download: download,
                    taskChanges: taskChanges,
                    syncedAt: now
                )
                let timestamps = try Self.timestamps(
                    in: syncRepository
                ).map {
                    $0.recordingSuccessfulSync(
                        at: now,
                        transferredData: result.transferredData
                    )
                } ?? SQLiteLocalFirstSyncTimestamps(
                    lastSyncedAt: now,
                    lastEffectiveSyncedAt:
                    result.transferredData ? now : nil
                )
                diagnosticOperation?.stage(
                    .successMetadata,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt,
                        recordCount: remoteAfter.count,
                        pendingCount: upload.pendingCount,
                        appliedCount: download.appliedCount,
                        conflictCount: download.conflictCount
                    )
                )
                if try saveSuccessMetadata(
                    status: .succeeded(result),
                    timestamps: timestamps,
                    establishedBaseline: pendingBaseline?.established(
                        at: now
                    )
                ) {
                    diagnosticOperation?.succeed(
                        progress: DiagnosticProgress(
                            recordCount: remoteAfter.count,
                            pendingCount: upload.pendingCount,
                            appliedCount: download.appliedCount,
                            conflictCount: download.conflictCount
                        )
                    )
                    return result
                }
                guard finalizationAttempt < maximumFinalizationAttempts else {
                    throw SQLiteLocalFirstSyncError
                        .uploadQueueNotDrained
                }
            }
            preconditionFailure(
                "sync finalization loop must return or throw"
            )
        } catch {
            diagnosticOperation?.fail(Self.diagnosticFailure(for: error))
            try? Self.persistFailure(
                error,
                at: now,
                in: syncRepository
            )
            throw error
        }
    }

    private static func diagnosticFailure(
        for error: Error
    ) -> DiagnosticFailure {
        guard let syncError = error as? SQLiteLocalFirstSyncError else {
            return DiagnosticFailureClassifier.classify(error)
        }
        let code: Int = switch syncError {
        case .baselineDeviceIdentityUnavailable:
            1
        case .baselinePreparationFailed:
            2
        case .baselineManifestInvalid:
            3
        case .baselineUploadIncomplete:
            4
        case .uploadMaterializationFailed:
            5
        case .uploadQueueNotDrained:
            6
        case .remoteChangesPending:
            7
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }

    private func retainingRemoteRecoveryEvidence(
        _ existing: [SyncRecord],
        plus additional: [SyncRecord]
    ) -> [SyncRecord] {
        let replacedCurrentRecordIDs = Set(
            additional.compactMap { record in
                record.entityType.requiresImmutableRecordPayload
                    ? nil
                    : record.id
            }
        )
        var recordsByEvidenceID: [
            SyncRecordEvidenceID: SyncRecord
        ] = [:]
        for record in existing
        where record.entityType.requiresImmutableRecordPayload
            || replacedCurrentRecordIDs.contains(record.id) == false
        {
            recordsByEvidenceID[
                SyncRecordEvidenceID(record: record)
            ] = record
        }
        for record in additional {
            recordsByEvidenceID[
                SyncRecordEvidenceID(record: record)
            ] = record
        }
        return recordsByEvidenceID
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map(\.value)
    }

    private func hasSameExactRemoteEvidence(
        _ lhs: [SyncRecord],
        _ rhs: [SyncRecord]
    ) -> Bool {
        Set(lhs.map(SyncRecordEvidenceID.init(record:)))
            == Set(rhs.map(SyncRecordEvidenceID.init(record:)))
    }

    private func accumulate(
        _ next: SQLiteSyncUploadResult,
        into result: inout SQLiteSyncUploadResult
    ) {
        result.pendingCount += next.pendingCount
        result.uploadedCount += next.uploadedCount
        result.failedCount += next.failedCount
    }

    private func accumulate(
        _ next: SQLiteSyncDownloadResult,
        into result: inout SQLiteSyncDownloadResult
    ) {
        result.fetchedCount += next.fetchedCount
        result.appliedCount += next.appliedCount
        result.waitingCount = next.waitingCount
        result.conflictCount = next.conflictCount
    }

    private func requireSuccessfulUpload(
        _ upload: SQLiteSyncUploadResult
    ) throws {
        guard upload.failedCount == 0 else {
            throw SQLiteLocalFirstSyncError
                .uploadMaterializationFailed(
                    count: upload.failedCount
                )
        }
    }

    private func uploadAllPending(limit: Int) async throws -> SQLiteSyncUploadResult {
        let batchLimit = max(limit, 1)
        var result = SQLiteSyncUploadResult(
            pendingCount: 0,
            uploadedCount: 0,
            failedCount: 0
        )

        while true {
            let batch = try await uploadCoordinator.uploadPending(
                limit: batchLimit
            )
            result.pendingCount += batch.pendingCount
            result.uploadedCount += batch.uploadedCount
            result.failedCount += batch.failedCount

            if batch.pendingCount == 0 || batch.failedCount > 0 {
                return result
            }
        }
    }

    private func prepareCompleteLocalBaseline(
        now: Date,
        remoteRecords: [SyncRecord]
    ) throws -> SQLiteSyncBaselineManifest? {
        let snapshot = try engineRepository.load().snapshot()
        let journalEntries = try syncRepository.journalEntries()
        let storedManifest: SQLiteSyncBaselineManifest?
        do {
            storedManifest = try syncRepository.metadata(
                for: Self.baselineManifestMetadataKey
            ).map(SQLiteSyncBaselineManifest.decode)
        } catch {
            throw SQLiteLocalFirstSyncError.baselineManifestInvalid
        }

        if let storedManifest,
           storedManifest.validate(against: journalEntries) == false
        {
            throw SQLiteLocalFirstSyncError.baselineManifestInvalid
        }

        let missingFactCount = SyncSnapshotBaselineCoverageAuditor()
            .missingFactCount(
                snapshot: snapshot,
                journalEntries: journalEntries,
                remoteRecords: remoteRecords
            )
        if missingFactCount == 0 {
            return storedManifest?.state == .pending
                ? storedManifest
                : nil
        }
        NSLog(
            "Noonmark sync baseline audit incomplete missing=%ld "
                + "days=%ld series=%ld chains=%ld definitions=%ld "
                + "traces=%ld subtasks=%ld classificationCommits=%ld "
                + "classificationEvents=%ld journal=%ld journalTypes=%@",
            missingFactCount,
            snapshot.days.count,
            snapshot.taskCycleSeries.count,
            snapshot.chains.count,
            snapshot.definitions.count,
            snapshot.traces.count,
            snapshot.subtasks.count,
            snapshot.classifications.changeRecords.count,
            snapshot.classifications.snapshotEventsByTraceID.values
                .reduce(0) { $0 + $1.count },
            journalEntries.count,
            Dictionary(grouping: journalEntries, by: \.entityType)
                .mapValues(\.count)
                .map { "\($0.key.rawValue)=\($0.value)" }
                .sorted()
                .joined(separator: ",")
        )
        if let storedManifest, storedManifest.state == .pending {
            do {
                try syncRepository
                    .requeueJournalEntriesForBaselineRecovery(
                        Set(journalEntries.map(\.id))
                    )
                let requeuedEntries = try syncRepository.journalEntries()
                guard storedManifest.validate(
                    against: requeuedEntries
                ) else {
                    throw SQLiteLocalFirstSyncError
                        .baselineManifestInvalid
                }
                if SyncSnapshotBaselineCoverageAuditor()
                    .isComplete(
                        snapshot: snapshot,
                        journalEntries: requeuedEntries,
                        remoteRecords: remoteRecords
                    )
                {
                    return storedManifest
                }
            } catch let error as SQLiteLocalFirstSyncError {
                throw error
            } catch {
                throw SQLiteLocalFirstSyncError
                    .baselinePreparationFailed
            }
            NSLog(
                "Noonmark pending sync baseline could not cover the "
                    + "current snapshot after requeue; creating a new "
                    + "complete baseline"
            )
        }

        guard let identity = try syncRepository.loadDeviceIdentity() else {
            throw SQLiteLocalFirstSyncError
                .baselineDeviceIdentityUnavailable
        }
        let entries: [SyncJournalEntry]
        do {
            entries = try SyncSnapshotBaselineBuilder().journalEntries(
                from: snapshot,
                modifiedBy: identity.deviceID,
                createdAt: now
            )
        } catch {
            throw SQLiteLocalFirstSyncError.baselinePreparationFailed
        }
        guard entries.isEmpty == false else {
            throw SQLiteLocalFirstSyncError.baselinePreparationFailed
        }
        let manifest = SQLiteSyncBaselineManifest(
            createdAt: now,
            entries: entries
        )
        do {
            try syncRepository.saveBaselineJournal(
                entries,
                manifestMetadata: try manifest.metadata(
                    key: Self.baselineManifestMetadataKey,
                    updatedAt: now
                )
            )
        } catch {
            throw SQLiteLocalFirstSyncError.baselinePreparationFailed
        }
        return manifest
    }

    private func requireBaselineUploaded(
        _ manifest: SQLiteSyncBaselineManifest
    ) throws {
        let entries = try syncRepository.journalEntries()
        guard manifest.validate(against: entries) else {
            throw SQLiteLocalFirstSyncError.baselineManifestInvalid
        }
        let entriesByID = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.id, $0) }
        )
        guard manifest.expectedJournalEntryIDs.allSatisfy({
            entriesByID[$0]?.state == .uploaded
        }) else {
            throw SQLiteLocalFirstSyncError.baselineUploadIncomplete
        }
    }

    public static func persistFailure(
        _ error: Error,
        at failedAt: Date,
        in repository: SQLiteSyncRepository
    ) throws {
        let reason =
            (error as? SQLiteLocalFirstSyncError)?.failureReason
                ?? .transportOrStorage
        try repository.saveMetadata(
            statusMetadata(
                .failed(
                    reason: reason,
                    message: error.localizedDescription,
                    failedAt: failedAt
                )
            )
        )
    }

    private func saveSuccessMetadata(
        status: SQLiteLocalFirstSyncStatus,
        timestamps: SQLiteLocalFirstSyncTimestamps,
        establishedBaseline: SQLiteSyncBaselineManifest?
    ) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var metadata = [
            try Self.statusMetadata(status),
            SyncMetadataEntry(
                key: Self.timestampsMetadataKey,
                value: try encoder.encode(timestamps),
                updatedAt: timestamps.lastSyncedAt
            )
        ]
        if let establishedBaseline {
            metadata.append(
                try establishedBaseline.metadata(
                    key: Self.baselineManifestMetadataKey,
                    updatedAt: timestamps.lastSyncedAt
                )
            )
        }
        return try syncRepository
            .saveMetadataIfJournalIsFullyUploaded(metadata)
    }

    private static func statusMetadata(
        _ status: SQLiteLocalFirstSyncStatus
    ) throws -> SyncMetadataEntry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return SyncMetadataEntry(
            key: Self.lastStatusMetadataKey,
            value: try encoder.encode(status),
            updatedAt: status.updatedAt
        )
    }

    public static func timestamps(
        in repository: SQLiteSyncRepository
    ) throws
        -> SQLiteLocalFirstSyncTimestamps?
    {
        guard let metadata = try repository.metadata(
            for: timestampsMetadataKey
        ) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let timestamps = try decoder.decode(
            SQLiteLocalFirstSyncTimestamps.self,
            from: metadata.value
        )
        let effectiveTimestampIsFinite =
            timestamps.lastEffectiveSyncedAt?
            .timeIntervalSinceReferenceDate.isFinite ?? true
        let effectiveTimestampIsNotLater =
            timestamps.lastEffectiveSyncedAt.map {
                $0 <= timestamps.lastSyncedAt
            } ?? true
        guard timestamps.lastSyncedAt.timeIntervalSinceReferenceDate.isFinite,
              effectiveTimestampIsFinite,
              effectiveTimestampIsNotLater
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "local-first sync timestamps are invalid"
            )
        }
        return timestamps
    }
}

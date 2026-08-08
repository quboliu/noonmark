import Foundation
import NoonmarkCore
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
    case previousSessionInterrupted

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
        case .previousSessionInterrupted:
            "Synchronization did not finish before the previous app session ended."
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
        case .previousSessionInterrupted:
            .operationInterrupted
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
    case operationInterrupted

    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .baselineUnavailable: 1
        case .baselineInvalid: 2
        case .baselineNotUploaded: 3
        case .localRecordsUnpreparable: 4
        case .localChangesPending: 5
        case .remoteChangesPending: 6
        case .transportOrStorage: 7
        case .operationInterrupted: 8
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
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

    public var isAwaitingUploadConfirmation: Bool {
        upload.awaitingConfirmationCount > 0
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
    case awaitingUploadConfirmation(
        result: SQLiteLocalFirstSyncResult,
        observedAt: Date
    )
    case succeeded(SQLiteLocalFirstSyncResult)
    case failed(
        reason: SQLiteLocalFirstSyncFailureReason,
        message: String,
        failedAt: Date,
        diagnosticCorrelation: DiagnosticOperationCorrelation? = nil
    )

    public var updatedAt: Date {
        switch self {
        case let .idle(since):
            since
        case let .awaitingUploadConfirmation(_, observedAt):
            observedAt
        case let .succeeded(result):
            result.syncedAt
        case let .failed(_, _, failedAt, _):
            failedAt
        }
    }
}

public final class SQLiteLocalFirstSyncCoordinator {
    public static let lastStatusMetadataKey = "localFirst.sync.lastStatus"
    public static let timestampsMetadataKey =
        "localFirst.sync.timestamps"
    public static let baselineManifestMetadataKey =
        "localFirst.sync.incrementalBaseline"

    private let uploadCoordinator: SQLiteSyncUploadCoordinator
    private let downloadCoordinator: SQLiteSyncDownloadCoordinator
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transportNamespace: String
    private let taskChangeAnalyzer: SQLiteSyncTaskChangeAnalyzer
    private let diagnosticOperation: DiagnosticOperation?
    private let completesDiagnosticOperationOnSuccess: Bool
    private let completesDiagnosticOperationOnFailure: Bool
    private let diagnosticHeartbeatIntervalNanoseconds: UInt64
    private let failureClock: @Sendable () -> Date
    private let maximumFinalizationAttempts = 8

    public convenience init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        diagnosticOperation: DiagnosticOperation? = nil,
        completesDiagnosticOperationOnSuccess: Bool = true,
        completesDiagnosticOperationOnFailure: Bool = true
    ) {
        self.init(
            databaseURL: databaseURL,
            transport: transport,
            diagnosticOperation: diagnosticOperation,
            completesDiagnosticOperationOnSuccess:
            completesDiagnosticOperationOnSuccess,
            completesDiagnosticOperationOnFailure:
            completesDiagnosticOperationOnFailure,
            diagnosticHeartbeatIntervalNanoseconds: 30_000_000_000,
            failureClock: { Date() }
        )
    }

    convenience init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        diagnosticOperation: DiagnosticOperation? = nil,
        failureClock: @escaping @Sendable () -> Date
    ) {
        self.init(
            databaseURL: databaseURL,
            transport: transport,
            diagnosticOperation: diagnosticOperation,
            completesDiagnosticOperationOnSuccess: true,
            completesDiagnosticOperationOnFailure: true,
            diagnosticHeartbeatIntervalNanoseconds: 30_000_000_000,
            failureClock: failureClock
        )
    }

    init(
        databaseURL: URL,
        transport: SyncRecordTransport,
        diagnosticOperation: DiagnosticOperation?,
        completesDiagnosticOperationOnSuccess: Bool,
        completesDiagnosticOperationOnFailure: Bool,
        diagnosticHeartbeatIntervalNanoseconds: UInt64,
        failureClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        uploadCoordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        downloadCoordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        transportNamespace = transport.frontierNamespace
        self.diagnosticOperation = diagnosticOperation
        self.completesDiagnosticOperationOnSuccess =
            completesDiagnosticOperationOnSuccess
        self.completesDiagnosticOperationOnFailure =
            completesDiagnosticOperationOnFailure
        self.diagnosticHeartbeatIntervalNanoseconds = max(
            1,
            diagnosticHeartbeatIntervalNanoseconds
        )
        self.failureClock = failureClock
        taskChangeAnalyzer = SQLiteSyncTaskChangeAnalyzer()
    }

    public func sync(limit: Int = 100, now: Date = Date()) async throws -> SQLiteLocalFirstSyncResult {
        let diagnosticHeartbeatTask = startDiagnosticHeartbeatTask()
        defer { diagnosticHeartbeatTask?.cancel() }
        do {
            diagnosticOperation?.stage(.localLoad)
            let localBefore = try engineRepository.load().snapshot()
            diagnosticOperation?.stage(
                .baselinePrepare,
                progress: DiagnosticProgress(recordCount: 0)
            )
            let pendingBaseline = try prepareCompleteLocalBaseline(
                now: now
            )
            // Capture the durable outbox before its state is advanced by this
            // run. Incremental transports cannot reconstruct a full remote
            // before/after mirror without violating their steady-state cost
            // bound, so this is the authoritative outbound change evidence.
            let journalEntriesBeforeSync = try syncRepository.journalEntries()
            var observedRemoteRecords: [SyncRecord] = []
            var upload = SQLiteSyncUploadResult(
                pendingCount: 0,
                uploadedCount: 0,
                failedCount: 0,
                awaitingConfirmationCount: 0
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
                if initialUpload.awaitingConfirmationCount > 0 {
                    return try finishAwaitingUploadConfirmation(
                        upload: upload,
                        download: download,
                        localBefore: localBefore,
                        now: now,
                        attempt: finalizationAttempt
                    )
                }
                if let pendingBaseline {
                    try requireBaselineUploaded(pendingBaseline)
                }

                var pageHasMore = true
                while pageHasMore {
                    diagnosticOperation?.stage(
                        .transportFetch,
                        progress: DiagnosticProgress(
                            attempt: finalizationAttempt
                        )
                    )
                    let observation = try await downloadCoordinator
                        .downloadAndMergeObservingRecords(
                            detectedAt: now,
                            limit: max(limit, 1)
                        )
                    diagnosticOperation?.stage(.downloadMerge)
                    observedRemoteRecords.append(
                        contentsOf: observation.fetchedRecords
                    )
                    accumulate(observation.result, into: &download)
                    pageHasMore = observation.hasMoreRemoteChanges
                    diagnosticOperation?.observeHeartbeatProgress(
                        DiagnosticProgress(
                            attempt: finalizationAttempt,
                            recordCount: download.fetchedCount,
                            appliedCount: download.appliedCount,
                            conflictCount: download.conflictCount
                        )
                    )
                }

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
                if catchUpUpload.awaitingConfirmationCount > 0 {
                    return try finishAwaitingUploadConfirmation(
                        upload: upload,
                        download: download,
                        localBefore: localBefore,
                        now: now,
                        attempt: finalizationAttempt
                    )
                }
                if let pendingBaseline {
                    try requireBaselineUploaded(pendingBaseline)
                }

                diagnosticOperation?.stage(
                    .finalFetch,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt
                    )
                )
                let stabilityObservation = try await downloadCoordinator
                    .downloadAndMergeObservingRecords(
                        detectedAt: now,
                        limit: max(limit, 1)
                    )
                diagnosticOperation?.stage(.downloadMerge)
                observedRemoteRecords.append(
                    contentsOf: stabilityObservation.fetchedRecords
                )
                accumulate(stabilityObservation.result, into: &download)
                let localAfter = try engineRepository.load().snapshot()
                let unfinishedJournalEntryCount = try syncRepository
                    .unfinishedJournalEntryCount()
                diagnosticOperation?.stage(
                    .coverageAndStability,
                    progress: DiagnosticProgress(
                        attempt: finalizationAttempt,
                        recordCount: stabilityObservation
                            .fetchedRecords.count,
                        pendingCount: unfinishedJournalEntryCount,
                        conflictCount: download.conflictCount
                    )
                )
                let remoteObservationIsStable =
                    stabilityObservation.fetchedRecords.isEmpty
                    && stabilityObservation.hasMoreRemoteChanges == false
                let outboxIsDrained = unfinishedJournalEntryCount == 0
                guard remoteObservationIsStable,
                      outboxIsDrained,
                      download.waitingCount == 0
                else {
                    guard finalizationAttempt
                        < maximumFinalizationAttempts
                    else {
                        if outboxIsDrained == false {
                            throw SQLiteLocalFirstSyncError
                                .uploadQueueNotDrained
                        }
                        throw SQLiteLocalFirstSyncError
                            .remoteChangesPending
                    }
                    continue
                }

                let taskChanges = taskChangeAnalyzer.changes(
                    localBefore: localBefore,
                    localAfter: localAfter,
                    outboundJournalEntries: journalEntriesBeforeSync
                )
                let establishedBaseline: SQLiteSyncBaselineManifest? = if let pendingBaseline {
                    pendingBaseline.established(at: now)
                } else {
                    try establishedRemoteBaselineIfComplete(
                        snapshot: localAfter,
                        observedRemoteRecords: observedRemoteRecords,
                        at: now
                    )
                }
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
                        recordCount: observedRemoteRecords.count,
                        pendingCount: upload.pendingCount,
                        appliedCount: download.appliedCount,
                        conflictCount: download.conflictCount
                    )
                )
                if try saveSuccessMetadata(
                    status: .succeeded(result),
                    timestamps: timestamps,
                    establishedBaseline: establishedBaseline
                ) {
                    if completesDiagnosticOperationOnSuccess {
                        diagnosticOperation?.succeed(
                            progress: DiagnosticProgress(
                                recordCount: observedRemoteRecords.count,
                                pendingCount: upload.pendingCount,
                                appliedCount: download.appliedCount,
                                conflictCount: download.conflictCount
                            )
                        )
                    }
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
            let failedAt = Self.persistedFailureTimestamp(failureClock())
            let diagnosticCorrelation = finishDiagnosticFailure(
                error,
                at: failedAt
            )
            try? Self.persistFailure(
                error,
                at: failedAt,
                diagnosticCorrelation: diagnosticCorrelation,
                in: syncRepository
            )
            throw error
        }
    }

    private func finishAwaitingUploadConfirmation(
        upload: SQLiteSyncUploadResult,
        download: SQLiteSyncDownloadResult,
        localBefore: NoonmarkSnapshot,
        now: Date,
        attempt: Int
    ) throws -> SQLiteLocalFirstSyncResult {
        let localAfter = try engineRepository.load().snapshot()
        let result = SQLiteLocalFirstSyncResult(
            upload: upload,
            download: download,
            taskChanges: taskChangeAnalyzer.changes(
                localBefore: localBefore,
                localAfter: localAfter,
                remoteBefore: [],
                remoteAfter: []
            ),
            syncedAt: now
        )
        try syncRepository.saveMetadata(
            try Self.statusMetadata(
                .awaitingUploadConfirmation(
                    result: result,
                    observedAt: now
                )
            )
        )
        diagnosticOperation?.stage(
            .successMetadata,
            progress: DiagnosticProgress(
                attempt: attempt,
                pendingCount: upload.awaitingConfirmationCount,
                appliedCount: download.appliedCount,
                conflictCount: download.conflictCount
            )
        )
        if completesDiagnosticOperationOnSuccess {
            diagnosticOperation?.succeed(
                progress: DiagnosticProgress(
                    pendingCount: upload.awaitingConfirmationCount,
                    appliedCount: download.appliedCount,
                    conflictCount: download.conflictCount
                )
            )
        }
        return result
    }

    private func finishDiagnosticFailure(
        _ error: Error,
        at failedAt: Date
    ) -> DiagnosticOperationCorrelation? {
        guard completesDiagnosticOperationOnFailure,
              let diagnosticOperation
        else { return nil }
        return diagnosticOperation.failWithCorrelation(
            Self.diagnosticFailure(for: error),
            detail: Self.diagnosticFailureDetail(for: error),
            at: failedAt
        )
    }

    private func startDiagnosticHeartbeatTask() -> Task<Void, Never>? {
        guard let diagnosticOperation else { return nil }
        let interval = diagnosticHeartbeatIntervalNanoseconds
        return Task {
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard Task.isCancelled == false else { return }
                diagnosticOperation.heartbeat()
            }
        }
    }

    private static func diagnosticFailure(
        for error: Error
    ) -> DiagnosticFailure {
        let reason = (error as? SQLiteLocalFirstSyncError)?.failureReason
            ?? .transportOrStorage
        return reason.diagnosticFailure
    }

    private static func diagnosticFailureDetail(
        for error: Error
    ) -> DiagnosticFailure {
        if let provider = error as? any DiagnosticFailureProviding {
            return provider.diagnosticFailure
        }
        let systemError = error as NSError
        return DiagnosticSystemFailureMapper.map(
            domain: systemError.domain,
            code: systemError.code
        )
    }

    private func accumulate(
        _ next: SQLiteSyncUploadResult,
        into result: inout SQLiteSyncUploadResult
    ) {
        result.pendingCount += next.pendingCount
        result.uploadedCount += next.uploadedCount
        result.failedCount += next.failedCount
        result.awaitingConfirmationCount =
            next.awaitingConfirmationCount
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
            failedCount: 0,
            awaitingConfirmationCount: 0
        )

        while true {
            let batch = try await uploadCoordinator.uploadPending(
                limit: batchLimit
            )
            result.pendingCount += batch.pendingCount
            result.uploadedCount += batch.uploadedCount
            result.failedCount += batch.failedCount
            result.awaitingConfirmationCount =
                batch.awaitingConfirmationCount
            diagnosticOperation?.observeHeartbeatProgress(
                DiagnosticProgress(
                    recordCount: result.uploadedCount,
                    pendingCount: batch.pendingCount
                )
            )

            if batch.pendingCount == 0
                || batch.failedCount > 0
                || batch.awaitingConfirmationCount > 0
            {
                return result
            }
        }
    }

    private func prepareCompleteLocalBaseline(
        now: Date
    ) throws -> SQLiteSyncBaselineManifest? {
        let storedManifest: SQLiteSyncBaselineManifest?
        do {
            storedManifest = try syncRepository.metadata(
                for: Self.baselineManifestMetadataKey
            ).map(SQLiteSyncBaselineManifest.decode)
        } catch {
            throw SQLiteLocalFirstSyncError.baselineManifestInvalid
        }

        let snapshot = try engineRepository.load().snapshot()
        let journalEntries = try syncRepository.journalEntries()

        // A frontier and its coverage proof only apply to the endpoint that
        // produced them. Switching endpoints is a fresh replication boundary:
        // retain local data, but create a new complete baseline instead of
        // treating the old endpoint's uploaded journal as remote coverage.
        if let storedManifest,
           let namespace = storedManifest.transportNamespace,
           namespace != transportNamespace
        {
            // A partial baseline can have published evidence whose acceptance
            // is still unknown. It must not be rebound or regenerated against
            // another endpoint: that would silently treat an interrupted
            // replication attempt as settled. The caller must finish or
            // explicitly recover the original endpoint first.
            guard storedManifest.state == .established else {
                throw SQLiteLocalFirstSyncError.baselineManifestInvalid
            }
            return try reseedCompleteLocalBaseline(
                from: snapshot,
                at: now
            )
        }

        if let storedManifest,
           storedManifest.state == .established
        {
            guard storedManifest.hasValidStructure,
                  let boundManifest = storedManifest.binding(
                      to: transportNamespace
                  )
            else {
                throw SQLiteLocalFirstSyncError.baselineManifestInvalid
            }
            if boundManifest != storedManifest {
                try syncRepository.saveMetadata(
                    try boundManifest.metadata(
                        key: Self.baselineManifestMetadataKey,
                        updatedAt: now
                    )
                )
            }
            return nil
        }
        if let storedManifest {
            guard storedManifest.validate(against: journalEntries),
                  let boundManifest = storedManifest.binding(
                      to: transportNamespace
                  )
            else {
                throw SQLiteLocalFirstSyncError.baselineManifestInvalid
            }
            if boundManifest != storedManifest {
                try syncRepository.saveMetadata(
                    try boundManifest.metadata(
                        key: Self.baselineManifestMetadataKey,
                        updatedAt: now
                    )
                )
            }
            return boundManifest
        }
        let missingFactCount = SyncSnapshotBaselineCoverageAuditor()
            .missingFactCount(
                snapshot: snapshot,
                journalEntries: journalEntries,
                remoteRecords: []
            )
        guard missingFactCount > 0 else {
            // A normal local save already has a complete pending journal, but
            // it has no manifest until the first transport round trip. Bind
            // that exact evidence now and establish it only after this run's
            // upload plus stable pull succeeds. Without this pending manifest
            // the next sync would treat uploaded rows as local-only evidence
            // and redundantly rebuild the entire baseline.
            guard journalEntries.isEmpty == false else { return nil }
            let manifest = SQLiteSyncBaselineManifest(
                createdAt: now,
                entries: journalEntries,
                transportNamespace: transportNamespace
            )
            do {
                try syncRepository.saveMetadata(
                    try manifest.metadata(
                        key: Self.baselineManifestMetadataKey,
                        updatedAt: now
                    )
                )
            } catch {
                throw SQLiteLocalFirstSyncError.baselinePreparationFailed
            }
            return manifest
        }
        diagnosticOperation?.stage(
            .baselineCoverageGap,
            progress: DiagnosticProgress(
                recordCount: missingFactCount,
                pendingCount: journalEntries.count
            )
        )
        return try reseedCompleteLocalBaseline(from: snapshot, at: now)
    }

    private func reseedCompleteLocalBaseline(
        from snapshot: NoonmarkSnapshot,
        at now: Date
    ) throws -> SQLiteSyncBaselineManifest {
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
            entries: entries,
            transportNamespace: transportNamespace
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

    private func establishedRemoteBaselineIfComplete(
        snapshot: NoonmarkSnapshot,
        observedRemoteRecords: [SyncRecord],
        at now: Date
    ) throws -> SQLiteSyncBaselineManifest? {
        guard observedRemoteRecords.isEmpty == false,
              try syncRepository.metadata(
                  for: Self.baselineManifestMetadataKey
              ) == nil,
              SyncSnapshotBaselineCoverageAuditor().isComplete(
                  snapshot: snapshot,
                  journalEntries: try syncRepository.journalEntries(),
                  remoteRecords: observedRemoteRecords
              )
        else {
            return nil
        }
        return SQLiteSyncBaselineManifest(
            createdAt: now,
            entries: [],
            transportNamespace: transportNamespace
        ).established(at: now)
    }

    public static func persistFailure(
        _ error: Error,
        at failedAt: Date,
        diagnosticCorrelation: DiagnosticOperationCorrelation? = nil,
        in repository: SQLiteSyncRepository
    ) throws {
        let failedAt = persistedFailureTimestamp(failedAt)
        let reason =
            (error as? SQLiteLocalFirstSyncError)?.failureReason
                ?? .transportOrStorage
        try repository.saveMetadata(
            statusMetadata(
                .failed(
                    reason: reason,
                    message: error.localizedDescription,
                    failedAt: failedAt,
                    diagnosticCorrelation: diagnosticCorrelation
                )
            )
        )
    }

    public static func persistInterruptedSyncFailureIfNewer(
        at interruptedAt: Date,
        diagnosticCorrelation: DiagnosticOperationCorrelation,
        in repository: SQLiteSyncRepository
    ) throws -> Bool {
        let interruptedAt = persistedFailureTimestamp(interruptedAt)
        if let metadata = try repository.metadata(
            for: lastStatusMetadataKey
        ) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let current = try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: metadata.value
            )
            let currentCorrelation: DiagnosticOperationCorrelation? =
                if case let .failed(_, _, _, correlation) = current {
                    correlation
                } else {
                    nil
                }
            guard currentCorrelation != diagnosticCorrelation else {
                return false
            }
            guard current.updatedAt <= interruptedAt else {
                return false
            }
            if current.updatedAt == interruptedAt {
                // ISO-8601 metadata is persisted at second precision. A
                // previous failure and the later interruption observed while
                // restoring the next session can therefore decode to the same
                // timestamp. Only another failed status is replaceable in
                // that tie; a successful or idle status remains authoritative.
                guard case .failed = current else { return false }
            }
        }
        try persistFailure(
            SQLiteLocalFirstSyncError.previousSessionInterrupted,
            at: interruptedAt,
            diagnosticCorrelation: diagnosticCorrelation,
            in: repository
        )
        return true
    }

    public static func persistedFailureTimestamp(_ date: Date) -> Date {
        Date(
            timeIntervalSince1970: date.timeIntervalSince1970
                .rounded(.down)
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

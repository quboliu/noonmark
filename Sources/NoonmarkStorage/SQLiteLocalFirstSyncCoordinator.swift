import Foundation
import NoonmarkSync

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
    case failed(message: String, failedAt: Date)

    public var updatedAt: Date {
        switch self {
        case let .idle(since):
            since
        case let .succeeded(result):
            result.syncedAt
        case let .failed(_, failedAt):
            failedAt
        }
    }
}

public final class SQLiteLocalFirstSyncCoordinator {
    public static let lastStatusMetadataKey = "localFirst.sync.lastStatus"
    public static let timestampsMetadataKey =
        "localFirst.sync.timestamps"

    private let uploadCoordinator: SQLiteSyncUploadCoordinator
    private let downloadCoordinator: SQLiteSyncDownloadCoordinator
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let transport: SyncRecordTransport
    private let taskChangeAnalyzer: SQLiteSyncTaskChangeAnalyzer

    public init(databaseURL: URL, transport: SyncRecordTransport) {
        uploadCoordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        downloadCoordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.transport = transport
        taskChangeAnalyzer = SQLiteSyncTaskChangeAnalyzer()
    }

    public func sync(limit: Int = 100, now: Date = Date()) async throws -> SQLiteLocalFirstSyncResult {
        do {
            let localBefore = try engineRepository.load().snapshot()
            let remoteBefore = try await transport.fetchAll()
            let upload = try await uploadAllPending(limit: limit)
            let downloadObservation = try await downloadCoordinator
                .downloadAndMergeObservingRecords(
                    detectedAt: now
                )
            let remoteAfter = downloadObservation.fetchedRecords
            let download = downloadObservation.result
            let taskChanges = taskChangeAnalyzer.changes(
                localBefore: localBefore,
                localAfter: try engineRepository.load().snapshot(),
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
            try saveSuccessMetadata(
                status: .succeeded(result),
                timestamps: timestamps
            )
            return result
        } catch {
            try? saveMetadata(
                .failed(message: error.localizedDescription, failedAt: now)
            )
            throw error
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

    private func saveMetadata(_ status: SQLiteLocalFirstSyncStatus) throws {
        try syncRepository.saveMetadata(statusMetadata(status))
    }

    private func saveSuccessMetadata(
        status: SQLiteLocalFirstSyncStatus,
        timestamps: SQLiteLocalFirstSyncTimestamps
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try syncRepository.saveMetadata([
            statusMetadata(status),
            SyncMetadataEntry(
                key: Self.timestampsMetadataKey,
                value: try encoder.encode(timestamps),
                updatedAt: timestamps.lastSyncedAt
            )
        ])
    }

    private func statusMetadata(
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

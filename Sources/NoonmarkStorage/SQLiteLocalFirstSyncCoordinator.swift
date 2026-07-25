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
            try saveMetadata(.succeeded(result))
            return result
        } catch {
            try? saveMetadata(
                .failed(message: error.localizedDescription, failedAt: now)
            )
            throw error
        }
    }

    private func uploadAllPending(limit: Int) async throws -> SQLiteSyncUploadResult {
        var result = SQLiteSyncUploadResult(
            pendingCount: 0,
            uploadedCount: 0,
            failedCount: 0
        )

        while true {
            let batch = try await uploadCoordinator.uploadPending(limit: limit)
            result.pendingCount += batch.pendingCount
            result.uploadedCount += batch.uploadedCount
            result.failedCount += batch.failedCount

            if batch.pendingCount == 0 || batch.failedCount > 0 {
                return result
            }
        }
    }

    private func saveMetadata(_ status: SQLiteLocalFirstSyncStatus) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: Self.lastStatusMetadataKey,
                value: try encoder.encode(status),
                updatedAt: status.updatedAt
            )
        )
    }
}

import Foundation
import NoonmarkSync

public struct SQLiteLocalFirstSyncResult: Codable, Equatable, Sendable {
    public var upload: SQLiteSyncUploadResult
    public var download: SQLiteSyncDownloadResult
    public var syncedAt: Date

    public init(upload: SQLiteSyncUploadResult, download: SQLiteSyncDownloadResult, syncedAt: Date) {
        self.upload = upload
        self.download = download
        self.syncedAt = syncedAt
    }
}

public final class SQLiteLocalFirstSyncCoordinator {
    private let uploadCoordinator: SQLiteSyncUploadCoordinator
    private let downloadCoordinator: SQLiteSyncDownloadCoordinator
    private let syncRepository: SQLiteSyncRepository

    public init(databaseURL: URL, transport: SyncRecordTransport) {
        uploadCoordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        downloadCoordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
    }

    public func sync(limit: Int = 100, now: Date = Date()) async throws -> SQLiteLocalFirstSyncResult {
        let upload = try await uploadCoordinator.uploadPending(limit: limit)
        let download = try await downloadCoordinator.downloadAndMerge(detectedAt: now)
        let result = SQLiteLocalFirstSyncResult(upload: upload, download: download, syncedAt: now)
        try saveMetadata(result)
        return result
    }

    private func saveMetadata(_ result: SQLiteLocalFirstSyncResult) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: "localFirst.sync.lastResult",
                value: try encoder.encode(result),
                updatedAt: result.syncedAt
            )
        )
    }
}

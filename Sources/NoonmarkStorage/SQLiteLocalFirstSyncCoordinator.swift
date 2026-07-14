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
    private let syncRepository: SQLiteSyncRepository

    public init(databaseURL: URL, transport: SyncRecordTransport) {
        uploadCoordinator = SQLiteSyncUploadCoordinator(databaseURL: databaseURL, transport: transport)
        downloadCoordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
    }

    public func sync(limit: Int = 100, now: Date = Date()) async throws -> SQLiteLocalFirstSyncResult {
        do {
            let upload = try await uploadCoordinator.uploadPending(limit: limit)
            let download = try await downloadCoordinator.downloadAndMerge(detectedAt: now)
            let result = SQLiteLocalFirstSyncResult(upload: upload, download: download, syncedAt: now)
            try saveMetadata(.succeeded(result))
            return result
        } catch {
            try? saveMetadata(
                .failed(message: error.localizedDescription, failedAt: now)
            )
            throw error
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

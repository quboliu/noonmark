import Foundation
import NoonmarkSync

public actor SQLiteCloudKitSyncPersistence: CloudKitSyncPersistence {
    public static let metadataKey = "cloudkit.sync.persistence.v1"

    private let repository: SQLiteSyncRepository
    private let lease: CloudKitSyncPersistenceLease

    public init(
        databaseURL: URL,
        lease: CloudKitSyncPersistenceLease = CloudKitSyncPersistenceLease()
    ) {
        repository = SQLiteSyncRepository(databaseURL: databaseURL)
        self.lease = lease
    }

    public func load() async throws -> CloudKitSyncPersistenceSnapshot {
        try lease.withActiveAccess {
            guard let metadata = try repository.metadata(for: Self.metadataKey) else {
                return .empty
            }
            do {
                return try JSONDecoder().decode(
                    CloudKitSyncPersistenceSnapshot.self,
                    from: metadata.value
                )
            } catch {
                throw CloudKitSyncPersistenceError.invalidSnapshot
            }
        }
    }

    public func save(_ snapshot: CloudKitSyncPersistenceSnapshot) async throws {
        try lease.withActiveAccess {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try repository.saveMetadata(
                SyncMetadataEntry(
                    key: Self.metadataKey,
                    value: try encoder.encode(snapshot)
                )
            )
        }
    }
}

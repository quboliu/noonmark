@testable import NoonmarkStorage
@testable import NoonmarkSync
import XCTest

final class SQLiteCloudKitSyncPersistenceTests: XCTestCase {
    func testEmptyDatabaseReturnsAnEmptyCloudKitPersistenceSnapshot() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }

        let snapshot = try await SQLiteCloudKitSyncPersistence(
            databaseURL: databaseURL
        ).load()

        XCTAssertEqual(snapshot, .empty)
    }

    func testCloudKitStateAccountAndMirrorRoundTripThroughSQLiteMetadata() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let persistence = SQLiteCloudKitSyncPersistence(databaseURL: databaseURL)
        let scope = CloudKitSyncScopeIdentity(
            containerIdentifier: "iCloud.app.noonmark.mac",
            zoneName: "NoonmarkUserDataV1",
            environment: .development
        )
        let snapshot = try CloudKitSyncPersistenceSnapshot(
            scope: scope,
            engineState: Data([0x01, 0x02, 0x03]),
            accountRecordName: "cloudkit-user-a",
            records: [
                CloudKitMirroredSyncRecord(
                    record: makeRecord(id: "trace:two", seconds: 2),
                    serverRecordSystemFields: Data([0x20])
                ),
                CloudKitMirroredSyncRecord(
                    record: makeRecord(id: "trace:one", seconds: 1),
                    serverRecordSystemFields: Data([0x10])
                )
            ]
        )

        try await persistence.save(snapshot)
        let restored = try await persistence.load()

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(
            restored.records.map(\.record.id.rawValue),
            ["trace:one", "trace:two"]
        )
    }

    func testCorruptedCloudKitPersistenceFailsClosed() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        try SQLiteSyncRepository(databaseURL: databaseURL).saveMetadata(
            SyncMetadataEntry(
                key: SQLiteCloudKitSyncPersistence.metadataKey,
                value: Data("not-json".utf8)
            )
        )

        do {
            _ = try await SQLiteCloudKitSyncPersistence(
                databaseURL: databaseURL
            ).load()
            XCTFail("corrupted CloudKit persistence must not be treated as empty")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .invalidSnapshot
            )
        }
    }

    func testSnapshotRejectsDuplicateRecordIdentity() {
        let first = CloudKitMirroredSyncRecord(
            record: makeRecord(id: "trace:duplicate", seconds: 1),
            serverRecordSystemFields: nil
        )
        let second = CloudKitMirroredSyncRecord(
            record: makeRecord(id: "trace:duplicate", seconds: 2),
            serverRecordSystemFields: nil
        )

        XCTAssertThrowsError(
            try CloudKitSyncPersistenceSnapshot(records: [first, second])
        ) { error in
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .duplicateRecordID(SyncRecordID("trace:duplicate"))
            )
        }
    }

    func testSnapshotRejectsAGapInDurableCloudKitInbox() {
        XCTAssertThrowsError(
            try CloudKitSyncPersistenceSnapshot(
                nextInboxSequence: 4,
                inbox: [
                    CloudKitSyncInboxEntry(
                        sequence: 1,
                        record: makeRecord(
                            id: "trace:first",
                            seconds: 1
                        )
                    ),
                    CloudKitSyncInboxEntry(
                        sequence: 3,
                        record: makeRecord(
                            id: "trace:third",
                            seconds: 3
                        )
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .invalidSnapshot
            )
        }
    }

    func testInvalidatedLeaseBlocksAnOldTransportFromReadingOrWriting() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let lease = CloudKitSyncPersistenceLease()
        let persistence = SQLiteCloudKitSyncPersistence(
            databaseURL: databaseURL,
            lease: lease
        )
        let original = try CloudKitSyncPersistenceSnapshot(
            scope: CloudKitSyncScopeIdentity(
                containerIdentifier: "iCloud.app.noonmark.mac",
                zoneName: "NoonmarkUserDataV1",
                environment: .development
            )
        )
        try await persistence.save(original)
        lease.invalidate()

        do {
            _ = try await persistence.load()
            XCTFail("an invalidated CloudKit persistence lease must reject reads")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .inactiveLease
            )
        }
        do {
            try await persistence.save(.empty)
            XCTFail("an invalidated CloudKit persistence lease must reject writes")
        } catch {
            XCTAssertEqual(
                error as? CloudKitSyncPersistenceError,
                .inactiveLease
            )
        }

        let stored = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL).metadata(
                for: SQLiteCloudKitSyncPersistence.metadataKey
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                CloudKitSyncPersistenceSnapshot.self,
                from: stored.value
            ),
            original
        )
    }

    private func makeRecord(id: String, seconds: TimeInterval) -> SyncRecord {
        SyncRecord(
            id: SyncRecordID(id),
            entityType: .dayTrace,
            entityID: id,
            modifiedAt: Date(timeIntervalSinceReferenceDate: seconds),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data(id.utf8)
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-cloudkit-persistence-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix)
            )
        }
    }
}

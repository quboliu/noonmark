@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class CloudKitSyncMirrorTests: XCTestCase {
    func testOlderServerRecordKeepsLocalWinnerAndRequestsReupload() throws {
        let local = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-local"
        )
        let server = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-server"
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([local])

        let result = try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: server,
                serverRecordSystemFields: Data([0x11])
            )
        ])

        XCTAssertEqual(result.recordIDsNeedingUpload, [local.id])
        XCTAssertEqual(mirror.records, [local])
        XCTAssertEqual(
            mirror.mirroredRecord(for: local.id)?.serverRecordSystemFields,
            Data([0x11])
        )
    }

    func testNewerServerRecordBecomesCanonicalWithoutReupload() throws {
        let local = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-local"
        )
        let server = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-server"
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([local])

        let result = try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: server,
                serverRecordSystemFields: Data([0x22])
            )
        ])

        XCTAssertTrue(result.recordIDsNeedingUpload.isEmpty)
        XCTAssertEqual(mirror.records, [server])
    }

    func testLocalMergePreservesLastKnownServerSystemFields() throws {
        let first = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "mac-a"
        )
        let second = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "mac-a"
        )
        let snapshot = try CloudKitSyncPersistenceSnapshot(
            records: [
                CloudKitMirroredSyncRecord(
                    record: first,
                    serverRecordSystemFields: Data([0x33])
                )
            ]
        )
        var mirror = try CloudKitSyncMirror(snapshot: snapshot)

        let result = try mirror.mergeLocal([second])

        XCTAssertEqual(result.recordIDsNeedingUpload, [second.id])
        XCTAssertEqual(mirror.records, [second])
        XCTAssertEqual(
            mirror.mirroredRecord(for: second.id)?.serverRecordSystemFields,
            Data([0x33])
        )
    }

    func testImmutableIdentityCollisionFailsClosed() throws {
        let id = SyncRecordID("classification-commit:one")
        let first = SyncRecord(
            id: id,
            entityType: .classificationCommit,
            entityID: "one",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data("first".utf8)
        )
        let second = SyncRecord(
            id: id,
            entityType: .classificationCommit,
            entityID: "one",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data("second".utf8)
        )
        var mirror = try CloudKitSyncMirror(snapshot: .empty)
        _ = try mirror.mergeLocal([first])

        XCTAssertThrowsError(try mirror.mergeServer([
            CloudKitMirroredSyncRecord(
                record: second,
                serverRecordSystemFields: Data([0x44])
            )
        ])) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: id)
            )
        }
    }

    private func preferenceRecord(
        theme: AppTheme,
        modifiedAt: Date,
        deviceID: String
    ) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: theme,
                language: .chinese,
                updatedAt: modifiedAt
            ),
            modifiedBy: SyncDeviceID(deviceID)
        )
    }
}

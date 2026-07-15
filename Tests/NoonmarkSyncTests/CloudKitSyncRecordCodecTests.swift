import CloudKit
import CryptoKit
@testable import NoonmarkSync
import XCTest

final class CloudKitSyncRecordCodecTests: XCTestCase {
    private let zoneID = CKRecordZone.ID(
        zoneName: "NoonmarkUserDataV1",
        ownerName: CKCurrentUserDefaultName
    )

    func testRecordRoundTripPreservesCanonicalSyncRecordAndStableIdentity() throws {
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let syncRecord = makeSyncRecord()

        let cloudRecord = try codec.encode(syncRecord)
        let restored = try codec.decode(cloudRecord)

        XCTAssertEqual(cloudRecord.recordType, "NoonmarkSyncRecordV1")
        XCTAssertEqual(cloudRecord.recordID, codec.recordID(for: syncRecord.id))
        XCTAssertEqual(
            Set(cloudRecord.allKeys()),
            ["formatVersion", "syncRecordID", "wirePayload", "wireSHA256"]
        )
        XCTAssertEqual(restored, syncRecord)
        XCTAssertEqual(
            restored.modifiedAt.timeIntervalSinceReferenceDate.bitPattern,
            syncRecord.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
        )
    }

    func testRecordNameIsSafeStableAndDistinct() {
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)

        let first = codec.recordID(for: SyncRecordID("trace:unsafe/name?one"))
        let same = codec.recordID(for: SyncRecordID("trace:unsafe/name?one"))
        let other = codec.recordID(for: SyncRecordID("trace:unsafe/name?two"))

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.recordName.hasPrefix("sync-"))
        XCTAssertEqual(first.recordName.count, 69)
        XCTAssertEqual(first.zoneID, zoneID)
    }

    func testDecodeRejectsWirePayloadTampering() throws {
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let cloudRecord = try codec.encode(makeSyncRecord())
        var wirePayload = try XCTUnwrap(cloudRecord["wirePayload"] as? Data)
        wirePayload[wirePayload.startIndex] ^= 0x01
        cloudRecord["wirePayload"] = wirePayload as CKRecordValue

        XCTAssertThrowsError(try codec.decode(cloudRecord)) { error in
            XCTAssertEqual(error as? CloudKitSyncRecordCodecError, .digestMismatch)
        }
    }

    func testDecodeRejectsNoncanonicalWireBytesWithMatchingDigest() throws {
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let cloudRecord = try codec.encode(makeSyncRecord())
        let canonical = try XCTUnwrap(cloudRecord["wirePayload"] as? Data)
        let object = try JSONSerialization.jsonObject(with: canonical)
        let noncanonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        cloudRecord["wirePayload"] = noncanonical as CKRecordValue
        cloudRecord["wireSHA256"] = sha256(noncanonical) as CKRecordValue

        XCTAssertThrowsError(try codec.decode(cloudRecord)) { error in
            XCTAssertEqual(error as? CloudKitSyncRecordCodecError, .noncanonicalWirePayload)
        }
    }

    func testDecodeRejectsUnexpectedRecordTypeAndZone() throws {
        let codec = CloudKitSyncRecordCodec(zoneID: zoneID)
        let wrongType = CKRecord(
            recordType: "OtherRecord",
            recordID: codec.recordID(for: SyncRecordID("trace:one"))
        )
        let wrongZone = CKRecord(
            recordType: "NoonmarkSyncRecordV1",
            recordID: CKRecord.ID(
                recordName: "sync-wrong-zone",
                zoneID: CKRecordZone.ID(zoneName: "OtherZone")
            )
        )

        XCTAssertThrowsError(try codec.decode(wrongType)) { error in
            XCTAssertEqual(error as? CloudKitSyncRecordCodecError, .unexpectedRecordType)
        }
        XCTAssertThrowsError(try codec.decode(wrongZone)) { error in
            XCTAssertEqual(error as? CloudKitSyncRecordCodecError, .unexpectedRecordZone)
        }
    }

    func testAccountStatusMappingIsExplicitAndFailClosed() {
        XCTAssertEqual(CloudKitAccountAvailability(.available), .available)
        XCTAssertEqual(CloudKitAccountAvailability(.noAccount), .noAccount)
        XCTAssertEqual(CloudKitAccountAvailability(.restricted), .restricted)
        XCTAssertEqual(
            CloudKitAccountAvailability(.temporarilyUnavailable),
            .temporarilyUnavailable
        )
        XCTAssertEqual(
            CloudKitAccountAvailability(.couldNotDetermine),
            .couldNotDetermine
        )
        XCTAssertTrue(CloudKitAccountAvailability.available.canSync)
        XCTAssertFalse(CloudKitAccountAvailability.couldNotDetermine.canSync)
    }

    private func makeSyncRecord() -> SyncRecord {
        SyncRecord(
            id: SyncRecordID("trace:unsafe/name?one"),
            entityType: .dayTrace,
            entityID: "12000000-0000-0000-0000-000000000001",
            modifiedAt: Date(
                timeIntervalSinceReferenceDate: 812_345_678.123_456_7
            ),
            modifiedByDeviceID: SyncDeviceID("mac-a"),
            payload: Data("canonical-domain-payload".utf8)
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

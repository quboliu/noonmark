import Foundation
@testable import NoonmarkSync
import XCTest

final class SyncConflictTests: XCTestCase {
    func testCanonicalEvidenceProducesStableConflictIdentity() {
        let record = SyncRecord(
            id: SyncRecordID("trace:stable-conflict"),
            entityType: .dayTrace,
            entityID: "stable-conflict",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 42.125),
            modifiedByDeviceID: SyncDeviceID("remote-device"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )
        let first = SyncConflict(
            type: .historicalTraceMutation,
            entityType: record.entityType,
            entityID: record.entityID,
            localRecordID: SyncRecordID("trace:local-version"),
            remoteRecord: record,
            detectedAt: Date(timeIntervalSince1970: 100),
            message: "first observation"
        )
        let repeated = SyncConflict(
            type: .historicalTraceMutation,
            entityType: record.entityType,
            entityID: record.entityID,
            localRecordID: SyncRecordID("trace:local-version"),
            remoteRecord: record,
            detectedAt: Date(timeIntervalSince1970: 200),
            message: "same evidence observed again"
        )

        XCTAssertEqual(first.id, repeated.id)
    }

    func testCanonicalEvidenceDistinguishesReactivationWitnesses() {
        let commonID = SyncRecordID("chain:witness-conflict")
        let commonClock = Date(timeIntervalSinceReferenceDate: 42.125)
        let firstRecord = SyncRecord(
            id: commonID,
            entityType: .taskChain,
            entityID: "witness-conflict",
            modifiedAt: commonClock,
            modifiedByDeviceID: SyncDeviceID("remote-device"),
            payload: Data([0x01, 0x02]),
            reactivationWitnesses: [Data([0xAA])]
        )
        let secondRecord = SyncRecord(
            id: commonID,
            entityType: .taskChain,
            entityID: "witness-conflict",
            modifiedAt: commonClock,
            modifiedByDeviceID: SyncDeviceID("remote-device"),
            payload: Data([0x01, 0x02]),
            reactivationWitnesses: [Data([0xBB])]
        )

        let first = SyncConflict(
            type: .invalidRecordPayload,
            entityType: .taskChain,
            entityID: "witness-conflict",
            remoteRecord: firstRecord,
            message: "first witness"
        )
        let second = SyncConflict(
            type: .invalidRecordPayload,
            entityType: .taskChain,
            entityID: "witness-conflict",
            remoteRecord: secondRecord,
            message: "second witness"
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.canonicalEvidenceID, second.canonicalEvidenceID)
    }
}

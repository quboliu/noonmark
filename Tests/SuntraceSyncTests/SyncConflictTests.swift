import Foundation
@testable import SuntraceSync
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
}

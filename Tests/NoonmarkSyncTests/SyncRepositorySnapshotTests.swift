@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRepositorySnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSnapshotDigestIsStableForRecordSetOrdering() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同步快照", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "生成 snapshot index", difficulty: .medium, now: now)

        let records = try SyncRecordMapper().records(from: engine.snapshot(), modifiedBy: SyncDeviceID("mac-a"))
        let builder = SyncRepositorySnapshotBuilder()
        let first = try builder.snapshot(records: records, createdAt: now, deviceID: SyncDeviceID("mac-a"))
        let second = try builder.snapshot(records: records.reversed(), createdAt: now, deviceID: SyncDeviceID("mac-a"))

        XCTAssertEqual(first.payloadDigest, second.payloadDigest)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.recordIDs, second.recordIDs)
        XCTAssertEqual(first.recordCount, records.count)
        XCTAssertEqual(first.memo, "[Sync] Cloud sync")
    }

    func testSnapshotRoundTripPreservesExactCreatedAtAndReconstructsIdentity() throws {
        let exactCreatedAt = Date(
            timeIntervalSinceReferenceDate: Double(
                bitPattern: 0x41C8_3456_789A_BCDE
            )
        )
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: exactCreatedAt
            ),
            modifiedBy: SyncDeviceID("mac-exact-snapshot")
        )
        let snapshot = try SyncRepositorySnapshotBuilder().snapshot(
            records: [record],
            createdAt: exactCreatedAt,
            deviceID: SyncDeviceID("mac-exact-snapshot")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            SyncRepositorySnapshot.self,
            from: encoder.encode(snapshot)
        )
        let reconstructed = try SyncRepositorySnapshotBuilder().snapshot(
            records: [record],
            memo: restored.memo,
            createdAt: restored.createdAt,
            deviceID: restored.deviceID
        )

        XCTAssertEqual(
            restored.createdAt.timeIntervalSinceReferenceDate.bitPattern,
            exactCreatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(restored.id, reconstructed.id)
        XCTAssertEqual(restored.payloadDigest, reconstructed.payloadDigest)
    }

    func testSnapshotBuilderRejectsNonfiniteCreatedAt() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(
                try SyncRepositorySnapshotBuilder().snapshot(
                    records: [],
                    createdAt: Date(
                        timeIntervalSinceReferenceDate: seconds
                    ),
                    deviceID: SyncDeviceID("mac-invalid-snapshot")
                )
            ) { error in
                XCTAssertEqual(
                    error as? SyncRepositorySnapshotError,
                    .invalidCreatedAt
                )
            }
        }
    }
}

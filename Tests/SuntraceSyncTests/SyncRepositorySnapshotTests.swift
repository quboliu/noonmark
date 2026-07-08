@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncRepositorySnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSnapshotDigestIsStableForRecordSetOrdering() throws {
        let engine = SuntraceEngine()
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
}

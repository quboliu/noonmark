@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncRecordMaterializerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testMaterializesJournalEntryFromCurrentSnapshot() throws {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "生成上传记录", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let entry = SyncJournalEntry(
            entityType: .dayTrace,
            entityID: traceID.rawValue.uuidString,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        let record = try SyncRecordMaterializer().record(for: entry, in: engine.snapshot())

        XCTAssertEqual(record.id.rawValue, "trace:\(traceID.rawValue.uuidString)")
        XCTAssertEqual(record.entityType, .dayTrace)
        XCTAssertEqual(record.modifiedByDeviceID, SyncDeviceID("mac-a"))
    }

    func testMissingEntityFailsClosed() {
        let entry = SyncJournalEntry(
            entityType: .subtask,
            entityID: UUID().uuidString,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: SuntraceEngine().snapshot())) { error in
            XCTAssertEqual(error as? SyncRecordMaterializerError, .missingEntity(.subtask, entry.entityID))
        }
    }

    func testDeleteOperationFailsClosedUntilTombstonesExist() {
        let entry = SyncJournalEntry(
            entityType: .day,
            entityID: today.description,
            operation: .delete,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertThrowsError(try SyncRecordMaterializer().record(for: entry, in: SuntraceEngine().snapshot())) { error in
            XCTAssertEqual(error as? SyncRecordMaterializerError, .unsupportedDelete(.day, today.description))
        }
    }
}

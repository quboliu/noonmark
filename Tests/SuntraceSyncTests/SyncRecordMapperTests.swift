@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class SyncRecordMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSnapshotRecordsRoundTripThroughGenericPayloads() throws {
        let engine = try makeEngine()
        let mapper = SyncRecordMapper()
        let deviceID = SyncDeviceID("mac-a")

        let records = try mapper.records(from: engine.snapshot(), modifiedBy: deviceID, preferencesUpdatedAt: now)

        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("day:") && $0.entityType == .day })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("chain:") && $0.entityType == .taskChain })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("definition:") && $0.entityType == .taskDefinition })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("trace:") && $0.entityType == .dayTrace })
        XCTAssertTrue(records.contains { $0.id.rawValue.hasPrefix("subtask:") && $0.entityType == .subtask })
        XCTAssertTrue(records.contains { $0.id.rawValue == "preferences:default" && $0.entityType == .appPreferences })
        XCTAssertTrue(records.allSatisfy { $0.modifiedByDeviceID == deviceID })

        let traceRecord = try XCTUnwrap(records.first { $0.entityType == .dayTrace })
        let decodedTrace = try mapper.decodeDayTrace(traceRecord)

        XCTAssertEqual(decodedTrace, try XCTUnwrap(engine.snapshot().traces.first))
    }

    func testDecodeRejectsMismatchedEntityType() throws {
        let engine = try makeEngine()
        let mapper = SyncRecordMapper()
        let dayRecord = try XCTUnwrap(try mapper.records(from: engine.snapshot(), modifiedBy: SyncDeviceID("mac-a")).first { $0.entityType == .day })

        XCTAssertThrowsError(try mapper.decodeDayTrace(dayRecord)) { error in
            XCTAssertEqual(
                error as? SyncRecordMapperError,
                .entityTypeMismatch(expected: .dayTrace, actual: .day)
            )
        }
    }

    private func makeEngine() throws -> SuntraceEngine {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "同步 mapper 测试", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "生成同步记录", difficulty: .medium, now: now)
        engine.updateDailyReview(date: today, summary: "完成同步记录 round-trip。", unfinishedReason: nil, tomorrowNote: nil, now: now)
        return engine
    }
}

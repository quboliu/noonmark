import SuntraceCore
@testable import SuntraceStorage
import XCTest

final class DataPackageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testJSONDataPackageRoundTripsSnapshot() throws {
        let engine = try makeEngine()

        let data = try SuntraceDataPackage.encode(engine.snapshot())
        let restored = try SuntraceEngine(snapshot: SuntraceDataPackage.decode(data))

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
    }

    func testJSONDataPackageRejectsDuplicateKeys() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        snapshot.days.append(try XCTUnwrap(snapshot.days.first))

        XCTAssertThrowsError(try SuntraceDataPackage.encode(snapshot)) { error in
            XCTAssertEqual(error as? DataPackageError, .duplicateField("days.date"))
        }
    }

    func testJSONDataPackageRejectsBrokenReferencesOnImport() throws {
        let engine = try makeEngine()
        var snapshot = engine.snapshot()
        snapshot.chains.removeAll()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        XCTAssertThrowsError(try SuntraceDataPackage.decode(data)) { error in
            XCTAssertEqual(error as? DataPackageError, .missingReference("definition references missing chain"))
        }
    }

    func testLegacyPreferencesDecodeWithDefaultDataModeAndBackupPolicy() throws {
        let json = """
        {
          "days": [],
          "chains": [],
          "definitions": [],
          "traces": [],
          "subtasks": [],
          "preferences": {
            "theme": "warmPaper",
            "language": "english",
            "syncEndpointOptions": []
          }
        }
        """

        let snapshot = try SuntraceDataPackage.decode(Data(json.utf8))

        XCTAssertEqual(snapshot.preferences.theme, .warmPaper)
        XCTAssertEqual(snapshot.preferences.language, .english)
        XCTAssertEqual(snapshot.preferences.dataMode, .localFirst)
        XCTAssertEqual(snapshot.preferences.backupPolicy, ScheduledBackupPolicy())
        XCTAssertEqual(snapshot.preferences.localFirstSyncPolicy, LocalFirstCloudSyncPolicy())
    }

    private func makeEngine() throws -> SuntraceEngine {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(
            title: "数据包测试",
            descriptionText: "用于导出导入测试。",
            note: "必须保留引用完整性。",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "写 JSON 测试", difficulty: .hard, now: now)
        engine.updateDailyReview(
            date: today,
            summary: "数据包 round-trip。",
            unfinishedReason: "无。",
            tomorrowNote: "继续验证导入。",
            now: now
        )
        return engine
    }
}

import SuntraceCore
@testable import SuntraceStorage
import XCTest

final class SQLiteSchemaTests: XCTestCase {
    func testSchemaContainsPrototypeBackedStorageObjects() {
        let schema = SQLiteSchema.statements.joined(separator: "\n")

        XCTAssertEqual(SQLiteSchema.version, 3)
        XCTAssertTrue(schema.contains("id TEXT NOT NULL"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS app_preferences"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS completed_subtask_record_view"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS sync_endpoint_options_view"))
        XCTAssertTrue(schema.contains("t.status != 'returnedToPool'"))
    }

    func testSQLiteRepositoryRoundTripsCoreEngineState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = LocalDate("2026-07-05")
        let day2 = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-storage-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(
            title: "持久化核心状态",
            descriptionText: "保存并恢复 Day Todo、子任务和复盘。",
            note: "稳定 ID 必须保留。",
            now: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "写 round-trip 测试", difficulty: .hard, now: now)
        try engine.completeSubtask(subtaskID, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)
        _ = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)

        let completedChainID = try engine.createPoolTask(title: "完成存储 schema", now: now)
        let completedTraceID = try engine.scheduleFromPool(chainID: completedChainID, date: day2, today: day2, now: now)
        try engine.markCompleted(traceID: completedTraceID, today: day2, now: now)
        let changedChainID = try engine.createPoolTask(title: "写旧版任务标题", now: now)
        let changedTraceID = try engine.scheduleFromPool(chainID: changedChainID, date: day2, today: day2, now: now)
        _ = try engine.changeTrace(traceID: changedTraceID, newTitle: "写新版任务标题", today: day2, now: now)
        engine.updateDailyReview(
            date: day1,
            summary: "已完成 schema 与 repository 第一版。",
            unfinishedReason: "还需要接入真实 app 生命周期。",
            tomorrowNote: "验证保存后读回。",
            now: now
        )
        engine.updateTheme(.warmPaper)
        engine.updateLanguage(.english)

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        let restored = try repository.load()

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
        XCTAssertEqual(restored.taskPool().count, 0)
        XCTAssertEqual(restored.unfinishedPool().count, 1)
        XCTAssertEqual(restored.completedPool().count, 1)
        XCTAssertEqual(restored.getDayTodo(date: day2).traces.count, 4)
        XCTAssertEqual(restored.engineReviewSummary(for: day1), "已完成 schema 与 repository 第一版。")
        XCTAssertEqual(restored.preferences.theme, .warmPaper)
        XCTAssertEqual(restored.preferences.language, .english)
    }
}

private extension SuntraceEngine {
    func engineReviewSummary(for date: LocalDate) -> String? {
        days[date]?.reviewSummary
    }
}

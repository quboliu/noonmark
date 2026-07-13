import NoonmarkCore
@testable import NoonmarkStorage
import XCTest

final class SQLiteSchemaTests: XCTestCase {
    func testSchemaDeclaresOnlyTheCurrentGenerationStorageContract() {
        let schema = SQLiteSchema.statements.joined(separator: "\n")

        XCTAssertEqual(SQLiteSchema.version, 1)
        XCTAssertTrue(schema.contains("id TEXT NOT NULL"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS app_preferences"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_canonical_name_ownership"))
        XCTAssertTrue(schema.contains("CREATE UNIQUE INDEX IF NOT EXISTS idx_classification_item_metadata_key"))
        XCTAssertTrue(schema.contains("CREATE TRIGGER IF NOT EXISTS claim_classification_canonical_name_owner"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_current_relation_facts"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_relation_history"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_merges"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_deletion_tombstones"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_change_record_plan_digests"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_change_record_integrity_digests"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_change_record_notice_records"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_change_record_finalizations"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_commit_receipt_integrity_digests"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS classification_commit_finalizations"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS trace_classification_snapshot_events"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS trace_classification_snapshot_event_finalizations"))
        XCTAssertTrue(schema.contains("planned_subtasks_json TEXT"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_device_identity"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_metadata"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS change_journal"))
        XCTAssertTrue(schema.contains("record_payload BLOB"))
        XCTAssertTrue(schema.contains(
            "changed_at_bits INTEGER NOT NULL CHECK (typeof(changed_at_bits) = 'integer')"
        ))
        XCTAssertTrue(schema.contains(
            "entity_type IN ('classificationCommit', 'traceClassificationEvent')"
        ))
        XCTAssertTrue(schema.contains("record_payload IS NOT NULL"))
        XCTAssertTrue(schema.contains(
            "entity_type NOT IN ('classificationCommit', 'traceClassificationEvent')"
        ))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_records"))
        XCTAssertTrue(
            schema.contains(
                "generation_id TEXT NOT NULL UNIQUE CHECK (length(generation_id) = 36)"
            )
        )
        XCTAssertTrue(schema.contains(
            "entity_type IN ('classificationCommit', 'traceClassificationEvent')"
        ))
        XCTAssertTrue(schema.contains("operation TEXT NOT NULL CHECK (operation = 'upsert')"))
        XCTAssertTrue(schema.contains("modified_at_bits INTEGER NOT NULL CHECK (typeof(modified_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("length(CAST(modified_by_device_id AS BLOB)) > 0"))
        XCTAssertTrue(schema.contains("payload BLOB NOT NULL CHECK (length(payload) > 0)"))
        XCTAssertTrue(schema.contains("first_seen_at_bits INTEGER NOT NULL CHECK (typeof(first_seen_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("last_attempted_at_bits INTEGER NOT NULL CHECK (typeof(last_attempted_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("attempt_count INTEGER NOT NULL CHECK ("))
        XCTAssertTrue(schema.contains("typeof(attempt_count) = 'integer'"))
        XCTAssertTrue(schema.contains("attempt_count BETWEEN 1 AND 2147483647"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_dependencies"))
        XCTAssertTrue(schema.contains("REFERENCES sync_pending_download_records(record_id)"))
        XCTAssertTrue(schema.contains("ON DELETE CASCADE"))
        XCTAssertTrue(schema.contains("'taskChain', 'dayTrace', 'category', 'label'"))
        XCTAssertTrue(schema.contains(
            "'classificationEvent', 'classificationCommit',"
        ))
        XCTAssertTrue(schema.contains("'classificationRevision'"))
        XCTAssertTrue(schema.contains("PRIMARY KEY(record_id, dependency_kind, dependency_id)"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_conflicts"))
        XCTAssertTrue(schema.contains(
            "remote_payload BLOB NOT NULL CHECK (length(remote_payload) > 0)"
        ))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_audit_log"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS completed_subtask_record_view"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS sync_endpoint_options_view"))
        XCTAssertTrue(schema.contains("t.status != 'returnedToPool'"))
    }

    func testSQLiteRepositoryRoundTripsCoreEngineState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day1 = LocalDate("2026-07-05")
        let day2 = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-storage-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "持久化核心状态",
            descriptionText: "保存并恢复 Day Todo、子任务和复盘。",
            note: "稳定 ID 必须保留。",
            now: now
        )
        _ = try engine.addPlannedSubtask(chainID: chainID, title: "先规划子任务", difficulty: .medium, now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "写 round-trip 测试", difficulty: .hard, now: now)
        try engine.completeSubtask(subtaskID, today: day1, now: now)
        engine.settleDays(upTo: day2, now: now)
        _ = try engine.continueTrace(traceID: traceID, targetDate: day2, today: day2, now: now)

        let completedChainID = try engine.createPoolTask(title: "完成存储 schema", now: now)
        let completedTraceID = try engine.scheduleFromPool(chainID: completedChainID, date: day2, today: day2, now: now)
        try engine.markCompleted(traceID: completedTraceID, today: day2, now: now)
        let changedChainID = try engine.createPoolTask(title: "写初始任务标题", now: now)
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
        engine.updateDataMode(.onlineFirst)
        engine.updateBackupPolicy(ScheduledBackupPolicy(frequency: .weekly, destination: .s3))
        engine.updateLocalFirstSyncPolicy(
            LocalFirstCloudSyncPolicy(
                endpoint: .webDAV,
                mode: .automatic,
                intervalSeconds: 120,
                generateConflictCopy: true,
                snapshotRetention: SyncSnapshotRetentionPolicy(indexRetentionDays: 120, retentionIndexesDaily: 4)
            )
        )

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
        XCTAssertEqual(restored.preferences.dataMode, .onlineFirst)
        XCTAssertEqual(restored.preferences.backupPolicy.frequency, .weekly)
        XCTAssertEqual(restored.preferences.backupPolicy.destination, .s3)
        XCTAssertEqual(restored.preferences.localFirstSyncPolicy.endpoint, .webDAV)
        XCTAssertEqual(restored.preferences.localFirstSyncPolicy.mode, .automatic)
        XCTAssertEqual(restored.preferences.localFirstSyncPolicy.intervalSeconds, 120)
        XCTAssertEqual(restored.preferences.localFirstSyncPolicy.snapshotRetention.retentionIndexesDaily, 4)
    }
}

private extension NoonmarkEngine {
    func engineReviewSummary(for date: LocalDate) -> String? {
        days[date]?.reviewSummary
    }
}

import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import SQLite3
import XCTest

final class SQLiteSchemaTests: XCTestCase {
    func testSchemaDeclaresOnlyTheCurrentGenerationStorageContract() throws {
        let schema = SQLiteSchema.statements.joined(separator: "\n")
        let taskChainTable = try XCTUnwrap(
            SQLiteSchema.statements.first { $0.contains("CREATE TABLE IF NOT EXISTS task_chains") }
        )
        let taskCycleSeriesTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains("CREATE TABLE IF NOT EXISTS task_cycle_series")
            }
        )
        let dayTable = try XCTUnwrap(
            SQLiteSchema.statements.first { $0.contains("CREATE TABLE IF NOT EXISTS days") }
        )
        let taskDefinitionTable = try XCTUnwrap(
            SQLiteSchema.statements.first { $0.contains("CREATE TABLE IF NOT EXISTS task_definitions") }
        )
        let dayTraceTable = try XCTUnwrap(
            SQLiteSchema.statements.first { $0.contains("CREATE TABLE IF NOT EXISTS day_traces") }
        )
        let subtaskTable = try XCTUnwrap(
            SQLiteSchema.statements.first { $0.contains("CREATE TABLE IF NOT EXISTS subtasks") }
        )
        let changeJournalTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains("CREATE TABLE IF NOT EXISTS change_journal")
            }
        )
        let pendingDownloadTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_records")
            }
        )
        let pendingDependencyTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_dependencies")
            }
        )
        let automaticClassificationJobTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains("CREATE TABLE IF NOT EXISTS automatic_classification_jobs")
            }
        )
        let automaticClassificationProviderCircuitTable = try XCTUnwrap(
            SQLiteSchema.statements.first {
                $0.contains(
                    "CREATE TABLE IF NOT EXISTS automatic_classification_provider_circuit"
                )
            }
        )
        let compactChangeJournalTable = changeJournalTable
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let compactPendingDownloadTable = pendingDownloadTable
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let compactPendingDependencyTable = pendingDependencyTable
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        XCTAssertEqual(SQLiteSchema.version, 15)
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
        XCTAssertTrue(taskChainTable.contains("note_entries_json TEXT NOT NULL"))
        XCTAssertTrue(taskCycleSeriesTable.contains("cancellation_facts_json TEXT NOT NULL"))
        XCTAssertTrue(taskCycleSeriesTable.contains("end_condition_json TEXT NOT NULL"))
        XCTAssertTrue(taskCycleSeriesTable.contains("plan_revisions_json TEXT NOT NULL"))
        XCTAssertTrue(taskCycleSeriesTable.contains("planned_subtasks_json TEXT NOT NULL"))
        XCTAssertTrue(taskCycleSeriesTable.contains("category_id TEXT"))
        XCTAssertTrue(taskCycleSeriesTable.contains("label_ids_json TEXT NOT NULL"))
        XCTAssertTrue(
            taskCycleSeriesTable.contains(
                "classification_revisions_json TEXT NOT NULL"
            )
        )
        XCTAssertTrue(taskChainTable.contains("cycle_membership_json TEXT"))
        XCTAssertFalse(
            taskDefinitionTable.contains("CHECK (length(trim(title)) > 0)")
        )
        XCTAssertTrue(
            subtaskTable.contains("CHECK (length(trim(title)) > 0)")
        )
        XCTAssertTrue(taskChainTable.contains("json_type(note_entries_json) = 'array'"))
        XCTAssertTrue(taskChainTable.contains("state TEXT NOT NULL"))
        XCTAssertTrue(taskChainTable.contains("created_at TEXT NOT NULL"))
        XCTAssertTrue(taskChainTable.contains("created_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(taskChainTable.contains("updated_at TEXT NOT NULL"))
        XCTAssertTrue(taskChainTable.contains("updated_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(dayTable.contains("locked_at_bits INTEGER"))
        XCTAssertTrue(dayTable.contains("created_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(dayTable.contains("updated_at_bits INTEGER NOT NULL"))
        XCTAssertFalse(taskDefinitionTable.contains("note_entries_json"))
        XCTAssertTrue(taskDefinitionTable.contains("planned_subtasks_json TEXT"))
        XCTAssertTrue(taskDefinitionTable.contains("content_updated_at TEXT NOT NULL"))
        XCTAssertTrue(taskDefinitionTable.contains("created_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(taskDefinitionTable.contains("content_updated_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(taskDefinitionTable.contains("superseded_at_bits INTEGER"))
        XCTAssertTrue(dayTraceTable.contains("created_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(dayTraceTable.contains("content_updated_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(dayTraceTable.contains("completed_at_bits INTEGER"))
        XCTAssertTrue(dayTraceTable.contains("settled_at_bits INTEGER"))
        XCTAssertTrue(dayTraceTable.contains("pin_order INTEGER"))
        XCTAssertTrue(subtaskTable.contains("created_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(subtaskTable.contains("updated_at TEXT NOT NULL"))
        XCTAssertTrue(subtaskTable.contains("updated_at_bits INTEGER NOT NULL"))
        XCTAssertTrue(subtaskTable.contains("completed_at_bits INTEGER"))
        XCTAssertTrue(subtaskTable.contains("settled_at_bits INTEGER"))
        XCTAssertTrue(subtaskTable.contains("status = 'pending'"))
        XCTAssertTrue(subtaskTable.contains("status = 'completed'"))
        XCTAssertTrue(subtaskTable.contains(
            "status IN ('unfinished', 'deferred', 'abandoned')"
        ))
        XCTAssertTrue(subtaskTable.contains("status = 'cancelledDraft'"))
        XCTAssertTrue(subtaskTable.contains("draft_cancellation_id TEXT"))
        XCTAssertTrue(dayTraceTable.contains("draft_cancellation_id TEXT"))
        XCTAssertTrue(dayTraceTable.contains("draft_cancelled_on TEXT"))
        XCTAssertTrue(schema.contains("CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_draft_cancellation_id"))
        XCTAssertTrue(schema.contains(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_unique_subtask_draft_cancellation_id"
        ))
        XCTAssertTrue(schema.contains("status = 'cancelledDraft'"))
        XCTAssertTrue(schema.contains("date >= draft_cancelled_on"))
        XCTAssertFalse(dayTraceTable.contains(
            "manual_progress_percent IS NULL"
                + "\n                            AND carried_from_trace_id IS NULL"
        ))
        XCTAssertTrue(schema.contains("chain_note_entries_json"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_device_identity"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_metadata"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS change_journal"))
        XCTAssertTrue(schema.contains("theme_language_writer_id TEXT NOT NULL"))
        XCTAssertTrue(schema.contains("record_payload BLOB"))
        XCTAssertTrue(schema.contains(
            "changed_at_bits INTEGER NOT NULL CHECK (typeof(changed_at_bits) = 'integer')"
        ))
        XCTAssertTrue(compactChangeJournalTable.contains(
            "entity_type IN ( 'appPreferences', 'classificationCommit', 'traceClassificationEvent' )"
        ))
        XCTAssertTrue(schema.contains("record_payload IS NOT NULL"))
        XCTAssertTrue(schema.contains("entity_type = 'taskChain'"))
        XCTAssertTrue(schema.contains("record_payload IS NULL OR length(record_payload) > 0"))
        XCTAssertTrue(compactChangeJournalTable.contains(
            "entity_type NOT IN ( 'appPreferences', 'classificationCommit', 'traceClassificationEvent', 'taskChain' )"
        ))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_records"))
        XCTAssertTrue(
            schema.contains(
                "generation_id TEXT NOT NULL UNIQUE CHECK (length(generation_id) = 36)"
            )
        )
        XCTAssertTrue(compactPendingDownloadTable.contains(
            "entity_type IN ( 'day', 'taskCycleSeries', 'taskChain', 'taskDefinition', 'dayTrace', 'subtask', 'appPreferences', 'classificationCommit', 'traceClassificationEvent' )"
        ))
        XCTAssertTrue(schema.contains("operation TEXT NOT NULL CHECK (operation = 'upsert')"))
        XCTAssertTrue(schema.contains("modified_at_bits INTEGER NOT NULL CHECK (typeof(modified_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("length(CAST(modified_by_device_id AS BLOB)) > 0"))
        XCTAssertTrue(schema.contains("payload BLOB NOT NULL CHECK (length(payload) > 0)"))
        XCTAssertTrue(pendingDownloadTable.contains(
            "reactivation_witnesses BLOB NOT NULL"
        ))
        XCTAssertTrue(schema.contains("first_seen_at_bits INTEGER NOT NULL CHECK (typeof(first_seen_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("last_attempted_at_bits INTEGER NOT NULL CHECK (typeof(last_attempted_at_bits) = 'integer')"))
        XCTAssertTrue(schema.contains("attempt_count INTEGER NOT NULL CHECK ("))
        XCTAssertTrue(schema.contains("typeof(attempt_count) = 'integer'"))
        XCTAssertTrue(schema.contains("attempt_count BETWEEN 1 AND 2147483647"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_pending_download_dependencies"))
        XCTAssertTrue(schema.contains("REFERENCES sync_pending_download_records(record_id)"))
        XCTAssertTrue(schema.contains("ON DELETE CASCADE"))
        XCTAssertTrue(compactPendingDependencyTable.contains(
            "'day', 'taskChain', 'dayTrace', 'taskDefinition', 'subtask', 'category', 'label', 'classificationEvent', 'classificationCommit', 'classificationRevision', 'currentSnapshotIntegrity'"
        ))
        XCTAssertTrue(schema.contains("PRIMARY KEY(record_id, dependency_kind, dependency_id)"))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_conflicts"))
        XCTAssertTrue(schema.contains(
            "remote_payload BLOB NOT NULL CHECK (length(remote_payload) > 0)"
        ))
        XCTAssertTrue(schema.contains("CREATE TABLE IF NOT EXISTS sync_audit_log"))
        XCTAssertTrue(automaticClassificationJobTable.contains("chain_id TEXT NOT NULL"))
        XCTAssertTrue(automaticClassificationJobTable.contains("content_digest TEXT NOT NULL"))
        XCTAssertTrue(automaticClassificationJobTable.contains(
            "classification_fingerprint TEXT NOT NULL"
        ))
        XCTAssertTrue(automaticClassificationJobTable.contains(
            "catalog_digest TEXT NOT NULL"
        ))
        XCTAssertTrue(automaticClassificationJobTable.contains("proposal_checkpoint BLOB"))
        XCTAssertTrue(automaticClassificationJobTable.contains("cancelled_by_undo"))
        XCTAssertTrue(automaticClassificationJobTable.contains("dispatch_authorization"))
        XCTAssertTrue(automaticClassificationJobTable.contains("authorization_id"))
        XCTAssertTrue(automaticClassificationJobTable.contains("authorized_at"))
        XCTAssertFalse(automaticClassificationJobTable.contains("task_title"))
        XCTAssertFalse(automaticClassificationJobTable.contains("description_text"))
        XCTAssertFalse(automaticClassificationJobTable.contains("api_key"))
        XCTAssertFalse(automaticClassificationJobTable.contains("raw_response"))
        XCTAssertTrue(automaticClassificationProviderCircuitTable.contains(
            "provider_execution_revision"
        ))
        XCTAssertTrue(automaticClassificationProviderCircuitTable.contains(
            "'unconfigured', 'closed', 'open', 'halfOpen', 'blocked'"
        ))
        XCTAssertTrue(automaticClassificationProviderCircuitTable.contains("probe_claim_id"))
        XCTAssertFalse(automaticClassificationProviderCircuitTable.contains("api_key"))
        XCTAssertFalse(automaticClassificationProviderCircuitTable.contains("base_url"))
        XCTAssertFalse(automaticClassificationProviderCircuitTable.contains("model"))
        XCTAssertFalse(automaticClassificationProviderCircuitTable.contains("hash"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS completed_subtask_record_view"))
        XCTAssertTrue(schema.contains("CREATE VIEW IF NOT EXISTS sync_endpoint_options_view"))
        XCTAssertTrue(schema.contains("t.status = 'pending'"))
        XCTAssertTrue(schema.contains(
            "latest.status IN ('returnedToPool', 'cancelledDraft')"
        ))
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
            initialNoteBody: "稳定 ID 必须保留。",
            now: now
        )
        let initialPoolNoteID = try XCTUnwrap(engine.chains[chainID]?.activeNoteEntries.first?.id)
        try engine.editPoolNote(
            chainID: chainID,
            noteID: initialPoolNoteID,
            body: "链级附言的编辑结果必须保留。",
            now: now
        )
        let deletedPoolNoteID = try engine.appendPoolNote(
            chainID: chainID,
            body: "这条链级附言会被删除。",
            now: now
        )
        try engine.deletePoolNote(chainID: chainID, noteID: deletedPoolNoteID, now: now)
        _ = try engine.addPlannedSubtask(chainID: chainID, title: "先规划子任务", difficulty: .medium, now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "写 round-trip 测试", difficulty: .hard, now: now)
        try engine.completeSubtask(subtaskID, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)
        let continuedTraceID = try engine.continueUnfinishedTrace(
            traceID: traceID,
            targetDate: day2,
            today: day2,
            now: now
        )
        let inheritedNoteID = try XCTUnwrap(engine.traces[continuedTraceID]?.activeNoteEntries.first?.id)
        try engine.editTraceNote(
            traceID: continuedTraceID,
            noteID: inheritedNoteID,
            body: "稳定 ID 和编辑结果必须保留。",
            today: day2,
            now: now.addingTimeInterval(30)
        )
        let deletedNoteID = try engine.appendTraceNote(
            traceID: continuedTraceID,
            body: "这条附言会被删除。",
            today: day2,
            now: now.addingTimeInterval(60)
        )
        try engine.deleteTraceNote(
            traceID: continuedTraceID,
            noteID: deletedNoteID,
            today: day2,
            now: now.addingTimeInterval(90)
        )

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
        try engine.updateTheme(
            .warmPaper,
            now: now.addingTimeInterval(100)
        )
        try engine.updateLanguage(
            .english,
            now: now.addingTimeInterval(101)
        )
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
        XCTAssertEqual(restored.getDayTodo(date: day2).traces.count, 3)
        XCTAssertEqual(restored.traces[changedTraceID]?.status, .changed)
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
        XCTAssertEqual(
            restored.chains[chainID]?.activeNoteEntries.map(\.body),
            ["链级附言的编辑结果必须保留。"]
        )
        XCTAssertEqual(
            restored.chains[chainID]?.noteEntries.first(where: { $0.id == deletedPoolNoteID })?.body,
            ""
        )
        XCTAssertEqual(
            restored.traces[continuedTraceID]?.activeNoteEntries.map(\.body),
            ["稳定 ID 和编辑结果必须保留。"]
        )
        XCTAssertEqual(
            restored.traces[continuedTraceID]?.noteEntries.first(where: { $0.id == deletedNoteID })?.body,
            ""
        )
    }

    func testSQLiteRepositoryRoundTripsThemeLanguageClockBitExactly() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-preference-clock-\(UUID().uuidString)"
            )
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let preferenceUpdatedAt = Date(
            timeIntervalSinceReferenceDate: 805_912_493.447_825
        )
        let engine = NoonmarkEngine()
        try engine.updateTheme(
            .warmPaper,
            writerID: "mac-preference-writer",
            now: preferenceUpdatedAt
        )

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        let restored = try repository.load()

        XCTAssertEqual(restored.preferences.theme, .warmPaper)
        XCTAssertEqual(
            restored.preferences.themeLanguageWriterID,
            "mac-preference-writer"
        )
        assertExactDate(
            restored.preferences.themeLanguageUpdatedAt,
            preferenceUpdatedAt,
            "主题与语言更新时间"
        )
    }

    func testSQLiteRepositoryRejectsThemeLanguageClockProjectionMismatch() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-preference-clock-projection-\(UUID().uuidString)"
            )
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let engine = NoonmarkEngine()
        try engine.updateTheme(
            .warmPaper,
            now: Date(timeIntervalSinceReferenceDate: 805_912_493.447_825)
        )
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        try executeSQL(
            """
            UPDATE app_preferences
            SET theme_language_updated_at = '2001-01-01T00:00:00.000Z'
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.load()) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) =
                error
            else {
                return XCTFail(
                    "预期主题与语言时钟投影校验失败，实际为 \(error)"
                )
            }
            XCTAssertEqual(
                message,
                "date projection does not match exact bit pattern"
            )
        }
    }

    func testSQLiteRepositoryRoundTripsCoreDomainDatesBitExactly() throws {
        let base = Date(timeIntervalSinceReferenceDate: 805_912_493.447_825)
        let noteEditedAt = base.addingTimeInterval(0.200_031)
        let deletedNoteCreatedAt = base.addingTimeInterval(0.400_061)
        let deletedNoteDeletedAt = base.addingTimeInterval(0.600_089)
        let plannedAt = base.addingTimeInterval(1.000_173)
        let completedTraceCreatedAt = base.addingTimeInterval(2.000_347)
        let definitionSupersededAt = base.addingTimeInterval(3.000_521)
        let subtaskCompletedAt = base.addingTimeInterval(4.000_695)
        let traceCompletedAt = base.addingTimeInterval(5.000_869)
        let unfinishedChainCreatedAt = base.addingTimeInterval(6.001_043)
        let unfinishedTraceCreatedAt = base.addingTimeInterval(7.001_217)
        let unfinishedSubtaskCreatedAt = base.addingTimeInterval(8.001_391)
        let settledAt = base.addingTimeInterval(9.001_565)
        let unlockedDayCreatedAt = base.addingTimeInterval(10.001_739)
        let day1 = LocalDate("2026-07-05")
        let day2 = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-exact-dates-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = NoonmarkEngine()
        let completedChainID = try engine.createPoolTask(
            title: "精确时间完成任务",
            initialNoteBody: "附言时间必须逐 bit 保留。",
            now: base
        )
        let originalDefinitionID = try XCTUnwrap(
            engine.definitions.values.first(where: { $0.chainID == completedChainID })?.id
        )
        let activeNoteID = try XCTUnwrap(
            engine.chains[completedChainID]?.activeNoteEntries.first?.id
        )
        try engine.editPoolNote(
            chainID: completedChainID,
            noteID: activeNoteID,
            body: "附言编辑时间必须逐 bit 保留。",
            now: noteEditedAt
        )
        let deletedNoteID = try engine.appendPoolNote(
            chainID: completedChainID,
            body: "附言墓碑时间必须逐 bit 保留。",
            now: deletedNoteCreatedAt
        )
        try engine.deletePoolNote(
            chainID: completedChainID,
            noteID: deletedNoteID,
            now: deletedNoteDeletedAt
        )
        let plannedSubtaskID = try engine.addPlannedSubtask(
            chainID: completedChainID,
            title: "精确时间计划子任务",
            difficulty: .medium,
            now: plannedAt
        )
        let completedTraceID = try engine.scheduleFromPool(
            chainID: completedChainID,
            date: day1,
            today: day1,
            now: completedTraceCreatedAt
        )
        try engine.renameTaskTitle(
            chainID: completedChainID,
            title: "精确时间完成任务（已换代）",
            today: day1,
            now: definitionSupersededAt
        )
        let replacementDefinitionID = try XCTUnwrap(
            engine.traces[completedTraceID]?.definitionID
        )
        let copiedSubtaskID = try XCTUnwrap(
            engine.subtasks.values.first(where: { $0.traceID == completedTraceID })?.id
        )
        try engine.completeSubtask(
            copiedSubtaskID,
            today: day1,
            now: subtaskCompletedAt
        )
        try engine.markCompleted(
            traceID: completedTraceID,
            today: day1,
            now: traceCompletedAt
        )

        let unfinishedChainID = try engine.createPoolTask(
            title: "精确时间未完成任务",
            now: unfinishedChainCreatedAt
        )
        let unfinishedTraceID = try engine.scheduleFromPool(
            chainID: unfinishedChainID,
            date: day1,
            today: day1,
            now: unfinishedTraceCreatedAt
        )
        let unfinishedSubtaskID = try engine.addSubtask(
            traceID: unfinishedTraceID,
            title: "精确时间待结算子任务",
            difficulty: .hard,
            now: unfinishedSubtaskCreatedAt
        )
        try engine.settleDays(
            upTo: day2,
            now: settledAt
        )
        engine.updateDailyReview(
            date: day2,
            summary: "未锁定 Day Todo 的时间也必须精确。",
            unfinishedReason: nil,
            tomorrowNote: nil,
            now: unlockedDayCreatedAt
        )
        let expected = engine.snapshot()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(expected)
        let restored = try repository.load()

        XCTAssertEqual(restored.snapshot(), expected)
        assertExactDate(restored.days[day1]?.createdAt, completedTraceCreatedAt, "锁定 Day Todo 创建时间")
        assertExactDate(restored.days[day1]?.updatedAt, settledAt, "锁定 Day Todo 更新时间")
        assertExactDate(restored.days[day1]?.lockedAt, settledAt, "锁定 Day Todo 锁定时间")
        assertExactDate(restored.days[day2]?.createdAt, unlockedDayCreatedAt, "未锁定 Day Todo 创建时间")
        assertExactDate(restored.days[day2]?.updatedAt, unlockedDayCreatedAt, "未锁定 Day Todo 更新时间")
        assertExactDate(restored.days[day2]?.lockedAt, nil, "未锁定 Day Todo 锁定时间")

        let restoredChain = try XCTUnwrap(restored.chains[completedChainID])
        let restoredActiveNote = try XCTUnwrap(
            restoredChain.noteEntries.first(where: { $0.id == activeNoteID })
        )
        let restoredDeletedNote = try XCTUnwrap(
            restoredChain.noteEntries.first(where: { $0.id == deletedNoteID })
        )
        assertExactDate(restoredActiveNote.createdAt, base, "附言创建时间")
        assertExactDate(restoredActiveNote.updatedAt, noteEditedAt, "附言编辑时间")
        assertExactDate(restoredActiveNote.deletedAt, nil, "活动附言删除时间")
        assertExactDate(restoredDeletedNote.createdAt, deletedNoteCreatedAt, "墓碑附言创建时间")
        assertExactDate(restoredDeletedNote.updatedAt, deletedNoteDeletedAt, "墓碑附言更新时间")
        assertExactDate(restoredDeletedNote.deletedAt, deletedNoteDeletedAt, "墓碑附言删除时间")

        let originalDefinition = try XCTUnwrap(restored.definitions[originalDefinitionID])
        let replacementDefinition = try XCTUnwrap(
            restored.definitions[replacementDefinitionID]
        )
        assertExactDate(originalDefinition.createdAt, base, "原任务定义创建时间")
        assertExactDate(
            originalDefinition.contentUpdatedAt,
            definitionSupersededAt,
            "原任务定义内容更新时间"
        )
        assertExactDate(
            originalDefinition.supersededAt,
            definitionSupersededAt,
            "原任务定义换代时间"
        )
        assertExactDate(replacementDefinition.createdAt, definitionSupersededAt, "新任务定义创建时间")
        assertExactDate(
            replacementDefinition.contentUpdatedAt,
            definitionSupersededAt,
            "新任务定义内容更新时间"
        )
        assertExactDate(replacementDefinition.supersededAt, nil, "当前任务定义换代时间")
        assertExactDate(
            originalDefinition.plannedSubtasks.first(where: {
                $0.id == plannedSubtaskID
            })?.createdAt,
            plannedAt,
            "计划子任务创建时间"
        )

        let completedTrace = try XCTUnwrap(restored.traces[completedTraceID])
        let unfinishedTrace = try XCTUnwrap(restored.traces[unfinishedTraceID])
        assertExactDate(completedTrace.createdAt, completedTraceCreatedAt, "完成轨迹创建时间")
        assertExactDate(completedTrace.contentUpdatedAt, traceCompletedAt, "完成轨迹更新时间")
        assertExactDate(completedTrace.completedAt, traceCompletedAt, "完成轨迹完成时间")
        assertExactDate(completedTrace.settledAt, nil, "完成轨迹结算时间")
        assertExactDate(unfinishedTrace.createdAt, unfinishedTraceCreatedAt, "未完成轨迹创建时间")
        assertExactDate(unfinishedTrace.contentUpdatedAt, settledAt, "未完成轨迹更新时间")
        assertExactDate(unfinishedTrace.completedAt, nil, "未完成轨迹完成时间")
        assertExactDate(unfinishedTrace.settledAt, settledAt, "未完成轨迹结算时间")

        let completedSubtask = try XCTUnwrap(restored.subtasks[copiedSubtaskID])
        let unfinishedSubtask = try XCTUnwrap(restored.subtasks[unfinishedSubtaskID])
        assertExactDate(completedSubtask.createdAt, completedTraceCreatedAt, "完成子任务创建时间")
        assertExactDate(completedSubtask.updatedAt, subtaskCompletedAt, "完成子任务更新时间")
        assertExactDate(completedSubtask.completedAt, subtaskCompletedAt, "完成子任务完成时间")
        assertExactDate(completedSubtask.settledAt, nil, "完成子任务结算时间")
        assertExactDate(unfinishedSubtask.createdAt, unfinishedSubtaskCreatedAt, "未完成子任务创建时间")
        assertExactDate(unfinishedSubtask.updatedAt, settledAt, "未完成子任务更新时间")
        assertExactDate(unfinishedSubtask.completedAt, nil, "未完成子任务完成时间")
        assertExactDate(unfinishedSubtask.settledAt, settledAt, "未完成子任务结算时间")
    }

    func testSQLiteRepositoryRejectsDateProjectionThatDisagreesWithExactBits() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-date-projection-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "拒绝分叉时间投影",
            now: Date(timeIntervalSinceReferenceDate: 805_912_493.447_825)
        )
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        try executeSQL(
            """
            UPDATE task_definitions
            SET created_at = '2001-01-01T00:00:00.000Z'
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try repository.load()) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) = error else {
                return XCTFail("预期精确时间投影校验失败，实际为 \(error)")
            }
            XCTAssertEqual(message, "date projection does not match exact bit pattern")
        }
    }

    func testFuturePlanReturnToPoolSurvivesRepositoryRoundTripWithoutVisibleTrace() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = LocalDate("2026-07-05")
        let futureDate = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-future-return-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "未来草稿回池",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: futureDate,
            today: today,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.addSubtask(
            traceID: traceID,
            title: "未来草稿子任务",
            now: now.addingTimeInterval(2)
        )
        try repository.save(engine)

        try engine.returnToPool(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        try repository.save(engine)

        let restored = try repository.load()
        XCTAssertEqual(restored.snapshot(), engine.snapshot())
        XCTAssertNotNil(restored.traces[traceID]?.draftCancellationID)
        XCTAssertEqual(restored.traces[traceID]?.draftCancelledOn, today)
        XCTAssertTrue(restored.futurePlans(today: today).isEmpty)
        XCTAssertTrue(restored.getDayTodo(date: futureDate).traces.isEmpty)
        XCTAssertEqual(restored.taskPool().map(\.chain.id), [chainID])
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM day_todo_view WHERE id = '\(traceID.rawValue.uuidString)'",
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM future_plan_view WHERE id = '\(traceID.rawValue.uuidString)'",
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM task_pool_view WHERE chain_id = '\(chainID.rawValue.uuidString)'",
                at: databaseURL
            ),
            1
        )
    }

    func testDeferredFutureTargetReturnUsesTheSameTaskPoolProjectionAfterRestart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = LocalDate("2026-07-05")
        let futureDate = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-deferred-return-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "延期目标持久化回池",
            now: now
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let targetTraceID = try engine.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: futureDate,
            today: today,
            now: now.addingTimeInterval(2)
        )
        try engine.returnToPool(
            traceID: targetTraceID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        try repository.save(engine)

        let restored = try repository.load()
        XCTAssertEqual(restored.snapshot(), engine.snapshot())
        XCTAssertEqual(restored.traces[sourceTraceID]?.status, .deferred)
        XCTAssertEqual(restored.traces[targetTraceID]?.status, .cancelledDraft)
        XCTAssertEqual(
            restored.traces[targetTraceID]?.carriedFromTraceID,
            sourceTraceID
        )
        XCTAssertEqual(restored.taskPool().map(\.chain.id), [chainID])
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM task_pool_view "
                    + "WHERE chain_id = '\(chainID.rawValue.uuidString)'",
                at: databaseURL
            ),
            1
        )
    }

    func testPinQueueAndWithdrawnDeferralSurviveRepositoryRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = LocalDate("2026-07-05")
        let tomorrow = LocalDate("2026-07-06")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-pin-withdraw-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let pinnedChainID = try engine.createPoolTask(
            title: "持久化置顶",
            now: now
        )
        let pinnedTraceID = try engine.scheduleFromPool(
            chainID: pinnedChainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.pinDayTrace(
            pinnedTraceID,
            today: today,
            now: now.addingTimeInterval(2)
        )

        let deferredChainID = try engine.createPoolTask(
            title: "持久化撤回延期",
            now: now.addingTimeInterval(3)
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: deferredChainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(4)
        )
        let targetTraceID = try engine.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: now.addingTimeInterval(5)
        )
        try engine.withdrawDeferral(
            sourceTraceID: sourceTraceID,
            today: today,
            now: now.addingTimeInterval(6)
        )

        try repository.save(engine)
        let restored = try repository.load()

        XCTAssertEqual(restored.snapshot(), engine.snapshot())
        XCTAssertEqual(restored.traces[pinnedTraceID]?.pinOrder, 1)
        XCTAssertEqual(restored.traces[sourceTraceID]?.status, .pending)
        XCTAssertEqual(restored.traces[targetTraceID]?.status, .cancelledDraft)
        XCTAssertTrue(restored.futurePlans(today: today).isEmpty)
        XCTAssertEqual(
            try integerScalar(
                "SELECT pin_order FROM day_traces WHERE id = '\(pinnedTraceID.rawValue.uuidString)'",
                at: databaseURL
            ),
            1
        )
        XCTAssertNoThrow(try restored.snapshot().validateIntegrity())
    }

    func testDayTodoViewExcludesReturnedSourceAfterSameDayReschedule() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = LocalDate("2026-07-05")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-day-todo-projection-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同日回池再排期", now: now)
        let returnedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.returnToPool(
            traceID: returnedTraceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        let replacementTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(3)
        )
        try repository.save(engine)

        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM day_todo_view WHERE chain_id = '\(chainID.rawValue.uuidString)'",
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM day_todo_view WHERE id = '\(returnedTraceID.rawValue.uuidString)'",
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM day_todo_view WHERE id = '\(replacementTraceID.rawValue.uuidString)'",
                at: databaseURL
            ),
            1
        )
    }

    func testCancelledFutureDraftStaysOutOfCompletedSQLiteProjectionsAfterChainCompletes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cancellationDay = LocalDate("2026-07-05")
        let cancelledDraftDate = LocalDate("2026-07-06")
        let completedDate = LocalDate("2026-07-07")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-completed-projection-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "完成投影过滤取消草稿",
            now: now
        )
        let cancelledTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: cancelledDraftDate,
            today: cancellationDay,
            now: now.addingTimeInterval(1)
        )
        let cancelledSubtaskID = try engine.addSubtask(
            traceID: cancelledTraceID,
            title: "隐藏取消草稿子任务",
            now: now.addingTimeInterval(2)
        )
        try engine.returnToPool(
            traceID: cancelledTraceID,
            today: cancellationDay,
            now: now.addingTimeInterval(3)
        )

        let completedTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: completedDate,
            today: completedDate,
            now: now.addingTimeInterval(4)
        )
        let carriedSubtaskID = try XCTUnwrap(
            engine.subtasks.values.first(where: {
                $0.traceID == completedTraceID
                    && $0.lineageID
                    == engine.subtasks[cancelledSubtaskID]?.lineageID
            })?.id
        )
        let completedSubtaskID = try engine.addSubtask(
            traceID: completedTraceID,
            title: "可见完成子任务",
            now: now.addingTimeInterval(5)
        )
        try engine.completeSubtask(
            carriedSubtaskID,
            today: completedDate,
            now: now.addingTimeInterval(6)
        )
        try engine.completeSubtask(
            completedSubtaskID,
            today: completedDate,
            now: now.addingTimeInterval(7)
        )
        try engine.markCompleted(
            traceID: completedTraceID,
            today: completedDate,
            now: now.addingTimeInterval(8)
        )
        try repository.save(engine)

        let completedTraceUUID = completedTraceID.rawValue.uuidString
        let cancelledTraceUUID = cancelledTraceID.rawValue.uuidString
        let carriedSubtaskUUID = carriedSubtaskID.rawValue.uuidString
        let completedSubtaskUUID = completedSubtaskID.rawValue.uuidString
        let cancelledSubtaskUUID = cancelledSubtaskID.rawValue.uuidString
        let chainUUID = chainID.rawValue.uuidString

        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_pool_view
                WHERE id = '\(completedTraceUUID)'
                  AND trajectory_start_date = '\(completedDate)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_trajectory_detail_view
                WHERE completed_trace_id = '\(completedTraceUUID)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_trajectory_detail_view
                WHERE completed_trace_id = '\(completedTraceUUID)'
                  AND trace_id = '\(cancelledTraceUUID)'
                """,
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_trajectory_detail_view
                WHERE completed_trace_id = '\(completedTraceUUID)'
                  AND subtask_id = '\(carriedSubtaskUUID)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_trajectory_detail_view
                WHERE completed_trace_id = '\(completedTraceUUID)'
                  AND subtask_id = '\(completedSubtaskUUID)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_trajectory_detail_view
                WHERE completed_trace_id = '\(completedTraceUUID)'
                  AND subtask_id = '\(cancelledSubtaskUUID)'
                """,
                at: databaseURL
            ),
            0
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_record_view
                WHERE parent_chain_id = '\(chainUUID)'
                  AND subtask_id = '\(carriedSubtaskUUID)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_record_view
                WHERE parent_chain_id = '\(chainUUID)'
                  AND subtask_id = '\(completedSubtaskUUID)'
                """,
                at: databaseURL
            ),
            1
        )
        XCTAssertEqual(
            try integerScalar(
                """
                SELECT COUNT(*)
                FROM completed_subtask_record_view
                WHERE parent_chain_id = '\(chainUUID)'
                  AND (
                    subtask_id = '\(cancelledSubtaskUUID)'
                    OR trace_id = '\(cancelledTraceUUID)'
                  )
                """,
                at: databaseURL
            ),
            0
        )
    }

    func testDataImportReplacementRemovesOldRowsAndResetsSyncState() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-import-replace-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let identity = SyncDeviceIdentity(
            displayName: "Import Test Mac",
            createdAt: now
        )
        let oldEngine = NoonmarkEngine()
        _ = try oldEngine.createPoolTask(title: "导入前旧任务", now: now)
        try syncRepository.saveDeviceIdentity(identity)
        try repository.save(
            oldEngine.snapshot(),
            recordingChangesFor: identity.deviceID,
            changedAt: now
        )
        try syncRepository.saveMetadata(
            SyncMetadataEntry(key: "old.sync.status", value: Data("old".utf8))
        )
        XCTAssertFalse(try syncRepository.journalEntries().isEmpty)

        let importedEngine = NoonmarkEngine()
        _ = try importedEngine.createPoolTask(title: "数据包任务", now: now)
        try repository.replaceForDataImport(
            importedEngine.snapshot(),
            preserving: identity
        )

        XCTAssertEqual(try repository.load().snapshot(), importedEngine.snapshot())
        XCTAssertEqual(try syncRepository.loadDeviceIdentity(), identity)
        XCTAssertTrue(try syncRepository.journalEntries().isEmpty)
        XCTAssertNil(try syncRepository.metadata(for: "old.sync.status"))
    }

    func testDataImportStagingFailureLeavesExistingDatabaseUnchanged() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-import-rollback-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let existingEngine = NoonmarkEngine()
        _ = try existingEngine.createPoolTask(title: "必须保留的任务", now: now)
        try repository.save(existingEngine)

        let invalidEngine = NoonmarkEngine()
        _ = try invalidEngine.createPoolTask(title: "无效导入任务", now: now)
        var invalidSnapshot = invalidEngine.snapshot()
        invalidSnapshot.chains.removeAll()

        XCTAssertThrowsError(
            try repository.replaceForDataImport(
                invalidSnapshot,
                preserving: nil
            )
        )
        XCTAssertEqual(try repository.load().snapshot(), existingEngine.snapshot())
    }
}

private extension NoonmarkEngine {
    func engineReviewSummary(for date: LocalDate) -> String? {
        days[date]?.reviewSummary
    }
}

private func assertExactDate(
    _ actual: Date?,
    _ expected: Date?,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        actual?.timeIntervalSinceReferenceDate.bitPattern,
        expected?.timeIntervalSinceReferenceDate.bitPattern,
        message,
        file: file,
        line: line
    )
}

private func integerScalar(_ sql: String, at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
        sqlite3_close(database)
        throw SQLiteRepositoryError.openFailed("test probe could not open database")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        throw SQLiteRepositoryError.prepareFailed("test probe could not prepare scalar")
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteRepositoryError.stepFailed("test probe could not read scalar")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

private func executeSQL(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
        sqlite3_close(database)
        throw SQLiteRepositoryError.openFailed("test probe could not open database")
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteRepositoryError.executeFailed("test probe could not execute SQL")
    }
}

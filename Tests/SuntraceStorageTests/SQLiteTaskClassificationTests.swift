import SQLite3
@testable import SuntraceCore
@testable import SuntraceStorage
@testable import SuntraceSync
import XCTest

final class SQLiteTaskClassificationTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let now = Date(timeIntervalSince1970: 1_800_000_000.123_456)

    func testRepositoryRoundTripPreservesClassificationAuditFactsAndEventStream() throws {
        let databaseURL = makeDatabaseURL("classification-audit")
        defer {
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                try? FileManager.default.removeItem(at: databaseURL)
            }
        }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类审计事实", now: now)
        let firstReceipt = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "项目", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "待核查", colorHex: "#0E9488"),
                        .new(name: "  待核查  ", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .zhulongSuggestion(
                sessionID: UUID(),
                draftID: UUID(),
                draftVersion: 8,
                evidenceID: UUID()
            ),
            to: engine,
            at: now
        )
        XCTAssertEqual(firstReceipt.notices, [.duplicateLabelCollapsed(name: "待核查")])

        let traceTime = now.addingTimeInterval(7.125_678)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: traceTime
        )
        let eventCaptureTime = now.addingTimeInterval(12.345_678)
        try engine.abandonChain(from: traceID, now: eventCaptureTime)

        let expected = engine.snapshot().classifications
        XCTAssertEqual(expected.snapshotEventsByTraceID[traceID]?.count, 1)
        XCTAssertEqual(expected.snapshotEventsByTraceID[traceID]?.first?.capturedAt, eventCaptureTime)
        XCTAssertEqual(
            expected.snapshotEventsByTraceID[traceID]?.first?.revision,
            expected.revision
        )
        for receipt in expected.committedReceiptsByInteractionID.values {
            let record = try XCTUnwrap(expected.changeRecords.first { $0.id == receipt.changeRecordID })
            XCTAssertEqual(receipt.changeRecordIntegrityDigest, record.integrityDigest)
            XCTAssertEqual(receipt.notices, record.notices)
            XCTAssertEqual(record.planDigest.count, 64)
            XCTAssertEqual(record.integrityDigest.count, 64)
            XCTAssertTrue(record.hasValidIntegrityDigest())
        }
        try expected.validateIntegrity()

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        let restored = try repository.load().snapshot().classifications

        XCTAssertEqual(restored, expected)
    }

    func testClassifiedPoolRemovalPersistsHistoryAnchorWithoutRevivingTaskOnRestart() throws {
        let databaseURL = makeDatabaseURL("classified-pool-removal")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "移出后不能复活", now: now)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "审计", colorHex: "#0E9488")]
                )
            ),
            to: engine,
            at: now
        )

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)

        let firstRestart = try repository.load()
        let removedAt = now.addingTimeInterval(60)
        XCTAssertEqual(
            try firstRestart.removeTaskFromPool(chainID: chainID, now: removedAt),
            .removedKeepingHistory
        )
        try repository.save(firstRestart)

        let secondRestart = try SQLiteEngineRepository(databaseURL: databaseURL).load()
        XCTAssertFalse(secondRestart.taskPool().contains { $0.chain.id == chainID })
        XCTAssertEqual(secondRestart.chains[chainID]?.state, .abandoned)

        let restoredState = secondRestart.snapshot().classifications
        XCTAssertNil(restoredState.currentByChainID[chainID]?.categoryID)
        XCTAssertEqual(restoredState.currentByChainID[chainID]?.labelIDs, [])
        XCTAssertEqual(restoredState.relationHistory.count, 2)
        XCTAssertTrue(restoredState.relationHistory.allSatisfy { entry in
            entry.chainID == chainID
                && entry.removedAt == removedAt
                && entry.removedBySource == .deterministicDomainAction(
                    reason: "task removed from task pool while preserving classification history"
                )
        })
        XCTAssertNoThrow(try secondRestart.snapshot().validateIntegrity())

        try repository.save(secondRestart)
        let thirdRestart = try repository.load().snapshot()
        XCTAssertEqual(thirdRestart, secondRestart.snapshot())
        XCTAssertFalse(try repository.load().taskPool().contains { $0.chain.id == chainID })
    }

    func testRepositoryRoundTripPreservesEveryCurrentClassificationSource() throws {
        let databaseURL = makeDatabaseURL("classification-sources")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainIDs = try (0 ..< 4).map { index in
            try engine.createPoolTask(title: "分类来源 \(index)", now: now)
        }
        let sources: [ClassificationSource] = [
            .userDirect,
            .zhulongSuggestion(
                sessionID: UUID(),
                draftID: UUID(),
                draftVersion: Int(Int32.max) + 17,
                evidenceID: UUID()
            ),
            .inherited(fromChainID: chainIDs[0]),
            .deterministicDomainAction(reason: "复制任务时继承已确认分类")
        ]

        for (index, source) in sources.enumerated() {
            let state = engine.snapshot().classifications
            let draft = if index == 0 {
                TaskClassificationDraft(
                    chainID: chainIDs[index],
                    category: .new(name: "来源分类", colorHex: "#2A6FDB"),
                    labels: [.new(name: "来源标签", colorHex: "#0E9488")]
                )
            } else {
                TaskClassificationDraft(
                    chainID: chainIDs[index],
                    category: .existing(try XCTUnwrap(state.categories.keys.first)),
                    labels: [.existing(try XCTUnwrap(state.labels.keys.first))]
                )
            }
            _ = try commit(
                .setCurrent(draft),
                source: source,
                to: engine,
                at: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let expected = engine.snapshot().classifications
        XCTAssertEqual(expected.changeRecords.map(\.source), sources)
        for (index, source) in sources.enumerated() {
            let current = try XCTUnwrap(expected.currentByChainID[chainIDs[index]])
            XCTAssertEqual(current.category?.source, source)
            XCTAssertTrue(current.labels.allSatisfy { $0.source == source })
        }

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        let restored = try repository.load().snapshot().classifications

        XCTAssertEqual(restored.changeRecords, expected.changeRecords)
        XCTAssertEqual(restored.currentByChainID, expected.currentByChainID)
    }

    func testRepositoryRoundTripPreservesMergesAndDeletionTombstones() throws {
        let databaseURL = makeDatabaseURL("classification-management")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "分类治理", now: now)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "分类 A", colorHex: "#2A6FDB"),
                    labels: [.new(name: "标签 A", colorHex: "#0E9488")]
                )
            ),
            to: engine,
            at: now
        )
        _ = try commit(.createCategory(name: "分类 B", colorHex: "#D1477A"), to: engine, at: now.addingTimeInterval(1))
        _ = try commit(.createLabel(name: "标签 B", colorHex: "#7C5CFF"), to: engine, at: now.addingTimeInterval(2))
        _ = try commit(.createCategory(name: "可删除分类", colorHex: "#E0851B"), to: engine, at: now.addingTimeInterval(3))
        _ = try commit(.createLabel(name: "可删除标签", colorHex: "#315B8A"), to: engine, at: now.addingTimeInterval(4))

        var state = engine.snapshot().classifications
        let categoryA = try XCTUnwrap(state.categories.values.first { $0.name == "分类 A" }?.id)
        let categoryB = try XCTUnwrap(state.categories.values.first { $0.name == "分类 B" }?.id)
        let labelA = try XCTUnwrap(state.labels.values.first { $0.name == "标签 A" }?.id)
        let labelB = try XCTUnwrap(state.labels.values.first { $0.name == "标签 B" }?.id)
        let deletedCategoryID = try XCTUnwrap(state.categories.values.first { $0.name == "可删除分类" }?.id)
        let deletedLabelID = try XCTUnwrap(state.labels.values.first { $0.name == "可删除标签" }?.id)

        _ = try commit(.mergeCategory(source: categoryA, into: categoryB), to: engine, at: now.addingTimeInterval(5))
        _ = try commit(.mergeLabel(source: labelA, into: labelB), to: engine, at: now.addingTimeInterval(6))
        _ = try commit(.hardDeleteCategory(deletedCategoryID), to: engine, at: now.addingTimeInterval(7))
        _ = try commit(.hardDeleteLabel(deletedLabelID), to: engine, at: now.addingTimeInterval(8))

        state = engine.snapshot().classifications
        XCTAssertEqual(state.categoryMerges[categoryA]?.targetID, categoryB)
        XCTAssertEqual(state.labelMerges[labelA]?.targetID, labelB)
        XCTAssertEqual(state.currentByChainID[chainID]?.categoryID, categoryB)
        XCTAssertEqual(state.currentByChainID[chainID]?.labelIDs, [labelB])
        XCTAssertNotNil(state.categoryDeletionTombstones[deletedCategoryID])
        XCTAssertNotNil(state.labelDeletionTombstones[deletedLabelID])

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        _ = try commit(
            .createCategory(name: "可删除分类", colorHex: "#E0851B"),
            to: engine,
            at: now.addingTimeInterval(9)
        )
        _ = try commit(
            .createLabel(name: "可删除标签", colorHex: "#315B8A"),
            to: engine,
            at: now.addingTimeInterval(10)
        )
        try repository.save(engine)
        state = engine.snapshot().classifications
        let restored = try repository.load().snapshot().classifications

        XCTAssertEqual(restored, state)
        XCTAssertNotNil(restored.categories.values.first { $0.name == "可删除分类" })
        XCTAssertNotNil(restored.labels.values.first { $0.name == "可删除标签" })
        XCTAssertEqual(try rowCount("task_categories", id: deletedCategoryID.description, at: databaseURL), 0)
        XCTAssertEqual(try rowCount("task_labels", id: deletedLabelID.description, at: databaseURL), 0)
    }

    func testRepositoryAtomicallyDeletesAndRecreatesClassificationHistoricalAliases() throws {
        let databaseURL = makeDatabaseURL("classification-delete-recreate")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "旧主分类别名", colorHex: "#2A6FDB"),
            to: engine,
            at: now
        )
        _ = try commit(
            .createLabel(name: "旧标签别名", colorHex: "#0E9488"),
            to: engine,
            at: now.addingTimeInterval(1)
        )
        var state = engine.snapshot().classifications
        let oldCategoryID = try XCTUnwrap(state.categories.keys.first)
        let oldLabelID = try XCTUnwrap(state.labels.keys.first)
        _ = try commit(
            .renameCategory(oldCategoryID, to: "删除前主分类名称"),
            to: engine,
            at: now.addingTimeInterval(2)
        )
        _ = try commit(
            .renameLabel(oldLabelID, to: "删除前标签名称"),
            to: engine,
            at: now.addingTimeInterval(3)
        )

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)

        _ = try commit(
            .hardDeleteCategory(oldCategoryID),
            to: engine,
            at: now.addingTimeInterval(4)
        )
        _ = try commit(
            .hardDeleteLabel(oldLabelID),
            to: engine,
            at: now.addingTimeInterval(5)
        )
        _ = try commit(
            .createCategory(name: "  旧主分类别名  ", colorHex: "#D1477A"),
            to: engine,
            at: now.addingTimeInterval(6)
        )
        _ = try commit(
            .createLabel(name: "  旧标签别名  ", colorHex: "#7C5CFF"),
            to: engine,
            at: now.addingTimeInterval(7)
        )
        let expected = engine.snapshot()

        try repository.save(expected)

        state = try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot().classifications
        XCTAssertEqual(state, expected.classifications)
        let newCategory = try XCTUnwrap(state.categories.values.first { $0.name == "旧主分类别名" })
        let newLabel = try XCTUnwrap(state.labels.values.first { $0.name == "旧标签别名" })
        XCTAssertNotEqual(newCategory.id, oldCategoryID)
        XCTAssertNotEqual(newLabel.id, oldLabelID)
        XCTAssertEqual(state.categoryDeletionTombstones[oldCategoryID], expected.classifications.categoryDeletionTombstones[oldCategoryID])
        XCTAssertEqual(state.labelDeletionTombstones[oldLabelID], expected.classifications.labelDeletionTombstones[oldLabelID])
        XCTAssertEqual(try rowCount("task_categories", id: oldCategoryID.description, at: databaseURL), 0)
        XCTAssertEqual(try rowCount("task_labels", id: oldLabelID.description, at: databaseURL), 0)
    }

    func testRepositoryPreservesExactClassificationTimesAndHistoricalAliases() throws {
        let databaseURL = makeDatabaseURL("classification-exact-times")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let createdAt = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let categoryRenameAt = createdAt.addingTimeInterval(10.234_567_8)
        let labelRenameAt = createdAt.addingTimeInterval(20.345_678_9)
        let eventAt = createdAt.addingTimeInterval(30.456_789_1)
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "精确分类时间", now: createdAt)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "健身", colorHex: "#2A6FDB"),
                    labels: [.new(name: "力量", colorHex: "#0E9488")]
                )
            ),
            to: engine,
            at: createdAt
        )
        var state = engine.snapshot().classifications
        let categoryID = try XCTUnwrap(state.currentByChainID[chainID]?.categoryID)
        let labelID = try XCTUnwrap(state.currentByChainID[chainID]?.labelIDs.first)
        _ = try commit(.renameCategory(categoryID, to: "运动"), to: engine, at: categoryRenameAt)
        _ = try commit(.renameLabel(labelID, to: "训练"), to: engine, at: labelRenameAt)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: eventAt)
        try engine.abandonChain(from: traceID, now: eventAt)

        let aliasChainID = try engine.createPoolTask(title: "历史名称复用", now: eventAt)
        let aliasReceipt = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: aliasChainID,
                    category: .new(name: "  健身  ", colorHex: "#D1477A"),
                    labels: [.new(name: "  力量  ", colorHex: "#E0851B")]
                )
            ),
            to: engine,
            at: eventAt.addingTimeInterval(1.123_456)
        )
        XCTAssertEqual(aliasReceipt.notices.count, 2)

        state = engine.snapshot().classifications
        XCTAssertEqual(state.currentByChainID[aliasChainID]?.categoryID, categoryID)
        XCTAssertEqual(state.currentByChainID[aliasChainID]?.labelIDs, [labelID])
        XCTAssertEqual(state.categories[categoryID]?.nameVersions.map(\.validFrom), [createdAt, categoryRenameAt])
        XCTAssertEqual(state.labels[labelID]?.nameVersions.map(\.validFrom), [createdAt, labelRenameAt])
        XCTAssertEqual(state.snapshotEventsByTraceID[traceID]?.first?.capturedAt, eventAt)
        XCTAssertNotNil(state.snapshotEventsByTraceID[traceID]?.first?.revision)

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)
        let restored = try repository.load().snapshot().classifications

        XCTAssertEqual(restored, state)

        let intruderID = UUID()
        let intruderVersionID = UUID()
        let claimedKey = ClassificationNameCanonicalizer.canonicalKey("健身")
        let keyVersion = ClassificationNameCanonicalizer.algorithmVersion
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                BEGIN IMMEDIATE;
                INSERT INTO task_categories(id, name, color_hex, created_at, updated_at)
                VALUES ('\(intruderID.uuidString)', '其他分类', '#000000', '2026-07-05T00:00:00.000Z', '2026-07-05T00:00:00.000Z');
                INSERT INTO classification_item_metadata(
                    kind, item_id, canonical_key, canonical_key_version, lifecycle
                )
                VALUES ('category', '\(intruderID.uuidString)', 'other-category', '\(keyVersion)', 'active');
                INSERT INTO classification_name_versions(
                    version_id, kind, item_id, version_sequence, name,
                    canonical_key, canonical_key_version, valid_from, valid_until
                )
                VALUES (
                    '\(intruderVersionID.uuidString)', 'category', '\(intruderID.uuidString)', 0,
                    '健身', '\(claimedKey)', '\(keyVersion)', '2026-07-05T00:00:00.000Z', NULL
                );
                COMMIT;
                """,
                at: databaseURL
            )
        )
        XCTAssertEqual(try repository.load().snapshot().classifications, state)
    }

    func testRepositoryRebuildsCanonicalAuditSequencesWhenConcurrentFactsSortBeforeStoredFacts() throws {
        let databaseURL = makeDatabaseURL("classification-canonical-audit-reorder")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let fixture = try makeConcurrentRemovalFixture()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)

        try repository.save(fixture.laterSnapshot)
        XCTAssertEqual(
            try repository.load().snapshot().classifications,
            fixture.laterSnapshot.classifications
        )
        XCTAssertEqual(fixture.earlierHistoryIDs.count, 2)
        XCTAssertEqual(fixture.laterHistoryIDs.count, 2)
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                UPDATE classification_change_records
                SET plan_id = '\(UUID().uuidString)'
                WHERE record_id = '\(fixture.laterChangeRecordID.uuidString)'
                """,
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                UPDATE classification_relation_history
                SET removed_at = removed_at + 1
                WHERE history_id = '\(try XCTUnwrap(fixture.laterHistoryIDs.first).uuidString)'
                """,
                at: databaseURL
            )
        )

        try repository.save(fixture.mergedSnapshot)
        let restored = try repository.load().snapshot()

        XCTAssertEqual(restored, fixture.mergedSnapshot)
        XCTAssertEqual(
            restored.classifications.changeRecords.map(\.id),
            fixture.mergedSnapshot.classifications.changeRecords.map(\.id)
        )
        XCTAssertEqual(
            restored.classifications.relationHistory.map(\.id),
            fixture.mergedSnapshot.classifications.relationHistory.map(\.id)
        )
        XCTAssertLessThan(
            try XCTUnwrap(
                restored.classifications.changeRecords.firstIndex {
                    $0.id == fixture.earlierChangeRecordID
                }
            ),
            try XCTUnwrap(
                restored.classifications.changeRecords.firstIndex {
                    $0.id == fixture.laterChangeRecordID
                }
            )
        )
        XCTAssertTrue(
            Set(fixture.earlierHistoryIDs).isSubset(
                of: Set(restored.classifications.relationHistory.prefix(2).map(\.id))
            )
        )
    }

    func testRepositoryRejectsChangeRecordIdentityCollisionAndRollsBackEarlierHistoryWrites() throws {
        let databaseURL = makeDatabaseURL("classification-change-record-collision")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let fixture = try makeConcurrentRemovalFixture()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(fixture.laterSnapshot)

        var collision = fixture.mergedSnapshot
        let storedRecord = try XCTUnwrap(
            collision.classifications.changeRecords.first {
                $0.id == fixture.laterChangeRecordID
            }
        )
        let collidingRecord = ClassificationChangeRecord(
            id: storedRecord.id,
            planID: storedRecord.planID,
            interactionID: storedRecord.interactionID,
            source: storedRecord.source,
            decisionID: storedRecord.decisionID,
            changes: storedRecord.changes,
            notices: storedRecord.notices,
            committedAt: storedRecord.committedAt,
            revision: storedRecord.revision,
            planDigest: storedRecord.planDigest == String(repeating: "0", count: 64)
                ? String(repeating: "f", count: 64)
                : String(repeating: "0", count: 64)
        )
        collision.classifications.changeRecords = try ClassificationAuditCanonicalOrder.changeRecords(
            collision.classifications.changeRecords.map {
                $0.id == collidingRecord.id ? collidingRecord : $0
            }
        )
        collision.classifications.committedReceiptsByInteractionID[collidingRecord.interactionID] =
            ClassificationReceipt(
                planID: collidingRecord.planID,
                revision: collidingRecord.revision,
                notices: collidingRecord.notices,
                changeRecordID: collidingRecord.id,
                decisionID: collidingRecord.decisionID,
                changeRecordIntegrityDigest: collidingRecord.integrityDigest
            )
        try collision.validateIntegrity()

        XCTAssertThrowsError(try repository.save(collision)) { error in
            self.assertInvalidStoredValue(error)
        }
        XCTAssertEqual(try repository.load().snapshot(), fixture.laterSnapshot)
    }

    func testRepositoryRejectsRelationHistoryIdentityCollisionWithoutMutation() throws {
        let databaseURL = makeDatabaseURL("classification-relation-history-collision")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let fixture = try makeConcurrentRemovalFixture()
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(fixture.laterSnapshot)

        var collision = fixture.mergedSnapshot
        let storedHistory = try XCTUnwrap(
            collision.classifications.relationHistory.first {
                fixture.laterHistoryIDs.contains($0.id)
            }
        )
        let collidingHistory = ClassificationRelationHistoryEntry(
            id: storedHistory.id,
            kind: storedHistory.kind,
            chainID: storedHistory.chainID,
            itemID: storedHistory.itemID,
            originSource: storedHistory.originSource,
            originDecisionID: storedHistory.originDecisionID,
            createdAt: storedHistory.createdAt,
            createdRevision: storedHistory.createdRevision,
            removedBySource: storedHistory.removedBySource,
            removedByDecisionID: storedHistory.removedByDecisionID,
            removedAt: storedHistory.removedAt.addingTimeInterval(0.25),
            removedRevision: storedHistory.removedRevision
        )
        collision.classifications.relationHistory = try ClassificationAuditCanonicalOrder.relationHistory(
            collision.classifications.relationHistory.map {
                $0.id == collidingHistory.id ? collidingHistory : $0
            }
        )
        try collision.validateIntegrity()

        XCTAssertThrowsError(try repository.save(collision)) { error in
            self.assertInvalidStoredValue(error)
        }
        XCTAssertEqual(try repository.load().snapshot(), fixture.laterSnapshot)
    }

    func testRepositoryCreatesOnlyAnEmptyStoreAndRejectsEveryNoncurrentShapeWithoutMutation() throws {
        let currentURL = makeDatabaseURL("classification-current-schema")
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let currentRepository = SQLiteEngineRepository(databaseURL: currentURL)
        _ = try currentRepository.load()
        XCTAssertEqual(try integerScalar("PRAGMA user_version", at: currentURL), SQLiteSchema.version)

        try executeProbeSQL("CREATE TABLE unexpected_object(id INTEGER PRIMARY KEY)", at: currentURL)
        XCTAssertThrowsError(try currentRepository.load()) { error in
            assertInvalidStoredValue(error)
        }
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'unexpected_object'",
                at: currentURL
            ),
            1
        )

        let nonemptyURL = makeDatabaseURL("classification-nonempty-schema")
        defer { try? FileManager.default.removeItem(at: nonemptyURL) }
        try executeProbeSQL("CREATE TABLE unrelated_facts(id INTEGER PRIMARY KEY)", at: nonemptyURL)
        XCTAssertThrowsError(try SQLiteEngineRepository(databaseURL: nonemptyURL).load()) { error in
            assertInvalidStoredValue(error)
        }
        XCTAssertEqual(try integerScalar("PRAGMA user_version", at: nonemptyURL), 0)
        XCTAssertEqual(
            try integerScalar("SELECT COUNT(*) FROM unrelated_facts", at: nonemptyURL),
            0
        )

        let otherVersionURL = makeDatabaseURL("classification-other-version")
        defer { try? FileManager.default.removeItem(at: otherVersionURL) }
        try executeProbeSQL("PRAGMA user_version = 2", at: otherVersionURL)
        XCTAssertThrowsError(try SQLiteEngineRepository(databaseURL: otherVersionURL).load()) { error in
            assertInvalidStoredValue(error)
        }
        XCTAssertEqual(try integerScalar("PRAGMA user_version", at: otherVersionURL), 2)
        XCTAssertEqual(
            try integerScalar(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                at: otherVersionURL
            ),
            0
        )
    }

    func testFinalizedClassificationFactsRejectLateChildrenAndDigestMutation() throws {
        let databaseURL = makeDatabaseURL("classification-finalization")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "完成态审计", now: now)
        let receipt = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "审计分类", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "审计标签", colorHex: "#0E9488"),
                        .new(name: " 审计标签 ", colorHex: "#7C5CFF")
                    ]
                )
            ),
            to: engine,
            at: now
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.abandonChain(from: traceID, now: now.addingTimeInterval(1))
        let expected = engine.snapshot().classifications
        let record = try XCTUnwrap(expected.changeRecords.first { $0.id == receipt.changeRecordID })
        let eventID = try XCTUnwrap(expected.snapshotEventsByTraceID[traceID]?.first?.id)

        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)

        XCTAssertThrowsError(
            try executeProbeSQL(
                "UPDATE classification_change_record_plan_digests SET digest = '\(String(repeating: "0", count: 64))' WHERE record_id = '\(record.id.uuidString)'",
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                "UPDATE classification_change_record_integrity_digests SET digest = '\(String(repeating: "1", count: 64))' WHERE record_id = '\(record.id.uuidString)'",
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                INSERT INTO classification_change_record_notice_records(
                    record_id, position, kind, duplicate_name, item_kind,
                    input_name, current_name, matched_historical_alias
                )
                VALUES ('\(record.id.uuidString)', 99, 'duplicateLabelCollapsed', 'late', NULL, NULL, NULL, NULL)
                """,
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                INSERT INTO classification_commit_notice_records(
                    interaction_id, position, kind, duplicate_name, item_kind,
                    input_name, current_name, matched_historical_alias
                )
                VALUES ('\(record.interactionID.uuidString)', 99, 'duplicateLabelCollapsed', 'late', NULL, NULL, NULL, NULL)
                """,
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                "UPDATE classification_commit_receipt_integrity_digests SET digest = '\(String(repeating: "2", count: 64))' WHERE interaction_id = '\(record.interactionID.uuidString)'",
                at: databaseURL
            )
        )
        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                INSERT INTO trace_classification_event_labels(event_id, label_id, name, color_hex)
                VALUES ('\(eventID.uuidString)', '\(UUID().uuidString)', 'late', '#000000')
                """,
                at: databaseURL
            )
        )

        XCTAssertEqual(try repository.load().snapshot().classifications, expected)
    }

    func testRepositoryRejectsStructurallyInvalidCurrentRelationSourceAndRemainsReadable() throws {
        let databaseURL = makeDatabaseURL("classification-source-check")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "来源结构约束", now: now)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "来源分类", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            source: .zhulongSuggestion(
                sessionID: UUID(),
                draftID: UUID(),
                draftVersion: 3,
                evidenceID: UUID()
            ),
            to: engine,
            at: now
        )
        let expected = engine.snapshot().classifications
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(engine)

        XCTAssertThrowsError(
            try executeProbeSQL(
                """
                UPDATE classification_current_relation_facts
                SET source_kind = 'userDirect'
                WHERE chain_id = '\(chainID.description)' AND kind = 'category'
                """,
                at: databaseURL
            )
        )
        XCTAssertEqual(try repository.load().snapshot().classifications, expected)
    }

    private struct ConcurrentRemovalFixture {
        let laterSnapshot: SuntraceSnapshot
        let mergedSnapshot: SuntraceSnapshot
        let earlierChangeRecordID: UUID
        let laterChangeRecordID: UUID
        let earlierHistoryIDs: [UUID]
        let laterHistoryIDs: [UUID]
    }

    private func makeConcurrentRemovalFixture() throws -> ConcurrentRemovalFixture {
        let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
        let baseEngine = SuntraceEngine()
        let firstChainID = try baseEngine.createPoolTask(
            title: "并发移除 A",
            now: fixtureNow
        )
        let secondChainID = try baseEngine.createPoolTask(
            title: "并发移除 B",
            now: fixtureNow.addingTimeInterval(1)
        )
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: firstChainID,
                    category: .new(name: "并发分类", colorHex: "#2A6FDB"),
                    labels: [.new(name: "并发标签", colorHex: "#0E9488")]
                )
            ),
            to: baseEngine,
            at: fixtureNow.addingTimeInterval(2)
        )
        let baseState = baseEngine.snapshot().classifications
        let categoryID = try XCTUnwrap(baseState.currentByChainID[firstChainID]?.categoryID)
        let labelID = try XCTUnwrap(baseState.currentByChainID[firstChainID]?.labelIDs.first)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: secondChainID,
                    category: .existing(categoryID),
                    labels: [.existing(labelID)]
                )
            ),
            to: baseEngine,
            at: fixtureNow.addingTimeInterval(3)
        )

        let baseSnapshot = baseEngine.snapshot()
        let laterEngine = try SuntraceEngine(snapshot: baseSnapshot)
        let laterReceipt = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: firstChainID,
                    category: nil,
                    labels: []
                )
            ),
            to: laterEngine,
            at: fixtureNow.addingTimeInterval(20)
        )
        let laterSnapshot = laterEngine.snapshot()

        let earlierEngine = try SuntraceEngine(snapshot: baseSnapshot)
        let earlierReceipt = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: secondChainID,
                    category: nil,
                    labels: []
                )
            ),
            to: earlierEngine,
            at: fixtureNow.addingTimeInterval(10)
        )
        let earlierSnapshot = earlierEngine.snapshot()
        let earlierEntry = try XCTUnwrap(
            try SyncSnapshotDiffer().journalEntries(
                from: baseSnapshot,
                to: earlierSnapshot,
                changedAt: fixtureNow.addingTimeInterval(10),
                deviceID: SyncDeviceID("classification-earlier")
            ).first { $0.entityType == .classificationCommit }
        )
        let earlierRecord = try SyncRecordMaterializer().record(
            for: earlierEntry,
            in: earlierSnapshot
        )
        let merge = SyncRecordMerger().merge(
            records: [earlierRecord],
            into: laterSnapshot,
            detectedAt: fixtureNow.addingTimeInterval(30)
        )
        XCTAssertEqual(merge.appliedRecordIDs, [earlierRecord.id])
        XCTAssertTrue(merge.waitingRecords.isEmpty)
        XCTAssertTrue(merge.conflicts.isEmpty)
        try merge.snapshot.validateIntegrity()

        return ConcurrentRemovalFixture(
            laterSnapshot: laterSnapshot,
            mergedSnapshot: merge.snapshot,
            earlierChangeRecordID: earlierReceipt.changeRecordID,
            laterChangeRecordID: laterReceipt.changeRecordID,
            earlierHistoryIDs: earlierSnapshot.classifications.relationHistory
                .filter { $0.removedAt == fixtureNow.addingTimeInterval(10) }
                .map(\.id),
            laterHistoryIDs: laterSnapshot.classifications.relationHistory
                .filter { $0.removedAt == fixtureNow.addingTimeInterval(20) }
                .map(\.id)
        )
    }

    @discardableResult
    private func commit(
        _ intent: ClassificationIntent,
        source: ClassificationSource = .userDirect,
        to engine: SuntraceEngine,
        at date: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: source,
            interactionID: UUID(),
            now: date
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: date
        )
    }

    private func makeDatabaseURL(_ stem: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-\(stem)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func assertInvalidStoredValue(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case SQLiteRepositoryError.invalidStoredValue = error else {
            return XCTFail("expected invalid stored value, got \(error)", file: file, line: line)
        }
    }

    private func executeProbeSQL(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed("test probe could not open database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown probe error"
            throw SQLiteRepositoryError.executeFailed(message)
        }
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

    private func rowCount(_ table: String, id: String, at databaseURL: URL) throws -> Int {
        let allowedTables = ["task_categories", "task_labels"]
        guard allowedTables.contains(table), UUID(uuidString: id) != nil else {
            throw SQLiteRepositoryError.invalidStoredValue("invalid test probe identifier")
        }
        return try integerScalar(
            "SELECT COUNT(*) FROM \(table) WHERE id = '\(id)'",
            at: databaseURL
        )
    }
}

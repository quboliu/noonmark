@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncSnapshotDifferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_100)
    private let today = LocalDate("2026-07-05")

    func testNewDomainObjectsBecomePendingUpsertsInDependencyOrder() throws {
        let oldSnapshot = NoonmarkEngine().snapshot()
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同步新增任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try engine.addSubtask(traceID: traceID, title: "新增子任务", difficulty: .medium, now: now)

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: engine.snapshot(),
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(entries.map(\.entityType), [.taskChain, .taskDefinition, .day, .dayTrace, .subtask])
        XCTAssertEqual(Set(entries.map(\.state)), [.pendingUpload])
        XCTAssertEqual(Set(entries.map(\.operation)), [.upsert])
        XCTAssertEqual(Set(entries.map(\.changedAt)), [later])
        XCTAssertEqual(Set(entries.map(\.deviceID)), [SyncDeviceID("mac-a")])
    }

    func testUnchangedSnapshotProducesNoJournalEntries() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "无变化任务", now: now)
        _ = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let snapshot = engine.snapshot()

        XCTAssertTrue(
            try SyncSnapshotDiffer().journalEntries(
                from: snapshot,
                to: snapshot,
                changedAt: later,
                deviceID: SyncDeviceID("mac-a")
            ).isEmpty
        )
    }

    func testReviewSubtaskAndPreferencesChangesAreTrackedAtEntityLevel() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "局部变更任务", now: now)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let subtaskID = try engine.addSubtask(traceID: traceID, title: "调整难度", difficulty: .simple, now: now)
        let oldSnapshot = engine.snapshot()

        engine.updateDailyReview(date: today, summary: "已复盘", unfinishedReason: nil, tomorrowNote: nil, now: later)
        try engine.updateSubtaskDifficulty(subtaskID, difficulty: .hard, today: today)
        engine.updateTheme(.warmPaper)

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: engine.snapshot(),
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(entries.map(\.entityType), [.day, .subtask, .appPreferences])
        XCTAssertEqual(entries.map(\.entityID).last, "default")
    }

    func testPoolNoteEditAndDeleteBecomeCurrentTaskChainSyncRecord() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "附言 journal",
            initialNoteBody: "待编辑",
            now: now
        )
        let editedID = try XCTUnwrap(
            engine.taskPool().first?.chain.activeNoteEntries.first?.id
        )
        let deletedID = try engine.appendPoolNote(
            chainID: chainID,
            body: "待删除",
            now: now.addingTimeInterval(10)
        )
        let oldSnapshot = engine.snapshot()

        try engine.editPoolNote(
            chainID: chainID,
            noteID: editedID,
            body: "编辑完成",
            now: now.addingTimeInterval(20)
        )
        try engine.deletePoolNote(
            chainID: chainID,
            noteID: deletedID,
            now: now.addingTimeInterval(30)
        )
        let newSnapshot = engine.snapshot()
        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )

        XCTAssertEqual(entries.map(\.entityType), [.taskChain])
        let chainEntry = try XCTUnwrap(
            entries.first { $0.entityType == .taskChain }
        )
        let record = try SyncRecordMaterializer().record(
            for: chainEntry,
            in: newSnapshot
        )
        let chain = try SyncRecordMapper().decodeTaskChain(record)

        XCTAssertEqual(record.modifiedAt, now.addingTimeInterval(30))
        XCTAssertEqual(chain.activeNoteEntries.map(\.body), ["编辑完成"])
        XCTAssertNotNil(
            chain.noteEntries.first(where: { $0.id == deletedID })?.deletedAt
        )
    }

    func testTraceClassificationSnapshotTravelsAsImmutableEventAndRoundTrips() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "延续时同步轨迹分类快照", now: now)
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let oldSnapshot = engine.snapshot()
        let tomorrow = LocalDate("2026-07-06")
        _ = try engine.continueTrace(
            traceID: sourceTraceID,
            targetDate: tomorrow,
            today: today,
            now: later
        )
        let newSnapshot = engine.snapshot()

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )
        XCTAssertFalse(entries.contains { $0.entityType == .classificationCommit })
        let sourceEntry = try XCTUnwrap(entries.first {
            $0.entityType == .dayTrace && $0.entityID == sourceTraceID.description
        })
        let sourceRecord = try SyncRecordMaterializer().record(
            for: sourceEntry,
            in: newSnapshot
        )
        let trace = try SyncRecordMapper().decodeDayTrace(sourceRecord)
        XCTAssertEqual(trace.status, .continued)
        let tracePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sourceRecord.payload) as? [String: Any]
        )
        let traceFacts = try XCTUnwrap(tracePayload["payload"] as? [String: Any])
        XCTAssertNil(traceFacts["classificationEvents"])
        XCTAssertNil(traceFacts["classificationRevision"])

        let eventEntry = try XCTUnwrap(entries.first {
            $0.entityType == .traceClassificationEvent
        })
        let eventPayload = try XCTUnwrap(eventEntry.recordPayload)
        let eventEnvelope = try TraceClassificationEventEnvelope.decode(eventPayload)
        XCTAssertEqual(
            eventEnvelope.event,
            newSnapshot.classifications.snapshotEventsByTraceID[sourceTraceID]?.last
        )
        XCTAssertNil(eventEnvelope.predecessorEventID)
        XCTAssertEqual(try eventEnvelope.canonicalData(), eventPayload)

        let records = try SyncRecordMaterializer().records(
            for: entries,
            in: newSnapshot
        )
        let merged = SyncRecordMerger().merge(
            records: records,
            into: oldSnapshot,
            detectedAt: later
        )
        XCTAssertTrue(merged.conflicts.isEmpty, "conflicts=\(merged.conflicts)")
        XCTAssertTrue(
            merged.waitingRecords.isEmpty,
            "waiting=\(merged.waitingRecords.map { ($0.record.id, $0.dependencies) })"
        )
        XCTAssertEqual(merged.snapshot, newSnapshot)
        try merged.snapshot.validateIntegrity()
    }

    func testTraceSnapshotAndInheritedClassificationCommitSyncAtomically() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "变更前任务", now: now)
        try commitClassification(
            engine,
            chainID: chainID,
            category: .new(name: "工程", colorHex: "#2A6FDB"),
            labels: [.new(name: "继承", colorHex: "#0E9488")],
            ordinal: 7
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let oldSnapshot = engine.snapshot()
        _ = try engine.changeTrace(
            traceID: traceID,
            newTitle: "变更后任务",
            today: today,
            now: later
        )
        let newSnapshot = engine.snapshot()

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )
        let commitEntry = try XCTUnwrap(entries.first {
            $0.entityType == .classificationCommit
        })
        let envelope = try ClassificationCommitEnvelope.decode(
            try XCTUnwrap(commitEntry.recordPayload)
        )
        guard case .inherited = envelope.changeRecord.source else {
            return XCTFail("任务变更应产生 inherited 分类提交")
        }
        XCTAssertNil(envelope.receipt)
        XCTAssertTrue(entries.contains {
            $0.entityType == .dayTrace && $0.entityID == traceID.description
        })
        XCTAssertTrue(entries.contains {
            $0.entityType == .traceClassificationEvent
        })

        let records = try SyncRecordMaterializer().records(
            for: entries,
            in: newSnapshot
        )
        let merged = SyncRecordMerger().merge(
            records: records,
            into: oldSnapshot,
            detectedAt: later
        )
        XCTAssertTrue(merged.conflicts.isEmpty, "conflicts=\(merged.conflicts)")
        XCTAssertTrue(
            merged.waitingRecords.isEmpty,
            "waiting=\(merged.waitingRecords.map { ($0.record.id, $0.dependencies) })"
        )
        XCTAssertEqual(merged.snapshot, newSnapshot)
        try merged.snapshot.validateIntegrity()
    }

    func testClassifiedPoolRemovalSyncsAsDeterministicCommitWithoutReceipt() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "同步移出已分类复制任务",
            now: now
        )
        try commitClassification(
            engine,
            chainID: chainID,
            category: .new(name: "工程", colorHex: "#2A6FDB"),
            labels: [.new(name: "复制", colorHex: "#0E9488")],
            ordinal: 9
        )
        let oldSnapshot = engine.snapshot()

        XCTAssertEqual(
            try engine.removeTaskFromPool(
                chainID: chainID,
                now: later.addingTimeInterval(20)
            ),
            .removedKeepingHistory
        )
        let newSnapshot = engine.snapshot()
        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: later.addingTimeInterval(20),
            deviceID: SyncDeviceID("mac-a")
        )
        let commitEntry = try XCTUnwrap(entries.first {
            $0.entityType == .classificationCommit
        })
        let envelope = try ClassificationCommitEnvelope.decode(
            try XCTUnwrap(commitEntry.recordPayload)
        )

        XCTAssertEqual(
            envelope.changeRecord.source,
            .deterministicDomainAction(
                reason: "task removed from task pool while preserving classification history"
            )
        )
        XCTAssertNil(envelope.changeRecord.decisionID)
        XCTAssertNil(envelope.receipt)
        XCTAssertTrue(entries.contains {
            $0.entityType == .taskChain && $0.entityID == chainID.description
        })

        let merged = SyncRecordMerger().merge(
            records: try SyncRecordMaterializer().records(
                for: entries,
                in: newSnapshot
            ),
            into: oldSnapshot,
            detectedAt: later.addingTimeInterval(20)
        )
        XCTAssertTrue(merged.conflicts.isEmpty, "conflicts=\(merged.conflicts)")
        XCTAssertTrue(merged.waitingRecords.isEmpty)
        XCTAssertEqual(merged.snapshot, newSnapshot)
        try merged.snapshot.validateIntegrity()
    }

    func testSingleSetCurrentCommitBecomesImmutableJournalPayload() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "同步 first-class 分类", now: now)
        let oldSnapshot = engine.snapshot()
        let interactionID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        let decisionID = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "同步", colorHex: "#0E9488"),
                        .new(name: "复盘", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: later
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: later
        )

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: engine.snapshot(),
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )
        let entry = try XCTUnwrap(entries.only)
        let payload = try XCTUnwrap(entry.recordPayload)
        let envelope = try ClassificationCommitEnvelope.decode(payload)

        XCTAssertEqual(entry.entityType, .classificationCommit)
        XCTAssertEqual(entry.entityID, receipt.changeRecordID.uuidString)
        XCTAssertEqual(entry.changedAt, later)
        XCTAssertEqual(envelope.changeRecord.id, receipt.changeRecordID)
        XCTAssertEqual(envelope.receipt, receipt)
        XCTAssertEqual(try envelope.canonicalData(), payload)
    }

    func testMultipleUnpersistedClassificationCommitsFailClosed() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "逐笔落盘", now: now)
        let oldSnapshot = engine.snapshot()
        try commitClassification(
            engine,
            chainID: chainID,
            category: .new(name: "工程", colorHex: "#2A6FDB"),
            labels: [.new(name: "同步", colorHex: "#0E9488")],
            ordinal: 1
        )
        let categoryID = try XCTUnwrap(engine.snapshot().classifications.currentByChainID[chainID]?.categoryID)
        try commitClassification(
            engine,
            chainID: chainID,
            category: .existing(categoryID),
            labels: [.new(name: "复盘", colorHex: "#7C5CFF")],
            ordinal: 2
        )

        XCTAssertThrowsError(
            try SyncSnapshotDiffer().journalEntries(
                from: oldSnapshot,
                to: engine.snapshot(),
                changedAt: later,
                deviceID: SyncDeviceID("mac-a")
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncSnapshotDifferError,
                .classificationCommitsMustBePersistedIndividually(count: 2)
            )
        }
    }

    func testClassificationManagementCommitBecomesImmutableJournalPayload() throws {
        let engine = NoonmarkEngine()
        let oldSnapshot = engine.snapshot()
        let plan = try engine.prepareClassification(
            .createLabel(name: "独立标签", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(uuidString: "33000000-0000-0000-0000-000000000001")!,
            now: later
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "33000000-0000-0000-0000-000000000002")!
            ),
            now: later
        )
        let newSnapshot = engine.snapshot()

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: later,
            deviceID: SyncDeviceID("mac-a")
        )
        let entry = try XCTUnwrap(entries.only)
        let payload = try XCTUnwrap(entry.recordPayload)
        let envelope = try ClassificationCommitEnvelope.decode(payload)

        XCTAssertEqual(entry.entityType, .classificationCommit)
        XCTAssertEqual(entry.entityID, receipt.changeRecordID.uuidString)
        XCTAssertEqual(envelope.changeRecord.id, receipt.changeRecordID)
        guard case .create = envelope.delta else {
            return XCTFail("独立标签创建必须编码为 create delta")
        }

        let records = try SyncRecordMaterializer().records(
            for: entries,
            in: newSnapshot
        )
        let merged = SyncRecordMerger().merge(
            records: records,
            into: oldSnapshot,
            detectedAt: later
        )
        XCTAssertTrue(merged.conflicts.isEmpty, "conflicts=\(merged.conflicts)")
        XCTAssertTrue(merged.waitingRecords.isEmpty)
        XCTAssertEqual(merged.snapshot, newSnapshot)
    }

    func testNoOpCommitUsesIdentityDeltaWhenCanonicalAuditOrderChanges() throws {
        let engine = NoonmarkEngine()
        let createPlan = try engine.prepareClassification(
            .createCategory(name: "不变名称", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "34000000-0000-0000-0000-000000000001")!,
            now: later
        )
        _ = try engine.commitClassification(
            createPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "34000000-0000-0000-0000-000000000002")!
            ),
            now: later
        )
        let oldSnapshot = engine.snapshot()
        let categoryID = try XCTUnwrap(oldSnapshot.classifications.categories.keys.first)

        let renamePlan = try engine.prepareClassification(
            .renameCategory(categoryID, to: "不变名称"),
            source: .userDirect,
            interactionID: UUID(uuidString: "34000000-0000-0000-0000-000000000003")!,
            now: now
        )
        let receipt = try engine.commitClassification(
            renamePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "34000000-0000-0000-0000-000000000004")!
            ),
            now: now
        )
        let newSnapshot = engine.snapshot()

        XCTAssertEqual(newSnapshot.classifications.revision, oldSnapshot.classifications.revision)
        XCTAssertEqual(newSnapshot.classifications.changeRecords.first?.id, receipt.changeRecordID)

        let entries = try SyncSnapshotDiffer().journalEntries(
            from: oldSnapshot,
            to: newSnapshot,
            changedAt: now,
            deviceID: SyncDeviceID("mac-a")
        )
        let entry = try XCTUnwrap(entries.only)
        let envelope = try ClassificationCommitEnvelope.decode(
            try XCTUnwrap(entry.recordPayload)
        )
        XCTAssertEqual(envelope.senderBaseRevision, envelope.senderResultRevision)
        guard case .rename = envelope.delta else {
            return XCTFail("精确重命名 no-op 必须保持 rename typed delta")
        }

        let merged = SyncRecordMerger().merge(
            records: try SyncRecordMaterializer().records(for: entries, in: newSnapshot),
            into: oldSnapshot,
            detectedAt: later
        )
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertTrue(merged.waitingRecords.isEmpty)
        XCTAssertEqual(merged.snapshot, newSnapshot)
    }

    func testEveryManagementDeltaKindRoundTripsThroughJournalRecordAndMerge() throws {
        let categoryRename = NoonmarkEngine()
        _ = try commitIntent(
            .createCategory(name: "改名前", colorHex: "#2A6FDB"),
            to: categoryRename,
            ordinal: 101
        )
        let renameCategoryID = try XCTUnwrap(
            categoryRename.snapshot().classifications.categories.keys.first
        )
        try assertIntentRoundTrip(
            .renameCategory(renameCategoryID, to: "改名后"),
            in: categoryRename,
            ordinal: 102
        )

        let labelRename = NoonmarkEngine()
        _ = try commitIntent(
            .createLabel(name: "标签改名前", colorHex: "#0E9488"),
            to: labelRename,
            ordinal: 103
        )
        let renameLabelID = try XCTUnwrap(
            labelRename.snapshot().classifications.labels.keys.first
        )
        try assertIntentRoundTrip(
            .renameLabel(renameLabelID, to: "标签改名后"),
            in: labelRename,
            ordinal: 104
        )

        let categoryLifecycle = NoonmarkEngine()
        _ = try commitIntent(
            .createCategory(name: "待归档主分类", colorHex: "#7C5CFF"),
            to: categoryLifecycle,
            ordinal: 105
        )
        let lifecycleCategoryID = try XCTUnwrap(
            categoryLifecycle.snapshot().classifications.categories.keys.first
        )
        try assertIntentRoundTrip(
            .archiveCategory(lifecycleCategoryID),
            in: categoryLifecycle,
            ordinal: 106
        )

        let labelLifecycle = NoonmarkEngine()
        _ = try commitIntent(
            .createLabel(name: "待归档标签", colorHex: "#D1477A"),
            to: labelLifecycle,
            ordinal: 107
        )
        let lifecycleLabelID = try XCTUnwrap(
            labelLifecycle.snapshot().classifications.labels.keys.first
        )
        try assertIntentRoundTrip(
            .archiveLabel(lifecycleLabelID),
            in: labelLifecycle,
            ordinal: 108
        )

        let categoryMerge = NoonmarkEngine()
        _ = try commitIntent(
            .createCategory(name: "合并来源", colorHex: "#2A6FDB"),
            to: categoryMerge,
            ordinal: 109
        )
        _ = try commitIntent(
            .createCategory(name: "合并目标", colorHex: "#0E9488"),
            to: categoryMerge,
            ordinal: 110
        )
        let categories = categoryMerge.snapshot().classifications.categories
        let sourceCategoryID = try XCTUnwrap(categories.values.first { $0.name == "合并来源" }?.id)
        let targetCategoryID = try XCTUnwrap(categories.values.first { $0.name == "合并目标" }?.id)
        try assertIntentRoundTrip(
            .mergeCategory(source: sourceCategoryID, into: targetCategoryID),
            in: categoryMerge,
            ordinal: 111
        )

        let labelMerge = NoonmarkEngine()
        _ = try commitIntent(
            .createLabel(name: "标签合并来源", colorHex: "#2A6FDB"),
            to: labelMerge,
            ordinal: 112
        )
        _ = try commitIntent(
            .createLabel(name: "标签合并目标", colorHex: "#0E9488"),
            to: labelMerge,
            ordinal: 113
        )
        let labels = labelMerge.snapshot().classifications.labels
        let sourceLabelID = try XCTUnwrap(labels.values.first { $0.name == "标签合并来源" }?.id)
        let targetLabelID = try XCTUnwrap(labels.values.first { $0.name == "标签合并目标" }?.id)
        try assertIntentRoundTrip(
            .mergeLabel(source: sourceLabelID, into: targetLabelID),
            in: labelMerge,
            ordinal: 114
        )

        let categoryDelete = NoonmarkEngine()
        _ = try commitIntent(
            .createCategory(name: "待删除主分类", colorHex: "#AA5500"),
            to: categoryDelete,
            ordinal: 115
        )
        let deleteCategoryID = try XCTUnwrap(
            categoryDelete.snapshot().classifications.categories.keys.first
        )
        try assertIntentRoundTrip(
            .hardDeleteCategory(deleteCategoryID),
            in: categoryDelete,
            ordinal: 116
        )

        let labelDelete = NoonmarkEngine()
        _ = try commitIntent(
            .createLabel(name: "待删除标签", colorHex: "#AA5501"),
            to: labelDelete,
            ordinal: 117
        )
        let deleteLabelID = try XCTUnwrap(
            labelDelete.snapshot().classifications.labels.keys.first
        )
        try assertIntentRoundTrip(
            .hardDeleteLabel(deleteLabelID),
            in: labelDelete,
            ordinal: 118
        )
    }

    @discardableResult
    private func commitIntent(
        _ intent: ClassificationIntent,
        to engine: NoonmarkEngine,
        ordinal: Int
    ) throws -> ClassificationReceipt {
        let time = later.addingTimeInterval(TimeInterval(ordinal))
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(
                uuidString: String(format: "35%06d-0000-0000-0000-000000000001", ordinal)
            )!,
            now: time
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(
                    uuidString: String(format: "35%06d-0000-0000-0000-000000000002", ordinal)
                )!
            ),
            now: time
        )
    }

    private func assertIntentRoundTrip(
        _ intent: ClassificationIntent,
        in engine: NoonmarkEngine,
        ordinal: Int
    ) throws {
        let before = engine.snapshot()
        let receipt = try commitIntent(intent, to: engine, ordinal: ordinal)
        let after = engine.snapshot()
        let entries = try SyncSnapshotDiffer().journalEntries(
            from: before,
            to: after,
            changedAt: later.addingTimeInterval(TimeInterval(ordinal)),
            deviceID: SyncDeviceID("mac-a")
        )
        let entry = try XCTUnwrap(entries.only)
        XCTAssertEqual(entry.entityType, .classificationCommit)
        XCTAssertEqual(entry.entityID, receipt.changeRecordID.uuidString)
        let records = try SyncRecordMaterializer().records(for: entries, in: after)
        let merged = SyncRecordMerger().merge(records: records, into: before)
        XCTAssertTrue(merged.conflicts.isEmpty, "conflicts=\(merged.conflicts)")
        XCTAssertTrue(merged.waitingRecords.isEmpty)
        XCTAssertEqual(merged.snapshot, after)
    }

    private func commitClassification(
        _ engine: NoonmarkEngine,
        chainID: TaskChainID,
        category: TaskCategoryChoice?,
        labels: [TaskLabelChoice],
        ordinal: Int
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: category,
                    labels: labels
                )
            ),
            source: .userDirect,
            interactionID: UUID(
                uuidString: String(format: "32%06d-0000-0000-0000-000000000001", ordinal)
            )!,
            now: later
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(
                    uuidString: String(format: "32%06d-0000-0000-0000-000000000002", ordinal)
                )!
            ),
            now: later.addingTimeInterval(TimeInterval(ordinal))
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

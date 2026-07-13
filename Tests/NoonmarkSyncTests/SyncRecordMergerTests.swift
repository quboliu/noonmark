@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class SyncRecordMergerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")
    private let tomorrow = LocalDate("2026-07-06")

    func testTwoDeviceSyncAppliesNewRecordsThroughGenericTransport() async throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "从 Mac 同步到 iPhone",
            descriptionText: "通用底座记录。",
            now: now
        )
        let traceID = try source.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try source.addSubtask(traceID: traceID, title: "写 mock transport 测试", difficulty: .hard, now: now)

        let mapper = SyncRecordMapper()
        let transport = InMemorySyncTransport()
        try await transport.push(try mapper.records(from: source.snapshot(), modifiedBy: SyncDeviceID("mac-a")))

        let target = NoonmarkEngine()
        let result = await SyncRecordMerger(mapper: mapper).merge(records: try transport.fetchAll(), into: target.snapshot(), detectedAt: now)
        let restored = try NoonmarkEngine(snapshot: result.snapshot)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertFalse(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        XCTAssertEqual(restored.getDayTodo(date: today).traces.first?.id, traceID)
    }

    func testTaskChainNotesMergeByStableIdentityAndTombstone() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "跨设备附言",
            initialNoteBody: "初始附言",
            now: now
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(base.taskPool().first?.chain.activeNoteEntries.first?.id)

        let local = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try local.appendPoolNote(
            chainID: chainID,
            body: "本地新增",
            now: now.addingTimeInterval(10)
        )

        let remote = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try remote.appendPoolNote(
            chainID: chainID,
            body: "远端新增",
            now: now.addingTimeInterval(20)
        )
        try remote.deletePoolNote(
            chainID: chainID,
            noteID: originalNoteID,
            now: now.addingTimeInterval(30)
        )
        let remoteChain = try XCTUnwrap(remote.taskPool().first?.chain)
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: remoteChain,
            modifiedBy: SyncDeviceID("iphone-b")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [record],
            into: local.snapshot(),
            detectedAt: now.addingTimeInterval(40)
        )
        let merged = try NoonmarkEngine(snapshot: result.snapshot)
        let chain = try XCTUnwrap(merged.taskPool().first?.chain)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(chain.activeNoteEntries.map(\.body), ["本地新增", "远端新增"])
        XCTAssertEqual(
            chain.noteEntries.first(where: { $0.id == originalNoteID })?.body,
            ""
        )
        XCTAssertEqual(
            chain.noteEntries.first(where: { $0.id == originalNoteID })?.deletedAt,
            now.addingTimeInterval(30)
        )
    }

    func testPendingTraceNotesMergeByStableIdentityAndTombstone() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "今日跨设备附言",
            initialNoteBody: "初始附言",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(
            base.getDayTodo(date: today).traces.first?.activeNoteEntries.first?.id
        )

        let local = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try local.appendTraceNote(
            traceID: traceID,
            body: "本地新增",
            today: today,
            now: now.addingTimeInterval(10)
        )

        let remote = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try remote.appendTraceNote(
            traceID: traceID,
            body: "远端新增",
            today: today,
            now: now.addingTimeInterval(20)
        )
        try remote.deleteTraceNote(
            traceID: traceID,
            noteID: originalNoteID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let remoteTrace = try XCTUnwrap(
            remote.getDayTodo(date: today).traces.first
        )
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: remoteTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [record],
            into: local.snapshot(),
            detectedAt: now.addingTimeInterval(40)
        )
        let merged = try NoonmarkEngine(snapshot: result.snapshot)
        let trace = try XCTUnwrap(
            merged.getDayTodo(date: today).traces.first
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(trace.activeNoteEntries.map(\.body), ["本地新增", "远端新增"])
        XCTAssertEqual(
            trace.noteEntries.first(where: { $0.id == originalNoteID })?.body,
            ""
        )
        XCTAssertEqual(
            trace.noteEntries.first(where: { $0.id == originalNoteID })?.deletedAt,
            now.addingTimeInterval(30)
        )
    }

    func testCompletedTracePreservesConcurrentPendingNoteAndTombstone() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "完成与附言并发",
            initialNoteBody: "待删除附言",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let baseSnapshot = base.snapshot()
        let originalNoteID = try XCTUnwrap(
            base.traces[traceID]?.activeNoteEntries.first?.id
        )

        let completed = try NoonmarkEngine(snapshot: baseSnapshot)
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let pending = try NoonmarkEngine(snapshot: baseSnapshot)
        _ = try pending.appendTraceNote(
            traceID: traceID,
            body: "并发新增附言",
            today: today,
            now: now.addingTimeInterval(30)
        )
        try pending.deleteTraceNote(
            traceID: traceID,
            noteID: originalNoteID,
            today: today,
            now: now.addingTimeInterval(40)
        )

        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: try XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("completed-device")
        )
        let pendingRecord = try mapper.record(
            for: try XCTUnwrap(pending.traces[traceID]),
            modifiedBy: SyncDeviceID("pending-device")
        )
        var canonicalRecords: [SyncRecord] = []

        for direction in [
            (snapshot: completed.snapshot(), record: pendingRecord),
            (snapshot: pending.snapshot(), record: completedRecord)
        ] {
            let result = SyncRecordMerger(mapper: mapper).merge(
                records: [direction.record],
                into: direction.snapshot,
                detectedAt: now.addingTimeInterval(50)
            )
            let merged = try XCTUnwrap(
                result.snapshot.traces.first { $0.id == traceID }
            )
            let tombstone = try XCTUnwrap(
                merged.noteEntries.first { $0.id == originalNoteID }
            )

            XCTAssertEqual(merged.status, .completed)
            XCTAssertEqual(merged.completedAt, now.addingTimeInterval(20))
            XCTAssertEqual(
                merged.activeNoteEntries.map(\.body),
                ["并发新增附言"]
            )
            XCTAssertTrue(tombstone.isDeleted)
            XCTAssertEqual(tombstone.body, "")
            XCTAssertEqual(tombstone.deletedAt, now.addingTimeInterval(40))
            canonicalRecords.append(try mapper.record(
                for: merged,
                modifiedBy: SyncDeviceID("canonical-device")
            ))
        }

        XCTAssertEqual(canonicalRecords[0], canonicalRecords[1])
    }

    func testMergingOrdinaryRecordPreservesClassificationStateExactly() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "保留本地分类", now: now)
        let plan = try local.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "同步保护", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            now: now
        )
        _ = try local.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let beforeMerge = local.snapshot()

        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: Day(date: tomorrow, now: now.addingTimeInterval(60)),
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [record],
            into: beforeMerge,
            detectedAt: now
        )

        XCTAssertEqual(result.appliedRecordIDs, [record.id])
        XCTAssertEqual(result.snapshot.classifications, beforeMerge.classifications)
    }

    func testFirstClassClassificationCommitSyncsCategoryLabelsAndAuditFacts() throws {
        let fixture = try makeClassificationCommitFixture()
        let mapper = SyncRecordMapper()
        let deviceID = SyncDeviceID("mac-a")
        let chain = try XCTUnwrap(fixture.source.chains[fixture.chainID])
        let chainRecord = try mapper.record(
            for: chain,
            modifiedBy: deviceID
        )
        let definition = try XCTUnwrap(
            fixture.source.snapshot().definitions.first { $0.chainID == fixture.chainID }
        )
        let definitionRecord = try mapper.record(for: definition, modifiedBy: deviceID)
        let classificationRecord = try mapper.record(
            for: fixture.envelope,
            modifiedBy: deviceID
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [classificationRecord, definitionRecord, chainRecord],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now
        )
        let current = try XCTUnwrap(
            result.snapshot.classifications.currentByChainID[fixture.chainID]
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.appliedRecordIDs,
            [chainRecord.id, definitionRecord.id, classificationRecord.id]
        )
        XCTAssertEqual(current.categoryID, fixture.categoryID)
        XCTAssertEqual(current.labelIDs, fixture.labelIDs)
        XCTAssertEqual(current.category?.source, .userDirect)
        XCTAssertTrue(current.labels.allSatisfy { $0.source == .userDirect })
        XCTAssertEqual(current.category?.decisionID, fixture.decisionID)
        XCTAssertEqual(Set(current.labels.compactMap(\.decisionID)), [fixture.decisionID])
        XCTAssertEqual(
            result.snapshot.classifications.changeRecords.last,
            fixture.envelope.changeRecord
        )
        XCTAssertEqual(
            result.snapshot.classifications.committedReceiptsByInteractionID[
                fixture.envelope.changeRecord.interactionID
            ],
            fixture.envelope.receipt
        )
    }

    func testClassificationCommitWithMissingChainRemainsWaiting() throws {
        let fixture = try makeClassificationCommitFixture()
        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: fixture.envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        let first = SyncRecordMerger(mapper: mapper).merge(
            records: [record],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(first.appliedRecordIDs.isEmpty)
        XCTAssertTrue(first.conflicts.isEmpty)
        XCTAssertEqual(
            first.waitingRecords,
            [
                SyncWaitingRecord(
                    record: record,
                    dependencies: [.taskChain(fixture.chainID)]
                )
            ]
        )

        let chain = try XCTUnwrap(fixture.source.chains[fixture.chainID])
        let chainRecord = try mapper.record(
            for: chain,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let retried = SyncRecordMerger(mapper: mapper).merge(
            records: [record, chainRecord],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(retried.waitingRecords.isEmpty)
        XCTAssertTrue(retried.conflicts.isEmpty)
        XCTAssertEqual(
            retried.snapshot.classifications.currentByChainID[fixture.chainID]?.labelIDs,
            fixture.labelIDs
        )
    }

    func testClassificationCommitsApplyInTypedCausalOrderRegardlessOfRecordID() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(title: "分类因果排序", now: now)
        _ = try commitClassification(
            .createCategory(name: "因果 A", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("71000000-0000-0000-0000-000000000001"),
            decisionID: uuid("71000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createCategory(name: "因果 B", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("71000000-0000-0000-0000-000000000003"),
            decisionID: uuid("71000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let categoryAID = try XCTUnwrap(
            source.snapshot().classifications.categories.values.first {
                $0.name == "因果 A"
            }?.id
        )
        let categoryBID = try XCTUnwrap(
            source.snapshot().classifications.categories.values.first {
                $0.name == "因果 B"
            }?.id
        )
        let base = source.snapshot()

        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryAID),
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("71000000-0000-0000-0000-000000000005"),
            decisionID: uuid("71000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let afterA = source.snapshot()
        let originalA = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterA.classifications,
            changeRecord: try XCTUnwrap(afterA.classifications.changeRecords.last)
        )

        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryBID),
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("71000000-0000-0000-0000-000000000007"),
            decisionID: uuid("71000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let afterB = source.snapshot()
        let originalB = try ClassificationCommitEnvelope(
            before: afterA.classifications,
            after: afterB.classifications,
            changeRecord: try XCTUnwrap(afterB.classifications.changeRecords.last)
        )

        let envelopeAID = uuid("F1000000-0000-0000-0000-000000000001")
        let envelopeBID = uuid("01000000-0000-0000-0000-000000000001")
        let envelopeA = try reidentified(originalA, as: envelopeAID)
        let envelopeB = try reidentified(
            originalB,
            as: envelopeBID,
            replacingPredecessorIDs: [originalA.changeRecord.id: envelopeAID]
        )
        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(for: envelopeA, modifiedBy: SyncDeviceID("mac-a"))
        let recordB = try mapper.record(for: envelopeB, modifiedBy: SyncDeviceID("mac-a"))

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [recordB, recordA],
            into: base,
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.appliedRecordIDs, [recordA.id, recordB.id])
        XCTAssertEqual(
            result.snapshot.classifications.currentByChainID[chainID]?.categoryID,
            categoryBID
        )
    }

    func testUnsafeSameBaseCategoryForkFailsClosedBeforeEitherCommitApplies() throws {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(title: "分类分叉", now: now)
        _ = try commitClassification(
            .createCategory(name: "分叉 A", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72000000-0000-0000-0000-000000000001"),
            decisionID: uuid("72000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createCategory(name: "分叉 B", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("72000000-0000-0000-0000-000000000003"),
            decisionID: uuid("72000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let base = source.snapshot()
        let categoryAID = try XCTUnwrap(
            base.classifications.categories.values.first { $0.name == "分叉 A" }?.id
        )
        let categoryBID = try XCTUnwrap(
            base.classifications.categories.values.first { $0.name == "分叉 B" }?.id
        )

        let branchA = try NoonmarkEngine(snapshot: base)
        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryAID),
                    labels: []
                )
            ),
            to: branchA,
            interactionID: uuid("72000000-0000-0000-0000-000000000005"),
            decisionID: uuid("72000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let afterA = branchA.snapshot()
        let envelopeA = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterA.classifications,
            changeRecord: try XCTUnwrap(afterA.classifications.changeRecords.last)
        )

        let branchB = try NoonmarkEngine(snapshot: base)
        _ = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryBID),
                    labels: []
                )
            ),
            to: branchB,
            interactionID: uuid("72000000-0000-0000-0000-000000000007"),
            decisionID: uuid("72000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let afterB = branchB.snapshot()
        let envelopeB = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterB.classifications,
            changeRecord: try XCTUnwrap(afterB.classifications.changeRecords.last)
        )
        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(for: envelopeA, modifiedBy: SyncDeviceID("mac-a"))
        let recordB = try mapper.record(for: envelopeB, modifiedBy: SyncDeviceID("mac-b"))

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [recordA, recordB],
            into: base,
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.conflicts.map(\.type),
            [.classificationCommitRejected, .classificationCommitRejected]
        )
        XCTAssertEqual(result.snapshot, base)
    }

    func testManagementCommitsApplyByExplicitPredecessorRegardlessOfRecordOrder() throws {
        let source = NoonmarkEngine()
        let base = source.snapshot()
        let createReceipt = try commitClassification(
            .createCategory(name: "管理因果", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72100000-0000-0000-0000-000000000001"),
            decisionID: uuid("72100000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let afterCreate = source.snapshot()
        let createRecord = try XCTUnwrap(
            afterCreate.classifications.changeRecords.first {
                $0.id == createReceipt.changeRecordID
            }
        )
        let createEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterCreate.classifications,
            changeRecord: createRecord
        )
        let categoryID = try XCTUnwrap(afterCreate.classifications.categories.keys.first)

        let renameReceipt = try commitClassification(
            .renameCategory(categoryID, to: "管理因果 v2"),
            to: source,
            interactionID: uuid("72100000-0000-0000-0000-000000000003"),
            decisionID: uuid("72100000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let afterRename = source.snapshot()
        let renameRecord = try XCTUnwrap(
            afterRename.classifications.changeRecords.first {
                $0.id == renameReceipt.changeRecordID
            }
        )
        let renameEnvelope = try ClassificationCommitEnvelope(
            before: afterCreate.classifications,
            after: afterRename.classifications,
            changeRecord: renameRecord
        )
        XCTAssertEqual(
            renameEnvelope.delta.mutation.predecessorChangeRecordIDs,
            [createReceipt.changeRecordID]
        )

        let archiveReceipt = try commitClassification(
            .archiveCategory(categoryID),
            to: source,
            interactionID: uuid("72100000-0000-0000-0000-000000000005"),
            decisionID: uuid("72100000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let afterArchive = source.snapshot()
        let archiveEnvelope = try ClassificationCommitEnvelope(
            before: afterRename.classifications,
            after: afterArchive.classifications,
            changeRecord: try XCTUnwrap(
                afterArchive.classifications.changeRecords.first {
                    $0.id == archiveReceipt.changeRecordID
                }
            )
        )
        XCTAssertEqual(
            archiveEnvelope.delta.mutation.predecessorChangeRecordIDs,
            [renameReceipt.changeRecordID]
        )

        let mapper = SyncRecordMapper()
        let createSyncRecord = try mapper.record(
            for: createEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let renameSyncRecord = try mapper.record(
            for: renameEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let archiveSyncRecord = try mapper.record(
            for: archiveEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [archiveSyncRecord, renameSyncRecord, createSyncRecord],
            into: base,
            detectedAt: now.addingTimeInterval(4)
        )

        XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.appliedRecordIDs,
            [createSyncRecord.id, renameSyncRecord.id, archiveSyncRecord.id]
        )
        XCTAssertEqual(result.snapshot, afterArchive)
    }

    func testManagementCausalClosureAppliesThreeStageChainAcrossPermutations() throws {
        let fixture = try makeManagementCausalFixture()
        let permutations = [
            [fixture.firstRecord, fixture.secondRecord, fixture.thirdRecord],
            [fixture.thirdRecord, fixture.firstRecord, fixture.secondRecord],
            [fixture.secondRecord, fixture.thirdRecord, fixture.firstRecord]
        ]

        for records in permutations {
            let result = SyncRecordMerger().merge(
                records: records,
                into: fixture.base,
                detectedAt: now.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.appliedRecordIDs.count, 3)
            XCTAssertEqual(result.snapshot, fixture.final)
        }
    }

    func testManagementCommitWithMissingMiddlePredecessorWaitsWithoutRejectingAncestor() throws {
        let fixture = try makeManagementCausalFixture()
        let result = SyncRecordMerger().merge(
            records: [fixture.thirdRecord, fixture.firstRecord],
            into: fixture.base,
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
        XCTAssertEqual(result.appliedRecordIDs, [fixture.firstRecord.id])
        XCTAssertEqual(result.waitingRecords.count, 1)
        let waiting = try XCTUnwrap(result.waitingRecords.first)
        XCTAssertEqual(waiting.record, fixture.thirdRecord)
        XCTAssertEqual(
            waiting.dependencies,
            [.classificationCommit(fixture.secondChangeRecordID)]
        )
        XCTAssertEqual(result.snapshot, fixture.afterFirst)
    }

    func testIndependentManagementCommitsConvergeAcrossInputPermutations() throws {
        let base = NoonmarkEngine().snapshot()
        let categoryBranch = try NoonmarkEngine(snapshot: base)
        let categoryReceipt = try commitClassification(
            .createCategory(name: "并发领域", colorHex: "#2A6FDB"),
            to: categoryBranch,
            interactionID: uuid("72200000-0000-0000-0000-000000000001"),
            decisionID: uuid("72200000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let categoryAfter = categoryBranch.snapshot()
        let categoryEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: categoryAfter.classifications,
            changeRecord: try XCTUnwrap(categoryAfter.classifications.changeRecords.first {
                $0.id == categoryReceipt.changeRecordID
            })
        )

        let labelBranch = try NoonmarkEngine(snapshot: base)
        let labelReceipt = try commitClassification(
            .createLabel(name: "并发标签", colorHex: "#0E9488"),
            to: labelBranch,
            interactionID: uuid("72200000-0000-0000-0000-000000000003"),
            decisionID: uuid("72200000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let labelAfter = labelBranch.snapshot()
        let labelEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: labelAfter.classifications,
            changeRecord: try XCTUnwrap(labelAfter.classifications.changeRecords.first {
                $0.id == labelReceipt.changeRecordID
            })
        )

        let mapper = SyncRecordMapper()
        let categoryRecord = try mapper.record(
            for: categoryEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let labelRecord = try mapper.record(
            for: labelEnvelope,
            modifiedBy: SyncDeviceID("mac-b")
        )
        let merger = SyncRecordMerger(mapper: mapper)
        let forward = merger.merge(
            records: [categoryRecord, labelRecord],
            into: base,
            detectedAt: now.addingTimeInterval(3)
        )
        let reverse = merger.merge(
            records: [labelRecord, categoryRecord],
            into: base,
            detectedAt: now.addingTimeInterval(3)
        )

        XCTAssertTrue(forward.conflicts.isEmpty, "conflicts=\(forward.conflicts)")
        XCTAssertTrue(forward.waitingRecords.isEmpty)
        XCTAssertEqual(reverse.snapshot, forward.snapshot)
        XCTAssertEqual(reverse.appliedRecordIDs, forward.appliedRecordIDs)
        XCTAssertEqual(forward.snapshot.classifications.categories.count, 1)
        XCTAssertEqual(forward.snapshot.classifications.labels.count, 1)
        XCTAssertEqual(
            Set(forward.snapshot.classifications.changeRecords.map(\.id)),
            Set([categoryReceipt.changeRecordID, labelReceipt.changeRecordID])
        )
        XCTAssertEqual(forward.snapshot.classifications.revision, 2)
    }

    func testConcurrentLabelAdditionsConvergeAcrossMergerPermutations() throws {
        let baseEngine = NoonmarkEngine()
        let chainID = try baseEngine.createPoolTask(title: "并发标签", now: now)
        let base = baseEngine.snapshot()

        func labelEnvelope(
            name: String,
            colorHex: String,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> ClassificationCommitEnvelope {
            let branch = try NoonmarkEngine(snapshot: base)
            let receipt = try commitClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: nil,
                        labels: [.new(name: name, colorHex: colorHex)]
                    )
                ),
                to: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let after = branch.snapshot()
            return try ClassificationCommitEnvelope(
                before: base.classifications,
                after: after.classifications,
                changeRecord: try XCTUnwrap(after.classifications.changeRecords.first {
                    $0.id == receipt.changeRecordID
                })
            )
        }

        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(
            for: labelEnvelope(
                name: "标签 A",
                colorHex: "#2A6FDB",
                interactionID: uuid("72210000-0000-0000-0000-000000000001"),
                decisionID: uuid("72210000-0000-0000-0000-000000000002"),
                at: now.addingTimeInterval(1)
            ),
            modifiedBy: SyncDeviceID("mac-a")
        )
        let recordB = try mapper.record(
            for: labelEnvelope(
                name: "标签 B",
                colorHex: "#0E9488",
                interactionID: uuid("72210000-0000-0000-0000-000000000003"),
                decisionID: uuid("72210000-0000-0000-0000-000000000004"),
                at: now.addingTimeInterval(2)
            ),
            modifiedBy: SyncDeviceID("mac-b")
        )
        let merger = SyncRecordMerger(mapper: mapper)
        let forward = merger.merge(records: [recordA, recordB], into: base)
        let reverse = merger.merge(records: [recordB, recordA], into: base)

        XCTAssertTrue(forward.conflicts.isEmpty, "conflicts=\(forward.conflicts)")
        XCTAssertTrue(forward.waitingRecords.isEmpty)
        XCTAssertEqual(reverse.snapshot, forward.snapshot)
        XCTAssertEqual(
            forward.snapshot.classifications.currentByChainID[chainID]?.labelIDs.count,
            2
        )
        XCTAssertEqual(forward.snapshot.classifications.labels.count, 2)
    }

    func testConcurrentSelectionHeadsFormCompleteCausalFrontierAcrossPermutations() throws {
        let fixture = try makeConcurrentSelectionFrontierFixture()
        XCTAssertEqual(
            Set(fixture.successorEnvelope.delta.mutation.predecessorChangeRecordIDs),
            Set([fixture.changeRecordIDA, fixture.changeRecordIDB])
        )

        let permutations = [
            [fixture.recordA, fixture.recordB, fixture.successorRecord],
            [fixture.recordA, fixture.successorRecord, fixture.recordB],
            [fixture.recordB, fixture.recordA, fixture.successorRecord],
            [fixture.recordB, fixture.successorRecord, fixture.recordA],
            [fixture.successorRecord, fixture.recordA, fixture.recordB],
            [fixture.successorRecord, fixture.recordB, fixture.recordA]
        ]
        let merger = SyncRecordMerger()
        for records in permutations {
            let result = merger.merge(records: records, into: fixture.base)
            XCTAssertTrue(result.conflicts.isEmpty, "input=\(records.map(\.id))")
            XCTAssertTrue(result.waitingRecords.isEmpty, "input=\(records.map(\.id))")
            XCTAssertEqual(result.appliedRecordIDs.count, 3)
            XCTAssertEqual(result.snapshot, fixture.final)
        }
    }

    func testSuccessorWaitsForEveryConcurrentSelectionHeadAcrossPages() throws {
        let fixture = try makeConcurrentSelectionFrontierFixture()
        let merger = SyncRecordMerger()

        let partial = merger.merge(
            records: [fixture.recordB, fixture.successorRecord],
            into: fixture.base
        )

        XCTAssertTrue(partial.conflicts.isEmpty, "conflicts=\(partial.conflicts)")
        XCTAssertEqual(partial.appliedRecordIDs, [fixture.recordB.id])
        XCTAssertEqual(partial.snapshot, fixture.afterB)
        XCTAssertEqual(partial.waitingRecords.count, 1)
        XCTAssertEqual(partial.waitingRecords.first?.record, fixture.successorRecord)
        XCTAssertEqual(
            partial.waitingRecords.first?.dependencies,
            [.classificationCommit(fixture.changeRecordIDA)]
        )

        let resumed = merger.merge(
            records: [fixture.successorRecord, fixture.recordA],
            into: partial.snapshot
        )
        XCTAssertTrue(resumed.conflicts.isEmpty, "conflicts=\(resumed.conflicts)")
        XCTAssertTrue(resumed.waitingRecords.isEmpty)
        XCTAssertEqual(resumed.appliedRecordIDs.count, 2)
        XCTAssertEqual(resumed.snapshot, fixture.final)
    }

    func testRenameCommutesWithCategoryAndLabelRelationWrites() throws {
        struct Fixture {
            let kind: ClassificationItemKind
            let itemID: String
            let renamedTo: String
            let base: NoonmarkSnapshot
            let rename: ClassificationCommitEnvelope
            let relation: ClassificationCommitEnvelope
            let chainID: TaskChainID
        }

        func fixture(for kind: ClassificationItemKind) throws -> Fixture {
            let source = NoonmarkEngine()
            let chainID = try source.createPoolTask(title: "rename relation", now: now)
            let createIntent: ClassificationIntent = switch kind {
            case .category:
                .createCategory(name: "关系主分类", colorHex: "#2A6FDB")
            case .label:
                .createLabel(name: "关系标签", colorHex: "#0E9488")
            }
            _ = try commitClassification(
                createIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(1)
            )
            let base = source.snapshot()
            let renamedTo = kind == .category ? "关系主分类 v2" : "关系标签 v2"

            let renameBranch = try NoonmarkEngine(snapshot: base)
            let renameIntent: ClassificationIntent
            let relationIntent: ClassificationIntent
            let itemID: String
            switch kind {
            case .category:
                let id = try XCTUnwrap(base.classifications.categories.keys.first)
                renameIntent = .renameCategory(id, to: renamedTo)
                relationIntent = .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .existing(id),
                        labels: []
                    )
                )
                itemID = id.description
            case .label:
                let id = try XCTUnwrap(base.classifications.labels.keys.first)
                renameIntent = .renameLabel(id, to: renamedTo)
                relationIntent = .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: nil,
                        labels: [.existing(id)]
                    )
                )
                itemID = id.description
            }
            let renameReceipt = try commitClassification(
                renameIntent,
                to: renameBranch,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(2)
            )
            let renamed = renameBranch.snapshot()
            let renameEnvelope = try ClassificationCommitEnvelope(
                before: base.classifications,
                after: renamed.classifications,
                changeRecord: try XCTUnwrap(renamed.classifications.changeRecords.first {
                    $0.id == renameReceipt.changeRecordID
                })
            )

            let relationBranch = try NoonmarkEngine(snapshot: base)
            let relationReceipt = try commitClassification(
                relationIntent,
                to: relationBranch,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(3)
            )
            let related = relationBranch.snapshot()
            return Fixture(
                kind: kind,
                itemID: itemID,
                renamedTo: renamedTo,
                base: base,
                rename: renameEnvelope,
                relation: try ClassificationCommitEnvelope(
                    before: base.classifications,
                    after: related.classifications,
                    changeRecord: try XCTUnwrap(related.classifications.changeRecords.first {
                        $0.id == relationReceipt.changeRecordID
                    })
                ),
                chainID: chainID
            )
        }

        let mapper = SyncRecordMapper()
        for kind in [ClassificationItemKind.category, .label] {
            let fixture = try fixture(for: kind)
            let renameRecord = try mapper.record(
                for: fixture.rename,
                modifiedBy: SyncDeviceID("mac-a")
            )
            let relationRecord = try mapper.record(
                for: fixture.relation,
                modifiedBy: SyncDeviceID("mac-b")
            )
            let merger = SyncRecordMerger(mapper: mapper)
            let forward = merger.merge(
                records: [renameRecord, relationRecord],
                into: fixture.base
            )
            let reverse = merger.merge(
                records: [relationRecord, renameRecord],
                into: fixture.base
            )

            XCTAssertTrue(forward.conflicts.isEmpty, "conflicts=\(forward.conflicts)")
            XCTAssertTrue(forward.waitingRecords.isEmpty)
            XCTAssertEqual(reverse.snapshot, forward.snapshot)
            switch fixture.kind {
            case .category:
                let id = TaskCategoryID(try XCTUnwrap(UUID(uuidString: fixture.itemID)))
                XCTAssertEqual(forward.snapshot.classifications.categories[id]?.name, fixture.renamedTo)
                XCTAssertEqual(
                    forward.snapshot.classifications.currentByChainID[fixture.chainID]?.categoryID,
                    id
                )
            case .label:
                let id = TaskLabelID(try XCTUnwrap(UUID(uuidString: fixture.itemID)))
                XCTAssertEqual(forward.snapshot.classifications.labels[id]?.name, fixture.renamedTo)
                XCTAssertEqual(
                    forward.snapshot.classifications.currentByChainID[fixture.chainID]?.labelIDs,
                    [id]
                )
            }
        }
    }

    func testRenameConflictsWithConcurrentMergeForSourceAndTargetAcrossPermutations() throws {
        for kind in [ClassificationItemKind.category, .label] {
            for renamedRole in [MergeItemRole.source, .target] {
                let fixture = try makeRenameMergeFixture(
                    kind: kind,
                    renamedRole: renamedRole
                )
                for records in [
                    [fixture.renameRecord, fixture.mergeRecord],
                    [fixture.mergeRecord, fixture.renameRecord]
                ] {
                    let result = SyncRecordMerger().merge(
                        records: records,
                        into: fixture.base
                    )
                    XCTAssertEqual(
                        result.conflicts.map(\.type),
                        [.classificationCommitRejected, .classificationCommitRejected],
                        "kind=\(kind), role=\(renamedRole), input=\(records.map(\.id))"
                    )
                    XCTAssertTrue(result.appliedRecordIDs.isEmpty)
                    XCTAssertTrue(result.waitingRecords.isEmpty)
                    XCTAssertEqual(result.snapshot, fixture.base)
                }
            }
        }
    }

    func testTargetRenameAfterMergeUsesExplicitCausalityAcrossArrivalOrders() throws {
        for kind in [ClassificationItemKind.category, .label] {
            let scenario = try makeMergeScenario(kind: kind)
            let source = try NoonmarkEngine(snapshot: scenario.base)
            let mergeReceipt = try commitClassification(
                scenario.items.mergeIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(12)
            )
            let afterMerge = source.snapshot()
            let mergeEnvelope = try ClassificationCommitEnvelope(
                before: scenario.base.classifications,
                after: afterMerge.classifications,
                changeRecord: try XCTUnwrap(afterMerge.classifications.changeRecords.first {
                    $0.id == mergeReceipt.changeRecordID
                })
            )

            let renameReceipt = try commitClassification(
                scenario.items.renameIntent(for: .target),
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(13)
            )
            let final = source.snapshot()
            let renameEnvelope = try ClassificationCommitEnvelope(
                before: afterMerge.classifications,
                after: final.classifications,
                changeRecord: try XCTUnwrap(final.classifications.changeRecords.first {
                    $0.id == renameReceipt.changeRecordID
                })
            )
            XCTAssertTrue(
                renameEnvelope.delta.mutation.predecessorChangeRecordIDs.contains(
                    mergeEnvelope.changeRecord.id
                )
            )

            let mapper = SyncRecordMapper()
            let mergeRecord = try mapper.record(
                for: mergeEnvelope,
                modifiedBy: SyncDeviceID("mac-merge")
            )
            let renameRecord = try mapper.record(
                for: renameEnvelope,
                modifiedBy: SyncDeviceID("mac-rename")
            )
            for records in [[renameRecord, mergeRecord], [mergeRecord, renameRecord]] {
                let result = SyncRecordMerger().merge(
                    records: records,
                    into: scenario.base
                )
                XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
                XCTAssertTrue(result.waitingRecords.isEmpty)
                XCTAssertEqual(result.appliedRecordIDs, [mergeRecord.id, renameRecord.id])
                XCTAssertEqual(result.snapshot, final)
            }
        }
    }

    func testExactRenameNoOpCommutesWithLaterRealRename() throws {
        let source = NoonmarkEngine()
        let createReceipt = try commitClassification(
            .createCategory(name: "纯审计名称", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72220000-0000-0000-0000-000000000001"),
            decisionID: uuid("72220000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(10)
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)

        let noOpReceipt = try commitClassification(
            .renameCategory(categoryID, to: "纯审计名称"),
            to: source,
            interactionID: uuid("72220000-0000-0000-0000-000000000003"),
            decisionID: uuid("72220000-0000-0000-0000-000000000004"),
            at: now
        )
        let afterNoOp = source.snapshot()
        let noOpEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterNoOp.classifications,
            changeRecord: try XCTUnwrap(afterNoOp.classifications.changeRecords.first {
                $0.id == noOpReceipt.changeRecordID
            })
        )
        XCTAssertTrue(noOpEnvelope.isAuditOnlyNoOpRename)

        let renameReceipt = try commitClassification(
            .renameCategory(categoryID, to: "纯审计名称 v2"),
            to: source,
            interactionID: uuid("72220000-0000-0000-0000-000000000005"),
            decisionID: uuid("72220000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(20)
        )
        let final = source.snapshot()
        let renameEnvelope = try ClassificationCommitEnvelope(
            before: afterNoOp.classifications,
            after: final.classifications,
            changeRecord: try XCTUnwrap(final.classifications.changeRecords.first {
                $0.id == renameReceipt.changeRecordID
            })
        )
        XCTAssertEqual(
            renameEnvelope.delta.mutation.predecessorChangeRecordIDs,
            [createReceipt.changeRecordID]
        )

        let mapper = SyncRecordMapper()
        let noOpRecord = try mapper.record(
            for: noOpEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let renameRecord = try mapper.record(
            for: renameEnvelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let merger = SyncRecordMerger(mapper: mapper)
        for records in [[noOpRecord, renameRecord], [renameRecord, noOpRecord]] {
            let result = merger.merge(records: records, into: base)
            XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.appliedRecordIDs.count, 2)
            XCTAssertEqual(result.snapshot, final)
        }
    }

    func testReleasedCanonicalOwnershipOrdersCategoryAndLabelRecreation() throws {
        for kind in [ClassificationItemKind.category, .label] {
            let source = NoonmarkEngine()
            let createIntent: ClassificationIntent = switch kind {
            case .category:
                .createCategory(name: "历史别名", colorHex: "#2A6FDB")
            case .label:
                .createLabel(name: "历史别名", colorHex: "#0E9488")
            }
            _ = try commitClassification(
                createIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(1)
            )
            let created = source.snapshot()

            let renameIntent: ClassificationIntent
            let hardDeleteIntent: ClassificationIntent
            switch kind {
            case .category:
                let id = try XCTUnwrap(created.classifications.categories.keys.first)
                renameIntent = .renameCategory(id, to: "当前名称")
                hardDeleteIntent = .hardDeleteCategory(id)
            case .label:
                let id = try XCTUnwrap(created.classifications.labels.keys.first)
                renameIntent = .renameLabel(id, to: "当前名称")
                hardDeleteIntent = .hardDeleteLabel(id)
            }
            _ = try commitClassification(
                renameIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(2)
            )
            let base = source.snapshot()

            let deleteReceipt = try commitClassification(
                hardDeleteIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(3)
            )
            let afterDelete = source.snapshot()
            let deleteEnvelope = try ClassificationCommitEnvelope(
                before: base.classifications,
                after: afterDelete.classifications,
                changeRecord: try XCTUnwrap(afterDelete.classifications.changeRecords.first {
                    $0.id == deleteReceipt.changeRecordID
                })
            )

            let recreateIntent: ClassificationIntent = switch kind {
            case .category:
                .createCategory(name: "  历史别名  ", colorHex: "#7C5CFF")
            case .label:
                .createLabel(name: "  历史别名  ", colorHex: "#D1477A")
            }
            let recreateReceipt = try commitClassification(
                recreateIntent,
                to: source,
                interactionID: UUID(),
                decisionID: UUID(),
                at: now.addingTimeInterval(4)
            )
            let final = source.snapshot()
            let recreateEnvelope = try ClassificationCommitEnvelope(
                before: afterDelete.classifications,
                after: final.classifications,
                changeRecord: try XCTUnwrap(final.classifications.changeRecords.first {
                    $0.id == recreateReceipt.changeRecordID
                })
            )
            XCTAssertTrue(
                recreateEnvelope.delta.mutation.predecessorChangeRecordIDs.contains(
                    deleteReceipt.changeRecordID
                )
            )

            let mapper = SyncRecordMapper()
            let deleteRecord = try mapper.record(
                for: deleteEnvelope,
                modifiedBy: SyncDeviceID("mac-a")
            )
            let recreateRecord = try mapper.record(
                for: recreateEnvelope,
                modifiedBy: SyncDeviceID("mac-a")
            )
            let result = SyncRecordMerger(mapper: mapper).merge(
                records: [recreateRecord, deleteRecord],
                into: base
            )

            XCTAssertTrue(result.conflicts.isEmpty, "conflicts=\(result.conflicts)")
            XCTAssertTrue(result.waitingRecords.isEmpty)
            XCTAssertEqual(result.appliedRecordIDs, [deleteRecord.id, recreateRecord.id])
            XCTAssertEqual(result.snapshot, final)
        }
    }

    func testConcurrentManagementForkFailsClosedBeforeEitherCommitApplies() throws {
        let source = NoonmarkEngine()
        _ = try commitClassification(
            .createCategory(name: "并发管理基础", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72300000-0000-0000-0000-000000000001"),
            decisionID: uuid("72300000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)

        func renameEnvelope(
            to name: String,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> ClassificationCommitEnvelope {
            let branch = try NoonmarkEngine(snapshot: base)
            let receipt = try commitClassification(
                .renameCategory(categoryID, to: name),
                to: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let after = branch.snapshot()
            return try ClassificationCommitEnvelope(
                before: base.classifications,
                after: after.classifications,
                changeRecord: try XCTUnwrap(after.classifications.changeRecords.first {
                    $0.id == receipt.changeRecordID
                })
            )
        }

        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(
            for: renameEnvelope(
                to: "并发管理 A",
                interactionID: uuid("72300000-0000-0000-0000-000000000003"),
                decisionID: uuid("72300000-0000-0000-0000-000000000004"),
                at: now.addingTimeInterval(2)
            ),
            modifiedBy: SyncDeviceID("mac-a")
        )
        let recordB = try mapper.record(
            for: renameEnvelope(
                to: "并发管理 B",
                interactionID: uuid("72300000-0000-0000-0000-000000000005"),
                decisionID: uuid("72300000-0000-0000-0000-000000000006"),
                at: now.addingTimeInterval(3)
            ),
            modifiedBy: SyncDeviceID("mac-b")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [recordB, recordA],
            into: base,
            detectedAt: now.addingTimeInterval(4)
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.conflicts.map(\.type),
            [.classificationCommitRejected, .classificationCommitRejected]
        )
        XCTAssertEqual(result.snapshot, base)
    }

    func testTerminalForkRejectionPropagatesToCausalDescendants() throws {
        let baseEngine = NoonmarkEngine()
        let chainID = try baseEngine.createPoolTask(title: "terminal fork", now: now)
        let base = baseEngine.snapshot()

        let firstBranch = try NoonmarkEngine(snapshot: base)
        let createReceipt = try commitClassification(
            .createCategory(name: "冲突名称", colorHex: "#2A6FDB"),
            to: firstBranch,
            interactionID: uuid("72500000-0000-0000-0000-000000000001"),
            decisionID: uuid("72500000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let afterCreate = firstBranch.snapshot()
        let createEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterCreate.classifications,
            changeRecord: try XCTUnwrap(afterCreate.classifications.changeRecords.first {
                $0.id == createReceipt.changeRecordID
            })
        )
        let categoryID = try XCTUnwrap(afterCreate.classifications.categories.keys.first)

        let setCurrentReceipt = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            to: firstBranch,
            interactionID: uuid("72500000-0000-0000-0000-000000000003"),
            decisionID: uuid("72500000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let afterSetCurrent = firstBranch.snapshot()
        let setCurrentEnvelope = try ClassificationCommitEnvelope(
            before: afterCreate.classifications,
            after: afterSetCurrent.classifications,
            changeRecord: try XCTUnwrap(afterSetCurrent.classifications.changeRecords.first {
                $0.id == setCurrentReceipt.changeRecordID
            })
        )
        let competingBranch = try NoonmarkEngine(snapshot: base)
        let competingReceipt = try commitClassification(
            .createCategory(name: "  冲突名称  ", colorHex: "#0E9488"),
            to: competingBranch,
            interactionID: uuid("72500000-0000-0000-0000-000000000005"),
            decisionID: uuid("72500000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let competingAfter = competingBranch.snapshot()
        let competingEnvelope = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: competingAfter.classifications,
            changeRecord: try XCTUnwrap(competingAfter.classifications.changeRecords.first {
                $0.id == competingReceipt.changeRecordID
            })
        )

        let mapper = SyncRecordMapper()
        let records = try [setCurrentEnvelope, competingEnvelope, createEnvelope].map {
            try mapper.record(for: $0, modifiedBy: SyncDeviceID("mac-a"))
        }
        let result = SyncRecordMerger(mapper: mapper).merge(records: records, into: base)

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, 3)
        XCTAssertEqual(Set(result.conflicts.map(\.type)), [.classificationCommitRejected])
        XCTAssertEqual(result.snapshot, base)
    }

    func testRuntimeClassificationRejectionPropagatesToExplicitCausalDescendants() throws {
        let source = NoonmarkEngine()
        _ = try commitClassification(
            .createCategory(name: "运行时冲突基础", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72510000-0000-0000-0000-000000000001"),
            decisionID: uuid("72510000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)

        let sender = try NoonmarkEngine(snapshot: base)
        let beforeFirst = sender.snapshot().classifications
        let firstReceipt = try commitClassification(
            .renameCategory(categoryID, to: "发送端第一版"),
            to: sender,
            interactionID: uuid("72510000-0000-0000-0000-000000000003"),
            decisionID: uuid("72510000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let afterFirst = sender.snapshot().classifications
        let firstEnvelope = try ClassificationCommitEnvelope(
            before: beforeFirst,
            after: afterFirst,
            changeRecord: try XCTUnwrap(afterFirst.changeRecords.first {
                $0.id == firstReceipt.changeRecordID
            })
        )

        let secondReceipt = try commitClassification(
            .renameCategory(categoryID, to: "发送端第二版"),
            to: sender,
            interactionID: uuid("72510000-0000-0000-0000-000000000005"),
            decisionID: uuid("72510000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let afterSecond = sender.snapshot().classifications
        let secondEnvelope = try ClassificationCommitEnvelope(
            before: afterFirst,
            after: afterSecond,
            changeRecord: try XCTUnwrap(afterSecond.changeRecords.first {
                $0.id == secondReceipt.changeRecordID
            })
        )
        XCTAssertTrue(
            secondEnvelope.delta.mutation.predecessorChangeRecordIDs.contains(
                firstReceipt.changeRecordID
            )
        )

        let receiver = try NoonmarkEngine(snapshot: base)
        _ = try commitClassification(
            .renameCategory(categoryID, to: "接收端胜出版本"),
            to: receiver,
            interactionID: uuid("72510000-0000-0000-0000-000000000007"),
            decisionID: uuid("72510000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let receiverSnapshot = receiver.snapshot()
        let mapper = SyncRecordMapper()
        let firstRecord = try mapper.record(
            for: firstEnvelope,
            modifiedBy: SyncDeviceID("mac-sender")
        )
        let secondRecord = try mapper.record(
            for: secondEnvelope,
            modifiedBy: SyncDeviceID("mac-sender")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [secondRecord, firstRecord],
            into: receiverSnapshot,
            detectedAt: now.addingTimeInterval(5)
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            Set(result.conflicts.map(\.remoteRecordID)),
            Set([firstRecord.id, secondRecord.id])
        )
        XCTAssertEqual(
            Set(result.conflicts.map(\.type)),
            [.classificationCommitRejected]
        )
        XCTAssertEqual(result.snapshot, receiverSnapshot)
    }

    func testClassificationCycleIsRejectedBeforeForkEvaluation() throws {
        let source = NoonmarkEngine()
        _ = try commitClassification(
            .createCategory(name: "循环基础", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72600000-0000-0000-0000-000000000001"),
            decisionID: uuid("72600000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)

        func envelope(
            for intent: ClassificationIntent,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> (snapshot: NoonmarkSnapshot, envelope: ClassificationCommitEnvelope) {
            let branch = try NoonmarkEngine(snapshot: base)
            let receipt = try commitClassification(
                intent,
                to: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let after = branch.snapshot()
            return (
                after,
                try ClassificationCommitEnvelope(
                    before: base.classifications,
                    after: after.classifications,
                    changeRecord: try XCTUnwrap(after.classifications.changeRecords.first {
                        $0.id == receipt.changeRecordID
                    })
                )
            )
        }

        let renameA = try envelope(
            for: .renameCategory(categoryID, to: "循环 A"),
            interactionID: uuid("72600000-0000-0000-0000-000000000003"),
            decisionID: uuid("72600000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let labelB = try envelope(
            for: .createLabel(name: "循环 B", colorHex: "#0E9488"),
            interactionID: uuid("72600000-0000-0000-0000-000000000005"),
            decisionID: uuid("72600000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let renameC = try envelope(
            for: .renameCategory(categoryID, to: "循环 C"),
            interactionID: uuid("72600000-0000-0000-0000-000000000007"),
            decisionID: uuid("72600000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let cyclicA = try replacingPredecessors(
            in: renameA.envelope,
            with: [labelB.envelope.changeRecord.id]
        )
        let cyclicB = try replacingPredecessors(
            in: labelB.envelope,
            with: [renameA.envelope.changeRecord.id]
        )
        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(for: cyclicA, modifiedBy: SyncDeviceID("mac-a"))
        let recordB = try mapper.record(for: cyclicB, modifiedBy: SyncDeviceID("mac-b"))
        let recordC = try mapper.record(
            for: renameC.envelope,
            modifiedBy: SyncDeviceID("mac-c")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [recordC, recordB, recordA],
            into: base
        )

        XCTAssertEqual(result.appliedRecordIDs, [recordC.id])
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(result.snapshot, renameC.snapshot)
    }

    func testDayTraceDependencyGraphIsStableAcrossEveryInputPermutation() throws {
        let baseEngine = NoonmarkEngine()
        let chainID = try baseEngine.createPoolTask(title: "轨迹 DAG", now: now)
        let definitionID = try XCTUnwrap(baseEngine.snapshot().definitions.first?.id)
        let targetID = DayTraceID(uuid("73000000-0000-0000-0000-000000000003"))
        var old = DayTrace(
            id: DayTraceID(uuid("73000000-0000-0000-0000-000000000001")),
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            status: .changed,
            priority: 0,
            continuationSeq: 0,
            now: now,
            contentUpdatedAt: now.addingTimeInterval(1)
        )
        old.changedToTraceID = targetID
        old.settledAt = now.addingTimeInterval(1)
        var unrelated = DayTrace(
            id: DayTraceID(uuid("73000000-0000-0000-0000-000000000002")),
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            status: .unfinished,
            priority: 1,
            continuationSeq: 1,
            now: now,
            contentUpdatedAt: now.addingTimeInterval(2)
        )
        unrelated.settledAt = now.addingTimeInterval(2)
        let target = DayTrace(
            id: targetID,
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            priority: 2,
            continuationSeq: 2,
            now: now.addingTimeInterval(3)
        )
        let mapper = SyncRecordMapper()
        let records = try [old, unrelated, target].map {
            try mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("mac-a")
            )
        }
        let permutations = [
            [records[0], records[1], records[2]],
            [records[0], records[2], records[1]],
            [records[1], records[0], records[2]],
            [records[1], records[2], records[0]],
            [records[2], records[0], records[1]],
            [records[2], records[1], records[0]]
        ]

        for permutation in permutations {
            let result = SyncRecordMerger(mapper: mapper).merge(
                records: permutation,
                into: baseEngine.snapshot(),
                detectedAt: now.addingTimeInterval(10)
            )
            XCTAssertTrue(result.conflicts.isEmpty, "input=\(permutation.map(\.id))")
            XCTAssertEqual(Set(result.appliedRecordIDs), Set(records.map(\.id)))
            XCTAssertEqual(Set(result.snapshot.traces.map(\.id)), Set([old.id, unrelated.id, target.id]))
        }
    }

    func testDayTraceDependencyCycleFailsClosedAsACycle() throws {
        let baseEngine = NoonmarkEngine()
        let chainID = try baseEngine.createPoolTask(title: "轨迹依赖环", now: now)
        let definitionID = try XCTUnwrap(baseEngine.snapshot().definitions.first?.id)
        let firstID = DayTraceID(uuid("74000000-0000-0000-0000-000000000001"))
        let secondID = DayTraceID(uuid("74000000-0000-0000-0000-000000000002"))
        let first = DayTrace(
            id: firstID,
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            priority: 0,
            continuedFromTraceID: secondID,
            now: now
        )
        let second = DayTrace(
            id: secondID,
            chainID: chainID,
            definitionID: definitionID,
            date: today,
            priority: 1,
            continuedFromTraceID: firstID,
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let records = try [first, second].map {
            try mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("mac-a")
            )
        }

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: baseEngine.snapshot(),
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(result.conflicts.map(\.type), [.invalidReference, .invalidReference])
        XCTAssertTrue(result.conflicts.allSatisfy {
            $0.message.contains("causal dependency cycle")
        })
    }

    func testTraceClassificationEventsApplyByPredecessorRegardlessOfRecordOrder() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件因果链", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let first = try traceClassificationEventEnvelope(
            id: "F5000000-0000-0000-0000-000000000001",
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: nil
        )
        let second = try traceClassificationEventEnvelope(
            id: "05000000-0000-0000-0000-000000000001",
            traceID: traceID,
            status: .unfinished,
            revision: 2,
            predecessorEventID: first.event.id
        )
        let mapper = SyncRecordMapper()
        let firstRecord = try mapper.record(
            for: first,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let secondRecord = try mapper.record(
            for: second,
            modifiedBy: SyncDeviceID("mac-a")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [secondRecord, firstRecord],
            into: engine.snapshot(),
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(result.appliedRecordIDs, [firstRecord.id, secondRecord.id])
        XCTAssertEqual(result.snapshot.classifications.revision, 2)
        XCTAssertEqual(
            result.snapshot.classifications.snapshotEventsByTraceID[traceID],
            [first.event, second.event]
        )
        XCTAssertEqual(
            result.snapshot.classifications.snapshotsByTraceID[traceID],
            second.event
        )
        try result.snapshot.validateIntegrity()
    }

    func testTraceClassificationEventWaitsForMissingTraceAndPredecessor() throws {
        let traceID = DayTraceID(
            uuid("77000000-0000-0000-0000-000000000001")
        )
        let first = try traceClassificationEventEnvelope(
            id: "77000000-0000-0000-0000-000000000002",
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: nil
        )
        let mapper = SyncRecordMapper()
        let firstRecord = try mapper.record(
            for: first,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let missingTrace = SyncRecordMerger(mapper: mapper).merge(
            records: [firstRecord],
            into: NoonmarkEngine().snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(missingTrace.conflicts.isEmpty)
        XCTAssertEqual(
            missingTrace.waitingRecords.first?.dependencies,
            [.dayTrace(traceID)]
        )

        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "缺 predecessor", now: now)
        let localTraceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let predecessorID = uuid("77000000-0000-0000-0000-000000000003")
        let successor = try traceClassificationEventEnvelope(
            id: "77000000-0000-0000-0000-000000000004",
            traceID: localTraceID,
            status: .unfinished,
            revision: 2,
            predecessorEventID: predecessorID
        )
        let successorRecord = try mapper.record(
            for: successor,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let missingPredecessor = SyncRecordMerger(mapper: mapper).merge(
            records: [successorRecord],
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(missingPredecessor.conflicts.isEmpty)
        XCTAssertEqual(
            missingPredecessor.waitingRecords.first?.dependencies,
            [.classificationEvent(predecessorID)]
        )
    }

    func testTraceClassificationEventWaitsForFutureRevisionFact() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件 revision", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let envelope = try traceClassificationEventEnvelope(
            id: "78000000-0000-0000-0000-000000000001",
            traceID: traceID,
            status: .continued,
            revision: 3,
            predecessorEventID: nil
        )
        let record = try SyncRecordMapper().record(
            for: envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        let result = SyncRecordMerger().merge(
            records: [record],
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(
            result.waitingRecords.first?.dependencies,
            [.classificationRevision(2)]
        )
    }

    func testTraceClassificationEventForkFailsClosedBeforeEitherEventApplies() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件分叉", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let first = try traceClassificationEventEnvelope(
            id: "79000000-0000-0000-0000-000000000001",
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: nil
        )
        let second = try traceClassificationEventEnvelope(
            id: "79000000-0000-0000-0000-000000000002",
            traceID: traceID,
            status: .unfinished,
            revision: 1,
            predecessorEventID: nil
        )
        let mapper = SyncRecordMapper()
        let records = try [first, second].map {
            try mapper.record(for: $0, modifiedBy: SyncDeviceID("mac-a"))
        }

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.conflicts.map(\.type),
            [.traceClassificationEventRejected, .traceClassificationEventRejected]
        )
        XCTAssertEqual(result.snapshot, engine.snapshot())
    }

    func testTraceClassificationEventForkRejectionPropagatesToCausalDescendant() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件分叉后代", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let rejectedParent = try traceClassificationEventEnvelope(
            id: "79100000-0000-0000-0000-000000000001",
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: nil
        )
        let rejectedSibling = try traceClassificationEventEnvelope(
            id: "79100000-0000-0000-0000-000000000002",
            traceID: traceID,
            status: .unfinished,
            revision: 1,
            predecessorEventID: nil
        )
        let descendant = try traceClassificationEventEnvelope(
            id: "79100000-0000-0000-0000-000000000003",
            traceID: traceID,
            status: .abandoned,
            revision: 2,
            predecessorEventID: rejectedParent.event.id
        )
        let mapper = SyncRecordMapper()
        let records = try [descendant, rejectedSibling, rejectedParent].map {
            try mapper.record(for: $0, modifiedBy: SyncDeviceID("mac-a"))
        }

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: records,
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(Set(result.conflicts.map(\.remoteRecordID)), Set(records.map(\.id)))
        XCTAssertEqual(
            Set(result.conflicts.map(\.type)),
            [.traceClassificationEventRejected]
        )
        XCTAssertEqual(result.snapshot, engine.snapshot())
    }

    func testTraceClassificationEventIdentityCollisionAndCycleFailClosed() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件 collision", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        let collisionID = "7C000000-0000-0000-0000-000000000001"
        let collisionA = try traceClassificationEventEnvelope(
            id: collisionID,
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: nil
        )
        let collisionB = try traceClassificationEventEnvelope(
            id: collisionID,
            traceID: traceID,
            status: .unfinished,
            revision: 1,
            predecessorEventID: nil
        )
        let mapper = SyncRecordMapper()
        let collisionRecords = try [collisionA, collisionB].map {
            try mapper.record(for: $0, modifiedBy: SyncDeviceID("mac-a"))
        }
        let collisionResult = SyncRecordMerger(mapper: mapper).merge(
            records: collisionRecords,
            into: engine.snapshot(),
            detectedAt: now
        )
        XCTAssertTrue(collisionResult.appliedRecordIDs.isEmpty)
        XCTAssertEqual(
            collisionResult.conflicts.map(\.type),
            [.traceClassificationEventRejected, .traceClassificationEventRejected]
        )

        let firstID = uuid("7C000000-0000-0000-0000-000000000002")
        let secondID = uuid("7C000000-0000-0000-0000-000000000003")
        let first = try traceClassificationEventEnvelope(
            id: firstID.uuidString,
            traceID: traceID,
            status: .continued,
            revision: 1,
            predecessorEventID: secondID
        )
        let second = try traceClassificationEventEnvelope(
            id: secondID.uuidString,
            traceID: traceID,
            status: .unfinished,
            revision: 2,
            predecessorEventID: firstID
        )
        let cycleRecords = try [first, second].map {
            try mapper.record(for: $0, modifiedBy: SyncDeviceID("mac-a"))
        }
        let cycleResult = SyncRecordMerger(mapper: mapper).merge(
            records: cycleRecords,
            into: engine.snapshot(),
            detectedAt: now
        )
        XCTAssertTrue(cycleResult.appliedRecordIDs.isEmpty)
        XCTAssertEqual(
            cycleResult.conflicts.map(\.type),
            [.traceClassificationEventRejected, .traceClassificationEventRejected]
        )
        XCTAssertTrue(cycleResult.conflicts.allSatisfy {
            $0.message.contains("causal dependency cycle")
        })
    }

    func testTombstonedClassificationIdentityRejectsEventPermanently() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件 tombstone", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        _ = try commitClassification(
            .createCategory(name: "已删除分类", colorHex: "#2A6FDB"),
            to: engine,
            interactionID: uuid("7A000000-0000-0000-0000-000000000001"),
            decisionID: uuid("7A000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let category = try XCTUnwrap(
            engine.snapshot().classifications.categories.values.first
        )
        _ = try commitClassification(
            .hardDeleteCategory(category.id),
            to: engine,
            interactionID: uuid("7A000000-0000-0000-0000-000000000003"),
            decisionID: uuid("7A000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let event = TraceClassificationSnapshot(
            id: uuid("7A000000-0000-0000-0000-000000000005"),
            traceID: traceID,
            status: .continued,
            category: HistoricalCategoryValue(
                id: category.id,
                name: category.name,
                colorHex: category.colorHex
            ),
            labels: [],
            capturedAt: now.addingTimeInterval(3),
            revision: engine.snapshot().classifications.revision + 1
        )
        let envelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: nil
        )
        let record = try SyncRecordMapper().record(
            for: envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        let result = SyncRecordMerger().merge(
            records: [record],
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.conflicts.map(\.type),
            [.traceClassificationEventRejected]
        )
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }

    func testTombstonedLabelIdentityRejectsEventPermanently() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "事件 label tombstone", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        _ = try commitClassification(
            .createLabel(name: "已删除标签", colorHex: "#0E9488"),
            to: engine,
            interactionID: uuid("7B000000-0000-0000-0000-000000000001"),
            decisionID: uuid("7B000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let label = try XCTUnwrap(
            engine.snapshot().classifications.labels.values.first
        )
        _ = try commitClassification(
            .hardDeleteLabel(label.id),
            to: engine,
            interactionID: uuid("7B000000-0000-0000-0000-000000000003"),
            decisionID: uuid("7B000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let event = TraceClassificationSnapshot(
            id: uuid("7B000000-0000-0000-0000-000000000005"),
            traceID: traceID,
            status: .continued,
            category: nil,
            labels: [
                HistoricalLabelValue(
                    id: label.id,
                    name: label.name,
                    colorHex: label.colorHex
                )
            ],
            capturedAt: now.addingTimeInterval(3),
            revision: engine.snapshot().classifications.revision + 1
        )
        let envelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: nil
        )
        let record = try SyncRecordMapper().record(
            for: envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )

        let result = SyncRecordMerger().merge(
            records: [record],
            into: engine.snapshot(),
            detectedAt: now
        )

        XCTAssertTrue(result.waitingRecords.isEmpty)
        XCTAssertEqual(
            result.conflicts.map(\.type),
            [.traceClassificationEventRejected]
        )
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }

    func testUnlockedDayAllowsCompletedTraceUndoInPlace() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "当日撤销完成", now: now)
        let traceID = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try local.markCompleted(traceID: traceID, today: today, now: now)

        let remote = try NoonmarkEngine(snapshot: local.snapshot())
        try remote.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let remoteTrace = try XCTUnwrap(remote.snapshot().traces.first)

        let mapper = SyncRecordMapper()
        let remoteRecord = try mapper.record(
            for: remoteTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(records: [remoteRecord], into: local.snapshot(), detectedAt: now)

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.appliedRecordIDs, [remoteRecord.id])
        XCTAssertEqual(
            result.snapshot.traces.first(where: { $0.id == traceID })?.status,
            .pending
        )
        XCTAssertNil(
            result.snapshot.traces.first(where: { $0.id == traceID })?.completedAt
        )
    }

    func testMissingDayRejectsCompletedTraceUndo() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "缺少日上下文不可撤销", now: now)
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try local.markCompleted(traceID: traceID, today: today, now: now)
        let completedSnapshot = local.snapshot()

        let remote = try NoonmarkEngine(snapshot: completedSnapshot)
        try remote.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let remoteRecord = try mapper.record(
            for: try XCTUnwrap(remote.traces[traceID]),
            modifiedBy: SyncDeviceID("iphone-b")
        )
        var missingDaySnapshot = completedSnapshot
        missingDaySnapshot.days = []

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [remoteRecord],
            into: missingDaySnapshot,
            detectedAt: now
        )

        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(result.snapshot, missingDaySnapshot)
    }

    func testLockedDayRejectsCompletedTraceUndo() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "锁定历史不可撤销", now: now)
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try local.markCompleted(traceID: traceID, today: today, now: now)
        try local.settleDays(upTo: tomorrow, now: now.addingTimeInterval(60))
        let localSnapshot = local.snapshot()

        let remote = try NoonmarkEngine(snapshot: localSnapshot)
        try remote.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(120)
        )
        let remoteTrace = try XCTUnwrap(
            remote.snapshot().traces.first(where: { $0.id == traceID })
        )
        let mapper = SyncRecordMapper()
        let remoteRecord = try mapper.record(
            for: remoteTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [remoteRecord],
            into: localSnapshot,
            detectedAt: now
        )

        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
        XCTAssertEqual(result.snapshot, localSnapshot)
    }

    func testLockedDayMaterializationKeepsLaterOfflineReviewAndRejectsCompletionUndo() throws {
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(
            title: "锁定日下载离线复盘",
            now: now
        )
        let traceID = try completed.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try completed.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(20)
        )

        let offline = try NoonmarkEngine(snapshot: completed.snapshot())
        try offline.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        offline.updateDailyReview(
            date: today,
            summary: "下载后的离线复盘",
            unfinishedReason: "下载后的原因",
            tomorrowNote: "下载后的明日提醒",
            now: now.addingTimeInterval(100)
        )

        let locked = try NoonmarkEngine(snapshot: completed.snapshot())
        try locked.settleDays(
            upTo: tomorrow,
            now: now.addingTimeInterval(60)
        )

        let mapper = SyncRecordMapper()
        let dayRecord = try mapper.record(
            for: try XCTUnwrap(offline.days[today]),
            modifiedBy: SyncDeviceID("offline-review-device")
        )
        let undoRecord = try mapper.record(
            for: try XCTUnwrap(offline.traces[traceID]),
            modifiedBy: SyncDeviceID("offline-undo-device")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [undoRecord, dayRecord],
            into: locked.snapshot(),
            detectedAt: now.addingTimeInterval(120)
        )

        let mergedDay = try XCTUnwrap(
            result.snapshot.days.first { $0.date == today }
        )
        let mergedTrace = try XCTUnwrap(
            result.snapshot.traces.first { $0.id == traceID }
        )
        XCTAssertEqual(mergedDay.lockedAt, now.addingTimeInterval(60))
        XCTAssertEqual(mergedDay.reviewSummary, "下载后的离线复盘")
        XCTAssertEqual(mergedDay.reviewUnfinishedReason, "下载后的原因")
        XCTAssertEqual(mergedDay.reviewTomorrowNote, "下载后的明日提醒")
        XCTAssertEqual(mergedTrace.status, .completed)
        XCTAssertEqual(mergedTrace.completedAt, now.addingTimeInterval(20))
        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
    }

    func testAbandonedTraceCanReactivateInPlaceAfterParentChainBecomesActive() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "原地恢复", now: now)
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try local.abandonChain(from: traceID, now: now.addingTimeInterval(1))
        let abandoned = local.snapshot()

        let remote = try NoonmarkEngine(snapshot: abandoned)
        _ = try remote.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        let mapper = SyncRecordMapper()
        let records = try SyncRecordMaterializer(mapper: mapper).records(
            for: SyncSnapshotDiffer().journalEntries(
                from: abandoned,
                to: remote.snapshot(),
                changedAt: now.addingTimeInterval(2),
                deviceID: SyncDeviceID("iphone-b")
            ),
            in: remote.snapshot()
        )
        let chainRecord = try XCTUnwrap(
            records.first { $0.entityType == .taskChain }
        )
        let traceRecord = try XCTUnwrap(
            records.first { $0.entityType == .dayTrace }
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, chainRecord],
            into: abandoned,
            detectedAt: now.addingTimeInterval(3)
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.appliedRecordIDs, [chainRecord.id, traceRecord.id])
        XCTAssertEqual(result.snapshot.chains.first?.state, .active)
        XCTAssertEqual(result.snapshot.traces.first?.id, traceID)
        XCTAssertEqual(result.snapshot.traces.first?.status, .pending)
        XCTAssertNil(result.snapshot.traces.first?.settledAt)
    }

    func testReactivationWitnessAuthorizesOfflineNoteSuccessorBeforeFirstSync() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(
            title: "恢复后离线继续编辑",
            now: now
        )
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )
        let abandoned = local.snapshot()

        let offline = try NoonmarkEngine(snapshot: abandoned)
        _ = try offline.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        let reactivationJournal = try SyncSnapshotDiffer().journalEntries(
            from: abandoned,
            to: offline.snapshot(),
            changedAt: now.addingTimeInterval(30),
            deviceID: SyncDeviceID("offline-mac")
        )

        let noteID = try offline.appendTraceNote(
            traceID: traceID,
            body: "恢复后、首次同步前新增的附言",
            today: today,
            now: now.addingTimeInterval(40)
        )
        let mapper = SyncRecordMapper()
        let records = try SyncRecordMaterializer(mapper: mapper).records(
            for: reactivationJournal,
            in: offline.snapshot()
        )
        let chainRecord = try XCTUnwrap(
            records.first { $0.entityType == .taskChain }
        )
        let traceRecord = try XCTUnwrap(
            records.first { $0.entityType == .dayTrace }
        )
        XCTAssertFalse(chainRecord.reactivationWitnesses.isEmpty)
        XCTAssertEqual(
            try mapper.decodeDayTrace(traceRecord).noteEntries.map(\.id),
            [noteID]
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, chainRecord],
            into: abandoned,
            detectedAt: now.addingTimeInterval(50)
        )

        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.snapshot.chains.first?.state, .active)
        let mergedTrace = try XCTUnwrap(
            result.snapshot.traces.first { $0.id == traceID }
        )
        XCTAssertEqual(mergedTrace.status, .pending)
        XCTAssertNil(mergedTrace.settledAt)
        XCTAssertEqual(mergedTrace.noteEntries.map(\.id), [noteID])
        XCTAssertEqual(
            mergedTrace.activeNoteEntries.map(\.body),
            ["恢复后、首次同步前新增的附言"]
        )
    }

    func testStaleCompletionUndoCannotAuthorizeAbandonedChainReactivation() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "完成撤销不能冒充恢复废弃",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )

        let abandoned = try NoonmarkEngine(snapshot: base.snapshot())
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let stale = try NoonmarkEngine(snapshot: base.snapshot())
        try stale.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        try stale.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(40)
        )

        let mapper = SyncRecordMapper()
        let staleRecords = [
            try mapper.record(
                for: try XCTUnwrap(stale.chains[chainID]),
                modifiedBy: SyncDeviceID("stale-chain-device")
            ),
            try mapper.record(
                for: try XCTUnwrap(stale.traces[traceID]),
                modifiedBy: SyncDeviceID("stale-trace-device")
            )
        ]
        var canonicalResults: [[SyncRecord]] = []

        for records in [staleRecords, staleRecords.reversed()] {
            let result = SyncRecordMerger(mapper: mapper).merge(
                records: Array(records),
                into: abandoned.snapshot(),
                detectedAt: now.addingTimeInterval(50)
            )
            let mergedChain = try XCTUnwrap(
                result.snapshot.chains.first { $0.id == chainID }
            )
            let mergedTrace = try XCTUnwrap(
                result.snapshot.traces.first { $0.id == traceID }
            )

            XCTAssertEqual(mergedChain.state, .abandoned)
            XCTAssertEqual(mergedTrace.status, .abandoned)
            XCTAssertEqual(mergedTrace.settledAt, now.addingTimeInterval(20))
            canonicalResults.append([
                try mapper.record(
                    for: mergedChain,
                    modifiedBy: SyncDeviceID("canonical-device")
                ),
                try mapper.record(
                    for: mergedTrace,
                    modifiedBy: SyncDeviceID("canonical-device")
                )
            ])
        }

        XCTAssertEqual(canonicalResults[0], canonicalResults[1])
    }

    func testAbandonedChainMaterializationRejectsLaterStaleActiveRenameButMergesNotes() throws {
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "下载时拒绝旧分支复活",
            now: now
        )
        let traceID = try base.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )

        let abandoned = try NoonmarkEngine(snapshot: base.snapshot())
        try abandoned.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(20)
        )

        let staleActive = try NoonmarkEngine(snapshot: base.snapshot())
        try staleActive.renameTaskTitle(
            chainID: chainID,
            title: "下载到的旧分支较晚改名",
            today: today,
            now: now.addingTimeInterval(30)
        )
        var staleActiveChain = try XCTUnwrap(staleActive.chains[chainID])
        staleActiveChain.noteEntries.append(
            try TaskNoteEntry(
                body: "下载到的旧 active 分支附言",
                now: now.addingTimeInterval(40)
            )
        )

        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: staleActiveChain,
            modifiedBy: SyncDeviceID("stale-active-chain-device")
        )
        let traceRecord = try mapper.record(
            for: try XCTUnwrap(staleActive.traces[traceID]),
            modifiedBy: SyncDeviceID("stale-active-trace-device")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, chainRecord],
            into: abandoned.snapshot(),
            detectedAt: now.addingTimeInterval(50)
        )

        let mergedChain = try XCTUnwrap(
            result.snapshot.chains.first { $0.id == chainID }
        )
        let mergedTrace = try XCTUnwrap(
            result.snapshot.traces.first { $0.id == traceID }
        )
        XCTAssertEqual(mergedChain.state, .abandoned)
        XCTAssertEqual(
            mergedChain.activeNoteEntries.map(\.body),
            ["下载到的旧 active 分支附言"]
        )
        XCTAssertEqual(mergedTrace.status, .abandoned)
        XCTAssertEqual(mergedTrace.settledAt, now.addingTimeInterval(20))
    }

    func testAbandonedTraceReactivationRejectsImmutableFactTampering() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "恢复不可篡改", now: now)
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try local.abandonChain(from: traceID, now: now.addingTimeInterval(1))
        let abandoned = local.snapshot()

        let remote = try NoonmarkEngine(snapshot: abandoned)
        _ = try remote.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        var tampered = try XCTUnwrap(remote.traces[traceID])
        tampered.noteEntries = [
            try TaskNoteEntry(
                body: "伪造的历史内容",
                now: now.addingTimeInterval(1)
            )
        ]
        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: try XCTUnwrap(remote.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let traceRecord = try mapper.record(
            for: tampered,
            modifiedBy: SyncDeviceID("iphone-b")
        )

        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, chainRecord],
            into: abandoned,
            detectedAt: now.addingTimeInterval(3)
        )

        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
        XCTAssertFalse(result.appliedRecordIDs.contains(traceRecord.id))
        XCTAssertEqual(
            result.snapshot.traces.first(where: { $0.id == traceID }),
            abandoned.traces.first(where: { $0.id == traceID })
        )
    }

    func testAbandonedTraceReactivationRejectsOmittedHistoricalNote() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(
            title: "恢复不可遗漏旧附言",
            now: now
        )
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        _ = try local.appendTraceNote(
            traceID: traceID,
            body: "恢复前已经存在的附言",
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.abandonChain(
            from: traceID,
            now: now.addingTimeInterval(2)
        )
        let abandoned = local.snapshot()

        let remote = try NoonmarkEngine(snapshot: abandoned)
        _ = try remote.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        var omitted = try XCTUnwrap(remote.traces[traceID])
        omitted.noteEntries = []

        let mapper = SyncRecordMapper()
        let chainRecord = try mapper.record(
            for: try XCTUnwrap(remote.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let traceRecord = try mapper.record(
            for: omitted,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(
            records: [traceRecord, chainRecord],
            into: abandoned,
            detectedAt: now.addingTimeInterval(4)
        )

        XCTAssertEqual(result.conflicts.map(\.type), [.historicalTraceMutation])
        XCTAssertFalse(result.appliedRecordIDs.contains(traceRecord.id))
        XCTAssertEqual(
            result.snapshot.traces.first(where: { $0.id == traceID }),
            abandoned.traces.first(where: { $0.id == traceID })
        )
    }

    func testMissingParentTraceFailsClosedForSubtask() throws {
        let orphan = Subtask(
            traceID: DayTraceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            title: "孤儿子任务",
            position: 0,
            now: now
        )

        let mapper = SyncRecordMapper()
        let record = try mapper.record(for: orphan, modifiedBy: SyncDeviceID("iphone-b"))
        let result = SyncRecordMerger(mapper: mapper).merge(records: [record], into: NoonmarkEngine().snapshot(), detectedAt: now)

        XCTAssertEqual(result.conflicts.map(\.type), [.missingParent])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }

    func testDuplicateActiveTraceFailsClosed() throws {
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "同一任务链只能一个活跃轨迹", now: now)
        let definitionID = try XCTUnwrap(local.snapshot().definitions.first?.id)
        _ = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        let secondTrace = DayTrace(
            chainID: chainID,
            definitionID: definitionID,
            date: tomorrow,
            priority: 0,
            now: now
        )

        let mapper = SyncRecordMapper()
        let record = try mapper.record(
            for: secondTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let result = SyncRecordMerger(mapper: mapper).merge(records: [record], into: local.snapshot(), detectedAt: now)

        XCTAssertEqual(result.conflicts.map(\.type), [.duplicateActiveTrace])
        XCTAssertTrue(result.appliedRecordIDs.isEmpty)
    }

    private struct ConcurrentSelectionFrontierFixture {
        let base: NoonmarkSnapshot
        let afterB: NoonmarkSnapshot
        let final: NoonmarkSnapshot
        let recordA: SyncRecord
        let recordB: SyncRecord
        let successorRecord: SyncRecord
        let successorEnvelope: ClassificationCommitEnvelope
        let changeRecordIDA: UUID
        let changeRecordIDB: UUID
    }

    private func makeConcurrentSelectionFrontierFixture() throws -> ConcurrentSelectionFrontierFixture {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(title: "完整 causal frontier", now: now)
        _ = try commitClassification(
            .createLabel(name: "前沿标签 A", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72210900-0000-0000-0000-000000000001"),
            decisionID: uuid("72210900-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        _ = try commitClassification(
            .createLabel(name: "前沿标签 B", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("72210900-0000-0000-0000-000000000003"),
            decisionID: uuid("72210900-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        _ = try commitClassification(
            .createLabel(name: "前沿标签 C", colorHex: "#7C5CFF"),
            to: source,
            interactionID: uuid("72210900-0000-0000-0000-000000000005"),
            decisionID: uuid("72210900-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let base = source.snapshot()
        let labelAID = try XCTUnwrap(base.classifications.labels.values.first {
            $0.name == "前沿标签 A"
        }?.id)
        let labelBID = try XCTUnwrap(base.classifications.labels.values.first {
            $0.name == "前沿标签 B"
        }?.id)
        let labelCID = try XCTUnwrap(base.classifications.labels.values.first {
            $0.name == "前沿标签 C"
        }?.id)

        func makeBranch(
            labelID: TaskLabelID,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> (
            snapshot: NoonmarkSnapshot,
            envelope: ClassificationCommitEnvelope
        ) {
            let branch = try NoonmarkEngine(snapshot: base)
            let receipt = try commitClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: nil,
                        labels: [.existing(labelID)]
                    )
                ),
                to: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let snapshot = branch.snapshot()
            let changeRecord = try XCTUnwrap(
                snapshot.classifications.changeRecords.first {
                    $0.id == receipt.changeRecordID
                }
            )
            return (
                snapshot,
                try ClassificationCommitEnvelope(
                    before: base.classifications,
                    after: snapshot.classifications,
                    changeRecord: changeRecord
                )
            )
        }

        let branchA = try makeBranch(
            labelID: labelAID,
            interactionID: uuid("72211000-0000-0000-0000-000000000001"),
            decisionID: uuid("72211000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(4)
        )
        let branchB = try makeBranch(
            labelID: labelBID,
            interactionID: uuid("72211000-0000-0000-0000-000000000003"),
            decisionID: uuid("72211000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(5)
        )
        let mapper = SyncRecordMapper()
        let recordA = try mapper.record(
            for: branchA.envelope,
            modifiedBy: SyncDeviceID("mac-a")
        )
        let recordB = try mapper.record(
            for: branchB.envelope,
            modifiedBy: SyncDeviceID("mac-b")
        )
        let joined = SyncRecordMerger(mapper: mapper).merge(
            records: [recordA, recordB],
            into: base
        )
        XCTAssertTrue(joined.conflicts.isEmpty, "conflicts=\(joined.conflicts)")
        XCTAssertTrue(joined.waitingRecords.isEmpty)

        let successor = try NoonmarkEngine(snapshot: joined.snapshot)
        let successorReceipt = try commitClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [
                        .existing(labelAID),
                        .existing(labelBID),
                        .existing(labelCID)
                    ]
                )
            ),
            to: successor,
            interactionID: uuid("72211000-0000-0000-0000-000000000005"),
            decisionID: uuid("72211000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(6)
        )
        let final = successor.snapshot()
        let successorChangeRecord = try XCTUnwrap(
            final.classifications.changeRecords.first {
                $0.id == successorReceipt.changeRecordID
            }
        )
        let successorEnvelope = try ClassificationCommitEnvelope(
            before: joined.snapshot.classifications,
            after: final.classifications,
            changeRecord: successorChangeRecord
        )
        return ConcurrentSelectionFrontierFixture(
            base: base,
            afterB: branchB.snapshot,
            final: final,
            recordA: recordA,
            recordB: recordB,
            successorRecord: try mapper.record(
                for: successorEnvelope,
                modifiedBy: SyncDeviceID("mac-c")
            ),
            successorEnvelope: successorEnvelope,
            changeRecordIDA: branchA.envelope.changeRecord.id,
            changeRecordIDB: branchB.envelope.changeRecord.id
        )
    }

    private enum MergeItemRole: String {
        case source
        case target
    }

    private enum MergeScenarioItems {
        case category(source: TaskCategoryID, target: TaskCategoryID)
        case label(source: TaskLabelID, target: TaskLabelID)

        var mergeIntent: ClassificationIntent {
            switch self {
            case let .category(source, target):
                .mergeCategory(source: source, into: target)
            case let .label(source, target):
                .mergeLabel(source: source, into: target)
            }
        }

        func renameIntent(for role: MergeItemRole) -> ClassificationIntent {
            switch self {
            case let .category(source, target):
                .renameCategory(
                    role == .source ? source : target,
                    to: "\(role.rawValue) 分类新名称"
                )
            case let .label(source, target):
                .renameLabel(
                    role == .source ? source : target,
                    to: "\(role.rawValue) 标签新名称"
                )
            }
        }
    }

    private struct MergeScenario {
        let base: NoonmarkSnapshot
        let items: MergeScenarioItems
    }

    private struct RenameMergeFixture {
        let base: NoonmarkSnapshot
        let renameRecord: SyncRecord
        let mergeRecord: SyncRecord
    }

    private func makeRenameMergeFixture(
        kind: ClassificationItemKind,
        renamedRole: MergeItemRole
    ) throws -> RenameMergeFixture {
        let scenario = try makeMergeScenario(kind: kind)
        let base = scenario.base
        let mergeIntent = scenario.items.mergeIntent
        let renameIntent = scenario.items.renameIntent(for: renamedRole)

        func makeEnvelope(
            _ intent: ClassificationIntent,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> ClassificationCommitEnvelope {
            let branch = try NoonmarkEngine(snapshot: base)
            let receipt = try commitClassification(
                intent,
                to: branch,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let after = branch.snapshot()
            return try ClassificationCommitEnvelope(
                before: base.classifications,
                after: after.classifications,
                changeRecord: try XCTUnwrap(after.classifications.changeRecords.first {
                    $0.id == receipt.changeRecordID
                })
            )
        }

        let rename = try makeEnvelope(
            renameIntent,
            interactionID: UUID(),
            decisionID: UUID(),
            at: now.addingTimeInterval(12)
        )
        let merge = try makeEnvelope(
            mergeIntent,
            interactionID: UUID(),
            decisionID: UUID(),
            at: now.addingTimeInterval(13)
        )
        let mapper = SyncRecordMapper()
        return RenameMergeFixture(
            base: base,
            renameRecord: try mapper.record(
                for: rename,
                modifiedBy: SyncDeviceID("mac-rename")
            ),
            mergeRecord: try mapper.record(
                for: merge,
                modifiedBy: SyncDeviceID("mac-merge")
            )
        )
    }

    private func makeMergeScenario(kind: ClassificationItemKind) throws -> MergeScenario {
        let source = NoonmarkEngine()
        let sourceName = kind == .category ? "合并源分类" : "合并源标签"
        let targetName = kind == .category ? "合并目标分类" : "合并目标标签"
        let sourceCreate: ClassificationIntent = switch kind {
        case .category:
            .createCategory(name: sourceName, colorHex: "#2A6FDB")
        case .label:
            .createLabel(name: sourceName, colorHex: "#2A6FDB")
        }
        let targetCreate: ClassificationIntent = switch kind {
        case .category:
            .createCategory(name: targetName, colorHex: "#0E9488")
        case .label:
            .createLabel(name: targetName, colorHex: "#0E9488")
        }
        _ = try commitClassification(
            sourceCreate,
            to: source,
            interactionID: UUID(),
            decisionID: UUID(),
            at: now.addingTimeInterval(10)
        )
        _ = try commitClassification(
            targetCreate,
            to: source,
            interactionID: UUID(),
            decisionID: UUID(),
            at: now.addingTimeInterval(11)
        )
        let base = source.snapshot()

        let items: MergeScenarioItems
        switch kind {
        case .category:
            let sourceID = try XCTUnwrap(base.classifications.categories.values.first {
                $0.name == sourceName
            }?.id)
            let targetID = try XCTUnwrap(base.classifications.categories.values.first {
                $0.name == targetName
            }?.id)
            items = .category(source: sourceID, target: targetID)
        case .label:
            let sourceID = try XCTUnwrap(base.classifications.labels.values.first {
                $0.name == sourceName
            }?.id)
            let targetID = try XCTUnwrap(base.classifications.labels.values.first {
                $0.name == targetName
            }?.id)
            items = .label(source: sourceID, target: targetID)
        }
        return MergeScenario(base: base, items: items)
    }

    private struct ManagementCausalFixture {
        let base: NoonmarkSnapshot
        let afterFirst: NoonmarkSnapshot
        let final: NoonmarkSnapshot
        let firstRecord: SyncRecord
        let secondRecord: SyncRecord
        let thirdRecord: SyncRecord
        let secondChangeRecordID: UUID
    }

    private func makeManagementCausalFixture() throws -> ManagementCausalFixture {
        let source = NoonmarkEngine()
        _ = try commitClassification(
            .createCategory(name: "传递因果 v1", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("72400000-0000-0000-0000-000000000001"),
            decisionID: uuid("72400000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)

        func commitEnvelope(
            _ intent: ClassificationIntent,
            interactionID: UUID,
            decisionID: UUID,
            at time: Date
        ) throws -> (snapshot: NoonmarkSnapshot, envelope: ClassificationCommitEnvelope) {
            let before = source.snapshot()
            let receipt = try commitClassification(
                intent,
                to: source,
                interactionID: interactionID,
                decisionID: decisionID,
                at: time
            )
            let after = source.snapshot()
            return (
                after,
                try ClassificationCommitEnvelope(
                    before: before.classifications,
                    after: after.classifications,
                    changeRecord: try XCTUnwrap(after.classifications.changeRecords.first {
                        $0.id == receipt.changeRecordID
                    })
                )
            )
        }

        let first = try commitEnvelope(
            .renameCategory(categoryID, to: "传递因果 v2"),
            interactionID: uuid("72400000-0000-0000-0000-000000000003"),
            decisionID: uuid("72400000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let second = try commitEnvelope(
            .renameCategory(categoryID, to: "传递因果 v3"),
            interactionID: uuid("72400000-0000-0000-0000-000000000005"),
            decisionID: uuid("72400000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let third = try commitEnvelope(
            .archiveCategory(categoryID),
            interactionID: uuid("72400000-0000-0000-0000-000000000007"),
            decisionID: uuid("72400000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let mapper = SyncRecordMapper()
        return ManagementCausalFixture(
            base: base,
            afterFirst: first.snapshot,
            final: third.snapshot,
            firstRecord: try mapper.record(
                for: first.envelope,
                modifiedBy: SyncDeviceID("mac-a")
            ),
            secondRecord: try mapper.record(
                for: second.envelope,
                modifiedBy: SyncDeviceID("mac-a")
            ),
            thirdRecord: try mapper.record(
                for: third.envelope,
                modifiedBy: SyncDeviceID("mac-a")
            ),
            secondChangeRecordID: second.envelope.changeRecord.id
        )
    }

    private func makeClassificationCommitFixture() throws -> (
        source: NoonmarkEngine,
        chainID: TaskChainID,
        categoryID: TaskCategoryID,
        labelIDs: Set<TaskLabelID>,
        decisionID: UUID,
        envelope: ClassificationCommitEnvelope
    ) {
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(title: "同步 typed 分类", now: now)
        let before = source.snapshot().classifications
        let decisionID = UUID(uuidString: "36000000-0000-0000-0000-000000000002")!
        let plan = try source.prepareClassification(
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
            interactionID: UUID(uuidString: "36000000-0000-0000-0000-000000000001")!,
            now: now
        )
        let receipt = try source.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )
        let after = source.snapshot().classifications
        let record = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        let current = try XCTUnwrap(after.currentByChainID[chainID])
        return (
            source,
            chainID,
            try XCTUnwrap(current.categoryID),
            current.labelIDs,
            decisionID,
            try ClassificationCommitEnvelope(
                before: before,
                after: after,
                changeRecord: record
            )
        )
    }

    @discardableResult
    private func commitClassification(
        _ intent: ClassificationIntent,
        to engine: NoonmarkEngine,
        interactionID: UUID,
        decisionID: UUID,
        at time: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: interactionID,
            now: time
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: time
        )
    }

    private func reidentified(
        _ envelope: ClassificationCommitEnvelope,
        as id: UUID,
        replacingPredecessorIDs replacements: [UUID: UUID] = [:]
    ) throws -> ClassificationCommitEnvelope {
        let original = envelope.changeRecord
        let record = ClassificationChangeRecord(
            id: id,
            planID: original.planID,
            interactionID: original.interactionID,
            source: original.source,
            decisionID: original.decisionID,
            changes: original.changes,
            notices: original.notices,
            committedAt: original.committedAt,
            revision: original.revision,
            planDigest: original.planDigest
        )
        let receipt = envelope.receipt.map {
            ClassificationReceipt(
                planID: record.planID,
                revision: record.revision,
                notices: $0.notices,
                changeRecordID: record.id,
                decisionID: record.decisionID,
                changeRecordIntegrityDigest: record.integrityDigest
            )
        }
        let mutation = envelope.delta.mutation
        let remappedMutation = ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: mutation.predecessorChangeRecordIDs
                .map { replacements[$0] ?? $0 }
                .sorted { $0.uuidString < $1.uuidString },
            categoryMutations: mutation.categoryMutations,
            labelMutations: mutation.labelMutations,
            currentMutations: mutation.currentMutations,
            categoryMergeMutations: mutation.categoryMergeMutations,
            labelMergeMutations: mutation.labelMergeMutations,
            categoryTombstoneMutations: mutation.categoryTombstoneMutations,
            labelTombstoneMutations: mutation.labelTombstoneMutations,
            requiredCategories: mutation.requiredCategories,
            requiredLabels: mutation.requiredLabels,
            appendedRelationHistory: mutation.appendedRelationHistory
        )
        let delta: ClassificationCommitDelta = switch envelope.delta {
        case .setCurrent:
            .setCurrent(remappedMutation)
        case .create:
            .create(remappedMutation)
        case .rename:
            .rename(remappedMutation)
        case .lifecycle:
            .lifecycle(remappedMutation)
        case .merge:
            .merge(remappedMutation)
        case .hardDelete:
            .hardDelete(remappedMutation)
        }
        return try ClassificationCommitEnvelope(
            senderBaseRevision: envelope.senderBaseRevision,
            senderResultRevision: envelope.senderResultRevision,
            delta: delta,
            changeRecord: record,
            receipt: receipt
        )
    }

    private func replacingPredecessors(
        in envelope: ClassificationCommitEnvelope,
        with predecessorIDs: [UUID]
    ) throws -> ClassificationCommitEnvelope {
        let mutation = envelope.delta.mutation
        let replacement = ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: predecessorIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            categoryMutations: mutation.categoryMutations,
            labelMutations: mutation.labelMutations,
            currentMutations: mutation.currentMutations,
            categoryMergeMutations: mutation.categoryMergeMutations,
            labelMergeMutations: mutation.labelMergeMutations,
            categoryTombstoneMutations: mutation.categoryTombstoneMutations,
            labelTombstoneMutations: mutation.labelTombstoneMutations,
            requiredCategories: mutation.requiredCategories,
            requiredLabels: mutation.requiredLabels,
            appendedRelationHistory: mutation.appendedRelationHistory
        )
        let delta: ClassificationCommitDelta = switch envelope.delta {
        case .setCurrent:
            .setCurrent(replacement)
        case .create:
            .create(replacement)
        case .rename:
            .rename(replacement)
        case .lifecycle:
            .lifecycle(replacement)
        case .merge:
            .merge(replacement)
        case .hardDelete:
            .hardDelete(replacement)
        }
        return try ClassificationCommitEnvelope(
            senderBaseRevision: envelope.senderBaseRevision,
            senderResultRevision: envelope.senderResultRevision,
            delta: delta,
            changeRecord: envelope.changeRecord,
            receipt: envelope.receipt
        )
    }

    private func traceClassificationEventEnvelope(
        id: String,
        traceID: DayTraceID,
        status: TraceStatus,
        revision: UInt64,
        predecessorEventID: UUID?
    ) throws -> TraceClassificationEventEnvelope {
        try TraceClassificationEventEnvelope(
            event: TraceClassificationSnapshot(
                id: uuid(id),
                traceID: traceID,
                status: status,
                category: nil,
                labels: [],
                capturedAt: now.addingTimeInterval(TimeInterval(revision)),
                revision: revision
            ),
            predecessorEventID: predecessorEventID
        )
    }

    private func uuid(_ value: String) -> UUID {
        guard let result = UUID(uuidString: value) else {
            preconditionFailure("测试 UUID 非法：\(value)")
        }
        return result
    }
}

@testable import SuntraceCore
@testable import SuntraceStorage
import SuntraceSync
import XCTest

final class SQLiteSyncDownloadCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testDownloadAndMergeAppliesRemoteRecordsWithoutCreatingUploadJournal() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "从远端下载任务", now: now)
        let traceID = try source.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try source.addSubtask(traceID: traceID, title: "合并远端子任务", difficulty: .hard, now: now)
        let records = try SyncRecordMapper().records(from: source.snapshot(), modifiedBy: SyncDeviceID("iphone-b"))
        let transport = InMemorySyncTransport(records: records)

        try engineRepository.save(SuntraceEngine().snapshot())

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        let restored = try engineRepository.load()

        XCTAssertEqual(result.fetchedCount, records.count)
        XCTAssertEqual(result.appliedCount, records.count)
        XCTAssertEqual(result.conflictCount, 0)
        XCTAssertEqual(restored.snapshot(), source.snapshot())
        XCTAssertTrue(try syncRepository.journalEntries(state: .pendingUpload).isEmpty)
        XCTAssertEqual(Set(try syncRepository.auditLog().map(\.action)), ["merged"])
        XCTAssertNotNil(try syncRepository.metadata(for: "generic.download.lastFetch"))
    }

    func testDownloadConflictIsPersistedWithoutOverwritingLocalSnapshot() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let local = SuntraceEngine()
        let chainID = try local.createPoolTask(title: "本地历史任务", now: now)
        let traceID = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try local.markCompleted(traceID: traceID, today: today, now: now.addingTimeInterval(1))
        local.settleDays(upTo: LocalDate("2026-07-06"), now: now.addingTimeInterval(2))
        let localSnapshot = local.snapshot()
        try engineRepository.save(localSnapshot)

        var remoteTrace = try XCTUnwrap(localSnapshot.traces.first)
        remoteTrace.status = .pending
        remoteTrace.completedAt = nil
        let remoteRecord = try SyncRecordMapper().record(
            for: remoteTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let transport = InMemorySyncTransport(records: [remoteRecord])

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: transport)
        let result = try await coordinator.downloadAndMerge(detectedAt: now.addingTimeInterval(10))

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 1,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 1
            )
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), localSnapshot)

        let conflict = try XCTUnwrap(syncRepository.unresolvedConflicts().first)
        XCTAssertEqual(conflict.type, .historicalTraceMutation)
        XCTAssertEqual(conflict.remoteRecordID, remoteRecord.id)
        XCTAssertEqual(conflict.remoteRecord, remoteRecord)
        XCTAssertEqual(try syncRepository.auditLog(limit: 1).first?.action, "conflict")
    }

    func testEmptyRemoteFetchUpdatesMetadataOnly() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)

        try engineRepository.save(SuntraceEngine().snapshot())

        let coordinator = SQLiteSyncDownloadCoordinator(databaseURL: databaseURL, transport: InMemorySyncTransport())
        let result = try await coordinator.downloadAndMerge(detectedAt: now)

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 0,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 0
            )
        )
        XCTAssertTrue(try syncRepository.auditLog().isEmpty)
        XCTAssertNotNil(try syncRepository.metadata(for: "generic.download.lastFetch"))
    }

    func testMissingClassificationDependencyPersistsAcrossAnEmptyFetchAndAppliesWhenParentsArrive() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(SuntraceEngine().snapshot())

        let fixture = try makeClassificationEnvelope()
        let mapper = SyncRecordMapper()
        let classificationRecord = try mapper.record(
            for: fixture.envelope,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let transport = InMemorySyncTransport(records: [classificationRecord])
        let coordinator = SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )

        let first = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(10)
        )
        let firstPending = try XCTUnwrap(syncRepository.pendingDownloads().first)

        await transport.removeAll()
        let second = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(20)
        )

        XCTAssertEqual(first.waitingCount, 1)
        XCTAssertEqual(first.appliedCount, 0)
        XCTAssertEqual(first.conflictCount, 0)
        XCTAssertEqual(firstPending.record, classificationRecord)
        XCTAssertEqual(firstPending.dependencies, [.taskChain(fixture.chainID)])
        XCTAssertEqual(firstPending.attemptCount, 1)
        XCTAssertEqual(second.fetchedCount, 0)
        XCTAssertEqual(second.appliedCount, 0)
        XCTAssertEqual(second.waitingCount, 1)
        XCTAssertEqual(second.conflictCount, 0)
        XCTAssertEqual(try syncRepository.pendingDownloads().map(\.record), [classificationRecord])
        XCTAssertEqual(try syncRepository.pendingDownloads().first?.attemptCount, 2)

        let parentRecords = try [
            mapper.record(
                for: fixture.chain,
                modifiedBy: SyncDeviceID("iphone-b")
            ),
            mapper.record(
                for: fixture.definition,
                modifiedBy: SyncDeviceID("iphone-b")
            )
        ]
        try await transport.push(parentRecords)

        let third = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(30)
        )
        let restored = try engineRepository.load().snapshot()

        XCTAssertEqual(third.fetchedCount, parentRecords.count)
        XCTAssertEqual(third.appliedCount, parentRecords.count + 1)
        XCTAssertEqual(third.waitingCount, 0)
        XCTAssertEqual(third.conflictCount, 0)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(
            restored.classifications.currentByChainID[fixture.chainID],
            try XCTUnwrap(
                fixture.envelope.delta.mutation.currentMutations.first?.post.value
            )
        )
        XCTAssertEqual(
            Set(try syncRepository.auditLog().map(\.action)),
            ["merged", "waiting"]
        )
    }

    func testMissingManagementPredecessorSurvivesRestartAndAppliesAfterArrival() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let source = SuntraceEngine()

        let createPlan = try source.prepareClassification(
            .createCategory(name: "持久因果", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "44000000-0000-0000-0000-000000000001")!,
            now: now
        )
        _ = try source.commitClassification(
            createPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "44000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let receiverBase = source.snapshot()
        let categoryID = try XCTUnwrap(receiverBase.classifications.categories.keys.first)
        try engineRepository.save(receiverBase)

        let renamePlan = try source.prepareClassification(
            .renameCategory(categoryID, to: "持久因果 v2"),
            source: .userDirect,
            interactionID: UUID(uuidString: "44000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(1)
        )
        let renameReceipt = try source.commitClassification(
            renamePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "44000000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(1)
        )
        let afterRename = source.snapshot()
        let renameEnvelope = try ClassificationCommitEnvelope(
            before: receiverBase.classifications,
            after: afterRename.classifications,
            changeRecord: try XCTUnwrap(afterRename.classifications.changeRecords.first {
                $0.id == renameReceipt.changeRecordID
            })
        )

        let archivePlan = try source.prepareClassification(
            .archiveCategory(categoryID),
            source: .userDirect,
            interactionID: UUID(uuidString: "44000000-0000-0000-0000-000000000005")!,
            now: now.addingTimeInterval(2)
        )
        let archiveReceipt = try source.commitClassification(
            archivePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "44000000-0000-0000-0000-000000000006")!
            ),
            now: now.addingTimeInterval(2)
        )
        let finalSnapshot = source.snapshot()
        let archiveEnvelope = try ClassificationCommitEnvelope(
            before: afterRename.classifications,
            after: finalSnapshot.classifications,
            changeRecord: try XCTUnwrap(finalSnapshot.classifications.changeRecords.first {
                $0.id == archiveReceipt.changeRecordID
            })
        )
        XCTAssertEqual(
            archiveEnvelope.delta.mutation.predecessorChangeRecordIDs,
            [renameReceipt.changeRecordID]
        )

        let mapper = SyncRecordMapper()
        let renameRecord = try mapper.record(
            for: renameEnvelope,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let archiveRecord = try mapper.record(
            for: archiveEnvelope,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let transport = InMemorySyncTransport(records: [archiveRecord])

        let first = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        let firstPending = try XCTUnwrap(syncRepository.pendingDownloads().first)
        XCTAssertEqual(first.appliedCount, 0)
        XCTAssertEqual(first.waitingCount, 1)
        XCTAssertEqual(
            firstPending.dependencies,
            [.classificationCommit(renameReceipt.changeRecordID)]
        )

        await transport.removeAll()
        let afterRestart = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))
        XCTAssertEqual(afterRestart.fetchedCount, 0)
        XCTAssertEqual(afterRestart.waitingCount, 1)
        XCTAssertEqual(try syncRepository.pendingDownloads().first?.attemptCount, 2)

        try await transport.push([renameRecord])
        let resolved = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(30))

        XCTAssertEqual(resolved.fetchedCount, 1)
        XCTAssertEqual(resolved.appliedCount, 2)
        XCTAssertEqual(resolved.waitingCount, 0)
        XCTAssertEqual(resolved.conflictCount, 0)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try engineRepository.load().snapshot(), finalSnapshot)
    }

    func testTerminalResultDoesNotDeletePendingInsertedAfterTheInitialRead() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(SuntraceEngine().snapshot())

        let fixture = try makeClassificationEnvelope()
        let validRecord = try SyncRecordMapper().record(
            for: fixture.envelope,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let waiting = SyncWaitingRecord(
            record: validRecord,
            dependencies: [.taskChain(fixture.chainID)]
        )
        var collidingRecord = validRecord
        collidingRecord.payload = Data([0x00])
        let transport = PendingInjectingTransport(
            databaseURL: databaseURL,
            waiting: waiting,
            attemptedAt: now.addingTimeInterval(5),
            fetched: [collidingRecord]
        )
        let coordinator = SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )

        let result = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(10)
        )

        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertEqual(result.waitingCount, 1)
        XCTAssertEqual(try syncRepository.pendingDownloads().map(\.record), [validRecord])
    }

    func testPendingValidationFailureRollsBackEveryDownloadedFact() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let before = SuntraceEngine().snapshot()
        try engineRepository.save(before)

        let baselineAudit = SyncAuditLogEntry(
            id: UUID(uuidString: "45000000-0000-0000-0000-000000000001")!,
            direction: .download,
            entityType: .day,
            entityID: "baseline-day",
            action: "baseline",
            createdAt: now,
            message: "must survive rollback"
        )
        let baselineMetadata = SyncMetadataEntry(
            key: "generic.download.lastFetch",
            value: Data([0x41, 0x00, 0x42]),
            updatedAt: now
        )
        try syncRepository.appendAuditLog(baselineAudit)
        try syncRepository.saveMetadata(baselineMetadata)

        let mapper = SyncRecordMapper()
        let appliedSource = SuntraceEngine()
        _ = try appliedSource.createPoolTask(
            title: "这次下载必须整体回滚",
            now: now.addingTimeInterval(1)
        )
        let appliedRecords = try mapper.records(
            from: appliedSource.snapshot(),
            modifiedBy: SyncDeviceID("iphone-applied")
        )
        let waitingFixture = try makeClassificationEnvelope()
        var invalidWaitingRecord = try mapper.record(
            for: waitingFixture.envelope,
            modifiedBy: SyncDeviceID("iphone-waiting")
        )
        invalidWaitingRecord.modifiedAt = Date(
            timeIntervalSinceReferenceDate: .nan
        )
        let transport = InMemorySyncTransport(
            records: appliedRecords + [invalidWaitingRecord]
        )

        do {
            _ = try await SQLiteSyncDownloadCoordinator(
                databaseURL: databaseURL,
                transport: transport
            ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
            XCTFail("expected pending validation to fail")
        } catch {
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }

        XCTAssertEqual(try engineRepository.load().snapshot(), before)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertTrue(try syncRepository.unresolvedConflicts().isEmpty)
        XCTAssertEqual(try syncRepository.auditLog(), [baselineAudit])
        XCTAssertEqual(
            try syncRepository.metadata(for: "generic.download.lastFetch"),
            baselineMetadata
        )
    }

    func testDownloadsCategoryDeleteThenHistoricalAliasRecreationInRemoteOrder() async throws {
        try await assertDeleteRecreateDownload(kind: .category, recordsReversed: false)
    }

    func testDownloadsCategoryDeleteThenHistoricalAliasRecreationInReverseOrder() async throws {
        try await assertDeleteRecreateDownload(kind: .category, recordsReversed: true)
    }

    func testDownloadsLabelDeleteThenHistoricalAliasRecreationInRemoteOrder() async throws {
        try await assertDeleteRecreateDownload(kind: .label, recordsReversed: false)
    }

    func testDownloadsLabelDeleteThenHistoricalAliasRecreationInReverseOrder() async throws {
        try await assertDeleteRecreateDownload(kind: .label, recordsReversed: true)
    }

    func testDeleteRecreateDownloadRollsBackWhenAuditPersistenceFails() async throws {
        let databaseURL = makeDatabaseURL()
        let fixture = try makeDeleteRecreateFixture(kind: .category)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(fixture.baseSnapshot)
        let auditID = UUID(uuidString: "46000000-0000-0000-0000-000000000001")!
        let baselineAudit = SyncAuditLogEntry(
            id: auditID,
            direction: .download,
            entityType: .classificationCommit,
            entityID: "baseline",
            action: "baseline",
            createdAt: now,
            message: "must survive rollback"
        )
        try syncRepository.appendAuditLog(baselineAudit)

        do {
            _ = try await SQLiteSyncDownloadCoordinator(
                databaseURL: databaseURL,
                transport: OrderedSyncTransport(records: fixture.records),
                auditEntryIDGenerator: { auditID }
            ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
            XCTFail("expected injected audit persistence failure")
        } catch {
            guard case SQLiteRepositoryError.stepFailed = error else {
                return XCTFail("expected SQLite step failure, got \(error)")
            }
        }

        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot(),
            fixture.baseSnapshot
        )
        XCTAssertEqual(try syncRepository.auditLog(), [baselineAudit])
        XCTAssertNil(try syncRepository.metadata(for: "generic.download.lastFetch"))
    }

    private func assertDeleteRecreateDownload(
        kind: ClassificationItemKind,
        recordsReversed: Bool
    ) async throws {
        let databaseURL = makeDatabaseURL()
        let fixture = try makeDeleteRecreateFixture(kind: kind)
        let records = recordsReversed ? Array(fixture.records.reversed()) : fixture.records
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        try repository.save(fixture.baseSnapshot)

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: OrderedSyncTransport(records: records)
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 2,
                appliedCount: 2,
                waitingCount: 0,
                conflictCount: 0
            )
        )
        try assertDeleteRecreateState(
            try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot(),
            fixture: fixture
        )

        let restarted = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: OrderedSyncTransport(records: records)
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))
        XCTAssertEqual(restarted.waitingCount, 0)
        XCTAssertEqual(restarted.conflictCount, 0)
        try assertDeleteRecreateState(
            try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot(),
            fixture: fixture
        )
    }

    private func makeDeleteRecreateFixture(
        kind: ClassificationItemKind
    ) throws -> DeleteRecreateFixture {
        let source = SuntraceEngine()
        let historicalAlias: String
        let createIntent: ClassificationIntent
        switch kind {
        case .category:
            historicalAlias = "远端历史主分类别名"
            createIntent = .createCategory(name: historicalAlias, colorHex: "#2A6FDB")
        case .label:
            historicalAlias = "远端历史标签别名"
            createIntent = .createLabel(name: historicalAlias, colorHex: "#0E9488")
        }
        _ = try commitClassification(createIntent, to: source, at: now)

        let oldIdentity: TestClassificationIdentity
        let renameIntent: ClassificationIntent
        switch kind {
        case .category:
            let id = try XCTUnwrap(source.snapshot().classifications.categories.keys.first)
            oldIdentity = .category(id)
            renameIntent = .renameCategory(id, to: "删除前远端主分类名称")
        case .label:
            let id = try XCTUnwrap(source.snapshot().classifications.labels.keys.first)
            oldIdentity = .label(id)
            renameIntent = .renameLabel(id, to: "删除前远端标签名称")
        }
        _ = try commitClassification(
            renameIntent,
            to: source,
            at: now.addingTimeInterval(1)
        )
        let baseSnapshot = source.snapshot()

        let deleteIntent: ClassificationIntent = switch oldIdentity {
        case let .category(id):
            .hardDeleteCategory(id)
        case let .label(id):
            .hardDeleteLabel(id)
        }
        let deleteReceipt = try commitClassification(
            deleteIntent,
            to: source,
            at: now.addingTimeInterval(2)
        )
        let afterDelete = source.snapshot()
        let deleteEnvelope = try ClassificationCommitEnvelope(
            before: baseSnapshot.classifications,
            after: afterDelete.classifications,
            changeRecord: try XCTUnwrap(afterDelete.classifications.changeRecords.first {
                $0.id == deleteReceipt.changeRecordID
            })
        )

        let recreateIntent: ClassificationIntent = switch kind {
        case .category:
            .createCategory(
                name: "  \(historicalAlias)  ",
                colorHex: "#D1477A"
            )
        case .label:
            .createLabel(
                name: "  \(historicalAlias)  ",
                colorHex: "#7C5CFF"
            )
        }
        let recreateReceipt = try commitClassification(
            recreateIntent,
            to: source,
            at: now.addingTimeInterval(3)
        )
        let finalSnapshot = source.snapshot()
        let recreateEnvelope = try ClassificationCommitEnvelope(
            before: afterDelete.classifications,
            after: finalSnapshot.classifications,
            changeRecord: try XCTUnwrap(finalSnapshot.classifications.changeRecords.first {
                $0.id == recreateReceipt.changeRecordID
            })
        )
        XCTAssertTrue(
            recreateEnvelope.delta.mutation.predecessorChangeRecordIDs.contains(
                deleteReceipt.changeRecordID
            )
        )

        let newIdentity: TestClassificationIdentity = switch kind {
        case .category:
            .category(
                try XCTUnwrap(finalSnapshot.classifications.categories.values.first {
                    $0.name == historicalAlias
                }?.id)
            )
        case .label:
            .label(
                try XCTUnwrap(finalSnapshot.classifications.labels.values.first {
                    $0.name == historicalAlias
                }?.id)
            )
        }
        let mapper = SyncRecordMapper()
        return DeleteRecreateFixture(
            baseSnapshot: baseSnapshot,
            finalSnapshot: finalSnapshot,
            oldIdentity: oldIdentity,
            newIdentity: newIdentity,
            records: [
                try mapper.record(for: deleteEnvelope, modifiedBy: SyncDeviceID("iphone-delete")),
                try mapper.record(for: recreateEnvelope, modifiedBy: SyncDeviceID("iphone-recreate"))
            ]
        )
    }

    private func assertDeleteRecreateState(
        _ snapshot: SuntraceSnapshot,
        fixture: DeleteRecreateFixture
    ) throws {
        XCTAssertEqual(snapshot, fixture.finalSnapshot)
        XCTAssertNotEqual(fixture.oldIdentity, fixture.newIdentity)
        switch (fixture.oldIdentity, fixture.newIdentity) {
        case let (.category(oldID), .category(newID)):
            XCTAssertNil(snapshot.classifications.categories[oldID])
            XCTAssertNotNil(snapshot.classifications.categories[newID])
            XCTAssertNotNil(snapshot.classifications.categoryDeletionTombstones[oldID])
        case let (.label(oldID), .label(newID)):
            XCTAssertNil(snapshot.classifications.labels[oldID])
            XCTAssertNotNil(snapshot.classifications.labels[newID])
            XCTAssertNotNil(snapshot.classifications.labelDeletionTombstones[oldID])
        default:
            XCTFail("classification identity kind changed during recreation")
        }
    }

    @discardableResult
    private func commitClassification(
        _ intent: ClassificationIntent,
        to engine: SuntraceEngine,
        at date: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(),
            now: date
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: date
        )
    }

    private func makeClassificationEnvelope() throws -> (
        chainID: TaskChainID,
        chain: TaskChain,
        definition: TaskDefinition,
        envelope: ClassificationCommitEnvelope
    ) {
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "等待父任务链", now: now)
        let before = source.snapshot().classifications
        let plan = try source.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "同步", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "43000000-0000-0000-0000-000000000001")!,
            now: now
        )
        let receipt = try source.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "43000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let after = source.snapshot().classifications
        let record = try XCTUnwrap(
            after.changeRecords.first { $0.id == receipt.changeRecordID }
        )
        return (
            chainID,
            try XCTUnwrap(source.chains[chainID]),
            try XCTUnwrap(source.definitions.values.first(where: { $0.chainID == chainID })),
            try ClassificationCommitEnvelope(
                before: before,
                after: after,
                changeRecord: record
            )
        )
    }

    private func makeDatabaseURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-sync-download-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private enum TestClassificationIdentity: Equatable {
    case category(TaskCategoryID)
    case label(TaskLabelID)
}

private struct DeleteRecreateFixture {
    let baseSnapshot: SuntraceSnapshot
    let finalSnapshot: SuntraceSnapshot
    let oldIdentity: TestClassificationIdentity
    let newIdentity: TestClassificationIdentity
    let records: [SyncRecord]
}

private struct OrderedSyncTransport: SyncRecordTransport {
    let records: [SyncRecord]

    func push(_: [SyncRecord]) async throws {}

    func fetchAll() async throws -> [SyncRecord] {
        records
    }
}

private actor PendingInjectingTransport: SyncRecordTransport {
    let databaseURL: URL
    let waiting: SyncWaitingRecord
    let attemptedAt: Date
    let fetched: [SyncRecord]

    init(
        databaseURL: URL,
        waiting: SyncWaitingRecord,
        attemptedAt: Date,
        fetched: [SyncRecord]
    ) {
        self.databaseURL = databaseURL
        self.waiting = waiting
        self.attemptedAt = attemptedAt
        self.fetched = fetched
    }

    func push(_: [SyncRecord]) async throws {}

    func fetchAll() async throws -> [SyncRecord] {
        try SQLiteSyncRepository(databaseURL: databaseURL).reconcilePendingDownloads(
            waiting: [waiting],
            terminal: [],
            attemptedAt: attemptedAt
        )
        return fetched
    }
}

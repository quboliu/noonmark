@testable import NoonmarkCore
import NoonmarkDiagnostics
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteLocalFirstSyncCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testSyncTimestampsDistinguishSuccessfulCheckFromEffectiveTransfer()
        async throws
    {
        let databaseURL = makeDatabaseURL("sync-timestamps")
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(
            databaseURL: databaseURL
        )
        let transport = InMemorySyncTransport()
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let firstSyncAt = now
        try engineRepository.save(NoonmarkEngine().snapshot())

        _ = try await coordinator.sync(now: firstSyncAt)
        XCTAssertEqual(
            try syncTimestamps(in: syncRepository),
            SQLiteLocalFirstSyncTimestamps(
                lastSyncedAt: firstSyncAt,
                lastEffectiveSyncedAt: nil
            )
        )

        let engine = try engineRepository.load()
        _ = try engine.createPoolTask(
            title: "触发有效同步",
            now: now.addingTimeInterval(1)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("timestamp-device"),
            changedAt: now.addingTimeInterval(1)
        )
        let effectiveSyncAt = now.addingTimeInterval(2)
        _ = try await coordinator.sync(now: effectiveSyncAt)
        XCTAssertEqual(
            try syncTimestamps(in: syncRepository),
            SQLiteLocalFirstSyncTimestamps(
                lastSyncedAt: effectiveSyncAt,
                lastEffectiveSyncedAt: effectiveSyncAt
            )
        )

        let emptySyncAt = now.addingTimeInterval(3)
        _ = try await coordinator.sync(now: emptySyncAt)
        XCTAssertEqual(
            try syncTimestamps(in: syncRepository),
            SQLiteLocalFirstSyncTimestamps(
                lastSyncedAt: emptySyncAt,
                lastEffectiveSyncedAt: effectiveSyncAt
            )
        )
    }

    func testNonPositiveBatchLimitStillDrainsTheUploadQueue() async throws {
        let databaseURL = makeDatabaseURL("non-positive-batch-limit")
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "仍须完成同步", now: now)
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("mac-zero-limit"),
            changedAt: now
        )

        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport()
        ).sync(limit: 0, now: now.addingTimeInterval(1))

        XCTAssertEqual(
            result.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
    }

    func testSubtaskRenameSurvivesUploadAfterInitialSync() async throws {
        // FAIL-2026-08-06-01：production 症状级复现。子任务首版上传后再改名，
        // 修复前下一轮上传 preflight 必抛 invalidCurrentRecordMerge（251），
        // 失败条目被反复重选，形成确定性毒记录循环。
        let databaseURL = makeDatabaseURL("subtask-rename-upload")
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(
            databaseURL: databaseURL
        )
        let transport = InMemorySyncTransport()
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        let deviceID = SyncDeviceID("subtask-rename-device")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "同步改名 fixture",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let subtaskID = try engine.addSubtask(
            traceID: traceID,
            title: "同步前标题",
            now: now.addingTimeInterval(2)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now.addingTimeInterval(2)
        )
        _ = try await coordinator.sync(now: now.addingTimeInterval(3))

        try engine.updateSubtaskTitle(
            subtaskID,
            title: "同步后标题",
            today: today,
            now: now.addingTimeInterval(4)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now.addingTimeInterval(4)
        )

        _ = try await coordinator.sync(now: now.addingTimeInterval(5))

        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
        let remoteRecords = try await transport.fetchAll()
        let remoteSubtask = try XCTUnwrap(
            remoteRecords.first {
                $0.entityType == .subtask
                    && $0.entityID == subtaskID.rawValue.uuidString
            }
        )
        XCTAssertEqual(
            try SyncRecordMapper().decodeSubtask(remoteSubtask).title,
            "同步后标题"
        )

        // 毒记录循环已终止：后续例行检查同步不再失败。
        _ = try await coordinator.sync(now: now.addingTimeInterval(6))
    }

    func testSyncDrainsLocalMutationCreatedWhileDownloadIsInFlight()
        async throws
    {
        let databaseURL = makeDatabaseURL(
            "mutation-during-download"
        )
        let repository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(
            databaseURL: databaseURL
        )
        let deviceID = SyncDeviceID(
            "mutation-during-download-device"
        )
        try saveSyncIdentity(deviceID, databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "同步开始前已有",
            now: now
        )
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )

        let injectedAt = now.addingTimeInterval(1)
        let transport = DownloadMutationInjectingTransport {
            let concurrentRepository = SQLiteEngineRepository(
                databaseURL: databaseURL
            )
            let concurrentEngine = try concurrentRepository.load()
            _ = try concurrentEngine.createPoolTask(
                title: "下载期间新增",
                now: injectedAt
            )
            try concurrentRepository.save(
                concurrentEngine.snapshot(),
                recordingChangesFor: deviceID,
                changedAt: injectedAt
            )
        }

        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(2))

        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .pendingUpload
            ).isEmpty,
            "同步返回成功前必须排空下载期间新增的本机变更"
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )

        let targetURL = makeDatabaseURL(
            "mutation-during-download-target"
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        try targetRepository.save(NoonmarkEngine().snapshot())
        let targetResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(3))
        XCTAssertEqual(targetResult.download.waitingCount, 0)
        XCTAssertEqual(targetResult.download.conflictCount, 0)
        XCTAssertEqual(
            Set(try targetRepository.load().taskPool().map {
                $0.definition.title
            }),
            ["同步开始前已有", "下载期间新增"]
        )
    }

    func testEndpointResetDuringSyncFailsClosedInsteadOfInventingCoverage()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "endpoint-cleared-during-sync-source"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let sourceDeviceID = SyncDeviceID(
            "endpoint-cleared-during-sync-source"
        )
        let source = NoonmarkEngine()
        _ = try source.createPoolTask(
            title: "同步中端点重置必须阻断成功",
            now: now
        )
        try sourceRepository.save(
            source.snapshot(),
            recordingChangesFor: sourceDeviceID,
            changedAt: now
        )
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: sourceDeviceID,
                createdAt: now
            )
        )
        let transport =
            ClearAfterFirstPushBeforeNextFetchSyncTransport()

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: sourceURL,
                transport: transport
            ).sync(now: now.addingTimeInterval(1))
            XCTFail("endpoint reset must fail the sync operation")
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .repositoryFormatMismatch
            )
        }
        let didClearEndpoint = await transport.didClearEndpoint()
        let remoteRecords = try await transport.fetchAll()

        XCTAssertTrue(didClearEndpoint)
        XCTAssertTrue(remoteRecords.isEmpty)
        let statusMetadata = try XCTUnwrap(
            sourceSyncRepository.metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        guard case .failed = try JSONDecoder().decode(
            SQLiteLocalFirstSyncStatus.self,
            from: statusMetadata.value
        ) else {
            return XCTFail("endpoint reset must persist a failed status")
        }
    }

    func testRemoteChangeArrivingDuringSyncIsMergedBeforeSuccess()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "remote-change-during-sync"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let sourceDeviceID = SyncDeviceID(
            "remote-change-during-sync-source"
        )
        let source = NoonmarkEngine()
        _ = try source.createPoolTask(
            title: "本机同步事实",
            now: now
        )
        try sourceRepository.save(
            source.snapshot(),
            recordingChangesFor: sourceDeviceID,
            changedAt: now
        )
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: sourceDeviceID,
                createdAt: now
            )
        )

        let remote = NoonmarkEngine()
        let remoteChainID = try remote.createPoolTask(
            title: "同步期间从另一台设备到达",
            now: now.addingTimeInterval(1)
        )
        let remoteDeviceID = SyncDeviceID(
            "remote-change-during-sync-peer"
        )
        let remoteEntries = try SyncSnapshotBaselineBuilder()
            .journalEntries(
                from: remote.snapshot(),
                modifiedBy: remoteDeviceID,
                createdAt: now.addingTimeInterval(1)
            )
        let remoteRecords = try SyncRecordMaterializer().records(
            for: remoteEntries,
            in: remote.snapshot()
        )
        let transport =
            InjectRemoteRecordsOnSecondFetchSyncTransport(
                records: remoteRecords
            )

        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(2))
        let didInjectRemoteRecords =
            await transport.didInjectRemoteRecords()

        XCTAssertTrue(didInjectRemoteRecords)
        XCTAssertEqual(result.download.waitingCount, 0)
        XCTAssertEqual(result.download.conflictCount, 0)
        XCTAssertNotNil(
            try sourceRepository.load().chains[remoteChainID],
            "同步返回成功前必须合并最终抓取中新增的远端事实"
        )
    }

    func testImportedSnapshotEstablishesACompleteSyncBaseline()
        async throws
    {
        let sourceURL = makeDatabaseURL("import-baseline-source")
        let targetURL = makeDatabaseURL("import-baseline-target")
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let transport = InMemorySyncTransport()
        let sourceDevice = SyncDeviceIdentity(
            deviceID: SyncDeviceID("import-baseline-source-device"),
            createdAt: now
        )
        let importedEngine = NoonmarkEngine()
        let importedChainID = try importedEngine.createPoolTask(
            title: "数据包中的任务",
            now: now
        )

        try sourceRepository.replaceForDataImport(
            importedEngine.snapshot(),
            preserving: sourceDevice
        )
        try targetRepository.save(NoonmarkEngine().snapshot())

        let sourceResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(1))
        let targetResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(2))

        XCTAssertEqual(
            sourceResult.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertEqual(
            targetResult.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertEqual(
            try targetRepository.load().chains[importedChainID]?
                .id,
            importedChainID
        )
        XCTAssertEqual(targetResult.download.waitingCount, 0)
        XCTAssertEqual(targetResult.download.conflictCount, 0)
    }

    func testImportedSnapshotBaselinePreservesClassificationHistory()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "classified-import-baseline-source"
        )
        let targetURL = makeDatabaseURL(
            "classified-import-baseline-target"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let transport = InMemorySyncTransport()
        let sourceDevice = SyncDeviceIdentity(
            deviceID: SyncDeviceID(
                "classified-import-baseline-source-device"
            ),
            createdAt: now
        )
        let importedEngine = NoonmarkEngine()
        let importedChainID = try importedEngine.createPoolTask(
            title: "带分类历史的数据包任务",
            now: now
        )
        let importedTraceID = try importedEngine.scheduleFromPool(
            chainID: importedChainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        _ = try importedEngine.addSubtask(
            traceID: importedTraceID,
            title: "数据包子任务",
            now: now.addingTimeInterval(2)
        )
        try commitClassification(
            on: importedEngine,
            chainID: importedChainID,
            interactionID: UUID(
                uuidString: "52000000-0000-0000-0000-000000000001"
            )!,
            decisionID: UUID(
                uuidString: "52000000-0000-0000-0000-000000000002"
            )!,
            now: now.addingTimeInterval(3)
        )
        let importedSnapshot = importedEngine.snapshot()

        try sourceRepository.replaceForDataImport(
            importedSnapshot,
            preserving: sourceDevice
        )
        try targetRepository.save(NoonmarkEngine().snapshot())

        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(4))
        let targetResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(5))
        let restored = try targetRepository.load().snapshot()

        XCTAssertEqual(restored.days, importedSnapshot.days)
        XCTAssertEqual(restored.taskCycleSeries, importedSnapshot.taskCycleSeries)
        XCTAssertEqual(restored.chains, importedSnapshot.chains)
        XCTAssertEqual(restored.definitions, importedSnapshot.definitions)
        XCTAssertEqual(restored.traces, importedSnapshot.traces)
        XCTAssertEqual(restored.subtasks, importedSnapshot.subtasks)
        XCTAssertEqual(
            restored.classifications,
            importedSnapshot.classifications
        )
        XCTAssertEqual(targetResult.download.waitingCount, 0)
        XCTAssertEqual(targetResult.download.conflictCount, 0)
    }

    func testMissingCurrentJournalReseedsBeforeSync()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "missing-journal-baseline-source"
        )
        let targetURL = makeDatabaseURL(
            "missing-journal-baseline-target"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let transport = InMemorySyncTransport()
        let importedEngine = NoonmarkEngine()
        let chainID = try importedEngine.createPoolTask(
            title: "当前事实必须重新入队",
            now: now
        )
        try sourceRepository.save(importedEngine.snapshot())
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: SyncDeviceID("missing-journal-source-device"),
                createdAt: now
            )
        )
        try targetRepository.save(NoonmarkEngine().snapshot())

        let sourceResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(1))
        let targetResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(2))

        XCTAssertEqual(
            sourceResult.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertEqual(
            targetResult.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertNotNil(try targetRepository.load().chains[chainID])
    }

    func testUploadedJournalDoesNotPretendAnEmptyEndpointIsCovered()
        async throws
    {
        let sourceURL = makeDatabaseURL("endpoint-reseed-source")
        let targetURL = makeDatabaseURL("endpoint-reseed-target")
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let deviceID = SyncDeviceID("endpoint-reseed-device")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "必须进入新端点",
            now: now
        )
        try sourceRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(deviceID: deviceID, createdAt: now)
        )

        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: InMemorySyncTransport()
        ).sync(now: now.addingTimeInterval(1))
        XCTAssertTrue(
            try sourceSyncRepository.journalEntries(
                state: .pendingUpload
            ).isEmpty
        )

        let emptyEndpoint = InMemorySyncTransport()
        let reseedResult = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: emptyEndpoint
        ).sync(now: now.addingTimeInterval(2))
        try targetRepository.save(NoonmarkEngine().snapshot())
        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: emptyEndpoint
        ).sync(now: now.addingTimeInterval(3))

        XCTAssertGreaterThan(reseedResult.upload.uploadedCount, 0)
        XCTAssertNotNil(try targetRepository.load().chains[chainID])
    }

    func testStaleUploadedJournalDoesNotCoverANewerLocalFact()
        async throws
    {
        let sourceURL = makeDatabaseURL("stale-journal-source")
        let targetURL = makeDatabaseURL("stale-journal-target")
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let targetRepository = SQLiteEngineRepository(
            databaseURL: targetURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("stale-journal-device")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "已有上传记录",
            now: now
        )
        try sourceRepository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(deviceID: deviceID, createdAt: now)
        )
        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(1))

        let newerLocal = try sourceRepository.load()
        _ = try newerLocal.appendPoolNote(
            chainID: chainID,
            body: "不能被旧 journal 掩盖",
            now: now.addingTimeInterval(2)
        )
        try sourceRepository.save(newerLocal.snapshot())

        let repaired = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(3))
        try targetRepository.save(NoonmarkEngine().snapshot())
        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: targetURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(4))

        XCTAssertGreaterThan(repaired.upload.uploadedCount, 0)
        XCTAssertEqual(
            try targetRepository.load().chains[chainID]?
                .activeNoteEntries.map(\.body),
            ["不能被旧 journal 掩盖"]
        )
    }

    func testNewerRemoteTaskChainCannotHideALocalForkFromBaseline()
        async throws
    {
        let sourceURL = makeDatabaseURL("newer-remote-fork-source")
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "双方都有事实",
            now: now
        )
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        _ = try local.appendPoolNote(
            chainID: chainID,
            body: "本机旧数据包中的附言",
            now: now.addingTimeInterval(1)
        )
        _ = try remote.appendPoolNote(
            chainID: chainID,
            body: "远端较新的附言",
            now: now.addingTimeInterval(2)
        )
        try sourceRepository.save(local.snapshot())
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: SyncDeviceID("newer-remote-fork-source"),
                createdAt: now
            )
        )

        let remoteDevice = SyncDeviceID("newer-remote-fork-remote")
        let remoteEntries = try SyncSnapshotBaselineBuilder()
            .journalEntries(
                from: remote.snapshot(),
                modifiedBy: remoteDevice,
                createdAt: now.addingTimeInterval(3)
            )
        let remoteRecords = try SyncRecordMaterializer().records(
            for: remoteEntries,
            in: remote.snapshot()
        )
        let transport = try InMemorySyncTransport(records: remoteRecords)

        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(4))

        XCTAssertGreaterThan(result.upload.uploadedCount, 0)
        let finalRecords = try await transport.fetchAll()
        let canonicalRecord = try XCTUnwrap(
            finalRecords.first {
                $0.entityType == .taskChain
                    && $0.entityID == chainID.description
            }
        )
        let canonicalChain = try SyncRecordMapper().decodeTaskChain(
            canonicalRecord
        )
        XCTAssertEqual(
            Set(canonicalChain.activeNoteEntries.map(\.body)),
            ["本机旧数据包中的附言", "远端较新的附言"]
        )
    }

    func testMalformedRemoteClassificationEvidenceCannotHideBaseline()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "malformed-remote-classification-source"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(
            title: "分类证据不可伪造",
            now: now
        )
        try commitClassification(
            on: local,
            chainID: chainID,
            interactionID: UUID(
                uuidString: "54000000-0000-0000-0000-000000000001"
            )!,
            decisionID: UUID(
                uuidString: "54000000-0000-0000-0000-000000000002"
            )!,
            now: now.addingTimeInterval(1)
        )
        let snapshot = local.snapshot()
        try sourceRepository.save(snapshot)
        try sourceSyncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: SyncDeviceID(
                    "malformed-remote-classification-source"
                ),
                createdAt: now
            )
        )

        let remoteDevice = SyncDeviceID(
            "malformed-remote-classification-remote"
        )
        let baselineEntries = try SyncSnapshotBaselineBuilder()
            .journalEntries(
                from: snapshot,
                modifiedBy: remoteDevice,
                createdAt: now.addingTimeInterval(2)
            )
        var remoteRecords = try SyncRecordMaterializer().records(
            for: baselineEntries,
            in: snapshot
        )
        let baselineIndex = try XCTUnwrap(
            remoteRecords.firstIndex {
                $0.entityType == .classificationBaseline
            }
        )
        let validBaseline = remoteRecords[baselineIndex]
        remoteRecords[baselineIndex] = SyncRecord(
            id: SyncRecordID(
                "forged-classification-baseline:\(UUID().uuidString)"
            ),
            entityType: validBaseline.entityType,
            entityID: validBaseline.entityID,
            modifiedAt: validBaseline.modifiedAt,
            modifiedByDeviceID: validBaseline.modifiedByDeviceID,
            payload: validBaseline.payload
        )
        remoteRecords.append(
            SyncRecord(
                id: validBaseline.id,
                entityType: validBaseline.entityType,
                entityID: validBaseline.entityID,
                operation: .delete,
                modifiedAt: validBaseline.modifiedAt,
                modifiedByDeviceID:
                validBaseline.modifiedByDeviceID,
                payload: validBaseline.payload
            )
        )
        let transport = RawCurrentRecordSyncTransport(
            records: remoteRecords
        )

        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: sourceURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(3))

        XCTAssertGreaterThan(result.upload.uploadedCount, 0)
        let finalRecords = await transport.fetchAll()
        XCTAssertTrue(
            finalRecords.contains {
                $0.entityType == .classificationBaseline
                    && (try? SyncRecordMapper()
                        .decodeClassificationBaseline($0)) != nil
            }
        )
    }

    func testPartiallyUploadedPendingBaselineRejectsEndpointReplacement()
        async throws
    {
        let sourceURL = makeDatabaseURL(
            "partially-uploaded-baseline-source"
        )
        let sourceRepository = SQLiteEngineRepository(
            databaseURL: sourceURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceURL
        )
        let imported = NoonmarkEngine()
        let chainID = try imported.createPoolTask(
            title: "分批失败后仍能完整重试",
            now: now
        )
        try sourceRepository.replaceForDataImport(
            imported.snapshot(),
            preserving: SyncDeviceIdentity(
                deviceID: SyncDeviceID(
                    "partially-uploaded-baseline-source"
                ),
                createdAt: now
            )
        )
        let interruptedTransport = FailAfterFirstPushSyncTransport()

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: sourceURL,
                transport: interruptedTransport
            ).sync(limit: 1, now: now.addingTimeInterval(1))
            XCTFail("第二批上传失败时不得返回成功")
        } catch {
            XCTAssertEqual(
                error as? FailAfterFirstPushSyncTransport.Failure,
                .interrupted
            )
        }
        let interruptedEntries = try sourceSyncRepository
            .journalEntries()
        XCTAssertTrue(
            interruptedEntries.contains { $0.state == .uploaded }
        )
        XCTAssertTrue(
            interruptedEntries.contains { $0.state == .pendingUpload }
        )

        let emptyEndpoint = InMemorySyncTransport()
        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: sourceURL,
                transport: emptyEndpoint
            ).sync(limit: 1, now: now.addingTimeInterval(2))
            XCTFail("pending baseline must not reuse another endpoint's receipts")
        } catch {
            XCTAssertEqual(
                error as? SQLiteLocalFirstSyncError,
                .baselineManifestInvalid
            )
        }
        let replacementEndpointRecords = try await emptyEndpoint.fetchAll()
        XCTAssertTrue(replacementEndpointRecords.isEmpty)
        XCTAssertNotNil(try sourceRepository.load().chains[chainID])
    }

    func testInvalidBaselineManifestFailsClosedAndPersistsFailure()
        async throws
    {
        let databaseURL = makeDatabaseURL(
            "invalid-baseline-manifest"
        )
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "不能被静默遗漏",
            now: now
        )
        try engineRepository.save(engine.snapshot())
        try syncRepository.saveDeviceIdentity(
            SyncDeviceIdentity(
                deviceID: SyncDeviceID("invalid-manifest-device"),
                createdAt: now
            )
        )
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: SQLiteLocalFirstSyncCoordinator
                    .baselineManifestMetadataKey,
                value: Data("{}".utf8),
                updatedAt: now
            )
        )
        let transport = InMemorySyncTransport()
        let failureAt = now.addingTimeInterval(1)

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: transport,
                failureClock: { failureAt }
            ).sync(now: failureAt)
            XCTFail("损坏的完整基线不得被标记为同步成功")
        } catch {
            XCTAssertEqual(
                error as? SQLiteLocalFirstSyncError,
                .baselineManifestInvalid
            )
        }

        let remoteRecords = try await transport.fetchAll()
        XCTAssertTrue(remoteRecords.isEmpty)
        let statusMetadata = try XCTUnwrap(
            syncRepository.metadata(
                for: SQLiteLocalFirstSyncCoordinator
                    .lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: statusMetadata.value
            ),
            .failed(
                reason: .baselineInvalid,
                message: SQLiteLocalFirstSyncError
                    .baselineManifestInvalid.localizedDescription,
                failedAt: failureAt
            )
        )
        XCTAssertNil(
            try SQLiteLocalFirstSyncCoordinator.timestamps(
                in: syncRepository
            )
        )
    }

    func testUnmaterializableLocalRecordCannotProduceFalseSuccess()
        async throws
    {
        let databaseURL = makeDatabaseURL(
            "unmaterializable-local-record"
        )
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(
            databaseURL: databaseURL
        )
        try engineRepository.save(NoonmarkEngine().snapshot())
        try syncRepository.appendJournalEntry(
            SyncJournalEntry(
                entityType: .taskChain,
                entityID:
                "53000000-0000-0000-0000-000000000001",
                changedAt: now,
                deviceID: SyncDeviceID(
                    "unmaterializable-record-device"
                )
            )
        )
        let failureAt = now.addingTimeInterval(1)

        do {
            _ = try await SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: InMemorySyncTransport(),
                failureClock: { failureAt }
            ).sync(now: failureAt)
            XCTFail("无法物化的本机记录不得被标记为同步成功")
        } catch {
            XCTAssertEqual(
                error as? SQLiteLocalFirstSyncError,
                .uploadMaterializationFailed(count: 1)
            )
        }

        let statusMetadata = try XCTUnwrap(
            syncRepository.metadata(
                for: SQLiteLocalFirstSyncCoordinator
                    .lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: statusMetadata.value
            ),
            .failed(
                reason: .localRecordsUnpreparable,
                message: SQLiteLocalFirstSyncError
                    .uploadMaterializationFailed(count: 1)
                    .localizedDescription,
                failedAt: failureAt
            )
        )
        XCTAssertNil(
            try SQLiteLocalFirstSyncCoordinator.timestamps(
                in: syncRepository
            )
        )
    }

    private func syncTimestamps(
        in repository: SQLiteSyncRepository
    ) throws -> SQLiteLocalFirstSyncTimestamps {
        let metadata = try XCTUnwrap(
            repository.metadata(
                for: SQLiteLocalFirstSyncCoordinator
                    .timestampsMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SQLiteLocalFirstSyncTimestamps.self,
            from: metadata.value
        )
    }

    func testTaskChangeSummaryIsIndependentOfSameIDVariantOrder() throws {
        let mapper = SyncRecordMapper()
        let firstChain = TaskChain(
            id: TaskChainID(
                UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
            ),
            now: now
        )
        let secondChain = TaskChain(
            id: TaskChainID(
                UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let traceID = DayTraceID(
            UUID(uuidString: "51000000-0000-0000-0000-000000000003")!
        )
        let firstDefinitionID = TaskDefinitionID(
            UUID(uuidString: "51000000-0000-0000-0000-000000000004")!
        )
        let secondDefinitionID = TaskDefinitionID(
            UUID(uuidString: "51000000-0000-0000-0000-000000000005")!
        )
        let firstTrace = DayTrace(
            id: traceID,
            chainID: firstChain.id,
            definitionID: firstDefinitionID,
            date: today,
            priority: 0,
            now: now
        )
        let secondTrace = DayTrace(
            id: traceID,
            chainID: secondChain.id,
            definitionID: secondDefinitionID,
            date: today,
            priority: 0,
            now: now.addingTimeInterval(1)
        )
        let deviceID = SyncDeviceID("variant-order")
        let chainRecords = try [
            mapper.record(for: firstChain, modifiedBy: deviceID),
            mapper.record(for: secondChain, modifiedBy: deviceID)
        ]
        let firstTraceRecord = try mapper.record(
            for: firstTrace,
            modifiedBy: deviceID
        )
        let secondTraceRecord = try mapper.record(
            for: secondTrace,
            modifiedBy: deviceID
        )
        let before = chainRecords + [firstTraceRecord]
        let local = NoonmarkEngine().snapshot()
        let analyzer = SQLiteSyncTaskChangeAnalyzer()

        let forward = analyzer.changes(
            localBefore: local,
            localAfter: local,
            remoteBefore: before,
            remoteAfter: chainRecords
                + [firstTraceRecord, secondTraceRecord]
        )
        let reversed = analyzer.changes(
            localBefore: local,
            localAfter: local,
            remoteBefore: before.reversed(),
            remoteAfter: chainRecords.reversed()
                + [secondTraceRecord, firstTraceRecord]
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 1)
        )
    }

    func testOneSyncDrainsMoreThanOneInternalUploadBatch() async throws {
        let databaseURL = makeDatabaseURL("drain-upload-batches")
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let engine = NoonmarkEngine()

        for index in 1 ... 51 {
            _ = try engine.createPoolTask(
                title: "待同步任务 \(index)",
                now: now.addingTimeInterval(Double(index))
            )
        }
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("mac-batch"),
            changedAt: now.addingTimeInterval(100)
        )

        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).sync(now: now.addingTimeInterval(200))

        XCTAssertEqual(result.upload.uploadedCount, 102)
        XCTAssertEqual(
            result.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 51, updatedTaskCount: 0)
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(state: .pendingUpload).isEmpty
        )
        XCTAssertTrue(
            try syncRepository.journalEntries(
                state: .blockedCorruption
            ).isEmpty
        )
    }

    func testRecurringSeriesCountsAsOneUserTaskWithRecurringBreakdown() async throws {
        let databaseURL = makeDatabaseURL("recurring-task-summary")
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-recurring-task-summary")
        let engine = NoonmarkEngine()
        let seriesID = try engine.createTaskCycleSeries(
            title: "连续三天复盘",
            startDate: today,
            endDate: LocalDate("2026-07-07"),
            schedule: .daily,
            today: today,
            now: now
        )
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )

        let created = try await coordinator.sync(
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            created.taskChanges,
            SQLiteSyncTaskChanges(
                newTaskCount: 1,
                updatedTaskCount: 0,
                newRecurringTaskCount: 1,
                updatedRecurringTaskCount: 0
            )
        )

        let changedEngine = try repository.load()
        try changedEngine.skipTaskCycleOccurrence(
            seriesID: seriesID,
            occurrenceDate: LocalDate("2026-07-07"),
            today: today,
            now: now.addingTimeInterval(2)
        )
        try repository.save(
            changedEngine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now.addingTimeInterval(2)
        )

        let updated = try await coordinator.sync(
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(
            updated.taskChanges,
            SQLiteSyncTaskChanges(
                newTaskCount: 0,
                updatedTaskCount: 1,
                newRecurringTaskCount: 0,
                updatedRecurringTaskCount: 1
            )
        )
    }

    func testConvertingExistingTaskCountsAsOneRecurringTaskUpdate() async throws {
        let databaseURL = makeDatabaseURL("recurring-conversion-summary")
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let transport = InMemorySyncTransport()
        let deviceID = SyncDeviceID("mac-recurring-conversion-summary")
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "既有任务",
            now: now
        )
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now
        )
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )
        _ = try await coordinator.sync(
            now: now.addingTimeInterval(1)
        )

        let changedEngine = try repository.load()
        _ = try changedEngine.convertTaskToCycleSeries(
            chainID: chainID,
            startDate: today,
            endDate: LocalDate("2026-07-07"),
            schedule: .daily,
            today: today,
            now: now.addingTimeInterval(2)
        )
        try repository.save(
            changedEngine.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: now.addingTimeInterval(2)
        )

        let converted = try await coordinator.sync(
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(
            converted.taskChanges,
            SQLiteSyncTaskChanges(
                newTaskCount: 0,
                updatedTaskCount: 1,
                newRecurringTaskCount: 0,
                updatedRecurringTaskCount: 1
            )
        )
    }

    func testSyncReportsUniqueNewAndUpdatedTasksAcrossUploadAndDownload() async throws {
        let macURL = makeDatabaseURL("task-summary-mac")
        let phoneURL = makeDatabaseURL("task-summary-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let transport = InMemorySyncTransport()
        let macDevice = SyncDeviceID("mac-task-summary")
        let phoneDevice = SyncDeviceID("phone-task-summary")
        try saveSyncIdentity(macDevice, databaseURL: macURL)
        try saveSyncIdentity(phoneDevice, databaseURL: phoneURL)
        let firstClock = now.addingTimeInterval(10)
        let macEngine = NoonmarkEngine()
        let firstChainID = try macEngine.createPoolTask(
            title: "第一条任务",
            now: now
        )
        _ = try macEngine.createPoolTask(
            title: "第二条任务",
            now: now.addingTimeInterval(1)
        )
        _ = try macEngine.createPoolTask(
            title: "第三条任务",
            now: now.addingTimeInterval(2)
        )
        try macRepository.save(
            macEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: firstClock
        )
        try phoneRepository.save(NoonmarkEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: transport
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: transport
        )

        let uploaded = try await macSync.sync(
            now: now.addingTimeInterval(20)
        )
        XCTAssertEqual(
            uploaded.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 3, updatedTaskCount: 0)
        )

        let downloaded = try await phoneSync.sync(
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(
            downloaded.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 3, updatedTaskCount: 0)
        )

        let changedEngine = try macRepository.load()
        try changedEngine.renameTaskTitle(
            chainID: firstChainID,
            title: "第一条任务已更新",
            today: today,
            now: now.addingTimeInterval(40)
        )
        _ = try changedEngine.appendPoolNote(
            chainID: firstChainID,
            body: "同一任务的另一项内部变化",
            now: now.addingTimeInterval(41)
        )
        try macRepository.save(
            changedEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now.addingTimeInterval(41)
        )

        let updatedUpload = try await macSync.sync(
            now: now.addingTimeInterval(50)
        )
        XCTAssertEqual(
            updatedUpload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 1)
        )

        let updatedDownload = try await phoneSync.sync(
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(
            updatedDownload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 1)
        )

        let classifiedEngine = try macRepository.load()
        try commitClassification(
            on: classifiedEngine,
            chainID: firstChainID,
            interactionID: UUID(
                uuidString: "42000000-0000-0000-0000-000000000001"
            )!,
            decisionID: UUID(
                uuidString: "42000000-0000-0000-0000-000000000002"
            )!,
            now: now.addingTimeInterval(70)
        )
        try macRepository.save(
            classifiedEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now.addingTimeInterval(70)
        )

        let classifiedUpload = try await macSync.sync(
            now: now.addingTimeInterval(80)
        )
        XCTAssertEqual(
            classifiedUpload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 1)
        )

        let classifiedDownload = try await phoneSync.sync(
            now: now.addingTimeInterval(90)
        )
        XCTAssertEqual(
            classifiedDownload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 1)
        )
    }

    func testTwoSQLiteStoresSyncThroughLocalFolderEndpoint() async throws {
        let folderURL = makeFolderURL()
        let macURL = makeDatabaseURL("mac")
        let phoneURL = makeDatabaseURL("phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let macDevice = SyncDeviceID("mac-a")
        let phoneDevice = SyncDeviceID("phone-b")
        try saveSyncIdentity(macDevice, databaseURL: macURL)
        try saveSyncIdentity(phoneDevice, databaseURL: phoneURL)

        let macEngine = NoonmarkEngine()
        let chainID = try macEngine.createPoolTask(title: "同步到另一台设备", now: now)
        let traceID = try macEngine.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try macEngine.addSubtask(traceID: traceID, title: "写本地文件夹同步测试", now: now)
        try macRepository.save(macEngine.snapshot(), recordingChangesFor: macDevice, changedAt: now)
        let decisionID = UUID(uuidString: "41000000-0000-0000-0000-000000000002")!
        try commitClassification(
            on: macEngine,
            chainID: chainID,
            interactionID: UUID(uuidString: "41000000-0000-0000-0000-000000000001")!,
            decisionID: decisionID,
            now: now.addingTimeInterval(1)
        )
        try macRepository.save(
            macEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now.addingTimeInterval(1)
        )
        try phoneRepository.save(NoonmarkEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: LocalFolderSyncTransport(rootURL: folderURL)
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: LocalFolderSyncTransport(rootURL: folderURL)
        )

        let macUpload = try await macSync.sync(now: now.addingTimeInterval(10))
        let phoneDownload = try await phoneSync.sync(now: now.addingTimeInterval(20))
        let phoneEngine = try phoneRepository.load()

        XCTAssertGreaterThanOrEqual(macUpload.upload.uploadedCount, 6)
        XCTAssertEqual(
            macUpload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertGreaterThanOrEqual(phoneDownload.download.appliedCount, 6)
        XCTAssertEqual(
            phoneDownload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 1, updatedTaskCount: 0)
        )
        XCTAssertEqual(phoneDownload.download.waitingCount, 0)
        XCTAssertEqual(phoneDownload.download.conflictCount, 0)
        XCTAssertEqual(phoneEngine.getDayTodo(date: today).traces.first?.id, traceID)
        XCTAssertEqual(phoneEngine.subtasks.count, 1)
        let phoneClassification = phoneEngine.snapshot().classifications
        let macClassification = macEngine.snapshot().classifications
        XCTAssertEqual(phoneClassification, macClassification)
        let current = try XCTUnwrap(
            phoneClassification.currentByChainID[chainID]
        )
        let categoryID = try XCTUnwrap(current.categoryID)
        XCTAssertEqual(
            phoneClassification.categories[categoryID]?.name,
            "项目"
        )
        XCTAssertEqual(
            Set(current.labelIDs.compactMap {
                phoneClassification.labels[$0]?.name
            }),
            ["同步", "复盘"]
        )
        XCTAssertEqual(current.category?.source, .userDirect)
        XCTAssertTrue(current.labels.allSatisfy { $0.source == .userDirect })
        XCTAssertEqual(current.category?.decisionID, decisionID)
        XCTAssertTrue(current.labels.allSatisfy { $0.decisionID == decisionID })
        XCTAssertEqual(
            phoneClassification.committedReceiptsByInteractionID.count,
            1
        )

        phoneEngine.updateDailyReview(
            date: today,
            summary: "手机端补写复盘",
            unfinishedReason: nil,
            tomorrowNote: nil,
            now: now.addingTimeInterval(30)
        )
        try phoneRepository.save(phoneEngine.snapshot(), recordingChangesFor: phoneDevice, changedAt: now.addingTimeInterval(30))

        let phoneUpload = try await phoneSync.sync(now: now.addingTimeInterval(40))
        let macDownload = try await macSync.sync(now: now.addingTimeInterval(50))
        let restoredMac = try macRepository.load()

        XCTAssertEqual(phoneUpload.upload.uploadedCount, 1)
        XCTAssertEqual(
            phoneUpload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 0)
        )
        XCTAssertGreaterThanOrEqual(macDownload.download.appliedCount, 1)
        XCTAssertEqual(
            macDownload.taskChanges,
            SQLiteSyncTaskChanges(newTaskCount: 0, updatedTaskCount: 0)
        )
        XCTAssertEqual(macDownload.download.waitingCount, 0)
        XCTAssertEqual(restoredMac.days[today]?.reviewSummary, "手机端补写复盘")
        let statusMetadata = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: macURL).metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: statusMetadata.value
            ),
            .succeeded(macDownload)
        )
    }

    func testFatalTransportFailurePersistsTheLatestSyncStatus() async throws {
        let databaseURL = makeDatabaseURL("failure-status")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let previousSyncAt = now.addingTimeInterval(-1)
        _ = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport()
        ).sync(now: previousSyncAt)
        let failureAt = now
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: FailingFetchSyncTransport(),
            failureClock: { failureAt }
        )

        do {
            _ = try await coordinator.sync(now: now)
            XCTFail("致命传输失败必须向调用方抛出")
        } catch {
            XCTAssertEqual(
                error as? FailingFetchSyncTransportError,
                .unavailable
            )
        }

        let metadata = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL).metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(SQLiteLocalFirstSyncStatus.self, from: metadata.value),
            .failed(
                reason: .transportOrStorage,
                message: FailingFetchSyncTransportError.unavailable.localizedDescription,
                failedAt: failureAt
            )
        )
        XCTAssertEqual(metadata.updatedAt, failureAt)
        XCTAssertEqual(
            try syncTimestamps(
                in: SQLiteSyncRepository(databaseURL: databaseURL)
            ),
            SQLiteLocalFirstSyncTimestamps(
                lastSyncedAt: previousSyncAt,
                lastEffectiveSyncedAt: nil
            )
        )
    }

    func testNewerInterruptedOperationReplacesOlderPersistedFailureCorrelation()
        throws
    {
        let databaseURL = makeDatabaseURL("interrupted-correlation")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let olderCorrelation = DiagnosticOperationCorrelation(
            operationID: DiagnosticOperationID(),
            incidentID: DiagnosticIncidentID()
        )
        try SQLiteLocalFirstSyncCoordinator.persistFailure(
            FailingFetchSyncTransportError.unavailable,
            at: now,
            diagnosticCorrelation: olderCorrelation,
            in: repository
        )
        let interruptedAt = now.addingTimeInterval(30.875)
        let interruptedCorrelation = DiagnosticOperationCorrelation(
            operationID: DiagnosticOperationID(),
            incidentID: DiagnosticIncidentID()
        )

        XCTAssertTrue(
            try SQLiteLocalFirstSyncCoordinator
                .persistInterruptedSyncFailureIfNewer(
                    at: interruptedAt,
                    diagnosticCorrelation: interruptedCorrelation,
                    in: repository
                )
        )

        let metadata = try XCTUnwrap(
            repository.metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: metadata.value
            ),
            .failed(
                reason: .operationInterrupted,
                message: SQLiteLocalFirstSyncError
                    .previousSessionInterrupted.localizedDescription,
                failedAt: now.addingTimeInterval(30),
                diagnosticCorrelation: interruptedCorrelation
            )
        )
    }

    func testSameSecondInterruptedOperationReplacesDistinctPersistedFailure()
        throws
    {
        let databaseURL = makeDatabaseURL("same-second-interruption")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let persistedAt = now.addingTimeInterval(30)
        try SQLiteLocalFirstSyncCoordinator.persistFailure(
            FailingFetchSyncTransportError.unavailable,
            at: persistedAt,
            diagnosticCorrelation: DiagnosticOperationCorrelation(
                operationID: DiagnosticOperationID(),
                incidentID: DiagnosticIncidentID()
            ),
            in: repository
        )
        let interruptedCorrelation = DiagnosticOperationCorrelation(
            operationID: DiagnosticOperationID(),
            incidentID: DiagnosticIncidentID()
        )

        XCTAssertTrue(
            try SQLiteLocalFirstSyncCoordinator
                .persistInterruptedSyncFailureIfNewer(
                    at: persistedAt.addingTimeInterval(0.875),
                    diagnosticCorrelation: interruptedCorrelation,
                    in: repository
                )
        )

        let metadata = try XCTUnwrap(
            repository.metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: metadata.value
            ),
            .failed(
                reason: .operationInterrupted,
                message: SQLiteLocalFirstSyncError
                    .previousSessionInterrupted.localizedDescription,
                failedAt: persistedAt,
                diagnosticCorrelation: interruptedCorrelation
            )
        )
    }

    func testSameSecondInterruptedOperationCannotReplaceSuccessfulSync()
        async throws
    {
        let databaseURL = makeDatabaseURL("same-second-success")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let repository = SQLiteSyncRepository(databaseURL: databaseURL)
        let syncedAt = now.addingTimeInterval(30)
        let result = try await SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport()
        ).sync(now: syncedAt)

        XCTAssertFalse(
            try SQLiteLocalFirstSyncCoordinator
                .persistInterruptedSyncFailureIfNewer(
                    at: syncedAt.addingTimeInterval(0.875),
                    diagnosticCorrelation: DiagnosticOperationCorrelation(
                        operationID: DiagnosticOperationID(),
                        incidentID: DiagnosticIncidentID()
                    ),
                    in: repository
                )
        )

        let metadata = try XCTUnwrap(
            repository.metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(
                SQLiteLocalFirstSyncStatus.self,
                from: metadata.value
            ),
            .succeeded(result)
        )
    }

    func testPersistedFailureTimestampExactlyMatchesDiagnosticTerminalEvent()
        async throws
    {
        let databaseURL = makeDatabaseURL("failure-correlation-timestamp")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let syncStartedAt = now.addingTimeInterval(0.875)
        let observedFailureAt = syncStartedAt.addingTimeInterval(90.5)
        let persistedFailureAt = now.addingTimeInterval(91)
        let operationStartedAt = syncStartedAt.addingTimeInterval(-5)
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: operationStartedAt
        )
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: SlowFailingFetchSyncTransport(),
            diagnosticOperation: operation,
            completesDiagnosticOperationOnSuccess: true,
            completesDiagnosticOperationOnFailure: true,
            diagnosticHeartbeatIntervalNanoseconds: 30_000_000_000,
            failureClock: { observedFailureAt }
        )
        let wallStartedAt = Date()

        do {
            _ = try await coordinator.sync(now: syncStartedAt)
            XCTFail("致命传输失败必须向调用方抛出")
        } catch {
            XCTAssertEqual(
                error as? SlowFailingFetchSyncTransport.Failure,
                .unavailable
            )
        }
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(wallStartedAt),
            0.04
        )

        let metadata = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL).metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(
            SQLiteLocalFirstSyncStatus.self,
            from: metadata.value
        )
        guard case let .failed(_, _, failedAt, _) = status else {
            return XCTFail("必须保存失败状态")
        }
        let terminal = try XCTUnwrap(
            recorder.snapshot().last {
                $0.event.code == .operationFailed
            }
        )

        XCTAssertEqual(failedAt, persistedFailureAt)
        XCTAssertEqual(metadata.updatedAt, persistedFailureAt)
        XCTAssertEqual(terminal.timestamp, persistedFailureAt)
        XCTAssertEqual(
            terminal.event.durationMilliseconds,
            Int64(
                persistedFailureAt.timeIntervalSince(operationStartedAt)
                    * 1000
            )
        )
        XCTAssertEqual(
            terminal.event.failure,
            DiagnosticFailure(domain: .syncProtocol, code: 7)
        )
        XCTAssertEqual(
            terminal.event.failureDetail,
            DiagnosticFailure(domain: .unknown, code: 0)
        )
    }

    func testLatestSameSecondFailurePersistsItsExactDiagnosticCorrelation()
        async throws
    {
        let databaseURL = makeDatabaseURL("same-second-failure-correlation")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let failedAt = now.addingTimeInterval(91)
        let recorder = InMemoryDiagnosticRecorder()
        let firstOperation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .localFolder,
            at: failedAt.addingTimeInterval(-2)
        )
        let secondOperation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .localFolder,
            at: failedAt.addingTimeInterval(-1)
        )

        for operation in [firstOperation, secondOperation] {
            let coordinator = SQLiteLocalFirstSyncCoordinator(
                databaseURL: databaseURL,
                transport: FailingFetchSyncTransport(),
                diagnosticOperation: operation,
                completesDiagnosticOperationOnSuccess: true,
                completesDiagnosticOperationOnFailure: true,
                diagnosticHeartbeatIntervalNanoseconds: 30_000_000_000,
                failureClock: { failedAt }
            )
            do {
                _ = try await coordinator.sync(now: failedAt)
                XCTFail("同秒故障注入必须向调用方抛出")
            } catch {
                XCTAssertEqual(
                    error as? FailingFetchSyncTransportError,
                    .unavailable
                )
            }
        }

        let metadata = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL).metadata(
                for: SQLiteLocalFirstSyncCoordinator.lastStatusMetadataKey
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(
            SQLiteLocalFirstSyncStatus.self,
            from: metadata.value
        )
        guard case let .failed(_, _, persistedFailedAt, correlation) = status
        else {
            return XCTFail("最新失败必须保存精确诊断关联")
        }
        let latestTerminal = try XCTUnwrap(
            recorder.snapshot().last {
                $0.event.code == .operationFailed
            }
        )

        XCTAssertEqual(persistedFailedAt, failedAt)
        XCTAssertEqual(correlation?.operationID, secondOperation.id)
        XCTAssertEqual(correlation?.incidentID, latestTerminal.event.incidentID)
        XCTAssertNotEqual(correlation?.operationID, firstOperation.id)
    }

    func testLongSyncWithoutSafeProgressDoesNotEmitHeartbeat()
        async throws
    {
        let databaseURL = makeDatabaseURL("diagnostic-heartbeat")
        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            NoonmarkEngine().snapshot()
        )
        let syncStartedAt = Date()
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: syncStartedAt.addingTimeInterval(-31)
        )
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: SlowFailingFetchSyncTransport(),
            diagnosticOperation: operation,
            completesDiagnosticOperationOnSuccess: false,
            completesDiagnosticOperationOnFailure: false,
            diagnosticHeartbeatIntervalNanoseconds: 5_000_000
        )

        do {
            _ = try await coordinator.sync(now: syncStartedAt)
            XCTFail("测试 transport 必须失败")
        } catch {
            XCTAssertEqual(
                error as? SlowFailingFetchSyncTransport.Failure,
                .unavailable
            )
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        let records = recorder.snapshot()
        XCTAssertFalse(
            records.contains { $0.event.code == .operationHeartbeat }
        )
        XCTAssertFalse(
            records.contains { $0.event.code.isTerminal }
        )
        operation.fail(
            DiagnosticFailure(domain: .syncProtocol, code: 7)
        )
    }

    func testLongSyncEmitsHeartbeatForChangedSafeUploadProgressAndStops()
        async throws
    {
        let databaseURL = makeDatabaseURL("diagnostic-progress-heartbeat")
        let repository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        for index in 1 ... 2 {
            _ = try engine.createPoolTask(
                title: "heartbeat task \(index)",
                now: now.addingTimeInterval(Double(index))
            )
        }
        try repository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("heartbeat-device"),
            changedAt: now.addingTimeInterval(3)
        )
        let syncStartedAt = Date()
        let recorder = InMemoryDiagnosticRecorder()
        let operation = recorder.startOperation(
            kind: .localFirstSync,
            endpoint: .iCloudDrive,
            at: syncStartedAt.addingTimeInterval(-31)
        )
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: SlowPushSyncTransport(),
            diagnosticOperation: operation,
            completesDiagnosticOperationOnSuccess: false,
            completesDiagnosticOperationOnFailure: false,
            diagnosticHeartbeatIntervalNanoseconds: 5_000_000
        )

        _ = try await coordinator.sync(limit: 1, now: syncStartedAt)
        let heartbeatCountAfterReturn = recorder.snapshot().filter {
            $0.event.code == .operationHeartbeat
        }.count
        try await Task.sleep(nanoseconds: 30_000_000)
        let records = recorder.snapshot()
        let heartbeats = records.filter {
            $0.event.code == .operationHeartbeat
        }

        XCTAssertEqual(heartbeatCountAfterReturn, 1)
        XCTAssertEqual(heartbeats.count, heartbeatCountAfterReturn)
        XCTAssertEqual(heartbeats.first?.event.stage, .upload)
        XCTAssertGreaterThan(
            heartbeats.first?.event.progress?.recordCount ?? 0,
            0
        )
        XCTAssertFalse(records.contains { $0.event.code.isTerminal })
        operation.succeed()
    }

    func testTwoSQLiteStoresConvergeConcurrentTaskNoteForksThroughSharedTransport() async throws {
        let macURL = makeDatabaseURL("note-fork-mac")
        let phoneURL = makeDatabaseURL("note-fork-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let transport = InMemorySyncTransport()
        let macDevice = SyncDeviceID("mac-note-device")
        let phoneDevice = SyncDeviceID("phone-note-device")
        try saveSyncIdentity(macDevice, databaseURL: macURL)
        try saveSyncIdentity(phoneDevice, databaseURL: phoneURL)

        let baselineEngine = NoonmarkEngine()
        let chainID = try baselineEngine.createPoolTask(
            title: "离线附言收敛",
            initialNoteBody: "共同旧附言",
            now: now
        )
        let baselineChain = try XCTUnwrap(
            baselineEngine.snapshot().chains.first { $0.id == chainID }
        )
        let oldNoteID = try XCTUnwrap(baselineChain.noteEntries.first?.id)
        try macRepository.save(
            baselineEngine.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now
        )
        try phoneRepository.save(NoonmarkEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: transport
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: transport
        )

        _ = try await macSync.sync(now: now.addingTimeInterval(10))
        let baselineDownload = try await phoneSync.sync(now: now.addingTimeInterval(20))
        XCTAssertEqual(baselineDownload.download.conflictCount, 0)
        XCTAssertEqual(baselineDownload.download.waitingCount, 0)
        XCTAssertEqual(
            try phoneRepository.load().snapshot().definitions,
            baselineEngine.snapshot().definitions
        )

        let forkTime = now.addingTimeInterval(100)
        let macFork = try macRepository.load()
        let macNoteID = try macFork.appendPoolNote(
            chainID: chainID,
            body: "Mac 离线新增",
            now: forkTime
        )
        try macFork.deletePoolNote(
            chainID: chainID,
            noteID: oldNoteID,
            now: forkTime
        )
        try macRepository.save(
            macFork.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: forkTime
        )

        let phoneFork = try phoneRepository.load()
        let phoneNoteID = try phoneFork.appendPoolNote(
            chainID: chainID,
            body: "Phone 离线新增",
            now: forkTime
        )
        try phoneFork.editPoolNote(
            chainID: chainID,
            noteID: oldNoteID,
            body: "Phone 同刻编辑旧附言",
            now: forkTime
        )
        try phoneRepository.save(
            phoneFork.snapshot(),
            recordingChangesFor: phoneDevice,
            changedAt: forkTime
        )

        for (coordinator, offset) in [
            (macSync, 110.0),
            (phoneSync, 120.0),
            (macSync, 130.0),
            (phoneSync, 140.0)
        ] {
            let result = try await coordinator.sync(now: now.addingTimeInterval(offset))
            XCTAssertEqual(result.download.conflictCount, 0)
            XCTAssertEqual(result.download.waitingCount, 0)
        }

        let remoteRecords = try await transport.fetchAll()
        let remoteRecord = try XCTUnwrap(remoteRecords.first {
            $0.entityType == .taskChain
                && $0.entityID == baselineChain.id.description
        })
        let remoteChain = try SyncRecordMapper().decodeTaskChain(remoteRecord)
        let macChain = try XCTUnwrap(
            try macRepository.load().snapshot().chains.first {
                $0.id == baselineChain.id
            }
        )
        let phoneChain = try XCTUnwrap(
            try phoneRepository.load().snapshot().chains.first {
                $0.id == baselineChain.id
            }
        )

        for chain in [macChain, phoneChain, remoteChain] {
            assertConvergedNotes(
                chain.noteEntries,
                oldNoteID: oldNoteID,
                macNoteID: macNoteID,
                phoneNoteID: phoneNoteID,
                forkTime: forkTime
            )
        }
        XCTAssertEqual(macChain.noteEntries, phoneChain.noteEntries)
        XCTAssertEqual(phoneChain.noteEntries, remoteChain.noteEntries)
    }

    func testPoolNoteMutationsRemainVisibleWhenRenameHappensOffline() async throws {
        for mutation in PoolNoteForkMutation.allCases {
            let macURL = makeDatabaseURL("rename-note-\(mutation.rawValue)-mac")
            let phoneURL = makeDatabaseURL("rename-note-\(mutation.rawValue)-phone")
            let macRepository = SQLiteEngineRepository(databaseURL: macURL)
            let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
            let transport = InMemorySyncTransport()
            let macDevice = SyncDeviceID("mac-rename-device")
            let phoneDevice = SyncDeviceID("phone-note-device")
            try saveSyncIdentity(macDevice, databaseURL: macURL)
            try saveSyncIdentity(phoneDevice, databaseURL: phoneURL)

            let baseline = NoonmarkEngine()
            let chainID = try baseline.createPoolTask(
                title: "重命名前",
                initialNoteBody: "共同旧附言",
                now: now
            )
            let originalNoteID = try XCTUnwrap(
                baseline.chains[chainID]?.activeNoteEntries.first?.id
            )
            let traceID = try baseline.scheduleFromPool(
                chainID: chainID,
                date: today,
                today: today,
                now: now
            )
            try baseline.returnToPool(
                traceID: traceID,
                today: today,
                now: now.addingTimeInterval(1)
            )
            try macRepository.save(
                baseline.snapshot(),
                recordingChangesFor: macDevice,
                changedAt: now.addingTimeInterval(1)
            )
            try phoneRepository.save(NoonmarkEngine().snapshot())

            let macSync = SQLiteLocalFirstSyncCoordinator(
                databaseURL: macURL,
                transport: transport
            )
            let phoneSync = SQLiteLocalFirstSyncCoordinator(
                databaseURL: phoneURL,
                transport: transport
            )
            _ = try await macSync.sync(now: now.addingTimeInterval(2))
            _ = try await phoneSync.sync(now: now.addingTimeInterval(3))

            let macFork = try macRepository.load()
            try macFork.renameTaskTitle(
                chainID: chainID,
                title: "重命名后",
                today: today,
                now: now.addingTimeInterval(10)
            )
            try macRepository.save(
                macFork.snapshot(),
                recordingChangesFor: macDevice,
                changedAt: now.addingTimeInterval(10)
            )

            let phoneFork = try phoneRepository.load()
            switch mutation {
            case .add:
                _ = try phoneFork.appendPoolNote(
                    chainID: chainID,
                    body: "Phone 离线新增附言",
                    now: now.addingTimeInterval(20)
                )
            case .edit:
                try phoneFork.editPoolNote(
                    chainID: chainID,
                    noteID: originalNoteID,
                    body: "Phone 离线编辑附言",
                    now: now.addingTimeInterval(20)
                )
            case .delete:
                try phoneFork.deletePoolNote(
                    chainID: chainID,
                    noteID: originalNoteID,
                    now: now.addingTimeInterval(20)
                )
            }
            try phoneRepository.save(
                phoneFork.snapshot(),
                recordingChangesFor: phoneDevice,
                changedAt: now.addingTimeInterval(20)
            )

            for (coordinator, offset) in [
                (macSync, 30.0),
                (phoneSync, 40.0),
                (macSync, 50.0),
                (phoneSync, 60.0)
            ] {
                let result = try await coordinator.sync(
                    now: now.addingTimeInterval(offset)
                )
                XCTAssertEqual(result.download.conflictCount, 0)
                XCTAssertEqual(result.download.waitingCount, 0)
            }

            let remoteRecords = try await transport.fetchAll()
            let remoteRecord = try XCTUnwrap(
                remoteRecords.first {
                    $0.entityType == .taskChain
                        && $0.entityID == chainID.description
                }
            )
            let remoteChain = try SyncRecordMapper().decodeTaskChain(remoteRecord)
            let tasks = try [macRepository, phoneRepository].map { repository in
                try XCTUnwrap(try repository.load().taskPool().first)
            }
            for task in tasks {
                XCTAssertEqual(task.definition.title, "重命名后")
                XCTAssertEqual(task.chain.noteEntries, remoteChain.noteEntries)
                switch mutation {
                case .add:
                    XCTAssertEqual(
                        task.chain.activeNoteEntries.map(\.body),
                        ["共同旧附言", "Phone 离线新增附言"]
                    )
                case .edit:
                    XCTAssertEqual(
                        task.chain.activeNoteEntries.map(\.body),
                        ["Phone 离线编辑附言"]
                    )
                case .delete:
                    XCTAssertTrue(task.chain.activeNoteEntries.isEmpty)
                    XCTAssertTrue(
                        task.chain.noteEntries.first {
                            $0.id == originalNoteID
                        }?.isDeleted == true
                    )
                }
            }
        }
    }

    func testLockedDayRejectsAStaleCompletedUndoAcrossTwoSQLiteStores() async throws {
        let macURL = makeDatabaseURL("locked-undo-mac")
        let phoneURL = makeDatabaseURL("locked-undo-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let transport = InMemorySyncTransport()
        let macDevice = SyncDeviceID("mac-locked-undo-device")
        let phoneDevice = SyncDeviceID("phone-locked-undo-device")
        try saveSyncIdentity(macDevice, databaseURL: macURL)
        try saveSyncIdentity(phoneDevice, databaseURL: phoneURL)

        let baseline = NoonmarkEngine()
        let chainID = try baseline.createPoolTask(
            title: "锁定后不可撤销完成",
            now: now
        )
        let traceID = try baseline.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now
        )
        try macRepository.save(
            baseline.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: now
        )
        try phoneRepository.save(NoonmarkEngine().snapshot())

        let macSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: macURL,
            transport: transport
        )
        let phoneSync = SQLiteLocalFirstSyncCoordinator(
            databaseURL: phoneURL,
            transport: transport
        )
        _ = try await macSync.sync(now: now.addingTimeInterval(1))
        _ = try await phoneSync.sync(now: now.addingTimeInterval(2))

        let completedAt = now.addingTimeInterval(10)
        let macCompleted = try macRepository.load()
        try macCompleted.markCompleted(
            traceID: traceID,
            today: today,
            now: completedAt
        )
        try macRepository.save(
            macCompleted.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: completedAt
        )
        _ = try await macSync.sync(now: now.addingTimeInterval(11))
        _ = try await phoneSync.sync(now: now.addingTimeInterval(12))

        let stalePhoneSnapshot = try phoneRepository.load().snapshot()
        XCTAssertEqual(
            stalePhoneSnapshot.traces.first { $0.id == traceID }?.status,
            .completed
        )
        XCTAssertNil(stalePhoneSnapshot.days.first { $0.date == today }?.lockedAt)

        let lockedAt = now.addingTimeInterval(20)
        let macLocked = try macRepository.load()
        try macLocked.settleDays(
            upTo: LocalDate("2026-07-06"),
            now: lockedAt
        )
        try macRepository.save(
            macLocked.snapshot(),
            recordingChangesFor: macDevice,
            changedAt: lockedAt
        )
        _ = try await macSync.sync(now: now.addingTimeInterval(21))

        let stalePhone = try phoneRepository.load()
        try stalePhone.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(30)
        )
        try phoneRepository.save(
            stalePhone.snapshot(),
            recordingChangesFor: phoneDevice,
            changedAt: now.addingTimeInterval(30)
        )

        for (coordinator, offset) in [
            (phoneSync, 31.0),
            (macSync, 32.0),
            (phoneSync, 33.0),
            (macSync, 34.0)
        ] {
            let result = try await coordinator.sync(
                now: now.addingTimeInterval(offset)
            )
            XCTAssertEqual(result.download.conflictCount, 0)
            XCTAssertEqual(result.download.waitingCount, 0)
        }

        let remoteRecords = try await transport.fetchAll()
        let mapper = SyncRecordMapper()
        let remoteDay = try mapper.decodeDay(
            XCTUnwrap(remoteRecords.first {
                $0.entityType == .day && $0.entityID == today.description
            })
        )
        let remoteTrace = try mapper.decodeDayTrace(
            XCTUnwrap(remoteRecords.first {
                $0.entityType == .dayTrace
                    && $0.entityID == traceID.description
            })
        )
        XCTAssertEqual(remoteDay.lockedAt, lockedAt)
        XCTAssertEqual(remoteTrace.status, .completed)
        XCTAssertEqual(remoteTrace.completedAt, completedAt)

        for repository in [macRepository, phoneRepository] {
            let snapshot = try repository.load().snapshot()
            XCTAssertEqual(
                snapshot.days.first { $0.date == today }?.lockedAt,
                lockedAt
            )
            let trace = try XCTUnwrap(
                snapshot.traces.first { $0.id == traceID }
            )
            XCTAssertEqual(trace.status, .completed)
            XCTAssertEqual(trace.completedAt, completedAt)
        }
    }

    private func commitClassification(
        on engine: NoonmarkEngine,
        chainID: TaskChainID,
        interactionID: UUID,
        decisionID: UUID,
        now: Date
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "项目", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "同步", colorHex: "#0E9488"),
                        .new(name: "复盘", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )
    }

    private func saveSyncIdentity(
        _ deviceID: SyncDeviceID,
        databaseURL: URL
    ) throws {
        try SQLiteSyncRepository(databaseURL: databaseURL)
            .saveDeviceIdentity(
                SyncDeviceIdentity(
                    deviceID: deviceID,
                    createdAt: now
                )
            )
    }

    private func assertConvergedNotes(
        _ notes: [TaskNoteEntry],
        oldNoteID: TaskNoteEntryID,
        macNoteID: TaskNoteEntryID,
        phoneNoteID: TaskNoteEntryID,
        forkTime: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            Set(notes.map(\.id)),
            [oldNoteID, macNoteID, phoneNoteID],
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(notes.filter { !$0.isDeleted }.map(\.id)),
            [macNoteID, phoneNoteID],
            file: file,
            line: line
        )
        let oldNote = notes.first { $0.id == oldNoteID }
        XCTAssertEqual(oldNote?.body, "", file: file, line: line)
        XCTAssertEqual(oldNote?.updatedAt, forkTime, file: file, line: line)
        XCTAssertEqual(oldNote?.deletedAt, forkTime, file: file, line: line)
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-local-first-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeFolderURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-local-first-folder-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private enum PoolNoteForkMutation: String, CaseIterable {
        case add
        case edit
        case delete
    }
}

private enum FailingFetchSyncTransportError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "E2E transport unavailable"
    }
}

private actor FailingFetchSyncTransport: SyncRecordTransport {
    func push(_: [SyncRecord]) async throws {}

    func fetchAll() async throws -> [SyncRecord] {
        throw FailingFetchSyncTransportError.unavailable
    }
}

private actor SlowFailingFetchSyncTransport: SyncRecordTransport {
    enum Failure: Error, Equatable {
        case unavailable
    }

    func push(_: [SyncRecord]) async throws {}

    func fetchAll() async throws -> [SyncRecord] {
        try await Task.sleep(nanoseconds: 50_000_000)
        throw Failure.unavailable
    }
}

private actor SlowPushSyncTransport: SyncRecordTransport {
    private let backing = InMemorySyncTransport()

    func push(_ records: [SyncRecord]) async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
        try await backing.push(records)
    }

    func fetchAll() async throws -> [SyncRecord] {
        try await backing.fetchAll()
    }
}

private actor RawCurrentRecordSyncTransport: SyncRecordTransport {
    private var recordsByID: [SyncRecordID: SyncRecord]

    init(records: [SyncRecord]) {
        recordsByID = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id, $0) }
        )
    }

    func push(_ records: [SyncRecord]) async throws {
        for record in records {
            recordsByID[record.id] = record
        }
    }

    func fetchAll() async -> [SyncRecord] {
        Array(recordsByID.values)
    }
}

private actor FailAfterFirstPushSyncTransport: SyncRecordTransport {
    enum Failure: Error, Equatable {
        case interrupted
    }

    private let backing = InMemorySyncTransport()
    private var completedPushCount = 0

    func push(_ records: [SyncRecord]) async throws {
        guard completedPushCount == 0 else {
            throw Failure.interrupted
        }
        try await backing.push(records)
        completedPushCount += 1
    }

    func fetchAll() async throws -> [SyncRecord] {
        try await backing.fetchAll()
    }
}

private actor ClearAfterFirstPushBeforeNextFetchSyncTransport:
    SyncRecordTransport
{
    private let backing = InMemorySyncTransport()
    private var shouldClearOnNextFetch = false
    private var clearedEndpoint = false

    func push(_ records: [SyncRecord]) async throws {
        try await backing.push(records)
        guard clearedEndpoint == false else { return }
        shouldClearOnNextFetch = true
    }

    func fetchAll() async throws -> [SyncRecord] {
        await clearEndpointIfNeeded()
        return try await backing.fetchAll()
    }

    func pull(
        after frontier: SyncTransportFrontier,
        limit: Int
    ) async throws -> SyncTransportChangePage {
        if shouldClearOnNextFetch {
            await clearEndpointIfNeeded()
            throw SyncRecordTransportError.repositoryFormatMismatch
        }
        return try await backing.pull(after: frontier, limit: limit)
    }

    private func clearEndpointIfNeeded() async {
        if shouldClearOnNextFetch {
            shouldClearOnNextFetch = false
            clearedEndpoint = true
            await backing.removeAll()
        }
    }

    func didClearEndpoint() -> Bool {
        clearedEndpoint
    }
}

private actor InjectRemoteRecordsOnSecondFetchSyncTransport:
    SyncRecordTransport
{
    private let backing = InMemorySyncTransport()
    private let records: [SyncRecord]
    private var fetchCount = 0
    private var injectedRemoteRecords = false

    init(records: [SyncRecord]) {
        self.records = records
    }

    func push(_ records: [SyncRecord]) async throws {
        try await backing.push(records)
    }

    func fetchAll() async throws -> [SyncRecord] {
        fetchCount += 1
        if fetchCount == 2 {
            try await backing.push(records)
            injectedRemoteRecords = true
        }
        return try await backing.fetchAll()
    }

    func didInjectRemoteRecords() -> Bool {
        injectedRemoteRecords
    }
}

private actor DownloadMutationInjectingTransport:
    SyncRecordTransport
{
    private let backing = InMemorySyncTransport()
    private let injectMutation: @Sendable () throws -> Void
    private var fetchCount = 0

    init(
        injectMutation: @escaping @Sendable () throws -> Void
    ) {
        self.injectMutation = injectMutation
    }

    func push(_ records: [SyncRecord]) async throws {
        try await backing.push(records)
    }

    func fetchAll() async throws -> [SyncRecord] {
        fetchCount += 1
        if fetchCount == 2 {
            try injectMutation()
        }
        return try await backing.fetchAll()
    }
}

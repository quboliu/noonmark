@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteLocalFirstSyncCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

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
            try syncRepository.journalEntries(state: .failed).isEmpty
        )
    }

    func testSyncReportsUniqueNewAndUpdatedTasksAcrossUploadAndDownload() async throws {
        let macURL = makeDatabaseURL("task-summary-mac")
        let phoneURL = makeDatabaseURL("task-summary-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let transport = InMemorySyncTransport()
        let macDevice = SyncDeviceID("mac-task-summary")
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
        let coordinator = SQLiteLocalFirstSyncCoordinator(
            databaseURL: databaseURL,
            transport: FailingFetchSyncTransport()
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
                message: FailingFetchSyncTransportError.unavailable.localizedDescription,
                failedAt: now
            )
        )
        XCTAssertEqual(metadata.updatedAt, now)
    }

    func testTwoSQLiteStoresConvergeConcurrentTaskNoteForksThroughSharedTransport() async throws {
        let macURL = makeDatabaseURL("note-fork-mac")
        let phoneURL = makeDatabaseURL("note-fork-phone")
        let macRepository = SQLiteEngineRepository(databaseURL: macURL)
        let phoneRepository = SQLiteEngineRepository(databaseURL: phoneURL)
        let transport = InMemorySyncTransport()
        let macDevice = SyncDeviceID("mac-note-device")
        let phoneDevice = SyncDeviceID("phone-note-device")

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

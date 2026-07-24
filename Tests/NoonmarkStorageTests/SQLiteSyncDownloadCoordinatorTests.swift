@testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import XCTest

final class SQLiteSyncDownloadCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-05")

    func testFixedPointProjectionUpdatesSyntheticOriginsFromWaitingToMergedOrConflict() throws {
        let first = evidenceRecord(suffix: "first", payload: 0x01)
        let second = evidenceRecord(suffix: "second", payload: 0x02)
        let canonical = evidenceRecord(suffix: "canonical", payload: 0x03)
        let canonicalEvidence = SyncRecordEvidence(record: canonical)
        let initial = [first, second].map {
            SyncRecordMergeOutcome(
                evidence: SyncRecordEvidence(record: $0),
                canonicalEvidenceID: canonicalEvidence.id,
                disposition: .waiting,
                dependencies: [.currentSnapshotIntegrity]
            )
        }
        let provenance = SyncRecordProvenanceGroup(
            canonicalRecord: canonical,
            contributingEvidenceIDs: initial.map(\.evidence.id),
            supersededEvidenceIDs: []
        )

        for terminal in [
            SyncRecordMergeOutcome(
                evidence: canonicalEvidence,
                canonicalEvidenceID: canonicalEvidence.id,
                disposition: .merged
            ),
            SyncRecordMergeOutcome(
                evidence: canonicalEvidence,
                canonicalEvidenceID: canonicalEvidence.id,
                disposition: .conflict,
                conflictID: UUID(
                    uuidString: "C2000000-0000-0000-0000-000000000001"
                )
            )
        ] {
            let projected = try SQLiteSyncOutcomeProjector.project(
                initialOutcomes: initial,
                latestOutcomesByEvidence: [canonicalEvidence.id: terminal],
                provenanceGroups: [provenance]
            )

            XCTAssertEqual(projected.map(\.disposition), [
                terminal.disposition,
                terminal.disposition
            ])
            XCTAssertTrue(projected.allSatisfy {
                $0.canonicalEvidenceID == canonicalEvidence.id
                    && $0.dependencies.isEmpty
            })
        }
    }

    func testFixedPointProjectionKeepsSupersededOriginIgnoredWhenWinnerWaitsOrConflicts() throws {
        let older = evidenceRecord(suffix: "older", payload: 0x11)
        let winner = evidenceRecord(suffix: "winner", payload: 0x22)
        let olderEvidence = SyncRecordEvidence(record: older)
        let winnerEvidence = SyncRecordEvidence(record: winner)
        let initial = [olderEvidence, winnerEvidence].map {
            SyncRecordMergeOutcome(
                evidence: $0,
                canonicalEvidenceID: winnerEvidence.id,
                disposition: .waiting,
                dependencies: [.currentSnapshotIntegrity]
            )
        }
        let provenance = SyncRecordProvenanceGroup(
            canonicalRecord: winner,
            contributingEvidenceIDs: [winnerEvidence.id],
            supersededEvidenceIDs: [olderEvidence.id]
        )

        for disposition in [
            SyncRecordOutcomeDisposition.waiting,
            .conflict
        ] {
            let latest = SyncRecordMergeOutcome(
                evidence: winnerEvidence,
                canonicalEvidenceID: winnerEvidence.id,
                disposition: disposition,
                dependencies: disposition == .waiting
                    ? [.currentSnapshotIntegrity]
                    : [],
                conflictID: disposition == .conflict ? UUID() : nil
            )
            let projected = try SQLiteSyncOutcomeProjector.project(
                initialOutcomes: initial,
                latestOutcomesByEvidence: [winnerEvidence.id: latest],
                provenanceGroups: [provenance]
            )
            XCTAssertEqual(
                projected.first {
                    $0.evidence.id == olderEvidence.id
                }?.disposition,
                .ignored
            )
            XCTAssertEqual(
                projected.first {
                    $0.evidence.id == winnerEvidence.id
                }?.disposition,
                disposition
            )
        }
    }

    func testDownloadAndMergeAppliesRemoteRecordsWithoutCreatingUploadJournal() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(title: "从远端下载任务", now: now)
        let traceID = try source.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        _ = try source.addSubtask(traceID: traceID, title: "合并远端子任务", difficulty: .hard, now: now)
        try source.updateTheme(
            .warmPaper,
            writerID: "iphone-b",
            now: now.addingTimeInterval(1)
        )
        let records = try SyncRecordMapper().records(from: source.snapshot(), modifiedBy: SyncDeviceID("iphone-b"))
        let transport = try InMemorySyncTransport(records: records)

        try engineRepository.save(NoonmarkEngine().snapshot())

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
        let local = NoonmarkEngine()
        let chainID = try local.createPoolTask(title: "本地历史任务", now: now)
        let traceID = try local.scheduleFromPool(chainID: chainID, date: today, today: today, now: now)
        try local.markCompleted(traceID: traceID, today: today, now: now.addingTimeInterval(1))
        try local.settleDays(upTo: LocalDate("2026-07-06"), now: now.addingTimeInterval(2))
        let localSnapshot = local.snapshot()
        try engineRepository.save(localSnapshot)

        var remoteTrace = try XCTUnwrap(localSnapshot.traces.first)
        remoteTrace.status = .pending
        remoteTrace.completedAt = nil
        let remoteRecord = try SyncRecordMapper().record(
            for: remoteTrace,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let transport = try InMemorySyncTransport(records: [remoteRecord])

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

        try engineRepository.save(NoonmarkEngine().snapshot())

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

    func testExactPreferenceReplayIsIgnoredAndAuditedWithoutChangingSQLite() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        var snapshot = NoonmarkEngine().snapshot()
        snapshot.preferences = AppPreferences(
            theme: .warmPaper,
            language: .english,
            themeLanguageUpdatedAt: now,
            themeLanguageWriterID: "remote-replay",
            settingsPoemDisplayPolicy: SettingsPoemDisplayPolicy(
                enabled: false,
                text: "本机保留"
            )
        )
        try engineRepository.save(snapshot)
        let record = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(preferences: snapshot.preferences),
            modifiedBy: SyncDeviceID("remote-replay")
        )

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: try InMemorySyncTransport(records: [record])
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(1))

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 1,
                appliedCount: 0,
                waitingCount: 0,
                conflictCount: 0
            )
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), snapshot)
        XCTAssertEqual(try syncRepository.auditLog().map(\.action), ["ignored"])
    }

    func testEachExactSameIDPreferenceVariantReceivesItsOwnAuditOutcome() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let mapper = SyncRecordMapper()
        let older = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .chinese,
                updatedAt: now,
                writerDeviceID: SyncDeviceID("remote-older")
            ),
            modifiedBy: SyncDeviceID("remote-older")
        )
        let newer = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now.addingTimeInterval(1),
                writerDeviceID: SyncDeviceID("remote-newer")
            ),
            modifiedBy: SyncDeviceID("remote-newer")
        )
        XCTAssertEqual(older.id, newer.id)
        XCTAssertFalse(older.exactlyMatches(newer))

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: OrderedSyncTransport(records: [older, newer])
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(2))

        XCTAssertEqual(result.appliedCount, 1)
        let audit = try syncRepository.auditLog()
        XCTAssertEqual(
            audit.count,
            2,
            "same logical identity must not collapse distinct exact evidence"
        )
        XCTAssertEqual(Set(audit.map(\.action)), ["ignored", "merged"])
        XCTAssertEqual(Set(audit.map(\.entityID)), [older.entityID])
        XCTAssertEqual(
            Set(audit.compactMap(\.sourceEvidenceID)),
            Set([
                SyncRecordEvidenceID(record: older),
                SyncRecordEvidenceID(record: newer)
            ])
        )
        XCTAssertEqual(
            Set(audit.compactMap(\.canonicalEvidenceID)),
            [SyncRecordEvidenceID(record: newer)]
        )
    }

    func testDownloadCommitRejectsSnapshotChangedAfterObservedMerge() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let baseline = NoonmarkEngine().snapshot()
        try engineRepository.save(baseline)

        let local = try NoonmarkEngine(snapshot: baseline)
        _ = try local.createPoolTask(
            title: "必须保留的并发本地写入",
            now: now.addingTimeInterval(1)
        )
        let localSnapshot = local.snapshot()
        let remote = try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now.addingTimeInterval(2),
                writerDeviceID: SyncDeviceID("remote-cas")
            ),
            modifiedBy: SyncDeviceID("remote-cas")
        )
        var injectedConcurrentWrite = false
        var concurrentWriteError: Error?
        let coordinator = SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: OrderedSyncTransport(records: [remote]),
            auditEntryIDGenerator: {
                if injectedConcurrentWrite == false {
                    do {
                        try engineRepository.save(localSnapshot)
                    } catch {
                        concurrentWriteError = error
                    }
                    injectedConcurrentWrite = true
                }
                return UUID(
                    uuidString: "C1000000-0000-0000-0000-000000000001"
                )!
            }
        )

        do {
            _ = try await coordinator.downloadAndMerge(
                detectedAt: now.addingTimeInterval(3)
            )
            XCTFail("a stale observed engine snapshot must fail its commit CAS")
        } catch {
            // The exact repository error is deliberately not coupled to the CAS test.
        }
        XCTAssertNil(concurrentWriteError)

        XCTAssertTrue(injectedConcurrentWrite)
        XCTAssertEqual(
            try engineRepository.load().snapshot(),
            localSnapshot,
            "the failed stale merge must not overwrite the concurrent local state"
        )
    }

    func testFetchedCurrentRecordCanonicalizesWithSameIdentityPendingVersion() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let mapper = SyncRecordMapper()
        let pendingRecord = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .chinese,
                updatedAt: now,
                writerDeviceID: SyncDeviceID("mac-pending-preference")
            ),
            modifiedBy: SyncDeviceID("mac-pending-preference")
        )
        let fetchedRecord = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now.addingTimeInterval(1),
                writerDeviceID: SyncDeviceID("mac-fetched-preference")
            ),
            modifiedBy: SyncDeviceID("mac-fetched-preference")
        )
        XCTAssertEqual(pendingRecord.id, fetchedRecord.id)
        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: pendingRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ],
            terminal: [],
            attemptedAt: now.addingTimeInterval(2)
        )

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: try InMemorySyncTransport(records: [fetchedRecord])
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(3))

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 1,
                appliedCount: 1,
                waitingCount: 0,
                conflictCount: 0
            )
        )
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        let restoredPreferences = try engineRepository.load().snapshot().preferences
        XCTAssertEqual(restoredPreferences.theme, .warmPaper)
        XCTAssertEqual(restoredPreferences.language, .english)
        XCTAssertEqual(
            restoredPreferences.themeLanguageWriterID,
            "mac-fetched-preference"
        )
    }

    func testPendingAndFetchedCompletionUndoCanonicalizeWithUnlockedSnapshotContext() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let completed = NoonmarkEngine()
        let chainID = try completed.createPoolTask(
            title: "跨重启完成撤回",
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
            now: now.addingTimeInterval(2)
        )
        let completedSnapshot = completed.snapshot()
        try engineRepository.save(completedSnapshot)

        let undone = try NoonmarkEngine(snapshot: completedSnapshot)
        try undone.undoCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        let mapper = SyncRecordMapper()
        let completedRecord = try mapper.record(
            for: try XCTUnwrap(completed.traces[traceID]),
            modifiedBy: SyncDeviceID("mac-completed-pending")
        )
        let undoRecord = try mapper.record(
            for: try XCTUnwrap(undone.traces[traceID]),
            modifiedBy: SyncDeviceID("iphone-fetched-undo")
        )
        XCTAssertEqual(completedRecord.id, undoRecord.id)
        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: completedRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ],
            terminal: [],
            attemptedAt: now.addingTimeInterval(4)
        )

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: try InMemorySyncTransport(records: [undoRecord])
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(5))
        let restored = try engineRepository.load().snapshot()
        let restoredTrace = try XCTUnwrap(
            restored.traces.first { $0.id == traceID }
        )

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 1,
                appliedCount: 1,
                waitingCount: 0,
                conflictCount: 0
            )
        )
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(restoredTrace.status, .pending)
        XCTAssertNil(restoredTrace.completedAt)
        XCTAssertNoThrow(try restored.validateIntegrity())
    }

    func testValidCurrentDuplicateCanonicalizesBesideUnrelatedMalformedUniqueRecord() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let mapper = SyncRecordMapper()
        let pendingPreference = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .coolGray,
                language: .chinese,
                updatedAt: now,
                writerDeviceID: SyncDeviceID("mac-pending-mixed-batch")
            ),
            modifiedBy: SyncDeviceID("mac-pending-mixed-batch")
        )
        let fetchedPreference = try mapper.record(
            for: AppPreferencesEnvelope(
                theme: .warmPaper,
                language: .english,
                updatedAt: now.addingTimeInterval(1),
                writerDeviceID: SyncDeviceID("mac-fetched-mixed-batch")
            ),
            modifiedBy: SyncDeviceID("mac-fetched-mixed-batch")
        )
        let malformedUnique = SyncRecord(
            id: SyncRecordID("day:malformed-unique"),
            entityType: .day,
            entityID: "malformed-unique",
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("mac-malformed-unique"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )
        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: pendingPreference,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ],
            terminal: [],
            attemptedAt: now.addingTimeInterval(2)
        )

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: HostileFixtureSyncTransport(
                uncheckedRecords: [fetchedPreference, malformedUnique]
            )
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(3))

        XCTAssertEqual(
            result,
            SQLiteSyncDownloadResult(
                fetchedCount: 2,
                appliedCount: 1,
                waitingCount: 0,
                conflictCount: 1
            )
        )
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(
            try syncRepository.unresolvedConflicts().map(\.remoteRecord),
            [malformedUnique]
        )
        let restoredPreferences = try engineRepository.load().snapshot().preferences
        XCTAssertEqual(restoredPreferences.theme, .warmPaper)
        XCTAssertEqual(restoredPreferences.language, .english)
        XCTAssertEqual(
            restoredPreferences.themeLanguageWriterID,
            "mac-fetched-mixed-batch"
        )
    }

    func testPartialCurrentBatchSurvivesRestartAndAppliesAfterDefinitionArrives() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "跨批次补齐定义",
            now: now
        )
        let mapper = SyncRecordMapper()
        let initialChainRecord = try mapper.record(
            for: try XCTUnwrap(source.snapshot().chains.first),
            modifiedBy: SyncDeviceID("iphone-partial-a")
        )
        _ = try source.appendPoolNote(
            chainID: chainID,
            body: "第二批观察到的 newer current fact",
            now: now.addingTimeInterval(1)
        )
        let finalSnapshot = source.snapshot()
        let newerChainRecord = try mapper.record(
            for: try XCTUnwrap(finalSnapshot.chains.first),
            modifiedBy: SyncDeviceID("iphone-partial-b")
        )
        let definitionRecord = try mapper.record(
            for: try XCTUnwrap(finalSnapshot.definitions.first),
            modifiedBy: SyncDeviceID("iphone-partial-b")
        )
        let transport = try InMemorySyncTransport(records: [initialChainRecord])

        let first = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))
        let firstPending = try XCTUnwrap(syncRepository.pendingDownloads().first)
        XCTAssertEqual(first.waitingCount, 1)
        XCTAssertEqual(first.appliedCount, 0)
        XCTAssertEqual(firstPending.record, initialChainRecord)
        XCTAssertEqual(firstPending.dependencies, [.currentSnapshotIntegrity])

        await transport.removeAll()
        try await transport.push([newerChainRecord])
        let second = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(20))
        let secondPending = try XCTUnwrap(syncRepository.pendingDownloads().first)
        XCTAssertEqual(second.waitingCount, 1)
        XCTAssertEqual(second.appliedCount, 0)
        XCTAssertEqual(secondPending.record, newerChainRecord)
        XCTAssertEqual(secondPending.generationID, firstPending.generationID)
        XCTAssertEqual(
            secondPending.firstSeenAt.timeIntervalSinceReferenceDate.bitPattern,
            firstPending.firstSeenAt.timeIntervalSinceReferenceDate.bitPattern
        )
        XCTAssertEqual(secondPending.attemptCount, 2)

        try await transport.push([definitionRecord])
        let third = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(30))
        let restored = try engineRepository.load().snapshot()

        XCTAssertEqual(third.fetchedCount, 2)
        XCTAssertEqual(third.appliedCount, 2)
        XCTAssertEqual(third.waitingCount, 0)
        XCTAssertEqual(third.conflictCount, 0)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(restored.chains, finalSnapshot.chains)
        XCTAssertEqual(restored.definitions, finalSnapshot.definitions)
        XCTAssertNoThrow(try restored.validateIntegrity())
    }

    func testMalformedFetchedSiblingConflictsDurablePendingIdentityAtomically() async throws {
        let databaseURL = makeDatabaseURL()
        let sourceDatabaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let sourceEngineRepository = SQLiteEngineRepository(
            databaseURL: sourceDatabaseURL
        )
        let sourceSyncRepository = SQLiteSyncRepository(
            databaseURL: sourceDatabaseURL
        )
        let baseline = NoonmarkEngine().snapshot()
        try engineRepository.save(baseline)

        let deviceID = SyncDeviceID("mac-durable-reactivation")
        let createdAt = now.addingTimeInterval(1)
        let abandonedAt = now.addingTimeInterval(2)
        let reactivatedAt = now.addingTimeInterval(3)
        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "碰撞不能吞掉持久 waiting",
            now: createdAt
        )
        let traceID = try source.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: createdAt
        )
        try source.abandonChain(from: traceID, now: abandonedAt)
        try sourceEngineRepository.save(
            source.snapshot(),
            recordingChangesFor: deviceID,
            changedAt: abandonedAt
        )
        _ = try source.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: reactivatedAt
        )
        let reactivatedSnapshot = source.snapshot()
        try sourceEngineRepository.save(
            reactivatedSnapshot,
            recordingChangesFor: deviceID,
            changedAt: reactivatedAt
        )
        let witnessEntry = try XCTUnwrap(
            sourceSyncRepository.journalEntries(state: .pendingUpload).first {
                $0.entityType == .taskChain
                    && $0.entityID == chainID.description
                    && $0.recordPayload != nil
            }
        )
        let durableRecord = try SyncRecordMaterializer().record(
            for: witnessEntry,
            in: reactivatedSnapshot
        )
        XCTAssertFalse(durableRecord.reactivationWitnesses.isEmpty)

        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: durableRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ],
            terminal: [],
            attemptedAt: now.addingTimeInterval(4)
        )
        let observedPending = try XCTUnwrap(
            syncRepository.pendingDownloads().first
        )
        var malformedFetchedRecord = durableRecord
        malformedFetchedRecord.payload = Data([0x00])

        let retryAt = now.addingTimeInterval(5)
        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: HostileFixtureSyncTransport(
                uncheckedRecords: [malformedFetchedRecord]
            )
        ).downloadAndMerge(detectedAt: retryAt)

        XCTAssertEqual(result.fetchedCount, 1)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.conflictCount, 2)
        XCTAssertEqual(result.waitingCount, 0)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertEqual(try engineRepository.load().snapshot(), baseline)
        let evidenceIDs = Set([
            SyncRecordEvidenceID(record: observedPending.record),
            SyncRecordEvidenceID(record: malformedFetchedRecord)
        ])
        XCTAssertEqual(
            Set(try syncRepository.unresolvedConflicts().map {
                SyncRecordEvidenceID(record: $0.remoteRecord)
            }),
            evidenceIDs
        )
        let audit = try syncRepository.auditLog()
        XCTAssertEqual(
            audit.map(\.action),
            ["conflict", "conflict"]
        )
        XCTAssertEqual(Set(audit.compactMap(\.sourceEvidenceID)), evidenceIDs)
        XCTAssertEqual(
            Set(audit.compactMap(\.canonicalEvidenceID)),
            evidenceIDs
        )
    }

    func testExactPendingAndFetchedDuplicateProducesOneAuditEntryPerCycle() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let fixture = try makeClassificationEnvelope()
        let record = try SyncRecordMapper().record(
            for: fixture.envelope,
            modifiedBy: SyncDeviceID("iphone-audit-duplicate")
        )
        let transport = try InMemorySyncTransport(records: [record])
        let coordinator = SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        )

        let first = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(1)
        )
        let second = try await coordinator.downloadAndMerge(
            detectedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(first.waitingCount, 1)
        XCTAssertEqual(second.fetchedCount, 1)
        XCTAssertEqual(second.waitingCount, 1)
        XCTAssertEqual(
            try syncRepository.pendingDownloads().first?.attemptCount,
            2
        )
        let audit = try syncRepository.auditLog()
        XCTAssertEqual(audit.count, 2)
        XCTAssertEqual(audit.map(\.action), ["waiting", "waiting"])
    }

    func testMissingClassificationDependencyPersistsAcrossAnEmptyFetchAndAppliesWhenParentsArrive() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())

        let fixture = try makeClassificationEnvelope()
        let mapper = SyncRecordMapper()
        let classificationRecord = try mapper.record(
            for: fixture.envelope,
            modifiedBy: SyncDeviceID("iphone-b")
        )
        let transport = try InMemorySyncTransport(
            records: [classificationRecord]
        )
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
        let source = NoonmarkEngine()

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
        let transport = try InMemorySyncTransport(records: [archiveRecord])

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
        try engineRepository.save(NoonmarkEngine().snapshot())

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

    func testStaleWaitingResultDoesNotOverwriteNewerPendingReplacement() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let baselineSnapshot = NoonmarkEngine().snapshot()
        try engineRepository.save(baselineSnapshot)

        let baselineAudit = SyncAuditLogEntry(
            id: UUID(uuidString: "45000000-0000-0000-0000-000000000011")!,
            direction: .download,
            entityType: .taskChain,
            entityID: "baseline-chain",
            action: "baseline",
            createdAt: now,
            message: "must survive stale waiting rollback"
        )
        let baselineMetadata = SyncMetadataEntry(
            key: "generic.download.lastFetch",
            value: Data([0x51, 0x00, 0x52]),
            updatedAt: now
        )
        try syncRepository.appendAuditLog(baselineAudit)
        try syncRepository.saveMetadata(baselineMetadata)

        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "旧 waiting 不能覆盖新 waiting",
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let oldRecord = try mapper.record(
            for: try XCTUnwrap(source.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-old-waiting")
        )
        _ = try source.appendPoolNote(
            chainID: chainID,
            body: "fetch 阶段到达的较新事实",
            now: now.addingTimeInterval(2)
        )
        let newRecord = try mapper.record(
            for: try XCTUnwrap(source.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-new-waiting")
        )
        XCTAssertEqual(oldRecord.id, newRecord.id)
        XCTAssertNotEqual(oldRecord, newRecord)

        let oldWaiting = SyncWaitingRecord(
            record: oldRecord,
            dependencies: [.currentSnapshotIntegrity]
        )
        let newWaiting = SyncWaitingRecord(
            record: newRecord,
            dependencies: [.currentSnapshotIntegrity]
        )
        try syncRepository.reconcilePendingDownloads(
            waiting: [oldWaiting],
            terminal: [],
            attemptedAt: now.addingTimeInterval(3)
        )
        let observedOldPending = try XCTUnwrap(
            syncRepository.pendingDownloads().first
        )
        let transport = PendingInjectingTransport(
            databaseURL: databaseURL,
            waiting: newWaiting,
            attemptedAt: now.addingTimeInterval(4),
            fetched: []
        )

        do {
            _ = try await SQLiteSyncDownloadCoordinator(
                databaseURL: databaseURL,
                transport: transport
            ).downloadAndMerge(detectedAt: now.addingTimeInterval(5))
            XCTFail("expected the stale waiting replacement to fail closed")
        } catch {
            guard case SQLiteRepositoryError.invalidStoredValue = error else {
                return XCTFail("expected invalid stored value, got \(error)")
            }
        }

        let durablePending = try XCTUnwrap(
            syncRepository.pendingDownloads().first
        )
        XCTAssertEqual(durablePending.record, newRecord)
        XCTAssertEqual(durablePending.generationID, observedOldPending.generationID)
        XCTAssertEqual(durablePending.attemptCount, 2)
        XCTAssertEqual(try engineRepository.load().snapshot(), baselineSnapshot)
        XCTAssertEqual(try syncRepository.auditLog(), [baselineAudit])
        XCTAssertEqual(
            try syncRepository.metadata(for: "generic.download.lastFetch"),
            baselineMetadata
        )
    }

    func testStaleTerminalResultPreservesNewerPendingReplacementAndCommitsEvidence() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let baseline = NoonmarkEngine().snapshot()
        try engineRepository.save(baseline)

        let source = NoonmarkEngine()
        let chainID = try source.createPoolTask(
            title: "旧 retained 不能跨过新 pending",
            now: now.addingTimeInterval(1)
        )
        let mapper = SyncRecordMapper()
        let oldRecord = try mapper.record(
            for: try XCTUnwrap(source.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-old-retained")
        )
        _ = try source.appendPoolNote(
            chainID: chainID,
            body: "fetch 阶段到达的新事实",
            now: now.addingTimeInterval(2)
        )
        let newRecord = try mapper.record(
            for: try XCTUnwrap(source.chains[chainID]),
            modifiedBy: SyncDeviceID("iphone-new-retained")
        )
        XCTAssertEqual(oldRecord.id, newRecord.id)
        XCTAssertFalse(oldRecord.exactlyMatches(newRecord))

        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: oldRecord,
                    dependencies: [.currentSnapshotIntegrity]
                )
            ],
            terminal: [],
            attemptedAt: now.addingTimeInterval(3)
        )
        let observedOldPending = try XCTUnwrap(
            syncRepository.pendingDownloads().first
        )
        var malformedFetchedRecord = oldRecord
        malformedFetchedRecord.payload = Data([0x00])
        let transport = PendingInjectingTransport(
            databaseURL: databaseURL,
            waiting: SyncWaitingRecord(
                record: newRecord,
                dependencies: [.currentSnapshotIntegrity]
            ),
            attemptedAt: now.addingTimeInterval(4),
            fetched: [malformedFetchedRecord]
        )

        let detectedAt = now.addingTimeInterval(5)
        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: detectedAt)

        let durablePending = try XCTUnwrap(
            syncRepository.pendingDownloads().first
        )
        XCTAssertEqual(result.fetchedCount, 1)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.waitingCount, 1)
        XCTAssertEqual(result.conflictCount, 2)
        XCTAssertEqual(durablePending.record, newRecord)
        XCTAssertEqual(durablePending.generationID, observedOldPending.generationID)
        XCTAssertEqual(durablePending.attemptCount, 2)
        XCTAssertEqual(try engineRepository.load().snapshot(), baseline)
        let evidenceIDs = Set([
            SyncRecordEvidenceID(record: oldRecord),
            SyncRecordEvidenceID(record: malformedFetchedRecord)
        ])
        XCTAssertEqual(
            Set(try syncRepository.unresolvedConflicts().map {
                SyncRecordEvidenceID(record: $0.remoteRecord)
            }),
            evidenceIDs
        )
        let audit = try syncRepository.auditLog()
        XCTAssertEqual(audit.map(\.action), ["conflict", "conflict"])
        XCTAssertEqual(Set(audit.compactMap(\.sourceEvidenceID)), evidenceIDs)
        XCTAssertEqual(
            Set(audit.compactMap(\.canonicalEvidenceID)),
            evidenceIDs
        )
        XCTAssertEqual(
            try syncRepository.metadata(for: "generic.download.lastFetch")?
                .updatedAt,
            detectedAt
        )
    }

    func testForgedImmutableHeaderClocksBecomeTerminalConflictsWithoutMutatingSnapshot() async throws {
        let databaseURL = makeDatabaseURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let before = NoonmarkEngine().snapshot()
        try engineRepository.save(before)

        let mapper = SyncRecordMapper()
        let classificationFixture = try makeClassificationEnvelope()
        var forgedClassification = try mapper.record(
            for: classificationFixture.envelope,
            modifiedBy: SyncDeviceID("iphone-classification")
        )
        forgedClassification.modifiedAt = Date(
            timeIntervalSinceReferenceDate: classificationFixture.envelope
                .changeRecord.committedAt.timeIntervalSinceReferenceDate.nextUp
        )

        let event = TraceClassificationSnapshot(
            id: UUID(uuidString: "45000000-0000-0000-0000-000000000001")!,
            traceID: DayTraceID(
                UUID(uuidString: "45000000-0000-0000-0000-000000000002")!
            ),
            status: .deferred,
            category: nil,
            labels: [],
            capturedAt: now.addingTimeInterval(1),
            revision: 1
        )
        let traceEnvelope = try TraceClassificationEventEnvelope(
            event: event,
            predecessorEventID: nil
        )
        var forgedTraceEvent = try mapper.record(
            for: traceEnvelope,
            modifiedBy: SyncDeviceID("iphone-trace")
        )
        forgedTraceEvent.modifiedAt = Date(
            timeIntervalSinceReferenceDate: event.capturedAt
                .timeIntervalSinceReferenceDate.nextUp
        )
        let transport = HostileFixtureSyncTransport(
            uncheckedRecords: [forgedClassification, forgedTraceEvent]
        )

        let result = try await SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: transport
        ).downloadAndMerge(detectedAt: now.addingTimeInterval(10))

        XCTAssertEqual(try engineRepository.load().snapshot(), before)
        XCTAssertEqual(result.fetchedCount, 2)
        XCTAssertEqual(result.appliedCount, 0)
        XCTAssertEqual(result.waitingCount, 0)
        XCTAssertEqual(result.conflictCount, 2)
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        let forgedRecords = [forgedClassification, forgedTraceEvent]
        let forgedEvidenceIDs = Set(forgedRecords.map {
            SyncRecordEvidenceID(record: $0)
        })
        let conflicts = try syncRepository.unresolvedConflicts()
        XCTAssertEqual(
            conflicts.map(\.type),
            [.invalidRecordPayload, .invalidRecordPayload]
        )
        XCTAssertEqual(
            Set(conflicts.map { SyncRecordEvidenceID(record: $0.remoteRecord) }),
            forgedEvidenceIDs
        )

        let terminalRejections = try syncRepository.terminalRejectionEvidence()
        XCTAssertEqual(
            Set(terminalRejections.map(\.identity)),
            [
                .classificationCommit(classificationFixture.envelope.changeRecord.id),
                .traceClassificationEvent(event.id)
            ]
        )
        XCTAssertEqual(
            Set(terminalRejections.map {
                SyncRecordEvidenceID(record: $0.conflict.remoteRecord)
            }),
            forgedEvidenceIDs
        )

        let audit = try syncRepository.auditLog()
        XCTAssertEqual(audit.map(\.action), ["conflict", "conflict"])
        XCTAssertEqual(Set(audit.compactMap(\.sourceEvidenceID)), forgedEvidenceIDs)
        XCTAssertEqual(
            Set(audit.compactMap(\.canonicalEvidenceID)),
            forgedEvidenceIDs
        )
        XCTAssertNotNil(
            try syncRepository.metadata(for: "generic.download.lastFetch")
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
        let source = NoonmarkEngine()
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
        _ snapshot: NoonmarkSnapshot,
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
        to engine: NoonmarkEngine,
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
        let source = NoonmarkEngine()
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
            .appendingPathComponent("noonmark-sync-download-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func evidenceRecord(
        suffix: String,
        payload: UInt8
    ) -> SyncRecord {
        SyncRecord(
            id: SyncRecordID("test-evidence:\(suffix)"),
            entityType: .appPreferences,
            entityID: suffix,
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("test-evidence"),
            payload: Data([payload])
        )
    }
}

private enum TestClassificationIdentity: Equatable {
    case category(TaskCategoryID)
    case label(TaskLabelID)
}

private struct DeleteRecreateFixture {
    let baseSnapshot: NoonmarkSnapshot
    let finalSnapshot: NoonmarkSnapshot
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

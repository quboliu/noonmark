@testable import NoonmarkStorage
@_spi(ClassificationUserDecision) import NoonmarkCore
@testable import NoonmarkSync
import SQLite3
import XCTest

final class LocalFirstReplicationTests: XCTestCase {
    private let generationID = UUID(
        uuidString: "91000000-0000-0000-0000-000000000001"
    )!
    private let producerA = UUID(
        uuidString: "92000000-0000-0000-0000-000000000001"
    )!
    private let producerB = UUID(
        uuidString: "92000000-0000-0000-0000-000000000002"
    )!
    private let producerC = UUID(
        uuidString: "92000000-0000-0000-0000-000000000003"
    )!
    private let now = Date(timeIntervalSinceReferenceDate: 810_100_000)
    private let publicationWatermarkStore =
        InMemoryReplicationPublicationWatermarkStore()

    func testCleanCutBaselineIgnoresLegacyJournalAndCapturesOnlyLaterMutations()
        async throws
    {
        let databaseURL = makeDatabaseURL("clean-cut")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let legacyEngine = NoonmarkEngine()
        _ = try legacyEngine.createPoolTask(
            title: "legacy local fact",
            now: now
        )
        try engineRepository.save(
            legacyEngine.snapshot(),
            recordingChangesFor: SyncDeviceID("legacy-v1-writer"),
            changedAt: now
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let legacyJournal = try syncRepository.journalEntries()
        XCTAssertFalse(legacyJournal.isEmpty)
        let legacyPendingRecord = try XCTUnwrap(
            SyncRecordMapper().records(
                from: legacyEngine.snapshot(),
                modifiedBy: SyncDeviceID("legacy-v1-remote")
            ).first { $0.entityType == .taskDefinition }
        )
        try syncRepository.reconcilePendingDownloads(
            waiting: [
                SyncWaitingRecord(
                    record: legacyPendingRecord,
                    dependencies: [.taskChain(TaskChainID())]
                ),
            ],
            terminal: [],
            attemptedAt: now
        )
        let terminalEntityID = UUID(
            uuidString: "91000000-0000-0000-0000-000000000099"
        )!.uuidString
        let terminalRecord = SyncRecord(
            id: SyncRecordID(
                "classification-baseline:\(terminalEntityID)"
            ),
            entityType: .classificationBaseline,
            entityID: terminalEntityID,
            modifiedAt: now,
            modifiedByDeviceID: SyncDeviceID("legacy-v1-remote"),
            payload: Data("legacy-terminal".utf8)
        )
        try syncRepository.saveConflict(
            SyncConflict(
                type: .classificationBaselineRejected,
                entityType: terminalRecord.entityType,
                entityID: terminalRecord.entityID,
                remoteRecord: terminalRecord,
                detectedAt: now,
                message: "legacy V1 terminal evidence"
            )
        )
        try syncRepository.appendAuditLog(
            SyncAuditLogEntry(
                direction: .download,
                entityType: .taskDefinition,
                entityID: legacyPendingRecord.entityID,
                action: "legacy-v1-download",
                createdAt: now
            )
        )
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: "legacy.v1.cursor",
                value: Data("legacy-v1-cursor".utf8),
                updatedAt: now
            )
        )
        XCTAssertEqual(try syncRepository.pendingDownloads().count, 1)
        XCTAssertEqual(try syncRepository.terminalRejectionEvidence().count, 1)
        XCTAssertEqual(try syncRepository.unresolvedConflicts().count, 1)
        XCTAssertEqual(try syncRepository.auditLog().count, 1)
        XCTAssertNotNil(try syncRepository.metadata(for: "legacy.v1.cursor"))

        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now.addingTimeInterval(1)
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)

        XCTAssertEqual(
            try ledger.cleanCutAuthority(),
            SQLiteReplicationCleanCutAuthority(
                generationID: generationID,
                producerID: producerA,
                baselineSequence: 1
            )
        )
        XCTAssertEqual(
            try ledger.outboxSnapshot(generationID: generationID),
            SQLiteReplicationOutboxSnapshot(
                pendingCount: 0,
                confirmedCount: 0
            )
        )
        XCTAssertEqual(
            try syncRepository.journalEntries(),
            legacyJournal
        )
        XCTAssertTrue(try syncRepository.pendingDownloads().isEmpty)
        XCTAssertTrue(try syncRepository.terminalRejectionEvidence().isEmpty)
        XCTAssertTrue(try syncRepository.unresolvedConflicts().isEmpty)
        XCTAssertTrue(try syncRepository.auditLog().isEmpty)
        XCTAssertNil(try syncRepository.metadata(for: "legacy.v1.cursor"))

        let baselineState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        XCTAssertEqual(baselineState.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(baselineState.convergence, .converged)

        let changed = try engineRepository.load()
        _ = try changed.createPoolTask(
            title: "v2 post-baseline fact",
            now: now.addingTimeInterval(3)
        )
        try engineRepository.save(
            changed.snapshot(),
            recordingChangesFor: SyncDeviceID("v2-writer"),
            changedAt: now.addingTimeInterval(3)
        )
        let captured = try ledger.outboxSnapshot(
            generationID: generationID
        )
        XCTAssertGreaterThan(captured.pendingCount, 0)
        XCTAssertEqual(captured.confirmedCount, 0)
        XCTAssertTrue(
            try syncRepository.journalEntries().prefix(legacyJournal.count)
                .elementsEqual(legacyJournal)
        )

        let deltaState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(4))
        )
        XCTAssertEqual(deltaState.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(deltaState.convergence, .converged)
        XCTAssertEqual(
            try ledger.outboxSnapshot(generationID: generationID)
                .pendingCount,
            0
        )
        XCTAssertGreaterThan(
            try ledger.outboxSnapshot(generationID: generationID)
                .confirmedCount,
            0
        )
    }

    func testCleanCutBaselineCarriesExistingClassificationStateToASecondStore()
        async throws
    {
        let sourceURL = makeDatabaseURL("classified-clean-cut-source")
        let targetURL = makeDatabaseURL("classified-clean-cut-target")
        let repositoryURL = makeRepositoryURL()
        let sourceRepository = SQLiteEngineRepository(databaseURL: sourceURL)
        let sourceEngine = NoonmarkEngine()
        let chainID = try sourceEngine.createPoolTask(
            title: "classified clean-cut fact",
            now: now
        )
        let plan = try sourceEngine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "Engineering", colorHex: "#2A6FDB"),
                    labels: [.new(name: "Sync", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(
                uuidString: "91000000-0000-0000-0000-000000000010"
            )!,
            now: now.addingTimeInterval(1)
        )
        _ = try sourceEngine.commitClassification(
            plan,
            confirmation: .confirmedByUser(
                confirming: plan,
                decisionID: UUID(
                    uuidString: "91000000-0000-0000-0000-000000000011"
                )!
            ),
            now: now.addingTimeInterval(1)
        )
        try sourceRepository.save(sourceEngine.snapshot())
        try SQLiteEngineRepository(databaseURL: targetURL)
            .save(NoonmarkEngine().snapshot())

        let sourceRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: sourceURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now.addingTimeInterval(2)
        )
        let sourceState = try await sourceRuntime.send(
            .reconcile(now: now.addingTimeInterval(3))
        )
        XCTAssertEqual(sourceState.convergence, .converged)

        let targetRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: targetURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now.addingTimeInterval(4)
        )
        let targetState = try await targetRuntime.send(
            .reconcile(now: now.addingTimeInterval(5))
        )
        XCTAssertEqual(targetState.convergence, .converged)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: targetURL)
                .load().snapshot().classifications,
            sourceEngine.snapshot().classifications
        )
    }

    func testCleanCutNeverPublishesPostBaselineDeltaBeforeBaselineConfirmation()
        async throws
    {
        let databaseURL = makeDatabaseURL("clean-cut-order")
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        try engineRepository.save(NoonmarkEngine().snapshot())
        let endpoint = RecordingConfirmationEndpoint()
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now
        )

        let changed = try engineRepository.load()
        _ = try changed.createPoolTask(
            title: "captured before first reconcile",
            now: now.addingTimeInterval(1)
        )
        try engineRepository.save(
            changed.snapshot(),
            recordingChangesFor: SyncDeviceID("clean-cut-order"),
            changedAt: now.addingTimeInterval(1)
        )

        let first = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        let firstPublishedSequences = await endpoint.publishedSequences()
        XCTAssertEqual(firstPublishedSequences, [1])
        XCTAssertEqual(first.convergence, .waitingForEndpoint)
        XCTAssertGreaterThan(
            try SQLiteReplicationLedger(databaseURL: databaseURL)
                .outboxSnapshot(generationID: generationID).pendingCount,
            0
        )

        let second = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(3))
        )
        let allPublishedSequences = await endpoint.publishedSequences()
        XCTAssertEqual(allPublishedSequences, [1, 2])
        XCTAssertEqual(second.convergence, .converged)
    }

    func testCleanCutRecoversCrashBetweenSQLiteAuthorityAndWatermarkCAS()
        async throws
    {
        let databaseURL = makeDatabaseURL("clean-cut-watermark-crash")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "baseline survives watermark crash",
            now: now
        )
        try engineRepository.save(engine.snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let watermarkStore = RollbackWatermarkStore()
        watermarkStore.failNextComparisonForCrashTest()

        XCTAssertThrowsError(
            try LocalFirstReplication.openCleanCut(
                databaseURL: databaseURL,
                endpoint: endpoint,
                generationID: generationID,
                producerID: producerA,
                publicationWatermarkStore: watermarkStore,
                installedAt: now
            )
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        XCTAssertEqual(try ledger.cleanCutAuthority()?.producerID, producerA)

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore,
            installedAt: now.addingTimeInterval(1)
        )
        let baseline = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        XCTAssertEqual(baseline.convergence, .converged)
        XCTAssertTrue(try ledger.cleanCutBaselineIsConfirmed())
        XCTAssertNotEqual(
            try ledger.cleanCutAuthority()?.producerID,
            producerA
        )

        let changed = try engineRepository.load()
        _ = try changed.createPoolTask(
            title: "post-crash delta",
            now: now.addingTimeInterval(3)
        )
        try engineRepository.save(
            changed.snapshot(),
            recordingChangesFor: SyncDeviceID("post-crash-writer"),
            changedAt: now.addingTimeInterval(3)
        )
        XCTAssertGreaterThan(
            try ledger.outboxSnapshot(generationID: generationID)
                .pendingCount,
            0
        )

        let delta = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(4))
        )
        XCTAssertEqual(delta.convergence, .converged)
        XCTAssertEqual(
            try ledger.outboxSnapshot(generationID: generationID)
                .pendingCount,
            0
        )
    }

    func testCleanCutReseedsAUserCreatedEmptyRepositoryWithFullSnapshot()
        async throws
    {
        let databaseURL = makeDatabaseURL("clean-cut-empty-repository-reseed")
        let engineRepository = SQLiteEngineRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "must be present in replacement repository",
            now: now
        )
        try engineRepository.save(engine.snapshot())
        let repositoryGenerationID = generationID
        let firstEndpoint = try ContentAddressedFileReplicationEndpoint
            .openCleanRepository(
                rootURL: makeRepositoryURL(),
                generationID: { repositoryGenerationID }
            )
        let watermarkStore = InMemoryReplicationPublicationWatermarkStore()
        let firstRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: firstEndpoint,
            generationID: firstEndpoint.generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore,
            repositoryWasCreated: firstEndpoint.repositoryWasCreated,
            installedAt: now
        )
        let first = try await firstRuntime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(first.convergence, .converged)
        _ = try await firstRuntime.shutdown()

        let replacementEndpoint = try ContentAddressedFileReplicationEndpoint
            .openCleanRepository(
                rootURL: makeRepositoryURL(),
                generationID: { repositoryGenerationID }
            )
        XCTAssertTrue(replacementEndpoint.repositoryWasCreated)
        let replacementRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: replacementEndpoint,
            generationID: replacementEndpoint.generationID,
            producerID: producerB,
            publicationWatermarkStore: watermarkStore,
            repositoryWasCreated: replacementEndpoint.repositoryWasCreated,
            installedAt: now.addingTimeInterval(2)
        )
        let replacement = try await replacementRuntime.send(
            .reconcile(now: now.addingTimeInterval(3))
        )
        let page = try await replacementEndpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 10,
                maximumBytes: 1_000_000
            )
        )

        XCTAssertEqual(replacement.convergence, .converged)
        XCTAssertEqual(page.publications.count, 1)
        XCTAssertTrue(
            page.publications[0].records.contains {
                $0.entityType == .taskDefinition
            }
        )
    }

    func testRuntimeWithoutCleanCutAuthorityFailsClosedInsteadOfReadingV1Journal()
        throws
    {
        let databaseURL = makeDatabaseURL("missing-clean-cut-authority")
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "legacy journal must not become V2 transport input",
            now: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("legacy-journal-writer"),
            changedAt: now
        )
        XCTAssertFalse(
            try SQLiteSyncRepository(databaseURL: databaseURL)
                .journalEntries().isEmpty
        )

        XCTAssertThrowsError(
            try LocalFirstReplication(
                databaseURL: databaseURL,
                endpoint: AwaitingMaterializationEndpoint(),
                generationID: generationID,
                producerID: producerA,
                publicationWatermarkStore:
                    InMemoryReplicationPublicationWatermarkStore()
            )
        ) { error in
            guard case let SQLiteRepositoryError.invalidStoredValue(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(
                message,
                "replication V2 clean-cut authority is missing"
            )
        }
    }

    func testTwoSQLiteStoresConvergeThroughConfirmedSealedPublicationAndRestart()
        async throws
    {
        let sourceURL = makeDatabaseURL("source")
        let targetURL = makeDatabaseURL("target")
        let repositoryURL = makeRepositoryURL()
        let sourceRepository = SQLiteEngineRepository(databaseURL: sourceURL)
        let targetRepository = SQLiteEngineRepository(databaseURL: targetURL)
        try sourceRepository.save(NoonmarkEngine().snapshot())
        try targetRepository.save(NoonmarkEngine().snapshot())

        let source = NoonmarkEngine()
        _ = try source.createPoolTask(title: "复制运行时纵向切片", now: now)
        try sourceRepository.save(
            source.snapshot(),
            recordingChangesFor: SyncDeviceID("replication-source"),
            changedAt: now
        )

        let sourceRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: sourceURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let sourceState = try await sourceRuntime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )

        XCTAssertEqual(sourceState.worker, .idle)
        XCTAssertEqual(sourceState.convergence, .converged)
        XCTAssertEqual(sourceState.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(sourceState.appliedRemotePublicationCount, 0)
        XCTAssertEqual(
            try SQLiteReplicationLedger(
                databaseURL: sourceURL
            ).snapshot(
                generationID: generationID,
                producerID: producerA
            ).selfWatermark?.sequence,
            1
        )

        let targetRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: targetURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let targetState = try await targetRuntime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )

        XCTAssertEqual(targetState.convergence, .converged)
        XCTAssertEqual(targetState.appliedRemotePublicationCount, 1)
        XCTAssertEqual(
            Set(try targetRepository.load().taskPool().map(\.definition.title)),
            ["复制运行时纵向切片"]
        )

        let restartedSource = try LocalFirstReplication.openCleanCut(
            databaseURL: sourceURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let restartedTarget = try LocalFirstReplication.openCleanCut(
            databaseURL: targetURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let sourceRestartState = try await restartedSource.send(
            .reconcile(now: now.addingTimeInterval(3))
        )
        let targetRestartState = try await restartedTarget.send(
            .reconcile(now: now.addingTimeInterval(4))
        )

        XCTAssertEqual(sourceRestartState.appliedRemotePublicationCount, 1)
        XCTAssertEqual(targetRestartState.appliedRemotePublicationCount, 0)
        XCTAssertEqual(
            try sourceRepository.load().snapshot(),
            try targetRepository.load().snapshot()
        )
    }

    func testRestartRestoresPendingPublicationAfterObservationCrashAndConvergesOnce()
        async throws
    {
        let sourceURL = makeDatabaseURL("crash-source")
        let targetURL = makeDatabaseURL("crash-target")
        let repositoryURL = makeRepositoryURL()
        let sourceRepository = SQLiteEngineRepository(databaseURL: sourceURL)
        let targetRepository = SQLiteEngineRepository(databaseURL: targetURL)
        try sourceRepository.save(NoonmarkEngine().snapshot())
        try targetRepository.save(NoonmarkEngine().snapshot())

        let source = NoonmarkEngine()
        _ = try source.createPoolTask(title: "确认前崩溃恢复", now: now)
        try sourceRepository.save(
            source.snapshot(),
            recordingChangesFor: SyncDeviceID("crash-recovery-source"),
            changedAt: now
        )

        let fileEndpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let interruptedRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: sourceURL,
            endpoint: FailFirstObservationEndpoint(base: fileEndpoint),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        do {
            _ = try await interruptedRuntime.send(
                .reconcile(now: now.addingTimeInterval(1))
            )
            XCTFail("expected the injected observation crash")
        } catch InjectedEndpointFailure.observationInterrupted {}

        let restartedSource = try LocalFirstReplication.openCleanCut(
            databaseURL: sourceURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        var restoredStates = await restartedSource.states().makeAsyncIterator()
        let nextRestoredState = await restoredStates.next()
        let restoredState = try XCTUnwrap(nextRestoredState)

        XCTAssertEqual(restoredState.worker, .idle)
        XCTAssertEqual(restoredState.convergence, .waitingForEndpoint)
        XCTAssertEqual(restoredState.incident, .runtimeFailure)
        XCTAssertEqual(restoredState.pendingLocalPublicationCount, 1)

        let recoveredState = try await restartedSource.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        XCTAssertEqual(recoveredState.convergence, .converged)
        XCTAssertEqual(recoveredState.pendingLocalPublicationCount, 0)
        XCTAssertEqual(recoveredState.confirmedLocalPublicationCount, 1)

        let targetRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: targetURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let firstTargetState = try await targetRuntime.send(
            .reconcile(now: now.addingTimeInterval(3))
        )
        let secondTargetState = try await targetRuntime.send(
            .reconcile(now: now.addingTimeInterval(4))
        )

        XCTAssertEqual(firstTargetState.appliedRemotePublicationCount, 1)
        XCTAssertEqual(secondTargetState.appliedRemotePublicationCount, 0)
        XCTAssertEqual(
            try targetRepository.load().taskPool().map(\.definition.title),
            ["确认前崩溃恢复"]
        )
    }

    func testPromisedItemMaterializationIsWaitingRatherThanRuntimeFailure()
        async throws
    {
        let databaseURL = makeDatabaseURL("materialization-wait")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: AwaitingMaterializationEndpoint(),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )

        let waitingState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )

        XCTAssertEqual(waitingState.worker, .idle)
        XCTAssertEqual(waitingState.convergence, .waitingForEndpoint)
        XCTAssertNil(waitingState.incident)
        XCTAssertNil(waitingState.lastSyncedAt)
        XCTAssertEqual(
            waitingState.lastEffectiveSyncedAt,
            now.addingTimeInterval(1)
        )

        let convergedState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )

        XCTAssertEqual(convergedState.convergence, .converged)
        XCTAssertNil(convergedState.incident)
        XCTAssertEqual(
            convergedState.lastSyncedAt,
            now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            convergedState.lastEffectiveSyncedAt,
            now.addingTimeInterval(1)
        )
    }

    func testProducerForkIsAnActionableIncidentRatherThanRuntimeFailure()
        async throws
    {
        let databaseURL = makeDatabaseURL("producer-fork")
        let repositoryURL = makeRepositoryURL()
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [try preferenceRecord(index: 1)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 2)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)

        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        var states = await runtime.states().makeAsyncIterator()
        _ = await states.next()
        let state = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        let observedStates = await statesUntil(
            state,
            from: &states
        )

        XCTAssertEqual(state.worker, .idle)
        XCTAssertEqual(state.convergence, .converged)
        XCTAssertNil(state.incident)
        XCTAssertTrue(observedStates.contains {
            $0.convergence == .blocked
                && $0.incident == .producerForkDetected
        })
        XCTAssertEqual(state.lastSyncedAt, now.addingTimeInterval(1))
        XCTAssertEqual(
            state.lastEffectiveSyncedAt,
            now.addingTimeInterval(1)
        )

        let expectedEvidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
            ]
        )
        let resolution = try XCTUnwrap(
            SQLiteReplicationLedger(databaseURL: databaseURL)
                .forkResolution(
                    resolutionID: expectedEvidence.resolutionID
                )
        )
        XCTAssertEqual(resolution.state, .closed)
        XCTAssertEqual(resolution.evidence, expectedEvidence)
    }

    func testForkDescendantCreatesANewDurableResolutionInsteadOfBeingIgnored()
        async throws
    {
        let databaseURL = makeDatabaseURL("producer-fork-descendant")
        let repositoryURL = makeRepositoryURL()
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [try preferenceRecord(index: 1)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 2)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)

        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        var states = await runtime.states().makeAsyncIterator()
        _ = await states.next()
        let firstState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        let firstObservedStates = await statesUntil(
            firstState,
            from: &states
        )
        XCTAssertNil(firstState.incident)
        XCTAssertEqual(firstState.convergence, .converged)
        XCTAssertTrue(firstObservedStates.contains {
            $0.incident == .producerForkDetected
        })
        let firstEvidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
            ]
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        XCTAssertEqual(
            try ledger.forkResolution(
                resolutionID: firstEvidence.resolutionID
            )?.state,
            .closed
        )

        let descendant = try builder.seal(
            records: [try preferenceRecord(index: 3)],
            generationID: generationID,
            producerID: producerA,
            sequence: 2,
            previousSealDigest: first.reference.sealDigest
        )
        try seedImmutable(descendant, into: repositoryURL)
        let secondState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        let secondObservedStates = await statesUntil(
            secondState,
            from: &states
        )
        XCTAssertNil(secondState.incident)
        XCTAssertEqual(secondState.convergence, .converged)
        XCTAssertTrue(secondObservedStates.contains {
            $0.incident == .producerForkDetected
        })
        let expandedEvidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
                ReceivedReplicationPublication(
                    reference: descendant.reference,
                    records: descendant.records
                ),
            ]
        )
        XCTAssertNotEqual(
            expandedEvidence.resolutionID,
            firstEvidence.resolutionID
        )
        let expandedResolution = try XCTUnwrap(
            ledger.forkResolution(
                resolutionID: expandedEvidence.resolutionID
            )
        )
        XCTAssertEqual(expandedResolution.state, .closed)
        XCTAssertEqual(expandedResolution.evidence, expandedEvidence)
    }

    func testConflictFreeForkRepairsPublishesBaselineAndStaysClosedAfterRestart()
        async throws
    {
        let databaseURL = makeDatabaseURL("conflict-free-fork-repair")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: try taskRecords(index: 1),
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: try taskRecords(index: 2),
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let evidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
            ]
        )

        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let repaired = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )

        XCTAssertEqual(repaired.convergence, .converged)
        XCTAssertNil(repaired.incident)
        XCTAssertEqual(repaired.appliedRemotePublicationCount, 2)
        XCTAssertEqual(repaired.confirmedLocalPublicationCount, 2)
        XCTAssertEqual(
            Set(try engineRepository.load().taskPool().map(\.definition.title)),
            ["分叉修复任务 1", "分叉修复任务 2"]
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        XCTAssertEqual(
            try ledger.forkResolution(
                resolutionID: evidence.resolutionID
            )?.state,
            .closed
        )
        let repairBaseline = try XCTUnwrap(
            ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerB
            )
        )
        XCTAssertEqual(
            repairBaseline.basedOnResolutionID,
            evidence.resolutionID,
            "closed repair must bind its local baseline to exact fork evidence"
        )

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let restartedState = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(2))
        )
        XCTAssertEqual(restartedState.convergence, .converged)
        XCTAssertNil(restartedState.incident)
        XCTAssertEqual(restartedState.appliedRemotePublicationCount, 0)
        XCTAssertEqual(restartedState.confirmedLocalPublicationCount, 0)
        XCTAssertEqual(
            Set(try engineRepository.load().taskPool().map(\.definition.title)),
            ["分叉修复任务 1", "分叉修复任务 2"]
        )
    }

    func testSelfForkRotatesProducerEpochAndRestartNeverPublishesOnRetiredChain()
        async throws
    {
        let databaseURL = makeDatabaseURL("self-fork-epoch-rotation")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let initialRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore,
            installedAt: now
        )
        let initialState = try await initialRuntime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(initialState.convergence, .converged)
        _ = try await initialRuntime.shutdown()
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        let retiredBaseline = try XCTUnwrap(
            ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            )
        )
        let builder = ReplicationPublicationBuilder()
        let fork = try builder.seal(
            records: try taskRecords(index: 2),
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: fork)

        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let repaired = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )

        XCTAssertEqual(repaired.convergence, .converged)
        XCTAssertNil(repaired.incident)
        XCTAssertEqual(repaired.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(
            try ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            ),
            retiredBaseline,
            "retiring an epoch must preserve its immutable local history"
        )
        let replacementProducerID = try ledger.loadOrInstallActiveProducerID(
            suggestedProducerID: producerA,
            installedAt: now.addingTimeInterval(3)
        )
        XCTAssertNotEqual(replacementProducerID, producerA)

        let restartedEngine = try engineRepository.load()
        _ = try restartedEngine.createPoolTask(
            title: "轮换后本机修改",
            now: now.addingTimeInterval(4)
        )
        try engineRepository.save(
            restartedEngine.snapshot(),
            recordingChangesFor: SyncDeviceID("rotated-producer"),
            changedAt: now.addingTimeInterval(4)
        )
        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: ContentAddressedFileReplicationEndpoint(
                rootURL: repositoryURL,
                generationID: generationID
            ),
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let restartedState = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(5))
        )

        XCTAssertEqual(restartedState.convergence, .converged)
        XCTAssertNil(restartedState.incident)
        XCTAssertEqual(restartedState.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(
            try ledger.loadOrInstallActiveProducerID(
                suggestedProducerID: producerA,
                installedAt: now.addingTimeInterval(6)
            ),
            replacementProducerID,
            "restart must restore the rotated epoch instead of the old seed"
        )
    }

    func testKeychainAheadOfSQLiteRotatesEpochBeforePublishAndRestartsCleanly()
        async throws
    {
        let databaseURL = makeDatabaseURL("rollback-watermark-rotation")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "回退前任务", now: now)
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("rollback-source"),
            changedAt: now
        )
        let watermarkStore = RollbackWatermarkStore()
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let firstRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore
        )
        let firstState = try await firstRuntime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(firstState.convergence, .converged)
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        let oldReference = try XCTUnwrap(
            ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            )
        )
        XCTAssertEqual(oldReference.sequence, 1)
        let oldScope = ReplicationPublicationWatermarkScope(
            generationID: generationID,
            producerID: producerA
        )
        XCTAssertEqual(
            watermarkStore.load(in: oldScope),
            oldReference.publicationWatermark
        )
        watermarkStore.overwriteForRollbackTest(
            ReplicationPublicationWatermark(
                sequence: 2,
                sealDigest: ReplicationDigest(
                    rawValue: String(repeating: "e", count: 64)
                )!
            ),
            in: oldScope
        )

        let changed = try engineRepository.load()
        _ = try changed.createPoolTask(
            title: "回退后仍须保留的任务",
            now: now.addingTimeInterval(2)
        )
        try engineRepository.save(
            changed.snapshot(),
            recordingChangesFor: SyncDeviceID("rollback-source"),
            changedAt: now.addingTimeInterval(2)
        )
        let recoveredRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore
        )
        let recovered = try await recoveredRuntime.send(
            .reconcile(now: now.addingTimeInterval(3))
        )

        XCTAssertEqual(recovered.convergence, .converged)
        XCTAssertNil(recovered.incident)
        XCTAssertEqual(recovered.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(
            try ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            ),
            oldReference,
            "a mismatched producer must be retired before sealing new facts"
        )

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore
        )
        let restartedState = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(4))
        )
        XCTAssertEqual(restartedState.convergence, .converged)
        XCTAssertEqual(restartedState.confirmedLocalPublicationCount, 0)
        XCTAssertEqual(restartedState.appliedRemotePublicationCount, 0)
        XCTAssertEqual(
            Set(try engineRepository.load().taskPool().map(\.definition.title)),
            ["回退前任务", "回退后仍须保留的任务"]
        )
    }

    func testSQLiteAheadOfKeychainNeverPublishesOldEpochAndRecoversOnRestart()
        async throws
    {
        let databaseURL = makeDatabaseURL("seal-before-keychain-crash")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let watermarkStore = RollbackWatermarkStore()
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let initialRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore,
            installedAt: now
        )
        let initialState = try await initialRuntime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(initialState.convergence, .converged)
        _ = try await initialRuntime.shutdown()
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        let oldBaseline = try XCTUnwrap(
            ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            )
        )

        let engine = try engineRepository.load()
        _ = try engine.createPoolTask(
            title: "镜像提交前中断",
            now: now.addingTimeInterval(2)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("watermark-crash"),
            changedAt: now.addingTimeInterval(2)
        )
        watermarkStore.failNextComparisonForCrashTest()
        let interrupted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore
        )

        do {
            _ = try await interrupted.send(
                .reconcile(now: now.addingTimeInterval(3))
            )
            XCTFail("the injected Keychain CAS interruption must fail closed")
        } catch let error as ReplicationPublicationWatermarkStoreError {
            XCTAssertEqual(error, .comparisonFailed)
        }
        XCTAssertEqual(
            try ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerA
            )?.sequence,
            2,
            "SQLite seal is durable before the external watermark CAS"
        )
        let beforeRestart = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 64,
                maximumBytes: 8 * 1024 * 1024
            )
        )
        XCTAssertEqual(
            beforeRestart.publications.map(\.reference),
            [oldBaseline],
            "the unmirrored sequence must never reach the endpoint"
        )

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerA,
            publicationWatermarkStore: watermarkStore
        )
        let recovered = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(4))
        )

        XCTAssertEqual(recovered.convergence, .converged)
        XCTAssertNil(recovered.incident)
        XCTAssertEqual(recovered.confirmedLocalPublicationCount, 1)
        let afterRestart = try await endpoint.read(
            after: .origin,
            budget: ReplicationReadBudget(
                maximumPublications: 64,
                maximumBytes: 8 * 1024 * 1024
            )
        )
        XCTAssertEqual(afterRestart.publications.count, 2)
        XCTAssertFalse(afterRestart.publications.contains {
            $0.reference.producerID == producerA
                && $0.reference.sequence == 2
        })
        XCTAssertEqual(
            try ledger.outboxSnapshot(generationID: generationID).pendingCount,
            0
        )
        XCTAssertNotEqual(
            try ledger.loadOrInstallActiveProducerID(
                suggestedProducerID: producerA,
                installedAt: now.addingTimeInterval(5)
            ),
            producerA
        )
    }

    func testForkWithDomainConflictDoesNotApplyAdvanceCursorOrPublishBaseline()
        async throws
    {
        let databaseURL = makeDatabaseURL("fork-domain-conflict")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let collision = try conflictingTaskDefinitionRecords()
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [collision.first],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [collision.second],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let evidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
            ]
        )
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        let cleanCutBaseline = try XCTUnwrap(
            ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerB
            )
        )

        let firstState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        let secondState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )

        for state in [firstState, secondState] {
            XCTAssertEqual(state.convergence, .blocked)
            XCTAssertEqual(state.incident, .producerForkDetected)
            XCTAssertEqual(
                state.actionableForkConflict?.resolutionID,
                evidence.resolutionID
            )
            XCTAssertFalse(
                state.actionableForkConflict?.conflicts.isEmpty ?? true
            )
            XCTAssertNil(state.lastSyncedAt)
            XCTAssertEqual(
                state.lastEffectiveSyncedAt,
                now.addingTimeInterval(1)
            )
            XCTAssertEqual(state.appliedRemotePublicationCount, 0)
        }
        XCTAssertEqual(firstState.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(secondState.confirmedLocalPublicationCount, 0)
        XCTAssertTrue(try engineRepository.load().taskPool().isEmpty)
        XCTAssertEqual(
            try ledger.forkResolution(
                resolutionID: evidence.resolutionID
            )?.state,
            .branchesValidated
        )
        XCTAssertEqual(
            try ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerB
            ),
            cleanCutBaseline,
            "a blocked fork must not publish a repair baseline"
        )
        let conflictSet = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL)
                .replicationForkConflictSet(
                    resolutionID: evidence.resolutionID
                )
        )
        XCTAssertFalse(conflictSet.conflicts.isEmpty)
        XCTAssertTrue(conflictSet.conflicts.allSatisfy {
            $0.decision == nil && $0.decidedAt == nil
        })

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        var restoredStates = await restarted.states().makeAsyncIterator()
        let restored = await restoredStates.next()
        XCTAssertEqual(
            restored?.actionableForkConflict,
            firstState.actionableForkConflict
        )
    }

    func testRepairBaselineWithoutALocallyClosedResolutionIsRejected()
        async throws
    {
        let databaseURL = makeDatabaseURL("unbound-repair-baseline")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        try engineRepository.save(NoonmarkEngine().snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let unboundResolutionID = ReplicationDigest(
            rawValue: String(repeating: "a", count: 64)
        )!
        let unboundBaseline = try ReplicationPublicationBuilder().seal(
            records: [try preferenceRecord(index: 1)],
            generationID: generationID,
            producerID: producerC,
            sequence: 1,
            previousSealDigest: nil,
            basedOnResolutionID: unboundResolutionID,
            resolutionManifest: ReplicationForkResolutionManifest(
                resolutionID: unboundResolutionID,
                decidedAt: nil,
                outcomes: []
            )
        )
        _ = try await endpoint.publish(sealed: unboundBaseline)
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )

        let firstState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        let secondState = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(2))
        )

        for state in [firstState, secondState] {
            XCTAssertEqual(state.convergence, .blocked)
            XCTAssertEqual(state.incident, .repairBaselineRejected)
            XCTAssertEqual(state.appliedRemotePublicationCount, 0)
            XCTAssertNil(state.lastSyncedAt)
            XCTAssertEqual(
                state.lastEffectiveSyncedAt,
                now.addingTimeInterval(1)
            )
        }
        XCTAssertEqual(
            try engineRepository.load().snapshot(),
            NoonmarkEngine().snapshot()
        )
    }

    func testKeepCurrentForkDecisionAtomicallyClosesAndPublishesRepairBaseline()
        async throws
    {
        let databaseURL = makeDatabaseURL("fork-keep-current")
        let repositoryURL = makeRepositoryURL()
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let local = NoonmarkEngine()
        _ = try local.createPoolTask(title: "保留本机事实", now: now)
        try engineRepository.save(local.snapshot())
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        let collision = try conflictingTaskDefinitionRecords()
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [collision.first],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [collision.second],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let evidence = try ReplicationForkEvidence(
            branches: [
                ReceivedReplicationPublication(
                    reference: first.reference,
                    records: first.records
                ),
                ReceivedReplicationPublication(
                    reference: fork.reference,
                    records: fork.records
                ),
            ]
        )
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )

        let blocked = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(1))
        )
        let actionable = try XCTUnwrap(blocked.actionableForkConflict)
        do {
            _ = try await runtime.send(
                .resolveForkConflicts(
                    resolutionID: actionable.resolutionID,
                    decisions: [],
                    now: now.addingTimeInterval(2)
                )
            )
            XCTFail("an incomplete decision set must fail closed")
        } catch {}

        _ = try local.createPoolTask(
            title: "决定期间新增的本机事实",
            now: now.addingTimeInterval(3)
        )
        try engineRepository.save(local.snapshot())
        let staleSelections = actionable.conflicts.map {
            ReplicationForkConflictDecisionSelection(
                conflictID: $0.conflictID,
                decision: .keepCurrent
            )
        }
        do {
            _ = try await runtime.send(
                .resolveForkConflicts(
                    resolutionID: actionable.resolutionID,
                    decisions: staleSelections,
                    now: now.addingTimeInterval(4)
                )
            )
            XCTFail("a stale engine generation must fail closed")
        } catch {}
        XCTAssertEqual(
            try SQLiteReplicationLedger(databaseURL: databaseURL)
                .forkResolution(resolutionID: evidence.resolutionID)?.state,
            .branchesValidated
        )
        XCTAssertTrue(
            try XCTUnwrap(
                SQLiteSyncRepository(databaseURL: databaseURL)
                    .replicationForkConflictSet(
                        resolutionID: evidence.resolutionID
                    )
            ).conflicts.allSatisfy { $0.decision == nil }
        )

        let refreshed = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(5))
        )
        let refreshedAction = try XCTUnwrap(
            refreshed.actionableForkConflict
        )
        let selections = refreshedAction.conflicts.map {
            ReplicationForkConflictDecisionSelection(
                conflictID: $0.conflictID,
                decision: .keepCurrent
            )
        }
        let repaired = try await runtime.send(
            .resolveForkConflicts(
                resolutionID: refreshedAction.resolutionID,
                decisions: selections,
                now: now.addingTimeInterval(6)
            )
        )

        XCTAssertEqual(repaired.convergence, .converged)
        XCTAssertNil(repaired.incident)
        XCTAssertNil(repaired.actionableForkConflict)
        XCTAssertEqual(repaired.confirmedLocalPublicationCount, 1)
        XCTAssertEqual(
            Set(try engineRepository.load().taskPool().map(\.definition.title)),
            ["保留本机事实", "决定期间新增的本机事实"]
        )
        XCTAssertEqual(
            try SQLiteReplicationLedger(databaseURL: databaseURL)
                .forkResolution(resolutionID: evidence.resolutionID)?.state,
            .closed
        )
        let conflictSet = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL)
                .replicationForkConflictSet(
                    resolutionID: evidence.resolutionID
                )
        )
        XCTAssertTrue(conflictSet.conflicts.allSatisfy {
            $0.decision == .keepCurrent && $0.decidedAt != nil
        })
        let repairBaseline = try XCTUnwrap(
            try SQLiteReplicationLedger(databaseURL: databaseURL)
                .latestSealedReference(
                    generationID: generationID,
                    producerID: producerB
                )
        )
        XCTAssertEqual(
            repairBaseline.basedOnResolutionID,
            evidence.resolutionID
        )
    }

    func testTaskDefinitionAcceptRemoteCreatesAForwardRevisionAndPreservesHistory()
        async throws
    {
        let databaseURL = makeDatabaseURL("fork-decision-capabilities")
        let repositoryURL = makeRepositoryURL()
        let today = LocalDate("2026-08-11")
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "本机历史标题",
            now: now
        )
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(local.snapshot())

        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        try remote.updatePoolTask(
            chainID: chainID,
            title: "远端候选标题",
            descriptionText: "远端候选描述",
            now: now.addingTimeInterval(3)
        )
        let remoteDefinition = try XCTUnwrap(
            remote.snapshot().definitions.first
        )
        let mapper = SyncRecordMapper()
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [
                try mapper.record(
                    for: remoteDefinition,
                    modifiedBy: SyncDeviceID("fork-decision-remote")
                ),
            ],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 7)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )

        let blocked = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(4))
        )

        let conflict = try XCTUnwrap(
            blocked.actionableForkConflict?.conflicts.first {
                $0.type == .taskDefinitionMutation
            }
        )
        XCTAssertEqual(conflict.entityType, .taskDefinition)
        XCTAssertEqual(
            conflict.allowedDecisions,
            [.keepCurrent, .acceptRemote, .copyAsNew]
        )

        let repaired = try await runtime.send(
            .resolveForkConflicts(
                resolutionID: try XCTUnwrap(
                    blocked.actionableForkConflict?.resolutionID
                ),
                decisions: [
                    ReplicationForkConflictDecisionSelection(
                        conflictID: conflict.conflictID,
                        decision: .acceptRemote
                    ),
                ],
                now: now.addingTimeInterval(5)
            )
        )

        XCTAssertEqual(repaired.convergence, .converged)
        XCTAssertNil(repaired.incident)
        let snapshot = try SQLiteEngineRepository(databaseURL: databaseURL)
            .load().snapshot()
        let definitions = snapshot.definitions
            .filter { $0.chainID == chainID }
            .sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].title, "本机历史标题")
        XCTAssertEqual(definitions[0].supersededByDefinitionID, definitions[1].id)
        XCTAssertEqual(definitions[1].title, "远端候选标题")
        XCTAssertEqual(definitions[1].descriptionText, "远端候选描述")
        let historicalTrace = try XCTUnwrap(
            snapshot.traces.first { $0.id == traceID }
        )
        XCTAssertEqual(historicalTrace.status, .completed)
        XCTAssertEqual(historicalTrace.definitionID, definitions[0].id)
        let storedConflict = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL)
                .replicationForkConflictSet(
                    resolutionID: try XCTUnwrap(
                        blocked.actionableForkConflict?.resolutionID
                    )
                )?.conflicts.first {
                    $0.conflict.id == conflict.conflictID
                }
        )
        XCTAssertEqual(storedConflict.decision, .acceptRemote)
        XCTAssertEqual(
            storedConflict.resultReference,
            ReplicationForkDecisionResultReference(
                entityType: .taskDefinition,
                entityID: definitions[1].id.description
            )
        )

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        var states = await restarted.states().makeAsyncIterator()
        let restartedState = await states.next()
        XCTAssertNil(restartedState?.actionableForkConflict)
    }

    func testThirdDeviceReplaysPublishedForkDecisionWithoutAskingAgain()
        async throws
    {
        let decidingDatabaseURL = makeDatabaseURL("fork-decision-device-b")
        let followingDatabaseURL = makeDatabaseURL("fork-decision-device-c")
        let repositoryURL = makeRepositoryURL()
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "共同的本机版本",
            now: now
        )
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let today = LocalDate("2026-08-11")
        let historicalTraceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.markCompleted(
            traceID: historicalTraceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        try SQLiteEngineRepository(databaseURL: decidingDatabaseURL)
            .save(local.snapshot())
        let following = try NoonmarkEngine(snapshot: local.snapshot())
        let unrelatedChainID = try following.createPoolTask(
            title: "第三台设备的无关本机事实",
            now: now.addingTimeInterval(3)
        )
        try SQLiteEngineRepository(databaseURL: followingDatabaseURL).save(
            following.snapshot(),
            recordingChangesFor: SyncDeviceID("replication-device-c"),
            changedAt: now.addingTimeInterval(3)
        )

        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        try remote.updatePoolTask(
            chainID: chainID,
            title: "用户决定接受的远端版本",
            descriptionText: "决定必须可由其他设备验证重放",
            now: now.addingTimeInterval(4)
        )
        let remoteDefinition = try XCTUnwrap(
            remote.snapshot().definitions.first
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [
                try SyncRecordMapper().record(
                    for: remoteDefinition,
                    modifiedBy: SyncDeviceID("fork-decision-remote")
                ),
            ],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 17)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)

        let deciding = try LocalFirstReplication.openCleanCut(
            databaseURL: decidingDatabaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        let blocked = try await deciding.send(
            .reconcile(now: now.addingTimeInterval(5))
        )
        let action = try XCTUnwrap(blocked.actionableForkConflict)
        let conflict = try XCTUnwrap(action.conflicts.first {
            $0.type == .taskDefinitionMutation
        })
        let decidingResult = try await deciding.send(
            .resolveForkConflicts(
                resolutionID: action.resolutionID,
                decisions: [
                    ReplicationForkConflictDecisionSelection(
                        conflictID: conflict.conflictID,
                        decision: .acceptRemote
                    ),
                ],
                now: now.addingTimeInterval(6)
            )
        )
        XCTAssertEqual(decidingResult.convergence, .converged)

        let followingRuntime = try LocalFirstReplication.openCleanCut(
            databaseURL: followingDatabaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerC,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        let followed = try await followingRuntime.send(
            .reconcile(now: now.addingTimeInterval(7))
        )

        XCTAssertEqual(followed.convergence, .converged)
        XCTAssertNil(followed.incident)
        XCTAssertNil(followed.actionableForkConflict)
        let decidingSnapshot = try SQLiteEngineRepository(
            databaseURL: decidingDatabaseURL
        ).load().snapshot()
        let followingSnapshot = try SQLiteEngineRepository(
            databaseURL: followingDatabaseURL
        ).load().snapshot()
        let decidingForward = try XCTUnwrap(
            decidingSnapshot.definitions.first {
                $0.chainID == chainID && $0.title == "用户决定接受的远端版本"
            }
        )
        let followingForward = try XCTUnwrap(
            followingSnapshot.definitions.first {
                $0.chainID == chainID && $0.title == "用户决定接受的远端版本"
            }
        )
        XCTAssertEqual(followingForward.id, decidingForward.id)
        XCTAssertNotNil(
            followingSnapshot.chains.first { $0.id == unrelatedChainID }
        )

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: followingDatabaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerC,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        var states = await restarted.states().makeAsyncIterator()
        let restored = await states.next()
        XCTAssertNil(restored?.actionableForkConflict)
        XCTAssertEqual(
            followingSnapshot.definitions.filter { $0.chainID == chainID }
                .count,
            2
        )
    }

    func testThirdDeviceRejectsCompetingForkDecisionManifestsWithoutMutation()
        async throws
    {
        let databaseURL = makeDatabaseURL("fork-competing-manifests")
        let repositoryURL = makeRepositoryURL()
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(title: "不可被竞争决定改写", now: now)
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let today = LocalDate("2026-08-11")
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        let originalSnapshot = local.snapshot()
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(originalSnapshot)

        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        try remote.updatePoolTask(
            chainID: chainID,
            title: "竞争的远端版本",
            now: now.addingTimeInterval(3)
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [
                try SyncRecordMapper().record(
                    for: try XCTUnwrap(remote.snapshot().definitions.first),
                    modifiedBy: SyncDeviceID("competing-manifest-remote")
                ),
            ],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 18)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let followingProducerID = UUID(
            uuidString: "92000000-0000-0000-0000-000000000004"
        )!
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: followingProducerID,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        let initiallyBlocked = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(4))
        )
        let action = try XCTUnwrap(
            initiallyBlocked.actionableForkConflict
        )
        let conflict = try XCTUnwrap(action.conflicts.first {
            $0.type == .taskDefinitionMutation
        })
        let decidedAt = now.addingTimeInterval(5)
        let keepManifest = ReplicationForkResolutionManifest(
            resolutionID: action.resolutionID,
            decidedAt: decidedAt,
            outcomes: [
                ReplicationForkResolutionOutcome(
                    conflictID: conflict.conflictID,
                    decision: .keepCurrent,
                    resultReference: nil
                ),
            ]
        )
        let acceptManifest = ReplicationForkResolutionManifest(
            resolutionID: action.resolutionID,
            decidedAt: decidedAt,
            outcomes: [
                ReplicationForkResolutionOutcome(
                    conflictID: conflict.conflictID,
                    decision: .acceptRemote,
                    resultReference:
                        ReplicationForkResolutionResultReference(
                            entityType: .taskDefinition,
                            entityID: UUID().uuidString
                        )
                ),
            ]
        )
        for (producerID, manifest, index) in [
            (producerB, keepManifest, 19),
            (producerC, acceptManifest, 20),
        ] {
            let baseline = try builder.seal(
                records: [try preferenceRecord(index: index)],
                generationID: generationID,
                producerID: producerID,
                sequence: 1,
                previousSealDigest: nil,
                basedOnResolutionID: action.resolutionID,
                resolutionManifest: manifest
            )
            _ = try await endpoint.publish(sealed: baseline)
        }

        let rejected = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(6))
        )

        XCTAssertEqual(rejected.convergence, .blocked)
        XCTAssertEqual(rejected.incident, .repairBaselineRejected)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: databaseURL)
                .load().snapshot(),
            originalSnapshot
        )
        let conflictSet = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL)
                .replicationForkConflictSet(
                    resolutionID: action.resolutionID
                )
        )
        XCTAssertTrue(conflictSet.conflicts.allSatisfy {
            $0.decision == nil && $0.decidedAt == nil
        })
        XCTAssertEqual(
            try SQLiteReplicationLedger(databaseURL: databaseURL)
                .forkResolution(resolutionID: action.resolutionID)?.state,
            .branchesValidated
        )
    }

    func testThirdDeviceRejectsManifestWithWrongDeterministicResultReference()
        async throws
    {
        let harness = try await historicalTaskDefinitionForkHarness(
            name: "fork-wrong-result-reference",
            preferenceIndex: 21
        )
        let conflict = try XCTUnwrap(harness.action.conflicts.first {
            $0.type == .taskDefinitionMutation
        })
        let manifest = ReplicationForkResolutionManifest(
            resolutionID: harness.action.resolutionID,
            decidedAt: now.addingTimeInterval(20),
            outcomes: [
                ReplicationForkResolutionOutcome(
                    conflictID: conflict.conflictID,
                    decision: .acceptRemote,
                    resultReference:
                        ReplicationForkResolutionResultReference(
                            entityType: .taskDefinition,
                            entityID: "ffffffff-ffff-4fff-bfff-ffffffffffff"
                        )
                ),
            ]
        )
        let baseline = try ReplicationPublicationBuilder().seal(
            records: [try preferenceRecord(index: 22)],
            generationID: generationID,
            producerID: producerB,
            sequence: 1,
            previousSealDigest: nil,
            basedOnResolutionID: harness.action.resolutionID,
            resolutionManifest: manifest
        )
        _ = try await harness.endpoint.publish(sealed: baseline)

        let rejected = try await harness.runtime.send(
            .reconcile(now: now.addingTimeInterval(21))
        )

        XCTAssertEqual(rejected.convergence, .blocked)
        XCTAssertEqual(rejected.incident, .repairBaselineRejected)
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: harness.databaseURL)
                .load().snapshot(),
            harness.originalSnapshot
        )
        XCTAssertTrue(
            try XCTUnwrap(
                SQLiteSyncRepository(databaseURL: harness.databaseURL)
                    .replicationForkConflictSet(
                        resolutionID: harness.action.resolutionID
                    )
            ).conflicts.allSatisfy {
                $0.decision == nil
                    && $0.decidedAt == nil
                    && $0.resultReference == nil
            }
        )
    }

    func testDisableJoinsBlockedWorkerAndRestartsAsDurablyDisabled()
        async throws
    {
        let databaseURL = makeDatabaseURL("durable-disable")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = BlockingLifecycleEndpoint()
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore(),
            stoppingDelay: .milliseconds(10)
        )
        var states = await runtime.states().makeAsyncIterator()
        _ = await states.next()
        let reconcileAt = now.addingTimeInterval(30)
        let reconcile = Task {
            try await runtime.send(
                .reconcile(now: reconcileAt)
            )
        }
        let concurrentReconcile = Task {
            try await runtime.send(
                .reconcile(now: reconcileAt.addingTimeInterval(1))
            )
        }
        await endpoint.waitUntilReadStarted()
        let readCount = await endpoint.readCount()
        XCTAssertEqual(readCount, 1)
        let disabling = Task {
            try await runtime.send(.disable)
        }
        await endpoint.waitUntilCancelStarted()
        _ = try? await reconcile.value
        _ = try? await concurrentReconcile.value
        var observedWorkerStates: [LocalFirstReplicationWorkerState] = []
        for _ in 0 ..< 3 {
            if let observed = await states.next() {
                observedWorkerStates.append(observed.worker)
            }
        }
        XCTAssertEqual(
            observedWorkerStates,
            [.running, .stopping, .stoppingDelayed]
        )
        await endpoint.finishJoin()
        let disabled = try await disabling.value

        XCTAssertEqual(disabled.worker, .disabled)
        XCTAssertNil(disabled.lastSyncedAt)
        XCTAssertNil(disabled.lastEffectiveSyncedAt)
        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        var restartedStates = await restarted.states().makeAsyncIterator()
        let restored = await restartedStates.next()
        XCTAssertEqual(restored?.worker, .disabled)
        XCTAssertNil(restored?.lastSyncedAt)
        XCTAssertNil(restored?.lastEffectiveSyncedAt)

        let enabled = try await restarted.send(.enable)
        XCTAssertEqual(enabled.worker, .idle)
        let converged = try await restarted.send(
            .reconcile(now: now.addingTimeInterval(31))
        )
        XCTAssertEqual(converged.convergence, .converged)
        XCTAssertNotNil(converged.lastSyncedAt)
        let control = try SQLiteSyncRepository(databaseURL: databaseURL)
            .localFirstReplicationControl()
        XCTAssertEqual(control.policy, .enabled)
        XCTAssertEqual(control.generation, 3)
    }

    func testShutdownJoinsBlockedWorkerButPreservesEnabledPolicyForRestart()
        async throws
    {
        let databaseURL = makeDatabaseURL("durable-shutdown")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = BlockingLifecycleEndpoint()
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore(),
            stoppingDelay: .milliseconds(10)
        )
        let reconcileAt = now.addingTimeInterval(40)
        let reconcile = Task {
            try await runtime.send(
                .reconcile(now: reconcileAt)
            )
        }
        await endpoint.waitUntilReadStarted()

        let shuttingDown = Task { try await runtime.shutdown() }
        await endpoint.waitUntilCancelStarted()
        _ = try? await reconcile.value
        await endpoint.finishJoin()
        let stopped = try await shuttingDown.value

        XCTAssertEqual(stopped.worker, .idle)
        let control = try SQLiteSyncRepository(databaseURL: databaseURL)
            .localFirstReplicationControl()
        XCTAssertEqual(control.policy, .enabled)
        XCTAssertEqual(control.generation, 2)

        let restarted = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: AwaitingMaterializationEndpoint(),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        var states = await restarted.states().makeAsyncIterator()
        let restored = await states.next()
        XCTAssertEqual(restored?.worker, .idle)
    }

    func testFailedShutdownFenceCanBeRetriedAndStillJoinsEndpoint()
        async throws
    {
        let databaseURL = makeDatabaseURL("retryable-shutdown-fence")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = CountingLifecycleEndpoint()
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
            InMemoryReplicationPublicationWatermarkStore()
        )

        var externalWriter: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(databaseURL.path, &externalWriter),
            SQLITE_OK
        )
        defer { sqlite3_close(externalWriter) }
        XCTAssertEqual(
            sqlite3_exec(
                externalWriter,
                "BEGIN IMMEDIATE TRANSACTION",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        do {
            _ = try await runtime.shutdown()
            XCTFail("a shutdown without its durable fence must fail")
        } catch {}
        let joinedAfterFailure = await endpoint.didCancelAndJoin()
        XCTAssertFalse(joinedAfterFailure)
        XCTAssertEqual(
            sqlite3_exec(externalWriter, "ROLLBACK", nil, nil, nil),
            SQLITE_OK
        )

        let stopped = try await runtime.shutdown()

        XCTAssertEqual(stopped.worker, .idle)
        let joinedAfterRetry = await endpoint.didCancelAndJoin()
        XCTAssertTrue(joinedAfterRetry)
        let control = try SQLiteSyncRepository(databaseURL: databaseURL)
            .localFirstReplicationControl()
        XCTAssertEqual(control.policy, .enabled)
        XCTAssertEqual(control.generation, 2)
    }

    func testAutomaticSchedulingIsOwnedAndJoinedByReplicationRuntime()
        async throws
    {
        let databaseURL = makeDatabaseURL("owned-automatic-loop")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        let endpoint = CountingLifecycleEndpoint()
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore(),
            stoppingDelay: .milliseconds(10)
        )

        try await runtime.startAutomatic(interval: .milliseconds(5))
        await endpoint.waitForReadCount(2)
        let stopped = try await runtime.shutdown()
        let countAtShutdown = await endpoint.readCount()
        try await Task.sleep(for: .milliseconds(20))
        let countAfterDelay = await endpoint.readCount()
        let didJoin = await endpoint.didCancelAndJoin()

        XCTAssertEqual(stopped.worker, .idle)
        XCTAssertEqual(countAfterDelay, countAtShutdown)
        XCTAssertTrue(didJoin)
    }

    func testDisabledControlRejectsLateDownloadCommitInsideSQLiteWriteLock()
        throws
    {
        let databaseURL = makeDatabaseURL("late-download-control-fence")
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let originalSnapshot = NoonmarkEngine().snapshot()
        try engineRepository.save(originalSnapshot)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let enabledControl = try syncRepository
            .loadOrInstallLocalFirstReplicationControl(installedAt: now)
        _ = try syncRepository.transitionLocalFirstReplicationControl(
            expectedGeneration: enabledControl.generation,
            policy: .disabled,
            updatedAt: now.addingTimeInterval(1)
        )
        let cursorMetadata = SyncMetadataEntry(
            key: "late-download-control-fence.cursor",
            value: Data([0x01]),
            updatedAt: now.addingTimeInterval(2)
        )

        XCTAssertThrowsError(
            try SQLiteSyncDownloadCoordinator(
                databaseURL: databaseURL,
                transport: InMemorySyncTransport()
            ).downloadAndMergeReplicationRecords(
                [try preferenceRecord(index: 23)],
                detectedAt: now.addingTimeInterval(2),
                cursorMetadata: cursorMetadata,
                expectedReplicationControl: enabledControl
            )
        )
        XCTAssertEqual(
            try engineRepository.load().snapshot(),
            originalSnapshot
        )
        XCTAssertNil(
            try syncRepository.metadata(for: cursorMetadata.key)
        )
    }

    func testRuntimeFailsClosedOnCorruptDurableControl() throws {
        let databaseURL = makeDatabaseURL("corrupt-runtime-control")
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(NoonmarkEngine().snapshot())
        _ = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: AwaitingMaterializationEndpoint(),
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        try SQLiteSyncRepository(databaseURL: databaseURL).saveMetadata(
            SyncMetadataEntry(
                key: SQLiteSyncRepository
                    .localFirstReplicationControlMetadataKey,
                value: Data("not-canonical-control".utf8),
                updatedAt: now
            )
        )

        XCTAssertThrowsError(
            try LocalFirstReplication(
                databaseURL: databaseURL,
                endpoint: AwaitingMaterializationEndpoint(),
                generationID: generationID,
                producerID: producerB,
                publicationWatermarkStore:
                    InMemoryReplicationPublicationWatermarkStore()
            )
        )
    }

    func testTaskDefinitionCopyAsNewCreatesAnIndependentCompletePoolTask()
        async throws
    {
        let databaseURL = makeDatabaseURL("fork-copy-task-definition")
        let repositoryURL = makeRepositoryURL()
        let today = LocalDate("2026-08-11")
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(
            title: "本机历史任务",
            descriptionText: "本机历史描述",
            initialNoteBody: "本机附言",
            now: now
        )
        _ = try base.addPlannedSubtask(
            chainID: chainID,
            title: "本机步骤",
            difficulty: .simple,
            now: now.addingTimeInterval(1)
        )
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(2)
        )
        let localSubtaskID = try XCTUnwrap(
            local.subtasks.values.first { $0.traceID == traceID }?.id
        )
        try local.completeSubtask(
            localSubtaskID,
            today: today,
            now: now.addingTimeInterval(3)
        )
        try local.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(4)
        )
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(local.snapshot())

        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        let remotePlanned = [
            PlannedSubtask(
                title: "远端步骤",
                difficulty: .hard,
                position: 1,
                now: now.addingTimeInterval(5)
            ),
        ]
        try remote.updatePoolTask(
            chainID: chainID,
            title: "远端副本任务",
            descriptionText: "远端副本描述",
            plannedSubtasks: remotePlanned,
            now: now.addingTimeInterval(5)
        )
        _ = try remote.appendPoolNote(
            chainID: chainID,
            body: "远端新增附言",
            now: now.addingTimeInterval(5)
        )
        let remoteSnapshot = remote.snapshot()
        let remoteDefinition = try XCTUnwrap(
            remoteSnapshot.definitions.first
        )
        let remoteChain = try XCTUnwrap(remoteSnapshot.chains.first)
        let mapper = SyncRecordMapper()
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [
                try mapper.record(
                    for: remoteChain,
                    modifiedBy: SyncDeviceID("fork-copy-chain")
                ),
                try mapper.record(
                    for: remoteDefinition,
                    modifiedBy: SyncDeviceID("fork-copy-definition")
                ),
            ],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: 9)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerB,
            publicationWatermarkStore: publicationWatermarkStore
        )
        let blocked = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(6))
        )
        let actionable = try XCTUnwrap(blocked.actionableForkConflict)
        let conflict = try XCTUnwrap(actionable.conflicts.first {
            $0.type == .taskDefinitionMutation
        })

        let repaired = try await runtime.send(
            .resolveForkConflicts(
                resolutionID: actionable.resolutionID,
                decisions: actionable.conflicts.map {
                    ReplicationForkConflictDecisionSelection(
                        conflictID: $0.conflictID,
                        decision: $0.conflictID == conflict.conflictID
                            ? .copyAsNew
                            : .keepCurrent
                    )
                },
                now: now.addingTimeInterval(7)
            )
        )

        XCTAssertEqual(repaired.convergence, .converged)
        let result = try SQLiteEngineRepository(databaseURL: databaseURL)
            .load()
        let copied = try XCTUnwrap(result.taskPool().first {
            $0.definition.title == "远端副本任务"
        })
        XCTAssertNotEqual(copied.chain.id, chainID)
        XCTAssertEqual(copied.definition.descriptionText, "远端副本描述")
        XCTAssertEqual(
            copied.chain.activeNoteEntries.map(\.body),
            ["本机附言", "远端新增附言"]
        )
        XCTAssertEqual(copied.definition.plannedSubtasks.count, 1)
        XCTAssertEqual(
            copied.definition.plannedSubtasks.first?.title,
            "远端步骤"
        )
        XCTAssertEqual(
            copied.definition.plannedSubtasks.first?.difficulty,
            .hard
        )
        let historical = try XCTUnwrap(result.snapshot().traces.first {
            $0.id == traceID
        })
        XCTAssertEqual(historical.status, .completed)
        let storedConflict = try XCTUnwrap(
            SQLiteSyncRepository(databaseURL: databaseURL)
                .replicationForkConflictSet(
                    resolutionID: actionable.resolutionID
                )?.conflicts.first {
                    $0.conflict.id == conflict.conflictID
                }
        )
        XCTAssertEqual(storedConflict.decision, .copyAsNew)
        XCTAssertEqual(
            storedConflict.resultReference,
            ReplicationForkDecisionResultReference(
                entityType: .taskChain,
                entityID: copied.chain.id.description
            )
        )
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-local-first-replication-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("noonmark.sqlite")
    }

    private func makeRepositoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-local-first-replication-repository-\(UUID().uuidString)",
                isDirectory: true
            )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func preferenceRecord(index: Int) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: index.isMultiple(of: 2) ? .coolGray : .warmPaper,
                language: index.isMultiple(of: 2) ? .english : .chinese,
                updatedAt: now.addingTimeInterval(Double(index))
            ),
            modifiedBy: SyncDeviceID("replication-fork-\(index)")
        )
    }

    private func taskRecords(index: Int) throws -> [SyncRecord] {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "分叉修复任务 \(index)",
            now: now.addingTimeInterval(Double(index))
        )
        return try SyncRecordMapper().records(
            from: engine.snapshot(),
            modifiedBy: SyncDeviceID("replication-repair-\(index)")
        ).filter {
            $0.entityType == .taskChain || $0.entityType == .taskDefinition
        }
    }

    private func conflictingTaskDefinitionRecords() throws -> (
        first: SyncRecord,
        second: SyncRecord
    ) {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(title: "分叉冲突", now: now)
        let definition = try XCTUnwrap(engine.snapshot().definitions.first)
        var divergent = definition
        divergent.chainID = TaskChainID()
        let mapper = SyncRecordMapper()
        return (
            try mapper.record(
                for: definition,
                modifiedBy: SyncDeviceID("fork-conflict-a")
            ),
            try mapper.record(
                for: divergent,
                modifiedBy: SyncDeviceID("fork-conflict-b")
            )
        )
    }

    private func historicalTaskDefinitionForkHarness(
        name: String,
        preferenceIndex: Int
    ) async throws -> (
        databaseURL: URL,
        endpoint: ContentAddressedFileReplicationEndpoint,
        runtime: LocalFirstReplication,
        originalSnapshot: NoonmarkSnapshot,
        action: LocalFirstReplicationActionableForkConflict
    ) {
        let databaseURL = makeDatabaseURL(name)
        let repositoryURL = makeRepositoryURL()
        let base = NoonmarkEngine()
        let chainID = try base.createPoolTask(title: "决定重放基线", now: now)
        let local = try NoonmarkEngine(snapshot: base.snapshot())
        let today = LocalDate("2026-08-11")
        let traceID = try local.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try local.markCompleted(
            traceID: traceID,
            today: today,
            now: now.addingTimeInterval(2)
        )
        let originalSnapshot = local.snapshot()
        try SQLiteEngineRepository(databaseURL: databaseURL)
            .save(originalSnapshot)
        let remote = try NoonmarkEngine(snapshot: base.snapshot())
        try remote.updatePoolTask(
            chainID: chainID,
            title: "决定重放远端版本",
            now: now.addingTimeInterval(3)
        )
        let builder = ReplicationPublicationBuilder()
        let first = try builder.seal(
            records: [
                try SyncRecordMapper().record(
                    for: try XCTUnwrap(remote.snapshot().definitions.first),
                    modifiedBy: SyncDeviceID("manifest-harness-remote")
                ),
            ],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let fork = try builder.seal(
            records: [try preferenceRecord(index: preferenceIndex)],
            generationID: generationID,
            producerID: producerA,
            sequence: 1,
            previousSealDigest: nil
        )
        let endpoint = ContentAddressedFileReplicationEndpoint(
            rootURL: repositoryURL,
            generationID: generationID
        )
        _ = try await endpoint.publish(sealed: first)
        _ = try await endpoint.publish(sealed: fork)
        let runtime = try LocalFirstReplication.openCleanCut(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: UUID(
                uuidString: "92000000-0000-0000-0000-000000000005"
            )!,
            publicationWatermarkStore:
                InMemoryReplicationPublicationWatermarkStore()
        )
        let blocked = try await runtime.send(
            .reconcile(now: now.addingTimeInterval(4))
        )
        return (
            databaseURL,
            endpoint,
            runtime,
            originalSnapshot,
            try XCTUnwrap(blocked.actionableForkConflict)
        )
    }

    private func statesUntil(
        _ terminal: LocalFirstReplicationState,
        from iterator: inout AsyncStream<LocalFirstReplicationState>
            .AsyncIterator
    ) async -> [LocalFirstReplicationState] {
        var observed: [LocalFirstReplicationState] = []
        for _ in 0 ..< 8 {
            guard let next = await iterator.next() else {
                break
            }
            observed.append(next)
            if next == terminal {
                break
            }
        }
        return observed
    }

    private func seedImmutable(
        _ publication: SealedReplicationPublication,
        into rootURL: URL
    ) throws {
        for object in publication.objects {
            let url = rootURL.appendingPathComponent(
                object.reference.relativeKey
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try object.bytes.write(to: url, options: [.withoutOverwriting])
        }
    }
}

private final class RollbackWatermarkStore:
    ReplicationPublicationWatermarkStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [
        ReplicationPublicationWatermarkScope: ReplicationPublicationWatermark
    ] = [:]
    private var comparisonFailuresRemaining = 0

    func load(
        in scope: ReplicationPublicationWatermarkScope
    ) -> ReplicationPublicationWatermark? {
        lock.lock()
        defer { lock.unlock() }
        return values[scope]
    }

    func compareAndSet(
        expected: ReplicationPublicationWatermark?,
        replacement: ReplicationPublicationWatermark,
        in scope: ReplicationPublicationWatermarkScope
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        if comparisonFailuresRemaining > 0 {
            comparisonFailuresRemaining -= 1
            throw ReplicationPublicationWatermarkStoreError.comparisonFailed
        }
        if values[scope] == replacement {
            return
        }
        guard values[scope] == expected,
              replacement.sequence == (expected?.sequence ?? 0) + 1
        else {
            throw ReplicationPublicationWatermarkStoreError.comparisonFailed
        }
        values[scope] = replacement
    }

    func overwriteForRollbackTest(
        _ watermark: ReplicationPublicationWatermark,
        in scope: ReplicationPublicationWatermarkScope
    ) {
        lock.lock()
        defer { lock.unlock() }
        values[scope] = watermark
    }

    func failNextComparisonForCrashTest() {
        lock.lock()
        defer { lock.unlock() }
        comparisonFailuresRemaining += 1
    }
}

private enum InjectedEndpointFailure: Error {
    case observationInterrupted
}

private actor FailFirstObservationEndpoint: ReplicationEndpoint {
    nonisolated let namespace: String

    private let base: ContentAddressedFileReplicationEndpoint
    private var shouldInterruptObservation = true

    init(base: ContentAddressedFileReplicationEndpoint) {
        self.base = base
        namespace = base.namespace
    }

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        try await base.publish(sealed: publication)
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        if shouldInterruptObservation {
            shouldInterruptObservation = false
            throw InjectedEndpointFailure.observationInterrupted
        }
        return try await base.observe(pending: receipts)
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        try await base.read(after: cursor, budget: budget)
    }

    func cancelAndJoin() async {
        await base.cancelAndJoin()
    }
}

private actor AwaitingMaterializationEndpoint: ReplicationEndpoint {
    nonisolated let namespace = "awaiting-materialization-test"

    private var waiting = true

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        receipts.map {
            ReplicationPublicationObservation(
                reference: $0.reference,
                state: .confirmed
            )
        }
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget _: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        defer { waiting = false }
        return ReplicationReadPage(
            publications: [],
            cursor: cursor,
            hasMore: false,
            openedByteCount: 0,
            state: waiting ? .awaitingMaterialization : .stable
        )
    }

    func cancelAndJoin() async {}
}

private actor RecordingConfirmationEndpoint: ReplicationEndpoint {
    nonisolated let namespace = "recording-confirmation-test"

    private var sequences: [UInt64] = []

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        sequences.append(publication.reference.sequence)
        return ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        receipts.map {
            ReplicationPublicationObservation(
                reference: $0.reference,
                state: .confirmed
            )
        }
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget _: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        ReplicationReadPage(
            publications: [],
            cursor: cursor,
            hasMore: false,
            openedByteCount: 0,
            state: .stable
        )
    }

    func publishedSequences() -> [UInt64] {
        sequences
    }

    func cancelAndJoin() async {}
}

private actor BlockingLifecycleEndpoint: ReplicationEndpoint {
    nonisolated let namespace = "blocking-lifecycle-test"

    private var readStarted = false
    private var observedReadCount = 0
    private var cancelStarted = false
    private var joinReleased = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Never>?
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        receipts.map {
            ReplicationPublicationObservation(
                reference: $0.reference,
                state: .confirmed
            )
        }
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget _: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        if cancelStarted, joinReleased {
            return ReplicationReadPage(
                publications: [],
                cursor: cursor,
                hasMore: false,
                openedByteCount: 0,
                state: .stable
            )
        }
        readStarted = true
        observedReadCount += 1
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
        await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
        return ReplicationReadPage(
            publications: [],
            cursor: cursor,
            hasMore: false,
            openedByteCount: 0,
            state: .stable
        )
    }

    func cancelAndJoin() async {
        cancelStarted = true
        cancelWaiters.forEach { $0.resume() }
        cancelWaiters.removeAll()
        readContinuation?.resume()
        readContinuation = nil
        guard joinReleased == false else { return }
        await withCheckedContinuation { continuation in
            joinContinuation = continuation
        }
    }

    func waitUntilReadStarted() async {
        guard readStarted == false else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
        }
    }

    func readCount() -> Int {
        observedReadCount
    }

    func waitUntilCancelStarted() async {
        guard cancelStarted == false else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    func finishJoin() {
        joinReleased = true
        joinContinuation?.resume()
        joinContinuation = nil
    }
}

private actor CountingLifecycleEndpoint: ReplicationEndpoint {
    nonisolated let namespace = "counting-lifecycle-test"

    private var observedReadCount = 0
    private var readWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var joined = false

    func publish(
        sealed publication: SealedReplicationPublication
    ) async throws -> ReplicationPublicationReceipt {
        ReplicationPublicationReceipt(
            reference: publication.reference,
            objects: publication.objects.map(\.reference)
        )
    }

    func observe(
        pending receipts: [ReplicationPublicationReceipt]
    ) async throws -> [ReplicationPublicationObservation] {
        receipts.map {
            ReplicationPublicationObservation(
                reference: $0.reference,
                state: .confirmed
            )
        }
    }

    func read(
        after cursor: ReplicationReadCursor,
        budget _: ReplicationReadBudget
    ) async throws -> ReplicationReadPage {
        observedReadCount += 1
        let ready = readWaiters.filter { observedReadCount >= $0.count }
        readWaiters.removeAll { observedReadCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return ReplicationReadPage(
            publications: [],
            cursor: cursor,
            hasMore: false,
            openedByteCount: 0,
            state: .stable
        )
    }

    func cancelAndJoin() async {
        joined = true
    }

    func waitForReadCount(_ count: Int) async {
        guard observedReadCount < count else { return }
        await withCheckedContinuation { continuation in
            readWaiters.append((count, continuation))
        }
    }

    func readCount() -> Int {
        observedReadCount
    }

    func didCancelAndJoin() -> Bool {
        joined
    }
}

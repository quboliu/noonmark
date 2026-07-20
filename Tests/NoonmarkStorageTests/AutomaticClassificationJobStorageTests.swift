import Dispatch
import Foundation
@_spi(AutomaticClassificationJobAuthority) @testable import NoonmarkCore
@testable import NoonmarkStorage
import NoonmarkSync
import SQLite3
import XCTest

final class AutomaticClassificationJobStorageTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 810_000_000)

    func testNewTaskSnapshotJournalAndAutomaticClassificationJobCommitAtomically() throws {
        let databaseURL = makeDatabaseURL("atomic-enqueue")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        let chainID = try engine.createPoolTask(
            title: "立即保存且稍后自动归类",
            descriptionText: "Provider 不得进入保存事务。",
            now: now
        )
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )

        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("automatic-classification-mac"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )

        XCTAssertEqual(try engineRepository.load().snapshot(), engine.snapshot())
        let persisted = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(persisted.chainID, chainID)
        XCTAssertEqual(persisted.state, .ready)
        XCTAssertEqual(persisted.generation, 1)
        XCTAssertEqual(
            try AutomaticClassificationAuthorityPayload.decode(
                persisted.authorityPayload
            ).jobID,
            enqueue.id
        )
        XCTAssertEqual(persisted.attempt, 0)
        XCTAssertNil(persisted.proposalCheckpoint)
        XCTAssertEqual(
            try SQLiteAutomaticClassificationJobRepository(databaseURL: databaseURL)
                .jobs(states: Set(AutomaticClassificationJobState.allCases)),
            [persisted]
        )

        let journal = try syncRepository.journalEntries()
        XCTAssertFalse(journal.isEmpty)
        XCTAssertFalse(journal.contains { $0.entityID == enqueue.id.uuidString })
        let package = try NoonmarkDataPackage.encode(try engineRepository.load().snapshot())
        XCTAssertEqual(try NoonmarkDataPackage.decode(package), engine.snapshot())
        XCTAssertEqual(try jobRepository.jobs(states: [.ready]), [persisted])
    }

    func testFutureDomainClockDoesNotDelayOrContaminateOperationalJobClock() throws {
        let databaseURL = makeDatabaseURL("independent-operational-clock")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())

        let operationalCreatedAt = now
        let futureDomainCreatedAt = now.addingTimeInterval(366 * 24 * 60 * 60)
        let chainID = try engine.createPoolTask(
            title: "未来领域时钟不得延迟本地队列",
            now: futureDomainCreatedAt
        )
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            availableAt: operationalCreatedAt,
            createdAt: operationalCreatedAt
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("independent-clock-device"),
            changedAt: futureDomainCreatedAt,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )

        let claim = try XCTUnwrap(
            jobRepository.claimNext(
                now: operationalCreatedAt.addingTimeInterval(1),
                staleBefore: operationalCreatedAt,
                claimID: UUID()
            )
        )
        try jobRepository.checkpointProposal(
            Data("independent-clock-proposal".utf8),
            for: claim,
            now: operationalCreatedAt.addingTimeInterval(2)
        )

        let authority = try AutomaticClassificationAuthorityPayload.decode(
            enqueue.authorityPayload
        )
        let futureDomainCompletedAt = futureDomainCreatedAt.addingTimeInterval(1)
        let plan = try engine.prepareAutomaticClassification(
            AutomaticClassificationApplicationProposal(
                category: .new(name: "时钟测试", colorHex: "#2A6FDB"),
                labels: [.new(name: "队列", colorHex: "#0E9488")]
            ),
            authority: authority,
            interactionID: UUID(),
            now: futureDomainCompletedAt
        )
        _ = try engine.commitAutomaticClassification(
            plan,
            authority: authority,
            now: futureDomainCompletedAt
        )
        let operationalCompletedAt = operationalCreatedAt.addingTimeInterval(3)
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("independent-clock-device"),
            changedAt: futureDomainCompletedAt,
            completingAutomaticClassificationJob: claim,
            automaticClassificationTransitionAt: operationalCompletedAt
        )

        let completed = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.createdAt, operationalCreatedAt)
        XCTAssertEqual(completed.updatedAt, operationalCompletedAt)
        XCTAssertEqual(completed.terminalAt, operationalCompletedAt)
        XCTAssertLessThan(completed.updatedAt, futureDomainCreatedAt)
        XCTAssertTrue(
            try syncRepository.journalEntries().contains {
                $0.changedAt == futureDomainCompletedAt
            }
        )
    }

    func testClaimReportsBoundedTransientContentionAndRemainsClaimableAfterLockRelease() throws {
        let databaseURL = makeDatabaseURL("claim-contention")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        var lockingDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &lockingDatabase), SQLITE_OK)
        defer {
            sqlite3_exec(lockingDatabase, "ROLLBACK", nil, nil, nil)
            sqlite3_close(lockingDatabase)
        }
        XCTAssertEqual(
            sqlite3_exec(
                lockingDatabase,
                "BEGIN IMMEDIATE TRANSACTION",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        var observedError: Error?
        do {
            _ = try repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
            XCTFail("a competing write lock must not allow the job claim")
        } catch {
            observedError = error
        }
        let elapsed = startedAt.duration(to: clock.now)
        let repositoryError = try XCTUnwrap(
            observedError as? SQLiteRepositoryError
        )
        XCTAssertEqual(repositoryError, .transientContention)
        XCTAssertTrue(repositoryError.isTransientContention)
        XCTAssertEqual(
            repositoryError.errorDescription,
            "SQLite is temporarily busy; retry later."
        )
        XCTAssertFalse(
            SQLiteRepositoryError.executeFailed("non-contention")
                .isTransientContention
        )
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        XCTAssertLessThan(elapsed, .seconds(2))

        XCTAssertEqual(
            sqlite3_exec(lockingDatabase, "COMMIT", nil, nil, nil),
            SQLITE_OK
        )
        let claim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        XCTAssertEqual(claim.jobID, fixture.enqueue.id)
        XCTAssertEqual(claim.attempt, 1)
    }

    func testClaimWaitsForShortWriteContentionAndSucceedsWithoutCallerRetry() throws {
        let databaseURL = makeDatabaseURL("short-claim-contention")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let writeLock = try SQLiteTestWriteLock(databaseURL: databaseURL)
        let releaseFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            writeLock.release()
            releaseFinished.signal()
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let claim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(
            releaseFinished.wait(timeout: .now() + .seconds(1)),
            .success
        )
        XCTAssertEqual(writeLock.releaseResult, SQLITE_OK)
        XCTAssertEqual(claim.jobID, fixture.enqueue.id)
        XCTAssertEqual(claim.attempt, 1)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testClaimCheckpointAndStaleRecoveryUseExactAttemptAndClaimCAS() throws {
        let databaseURL = makeDatabaseURL("claim-recovery")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 3)
        let firstRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let firstClaimID = UUID()

        let firstClaim = try XCTUnwrap(
            firstRepository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: firstClaimID
            )
        )
        XCTAssertEqual(firstClaim.jobID, fixture.enqueue.id)
        XCTAssertEqual(firstClaim.generation, 3)
        XCTAssertEqual(firstClaim.attempt, 1)
        XCTAssertEqual(firstClaim.claimID, firstClaimID)
        XCTAssertEqual(firstClaim.state, .running)
        XCTAssertNil(firstClaim.proposalCheckpoint)
        XCTAssertNil(
            try firstRepository.claimNext(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )

        let proposal = Data(#"{"category":"category-0","labels":["label-0"]}"#.utf8)
        try firstRepository.checkpointProposal(
            proposal,
            for: firstClaim,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(
            try firstRepository.job(id: fixture.enqueue.id)?.state,
            .proposalReady
        )

        let restartedRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let recoveredClaimID = UUID()
        let recovered = try XCTUnwrap(
            restartedRepository.claimNext(
                now: now.addingTimeInterval(4),
                staleBefore: now.addingTimeInterval(3),
                claimID: recoveredClaimID
            )
        )
        XCTAssertEqual(recovered.state, .proposalReady)
        XCTAssertEqual(recovered.attempt, 2)
        XCTAssertEqual(recovered.claimID, recoveredClaimID)
        XCTAssertEqual(recovered.proposalCheckpoint, proposal)
        XCTAssertEqual(recovered.authorityPayload, fixture.enqueue.authorityPayload)

        XCTAssertThrowsError(
            try restartedRepository.checkpointProposal(
                Data("stale".utf8),
                for: firstClaim,
                now: now.addingTimeInterval(5)
            )
        )
    }

    func testInvalidAuthorityPayloadRollsBackSnapshotJournalAndJob() throws {
        let databaseURL = makeDatabaseURL("authority-rollback")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        let baseline = engine.snapshot()
        try engineRepository.save(baseline)
        let chainID = try engine.createPoolTask(title: "必须整体回滚", now: now)
        let invalid = AutomaticClassificationJobEnqueue(
            chainID: chainID,
            contentDigest: digest("c"),
            classificationFingerprint: digest("d"),
            authorityPayload: Data(repeating: 0x41, count: 65537),
            catalogDigest: digest("e"),
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )

        XCTAssertThrowsError(
            try engineRepository.save(
                engine.snapshot(),
                recordingChangesFor: SyncDeviceID("rollback-mac"),
                changedAt: now,
                enqueuingAutomaticClassificationJobs: [invalid]
            )
        )

        XCTAssertEqual(try engineRepository.load().snapshot(), baseline)
        XCTAssertTrue(try syncRepository.journalEntries().isEmpty)
        XCTAssertTrue(
            try SQLiteAutomaticClassificationJobRepository(databaseURL: databaseURL)
                .jobs()
                .isEmpty
        )
    }

    func testTerminalRetryAndSupersedeTransitionsHonorExactFence() throws {
        let databaseURL = makeDatabaseURL("terminal-cas")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let firstClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )

        try repository.fail(
            firstClaim.fence,
            errorCode: .providerRateLimited,
            now: now.addingTimeInterval(2)
        )
        let failed = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.errorCode, .providerRateLimited)
        XCTAssertEqual(failed.fence, firstClaim.fence)

        try repository.retry(
            failed.fence,
            to: .ready,
            availableAt: now.addingTimeInterval(3),
            now: now.addingTimeInterval(3)
        )
        let retried = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(retried.state, .ready)
        XCTAssertEqual(retried.attempt, 1)
        XCTAssertNil(retried.claimID)
        XCTAssertNil(retried.terminalAt)
        XCTAssertEqual(retried.errorCode, .providerRateLimited)

        let secondClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(4),
                staleBefore: now.addingTimeInterval(3),
                claimID: UUID()
            )
        )
        try repository.checkpointProposal(
            Data("normalized-proposal".utf8),
            for: secondClaim,
            now: now.addingTimeInterval(5)
        )
        XCTAssertThrowsError(
            try repository.supersede(
                firstClaim.fence,
                now: now.addingTimeInterval(6)
            )
        )
        try repository.supersede(
            secondClaim.fence,
            now: now.addingTimeInterval(6)
        )

        let superseded = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertEqual(superseded.errorCode, .contentOrCatalogChanged)
        XCTAssertNil(superseded.proposalCheckpoint)
        XCTAssertEqual(superseded.fence, secondClaim.fence)
    }

    func testRescheduleAtomicallyBacksOffOnlyAnExactRunningClaim() throws {
        let databaseURL = makeDatabaseURL("reschedule-cas")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let claim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )

        XCTAssertThrowsError(
            try repository.reschedule(
                claim.fence,
                errorCode: .providerRateLimited,
                availableAt: now.addingTimeInterval(1),
                now: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(try repository.job(id: fixture.enqueue.id)?.state, .running)

        let retryAt = now.addingTimeInterval(30)
        try repository.reschedule(
            claim.fence,
            errorCode: .providerRateLimited,
            availableAt: retryAt,
            now: now.addingTimeInterval(2)
        )
        let delayed = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(delayed.state, .ready)
        XCTAssertEqual(delayed.attempt, 1)
        XCTAssertNil(delayed.claimID)
        XCTAssertNil(delayed.claimedAt)
        XCTAssertNil(delayed.proposalCheckpoint)
        XCTAssertEqual(delayed.errorCode, .providerRateLimited)
        XCTAssertEqual(delayed.availableAt, retryAt)
        XCTAssertNil(
            try repository.claimNext(
                now: now.addingTimeInterval(29),
                staleBefore: now.addingTimeInterval(28),
                claimID: UUID()
            )
        )
        XCTAssertThrowsError(
            try repository.reschedule(
                claim.fence,
                errorCode: .providerUnavailable,
                availableAt: now.addingTimeInterval(40),
                now: now.addingTimeInterval(3)
            )
        )

        let nextClaim = try XCTUnwrap(
            repository.claimNext(
                now: retryAt,
                staleBefore: now.addingTimeInterval(29),
                claimID: UUID()
            )
        )
        try repository.checkpointProposal(
            Data("do-not-request-provider-again".utf8),
            for: nextClaim,
            now: now.addingTimeInterval(31)
        )
        XCTAssertThrowsError(
            try repository.reschedule(
                nextClaim.fence,
                errorCode: .providerUnavailable,
                availableAt: now.addingTimeInterval(60),
                now: now.addingTimeInterval(32)
            )
        )
        XCTAssertEqual(
            try repository.job(id: fixture.enqueue.id)?.state,
            .proposalReady
        )
    }

    func testCancellationAndManualSupersedeInvalidateExistingWorkers() throws {
        let databaseURL = makeDatabaseURL("cancel-manual")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let cancelChainID = try engine.createPoolTask(title: "取消工作", now: now)
        let manualChainID = try engine.createPoolTask(
            title: "人工分类胜出",
            now: now.addingTimeInterval(1)
        )
        let cancelEnqueue = try makeEnqueue(
            engine: engine,
            chainID: cancelChainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )
        let manualEnqueue = try makeEnqueue(
            engine: engine,
            chainID: manualChainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now.addingTimeInterval(1)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("cancel-manual-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: [cancelEnqueue, manualEnqueue]
        )

        let cancelFence = try XCTUnwrap(repository.job(id: cancelEnqueue.id)).fence
        try repository.cancel(cancelFence, now: now.addingTimeInterval(2))
        XCTAssertEqual(try repository.job(id: cancelEnqueue.id)?.state, .cancelled)
        XCTAssertFalse(
            try XCTUnwrap(repository.job(id: cancelEnqueue.id)).cancelledByUndo
        )

        let manualClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(3),
                staleBefore: now.addingTimeInterval(2),
                claimID: UUID()
            )
        )
        XCTAssertEqual(manualClaim.jobID, manualEnqueue.id)
        XCTAssertEqual(
            try repository.supersedeJobs(
                forChain: manualChainID,
                now: now.addingTimeInterval(4)
            ),
            1
        )
        let manual = try XCTUnwrap(repository.job(id: manualEnqueue.id))
        XCTAssertEqual(manual.state, .superseded)
        XCTAssertEqual(manual.errorCode, .manualClassificationWon)
        XCTAssertThrowsError(
            try repository.fail(
                manualClaim.fence,
                errorCode: .providerUnavailable,
                now: now.addingTimeInterval(5)
            )
        )
    }

    func testManualOverrideOfCompletedJobPreventsUndoRedoReclassification() throws {
        let databaseURL = makeDatabaseURL("completed-manual-override")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let claim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try repository.checkpointProposal(
            Data("completed-before-manual-override".utf8),
            for: claim,
            now: now.addingTimeInterval(2)
        )
        try engineRepository.save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("completed-manual-override-device"),
            changedAt: now.addingTimeInterval(2),
            completingAutomaticClassificationJob: claim,
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            try repository.supersedeJobs(
                forChain: fixture.enqueue.chainID,
                now: now.addingTimeInterval(3)
            ),
            1
        )
        let superseded = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertEqual(superseded.errorCode, .manualClassificationWon)
        XCTAssertEqual(
            try repository.cancelJobs(
                forUndoneChain: fixture.enqueue.chainID,
                now: now.addingTimeInterval(4)
            ),
            0
        )
        XCTAssertEqual(try repository.job(id: fixture.enqueue.id)?.state, .superseded)
    }

    func testProviderConfigurationTransitionsOnlyProviderDependentStates() throws {
        let databaseURL = makeDatabaseURL("provider-configuration")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainIDs = try (0 ..< 4).map { index in
            try engine.createPoolTask(
                title: "配置状态 \(index)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let enqueues = try chainIDs.enumerated().map { index, chainID in
            try makeEnqueue(
                engine: engine,
                chainID: chainID,
                generation: 1,
                initialState: index == 3 ? .waitingForConfiguration : .ready,
                availableAt: now,
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("provider-configuration-device"),
            changedAt: now.addingTimeInterval(4),
            enqueuingAutomaticClassificationJobs: enqueues
        )

        let proposalClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(5),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try repository.checkpointProposal(
            Data("provider-already-returned".utf8),
            for: proposalClaim,
            now: now.addingTimeInterval(6)
        )
        let runningClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(7),
                staleBefore: now,
                claimID: UUID()
            )
        )
        XCTAssertEqual(runningClaim.jobID, enqueues[1].id)

        XCTAssertEqual(
            try repository.makeProviderDependentJobsWaitForConfiguration(
                now: now.addingTimeInterval(8)
            ),
            2
        )
        let proposalReady = try XCTUnwrap(repository.job(id: enqueues[0].id))
        XCTAssertEqual(proposalReady.state, .proposalReady)
        XCTAssertEqual(proposalReady.proposalCheckpoint, Data("provider-already-returned".utf8))
        XCTAssertEqual(proposalReady.claimID, proposalClaim.claimID)
        let invalidatedRunning = try XCTUnwrap(repository.job(id: enqueues[1].id))
        XCTAssertEqual(invalidatedRunning.state, .waitingForConfiguration)
        XCTAssertNil(invalidatedRunning.claimID)
        XCTAssertEqual(invalidatedRunning.errorCode, .configurationUnavailable)
        XCTAssertEqual(
            try repository.job(id: enqueues[2].id)?.state,
            .waitingForConfiguration
        )
        let originallyWaiting = try XCTUnwrap(repository.job(id: enqueues[3].id))
        XCTAssertEqual(originallyWaiting.state, .waitingForConfiguration)
        XCTAssertNil(originallyWaiting.errorCode)
        XCTAssertThrowsError(
            try repository.fail(
                runningClaim.fence,
                errorCode: .providerUnavailable,
                now: now.addingTimeInterval(9)
            )
        )

        XCTAssertEqual(
            try repository.makeWaitingForConfigurationJobsReady(
                now: now.addingTimeInterval(10)
            ),
            2
        )
        XCTAssertEqual(
            try repository.jobs(states: [.ready]).map(\.id),
            [enqueues[1].id, enqueues[2].id]
        )
        XCTAssertEqual(originallyWaiting.dispatchAuthorization, .pendingUserDecision)
        XCTAssertEqual(
            try repository.job(id: enqueues[3].id)?.state,
            .waitingForConfiguration
        )
        XCTAssertEqual(
            try repository.job(id: enqueues[0].id)?.state,
            .proposalReady
        )
        XCTAssertTrue(
            try repository.jobs(states: [.ready]).allSatisfy {
                $0.claimID == nil && $0.errorCode == nil
            }
        )
    }

    func testUnconfiguredCircuitWakesForFreshProposalCheckpointLease() throws {
        let databaseURL = makeDatabaseURL("unconfigured-proposal-wake")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now
        )
        let firstClaim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let checkpoint = Data("provider-result-before-unconfigure".utf8)
        try repository.resolveProviderAttempt(
            .checkpoint(checkpoint),
            for: firstClaim,
            now: now.addingTimeInterval(2)
        )
        _ = try repository.reconcileProviderExecution(
            .unconfigured,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(
            try repository.nextDispatch(
                now: now.addingTimeInterval(5),
                staleBefore: now,
                claimID: UUID()
            ),
            .idle(nextWakeAt: now.addingTimeInterval(6))
        )
        let recovered = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(6),
                staleBefore: now.addingTimeInterval(1),
                claimID: UUID()
            )
        )
        XCTAssertEqual(recovered.jobID, fixture.enqueue.id)
        XCTAssertEqual(recovered.state, .proposalReady)
        XCTAssertEqual(recovered.attempt, 2)
        XCTAssertEqual(recovered.proposalCheckpoint, checkpoint)
        XCTAssertEqual(try repository.providerCircuit()?.state, .unconfigured)
    }

    func testContentOrCatalogReplacementIsAtomicAndKeepsClassificationFence() throws {
        let databaseURL = makeDatabaseURL("replacement")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let claim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )

        XCTAssertThrowsError(
            try repository.replace(
                claim.fence,
                with: fixture.enqueue,
                now: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(try repository.job(id: fixture.enqueue.id)?.state, .running)

        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "内容改变后重新建立 authority",
            now: now.addingTimeInterval(3)
        )
        let replacement = try makeEnqueue(
            engine: fixture.engine,
            chainID: fixture.enqueue.chainID,
            generation: 2,
            initialState: .ready,
            availableAt: now.addingTimeInterval(3),
            createdAt: now.addingTimeInterval(3)
        )
        XCTAssertEqual(
            replacement.classificationFingerprint,
            fixture.enqueue.classificationFingerprint
        )
        XCTAssertNotEqual(replacement.contentDigest, fixture.enqueue.contentDigest)

        try repository.replace(
            claim.fence,
            with: replacement,
            now: now.addingTimeInterval(4)
        )
        let old = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(old.state, .superseded)
        XCTAssertEqual(old.errorCode, .contentOrCatalogChanged)
        let new = try XCTUnwrap(repository.job(id: replacement.id))
        XCTAssertEqual(new.state, .ready)
        XCTAssertEqual(new.generation, 2)
        XCTAssertEqual(new.authorityPayload, replacement.authorityPayload)
        XCTAssertThrowsError(
            try repository.cancel(claim.fence, now: now.addingTimeInterval(5))
        )

        let replacementClaim = try XCTUnwrap(
            repository.claimNext(
                now: now.addingTimeInterval(5),
                staleBefore: now.addingTimeInterval(4),
                claimID: UUID()
            )
        )
        XCTAssertEqual(replacementClaim.jobID, replacement.id)
        let catalogChainID = try fixture.engine.createPoolTask(
            title: "仅改变 active catalog",
            now: now.addingTimeInterval(6)
        )
        let catalogPlan = try fixture.engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: catalogChainID,
                    category: .new(name: "新增目录项", colorHex: "#2A6FDB"),
                    labels: [.new(name: "新增目录标签", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: now.addingTimeInterval(6)
        )
        _ = try fixture.engine.commitClassification(
            catalogPlan,
            confirmation: .user(decisionID: UUID()),
            now: now.addingTimeInterval(6)
        )
        let catalogReplacement = try makeEnqueue(
            engine: fixture.engine,
            chainID: fixture.enqueue.chainID,
            generation: 3,
            initialState: .ready,
            availableAt: now.addingTimeInterval(7),
            createdAt: now.addingTimeInterval(7)
        )
        XCTAssertEqual(catalogReplacement.contentDigest, replacement.contentDigest)
        XCTAssertEqual(
            catalogReplacement.classificationFingerprint,
            replacement.classificationFingerprint
        )
        XCTAssertNotEqual(catalogReplacement.catalogDigest, replacement.catalogDigest)
        try repository.replace(
            replacementClaim.fence,
            with: catalogReplacement,
            now: now.addingTimeInterval(8)
        )
        XCTAssertEqual(try repository.job(id: replacement.id)?.state, .superseded)
        XCTAssertEqual(try repository.job(id: catalogReplacement.id)?.state, .ready)
    }

    func testWaitingJobTaskContentAndJournalRefreshCommitAtomically() throws {
        let databaseURL = makeDatabaseURL("atomic-waiting-content-refresh")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedWaitingJob(at: databaseURL, generation: 1)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let source = try XCTUnwrap(jobRepository.job(id: fixture.enqueue.id))
        let journalCountBefore = try syncRepository.journalEntries().count

        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "等待配置期间改写后的任务",
            descriptionText: "新定义必须产生新的 Provider context。",
            now: now.addingTimeInterval(1)
        )
        let replacement = try makeEnqueue(
            engine: fixture.engine,
            chainID: fixture.enqueue.chainID,
            generation: 2,
            initialState: .waitingForConfiguration,
            availableAt: now.addingTimeInterval(2),
            createdAt: now.addingTimeInterval(2)
        )

        try engineRepository.save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("waiting-content-refresh-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: [],
            applyingAutomaticClassificationJobMutations: [
                .replace(source.fence, with: replacement)
            ],
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(try engineRepository.load().snapshot(), fixture.engine.snapshot())
        XCTAssertGreaterThan(try syncRepository.journalEntries().count, journalCountBefore)
        let superseded = try XCTUnwrap(jobRepository.job(id: source.id))
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertEqual(superseded.errorCode, .contentOrCatalogChanged)
        let refreshed = try XCTUnwrap(jobRepository.job(id: replacement.id))
        XCTAssertEqual(refreshed.state, .waitingForConfiguration)
        XCTAssertEqual(refreshed.generation, 2)
        XCTAssertEqual(refreshed.dispatchAuthorization, .pendingUserDecision)
        XCTAssertNotEqual(refreshed.contentDigest, source.contentDigest)
        XCTAssertEqual(
            try AutomaticClassificationAuthorityPayload.decode(
                refreshed.authorityPayload
            ),
            try AutomaticClassificationAuthorityPayload.decode(
                replacement.authorityPayload
            )
        )
    }

    func testFailedJobContentChangePlansFreshAutomaticGenerationWithoutRetry() throws {
        let databaseURL = makeDatabaseURL("failed-content-refresh-plan")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try jobRepository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(0.5)
        )
        let claim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try jobRepository.resolveProviderAttempt(
            .invalidResponse,
            for: claim,
            now: now.addingTimeInterval(2)
        )
        let failed = try XCTUnwrap(jobRepository.job(id: fixture.enqueue.id))
        XCTAssertEqual(failed.state, .failed)

        let originalSnapshot = fixture.engine.snapshot()
        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "修正后应自动再归类",
            descriptionText: "内容修正本身就是新的可执行尝试。",
            now: now.addingTimeInterval(3)
        )
        let plan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .reconcileExisting,
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(4)
        )

        XCTAssertTrue(plan.enqueues.isEmpty)
        guard case let .replace(sourceFence, replacement) = plan.mutations.first,
              plan.mutations.count == 1
        else {
            return XCTFail("failed content change did not plan one replacement")
        }
        XCTAssertEqual(sourceFence, failed.fence)
        XCTAssertEqual(replacement.chainID, failed.chainID)
        XCTAssertEqual(replacement.generation, 2)
        XCTAssertEqual(replacement.initialState, .ready)
        XCTAssertEqual(replacement.dispatchAuthorization, .automatic)
        XCTAssertEqual(
            replacement.classificationFingerprint,
            failed.classificationFingerprint
        )
        XCTAssertNotEqual(replacement.contentDigest, failed.contentDigest)

        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("failed-content-refresh-device"),
            changedAt: now.addingTimeInterval(3),
            enqueuingAutomaticClassificationJobs: plan.enqueues,
            applyingAutomaticClassificationJobMutations: plan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(4)
        )
        XCTAssertEqual(
            try jobRepository.job(id: failed.id)?.state,
            .superseded
        )
        let refreshed = try XCTUnwrap(jobRepository.job(id: replacement.id))
        XCTAssertEqual(refreshed.state, .ready)
        let automaticClaim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(5),
                staleBefore: now.addingTimeInterval(4),
                claimID: UUID()
            )
        )
        XCTAssertEqual(automaticClaim.jobID, replacement.id)
    }

    func testActiveCatalogChangePlansAndAtomicallyReplacesEveryReadyJob() throws {
        let databaseURL = makeDatabaseURL("active-catalog-refresh")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 2)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let originalSnapshot = fixture.engine.snapshot()
        let catalogOwner = try fixture.engine.createPoolTask(
            title: "建立新的有效目录内容",
            now: now.addingTimeInterval(1)
        )
        let catalogPlan = try fixture.engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: catalogOwner,
                    category: .new(name: "新增有效分组", colorHex: "#2A6FDB"),
                    labels: [.new(name: "新增有效标签", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: now.addingTimeInterval(1)
        )
        _ = try fixture.engine.commitClassification(
            catalogPlan,
            confirmation: .user(decisionID: UUID()),
            now: now.addingTimeInterval(1)
        )

        let mutationPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .reconcileExisting,
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(2)
        )
        XCTAssertTrue(mutationPlan.enqueues.isEmpty)
        XCTAssertEqual(mutationPlan.mutations.count, 2)
        var sourceIDs: Set<UUID> = []
        var replacements: [AutomaticClassificationJobEnqueue] = []
        for mutation in mutationPlan.mutations {
            guard case let .replace(sourceFence, replacement) = mutation else {
                return XCTFail("catalog change superseded an unchanged task baseline")
            }
            sourceIDs.insert(sourceFence.jobID)
            replacements.append(replacement)
            XCTAssertEqual(replacement.generation, 2)
            XCTAssertEqual(replacement.initialState, .ready)
        }
        XCTAssertEqual(sourceIDs, Set(fixture.enqueues.map(\.id)))
        XCTAssertTrue(replacements.allSatisfy { replacement in
            fixture.enqueues.contains { source in
                source.chainID == replacement.chainID
                    && source.catalogDigest != replacement.catalogDigest
                    && source.classificationFingerprint
                    == replacement.classificationFingerprint
            }
        })

        try engineRepository.save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("active-catalog-refresh-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: mutationPlan.enqueues,
            applyingAutomaticClassificationJobMutations: mutationPlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )
        for source in fixture.enqueues {
            XCTAssertEqual(try jobRepository.job(id: source.id)?.state, .superseded)
        }
        for replacement in replacements {
            XCTAssertEqual(try jobRepository.job(id: replacement.id)?.state, .ready)
        }
    }

    func testDefinitionEditPolicyRefreshesOnlyTheEditedTask() throws {
        let databaseURL = makeDatabaseURL("scoped-definition-refresh")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 2)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let originalSnapshot = fixture.engine.snapshot()
        let editedChainID = fixture.enqueues[0].chainID
        let unrelatedChainID = fixture.enqueues[1].chainID
        try fixture.engine.updatePoolTask(
            chainID: editedChainID,
            title: "用户这次实际编辑的任务",
            now: now.addingTimeInterval(1)
        )
        try fixture.engine.updatePoolTask(
            chainID: unrelatedChainID,
            title: "模拟先前已失效但不属于本次 mutation 的任务",
            now: now.addingTimeInterval(1)
        )

        let mutationPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskDefinitionChanged(editedChainID),
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(2)
        )
        guard case let .replace(sourceFence, replacement) = mutationPlan.mutations.first,
              mutationPlan.mutations.count == 1
        else {
            return XCTFail("definition edit was not scoped to one replacement")
        }
        XCTAssertEqual(sourceFence.jobID, fixture.enqueues[0].id)
        XCTAssertEqual(replacement.chainID, editedChainID)
        XCTAssertFalse(mutationPlan.mutations.contains {
            if case let .replace(_, candidate) = $0 {
                candidate.chainID == unrelatedChainID
            } else {
                false
            }
        })
    }

    func testUserClassificationBaselineChangePlansSupersedeNotReplacement() throws {
        let databaseURL = makeDatabaseURL("user-baseline-wins-plan")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedWaitingJob(at: databaseURL, generation: 1)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let originalSnapshot = fixture.engine.snapshot()
        let userPlan = try fixture.engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: fixture.enqueue.chainID,
                    category: .new(name: "人工决定分组", colorHex: "#2A6FDB"),
                    labels: [.new(name: "人工决定标签", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: now.addingTimeInterval(1)
        )
        _ = try fixture.engine.commitClassification(
            userPlan,
            confirmation: .user(decisionID: UUID()),
            now: now.addingTimeInterval(1)
        )

        let mutationPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .reconcileExisting,
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: false,
            operationalNow: now.addingTimeInterval(2)
        )
        XCTAssertTrue(mutationPlan.enqueues.isEmpty)
        XCTAssertEqual(
            mutationPlan.mutations,
            [.supersedeChain(fixture.enqueue.chainID)]
        )
        try engineRepository.save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("user-baseline-wins-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: mutationPlan.enqueues,
            applyingAutomaticClassificationJobMutations: mutationPlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )
        let userWon = try XCTUnwrap(
            jobRepository.job(id: fixture.enqueue.id)
        )
        XCTAssertEqual(userWon.state, .superseded)
        XCTAssertEqual(userWon.errorCode, .manualClassificationWon)
        let eligibilityPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameEligible(fixture.enqueue.chainID),
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(3)
        )
        XCTAssertTrue(eligibilityPlan.isEmpty)
    }

    func testTaskAndJournalRollBackWhenAtomicJobReplacementFenceFails() throws {
        let databaseURL = makeDatabaseURL("content-refresh-rollback")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedWaitingJob(at: databaseURL, generation: 1)
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let persistedBefore = try engineRepository.load().snapshot()
        let journalBefore = try syncRepository.journalEntries()
        let source = try XCTUnwrap(jobRepository.job(id: fixture.enqueue.id))
        let originalSnapshot = fixture.engine.snapshot()
        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "事务必须整体回滚",
            now: now.addingTimeInterval(1)
        )
        let validPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .reconcileExisting,
            candidate: fixture.engine,
            originalSnapshot: originalSnapshot,
            existingJobs: [source],
            providerIsReady: false,
            operationalNow: now.addingTimeInterval(2)
        )
        guard case let .replace(_, replacement) = validPlan.mutations.first else {
            return XCTFail("content change did not create a replacement plan")
        }
        let staleFence = AutomaticClassificationJobFence(
            jobID: source.id,
            generation: source.generation,
            attempt: source.attempt + 1,
            claimID: source.claimID
        )

        XCTAssertThrowsError(
            try engineRepository.save(
                fixture.engine.snapshot(),
                recordingChangesFor: SyncDeviceID("content-refresh-rollback-device"),
                changedAt: now.addingTimeInterval(1),
                enqueuingAutomaticClassificationJobs: [],
                applyingAutomaticClassificationJobMutations: [
                    .replace(staleFence, with: replacement)
                ],
                automaticClassificationTransitionAt: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), persistedBefore)
        XCTAssertEqual(try syncRepository.journalEntries(), journalBefore)
        XCTAssertEqual(try jobRepository.job(id: source.id), source)
        XCTAssertNil(try jobRepository.job(id: replacement.id))
    }

    func testChangedTraceAtomicallyTerminatesOldWorkWithoutQueuingInheritedChain() throws {
        let databaseURL = makeDatabaseURL("changed-trace-terminates-work")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let today = LocalDate("2026-07-20")
        let sourceChainID = try engine.createPoolTask(
            title: "旧承诺不应在变更后重新归类",
            now: now
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: now
        )
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: sourceChainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("changed-trace-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )

        let originalSnapshot = engine.snapshot()
        let replacementTraceID = try engine.changeTrace(
            traceID: sourceTraceID,
            newTitle: "继承的新承诺不属于自动捕获入口",
            today: today,
            now: now.addingTimeInterval(1)
        )
        let replacementChainID = try XCTUnwrap(
            engine.traces[replacementTraceID]?.chainID
        )
        XCTAssertNotEqual(replacementChainID, sourceChainID)
        let mutationPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameIneligible(sourceChainID),
            candidate: engine,
            originalSnapshot: originalSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(2)
        )
        XCTAssertTrue(mutationPlan.enqueues.isEmpty)
        XCTAssertEqual(
            mutationPlan.mutations,
            [.invalidateChain(sourceChainID)]
        )

        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("changed-trace-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: mutationPlan.enqueues,
            applyingAutomaticClassificationJobMutations: mutationPlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )
        let terminated = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(terminated.state, .superseded)
        XCTAssertEqual(terminated.errorCode, .taskBecameIneligible)
        let persistedJobs = try jobRepository.jobs()
        XCTAssertEqual(persistedJobs.map(\.chainID), [sourceChainID])
        XCTAssertFalse(persistedJobs.contains {
            $0.chainID == replacementChainID
        })
    }

    func testAbandonUndoAtomicallyRestoresOnlyTheIneligibleJob() throws {
        let databaseURL = makeDatabaseURL("abandon-undo-restores-ineligible")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let today = LocalDate("2026-07-20")
        let chainID = try engine.createPoolTask(
            title: "撤销放弃后继续原有自动归类",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let activeSnapshot = engine.snapshot()
        let authorizationID = UUID()
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            dispatchAuthorization: .explicit,
            authorizationID: authorizationID,
            authorizedAt: now.addingTimeInterval(1),
            availableAt: now.addingTimeInterval(1),
            createdAt: now.addingTimeInterval(1)
        )
        try engineRepository.save(
            activeSnapshot,
            recordingChangesFor: SyncDeviceID("abandon-undo-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: [enqueue]
        )

        try engine.abandonChain(from: traceID, now: now.addingTimeInterval(2))
        let abandonedSnapshot = engine.snapshot()
        let abandonPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameIneligible(chainID),
            candidate: engine,
            originalSnapshot: activeSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(3)
        )
        try engineRepository.save(
            abandonedSnapshot,
            recordingChangesFor: SyncDeviceID("abandon-undo-device"),
            changedAt: now.addingTimeInterval(2),
            enqueuingAutomaticClassificationJobs: abandonPlan.enqueues,
            applyingAutomaticClassificationJobMutations: abandonPlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(3)
        )
        let ineligible = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(ineligible.state, .superseded)
        XCTAssertEqual(ineligible.errorCode, .taskBecameIneligible)

        let undoCandidate = try NoonmarkEngine(snapshot: activeSnapshot)
        let undoOutcome = try undoCandidate.prepareSnapshotUndo(
            replacing: abandonedSnapshot,
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(
            undoOutcome.automaticClassificationRestoredChainIDs,
            [chainID]
        )
        let restorePlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameEligible(chainID),
            candidate: undoCandidate,
            originalSnapshot: abandonedSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(5)
        )
        guard case let .restoreEligibility(sourceFence, replacement) =
            restorePlan.mutations.first,
            restorePlan.mutations.count == 1
        else {
            return XCTFail("undo did not plan one fenced eligibility restoration")
        }
        XCTAssertEqual(sourceFence, ineligible.fence)
        XCTAssertEqual(replacement.generation, 2)

        try engineRepository.save(
            undoCandidate.snapshot(),
            recordingChangesFor: SyncDeviceID("abandon-undo-device"),
            changedAt: now.addingTimeInterval(4),
            enqueuingAutomaticClassificationJobs: restorePlan.enqueues,
            applyingAutomaticClassificationJobMutations: restorePlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(5)
        )
        XCTAssertEqual(try jobRepository.job(id: enqueue.id), ineligible)
        let restored = try XCTUnwrap(jobRepository.job(id: replacement.id))
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.generation, 2)
        XCTAssertEqual(restored.dispatchAuthorization, .explicit)
        XCTAssertEqual(restored.authorizationID, authorizationID)
        XCTAssertEqual(restored.authorizedAt, now.addingTimeInterval(1))

        let firstUndoSnapshot = undoCandidate.snapshot()
        let redoCandidate = try NoonmarkEngine(snapshot: abandonedSnapshot)
        let redoOutcome = try redoCandidate.prepareSnapshotUndo(
            replacing: firstUndoSnapshot,
            now: now.addingTimeInterval(6)
        )
        XCTAssertEqual(
            redoOutcome.automaticClassificationCancelledChainIDs,
            [chainID]
        )
        try engineRepository.save(
            redoCandidate.snapshot(),
            recordingChangesFor: SyncDeviceID("abandon-undo-device"),
            changedAt: now.addingTimeInterval(6),
            enqueuingAutomaticClassificationJobs: [],
            applyingAutomaticClassificationJobMutations: [
                .invalidateChain(chainID)
            ],
            automaticClassificationTransitionAt: now.addingTimeInterval(7)
        )
        let reinvalidated = try XCTUnwrap(
            jobRepository.job(id: replacement.id)
        )
        XCTAssertEqual(reinvalidated.state, .superseded)
        XCTAssertEqual(reinvalidated.errorCode, .taskBecameIneligible)

        let secondUndoCandidate = try NoonmarkEngine(snapshot: firstUndoSnapshot)
        let secondUndoOutcome = try secondUndoCandidate.prepareSnapshotUndo(
            replacing: redoCandidate.snapshot(),
            now: now.addingTimeInterval(8)
        )
        XCTAssertEqual(
            secondUndoOutcome.automaticClassificationRestoredChainIDs,
            [chainID]
        )
        let secondRestorePlan = try AutomaticClassificationJobMutationPlanner()
            .plan(
                policy: .taskBecameEligible(chainID),
                candidate: secondUndoCandidate,
                originalSnapshot: redoCandidate.snapshot(),
                existingJobs: jobRepository.jobs(),
                providerIsReady: true,
                operationalNow: now.addingTimeInterval(9)
            )
        guard case let .restoreEligibility(secondFence, secondReplacement) =
            secondRestorePlan.mutations.first
        else {
            return XCTFail("second undo did not restore the next generation")
        }
        XCTAssertEqual(secondFence, reinvalidated.fence)
        XCTAssertEqual(secondReplacement.generation, 3)
        try engineRepository.save(
            secondUndoCandidate.snapshot(),
            recordingChangesFor: SyncDeviceID("abandon-undo-device"),
            changedAt: now.addingTimeInterval(8),
            enqueuingAutomaticClassificationJobs: secondRestorePlan.enqueues,
            applyingAutomaticClassificationJobMutations:
            secondRestorePlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(9)
        )
        let secondRestored = try XCTUnwrap(
            jobRepository.job(id: secondReplacement.id)
        )
        XCTAssertEqual(secondRestored.generation, 3)
        XCTAssertEqual(secondRestored.state, .ready)
        XCTAssertEqual(secondRestored.dispatchAuthorization, .explicit)
        XCTAssertEqual(secondRestored.authorizationID, authorizationID)
    }

    func testExplicitReactivateRestorationFenceFailureRollsBackEverything() throws {
        let databaseURL = makeDatabaseURL("reactivate-restoration-rollback")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let today = LocalDate("2026-07-20")
        let chainID = try engine.createPoolTask(
            title: "重新启用后恢复等待授权的归类",
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let activeSnapshot = engine.snapshot()
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .waitingForConfiguration,
            availableAt: now.addingTimeInterval(1),
            createdAt: now.addingTimeInterval(1)
        )
        try engineRepository.save(
            activeSnapshot,
            recordingChangesFor: SyncDeviceID("reactivate-rollback-device"),
            changedAt: now.addingTimeInterval(1),
            enqueuingAutomaticClassificationJobs: [enqueue]
        )
        try engine.abandonChain(from: traceID, now: now.addingTimeInterval(2))
        let abandonPlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameIneligible(chainID),
            candidate: engine,
            originalSnapshot: activeSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: false,
            operationalNow: now.addingTimeInterval(3)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("reactivate-rollback-device"),
            changedAt: now.addingTimeInterval(2),
            enqueuingAutomaticClassificationJobs: abandonPlan.enqueues,
            applyingAutomaticClassificationJobMutations: abandonPlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(3)
        )
        let ineligible = try XCTUnwrap(jobRepository.job(id: enqueue.id))

        _ = try engine.reactivateAbandonedChain(
            from: traceID,
            today: today,
            now: now.addingTimeInterval(4)
        )
        let restorePlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameEligible(chainID),
            candidate: engine,
            originalSnapshot: activeSnapshot,
            existingJobs: jobRepository.jobs(),
            providerIsReady: false,
            operationalNow: now.addingTimeInterval(5)
        )
        guard case let .restoreEligibility(_, replacement) =
            restorePlan.mutations.first
        else {
            return XCTFail("reactivation did not plan eligibility restoration")
        }
        let persistedBefore = try engineRepository.load().snapshot()
        let journalBefore = try syncRepository.journalEntries()
        let staleFence = AutomaticClassificationJobFence(
            jobID: ineligible.id,
            generation: ineligible.generation,
            attempt: ineligible.attempt + 1,
            claimID: ineligible.claimID
        )
        XCTAssertThrowsError(
            try engineRepository.save(
                engine.snapshot(),
                recordingChangesFor: SyncDeviceID("reactivate-rollback-device"),
                changedAt: now.addingTimeInterval(4),
                enqueuingAutomaticClassificationJobs: [],
                applyingAutomaticClassificationJobMutations: [
                    .restoreEligibility(staleFence, with: replacement)
                ],
                automaticClassificationTransitionAt: now.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), persistedBefore)
        XCTAssertEqual(try syncRepository.journalEntries(), journalBefore)
        XCTAssertEqual(try jobRepository.job(id: enqueue.id), ineligible)
        XCTAssertNil(try jobRepository.job(id: replacement.id))

        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("reactivate-rollback-device"),
            changedAt: now.addingTimeInterval(4),
            enqueuingAutomaticClassificationJobs: restorePlan.enqueues,
            applyingAutomaticClassificationJobMutations: restorePlan.mutations,
            automaticClassificationTransitionAt: now.addingTimeInterval(5)
        )
        let restored = try XCTUnwrap(jobRepository.job(id: replacement.id))
        XCTAssertEqual(restored.state, .waitingForConfiguration)
        XCTAssertEqual(restored.dispatchAuthorization, .pendingUserDecision)
        XCTAssertNil(restored.authorizationID)
        XCTAssertNil(restored.authorizedAt)
    }

    func testIneligibleMutationDoesNotRewriteCompletedJobHistory() throws {
        let databaseURL = makeDatabaseURL("ineligible-preserves-completed-history")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainID = try engine.createPoolTask(
            title: "已经成功自动归类的任务",
            now: now
        )
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("completed-history-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )
        _ = try jobRepository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        let claim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try jobRepository.checkpointProposal(
            Data("completed-history-proposal".utf8),
            for: claim,
            now: now.addingTimeInterval(3)
        )
        let authority = try AutomaticClassificationAuthorityPayload.decode(
            enqueue.authorityPayload
        )
        let classificationPlan = try engine.prepareAutomaticClassification(
            AutomaticClassificationApplicationProposal(
                category: .new(name: "已完成自动分组", colorHex: "#2A6FDB"),
                labels: [.new(name: "已完成自动标签", colorHex: "#0E9488")]
            ),
            authority: authority,
            interactionID: UUID(),
            now: now.addingTimeInterval(4)
        )
        _ = try engine.commitAutomaticClassification(
            classificationPlan,
            authority: authority,
            now: now.addingTimeInterval(4)
        )
        let proposalReadyClaim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(4),
                staleBefore: now.addingTimeInterval(3),
                claimID: UUID()
            )
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("completed-history-device"),
            changedAt: now.addingTimeInterval(4),
            completingAutomaticClassificationJob: proposalReadyClaim,
            automaticClassificationTransitionAt: now.addingTimeInterval(4)
        )
        let completed = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(completed.state, .completed)

        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("completed-history-device"),
            changedAt: now.addingTimeInterval(5),
            enqueuingAutomaticClassificationJobs: [],
            applyingAutomaticClassificationJobMutations: [
                .invalidateChain(chainID)
            ],
            automaticClassificationTransitionAt: now.addingTimeInterval(5)
        )
        XCTAssertEqual(try jobRepository.job(id: enqueue.id), completed)
        let restorePlan = try AutomaticClassificationJobMutationPlanner().plan(
            policy: .taskBecameEligible(chainID),
            candidate: engine,
            originalSnapshot: engine.snapshot(),
            existingJobs: jobRepository.jobs(),
            providerIsReady: true,
            operationalNow: now.addingTimeInterval(6)
        )
        XCTAssertTrue(restorePlan.isEmpty)
    }

    func testFinalSnapshotJournalAndCompletionUseOneFullClaimCAS() throws {
        let databaseURL = makeDatabaseURL("atomic-completion")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainID = try engine.createPoolTask(title: "原子发布归类", now: now)
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("atomic-completion-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )
        let beforeClassification = try engineRepository.load().snapshot()
        let journalCountBeforeCompletion = try syncRepository.journalEntries().count
        let firstClaim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let proposalPayload = Data("normalized-typed-proposal".utf8)
        try jobRepository.checkpointProposal(
            proposalPayload,
            for: firstClaim,
            now: now.addingTimeInterval(2)
        )
        let recoveredClaim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(4),
                staleBefore: now.addingTimeInterval(3),
                claimID: UUID()
            )
        )
        XCTAssertEqual(recoveredClaim.proposalCheckpoint, proposalPayload)

        let authority = try AutomaticClassificationAuthorityPayload.decode(
            enqueue.authorityPayload
        )
        let plan = try engine.prepareAutomaticClassification(
            AutomaticClassificationApplicationProposal(
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "自动", colorHex: "#0E9488")]
            ),
            authority: authority,
            interactionID: UUID(),
            now: now.addingTimeInterval(5)
        )
        _ = try engine.commitAutomaticClassification(
            plan,
            authority: authority,
            now: now.addingTimeInterval(5)
        )

        XCTAssertThrowsError(
            try engineRepository.save(
                engine.snapshot(),
                recordingChangesFor: SyncDeviceID("atomic-completion-device"),
                changedAt: now.addingTimeInterval(5),
                completingAutomaticClassificationJob: firstClaim,
                automaticClassificationTransitionAt: now.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), beforeClassification)
        XCTAssertEqual(
            try syncRepository.journalEntries().count,
            journalCountBeforeCompletion
        )
        XCTAssertEqual(
            try jobRepository.job(id: enqueue.id)?.claimID,
            recoveredClaim.claimID
        )

        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("atomic-completion-device"),
            changedAt: now.addingTimeInterval(6),
            completingAutomaticClassificationJob: recoveredClaim,
            automaticClassificationTransitionAt: now.addingTimeInterval(6)
        )
        XCTAssertEqual(try engineRepository.load().snapshot(), engine.snapshot())
        let completed = try XCTUnwrap(jobRepository.job(id: enqueue.id))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.fence, recoveredClaim.fence)
        XCTAssertNil(completed.proposalCheckpoint)
        XCTAssertNotNil(completed.terminalAt)
        XCTAssertGreaterThan(
            try syncRepository.journalEntries().count,
            journalCountBeforeCompletion
        )
        let current = try XCTUnwrap(
            engine.snapshot().classifications.currentByChainID[chainID]
        )
        XCTAssertEqual(
            current.category?.source,
            .automaticAI(jobID: enqueue.id, generation: 1)
        )
    }

    func testManualClassificationSnapshotJournalAndSupersedeCommitAtomically() throws {
        let databaseURL = makeDatabaseURL("atomic-manual-supersede")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let persistedBefore = try SQLiteEngineRepository(databaseURL: databaseURL)
            .load()
            .snapshot()
        let journalCountBefore = try syncRepository.journalEntries().count

        let plan = try fixture.engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: fixture.enqueue.chainID,
                    category: .new(name: "人工分组", colorHex: "#2A6FDB"),
                    labels: [.new(name: "人工标签", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: now.addingTimeInterval(1)
        )
        _ = try fixture.engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: now.addingTimeInterval(1)
        )
        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "人工分类同时修改标题",
            now: now.addingTimeInterval(1.5)
        )

        let collidingJournalID = UUID()
        let failingRepository = SQLiteEngineRepository(
            databaseURL: databaseURL,
            journalEntryIDGenerator: { collidingJournalID }
        )
        XCTAssertThrowsError(
            try failingRepository.save(
                fixture.engine.snapshot(),
                recordingChangesFor: SyncDeviceID("manual-supersede-device"),
                changedAt: now.addingTimeInterval(2),
                supersedingAutomaticClassificationJobsForChain: fixture.enqueue.chainID,
                automaticClassificationTransitionAt: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot(),
            persistedBefore
        )
        XCTAssertEqual(try syncRepository.journalEntries().count, journalCountBefore)
        XCTAssertEqual(try jobRepository.job(id: fixture.enqueue.id)?.state, .ready)

        try SQLiteEngineRepository(databaseURL: databaseURL).save(
            fixture.engine.snapshot(),
            recordingChangesFor: SyncDeviceID("manual-supersede-device"),
            changedAt: now.addingTimeInterval(3),
            supersedingAutomaticClassificationJobsForChain: fixture.enqueue.chainID,
            automaticClassificationTransitionAt: now.addingTimeInterval(3)
        )
        XCTAssertEqual(
            try SQLiteEngineRepository(databaseURL: databaseURL).load().snapshot(),
            fixture.engine.snapshot()
        )
        let superseded = try XCTUnwrap(jobRepository.job(id: fixture.enqueue.id))
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertEqual(superseded.errorCode, .manualClassificationWon)
        XCTAssertGreaterThan(try syncRepository.journalEntries().count, journalCountBefore)
    }

    func testUndoCancelsCompletedJobAndRedoAtomicallyQueuesOnlyThatCancellation() throws {
        let databaseURL = makeDatabaseURL("undo-redo")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let beforeCreation = NoonmarkEngine().snapshot()
        let created = NoonmarkEngine()
        try engineRepository.save(beforeCreation)
        let chainID = try created.createPoolTask(title: "撤销后重做", now: now)
        let redoAuthorizationID = UUID()
        let first = try makeEnqueue(
            engine: created,
            chainID: chainID,
            generation: 1,
            initialState: .ready,
            dispatchAuthorization: .explicit,
            authorizationID: redoAuthorizationID,
            authorizedAt: now,
            availableAt: now,
            createdAt: now
        )
        let afterCreation = created.snapshot()
        try engineRepository.save(
            afterCreation,
            recordingChangesFor: SyncDeviceID("undo-redo-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [first]
        )
        let claim = try XCTUnwrap(
            jobRepository.claimNext(
                now: now.addingTimeInterval(1),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try jobRepository.checkpointProposal(
            Data("proposal-before-undo".utf8),
            for: claim,
            now: now.addingTimeInterval(2)
        )
        try engineRepository.save(
            afterCreation,
            recordingChangesFor: SyncDeviceID("undo-redo-device"),
            changedAt: now.addingTimeInterval(2),
            completingAutomaticClassificationJob: claim,
            automaticClassificationTransitionAt: now.addingTimeInterval(2)
        )
        XCTAssertEqual(try jobRepository.job(id: first.id)?.state, .completed)

        let undone = try NoonmarkEngine(snapshot: beforeCreation)
        let undoOutcome = try undone.prepareSnapshotUndo(
            replacing: afterCreation,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(undoOutcome.automaticClassificationCancelledChainIDs, [chainID])
        try engineRepository.save(
            undone.snapshot(),
            recordingChangesFor: SyncDeviceID("undo-redo-device"),
            changedAt: now.addingTimeInterval(3),
            cancellingAutomaticClassificationJobsForUndoneChain: chainID,
            automaticClassificationTransitionAt: now.addingTimeInterval(3)
        )
        let cancelled = try XCTUnwrap(jobRepository.job(id: first.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertTrue(cancelled.cancelledByUndo)
        XCTAssertEqual(cancelled.errorCode, .cancelledByUndo)
        XCTAssertEqual(cancelled.fence, claim.fence)

        let redone = try NoonmarkEngine(snapshot: afterCreation)
        let redoOutcome = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: now.addingTimeInterval(4)
        )
        XCTAssertEqual(redoOutcome.automaticClassificationRestoredChainIDs, [chainID])
        let second = try makeEnqueue(
            engine: redone,
            chainID: chainID,
            generation: 2,
            initialState: .ready,
            availableAt: now.addingTimeInterval(4),
            createdAt: now.addingTimeInterval(4)
        )
        let journalCountBeforeRedo = try syncRepository.journalEntries().count
        try engineRepository.save(
            redone.snapshot(),
            recordingChangesFor: SyncDeviceID("undo-redo-device"),
            changedAt: now.addingTimeInterval(4),
            requeuingAutomaticClassificationJobForRedo: AutomaticClassificationJobRedo(
                cancelledJob: cancelled.fence,
                replacement: second
            )
        )
        let redoneJob = try XCTUnwrap(jobRepository.job(id: second.id))
        XCTAssertEqual(redoneJob.state, .ready)
        XCTAssertEqual(redoneJob.dispatchAuthorization, .explicit)
        XCTAssertEqual(redoneJob.authorizationID, redoAuthorizationID)
        XCTAssertEqual(redoneJob.authorizedAt, now)
        XCTAssertGreaterThan(
            try syncRepository.journalEntries().count,
            journalCountBeforeRedo
        )

        let third = try makeEnqueue(
            engine: redone,
            chainID: chainID,
            generation: 3,
            initialState: .ready,
            availableAt: now.addingTimeInterval(5),
            createdAt: now.addingTimeInterval(5)
        )
        XCTAssertThrowsError(
            try engineRepository.save(
                redone.snapshot(),
                recordingChangesFor: SyncDeviceID("undo-redo-device"),
                changedAt: now.addingTimeInterval(5),
                requeuingAutomaticClassificationJobForRedo: AutomaticClassificationJobRedo(
                    cancelledJob: cancelled.fence,
                    replacement: third
                )
            )
        )
        XCTAssertNil(try jobRepository.job(id: third.id))
    }

    func testProviderEnableKeepsPendingBacklogBehindExactUserAuthorization() throws {
        let databaseURL = makeDatabaseURL("backlog-authorization")
        defer { removeDatabase(at: databaseURL) }
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let jobRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainIDs = try (0 ..< 4).map { index in
            try engine.createPoolTask(
                title: "待授权历史任务 \(index)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
        }
        let enqueues = try chainIDs.enumerated().map { index, chainID in
            try makeEnqueue(
                engine: engine,
                chainID: chainID,
                generation: 1,
                initialState: .waitingForConfiguration,
                availableAt: now,
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("backlog-authorization-device"),
            changedAt: now.addingTimeInterval(4),
            enqueuingAutomaticClassificationJobs: enqueues
        )

        let providerRevision = UUID()
        let circuit = try jobRepository.reconcileProviderExecution(
            .configured(executionRevision: providerRevision),
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(circuit.state, .closed)
        XCTAssertEqual(circuit.providerExecutionRevision, providerRevision)
        XCTAssertTrue(
            try jobRepository.jobs().allSatisfy {
                $0.state == .waitingForConfiguration
                    && $0.dispatchAuthorization == .pendingUserDecision
            }
        )
        XCTAssertEqual(
            try jobRepository.nextDispatch(
                now: now.addingTimeInterval(6),
                staleBefore: now,
                claimID: UUID()
            ),
            .backlogDecisionRequired(count: 4)
        )

        let snapshot = try jobRepository.pendingBacklog()
        XCTAssertEqual(snapshot.items.count, 4)
        XCTAssertEqual(snapshot.items.map(\.fence), enqueues.map {
            AutomaticClassificationJobFence(
                jobID: $0.id,
                generation: $0.generation,
                attempt: 0,
                claimID: nil
            )
        })

        XCTAssertEqual(
            try jobRepository.supersedeJobs(
                forChain: chainIDs[0],
                now: now.addingTimeInterval(7)
            ),
            1
        )
        let lateChainID = try engine.createPoolTask(
            title: "确认画面之后才进入的任务",
            now: now.addingTimeInterval(8)
        )
        let lateEnqueue = try makeEnqueue(
            engine: engine,
            chainID: lateChainID,
            generation: 1,
            initialState: .waitingForConfiguration,
            availableAt: now,
            createdAt: now.addingTimeInterval(8)
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("backlog-authorization-device"),
            changedAt: now.addingTimeInterval(8),
            enqueuingAutomaticClassificationJobs: [lateEnqueue]
        )

        let decisionID = UUID()
        let resolution = try jobRepository.resolveBacklog(
            snapshot,
            decision: .authorize(decisionID: decisionID),
            now: now.addingTimeInterval(9)
        )
        XCTAssertEqual(resolution.authorizedCount, 3)
        XCTAssertEqual(resolution.skippedCount, 0)
        XCTAssertEqual(resolution.ignoredCount, 1)
        XCTAssertEqual(
            try jobRepository.job(id: lateEnqueue.id)?.dispatchAuthorization,
            .pendingUserDecision
        )
        XCTAssertEqual(
            try jobRepository.job(id: lateEnqueue.id)?.state,
            .waitingForConfiguration
        )
        for enqueue in enqueues.dropFirst() {
            let authorized = try XCTUnwrap(jobRepository.job(id: enqueue.id))
            XCTAssertEqual(authorized.dispatchAuthorization, .explicit)
            XCTAssertEqual(authorized.authorizationID, decisionID)
            XCTAssertEqual(authorized.authorizedAt, now.addingTimeInterval(9))
            XCTAssertEqual(authorized.state, .ready)
        }
        XCTAssertEqual(
            try jobRepository.job(id: enqueues[0].id)?.errorCode,
            .manualClassificationWon
        )
    }

    func testBacklogLaterSurvivesRestartAndSkipIsTerminal() throws {
        let databaseURL = makeDatabaseURL("backlog-later-skip")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedWaitingJob(at: databaseURL, generation: 1)
        let firstRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try firstRepository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        let snapshot = try firstRepository.pendingBacklog()
        XCTAssertEqual(snapshot.items.count, 1)

        let restartedRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let deferred = try XCTUnwrap(restartedRepository.job(id: fixture.enqueue.id))
        XCTAssertEqual(deferred.state, .waitingForConfiguration)
        XCTAssertEqual(deferred.dispatchAuthorization, .pendingUserDecision)

        let result = try restartedRepository.resolveBacklog(
            snapshot,
            decision: .skip,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(result.authorizedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.ignoredCount, 0)
        let skipped = try XCTUnwrap(restartedRepository.job(id: fixture.enqueue.id))
        XCTAssertEqual(skipped.state, .cancelled)
        XCTAssertEqual(skipped.errorCode, .backlogSkippedByUser)
        XCTAssertFalse(skipped.cancelledByUndo)
        XCTAssertTrue(try restartedRepository.pendingBacklog().items.isEmpty)
    }

    func testRepeatedUnconfiguredProviderReconciliationIsStorageIdempotent() throws {
        let databaseURL = makeDatabaseURL("provider-unconfigured-idempotence")
        defer { removeDatabase(at: databaseURL) }
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )

        let first = try repository.reconcileProviderExecution(
            .unconfigured,
            now: now
        )
        let baselineDatabase = try Data(contentsOf: databaseURL)

        let repeated = try repository.reconcileProviderExecution(
            .unconfigured,
            now: now.addingTimeInterval(1)
        )
        let repeatedDatabase = try Data(contentsOf: databaseURL)

        XCTAssertEqual(repeated, first)
        XCTAssertEqual(repeatedDatabase, baselineDatabase)
    }

    func testRepeatedUnconfiguredReconciliationStillIsolatesReadyJobs() throws {
        let databaseURL = makeDatabaseURL("provider-unconfigured-job-isolation")
        defer { removeDatabase(at: databaseURL) }
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let circuit = try repository.reconcileProviderExecution(
            .unconfigured,
            now: now
        )
        let fixture = try seedReadyJob(at: databaseURL, generation: 1)

        let repeated = try repository.reconcileProviderExecution(
            .unconfigured,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(repeated, circuit)
        let isolated = try XCTUnwrap(repository.job(id: fixture.enqueue.id))
        XCTAssertEqual(isolated.state, .waitingForConfiguration)
        XCTAssertEqual(isolated.errorCode, .configurationUnavailable)
        XCTAssertEqual(isolated.updatedAt, now.addingTimeInterval(1))
    }

    func testCredentialRejectionBlocksWholeProviderUntilExecutionRevisionChanges() throws {
        let databaseURL = makeDatabaseURL("provider-blocked")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 2)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let firstRevision = UUID()
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: firstRevision),
            now: now.addingTimeInterval(1)
        )
        let firstClaim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try repository.resolveProviderAttempt(
            .credentialsRejected,
            for: firstClaim,
            now: now.addingTimeInterval(3)
        )
        let blocked = try XCTUnwrap(repository.providerCircuit())
        XCTAssertEqual(blocked.state, .blocked)
        XCTAssertEqual(blocked.providerExecutionRevision, firstRevision)
        XCTAssertEqual(blocked.failureCode, .providerRejected)
        XCTAssertEqual(
            try repository.nextDispatch(
                now: now.addingTimeInterval(4),
                staleBefore: now,
                claimID: UUID()
            ),
            .providerBlocked(errorCode: .providerRejected)
        )
        XCTAssertEqual(try repository.job(id: fixture.enqueues[1].id)?.attempt, 0)

        let sameRevision = try repository.reconcileProviderExecution(
            .configured(executionRevision: firstRevision),
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(sameRevision.state, .blocked)

        let secondRevision = UUID()
        let reset = try repository.reconcileProviderExecution(
            .configured(executionRevision: secondRevision),
            now: now.addingTimeInterval(6)
        )
        XCTAssertEqual(reset.state, .closed)
        XCTAssertEqual(reset.providerExecutionRevision, secondRevision)
        _ = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(7),
                staleBefore: now.addingTimeInterval(6),
                claimID: UUID()
            )
        )
    }

    func testProviderCircuitResetRequiresSameBlockedExecutionRevision() throws {
        let databaseURL = makeDatabaseURL("provider-reset-guard")
        defer { removeDatabase(at: databaseURL) }
        _ = try seedReadyJobs(at: databaseURL, count: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        let executionRevision = UUID()
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: executionRevision),
            now: now.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try repository.resetProviderCircuit(
                executionRevision: executionRevision,
                now: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .closed)

        let firstClaim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(3),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let retryAt = now.addingTimeInterval(10)
        try repository.resolveProviderAttempt(
            .transientFailure(retryAt: retryAt),
            for: firstClaim,
            now: now.addingTimeInterval(4)
        )
        XCTAssertThrowsError(
            try repository.resetProviderCircuit(
                executionRevision: executionRevision,
                now: now.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .open)

        let canary = try claimed(
            repository.nextDispatch(
                now: retryAt,
                staleBefore: now.addingTimeInterval(9),
                claimID: UUID()
            )
        )
        XCTAssertThrowsError(
            try repository.resetProviderCircuit(
                executionRevision: executionRevision,
                now: retryAt.addingTimeInterval(1)
            )
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .halfOpen)

        try repository.resolveProviderAttempt(
            .credentialsRejected,
            for: canary,
            now: retryAt.addingTimeInterval(2)
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .blocked)
        XCTAssertThrowsError(
            try repository.resetProviderCircuit(
                executionRevision: UUID(),
                now: retryAt.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .blocked)

        let reset = try repository.resetProviderCircuit(
            executionRevision: executionRevision,
            now: retryAt.addingTimeInterval(4)
        )
        XCTAssertEqual(reset.state, .closed)
        XCTAssertEqual(reset.providerExecutionRevision, executionRevision)
        XCTAssertEqual(reset.consecutiveFailures, 0)
        XCTAssertNil(reset.failureCode)
        XCTAssertNil(reset.retryAt)
        XCTAssertNil(reset.probeFence)
    }

    func testRateLimitOpensCircuitAndOnlyOneHalfOpenCanaryCanRun() throws {
        let databaseURL = makeDatabaseURL("provider-half-open")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 3)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        let firstClaim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let retryAt = now.addingTimeInterval(20)
        try repository.resolveProviderAttempt(
            .rateLimited(retryAt: retryAt),
            for: firstClaim,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .open)
        XCTAssertEqual(
            try repository.nextDispatch(
                now: now.addingTimeInterval(10),
                staleBefore: now,
                claimID: UUID()
            ),
            .idle(nextWakeAt: retryAt)
        )
        XCTAssertEqual(try repository.job(id: fixture.enqueues[1].id)?.attempt, 0)
        XCTAssertEqual(try repository.job(id: fixture.enqueues[2].id)?.attempt, 0)

        let canary = try claimed(
            repository.nextDispatch(
                now: retryAt,
                staleBefore: now.addingTimeInterval(19),
                claimID: UUID()
            )
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .halfOpen)
        let competingRepository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        guard case .idle = try competingRepository.nextDispatch(
            now: retryAt,
            staleBefore: now.addingTimeInterval(19),
            claimID: UUID()
        ) else {
            return XCTFail("half-open circuit accepted a second canary")
        }

        let checkpoint = Data("half-open-provider-proposal".utf8)
        try repository.resolveProviderAttempt(
            .checkpoint(checkpoint),
            for: canary,
            now: retryAt.addingTimeInterval(1)
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .closed)
        let proposalReady = try XCTUnwrap(repository.job(id: canary.jobID))
        XCTAssertEqual(proposalReady.state, .proposalReady)
        XCTAssertEqual(proposalReady.proposalCheckpoint, checkpoint)

        let rejectedClaim = try claimed(
            repository.nextDispatch(
                now: retryAt.addingTimeInterval(2),
                staleBefore: retryAt.addingTimeInterval(-1),
                claimID: UUID()
            )
        )
        XCTAssertEqual(rejectedClaim.jobID, fixture.enqueues[1].id)
        XCTAssertEqual(rejectedClaim.state, .running)
        try repository.resolveProviderAttempt(
            .credentialsRejected,
            for: rejectedClaim,
            now: retryAt.addingTimeInterval(3)
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .blocked)
        let recoveredProposal = try claimed(
            repository.nextDispatch(
                now: retryAt.addingTimeInterval(30),
                staleBefore: retryAt.addingTimeInterval(20),
                claimID: UUID()
            )
        )
        XCTAssertEqual(recoveredProposal.jobID, canary.jobID)
        XCTAssertEqual(recoveredProposal.state, .proposalReady)
        XCTAssertEqual(recoveredProposal.proposalCheckpoint, checkpoint)
        XCTAssertEqual(try repository.providerCircuit()?.state, .blocked)
    }

    func testThreeTransientFailuresBlockGloballyWithoutBurningBacklog() throws {
        let databaseURL = makeDatabaseURL("provider-three-strikes")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 4)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        var claim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        for failure in 1 ... 3 {
            let failedAt = now.addingTimeInterval(TimeInterval(failure * 10))
            let retryAt = failedAt.addingTimeInterval(5)
            try repository.resolveProviderAttempt(
                .transientFailure(retryAt: retryAt),
                for: claim,
                now: failedAt
            )
            let circuit = try XCTUnwrap(repository.providerCircuit())
            XCTAssertEqual(circuit.consecutiveFailures, failure)
            if failure < 3 {
                XCTAssertEqual(circuit.state, .open)
                XCTAssertEqual(
                    try repository.nextDispatch(
                        now: failedAt.addingTimeInterval(1),
                        staleBefore: failedAt,
                        claimID: UUID()
                    ),
                    .idle(nextWakeAt: retryAt)
                )
                claim = try claimed(
                    repository.nextDispatch(
                        now: retryAt,
                        staleBefore: failedAt,
                        claimID: UUID()
                    )
                )
            } else {
                XCTAssertEqual(circuit.state, .blocked)
                XCTAssertEqual(
                    try repository.nextDispatch(
                        now: retryAt,
                        staleBefore: failedAt,
                        claimID: UUID()
                    ),
                    .providerBlocked(errorCode: .providerUnavailable)
                )
            }
        }
        XCTAssertEqual(try repository.job(id: fixture.enqueues[0].id)?.attempt, 3)
        for enqueue in fixture.enqueues.dropFirst() {
            XCTAssertEqual(try repository.job(id: enqueue.id)?.attempt, 0)
        }
    }

    func testInvalidHalfOpenResponseFailsOnlyCanaryAndClosesCircuit() throws {
        let databaseURL = makeDatabaseURL("provider-invalid-canary")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedReadyJobs(at: databaseURL, count: 2)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        let first = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(2),
                staleBefore: now,
                claimID: UUID()
            )
        )
        let retryAt = now.addingTimeInterval(10)
        try repository.resolveProviderAttempt(
            .rateLimited(retryAt: retryAt),
            for: first,
            now: now.addingTimeInterval(3)
        )
        let canary = try claimed(
            repository.nextDispatch(
                now: retryAt,
                staleBefore: now.addingTimeInterval(9),
                claimID: UUID()
            )
        )
        try repository.resolveProviderAttempt(
            .invalidResponse,
            for: canary,
            now: retryAt.addingTimeInterval(1)
        )
        XCTAssertEqual(try repository.providerCircuit()?.state, .closed)
        XCTAssertEqual(try repository.providerCircuit()?.consecutiveFailures, 0)
        XCTAssertEqual(try repository.job(id: canary.jobID)?.state, .failed)
        XCTAssertEqual(
            try repository.job(id: canary.jobID)?.errorCode,
            .invalidProviderResponse
        )
        let next = try claimed(
            repository.nextDispatch(
                now: retryAt.addingTimeInterval(2),
                staleBefore: retryAt,
                claimID: UUID()
            )
        )
        XCTAssertEqual(next.jobID, fixture.enqueues[1].id)
    }

    func testContentReplacementPreservesExplicitBacklogAuthorization() throws {
        let databaseURL = makeDatabaseURL("replacement-authorization")
        defer { removeDatabase(at: databaseURL) }
        let fixture = try seedWaitingJob(at: databaseURL, generation: 1)
        let repository = SQLiteAutomaticClassificationJobRepository(
            databaseURL: databaseURL
        )
        _ = try repository.reconcileProviderExecution(
            .configured(executionRevision: UUID()),
            now: now.addingTimeInterval(1)
        )
        let decisionID = UUID()
        _ = try repository.resolveBacklog(
            repository.pendingBacklog(),
            decision: .authorize(decisionID: decisionID),
            now: now.addingTimeInterval(2)
        )
        let claim = try claimed(
            repository.nextDispatch(
                now: now.addingTimeInterval(3),
                staleBefore: now,
                claimID: UUID()
            )
        )
        try fixture.engine.updatePoolTask(
            chainID: fixture.enqueue.chainID,
            title: "授权后内容更新",
            now: now.addingTimeInterval(4)
        )
        let replacement = try makeEnqueue(
            engine: fixture.engine,
            chainID: fixture.enqueue.chainID,
            generation: 2,
            initialState: .ready,
            availableAt: now.addingTimeInterval(4),
            createdAt: now.addingTimeInterval(4)
        )
        try repository.replace(
            claim.fence,
            with: replacement,
            now: now.addingTimeInterval(5)
        )
        let persisted = try XCTUnwrap(repository.job(id: replacement.id))
        XCTAssertEqual(persisted.dispatchAuthorization, .explicit)
        XCTAssertEqual(persisted.authorizationID, decisionID)
        XCTAssertEqual(persisted.authorizedAt, now.addingTimeInterval(2))
        XCTAssertEqual(persisted.state, .ready)
    }

    private func seedReadyJob(
        at databaseURL: URL,
        generation: Int
    ) throws -> (engine: NoonmarkEngine, enqueue: AutomaticClassificationJobEnqueue) {
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainID = try engine.createPoolTask(title: "可恢复自动归类", now: now)
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: generation,
            initialState: .ready,
            availableAt: now,
            createdAt: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("seed-mac"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )
        return (engine, enqueue)
    }

    private func seedWaitingJob(
        at databaseURL: URL,
        generation: Int
    ) throws -> (engine: NoonmarkEngine, enqueue: AutomaticClassificationJobEnqueue) {
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainID = try engine.createPoolTask(title: "等待积压授权", now: now)
        let enqueue = try makeEnqueue(
            engine: engine,
            chainID: chainID,
            generation: generation,
            initialState: .waitingForConfiguration,
            availableAt: now,
            createdAt: now
        )
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("seed-waiting-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: [enqueue]
        )
        return (engine, enqueue)
    }

    private func seedReadyJobs(
        at databaseURL: URL,
        count: Int
    ) throws -> (engine: NoonmarkEngine, enqueues: [AutomaticClassificationJobEnqueue]) {
        let engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        let engine = NoonmarkEngine()
        try engineRepository.save(engine.snapshot())
        let chainIDs = try (0 ..< count).map { index in
            let createdAt = now.addingTimeInterval(TimeInterval(index - count))
            return try engine.createPoolTask(
                title: "Provider 队列任务 \(index)",
                now: createdAt
            )
        }
        let enqueues = try chainIDs.enumerated().map { index, chainID in
            try makeEnqueue(
                engine: engine,
                chainID: chainID,
                generation: 1,
                initialState: .ready,
                availableAt: now,
                createdAt: now.addingTimeInterval(TimeInterval(index - count))
            )
        }
        try engineRepository.save(
            engine.snapshot(),
            recordingChangesFor: SyncDeviceID("seed-ready-jobs-device"),
            changedAt: now,
            enqueuingAutomaticClassificationJobs: enqueues
        )
        return (engine, enqueues)
    }

    private func claimed(
        _ dispatch: AutomaticClassificationNextDispatch
    ) throws -> AutomaticClassificationJobClaim {
        guard case let .claimed(claim) = dispatch else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "expected an automatic classification claim"
            )
        }
        return claim
    }

    // swiftlint:disable:next function_parameter_count
    private func makeEnqueue(
        engine: NoonmarkEngine,
        chainID: TaskChainID,
        generation: Int,
        initialState: AutomaticClassificationJobState,
        dispatchAuthorization: AutomaticClassificationDispatchAuthorization? = nil,
        authorizationID: UUID? = nil,
        authorizedAt: Date? = nil,
        availableAt: Date,
        createdAt: Date
    ) throws -> AutomaticClassificationJobEnqueue {
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: UUID(),
            generation: generation
        )
        return try AutomaticClassificationJobEnqueue(
            authority: context.authority,
            initialState: initialState,
            dispatchAuthorization: dispatchAuthorization,
            authorizationID: authorizationID,
            authorizedAt: authorizedAt,
            availableAt: availableAt,
            createdAt: createdAt
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    private func makeDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-automatic-classification-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}

private final class SQLiteTestWriteLock: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var storedReleaseResult: Int32?

    init(databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.openFailed(
                "test write-lock connection could not open"
            )
        }
        guard sqlite3_exec(
            database,
            "BEGIN EXCLUSIVE TRANSACTION",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(database)
            throw SQLiteRepositoryError.executeFailed(
                "test write-lock transaction could not begin"
            )
        }
        self.database = database
    }

    deinit {
        lock.lock()
        if let database {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
        }
        lock.unlock()
    }

    var releaseResult: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return storedReleaseResult
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        let result = sqlite3_exec(database, "COMMIT", nil, nil, nil)
        if result != SQLITE_OK {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        }
        sqlite3_close(database)
        self.database = nil
        storedReleaseResult = result
    }
}

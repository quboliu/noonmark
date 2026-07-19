import Foundation
@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongApplicationCommitCoordinatorTests: XCTestCase {
    func testSessionFailureAfterEnginePersistenceReportsAfterEngineAsDurable() {
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: {},
            persistSession: { throw TestFailure.session },
            clearJournal: { _ in
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersisted)
        XCTAssertEqual(outcome.failureStage, .sessionPersistence)
        XCTAssertTrue(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(journalClearCount, 0)
    }

    func testJournalClearFailureReportsAfterSessionAsDurable() {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: {},
            persistSession: {},
            clearJournal: { _ in throw TestFailure.journal }
        )

        XCTAssertEqual(outcome.progress, .sessionPersisted)
        XCTAssertEqual(outcome.failureStage, .journalClear)
        XCTAssertTrue(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
    }

    func testEngineFailureReportsBeforeEngineAndAttemptsJournalRollback() {
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: { throw TestFailure.engine },
            reconcileEnginePersistenceFailure: { .before },
            persistSession: { XCTFail("不得写入 sidecar") },
            clearJournal: { requirement in
                XCTAssertEqual(requirement, .beforeSession)
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .beforeEngine)
        XCTAssertEqual(outcome.failureStage, .enginePersistence)
        XCTAssertFalse(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(outcome.enginePersistenceFailureResolution, .before)
        XCTAssertEqual(journalClearCount, 1)
        XCTAssertNil(outcome.cleanupError)
    }

    func testEngineThrowAfterDurableAfterContinuesSessionAndJournalButNeverReportsCleanSuccess() throws {
        let pending = try makePendingApplication()
        var durableEngine = try NoonmarkEngine(
            snapshot: pending.beforeSnapshot
        )
        var sessionPersistCount = 0
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: {
                durableEngine = try NoonmarkEngine(
                    snapshot: pending.afterSnapshot
                )
                throw TestFailure.engine
            },
            reconcileEnginePersistenceFailure: {
                try ZhulongEnginePersistenceInspector.resolve(
                    persistedEngine: durableEngine,
                    pendingApplication: pending
                )
            },
            persistSession: { sessionPersistCount += 1 },
            clearJournal: { requirement in
                XCTAssertEqual(requirement, .afterSession)
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .completed)
        XCTAssertNil(outcome.failureStage)
        XCTAssertTrue(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(outcome.enginePersistenceFailureResolution, .after)
        XCTAssertEqual(outcome.recoveredEnginePersistenceError as? TestFailure, .engine)
        XCTAssertEqual(sessionPersistCount, 1)
        XCTAssertEqual(journalClearCount, 1)
    }

    func testEngineThrowWithThirdDurableStateKeepsJournalAndNeverTouchesSession() {
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: { throw TestFailure.engine },
            reconcileEnginePersistenceFailure: { .conflict },
            persistSession: { XCTFail("第三 Engine 状态不得写入 sidecar") },
            clearJournal: { _ in
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersistenceUnresolved)
        XCTAssertEqual(outcome.failureStage, .enginePersistence)
        XCTAssertFalse(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(outcome.enginePersistenceFailureResolution, .conflict)
        XCTAssertEqual(outcome.underlyingError as? TestFailure, .engine)
        XCTAssertEqual(journalClearCount, 0)
    }

    func testEngineThrowWithUnreadableDurableStateKeepsJournalAndReconciliationEvidence() {
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: { throw TestFailure.engine },
            reconcileEnginePersistenceFailure: { throw TestFailure.reconciliation },
            persistSession: { XCTFail("不可读 Engine 状态不得写入 sidecar") },
            clearJournal: { _ in
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersistenceUnresolved)
        XCTAssertEqual(outcome.failureStage, .enginePersistence)
        XCTAssertFalse(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertNil(outcome.enginePersistenceFailureResolution)
        XCTAssertEqual(outcome.underlyingError as? TestFailure, .engine)
        XCTAssertEqual(outcome.reconciliationError as? TestFailure, .reconciliation)
        XCTAssertEqual(journalClearCount, 0)
    }

    func testEngineThrowWithoutReconcilerDefaultsToKeepingJournal() {
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: { throw TestFailure.engine },
            persistSession: { XCTFail("未分类 Engine 状态不得写入 sidecar") },
            clearJournal: { _ in
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersistenceUnresolved)
        XCTAssertEqual(
            outcome.reconciliationError
                as? ZhulongCommitReconciliationError,
            .durableEngineStateUnavailable
        )
        XCTAssertEqual(journalClearCount, 0)
    }

    func testEngineFailureRetainsIndependentJournalCleanupFailureEvidence() {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: { throw TestFailure.engine },
            reconcileEnginePersistenceFailure: { .before },
            persistSession: { XCTFail("不得写入 sidecar") },
            clearJournal: { requirement in
                XCTAssertEqual(requirement, .beforeSession)
                throw TestFailure.journal
            }
        )

        XCTAssertEqual(outcome.progress, .beforeEngine)
        XCTAssertEqual(outcome.failureStage, .enginePersistence)
        XCTAssertNotNil(outcome.underlyingError as? TestFailure)
        XCTAssertEqual(outcome.cleanupError as? TestFailure, .journal)
    }

    func testRecoveryStartingFromPersistedEngineNeverReportsBeforeEngine() {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: true,
            persistEngine: { XCTFail("不得重复持久化 engine") },
            persistSession: { throw TestFailure.session },
            clearJournal: { _ in
                XCTFail("sidecar 失败时必须保留 journal")
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersisted)
        XCTAssertTrue(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
    }

    func testSessionCASThirdStateKeepsDurableEngineAfterAndNeverOverwritesSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "zhulong-commit-cas-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongSessionRepository(
            directoryURL: directory,
            keySource: CommitCoordinatorKeySource()
        )
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let before = try ZhulongSession(
            primaryIntent: "验证第三态 CAS",
            proposedScopes: [.taskPool],
            now: now
        )
        var after = before
        try after.pause(now: now.addingTimeInterval(1))
        var thirdState = before
        try thirdState.pause(now: now.addingTimeInterval(2))
        try repository.save(thirdState)
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: true,
            persistEngine: { XCTFail("engine 已是 durable after") },
            persistSession: {
                try repository.save(after, replacing: before)
            },
            clearJournal: { _ in
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .enginePersisted)
        XCTAssertEqual(outcome.failureStage, .sessionPersistence)
        XCTAssertTrue(outcome.durableEngineIsAfter)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(journalClearCount, 0)
        XCTAssertEqual(try repository.load(before.id), thirdState)
    }

    func testRecoveredPrepareCompletesButNeverReportsCleanCommit() {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            prepareJournal: .recoveredCommitted(after: .replacement),
            engineAlreadyPersisted: false,
            persistEngine: {},
            persistSession: {},
            clearJournal: { _ in .committed }
        )

        XCTAssertEqual(outcome.progress, .completed)
        XCTAssertNil(outcome.failureStage)
        XCTAssertTrue(outcome.recoveredJournalMutation)
        XCTAssertFalse(outcome.commitCompleted)
    }

    func testRecoveredClearCompletesButNeverReportsCleanCommit() {
        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: false,
            persistEngine: {},
            persistSession: {},
            clearJournal: { _ in
                .recoveredCommitted(after: .directorySync)
            }
        )

        XCTAssertEqual(outcome.progress, .completed)
        XCTAssertNil(outcome.failureStage)
        XCTAssertTrue(outcome.recoveredJournalMutation)
        XCTAssertFalse(outcome.commitCompleted)
    }

    private func makePendingApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let beforeSession = try ZhulongSession(
            primaryIntent: "验证 durable after throw",
            proposedScopes: [.taskPool],
            now: now
        )
        var afterSession = beforeSession
        try afterSession.pause(now: now.addingTimeInterval(2))
        let beforeEngine = NoonmarkEngine()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "已写入但回报失败",
            now: now.addingTimeInterval(2)
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: beforeSession.id,
            beforeSnapshot: beforeEngine.snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: afterSession,
            createdAt: now.addingTimeInterval(2)
        )
    }
}

private enum TestFailure: Error, Equatable {
    case engine
    case session
    case journal
    case reconciliation
}

private struct CommitCoordinatorKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        Data(repeating: 0x5A, count: 32)
    }
}

import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongApplicationMutationClockTests: XCTestCase {
    func testFirstApplicationAllocatesAuthorizationAndApplyAfterEveryClock() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "未来 engine fact",
            now: reference.addingTimeInterval(20)
        )
        let session = try ZhulongSession(
            primaryIntent: "未来 sidecar session",
            proposedScopes: [.taskPool],
            now: reference.addingTimeInterval(30)
        )

        let timeline = try ZhulongApplicationMutationTimeline(
            reference: reference,
            engine: engine,
            selectedSession: session,
            pendingApplication: nil,
            requiresAuthorization: true
        )

        let authorizationAt = try XCTUnwrap(timeline.authorizationAt)
        XCTAssertGreaterThan(authorizationAt, reference.addingTimeInterval(30))
        XCTAssertGreaterThan(timeline.applyAt, authorizationAt)
    }

    func testExistingAuthorizationAllocatesOnlyApplyAfterFutureSession() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        var session = try ZhulongSession(
            primaryIntent: "已有授权的会话",
            proposedScopes: [.taskPool],
            now: reference.addingTimeInterval(10)
        )
        _ = try session.appendEntry(
            author: .user,
            kind: .answer,
            content: "未来草稿已经审查",
            now: reference.addingTimeInterval(40)
        )

        let timeline = try ZhulongApplicationMutationTimeline(
            reference: reference,
            engine: NoonmarkEngine(),
            selectedSession: session,
            pendingApplication: nil,
            requiresAuthorization: false
        )

        XCTAssertNil(timeline.authorizationAt)
        XCTAssertGreaterThan(timeline.applyAt, reference.addingTimeInterval(40))
    }

    func testExistingAuthorizationUsesFirstRepresentableEngineCandidate() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "engine frontier",
            now: reference.addingTimeInterval(20)
        )
        let session = try ZhulongSession(
            primaryIntent: "sidecar behind engine",
            proposedScopes: [.taskPool],
            now: reference.addingTimeInterval(10)
        )
        let expectedApplyAt = try engine.nextMutationDate(
            reference: reference
        )

        let timeline = try ZhulongApplicationMutationTimeline(
            reference: reference,
            engine: engine,
            selectedSession: session,
            pendingApplication: nil,
            requiresAuthorization: false
        )

        XCTAssertNil(timeline.authorizationAt)
        XCTAssertEqual(timeline.applyAt, expectedApplyAt)
    }

    func testPendingApplicationAndWallClockRollbackAdvanceTheApplyClock() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let selectedSession = try ZhulongSession(
            primaryIntent: "当前会话",
            proposedScopes: [.taskPool],
            now: reference
        )
        var pendingSession = selectedSession
        _ = try pendingSession.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "未来 sidecar fact",
            now: reference.addingTimeInterval(70)
        )
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "未来 pending engine fact",
            now: reference.addingTimeInterval(60)
        )
        let pending = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: selectedSession.id,
            beforeSnapshot: NoonmarkEngine().snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: selectedSession,
            afterSession: pendingSession,
            createdAt: reference.addingTimeInterval(70)
        )

        let timeline = try ZhulongApplicationMutationTimeline(
            reference: reference.addingTimeInterval(-100),
            engine: NoonmarkEngine(),
            selectedSession: selectedSession,
            pendingApplication: pending,
            requiresAuthorization: false
        )

        XCTAssertGreaterThan(timeline.applyAt, pending.createdAt)
    }
}

final class ZhulongRecoveryPlanTests: XCTestCase {
    func testEnginePersistenceInspectorClassifiesExactBeforeAfterAndThirdState() throws {
        let pending = try makePendingApplication()
        let before = try NoonmarkEngine(snapshot: pending.beforeSnapshot)
        let after = try NoonmarkEngine(snapshot: pending.afterSnapshot)
        let third = NoonmarkEngine()
        _ = try third.createPoolTask(
            title: "第三 Engine 状态",
            now: pending.createdAt.addingTimeInterval(1)
        )

        XCTAssertEqual(
            try ZhulongEnginePersistenceInspector.resolve(
                persistedEngine: before,
                pendingApplication: pending
            ),
            .before
        )
        XCTAssertEqual(
            try ZhulongEnginePersistenceInspector.resolve(
                persistedEngine: after,
                pendingApplication: pending
            ),
            .after
        )
        XCTAssertEqual(
            try ZhulongEnginePersistenceInspector.resolve(
                persistedEngine: third,
                pendingApplication: pending
            ),
            .conflict
        )
    }

    func testBeforeSnapshotRequiresOneSaveAtTheOriginalApplyInstant() throws {
        let pending = try makePendingApplication()

        let plan = try ZhulongPendingApplicationRecoveryPlan(
            currentEngine: try NoonmarkEngine(snapshot: pending.beforeSnapshot),
            pendingApplication: pending
        )

        XCTAssertEqual(plan.recoveredSnapshot, pending.afterSnapshot)
        XCTAssertEqual(plan.persistenceChangedAt, pending.createdAt)
    }

    func testAfterSnapshotDoesNotRequestAnotherSave() throws {
        let pending = try makePendingApplication()

        let plan = try ZhulongPendingApplicationRecoveryPlan(
            currentEngine: try NoonmarkEngine(snapshot: pending.afterSnapshot),
            pendingApplication: pending
        )

        XCTAssertEqual(plan.recoveredSnapshot, pending.afterSnapshot)
        XCTAssertNil(plan.persistenceChangedAt)
    }

    func testIdenticalBeforeAndAfterSnapshotAlreadySatisfiesEngineTarget() throws {
        let original = try makePendingApplication()
        let pending = try ZhulongPendingApplication(
            id: original.id,
            kind: original.kind,
            sessionID: original.sessionID,
            beforeSnapshot: original.beforeSnapshot,
            afterSnapshot: original.beforeSnapshot,
            beforeSession: original.beforeSession,
            afterSession: original.afterSession,
            createdAt: original.createdAt
        )

        let plan = try ZhulongPendingApplicationRecoveryPlan(
            currentEngine: try NoonmarkEngine(snapshot: pending.beforeSnapshot),
            pendingApplication: pending
        )

        XCTAssertEqual(plan.recoveredSnapshot, pending.afterSnapshot)
        XCTAssertNil(plan.persistenceChangedAt)
    }

    func testPersistedAfterSessionRecoveryOnlyClearsJournalWithoutDuplicateSave() throws {
        let pending = try makePendingApplication()
        var sessionReplaceCount = 0
        var journalClearCount = 0

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: true,
            persistEngine: { XCTFail("engine 已经持久化") },
            persistSession: {
                let action = try ZhulongPendingSessionReconciler.reconcile(
                    pendingApplication: pending,
                    loadPersistedSession: { pending.afterSession },
                    replaceExpectedSession: { _, _ in
                        sessionReplaceCount += 1
                    }
                )
                XCTAssertEqual(action, .alreadyAfter)
            },
            clearJournal: { requirement in
                XCTAssertEqual(requirement, .afterSession)
                journalClearCount += 1
                return .committed
            }
        )

        XCTAssertEqual(outcome.progress, .completed)
        XCTAssertTrue(outcome.commitCompleted)
        XCTAssertEqual(sessionReplaceCount, 0)
        XCTAssertEqual(journalClearCount, 1)
    }

    func testPersistedBeforeSessionRecoveryUsesOneCompareAndSwap() throws {
        let pending = try makePendingApplication()
        var capturedReplacement: ZhulongSession?
        var capturedExpected: ZhulongSession?

        let action = try ZhulongPendingSessionReconciler.reconcile(
            pendingApplication: pending,
            loadPersistedSession: { pending.beforeSession },
            replaceExpectedSession: { replacement, expected in
                capturedReplacement = replacement
                capturedExpected = expected
            }
        )

        XCTAssertEqual(action, .replaceExpectedBefore)
        XCTAssertEqual(capturedReplacement, pending.afterSession)
        XCTAssertEqual(capturedExpected, pending.beforeSession)
    }

    func testPersistedThirdSessionRecoveryFailsClosedBeforeCompareAndSwap() throws {
        let pending = try makePendingApplication()
        var thirdState = pending.beforeSession
        try thirdState.pause(
            now: pending.createdAt.addingTimeInterval(1)
        )
        var sessionReplaceCount = 0

        XCTAssertThrowsError(
            try ZhulongPendingSessionReconciler.reconcile(
                pendingApplication: pending,
                loadPersistedSession: { thirdState },
                replaceExpectedSession: { _, _ in
                    sessionReplaceCount += 1
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .sessionConflict
            )
        }
        XCTAssertEqual(sessionReplaceCount, 0)
    }

    func testPendingApplicationBlocksEveryGuardedFollowUpMutation() throws {
        let pending = try makePendingApplication()

        XCTAssertNoThrow(
            try ZhulongPendingApplicationMutationGate.validate(nil)
        )
        XCTAssertThrowsError(
            try ZhulongPendingApplicationMutationGate.validate(pending)
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
    }

    private func makePendingApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = try ZhulongSession(
            primaryIntent: "恢复跨存储应用",
            proposedScopes: [.taskPool],
            now: now
        )
        let beforeSession = session
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "应用已经形成",
            now: now.addingTimeInterval(2)
        )
        let beforeEngine = NoonmarkEngine()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "恢复后的任务",
            now: now.addingTimeInterval(2)
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: beforeEngine.snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: now.addingTimeInterval(2)
        )
    }
}

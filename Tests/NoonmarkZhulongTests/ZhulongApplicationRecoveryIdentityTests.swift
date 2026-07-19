import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongApplicationRecoveryIdentityTests: XCTestCase {
    private let baseInstant = Date(timeIntervalSince1970: 1_800_000_000)

    func testApplicationIdentityDistinguishesNextRepresentableContentClock() throws {
        let snapshots = try makeClockOnlySnapshots()

        XCTAssertNotEqual(
            try ZhulongApplicationSnapshotDigest.value(snapshots.before),
            try ZhulongApplicationSnapshotDigest.value(snapshots.after)
        )
    }

    func testRecoveryFromExactAfterSnapshotDoesNotRequestDuplicateSaveForClockOnlyChange() throws {
        let snapshots = try makeClockOnlySnapshots()
        let pending = try makePendingApplication(
            before: snapshots.before,
            after: snapshots.after
        )

        let plan = try ZhulongPendingApplicationRecoveryPlan(
            currentEngine: try NoonmarkEngine(snapshot: snapshots.after),
            pendingApplication: pending
        )

        XCTAssertEqual(plan.recoveredSnapshot, snapshots.after)
        XCTAssertNil(plan.persistenceChangedAt)
    }

    func testRecoveryRejectsPreferenceOnlyThirdSnapshot() throws {
        let beforeEngine = NoonmarkEngine()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "待恢复事实",
            now: baseInstant
        )
        let pending = try makePendingApplication(
            before: beforeEngine.snapshot(),
            after: afterEngine.snapshot()
        )
        let divergentEngine = NoonmarkEngine()
        divergentEngine.updateDataMode(.onlineFirst)

        XCTAssertThrowsError(
            try ZhulongPendingApplicationRecoveryPlan(
                currentEngine: divergentEngine,
                pendingApplication: pending
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .snapshotConflict
            )
        }
    }

    func testApplicationIdentityIncludesLocalOnlyPreferences() throws {
        let localFirst = NoonmarkEngine()
        let onlineFirst = NoonmarkEngine()
        onlineFirst.updateDataMode(.onlineFirst)

        XCTAssertNotEqual(
            try ZhulongApplicationSnapshotDigest.value(
                localFirst.snapshot()
            ),
            try ZhulongApplicationSnapshotDigest.value(
                onlineFirst.snapshot()
            )
        )
    }

    func testApplicationIdentityCanonicalizesTopLevelFactOrder() throws {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "第一项",
            now: baseInstant
        )
        _ = try engine.createPoolTask(
            title: "第二项",
            now: baseInstant.addingTimeInterval(1)
        )
        let canonical = engine.snapshot()
        var reordered = canonical
        reordered.chains.reverse()
        reordered.definitions.reverse()
        try reordered.validateIntegrity()

        XCTAssertEqual(
            try ZhulongApplicationSnapshotDigest.value(canonical),
            try ZhulongApplicationSnapshotDigest.value(reordered)
        )
    }

    func testApplicationIdentityIsStableAcrossClassificationDictionaryInsertionOrder() throws {
        let firstID = TaskCategoryID(
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        )
        let secondID = TaskCategoryID(
            UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
        )
        let first = TaskCategory(
            id: firstID,
            name: "工作",
            colorHex: "#111111",
            now: baseInstant
        )
        let second = TaskCategory(
            id: secondID,
            name: "生活",
            colorHex: "#222222",
            now: baseInstant
        )
        var left = NoonmarkEngine().snapshot()
        left.classifications = TaskClassificationState(
            categories: [
                firstID: first,
                secondID: second
            ]
        )
        var right = NoonmarkEngine().snapshot()
        right.classifications = TaskClassificationState(
            categories: [
                secondID: second,
                firstID: first
            ]
        )

        XCTAssertEqual(
            try ZhulongApplicationSnapshotDigest.value(left),
            try ZhulongApplicationSnapshotDigest.value(right)
        )
    }

    private func makeClockOnlySnapshots() throws -> (
        before: NoonmarkSnapshot,
        after: NoonmarkSnapshot
    ) {
        let engine = NoonmarkEngine()
        _ = try engine.createPoolTask(
            title: "仅时钟变化",
            now: baseInstant
        )
        let before = engine.snapshot()
        var after = before
        let currentClock = try XCTUnwrap(after.chains.first?.updatedAt)
        let currentSeconds = currentClock.timeIntervalSinceReferenceDate
        let nextClock = Date(
            timeIntervalSinceReferenceDate: currentSeconds.nextUp
        )
        XCTAssertGreaterThan(nextClock, currentClock)
        after.chains[0].updatedAt = nextClock
        try after.validateIntegrity()
        return (before, after)
    }

    private func makePendingApplication(
        before: NoonmarkSnapshot,
        after: NoonmarkSnapshot
    ) throws -> ZhulongPendingApplication {
        let createdAt = baseInstant.addingTimeInterval(10)
        let beforeSession = try ZhulongSession(
            primaryIntent: "验证恢复身份",
            proposedScopes: [.taskPool],
            now: Date(
                timeIntervalSinceReferenceDate: createdAt
                    .timeIntervalSinceReferenceDate.nextDown
            )
        )
        var afterSession = beforeSession
        _ = try afterSession.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "应用完成",
            now: createdAt
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: beforeSession.id,
            beforeSnapshot: before,
            afterSnapshot: after,
            beforeSession: beforeSession,
            afterSession: afterSession,
            createdAt: createdAt
        )
    }
}

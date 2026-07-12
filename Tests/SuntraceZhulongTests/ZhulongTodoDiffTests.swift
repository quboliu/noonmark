@testable import SuntraceCore
@testable import SuntraceZhulong
import XCTest

final class ZhulongTodoDiffTests: XCTestCase {
    private let today = LocalDate("2026-07-12")
    private let tomorrow = LocalDate("2026-07-13")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let sessionID = ZhulongSessionID(
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    )
    private let artifactID = ZhulongPlanArtifactID(
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    )

    func testBatchApplySwapsEngineOnlyAfterEveryOperationSucceeds() throws {
        var engine = SuntraceEngine()
        let original = engine.snapshot()
        let draft = try makeDraft(
            snapshot: original,
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "交付原子批次",
                        descriptionText: nil,
                        note: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                ),
                ZhulongTodoDiffItem(
                    operation: .scheduleFromPool(
                        chainID: TaskChainID(
                            UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
                        ),
                        targetDate: tomorrow
                    )
                )
            ]
        )
        var authorization = try ZhulongTodoDiffApplier().authorize(
            draft,
            against: engine,
            today: today,
            now: now.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().apply(
                draft,
                authorization: &authorization,
                to: &engine,
                today: today,
                now: now.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(engine.snapshot(), original)
        XCTAssertEqual(authorization.status, .active)
    }

    func testSuccessfulBatchCreatesScheduledTaskSubtasksAndReceipt() throws {
        var engine = SuntraceEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "完成正式三视图",
                        descriptionText: "迁移已确认的会话结构",
                        note: "保留状态",
                        plannedSubtasks: [
                            try ZhulongPlannedSubtaskDraft(title: "接入 A", difficulty: .medium),
                            try ZhulongPlannedSubtaskDraft(title: "接入 B", difficulty: .hard)
                        ],
                        targetDate: tomorrow
                    )
                )
            ]
        )
        let applier = ZhulongTodoDiffApplier()
        var authorization = try applier.authorize(
            draft,
            against: engine,
            today: today,
            now: now.addingTimeInterval(1)
        )

        let receipt = try applier.apply(
            draft,
            authorization: &authorization,
            to: &engine,
            today: today,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(receipt.items.count, 1)
        XCTAssertEqual(receipt.beforeSnapshotDigest, draft.sourceSnapshotDigest)
        XCTAssertNotEqual(receipt.afterSnapshotDigest, receipt.beforeSnapshotDigest)
        guard case let .consumed(receiptID, _) = authorization.status else {
            return XCTFail("Expected consumed authorization")
        }
        XCTAssertEqual(receiptID, receipt.id)
        guard case let .createdTask(chainID, traceID, plannedIDs) = receipt.items[0].result else {
            return XCTFail("Expected created task receipt")
        }
        XCTAssertEqual(plannedIDs.count, 2)
        XCTAssertEqual(engine.traces[try XCTUnwrap(traceID)]?.date, tomorrow)
        XCTAssertEqual(engine.definitions.values.first(where: { $0.chainID == chainID })?.plannedSubtasks.count, 2)
    }

    func testAuthorizationRejectsStaleSnapshotCrossDayTamperingAndReuse() throws {
        var engine = SuntraceEngine()
        let item = ZhulongTodoDiffItem(
            operation: .createTask(
                title: "可信写入",
                descriptionText: nil,
                note: nil,
                plannedSubtasks: [],
                targetDate: nil
            )
        )
        let draft = try makeDraft(snapshot: engine.snapshot(), items: [item])
        let applier = ZhulongTodoDiffApplier()
        var authorization = try applier.authorize(
            draft,
            against: engine,
            today: today,
            now: now.addingTimeInterval(1)
        )
        let tampered = try makeDraft(
            id: draft.id,
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    id: item.id,
                    operation: .createTask(
                        title: "被篡改的写入",
                        descriptionText: nil,
                        note: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )
        XCTAssertThrowsError(
            try applier.apply(
                tampered,
                authorization: &authorization,
                to: &engine,
                today: today,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .authorizationMismatch)
        }
        XCTAssertThrowsError(
            try applier.apply(
                draft,
                authorization: &authorization,
                to: &engine,
                today: tomorrow,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .planningDateMismatch)
        }

        _ = try applier.apply(
            draft,
            authorization: &authorization,
            to: &engine,
            today: today,
            now: now.addingTimeInterval(2)
        )
        XCTAssertThrowsError(
            try applier.apply(
                draft,
                authorization: &authorization,
                to: &engine,
                today: today,
                now: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .authorizationConsumed)
        }
    }

    func testAuthorizationAndApplyRejectSnapshotChanges() throws {
        let engine = SuntraceEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "会过期的草稿",
                        descriptionText: nil,
                        note: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )
        _ = try engine.createPoolTask(title: "外部变更", now: now.addingTimeInterval(1))
        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().authorize(
                draft,
                against: engine,
                today: today,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .staleDraft)
        }

        var cleanEngine = SuntraceEngine()
        var authorization = try ZhulongTodoDiffApplier().authorize(
            draft,
            against: cleanEngine,
            today: today,
            now: now.addingTimeInterval(2)
        )
        _ = try cleanEngine.createPoolTask(title: "授权后变更", now: now.addingTimeInterval(3))
        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().apply(
                draft,
                authorization: &authorization,
                to: &cleanEngine,
                today: today,
                now: now.addingTimeInterval(4)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .staleDraft)
        }
        XCTAssertEqual(authorization.status, .active)
    }

    func testUserRevisionRequiresParentAndExplicitModifiedItems() throws {
        let engine = SuntraceEngine()
        let item = ZhulongTodoDiffItem(
            operation: .createTask(
                title: "用户修订",
                descriptionText: nil,
                note: nil,
                plannedSubtasks: [],
                targetDate: nil
            )
        )
        let original = try makeDraft(snapshot: engine.snapshot(), items: [item])
        XCTAssertThrowsError(
            try ZhulongTodoDiffDraft(
                revising: original,
                createdAt: now.addingTimeInterval(1),
                items: [item]
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .invalidRevision)
        }

        let removed = try ZhulongTodoDiffDraft(
            revising: original,
            createdAt: now.addingTimeInterval(1),
            items: []
        )
        guard case let .userRevision(parentID, modifiedIDs) = removed.source else {
            return XCTFail("Expected user revision")
        }
        XCTAssertEqual(parentID, original.id)
        XCTAssertTrue(modifiedIDs.contains(item.id))
        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().authorize(
                removed,
                against: engine,
                today: today,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .emptyDiff)
        }
    }

    func testAuthorizationRequiresCausalTimesAndIgnoresPreferenceOnlyChanges() throws {
        var engine = SuntraceEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "不受界面设置影响",
                        descriptionText: nil,
                        note: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )
        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().authorize(
                draft,
                against: engine,
                today: today,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .invalidTime)
        }

        engine.updateTheme(.warmPaper)
        var authorization = try ZhulongTodoDiffApplier().authorize(
            draft,
            against: engine,
            today: today,
            now: now.addingTimeInterval(2)
        )
        XCTAssertThrowsError(
            try ZhulongTodoDiffApplier().apply(
                draft,
                authorization: &authorization,
                to: &engine,
                today: today,
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongTodoDiffError, .invalidTime)
        }
        XCTAssertEqual(authorization.status, .active)
    }

    private func makeDraft(
        id: ZhulongTodoDiffID = ZhulongTodoDiffID(),
        snapshot: SuntraceSnapshot,
        items: [ZhulongTodoDiffItem]
    ) throws -> ZhulongTodoDiffDraft {
        try ZhulongTodoDiffDraft(
            id: id,
            sessionID: sessionID,
            planArtifactID: artifactID,
            planArtifactVersion: 1,
            planningDate: today,
            sourceSnapshot: snapshot,
            createdAt: now,
            items: items
        )
    }
}

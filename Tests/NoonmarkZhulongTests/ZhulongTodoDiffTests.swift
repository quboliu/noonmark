@testable import NoonmarkCore
@testable import NoonmarkZhulong
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

    func testCreateTaskEncodingMatchesTheCurrentOperationShape() throws {
        let operation = ZhulongTodoDiffOperation.createTask(
            title: "当前结构",
            descriptionText: nil,
            initialNoteBody: "初始附言",
            plannedSubtasks: [],
            targetDate: nil
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["createTask"])
        let createTask = try XCTUnwrap(object["createTask"] as? [String: Any])
        XCTAssertEqual(Set(createTask.keys), ["title", "initialNoteBody", "plannedSubtasks"])
        XCTAssertEqual(createTask["title"] as? String, "当前结构")
        XCTAssertEqual(createTask["initialNoteBody"] as? String, "初始附言")
        XCTAssertEqual((createTask["plannedSubtasks"] as? [Any])?.count, 0)
    }

    func testBatchApplySwapsEngineOnlyAfterEveryOperationSucceeds() throws {
        var engine = NoonmarkEngine()
        let original = engine.snapshot()
        let draft = try makeDraft(
            snapshot: original,
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "交付原子批次",
                        descriptionText: nil,
                        initialNoteBody: nil,
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
        var engine = NoonmarkEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "完成正式会话流",
                        descriptionText: "迁移已确认的会话结构",
                        initialNoteBody: "保留状态",
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
        var engine = NoonmarkEngine()
        let item = ZhulongTodoDiffItem(
            operation: .createTask(
                title: "可信写入",
                descriptionText: nil,
                initialNoteBody: nil,
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
                        initialNoteBody: nil,
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
        let engine = NoonmarkEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "会过期的草稿",
                        descriptionText: nil,
                        initialNoteBody: nil,
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

        var cleanEngine = NoonmarkEngine()
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
        let engine = NoonmarkEngine()
        let item = ZhulongTodoDiffItem(
            operation: .createTask(
                title: "用户修订",
                descriptionText: nil,
                initialNoteBody: nil,
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

    func testUserRevisionCanEditRemoveAndSplitBeforeAtomicApply() throws {
        var engine = NoonmarkEngine()
        let editedID = ZhulongTodoDiffItemID()
        let removedID = ZhulongTodoDiffItemID()
        let splitID = ZhulongTodoDiffItemID()
        let original = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    id: editedID,
                    operation: .createTask(
                        title: "原始交付物",
                        descriptionText: nil,
                        initialNoteBody: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                ),
                ZhulongTodoDiffItem(
                    id: removedID,
                    operation: .createTask(
                        title: "不再需要的交付物",
                        descriptionText: nil,
                        initialNoteBody: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )
        let revision = try ZhulongTodoDiffDraft(
            revising: original,
            createdAt: now.addingTimeInterval(1),
            items: [
                ZhulongTodoDiffItem(
                    id: editedID,
                    operation: .createTask(
                        title: "编辑后的第一部分",
                        descriptionText: nil,
                        initialNoteBody: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                ),
                ZhulongTodoDiffItem(
                    id: splitID,
                    operation: .createTask(
                        title: "拆分出的第二部分",
                        descriptionText: nil,
                        initialNoteBody: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )

        guard case let .userRevision(parentID, modifiedIDs) = revision.source else {
            return XCTFail("Expected user revision")
        }
        XCTAssertEqual(parentID, original.id)
        XCTAssertEqual(Set(modifiedIDs), [editedID, removedID, splitID])

        var authorization = try ZhulongTodoDiffApplier().authorize(
            revision,
            against: engine,
            today: today,
            now: now.addingTimeInterval(2)
        )
        _ = try ZhulongTodoDiffApplier().apply(
            revision,
            authorization: &authorization,
            to: &engine,
            today: today,
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(
            Set(engine.definitions.values.map(\.title)),
            ["编辑后的第一部分", "拆分出的第二部分"]
        )
    }

    func testAuthorizationRequiresCausalTimesAndIgnoresPreferenceOnlyChanges() throws {
        var engine = NoonmarkEngine()
        let draft = try makeDraft(
            snapshot: engine.snapshot(),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "不受界面设置影响",
                        descriptionText: nil,
                        initialNoteBody: nil,
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

        try engine.updateTheme(
            .warmPaper,
            now: now.addingTimeInterval(1)
        )
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
        snapshot: NoonmarkSnapshot,
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

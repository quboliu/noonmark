@testable import SuntraceCore
@testable import SuntraceSync
import XCTest

final class ClassificationCommitEnvelopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreateDeltaRoundTripsAndAppliesExactFacts() throws {
        let source = SuntraceEngine()
        let before = source.snapshot()
        _ = try commit(
            .createCategory(name: "新建主分类", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("10000000-0000-0000-0000-000000000001"),
            decisionID: uuid("10000000-0000-0000-0000-000000000002"),
            at: now
        )
        let after = source.snapshot()
        let record = try XCTUnwrap(after.classifications.changeRecords.last)
        let envelope = try ClassificationCommitEnvelope(
            before: before.classifications,
            after: after.classifications,
            changeRecord: record
        )

        guard case .create = envelope.delta else {
            return XCTFail("预期 create typed delta")
        }
        let decoded = try ClassificationCommitEnvelope.decode(envelope.canonicalData())
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(decoded, to: before),
            .applied(after)
        )
    }

    func testConstructorRejectsFactsOutsideTheAuditedOperation() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createLabel(name: "无关基础标签", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("1B000000-0000-0000-0000-000000000001"),
            decisionID: uuid("1B000000-0000-0000-0000-000000000002"),
            at: now
        )
        let before = source.snapshot()
        let receipt = try commit(
            .createCategory(name: "审计内创建", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("1B000000-0000-0000-0000-000000000003"),
            decisionID: uuid("1B000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        var forged = source.snapshot().classifications
        let labelID = try XCTUnwrap(forged.labels.keys.first)
        var label = try XCTUnwrap(forged.labels[labelID])
        label.colorHex = "#FFFFFF"
        forged.labels[labelID] = label
        try forged.validateIntegrity()
        let record = try XCTUnwrap(forged.changeRecords.first {
            $0.id == receipt.changeRecordID
        })

        XCTAssertThrowsError(
            try ClassificationCommitEnvelope(
                before: before.classifications,
                after: forged,
                changeRecord: record
            )
        )
    }

    func testRenameDeltaRoundTripsAndAppliesExactFacts() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "改名前", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("11000000-0000-0000-0000-000000000001"),
            decisionID: uuid("11000000-0000-0000-0000-000000000002"),
            at: now
        )
        let categoryID = try XCTUnwrap(source.snapshot().classifications.categories.keys.first)
        let fixture = try makeDeltaFixture(
            .renameCategory(categoryID, to: "改名后"),
            in: source,
            interactionID: uuid("11000000-0000-0000-0000-000000000003"),
            decisionID: uuid("11000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )

        guard case .rename = fixture.envelope.delta else {
            return XCTFail("预期 rename typed delta")
        }
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                try ClassificationCommitEnvelope.decode(fixture.envelope.canonicalData()),
                to: fixture.before
            ),
            .applied(fixture.after)
        )
    }

    func testLifecycleDeltaRoundTripsAndAppliesExactFacts() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createLabel(name: "归档标签", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("12000000-0000-0000-0000-000000000001"),
            decisionID: uuid("12000000-0000-0000-0000-000000000002"),
            at: now
        )
        let labelID = try XCTUnwrap(source.snapshot().classifications.labels.keys.first)
        let fixture = try makeDeltaFixture(
            .archiveLabel(labelID),
            in: source,
            interactionID: uuid("12000000-0000-0000-0000-000000000003"),
            decisionID: uuid("12000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )

        guard case .lifecycle = fixture.envelope.delta else {
            return XCTFail("预期 lifecycle typed delta")
        }
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(fixture.envelope, to: fixture.before),
            .applied(fixture.after)
        )
    }

    func testMergeDeltaRoundTripsAndAppliesCurrentRewrites() throws {
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "合并当前关系", now: now)
        _ = try commit(
            .createCategory(name: "合并来源", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("13000000-0000-0000-0000-000000000001"),
            decisionID: uuid("13000000-0000-0000-0000-000000000002"),
            at: now
        )
        _ = try commit(
            .createCategory(name: "合并目标", colorHex: "#0E9488"),
            to: source,
            interactionID: uuid("13000000-0000-0000-0000-000000000003"),
            decisionID: uuid("13000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let sourceID = try XCTUnwrap(
            source.snapshot().classifications.categories.values.first {
                $0.name == "合并来源"
            }?.id
        )
        let targetID = try XCTUnwrap(
            source.snapshot().classifications.categories.values.first {
                $0.name == "合并目标"
            }?.id
        )
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(sourceID),
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("13000000-0000-0000-0000-000000000005"),
            decisionID: uuid("13000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let fixture = try makeDeltaFixture(
            .mergeCategory(source: sourceID, into: targetID),
            in: source,
            interactionID: uuid("13000000-0000-0000-0000-000000000007"),
            decisionID: uuid("13000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )

        guard case let .merge(mutation) = fixture.envelope.delta else {
            return XCTFail("预期 merge typed delta")
        }
        XCTAssertEqual(mutation.currentMutations.map(\.id), [chainID])
        XCTAssertEqual(mutation.appendedRelationHistory.count, 1)
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(fixture.envelope, to: fixture.before),
            .applied(fixture.after)
        )
    }

    func testHardDeleteDeltaRoundTripsAndAppliesTombstone() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createLabel(name: "待硬删除", colorHex: "#D1477A"),
            to: source,
            interactionID: uuid("14000000-0000-0000-0000-000000000001"),
            decisionID: uuid("14000000-0000-0000-0000-000000000002"),
            at: now
        )
        let labelID = try XCTUnwrap(source.snapshot().classifications.labels.keys.first)
        let fixture = try makeDeltaFixture(
            .hardDeleteLabel(labelID),
            in: source,
            interactionID: uuid("14000000-0000-0000-0000-000000000003"),
            decisionID: uuid("14000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )

        guard case .hardDelete = fixture.envelope.delta else {
            return XCTFail("预期 hardDelete typed delta")
        }
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(fixture.envelope, to: fixture.before),
            .applied(fixture.after)
        )
    }

    func testExactRenameNoOpAddsAuditWithoutAdvancingRevision() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "不变名称", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("15000000-0000-0000-0000-000000000001"),
            decisionID: uuid("15000000-0000-0000-0000-000000000002"),
            at: now
        )
        let categoryID = try XCTUnwrap(source.snapshot().classifications.categories.keys.first)
        let fixture = try makeDeltaFixture(
            .renameCategory(categoryID, to: "不变名称"),
            in: source,
            interactionID: uuid("15000000-0000-0000-0000-000000000003"),
            decisionID: uuid("15000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            fixture.envelope.senderResultRevision,
            fixture.envelope.senderBaseRevision
        )
        XCTAssertFalse(fixture.envelope.changeRecord.advancesStateRevision)
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(fixture.envelope, to: fixture.before),
            .applied(fixture.after)
        )
    }

    func testExactRenameNoOpRemainsAuditOnlyAfterLaterRename() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "审计基础名称", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("15100000-0000-0000-0000-000000000001"),
            decisionID: uuid("15100000-0000-0000-0000-000000000002"),
            at: now
        )
        let base = source.snapshot()
        let creationID = try XCTUnwrap(base.classifications.changeRecords.last?.id)
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)
        let noOp = try makeDeltaFixture(
            .renameCategory(categoryID, to: "审计基础名称"),
            in: source,
            interactionID: uuid("15100000-0000-0000-0000-000000000003"),
            decisionID: uuid("15100000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let rename = try makeDeltaFixture(
            .renameCategory(categoryID, to: "后续真实名称"),
            in: source,
            interactionID: uuid("15100000-0000-0000-0000-000000000005"),
            decisionID: uuid("15100000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )

        XCTAssertTrue(noOp.envelope.isAuditOnlyNoOpRename)
        XCTAssertFalse(rename.envelope.isAuditOnlyNoOpRename)
        XCTAssertEqual(
            rename.envelope.delta.mutation.predecessorChangeRecordIDs,
            [creationID]
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(renamed) = receiver.apply(rename.envelope, to: base),
              case let .applied(withAudit) = receiver.apply(noOp.envelope, to: renamed)
        else {
            return XCTFail("晚到的精确 rename no-op 应只追加审计，不覆盖后续事实")
        }
        XCTAssertEqual(withAudit, source.snapshot())
        XCTAssertEqual(
            withAudit.classifications.categories[categoryID]?.name,
            "后续真实名称"
        )
    }

    func testExactRenameNoOpCanArriveAfterHardDeleteWithoutResurrection() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "可删除审计对象", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("15200000-0000-0000-0000-000000000001"),
            decisionID: uuid("15200000-0000-0000-0000-000000000002"),
            at: now
        )
        let base = source.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)
        let noOpBranch = try SuntraceEngine(snapshot: base)
        let noOp = try makeDeltaFixture(
            .renameCategory(categoryID, to: "可删除审计对象"),
            in: noOpBranch,
            interactionID: uuid("15200000-0000-0000-0000-000000000003"),
            decisionID: uuid("15200000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let deleteBranch = try SuntraceEngine(snapshot: base)
        let deletion = try makeDeltaFixture(
            .hardDeleteCategory(categoryID),
            in: deleteBranch,
            interactionID: uuid("15200000-0000-0000-0000-000000000005"),
            decisionID: uuid("15200000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(audited) = receiver.apply(noOp.envelope, to: base),
              case let .applied(expected) = receiver.apply(deletion.envelope, to: audited),
              case let .applied(deleted) = receiver.apply(deletion.envelope, to: base),
              case let .applied(actual) = receiver.apply(noOp.envelope, to: deleted)
        else {
            return XCTFail("精确 rename no-op 在 hard-delete 后仍应作为纯审计事实收敛")
        }
        XCTAssertEqual(actual, expected)
        XCTAssertNil(actual.classifications.categories[categoryID])
        XCTAssertNotNil(actual.classifications.categoryDeletionTombstones[categoryID])
        try actual.validateIntegrity()
    }

    func testCategoryCreateDependsOnHardDeleteThatReleasedHistoricalAlias() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "已释放主分类别名", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("15300000-0000-0000-0000-000000000001"),
            decisionID: uuid("15300000-0000-0000-0000-000000000002"),
            at: now
        )
        let oldID = try XCTUnwrap(source.snapshot().classifications.categories.keys.first)
        _ = try makeDeltaFixture(
            .renameCategory(oldID, to: "删除前主分类名称"),
            in: source,
            interactionID: uuid("15300000-0000-0000-0000-000000000003"),
            decisionID: uuid("15300000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let deletion = try makeDeltaFixture(
            .hardDeleteCategory(oldID),
            in: source,
            interactionID: uuid("15300000-0000-0000-0000-000000000005"),
            decisionID: uuid("15300000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let recreation = try makeDeltaFixture(
            .createCategory(name: "  已释放主分类别名  ", colorHex: "#0E9488"),
            in: source,
            interactionID: uuid("15300000-0000-0000-0000-000000000007"),
            decisionID: uuid("15300000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )

        XCTAssertTrue(
            recreation.envelope.delta.mutation.predecessorChangeRecordIDs.contains(
                deletion.envelope.changeRecord.id
            )
        )
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                recreation.envelope,
                to: deletion.before
            ),
            .waiting([.classificationCommit(deletion.envelope.changeRecord.id)])
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(deleted) = receiver.apply(
            deletion.envelope,
            to: deletion.before
        ), case let .applied(recreated) = receiver.apply(
            recreation.envelope,
            to: deleted
        ) else {
            return XCTFail("补齐别名释放 hard-delete 后，主分类新 identity 应可创建")
        }
        XCTAssertEqual(recreated, source.snapshot())
        XCTAssertNil(recreated.classifications.categories[oldID])
    }

    func testInlineLabelCreateDependsOnHardDeleteThatReleasedHistoricalAlias() throws {
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "内联复用标签别名", now: now)
        _ = try commit(
            .createLabel(name: "已释放标签别名", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("15400000-0000-0000-0000-000000000001"),
            decisionID: uuid("15400000-0000-0000-0000-000000000002"),
            at: now
        )
        let oldID = try XCTUnwrap(source.snapshot().classifications.labels.keys.first)
        _ = try makeDeltaFixture(
            .renameLabel(oldID, to: "删除前标签名称"),
            in: source,
            interactionID: uuid("15400000-0000-0000-0000-000000000003"),
            decisionID: uuid("15400000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let deletion = try makeDeltaFixture(
            .hardDeleteLabel(oldID),
            in: source,
            interactionID: uuid("15400000-0000-0000-0000-000000000005"),
            decisionID: uuid("15400000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let recreation = try makeDeltaFixture(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [
                        .new(name: "  已释放标签别名  ", colorHex: "#0E9488")
                    ]
                )
            ),
            in: source,
            interactionID: uuid("15400000-0000-0000-0000-000000000007"),
            decisionID: uuid("15400000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )

        XCTAssertTrue(
            recreation.envelope.delta.mutation.predecessorChangeRecordIDs.contains(
                deletion.envelope.changeRecord.id
            )
        )
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                recreation.envelope,
                to: deletion.before
            ),
            .waiting([.classificationCommit(deletion.envelope.changeRecord.id)])
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(deleted) = receiver.apply(
            deletion.envelope,
            to: deletion.before
        ), case let .applied(recreated) = receiver.apply(
            recreation.envelope,
            to: deleted
        ) else {
            return XCTFail("补齐别名释放 hard-delete 后，setCurrent 应可内联创建标签")
        }
        XCTAssertEqual(recreated, source.snapshot())
        XCTAssertNil(recreated.classifications.labels[oldID])
    }

    func testConcurrentDifferentCreatesConvergeInEitherArrivalOrder() throws {
        let base = SuntraceEngine().snapshot()
        let branchA = try SuntraceEngine(snapshot: base)
        let fixtureA = try makeDeltaFixture(
            .createCategory(name: "并发创建 A", colorHex: "#2A6FDB"),
            in: branchA,
            interactionID: uuid("16000000-0000-0000-0000-000000000001"),
            decisionID: uuid("16000000-0000-0000-0000-000000000002"),
            at: now
        )
        let branchB = try SuntraceEngine(snapshot: base)
        let fixtureB = try makeDeltaFixture(
            .createCategory(name: "并发创建 B", colorHex: "#0E9488"),
            in: branchB,
            interactionID: uuid("16000000-0000-0000-0000-000000000003"),
            decisionID: uuid("16000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(a) = receiver.apply(fixtureA.envelope, to: base),
              case let .applied(ab) = receiver.apply(fixtureB.envelope, to: a),
              case let .applied(b) = receiver.apply(fixtureB.envelope, to: base),
              case let .applied(ba) = receiver.apply(fixtureA.envelope, to: b)
        else {
            return XCTFail("不同 identity 的并发 create 应可合并")
        }

        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.classifications.categories.count, 2)
        XCTAssertEqual(ab.classifications.revision, 2)
        try ab.validateIntegrity()
    }

    func testConcurrentCreateWithSameCanonicalNameFailsClosed() throws {
        let base = SuntraceEngine().snapshot()
        let branchA = try SuntraceEngine(snapshot: base)
        let fixtureA = try makeDeltaFixture(
            .createLabel(name: "同名标签", colorHex: "#2A6FDB"),
            in: branchA,
            interactionID: uuid("17000000-0000-0000-0000-000000000001"),
            decisionID: uuid("17000000-0000-0000-0000-000000000002"),
            at: now
        )
        let branchB = try SuntraceEngine(snapshot: base)
        let fixtureB = try makeDeltaFixture(
            .createLabel(name: "  同名标签  ", colorHex: "#0E9488"),
            in: branchB,
            interactionID: uuid("17000000-0000-0000-0000-000000000003"),
            decisionID: uuid("17000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(first) = receiver.apply(fixtureA.envelope, to: base) else {
            return XCTFail("首个 create 应当成功")
        }

        guard case .conflicted(.canonicalNameCollision) = receiver.apply(
            fixtureB.envelope,
            to: first
        ) else {
            return XCTFail("并发 canonical 同名必须 fail-closed")
        }
    }

    func testConcurrentRenameOfSameItemFailsTypedBaseCheck() throws {
        let baseEngine = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "并发改名基础", colorHex: "#2A6FDB"),
            to: baseEngine,
            interactionID: uuid("18000000-0000-0000-0000-000000000001"),
            decisionID: uuid("18000000-0000-0000-0000-000000000002"),
            at: now
        )
        let base = baseEngine.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)
        let branchA = try SuntraceEngine(snapshot: base)
        let fixtureA = try makeDeltaFixture(
            .renameCategory(categoryID, to: "并发改名 A"),
            in: branchA,
            interactionID: uuid("18000000-0000-0000-0000-000000000003"),
            decisionID: uuid("18000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let branchB = try SuntraceEngine(snapshot: base)
        let fixtureB = try makeDeltaFixture(
            .renameCategory(categoryID, to: "并发改名 B"),
            in: branchB,
            interactionID: uuid("18000000-0000-0000-0000-000000000005"),
            decisionID: uuid("18000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(first) = receiver.apply(fixtureA.envelope, to: base) else {
            return XCTFail("首个 rename 应当成功")
        }
        XCTAssertEqual(
            receiver.apply(fixtureB.envelope, to: first),
            .conflicted(
                .expectedItemBaseMismatch(
                    kind: .category,
                    itemID: categoryID.description
                )
            )
        )
    }

    func testMissingItemPredecessorWaitsEvenWhenFrontierWasFilledByUnrelatedFacts() throws {
        let source = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "因果主分类", colorHex: "#2A6FDB"),
            to: source,
            interactionID: uuid("19000000-0000-0000-0000-000000000001"),
            decisionID: uuid("19000000-0000-0000-0000-000000000002"),
            at: now
        )
        let receiverBase = source.snapshot()
        let categoryID = try XCTUnwrap(receiverBase.classifications.categories.keys.first)
        let rename = try makeDeltaFixture(
            .renameCategory(categoryID, to: "因果主分类 v2"),
            in: source,
            interactionID: uuid("19000000-0000-0000-0000-000000000003"),
            decisionID: uuid("19000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let lifecycle = try makeDeltaFixture(
            .archiveCategory(categoryID),
            in: source,
            interactionID: uuid("19000000-0000-0000-0000-000000000005"),
            decisionID: uuid("19000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let target = try SuntraceEngine(snapshot: receiverBase)
        _ = try commit(
            .createLabel(name: "无关事实 1", colorHex: "#AA5500"),
            to: target,
            interactionID: uuid("19000000-0000-0000-0000-000000000007"),
            decisionID: uuid("19000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )
        _ = try commit(
            .createLabel(name: "无关事实 2", colorHex: "#AA5501"),
            to: target,
            interactionID: uuid("19000000-0000-0000-0000-000000000009"),
            decisionID: uuid("19000000-0000-0000-0000-00000000000A"),
            at: now.addingTimeInterval(4)
        )
        XCTAssertGreaterThanOrEqual(
            target.snapshot().classifications.revision,
            lifecycle.envelope.senderBaseRevision
        )

        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                lifecycle.envelope,
                to: target.snapshot()
            ),
            .waiting([.classificationCommit(rename.envelope.changeRecord.id)])
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(withRename) = receiver.apply(
            rename.envelope,
            to: target.snapshot()
        ), case let .applied(withLifecycle) = receiver.apply(
            lifecycle.envelope,
            to: withRename
        ) else {
            return XCTFail("补齐 item predecessor 后应可重试成功")
        }
        XCTAssertEqual(
            withLifecycle.classifications.categories[categoryID]?.lifecycle,
            .archived
        )
        try withLifecycle.validateIntegrity()
    }

    func testItemPredecessorTracksLastFactEstablisherNotLaterRelationReference() throws {
        let source = SuntraceEngine()
        _ = try source.createPoolTask(title: "前驱事实链", now: now)
        let creation = try makeDeltaFixture(
            .createCategory(name: "前驱分类", colorHex: "#2A6FDB"),
            in: source,
            interactionID: uuid("1C000000-0000-0000-0000-000000000001"),
            decisionID: uuid("1C000000-0000-0000-0000-000000000002"),
            at: now
        )
        let categoryID = try XCTUnwrap(
            creation.after.classifications.categories.keys.first
        )
        let chainID = try XCTUnwrap(creation.after.chains.first?.id)
        let relation = try makeDeltaFixture(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            in: source,
            interactionID: uuid("1C000000-0000-0000-0000-000000000003"),
            decisionID: uuid("1C000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let rename = try makeDeltaFixture(
            .renameCategory(categoryID, to: "前驱分类 v2"),
            in: source,
            interactionID: uuid("1C000000-0000-0000-0000-000000000005"),
            decisionID: uuid("1C000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )

        XCTAssertEqual(
            rename.envelope.delta.mutation.predecessorChangeRecordIDs,
            [creation.envelope.changeRecord.id]
        )
        XCTAssertFalse(
            rename.envelope.delta.mutation.predecessorChangeRecordIDs.contains(
                relation.envelope.changeRecord.id
            )
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(withCreation) = receiver.apply(
            creation.envelope,
            to: creation.before
        ) else {
            return XCTFail("前驱 create 应先应用成功")
        }
        let target = try SuntraceEngine(snapshot: withCreation)
        _ = try commit(
            .createLabel(name: "填充 frontier", colorHex: "#0E9488"),
            to: target,
            interactionID: uuid("1C000000-0000-0000-0000-000000000007"),
            decisionID: uuid("1C000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )
        guard case let .applied(renamed) = receiver.apply(
            rename.envelope,
            to: target.snapshot()
        ) else {
            return XCTFail("具备 exact item fact 前驱时不应等待无关 setCurrent")
        }
        XCTAssertEqual(
            renamed.classifications.categories[categoryID]?.name,
            "前驱分类 v2"
        )
    }

    func testConcurrentMergeAndHardDeleteFailClosedInBothArrivalOrders() throws {
        let baseEngine = SuntraceEngine()
        _ = try commit(
            .createCategory(name: "竞态来源", colorHex: "#2A6FDB"),
            to: baseEngine,
            interactionID: uuid("1A000000-0000-0000-0000-000000000001"),
            decisionID: uuid("1A000000-0000-0000-0000-000000000002"),
            at: now
        )
        _ = try commit(
            .createCategory(name: "竞态目标", colorHex: "#0E9488"),
            to: baseEngine,
            interactionID: uuid("1A000000-0000-0000-0000-000000000003"),
            decisionID: uuid("1A000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let base = baseEngine.snapshot()
        let sourceID = try XCTUnwrap(base.classifications.categories.values.first {
            $0.name == "竞态来源"
        }?.id)
        let targetID = try XCTUnwrap(base.classifications.categories.values.first {
            $0.name == "竞态目标"
        }?.id)

        let mergeBranch = try SuntraceEngine(snapshot: base)
        let merge = try makeDeltaFixture(
            .mergeCategory(source: sourceID, into: targetID),
            in: mergeBranch,
            interactionID: uuid("1A000000-0000-0000-0000-000000000005"),
            decisionID: uuid("1A000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let deleteBranch = try SuntraceEngine(snapshot: base)
        let delete = try makeDeltaFixture(
            .hardDeleteCategory(sourceID),
            in: deleteBranch,
            interactionID: uuid("1A000000-0000-0000-0000-000000000007"),
            decisionID: uuid("1A000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(3)
        )
        let receiver = ClassificationCommitEnvelopeReceiver()

        guard case let .applied(deleted) = receiver.apply(delete.envelope, to: base),
              case .conflicted(.dependencyPermanentlyDeleted) = receiver.apply(
                  merge.envelope,
                  to: deleted
              ),
              case let .applied(merged) = receiver.apply(merge.envelope, to: base),
              case .conflicted = receiver.apply(delete.envelope, to: merged)
        else {
            return XCTFail("merge/delete race must fail closed in either order")
        }
    }

    func testSetCurrentRejectsCategoryArchivedByConcurrentCommit() throws {
        let baseEngine = SuntraceEngine()
        let chainID = try baseEngine.createPoolTask(title: "归档并发关系", now: now)
        _ = try commit(
            .createCategory(name: "即将归档", colorHex: "#2A6FDB"),
            to: baseEngine,
            interactionID: uuid("1D000000-0000-0000-0000-000000000001"),
            decisionID: uuid("1D000000-0000-0000-0000-000000000002"),
            at: now
        )
        let base = baseEngine.snapshot()
        let categoryID = try XCTUnwrap(base.classifications.categories.keys.first)
        let archiveBranch = try SuntraceEngine(snapshot: base)
        let archive = try makeDeltaFixture(
            .archiveCategory(categoryID),
            in: archiveBranch,
            interactionID: uuid("1D000000-0000-0000-0000-000000000003"),
            decisionID: uuid("1D000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let relationBranch = try SuntraceEngine(snapshot: base)
        let relation = try makeDeltaFixture(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            in: relationBranch,
            interactionID: uuid("1D000000-0000-0000-0000-000000000005"),
            decisionID: uuid("1D000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let receiver = ClassificationCommitEnvelopeReceiver()

        guard case let .applied(archived) = receiver.apply(archive.envelope, to: base) else {
            return XCTFail("archive 分支应先应用成功")
        }
        XCTAssertEqual(
            receiver.apply(relation.envelope, to: archived),
            .conflicted(
                .inactiveDependency(
                    kind: .category,
                    itemID: categoryID.description
                )
            )
        )
    }

    func testSetCurrentRejectsLabelArchivedByConcurrentCommit() throws {
        let baseEngine = SuntraceEngine()
        let chainID = try baseEngine.createPoolTask(title: "标签归档并发关系", now: now)
        _ = try commit(
            .createLabel(name: "即将归档标签", colorHex: "#0E9488"),
            to: baseEngine,
            interactionID: uuid("1E000000-0000-0000-0000-000000000001"),
            decisionID: uuid("1E000000-0000-0000-0000-000000000002"),
            at: now
        )
        let base = baseEngine.snapshot()
        let labelID = try XCTUnwrap(base.classifications.labels.keys.first)
        let archiveBranch = try SuntraceEngine(snapshot: base)
        let archive = try makeDeltaFixture(
            .archiveLabel(labelID),
            in: archiveBranch,
            interactionID: uuid("1E000000-0000-0000-0000-000000000003"),
            decisionID: uuid("1E000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(1)
        )
        let relationBranch = try SuntraceEngine(snapshot: base)
        let relation = try makeDeltaFixture(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [.existing(labelID)]
                )
            ),
            in: relationBranch,
            interactionID: uuid("1E000000-0000-0000-0000-000000000005"),
            decisionID: uuid("1E000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(2)
        )
        let receiver = ClassificationCommitEnvelopeReceiver()

        guard case let .applied(archived) = receiver.apply(archive.envelope, to: base) else {
            return XCTFail("label archive 分支应先应用成功")
        }
        XCTAssertEqual(
            receiver.apply(relation.envelope, to: archived),
            .conflicted(
                .inactiveDependency(
                    kind: .label,
                    itemID: labelID.description
                )
            )
        )
    }

    func testExplicitSetCurrentRoundTripsCanonicalEnvelopeAndAppliesExactFacts() throws {
        let fixture = try makeFixture()

        let firstEncoding = try fixture.envelope.canonicalData()
        let decoded = try ClassificationCommitEnvelope.decode(firstEncoding)
        let secondEncoding = try decoded.canonicalData()

        XCTAssertEqual(decoded, fixture.envelope)
        XCTAssertEqual(secondEncoding, firstEncoding)
        XCTAssertTrue(try decoded.hasValidIntegrityDigest())

        let topLevel = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstEncoding) as? [String: Any]
        )
        XCTAssertEqual(topLevel["formatVersion"] as? Int, 1)
        XCTAssertNotNil(topLevel["delta"])
        XCTAssertNil(topLevel["setCurrent"])
        XCTAssertNil(topLevel["createdCategories"])
        XCTAssertNil(topLevel["snapshot"])
        XCTAssertNil(topLevel["classificationPlan"])

        let result = ClassificationCommitEnvelopeReceiver().apply(
            decoded,
            to: fixture.beforeSnapshot
        )
        guard case let .applied(snapshot) = result else {
            return XCTFail("预期接收端应用显式当前分类提交，实际为 \(result)")
        }
        XCTAssertEqual(snapshot, fixture.afterSnapshot)
        XCTAssertEqual(
            snapshot.classifications.changeRecords.last,
            fixture.envelope.changeRecord
        )
        XCTAssertEqual(
            snapshot.classifications.committedReceiptsByInteractionID[
                fixture.envelope.changeRecord.interactionID
            ],
            fixture.envelope.receipt
        )
        try snapshot.validateIntegrity()

        let inlineCreation = try makeInlineCreationFixture()
        let inlineMutation = inlineCreation.envelope.delta.mutation
        XCTAssertEqual(inlineMutation.categoryMutations.count, 1)
        XCTAssertEqual(inlineMutation.categoryMutations.first?.expected, .absent)
        XCTAssertEqual(inlineMutation.labelMutations.count, 1)
        XCTAssertEqual(inlineMutation.labelMutations.first?.expected, .absent)
        guard case let .applied(inlineApplied) = ClassificationCommitEnvelopeReceiver().apply(
            inlineCreation.envelope,
            to: inlineCreation.beforeSnapshot
        ) else {
            return XCTFail("同一次 setCurrent 创建的分类 facts 应当自包含")
        }
        XCTAssertEqual(inlineApplied, inlineCreation.afterSnapshot)
    }

    func testEnvelopeRejectsTamperingUnknownVersionAndMissingVersion() throws {
        let envelope = try makeFixture().envelope
        let data = try envelope.canonicalData()

        var tampered = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        tampered["senderResultRevision"] = 999
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        XCTAssertThrowsError(try ClassificationCommitEnvelope.decode(tamperedData)) { error in
            XCTAssertEqual(
                error as? ClassificationCommitEnvelopeError,
                .integrityDigestMismatch
            )
        }

        var unknownVersion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        unknownVersion["formatVersion"] = 2
        let unknownVersionData = try JSONSerialization.data(withJSONObject: unknownVersion)
        XCTAssertThrowsError(
            try ClassificationCommitEnvelope.decode(unknownVersionData)
        ) { error in
            XCTAssertEqual(
                error as? ClassificationCommitEnvelopeError,
                .unsupportedFormatVersion(2)
            )
        }

        var missingVersion = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        missingVersion.removeValue(forKey: "formatVersion")
        let missingVersionData = try JSONSerialization.data(withJSONObject: missingVersion)
        XCTAssertThrowsError(try ClassificationCommitEnvelope.decode(missingVersionData))

        var unknownField = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        unknownField["classificationPlan"] = ["forbidden": true]
        let unknownFieldData = try JSONSerialization.data(withJSONObject: unknownField)
        XCTAssertThrowsError(
            try ClassificationCommitEnvelope.decode(unknownFieldData)
        ) { error in
            XCTAssertEqual(
                error as? ClassificationCommitEnvelopeError,
                .nonCanonicalEncoding
            )
        }
    }

    func testReceiverWaitsForMissingChainCategoryAndLabelDependencies() throws {
        let fixture = try makeFixture()

        let empty = SuntraceEngine().snapshot()
        let missingChain = ClassificationCommitEnvelopeReceiver().apply(
            fixture.envelope,
            to: empty
        )
        guard case let .waiting(dependencies) = missingChain else {
            return XCTFail("预期等待任务链依赖，实际为 \(missingChain)")
        }
        XCTAssertTrue(dependencies.contains(.taskChain(fixture.chainID)))

        var missingCatalog = fixture.beforeSnapshot
        missingCatalog.classifications = TaskClassificationState()
        let missingItems = ClassificationCommitEnvelopeReceiver().apply(
            fixture.envelope,
            to: missingCatalog
        )
        guard case let .waiting(dependencies) = missingItems else {
            return XCTFail("预期等待分类目录依赖，实际为 \(missingItems)")
        }
        XCTAssertEqual(
            Set(dependencies),
            [
                .category(fixture.categoryID),
                .label(fixture.labelID)
            ]
        )
    }

    func testCausalSuccessorWaitsForMissingFactsBeforeExpectedBaseConflict() throws {
        let initial = try makeFixture(seed: "35")
        let source = try SuntraceEngine(snapshot: initial.afterSnapshot)
        let before = source.snapshot()
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: initial.chainID,
                    category: nil,
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("35000000-0000-0000-0000-000000000007"),
            decisionID: uuid("35000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let after = source.snapshot()
        let successor = try ClassificationCommitEnvelope(
            before: before.classifications,
            after: after.classifications,
            changeRecord: try XCTUnwrap(after.classifications.changeRecords.last)
        )

        let result = ClassificationCommitEnvelopeReceiver().apply(
            successor,
            to: SuntraceEngine().snapshot()
        )

        guard case let .waiting(dependencies) = result else {
            return XCTFail("后继提交缺少 typed facts 时应等待，实际为 \(result)")
        }
        XCTAssertEqual(
            Set(dependencies),
            [
                .taskChain(initial.chainID),
                .category(initial.categoryID),
                .label(initial.labelID),
                .classificationCommit(initial.envelope.changeRecord.id)
            ]
        )
    }

    func testReceiverIsIdempotentForSameChangeRecordAndIntegrityDigest() throws {
        let fixture = try makeFixture()
        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(firstSnapshot) = receiver.apply(
            fixture.envelope,
            to: fixture.beforeSnapshot
        ) else {
            return XCTFail("首次提交应当成功")
        }

        let secondResult = receiver.apply(fixture.envelope, to: firstSnapshot)
        guard case let .duplicate(secondSnapshot) = secondResult else {
            return XCTFail("同一提交应当幂等，实际为 \(secondResult)")
        }
        XCTAssertEqual(secondSnapshot, firstSnapshot)
    }

    func testReplayRemainsDuplicateAfterLaterCommitSupersedesProjection() throws {
        let fixture = try makeFixture(seed: "36")
        let evolvedEngine = try SuntraceEngine(snapshot: fixture.afterSnapshot)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: fixture.chainID,
                    category: nil,
                    labels: []
                )
            ),
            to: evolvedEngine,
            interactionID: uuid("36000000-0000-0000-0000-000000000007"),
            decisionID: uuid("36000000-0000-0000-0000-000000000008"),
            at: now.addingTimeInterval(4)
        )
        let evolved = evolvedEngine.snapshot()
        XCTAssertNil(
            evolved.classifications.currentByChainID[fixture.chainID]?.categoryID
        )
        XCTAssertEqual(
            evolved.classifications.currentByChainID[fixture.chainID]?.labelIDs,
            []
        )

        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                fixture.envelope,
                to: evolved
            ),
            .duplicate(evolved)
        )
    }

    func testSameChangeRecordIdentityWithDifferentContentConflicts() throws {
        let first = try makeFixture(seed: "31")
        let second = try makeFixture(seed: "32")
        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(firstApplied) = receiver.apply(
            first.envelope,
            to: first.beforeSnapshot
        ) else {
            return XCTFail("首个提交应当成功")
        }

        let secondRecord = second.envelope.changeRecord
        let collisionRecord = ClassificationChangeRecord(
            id: first.envelope.changeRecord.id,
            planID: secondRecord.planID,
            interactionID: secondRecord.interactionID,
            source: secondRecord.source,
            decisionID: secondRecord.decisionID,
            changes: secondRecord.changes,
            notices: secondRecord.notices,
            committedAt: secondRecord.committedAt,
            revision: secondRecord.revision,
            planDigest: secondRecord.planDigest
        )
        let secondReceipt = try XCTUnwrap(second.envelope.receipt)
        let collisionReceipt = ClassificationReceipt(
            planID: collisionRecord.planID,
            revision: collisionRecord.revision,
            notices: secondReceipt.notices,
            changeRecordID: collisionRecord.id,
            decisionID: collisionRecord.decisionID,
            changeRecordIntegrityDigest: collisionRecord.integrityDigest
        )
        let collisionEnvelope = try ClassificationCommitEnvelope(
            senderBaseRevision: second.envelope.senderBaseRevision,
            senderResultRevision: second.envelope.senderResultRevision,
            delta: second.envelope.delta,
            changeRecord: collisionRecord,
            receipt: collisionReceipt
        )

        XCTAssertEqual(
            receiver.apply(collisionEnvelope, to: firstApplied),
            .conflicted(.changeRecordIdentityCollision(collisionRecord.id))
        )
    }

    func testUnrelatedLocalRevisionDoesNotBlockTypedBaseFact() throws {
        let fixture = try makeFixture()
        let target = try SuntraceEngine(snapshot: fixture.beforeSnapshot)
        _ = try commit(
            .createLabel(name: "仅在接收端", colorHex: "#AA5500"),
            to: target,
            interactionID: uuid("41000000-0000-0000-0000-000000000001"),
            decisionID: uuid("41000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(20)
        )
        let localBefore = target.snapshot()
        XCTAssertEqual(
            localBefore.classifications.revision,
            fixture.envelope.senderResultRevision
        )

        let result = ClassificationCommitEnvelopeReceiver().apply(
            fixture.envelope,
            to: localBefore
        )
        guard case let .applied(snapshot) = result else {
            return XCTFail("不相关的本地 revision 不应阻断 typed base fact，实际为 \(result)")
        }
        XCTAssertEqual(
            snapshot.classifications.currentByChainID[fixture.chainID]?.categoryID,
            fixture.categoryID
        )
        XCTAssertTrue(
            snapshot.classifications.labels.values.contains { $0.name == "仅在接收端" }
        )
        try snapshot.validateIntegrity()

        let divergent = try SuntraceEngine(snapshot: fixture.beforeSnapshot)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: fixture.chainID,
                    category: .existing(fixture.categoryID),
                    labels: []
                )
            ),
            to: divergent,
            interactionID: uuid("42000000-0000-0000-0000-000000000001"),
            decisionID: uuid("42000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(21)
        )
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                fixture.envelope,
                to: divergent.snapshot()
            ),
            .conflicted(.expectedBaseMismatch(fixture.chainID))
        )
    }

    func testFutureSenderBaseRevisionWaitsForMissingRevisionFact() throws {
        let source = SuntraceEngine()
        let chainID = try source.createPoolTask(title: "revision 等待", now: now)
        let receiverBase = source.snapshot()
        _ = try commit(
            .createLabel(name: "发送端先前事实", colorHex: "#AA5500"),
            to: source,
            interactionID: uuid("44000000-0000-0000-0000-000000000001"),
            decisionID: uuid("44000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(20)
        )
        let senderBase = source.snapshot()
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "稍后到达的分类", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("44000000-0000-0000-0000-000000000003"),
            decisionID: uuid("44000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(21)
        )
        let senderResult = source.snapshot()
        let envelope = try ClassificationCommitEnvelope(
            before: senderBase.classifications,
            after: senderResult.classifications,
            changeRecord: try XCTUnwrap(senderResult.classifications.changeRecords.last)
        )

        XCTAssertEqual(envelope.senderBaseRevision, 1)
        XCTAssertEqual(receiverBase.classifications.revision, 0)
        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                envelope,
                to: receiverBase
            ),
            .waiting([.classificationRevision(1)])
        )
    }

    func testConcurrentDifferentLabelAdditionsMergeFromTheSameBase() throws {
        let baseEngine = SuntraceEngine()
        let chainID = try baseEngine.createPoolTask(title: "并发标签合并", now: now)
        let base = baseEngine.snapshot()

        let branchA = try SuntraceEngine(snapshot: base)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [.new(name: "并发标签 A", colorHex: "#2A6FDB")]
                )
            ),
            to: branchA,
            interactionID: uuid("43000000-0000-0000-0000-000000000001"),
            decisionID: uuid("43000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(30)
        )
        let afterA = branchA.snapshot()
        let recordA = try XCTUnwrap(afterA.classifications.changeRecords.last)
        let envelopeA = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterA.classifications,
            changeRecord: recordA
        )

        let branchB = try SuntraceEngine(snapshot: base)
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [.new(name: "并发标签 B", colorHex: "#0E9488")]
                )
            ),
            to: branchB,
            interactionID: uuid("43000000-0000-0000-0000-000000000003"),
            decisionID: uuid("43000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(31)
        )
        let afterB = branchB.snapshot()
        let recordB = try XCTUnwrap(afterB.classifications.changeRecords.last)
        let envelopeB = try ClassificationCommitEnvelope(
            before: base.classifications,
            after: afterB.classifications,
            changeRecord: recordB
        )

        let receiver = ClassificationCommitEnvelopeReceiver()
        guard case let .applied(receivedA) = receiver.apply(envelopeA, to: base) else {
            return XCTFail("接收端应先应用并发分支 A")
        }
        guard case let .applied(merged) = receiver.apply(envelopeB, to: receivedA) else {
            return XCTFail("接收端应以 label delta 合并并发分支 B")
        }

        let labelA = try XCTUnwrap(
            merged.classifications.labels.values.first { $0.name == "并发标签 A" }
        )
        let labelB = try XCTUnwrap(
            merged.classifications.labels.values.first { $0.name == "并发标签 B" }
        )
        XCTAssertEqual(
            merged.classifications.currentByChainID[chainID]?.labelIDs,
            Set([labelA.id, labelB.id])
        )
        XCTAssertEqual(
            Set(merged.classifications.changeRecords.suffix(2).map(\.id)),
            Set([recordA.id, recordB.id])
        )
        XCTAssertEqual(merged.classifications.committedReceiptsByInteractionID.count, 2)
        try merged.validateIntegrity()

        guard case let .applied(receivedB) = receiver.apply(envelopeB, to: base) else {
            return XCTFail("接收端应先应用并发分支 B")
        }
        guard case let .applied(reverseMerged) = receiver.apply(envelopeA, to: receivedB) else {
            return XCTFail("接收端应以 label delta 反序合并分支 A")
        }
        XCTAssertEqual(reverseMerged, merged)
        try reverseMerged.validateIntegrity()
    }

    func testPermanentDeletionTombstoneBlocksOlderEnvelopeFromResurrectingIdentity() throws {
        let fixture = try makeFixture()
        let target = try SuntraceEngine(snapshot: fixture.beforeSnapshot)
        _ = try commit(
            .hardDeleteCategory(fixture.categoryID),
            to: target,
            interactionID: uuid("51000000-0000-0000-0000-000000000001"),
            decisionID: uuid("51000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(30)
        )
        let tombstoned = target.snapshot()
        XCTAssertNotNil(
            tombstoned.classifications.categoryDeletionTombstones[fixture.categoryID]
        )

        XCTAssertEqual(
            ClassificationCommitEnvelopeReceiver().apply(
                fixture.envelope,
                to: tombstoned
            ),
            .conflicted(
                .dependencyPermanentlyDeleted(
                    kind: .category,
                    itemID: fixture.categoryID.description
                )
            )
        )
        XCTAssertNil(tombstoned.classifications.categories[fixture.categoryID])
    }

    func testReplacementPreservesRemovalHistoryAndRelationProvenance() throws {
        let initial = try makeFixture()
        let source = try SuntraceEngine(snapshot: initial.afterSnapshot)
        let before = source.snapshot()
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: initial.chainID,
                    category: nil,
                    labels: []
                )
            ),
            to: source,
            interactionID: uuid("61000000-0000-0000-0000-000000000001"),
            decisionID: uuid("61000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(40)
        )
        let after = source.snapshot()
        let record = try XCTUnwrap(after.classifications.changeRecords.last)
        let envelope = try ClassificationCommitEnvelope(
            before: before.classifications,
            after: after.classifications,
            changeRecord: record
        )

        let result = ClassificationCommitEnvelopeReceiver().apply(envelope, to: before)
        guard case let .applied(applied) = result else {
            return XCTFail("预期应用移除关系提交，实际为 \(result)")
        }
        XCTAssertEqual(applied, after)
        XCTAssertEqual(envelope.delta.mutation.appendedRelationHistory.count, 2)
        XCTAssertTrue(envelope.delta.mutation.appendedRelationHistory.allSatisfy { history in
            history.chainID == initial.chainID
                && history.removedBySource == record.source
                && history.removedByDecisionID == record.decisionID
                && history.removedAt == record.committedAt
                && history.removedRevision == record.revision
        })
        try applied.validateIntegrity()
    }
}

private extension ClassificationCommitEnvelopeTests {
    struct DeltaFixture {
        let before: SuntraceSnapshot
        let after: SuntraceSnapshot
        let envelope: ClassificationCommitEnvelope
    }

    struct Fixture {
        let chainID: TaskChainID
        let categoryID: TaskCategoryID
        let labelID: TaskLabelID
        let beforeSnapshot: SuntraceSnapshot
        let afterSnapshot: SuntraceSnapshot
        let envelope: ClassificationCommitEnvelope
    }

    func makeDeltaFixture(
        _ intent: ClassificationIntent,
        in engine: SuntraceEngine,
        interactionID: UUID,
        decisionID: UUID,
        at time: Date
    ) throws -> DeltaFixture {
        let before = engine.snapshot()
        let receipt = try commit(
            intent,
            to: engine,
            interactionID: interactionID,
            decisionID: decisionID,
            at: time
        )
        let after = engine.snapshot()
        let record = try XCTUnwrap(after.classifications.changeRecords.first {
            $0.id == receipt.changeRecordID
        })
        return DeltaFixture(
            before: before,
            after: after,
            envelope: try ClassificationCommitEnvelope(
                before: before.classifications,
                after: after.classifications,
                changeRecord: record
            )
        )
    }

    func makeFixture(seed: String = "30") throws -> Fixture {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(
            title: "同步分类 \(seed)",
            now: now
        )
        _ = try commit(
            .createCategory(name: "领域 \(seed)", colorHex: "#2A6FDB"),
            to: engine,
            interactionID: uuid("\(seed)000000-0000-0000-0000-000000000001"),
            decisionID: uuid("\(seed)000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(1)
        )
        _ = try commit(
            .createLabel(name: "白盒 \(seed)", colorHex: "#0E9488"),
            to: engine,
            interactionID: uuid("\(seed)000000-0000-0000-0000-000000000003"),
            decisionID: uuid("\(seed)000000-0000-0000-0000-000000000004"),
            at: now.addingTimeInterval(2)
        )
        let categoryID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        let labelID = try XCTUnwrap(engine.snapshot().classifications.labels.keys.first)
        let before = engine.snapshot()

        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: [.existing(labelID)]
                )
            ),
            to: engine,
            interactionID: uuid("\(seed)000000-0000-0000-0000-000000000005"),
            decisionID: uuid("\(seed)000000-0000-0000-0000-000000000006"),
            at: now.addingTimeInterval(3)
        )
        let after = engine.snapshot()
        let record = try XCTUnwrap(after.classifications.changeRecords.last)
        let envelope = try ClassificationCommitEnvelope(
            before: before.classifications,
            after: after.classifications,
            changeRecord: record
        )
        return Fixture(
            chainID: chainID,
            categoryID: categoryID,
            labelID: labelID,
            beforeSnapshot: before,
            afterSnapshot: after,
            envelope: envelope
        )
    }

    func makeInlineCreationFixture() throws -> Fixture {
        let engine = SuntraceEngine()
        let chainID = try engine.createPoolTask(title: "提交内创建分类", now: now)
        let before = engine.snapshot()
        _ = try commit(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "提交内主分类", colorHex: "#2A6FDB"),
                    labels: [.new(name: "提交内标签", colorHex: "#0E9488")]
                )
            ),
            to: engine,
            interactionID: uuid("33000000-0000-0000-0000-000000000001"),
            decisionID: uuid("33000000-0000-0000-0000-000000000002"),
            at: now.addingTimeInterval(3)
        )
        let after = engine.snapshot()
        let categoryID = try XCTUnwrap(after.classifications.categories.keys.first)
        let labelID = try XCTUnwrap(after.classifications.labels.keys.first)
        let record = try XCTUnwrap(after.classifications.changeRecords.last)
        return Fixture(
            chainID: chainID,
            categoryID: categoryID,
            labelID: labelID,
            beforeSnapshot: before,
            afterSnapshot: after,
            envelope: try ClassificationCommitEnvelope(
                before: before.classifications,
                after: after.classifications,
                changeRecord: record
            )
        )
    }

    @discardableResult
    func commit(
        _ intent: ClassificationIntent,
        to engine: SuntraceEngine,
        interactionID: UUID,
        decisionID: UUID,
        at time: Date
    ) throws -> ClassificationReceipt {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: interactionID,
            now: time
        )
        return try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: time
        )
    }

    func uuid(_ value: String) -> UUID {
        guard let result = UUID(uuidString: value) else {
            preconditionFailure("测试 UUID 非法：\(value)")
        }
        return result
    }
}

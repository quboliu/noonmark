@testable import NoonmarkCore
import XCTest

final class TaskClassificationModuleTests: XCTestCase {
    private let day1 = LocalDate("2026-07-05")
    private let day2 = LocalDate("2026-07-06")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMutationClockAdvancesPastClassificationOnlyFutureFacts() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "未来时间分类", now: now)
        let classificationTime = now.addingTimeInterval(100)
        let initialPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "白盒", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: classificationTime
        )
        _ = try engine.commitClassification(
            initialPlan,
            confirmation: .user(decisionID: UUID()),
            now: classificationTime
        )

        let mutationDate = try engine.nextMutationDate(
            reference: now.addingTimeInterval(50)
        )
        XCTAssertGreaterThan(mutationDate, classificationTime)

        let categoryID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        let removalPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: UUID(),
            now: mutationDate
        )
        XCTAssertNoThrow(
            try engine.commitClassification(
                removalPlan,
                confirmation: .user(decisionID: UUID()),
                now: mutationDate
            )
        )
    }

    func testUserCanPrepareThenCommitOneCategoryAndMoreThanThreePeerLabels() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "整理季度发布", now: now)
        let interactionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let decisionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [
                        .new(name: "复盘", colorHex: "#0E9488"),
                        .new(name: "客户", colorHex: "#7C5CFF"),
                        .new(name: "周五", colorHex: "#D1477A"),
                        .new(name: "深度工作", colorHex: "#E0851B")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )

        let beforeCommit = try taskProjection(from: engine.classification(.task(chainID)))
        XCTAssertNil(beforeCommit.category)
        XCTAssertTrue(beforeCommit.labels.isEmpty)
        guard case let .setCurrent(_, _, after) = try XCTUnwrap(plan.changes.first) else {
            return XCTFail("预期当前分类变更预览")
        }
        let plannedCategoryID = try XCTUnwrap(after.category?.id)
        let plannedLabelIDs = Set(try after.labels.map { try XCTUnwrap($0.id) })
        XCTAssertTrue(after.labels.allSatisfy { $0.id != nil })

        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )

        let committed = try taskProjection(from: engine.classification(.task(chainID)))
        XCTAssertEqual(committed.category?.name, "工程")
        XCTAssertEqual(Set(committed.labels.map(\.name)), ["复盘", "客户", "周五", "深度工作"])
        XCTAssertEqual(committed.category?.id, plannedCategoryID)
        XCTAssertEqual(Set(committed.labels.map(\.id)), plannedLabelIDs)
    }

    func testCurrentRelationsPreserveOriginAndAppendRemovalHistory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "关系来源", now: now)
        let source = ClassificationSource.zhulongSuggestion(
            sessionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            draftID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            draftVersion: 3,
            evidenceID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        )
        let decisionID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "项目", colorHex: "#2A6FDB"),
                    labels: [.new(name: "白盒", colorHex: "#0E9488")]
                )
            ),
            source: source,
            interactionID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )

        var state = engine.snapshot().classifications
        let current = try XCTUnwrap(state.currentByChainID[chainID])
        let category = try XCTUnwrap(current.category)
        let label = try XCTUnwrap(current.labels.first)
        XCTAssertEqual(category.source, source)
        XCTAssertEqual(category.decisionID, decisionID)
        XCTAssertEqual(category.createdAt, now)
        XCTAssertEqual(category.revision, 1)
        XCTAssertEqual(label.source, source)
        XCTAssertEqual(label.decisionID, decisionID)

        let removalTime = now.addingTimeInterval(60)
        let removalDecisionID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        let removalPlan = try engine.prepareClassification(
            .setCurrent(TaskClassificationDraft(chainID: chainID, category: nil, labels: [])),
            source: .userDirect,
            interactionID: UUID(uuidString: "10000000-0000-0000-0000-000000000007")!,
            now: removalTime
        )
        _ = try engine.commitClassification(
            removalPlan,
            confirmation: .user(decisionID: removalDecisionID),
            now: removalTime
        )

        state = engine.snapshot().classifications
        XCTAssertNil(state.currentByChainID[chainID]?.category)
        XCTAssertTrue(state.currentByChainID[chainID]?.labels.isEmpty == true)
        XCTAssertEqual(state.relationHistory.count, 2)
        XCTAssertEqual(Set(state.relationHistory.map(\.kind)), [.category, .label])
        XCTAssertTrue(state.relationHistory.allSatisfy { history in
            history.chainID == chainID
                && history.originSource == source
                && history.originDecisionID == decisionID
                && history.removedBySource == .userDirect
                && history.removedByDecisionID == removalDecisionID
                && history.createdRevision == 1
                && history.removedRevision == 2
                && history.removedAt == removalTime
        })
    }

    func testBackdatedCurrentReplacementFailsWithoutPublishingHistory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "拒绝倒序关系", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "当前关系", colorHex: "#2A6FDB"),
                labels: [.new(name: "时间有序", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "10100000-0000-0000-0000-000000000001",
            decisionID: "10100000-0000-0000-0000-000000000002"
        )
        let before = engine.snapshot().classifications
        let plan = try engine.prepareClassification(
            .setCurrent(TaskClassificationDraft(chainID: chainID, category: nil, labels: [])),
            source: .userDirect,
            interactionID: UUID(uuidString: "10100000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(-500)
        )

        XCTAssertThrowsError(
            try engine.commitClassification(
                plan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "10100000-0000-0000-0000-000000000004")!
                ),
                now: now.addingTimeInterval(-500)
            )
        )
        XCTAssertEqual(engine.snapshot().classifications, before)
    }

    func testUserCanCreateUnassignedCategoryAndLabelThroughThePlanSeam() throws {
        let engine = NoonmarkEngine()
        let categoryPlan = try engine.prepareClassification(
            .createCategory(name: "待规划", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "11000000-0000-0000-0000-000000000001")!,
            now: now
        )
        guard case let .create(categoryKind, categoryID, categoryName, _) = try XCTUnwrap(
            categoryPlan.changes.first
        ) else {
            return XCTFail("预期主分类创建预览")
        }
        XCTAssertEqual(categoryKind, .category)
        XCTAssertEqual(categoryName, "待规划")
        XCTAssertNotNil(UUID(uuidString: categoryID))
        _ = try engine.commitClassification(
            categoryPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "11000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )

        let labelPlan = try engine.prepareClassification(
            .createLabel(name: "待确认", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(uuidString: "11000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.commitClassification(
            labelPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "11000000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(1)
        )

        let state = engine.snapshot().classifications
        XCTAssertEqual(state.categories.values.map(\.name), ["待规划"])
        XCTAssertEqual(state.labels.values.map(\.name), ["待确认"])
        XCTAssertTrue(state.currentByChainID.isEmpty)
        XCTAssertTrue(state.relationHistory.isEmpty)
        XCTAssertEqual(state.changeRecords.flatMap(\.changes).count, 2)
    }

    func testCategoryMergePreviewsImpactMigratesCurrentRelationsAndKeepsHistoryFrozen() throws {
        let engine = NoonmarkEngine()
        let sourceChainID = try engine.createPoolTask(title: "来源分类任务", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: sourceChainID,
                category: .new(name: "旧项目", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "12000000-0000-0000-0000-000000000001",
            decisionID: "12000000-0000-0000-0000-000000000002"
        )
        let sourceID = try XCTUnwrap(
            engine.snapshot().classifications.categories.values.first(where: { $0.name == "旧项目" })?.id
        )
        let traceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(30))

        let targetPlan = try engine.prepareClassification(
            .createCategory(name: "统一项目", colorHex: "#7C5CFF"),
            source: .userDirect,
            interactionID: UUID(uuidString: "12000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(40)
        )
        _ = try engine.commitClassification(
            targetPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "12000000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(40)
        )
        let targetID = try XCTUnwrap(
            engine.snapshot().classifications.categories.values.first(where: { $0.name == "统一项目" })?.id
        )
        let historicalBefore = try historyProjection(from: engine.classification(.history(traceID)))

        let mergePlan = try engine.prepareClassification(
            .mergeCategory(source: sourceID, into: targetID),
            source: .userDirect,
            interactionID: UUID(uuidString: "12000000-0000-0000-0000-000000000005")!,
            now: now.addingTimeInterval(60)
        )
        guard case let .merge(kind, previewSourceID, _, previewTargetID, _, sourceLifecycle, impact) = try XCTUnwrap(
            mergePlan.changes.first
        ) else {
            return XCTFail("预期主分类合并预览")
        }
        XCTAssertEqual(kind, .category)
        XCTAssertEqual(previewSourceID, sourceID.description)
        XCTAssertEqual(previewTargetID, targetID.description)
        XCTAssertEqual(sourceLifecycle, .active)
        XCTAssertEqual(impact.currentChainIDs, [sourceChainID])
        XCTAssertEqual(impact.historicalTraceIDs, [traceID])
        XCTAssertEqual(impact.historicalEventIDs.count, 1)
        XCTAssertEqual(impact.migratedRelationCount, 1)
        XCTAssertEqual(impact.deduplicatedRelationCount, 0)

        _ = try engine.commitClassification(
            mergePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "12000000-0000-0000-0000-000000000006")!
            ),
            now: now.addingTimeInterval(60)
        )

        let current = try taskProjection(from: engine.classification(.task(sourceChainID)))
        XCTAssertEqual(current.category?.id, targetID.description)
        XCTAssertEqual(try historyProjection(from: engine.classification(.history(traceID))), historicalBefore)
        let state = engine.snapshot().classifications
        XCTAssertEqual(state.categories[sourceID]?.lifecycle, .merged)
        XCTAssertEqual(state.categoryMerges[sourceID]?.targetID, targetID)
        XCTAssertEqual(state.relationHistory.last?.itemID, sourceID.description)
        guard case let .catalog(catalog) = try engine.classification(.catalog) else {
            return XCTFail("预期分类目录")
        }
        XCTAssertEqual(catalog.categories.first(where: { $0.id == sourceID.description })?.mergedIntoID, targetID.description)
    }

    func testLabelMergeDeduplicatesExistingTargetWithoutReplacingItsOrigin() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(title: "标签迁移", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: firstChainID,
                category: nil,
                labels: [.new(name: "旧标签", colorHex: "#2A6FDB")]
            ),
            to: engine,
            interactionID: "13000000-0000-0000-0000-000000000001",
            decisionID: "13000000-0000-0000-0000-000000000002"
        )
        let sourceID = try XCTUnwrap(
            engine.snapshot().classifications.labels.values.first(where: { $0.name == "旧标签" })?.id
        )
        let targetPlan = try engine.prepareClassification(
            .createLabel(name: "统一标签", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(uuidString: "13000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(10)
        )
        _ = try engine.commitClassification(
            targetPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "13000000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(10)
        )
        let targetID = try XCTUnwrap(
            engine.snapshot().classifications.labels.values.first(where: { $0.name == "统一标签" })?.id
        )
        let secondChainID = try engine.createPoolTask(title: "标签去重", now: now)
        let secondDecisionID = UUID(uuidString: "13000000-0000-0000-0000-000000000005")!
        let secondPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: secondChainID,
                    category: nil,
                    labels: [.existing(sourceID), .existing(targetID)]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "13000000-0000-0000-0000-000000000006")!,
            now: now.addingTimeInterval(20)
        )
        _ = try engine.commitClassification(
            secondPlan,
            confirmation: .user(decisionID: secondDecisionID),
            now: now.addingTimeInterval(20)
        )
        let targetOriginBefore = try XCTUnwrap(
            engine.snapshot().classifications.currentByChainID[secondChainID]?.labels.first(where: {
                $0.labelID == targetID
            })
        )

        let mergePlan = try engine.prepareClassification(
            .mergeLabel(source: sourceID, into: targetID),
            source: .userDirect,
            interactionID: UUID(uuidString: "13000000-0000-0000-0000-000000000007")!,
            now: now.addingTimeInterval(30)
        )
        guard case let .merge(_, _, _, _, _, _, impact) = try XCTUnwrap(mergePlan.changes.first) else {
            return XCTFail("预期标签合并预览")
        }
        XCTAssertEqual(Set(impact.currentChainIDs), [firstChainID, secondChainID])
        XCTAssertEqual(impact.migratedRelationCount, 2)
        XCTAssertEqual(impact.deduplicatedRelationCount, 1)

        _ = try engine.commitClassification(
            mergePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "13000000-0000-0000-0000-000000000008")!
            ),
            now: now.addingTimeInterval(30)
        )

        XCTAssertEqual(
            try taskProjection(from: engine.classification(.task(firstChainID))).labels.map(\.id),
            [targetID.description]
        )
        XCTAssertEqual(
            try taskProjection(from: engine.classification(.task(secondChainID))).labels.map(\.id),
            [targetID.description]
        )
        let state = engine.snapshot().classifications
        XCTAssertEqual(state.labels[sourceID]?.lifecycle, .merged)
        XCTAssertEqual(state.labelMerges[sourceID]?.targetID, targetID)
        XCTAssertEqual(
            state.currentByChainID[secondChainID]?.labels.first(where: { $0.labelID == targetID }),
            targetOriginBefore
        )
        XCTAssertEqual(state.relationHistory.filter { $0.itemID == sourceID.description }.count, 2)
    }

    func testUnusedItemsCanBeHardDeletedAndNamesReusedWithoutRevivingOldIdentity() throws {
        let engine = NoonmarkEngine()
        let createPlan = try engine.prepareClassification(
            .createCategory(name: "临时分类", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "14000000-0000-0000-0000-000000000001")!,
            now: now
        )
        _ = try engine.commitClassification(
            createPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "14000000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let oldID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        try commitIntent(
            .archiveCategory(oldID),
            to: engine,
            interactionID: "14000000-0000-0000-0000-000000000003",
            decisionID: "14000000-0000-0000-0000-000000000004"
        )

        let deletePlan = try engine.prepareClassification(
            .hardDeleteCategory(oldID),
            source: .userDirect,
            interactionID: UUID(uuidString: "14000000-0000-0000-0000-000000000005")!,
            now: now.addingTimeInterval(30)
        )
        guard case let .hardDelete(kind, itemID, name, lifecycle, references) = try XCTUnwrap(
            deletePlan.changes.first
        ) else {
            return XCTFail("预期分类硬删除预览")
        }
        XCTAssertEqual(kind, .category)
        XCTAssertEqual(itemID, oldID.description)
        XCTAssertEqual(name, "临时分类")
        XCTAssertEqual(lifecycle, .archived)
        XCTAssertEqual(references, ClassificationReferenceSummary())
        let receipt = try engine.commitClassification(
            deletePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "14000000-0000-0000-0000-000000000006")!
            ),
            now: now.addingTimeInterval(30)
        )

        var state = engine.snapshot().classifications
        XCTAssertNil(state.categories[oldID])
        XCTAssertEqual(state.categoryDeletionTombstones[oldID]?.changeRecordID, receipt.changeRecordID)
        XCTAssertEqual(state.categoryDeletionTombstones[oldID]?.revision, receipt.revision)

        let recreatePlan = try engine.prepareClassification(
            .createCategory(name: "临时分类", colorHex: "#7C5CFF"),
            source: .userDirect,
            interactionID: UUID(uuidString: "14000000-0000-0000-0000-000000000007")!,
            now: now.addingTimeInterval(60)
        )
        _ = try engine.commitClassification(
            recreatePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "14000000-0000-0000-0000-000000000008")!
            ),
            now: now.addingTimeInterval(60)
        )
        state = engine.snapshot().classifications
        let newID = try XCTUnwrap(state.categories.keys.first)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(state.categories[newID]?.name, "临时分类")

        let chainID = try engine.createPoolTask(title: "禁止复活", now: now)
        XCTAssertThrowsError(
            try engine.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: chainID,
                        category: .existing(oldID),
                        labels: []
                    )
                ),
                source: .userDirect,
                interactionID: UUID(uuidString: "14000000-0000-0000-0000-000000000009")!,
                now: now.addingTimeInterval(70)
            )
        )
    }

    func testHardDeleteRejectsCurrentRelationRelationHistoryAndMergeReferences() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "硬删除引用", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "曾使用", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "15000000-0000-0000-0000-000000000001",
            decisionID: "15000000-0000-0000-0000-000000000002"
        )
        let usedID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        let currentReferencePlan = try engine.prepareClassification(
            .hardDeleteCategory(usedID),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(1)
        )
        guard case let .referencedItem(kind, itemID, currentReferences) = try XCTUnwrap(
            currentReferencePlan.blockers.first
        ) else {
            return XCTFail("预期硬删除引用 blocker")
        }
        XCTAssertEqual(kind, .category)
        XCTAssertEqual(itemID, usedID.description)
        XCTAssertEqual(currentReferences.currentRelationCount, 1)
        XCTAssertThrowsError(
            try engine.commitClassification(
                currentReferencePlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000015")!
                ),
                now: now.addingTimeInterval(1)
            )
        )

        try commit(
            TaskClassificationDraft(chainID: chainID, category: nil, labels: []),
            to: engine,
            interactionID: "15000000-0000-0000-0000-000000000004",
            decisionID: "15000000-0000-0000-0000-000000000005"
        )
        let historyReferencePlan = try engine.prepareClassification(
            .hardDeleteCategory(usedID),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000006")!,
            now: now.addingTimeInterval(2)
        )
        guard case let .referencedItem(_, _, historyReferences) = try XCTUnwrap(
            historyReferencePlan.blockers.first
        ) else {
            return XCTFail("预期关系历史 blocker")
        }
        XCTAssertEqual(historyReferences.currentRelationCount, 0)
        XCTAssertEqual(historyReferences.relationHistoryCount, 1)
        XCTAssertThrowsError(
            try engine.commitClassification(
                historyReferencePlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000016")!
                ),
                now: now.addingTimeInterval(2)
            )
        )

        let sourcePlan = try engine.prepareClassification(
            .createCategory(name: "合并来源", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000007")!,
            now: now.addingTimeInterval(3)
        )
        _ = try engine.commitClassification(
            sourcePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000008")!
            ),
            now: now.addingTimeInterval(3)
        )
        let targetPlan = try engine.prepareClassification(
            .createCategory(name: "合并目标", colorHex: "#7C5CFF"),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000009")!,
            now: now.addingTimeInterval(4)
        )
        _ = try engine.commitClassification(
            targetPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000010")!
            ),
            now: now.addingTimeInterval(4)
        )
        let state = engine.snapshot().classifications
        let sourceID = try XCTUnwrap(state.categories.values.first(where: { $0.name == "合并来源" })?.id)
        let targetID = try XCTUnwrap(state.categories.values.first(where: { $0.name == "合并目标" })?.id)
        let mergePlan = try engine.prepareClassification(
            .mergeCategory(source: sourceID, into: targetID),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000011")!,
            now: now.addingTimeInterval(5)
        )
        _ = try engine.commitClassification(
            mergePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000012")!
            ),
            now: now.addingTimeInterval(5)
        )
        XCTAssertThrowsError(
            try engine.prepareClassification(
                .hardDeleteCategory(sourceID),
                source: .userDirect,
                interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000013")!,
                now: now.addingTimeInterval(6)
            )
        )
        let targetReferencePlan = try engine.prepareClassification(
            .hardDeleteCategory(targetID),
            source: .userDirect,
            interactionID: UUID(uuidString: "15000000-0000-0000-0000-000000000014")!,
            now: now.addingTimeInterval(6)
        )
        guard case let .referencedItem(_, _, targetReferences) = try XCTUnwrap(
            targetReferencePlan.blockers.first
        ) else {
            return XCTFail("预期合并目标 blocker")
        }
        XCTAssertEqual(targetReferences.mergeTargetCount, 1)
        XCTAssertThrowsError(
            try engine.commitClassification(
                targetReferencePlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "15000000-0000-0000-0000-000000000017")!
                ),
                now: now.addingTimeInterval(6)
            )
        )
    }

    func testHardDeleteAndDecodeRejectDivergentLatestAndEventHistory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "历史引用不能绕过", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        let createPlan = try engine.prepareClassification(
            .createCategory(name: "历史仍引用", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "15010000-0000-0000-0000-000000000001")!,
            now: now
        )
        _ = try engine.commitClassification(
            createPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "15010000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        var snapshot = engine.snapshot()
        let category = try XCTUnwrap(snapshot.classifications.categories.values.first)
        let latest = TraceClassificationSnapshot(
            traceID: traceID,
            status: .completed,
            category: HistoricalCategoryValue(
                id: category.id,
                name: category.name,
                colorHex: category.colorHex
            ),
            labels: [],
            capturedAt: now,
            revision: snapshot.classifications.revision
        )
        let unrelatedEvent = TraceClassificationSnapshot(
            traceID: traceID,
            status: .completed,
            category: nil,
            labels: [],
            capturedAt: now,
            revision: snapshot.classifications.revision
        )
        snapshot.classifications.snapshotsByTraceID[traceID] = latest
        snapshot.classifications.snapshotEventsByTraceID[traceID] = [unrelatedEvent]

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(snapshot.classifications)
            )
        )
        XCTAssertThrowsError(try NoonmarkEngine(snapshot: snapshot))
    }

    func testCategoryMergeSupportsAChainWhoseFinalTargetRemainsActive() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "多跳合并", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "分类 A", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "15100000-0000-0000-0000-000000000001",
            decisionID: "15100000-0000-0000-0000-000000000002"
        )
        for (name, colorHex, suffix) in [
            ("分类 B", "#0E9488", "3"),
            ("分类 C", "#7C5CFF", "5")
        ] {
            let plan = try engine.prepareClassification(
                .createCategory(name: name, colorHex: colorHex),
                source: .userDirect,
                interactionID: UUID(uuidString: "15100000-0000-0000-0000-00000000000\(suffix)")!,
                now: now
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .user(
                    decisionID: UUID(
                        uuidString: "15100000-0000-0000-0000-00000000000\(Int(suffix)! + 1)"
                    )!
                ),
                now: now
            )
        }
        let initial = engine.snapshot().classifications
        let aID = try XCTUnwrap(initial.categories.values.first(where: { $0.name == "分类 A" })?.id)
        let bID = try XCTUnwrap(initial.categories.values.first(where: { $0.name == "分类 B" })?.id)
        let cID = try XCTUnwrap(initial.categories.values.first(where: { $0.name == "分类 C" })?.id)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day1,
            today: day1,
            now: now
        )
        try engine.settleDays(upTo: day2, now: now)

        try commitIntent(
            .mergeCategory(source: aID, into: bID),
            to: engine,
            interactionID: "15100000-0000-0000-0000-000000000007",
            decisionID: "15100000-0000-0000-0000-000000000008"
        )
        let secondMergePlan = try engine.prepareClassification(
            .mergeCategory(source: bID, into: cID),
            source: .userDirect,
            interactionID: UUID(uuidString: "15100000-0000-0000-0000-000000000009")!,
            now: now
        )
        guard case let .merge(_, _, _, _, _, _, impact) = try XCTUnwrap(secondMergePlan.changes.first) else {
            return XCTFail("预期第二次分类合并预览")
        }
        XCTAssertEqual(impact.historicalTraceIDs, [traceID])
        XCTAssertEqual(impact.historicalEventIDs.count, 1)
        _ = try engine.commitClassification(
            secondMergePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "15100000-0000-0000-0000-000000000010")!
            ),
            now: now
        )

        let state = engine.snapshot().classifications
        XCTAssertEqual(state.categoryMerges[aID]?.targetID, bID)
        XCTAssertEqual(state.categoryMerges[bID]?.targetID, cID)
        XCTAssertEqual(state.categories[aID]?.lifecycle, .merged)
        XCTAssertEqual(state.categories[bID]?.lifecycle, .merged)
        XCTAssertEqual(state.categories[cID]?.lifecycle, .active)
        XCTAssertEqual(state.currentByChainID[chainID]?.categoryID, cID)
        guard case let .catalog(catalog) = try engine.classification(.catalog) else {
            return XCTFail("预期分类目录")
        }
        XCTAssertEqual(catalog.categories.first(where: { $0.id == aID.description })?.mergedIntoID, cID.description)
        XCTAssertEqual(catalog.categories.first(where: { $0.id == bID.description })?.mergedIntoID, cID.description)
        XCTAssertEqual(catalog.categories.first(where: { $0.id == cID.description })?.historicalUsageCount, 1)
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(state)
            )
        )
    }

    func testMergeAcceptsArchivedSourceButRejectsArchivedTarget() throws {
        let engine = NoonmarkEngine()
        for (name, colorHex, suffix) in [
            ("已归档来源", "#2A6FDB", "1"),
            ("有效目标", "#0E9488", "3"),
            ("已归档目标", "#7C5CFF", "5")
        ] {
            let plan = try engine.prepareClassification(
                .createCategory(name: name, colorHex: colorHex),
                source: .userDirect,
                interactionID: UUID(uuidString: "15200000-0000-0000-0000-00000000000\(suffix)")!,
                now: now
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .user(
                    decisionID: UUID(
                        uuidString: "15200000-0000-0000-0000-00000000000\(Int(suffix)! + 1)"
                    )!
                ),
                now: now
            )
        }
        let initial = engine.snapshot().classifications
        let sourceID = try XCTUnwrap(
            initial.categories.values.first(where: { $0.name == "已归档来源" })?.id
        )
        let activeTargetID = try XCTUnwrap(
            initial.categories.values.first(where: { $0.name == "有效目标" })?.id
        )
        let archivedTargetID = try XCTUnwrap(
            initial.categories.values.first(where: { $0.name == "已归档目标" })?.id
        )
        try commitIntent(
            .archiveCategory(sourceID),
            to: engine,
            interactionID: "15200000-0000-0000-0000-000000000007",
            decisionID: "15200000-0000-0000-0000-000000000008"
        )
        try commitIntent(
            .archiveCategory(archivedTargetID),
            to: engine,
            interactionID: "15200000-0000-0000-0000-000000000009",
            decisionID: "15200000-0000-0000-0000-000000000010"
        )

        XCTAssertThrowsError(
            try engine.prepareClassification(
                .mergeCategory(source: sourceID, into: archivedTargetID),
                source: .userDirect,
                interactionID: UUID(uuidString: "15200000-0000-0000-0000-000000000011")!,
                now: now.addingTimeInterval(11)
            )
        )
        try commitIntent(
            .mergeCategory(source: sourceID, into: activeTargetID),
            to: engine,
            interactionID: "15200000-0000-0000-0000-000000000012",
            decisionID: "15200000-0000-0000-0000-000000000013"
        )
        XCTAssertEqual(engine.snapshot().classifications.categoryMerges[sourceID]?.targetID, activeTargetID)
    }

    func testMergeTargetCannotBeArchivedWhileItTerminatesAnIncomingMerge() throws {
        let engine = NoonmarkEngine()
        for (name, suffix) in [("合并来源", "1"), ("合并终点", "3")] {
            let plan = try engine.prepareClassification(
                .createCategory(name: name, colorHex: "#2A6FDB"),
                source: .userDirect,
                interactionID: UUID(uuidString: "15300000-0000-0000-0000-00000000000\(suffix)")!,
                now: now
            )
            _ = try engine.commitClassification(
                plan,
                confirmation: .user(
                    decisionID: UUID(
                        uuidString: "15300000-0000-0000-0000-00000000000\(Int(suffix)! + 1)"
                    )!
                ),
                now: now
            )
        }
        let state = engine.snapshot().classifications
        let sourceID = try XCTUnwrap(
            state.categories.values.first(where: { $0.name == "合并来源" })?.id
        )
        let targetID = try XCTUnwrap(
            state.categories.values.first(where: { $0.name == "合并终点" })?.id
        )
        try commitIntent(
            .mergeCategory(source: sourceID, into: targetID),
            to: engine,
            interactionID: "15300000-0000-0000-0000-000000000005",
            decisionID: "15300000-0000-0000-0000-000000000006"
        )

        XCTAssertThrowsError(
            try engine.prepareClassification(
                .archiveCategory(targetID),
                source: .userDirect,
                interactionID: UUID(uuidString: "15300000-0000-0000-0000-000000000007")!,
                now: now
            )
        )
        XCTAssertEqual(engine.snapshot().classifications.categories[targetID]?.lifecycle, .active)
    }

    func testClassificationStateDecodeRejectsMergeCyclesAndMergedItemsWithoutEdges() throws {
        let firstID = TaskCategoryID(
            UUID(uuidString: "16000000-0000-0000-0000-000000000001")!
        )
        let secondID = TaskCategoryID(
            UUID(uuidString: "16000000-0000-0000-0000-000000000002")!
        )
        var first = TaskCategory(id: firstID, name: "一", colorHex: "#2A6FDB", now: now)
        var second = TaskCategory(id: secondID, name: "二", colorHex: "#0E9488", now: now)
        first.lifecycle = .merged
        second.lifecycle = .merged
        let changeRecordID = UUID(uuidString: "16000000-0000-0000-0000-000000000003")!
        let cycle = TaskClassificationState(
            categories: [firstID: first, secondID: second],
            categoryMerges: [
                firstID: TaskCategoryMerge(
                    sourceID: firstID,
                    targetID: secondID,
                    mergedAt: now,
                    revision: 1,
                    changeRecordID: changeRecordID
                ),
                secondID: TaskCategoryMerge(
                    sourceID: secondID,
                    targetID: firstID,
                    mergedAt: now,
                    revision: 2,
                    changeRecordID: changeRecordID
                )
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(cycle)
            )
        )

        let missingEdge = TaskClassificationState(categories: [firstID: first])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(missingEdge)
            )
        )
    }

    func testClassificationStateDecodeRejectsDanglingCurrentRelations() throws {
        let chainID = TaskChainID(
            UUID(uuidString: "16100000-0000-0000-0000-000000000001")!
        )
        let missingCategoryID = TaskCategoryID(
            UUID(uuidString: "16100000-0000-0000-0000-000000000002")!
        )
        let danglingCategory = TaskClassificationState(
            currentByChainID: [
                chainID: CurrentTaskClassification(
                    category: TaskCategoryRelation(
                        categoryID: missingCategoryID,
                        source: .deterministicDomainAction(reason: "构造悬空分类关系"),
                        decisionID: nil,
                        createdAt: now,
                        updatedAt: now,
                        revision: 0
                    ),
                    labels: []
                )
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(danglingCategory)
            )
        )

        let missingLabelID = TaskLabelID(
            UUID(uuidString: "16100000-0000-0000-0000-000000000003")!
        )
        let danglingLabel = TaskClassificationState(
            currentByChainID: [
                chainID: CurrentTaskClassification(
                    category: nil,
                    labels: [
                        TaskLabelRelation(
                            labelID: missingLabelID,
                            source: .deterministicDomainAction(reason: "构造悬空标签关系"),
                            decisionID: nil,
                            createdAt: now,
                            updatedAt: now,
                            revision: 0
                        )
                    ]
                )
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(danglingLabel)
            )
        )
    }

    func testClassificationStateDecodeRejectsMismatchedIdentityKeysAndDuplicateNames() throws {
        let categoryID = TaskCategoryID(
            UUID(uuidString: "16200000-0000-0000-0000-000000000001")!
        )
        let wrongKey = TaskCategoryID(
            UUID(uuidString: "16200000-0000-0000-0000-000000000002")!
        )
        let category = TaskCategory(
            id: categoryID,
            name: "唯一身份",
            colorHex: "#2A6FDB",
            now: now
        )
        let mismatchedKey = TaskClassificationState(categories: [wrongKey: category])
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(mismatchedKey)
            )
        )

        let duplicateID = TaskCategoryID(
            UUID(uuidString: "16200000-0000-0000-0000-000000000003")!
        )
        let duplicateName = TaskClassificationState(
            categories: [
                categoryID: TaskCategory(
                    id: categoryID,
                    name: "ＡＢＣ",
                    colorHex: "#2A6FDB",
                    now: now
                ),
                duplicateID: TaskCategory(
                    id: duplicateID,
                    name: "abc",
                    colorHex: "#0E9488",
                    now: now
                )
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(duplicateName)
            )
        )
    }

    func testClassificationStateDecodeRejectsManagementFactsWithoutMatchingAuditChange() throws {
        let sourceID = TaskCategoryID(
            UUID(uuidString: "16300000-0000-0000-0000-000000000001")!
        )
        let targetID = TaskCategoryID(
            UUID(uuidString: "16300000-0000-0000-0000-000000000002")!
        )
        var source = TaskCategory(id: sourceID, name: "来源", colorHex: "#2A6FDB", now: now)
        source.lifecycle = .merged
        let target = TaskCategory(id: targetID, name: "目标", colorHex: "#0E9488", now: now)
        let unrelatedRecord = ClassificationChangeRecord(
            id: UUID(uuidString: "16300000-0000-0000-0000-000000000003")!,
            planID: UUID(uuidString: "16300000-0000-0000-0000-000000000004")!,
            interactionID: UUID(uuidString: "16300000-0000-0000-0000-000000000005")!,
            source: .deterministicDomainAction(reason: "不相关审计记录"),
            decisionID: nil,
            changes: [
                .create(
                    kind: .category,
                    itemID: targetID.description,
                    name: target.name,
                    colorHex: target.colorHex
                )
            ],
            notices: [],
            committedAt: now,
            revision: 1,
            planDigest: String(repeating: "a", count: 64)
        )
        let unbackedMerge = TaskClassificationState(
            revision: 1,
            categories: [sourceID: source, targetID: target],
            categoryMerges: [
                sourceID: TaskCategoryMerge(
                    sourceID: sourceID,
                    targetID: targetID,
                    mergedAt: now,
                    revision: 1,
                    changeRecordID: unrelatedRecord.id
                )
            ],
            changeRecords: [unrelatedRecord]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(unbackedMerge)
            )
        )

        let deletedID = TaskLabelID(
            UUID(uuidString: "16300000-0000-0000-0000-000000000007")!
        )
        let missingRecordTombstone = TaskClassificationState(
            revision: 1,
            labelDeletionTombstones: [
                deletedID: TaskLabelDeletionTombstone(
                    itemID: deletedID,
                    deletedAt: now,
                    revision: 1,
                    changeRecordID: UUID(uuidString: "16300000-0000-0000-0000-000000000008")!
                )
            ]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(missingRecordTombstone)
            )
        )
    }

    func testClassificationStateDecodeRejectsReceiptThatDoesNotMatchCurrentChangeRecord() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "回执对账", now: now)
        let interactionID = UUID(uuidString: "16400000-0000-0000-0000-000000000001")!
        let decisionID = UUID(uuidString: "16400000-0000-0000-0000-000000000002")!
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "回执", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now
        )
        var malformed = engine.snapshot().classifications
        malformed.committedReceiptsByInteractionID[interactionID] = ClassificationReceipt(
            planID: receipt.planID,
            revision: receipt.revision,
            notices: receipt.notices,
            changeRecordID: UUID(uuidString: "16400000-0000-0000-0000-000000000003")!,
            decisionID: decisionID,
            changeRecordIntegrityDigest: receipt.changeRecordIntegrityDigest
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(malformed)
            )
        )
    }

    func testCurrentClassificationStateDecodeRejectsMissingRelationHistory() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "历史字段不可静默丢失", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "历史分类", colorHex: "#2A6FDB"),
                labels: [.new(name: "曾使用", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "16500000-0000-0000-0000-000000000001",
            decisionID: "16500000-0000-0000-0000-000000000002"
        )
        let categoryID = try XCTUnwrap(
            engine.snapshot().classifications.currentByChainID[chainID]?.categoryID
        )
        let removalPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .existing(categoryID),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "16500000-0000-0000-0000-000000000003")!,
            now: now.addingTimeInterval(1)
        )
        _ = try engine.commitClassification(
            removalPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "16500000-0000-0000-0000-000000000004")!
            ),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(engine.snapshot().classifications.relationHistory.count, 1)

        let data = try JSONEncoder().encode(engine.snapshot().classifications)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "relationHistory")

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testClassificationStateDecodeRejectsUnconfirmedZhulongRelation() throws {
        let chainID = TaskChainID(
            UUID(uuidString: "16600000-0000-0000-0000-000000000001")!
        )
        let category = TaskCategory(
            id: TaskCategoryID(
                UUID(uuidString: "16600000-0000-0000-0000-000000000002")!
            ),
            name: "未经确认",
            colorHex: "#2A6FDB",
            now: now
        )
        let malformed = TaskClassificationState(
            categories: [category.id: category],
            currentByChainID: [
                chainID: CurrentTaskClassification(
                    category: TaskCategoryRelation(
                        categoryID: category.id,
                        source: .zhulongSuggestion(
                            sessionID: UUID(uuidString: "16600000-0000-0000-0000-000000000003")!,
                            draftID: UUID(uuidString: "16600000-0000-0000-0000-000000000004")!,
                            draftVersion: 1,
                            evidenceID: UUID(uuidString: "16600000-0000-0000-0000-000000000005")!
                        ),
                        decisionID: nil,
                        createdAt: now,
                        updatedAt: now,
                        revision: 0
                    ),
                    labels: []
                )
            ]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONEncoder().encode(malformed)
            )
        )
    }

    func testClassificationStateDecodeRejectsForgedChangeRecordContents() throws {
        let engine = NoonmarkEngine()
        let plan = try engine.prepareClassification(
            .createCategory(name: "真实审计", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "16800000-0000-0000-0000-000000000001")!,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "16800000-0000-0000-0000-000000000002")!
            ),
            now: now
        )

        let data = try JSONEncoder().encode(engine.snapshot().classifications)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var records = try XCTUnwrap(object["changeRecords"] as? [[String: Any]])
        records[0]["changes"] = []
        object["changeRecords"] = records

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                TaskClassificationState.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testEngineRestoreRejectsClassificationReferencesToMissingTodoEntities() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "外部引用完整性", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "引用", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "16900000-0000-0000-0000-000000000001",
            decisionID: "16900000-0000-0000-0000-000000000002"
        )
        var snapshot = engine.snapshot()
        snapshot.chains.removeAll()
        snapshot.definitions.removeAll()

        XCTAssertThrowsError(try NoonmarkEngine(snapshot: snapshot))
    }

    func testHistoricalTraceKeepsItsClassificationAfterCurrentClassificationChanges() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "完成阅读计划", now: now)

        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "阅读", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "11111111-1111-1111-1111-111111111111",
            decisionID: "22222222-2222-2222-2222-222222222222"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "健康", colorHex: "#D1477A"),
                labels: [.new(name: "运动", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "33333333-3333-3333-3333-333333333333",
            decisionID: "44444444-4444-4444-4444-444444444444"
        )

        let current = try taskProjection(from: engine.classification(.task(chainID)))
        XCTAssertEqual(current.category?.name, "健康")
        XCTAssertEqual(current.labels.map(\.name), ["运动"])

        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "工作")
        XCTAssertEqual(historical.labels.map(\.name), ["阅读"])
    }

    func testUndoableCompletionFreezesClassificationOnlyWhenTheDayBecomesHistorical() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "可撤销完成", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "完成前", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "55556666-7777-8888-9999-AAAABBBBCCCC",
            decisionID: "66667777-8888-9999-AAAA-BBBBCCCCDDDD"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.markCompleted(traceID: traceID, today: day1, now: now)
        XCTAssertThrowsError(try engine.classification(.history(traceID)))
        try engine.undoCompleted(traceID: traceID, today: day1, now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "最终完成", colorHex: "#D1477A"),
                labels: []
            ),
            to: engine,
            interactionID: "77778888-9999-AAAA-BBBB-CCCCDDDDEEEE",
            decisionID: "88889999-AAAA-BBBB-CCCC-DDDDEEEEFFFF"
        )
        try engine.markCompleted(traceID: traceID, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now.addingTimeInterval(120))

        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "最终完成")
        XCTAssertEqual(historical.events.count, 1)
        XCTAssertEqual(historical.events.first?.status, .completed)
    }

    func testReturningCurrentTraceToPoolFreezesItsClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "退回任务池", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "稍后处理", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "10101010-1010-1010-1010-101010101010",
            decisionID: "20202020-2020-2020-2020-202020202020"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.returnToPool(traceID: traceID, today: day1, now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "个人", colorHex: "#D1477A"),
                labels: [.new(name: "待整理", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "30303030-3030-3030-3030-303030303030",
            decisionID: "40404040-4040-4040-4040-404040404040"
        )

        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "工作")
        XCTAssertEqual(historical.labels.map(\.name), ["稍后处理"])
    }

    func testContinuingCurrentTraceFreezesSourceClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "延续任务", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "项目", colorHex: "#2A6FDB"),
                labels: [.new(name: "第一阶段", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "50505050-5050-5050-5050-505050505050",
            decisionID: "60606060-6060-6060-6060-606060606060"
        )
        let sourceTraceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        _ = try engine.deferCurrentTrace(
            traceID: sourceTraceID,
            targetDate: day2,
            today: day1,
            now: now
        )
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "维护", colorHex: "#D1477A"),
                labels: [.new(name: "第二阶段", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "70707070-7070-7070-7070-707070707070",
            decisionID: "80808080-8080-8080-8080-808080808080"
        )

        let historical = try historyProjection(from: engine.classification(.history(sourceTraceID)))
        XCTAssertEqual(historical.category?.name, "项目")
        XCTAssertEqual(historical.labels.map(\.name), ["第一阶段"])
    }

    func testAbandoningCurrentChainFreezesItsTraceClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "放弃任务", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "实验", colorHex: "#2A6FDB"),
                labels: [.new(name: "停止", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "90909090-9090-9090-9090-909090909090",
            decisionID: "A0A0A0A0-A0A0-A0A0-A0A0-A0A0A0A0A0A0"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)

        try engine.abandonChain(from: traceID, now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "归档", colorHex: "#D1477A"),
                labels: [.new(name: "已复核", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "B0B0B0B0-B0B0-B0B0-B0B0-B0B0B0B0B0B0",
            decisionID: "C0C0C0C0-C0C0-C0C0-C0C0-C0C0C0C0C0C0"
        )

        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "实验")
        XCTAssertEqual(historical.labels.map(\.name), ["停止"])
    }

    func testReactivatedTraceAppendsClassificationHistoryWithoutOverwritingAbandonment() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "重新启用任务", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "第一次", colorHex: "#2A6FDB"),
                labels: [.new(name: "暂停", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "11112222-3333-4444-5555-666677778888",
            decisionID: "22223333-4444-5555-6666-777788889999"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.abandonChain(from: traceID, now: now)

        let reactivatedTraceID = try engine.reactivateAbandonedChain(
            from: traceID,
            today: day1,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(reactivatedTraceID, traceID)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "第二次", colorHex: "#D1477A"),
                labels: [.new(name: "再次暂停", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "33334444-5555-6666-7777-88889999AAAA",
            decisionID: "44445555-6666-7777-8888-9999AAAABBBB"
        )
        try engine.abandonChain(from: traceID, now: now.addingTimeInterval(120))

        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "第二次")
        XCTAssertEqual(historical.events.map { $0.category?.name }, ["第一次", "第二次"])
        XCTAssertEqual(historical.events.map(\.status), [.abandoned, .abandoned])
    }

    func testChangingTaskFreezesOldTraceAndInheritsCurrentClassificationToNewChain() throws {
        let engine = NoonmarkEngine()
        let oldChainID = try engine.createPoolTask(title: "整理发布说明", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: oldChainID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "复盘", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "55555555-5555-5555-5555-555555555555",
            decisionID: "66666666-6666-6666-6666-666666666666"
        )
        let oldTraceID = try engine.scheduleFromPool(chainID: oldChainID, date: day1, today: day1, now: now)

        let newTraceID = try engine.changeTrace(
            traceID: oldTraceID,
            newTitle: "重写发布说明",
            today: day1,
            now: now
        )
        let newChainID = try XCTUnwrap(engine.traces[newTraceID]?.chainID)

        let oldHistory = try historyProjection(from: engine.classification(.history(oldTraceID)))
        XCTAssertEqual(oldHistory.category?.name, "工作")
        XCTAssertEqual(oldHistory.labels.map(\.name), ["复盘"])

        let inherited = try taskProjection(from: engine.classification(.task(newChainID)))
        XCTAssertEqual(inherited.category?.name, "工作")
        XCTAssertEqual(inherited.labels.map(\.name), ["复盘"])
        XCTAssertThrowsError(try engine.classification(.history(newTraceID)))
    }

    func testCopyingTaskInheritsCurrentClassification() throws {
        let engine = NoonmarkEngine()
        let sourceChainID = try engine.createPoolTask(title: "复制模板", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: sourceChainID,
                category: .new(name: "模板", colorHex: "#2A6FDB"),
                labels: [
                    .new(name: "可复用", colorHex: "#0E9488"),
                    .new(name: "每周", colorHex: "#7C5CFF")
                ]
            ),
            to: engine,
            interactionID: "D0D0D0D0-D0D0-D0D0-D0D0-D0D0D0D0D0D0",
            decisionID: "E0E0E0E0-E0E0-E0E0-E0E0-E0E0E0E0E0E0"
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: day1,
            today: day1,
            now: now
        )

        let copiedChainID = try engine.copyAsNewTask(
            from: sourceTraceID,
            target: .taskPool,
            today: day1,
            now: now
        )

        let copied = try taskProjection(from: engine.classification(.task(copiedChainID)))
        XCTAssertEqual(copied.category?.name, "模板")
        XCTAssertEqual(Set(copied.labels.map(\.name)), ["可复用", "每周"])
        let inheritanceRecord = try XCTUnwrap(engine.snapshot().classifications.changeRecords.last)
        XCTAssertEqual(inheritanceRecord.source, .inherited(fromChainID: sourceChainID))
        XCTAssertNil(inheritanceRecord.decisionID)
        XCTAssertEqual(inheritanceRecord.planDigest.count, 64)
    }

    func testRenamingCategoryKeepsIdentityHistoryAndReservesTheOldName() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "分类改名", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "健身", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "9999AAAA-BBBB-CCCC-DDDD-EEEEFFFF0000",
            decisionID: "AAAA0000-BBBB-CCCC-DDDD-EEEEFFFF1111"
        )
        let categoryID = try XCTUnwrap(engine.snapshot().classifications.categories.keys.first)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        let renamePlan = try engine.prepareClassification(
            .renameCategory(categoryID, to: "运动"),
            source: .userDirect,
            interactionID: UUID(uuidString: "BBBB1111-CCCC-DDDD-EEEE-FFFF00002222")!,
            now: now.addingTimeInterval(60)
        )
        _ = try engine.commitClassification(
            renamePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "CCCC2222-DDDD-EEEE-FFFF-000011113333")!
            ),
            now: now.addingTimeInterval(60)
        )

        let current = try taskProjection(from: engine.classification(.task(chainID)))
        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(current.category?.id, categoryID.description)
        XCTAssertEqual(current.category?.name, "运动")
        XCTAssertEqual(historical.category?.name, "健身")

        let secondChainID = try engine.createPoolTask(title: "旧名称解析", now: now)
        let aliasPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: secondChainID,
                    category: .new(name: "  健身  ", colorHex: "#D1477A"),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "DDDD3333-EEEE-FFFF-0000-111122224444")!,
            now: now
        )
        XCTAssertEqual(
            aliasPlan.notices,
            [
                .existingItemReused(
                    kind: .category,
                    inputName: "健身",
                    currentName: "运动",
                    matchedHistoricalAlias: true
                )
            ]
        )
        _ = try engine.commitClassification(
            aliasPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "EEEE4444-FFFF-0000-1111-222233335555")!
            ),
            now: now
        )
        let reused = try taskProjection(from: engine.classification(.task(secondChainID)))
        XCTAssertEqual(reused.category?.id, categoryID.description)
        XCTAssertEqual(engine.snapshot().classifications.categories.count, 1)
    }

    func testExactRenameNoOpKeepsRevisionAndBackdatedRenameFailsClosed() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "改名时间顺序", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "工程", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "10112222-3333-4444-5555-666677778889",
            decisionID: "20223333-4444-5555-6666-777788889990"
        )
        let before = engine.snapshot().classifications
        let categoryID = try XCTUnwrap(before.categories.keys.first)

        let noOpPlan = try engine.prepareClassification(
            .renameCategory(categoryID, to: "工程"),
            source: .userDirect,
            interactionID: UUID(uuidString: "30334444-5555-6666-7777-88889999AAA1")!,
            now: now.addingTimeInterval(1)
        )
        let noOpReceipt = try engine.commitClassification(
            noOpPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "40445555-6666-7777-8888-9999AAAABBB2")!
            ),
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(noOpReceipt.revision, before.revision)
        let afterNoOp = engine.snapshot().classifications
        XCTAssertEqual(afterNoOp.categories[categoryID]?.nameVersions.count, 1)
        XCTAssertEqual(afterNoOp.changeRecords.count, before.changeRecords.count + 1)
        XCTAssertFalse(try XCTUnwrap(afterNoOp.changeRecords.last).advancesStateRevision)
        try afterNoOp.validateIntegrity()

        let backdatedPlan = try engine.prepareClassification(
            .renameCategory(categoryID, to: "平台工程"),
            source: .userDirect,
            interactionID: UUID(uuidString: "50556666-7777-8888-9999-AAAABBBBCCC3")!,
            now: now
        )
        XCTAssertThrowsError(
            try engine.commitClassification(
                backdatedPlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "60667777-8888-9999-AAAA-BBBBCCCCDDD4")!
                ),
                now: now.addingTimeInterval(-1)
            )
        )
        XCTAssertEqual(engine.snapshot().classifications.categories[categoryID]?.name, "工程")
    }

    func testLocalNoOpCommitUsesCanonicalAuditInsertion() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "审计排序", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "工程", colorHex: "#2A6FDB"),
                labels: []
            ),
            to: engine,
            interactionID: "13100000-0000-0000-0000-000000000001",
            decisionID: "23100000-0000-0000-0000-000000000001"
        )
        let before = engine.snapshot().classifications
        let originalRecordID = try XCTUnwrap(before.changeRecords.first?.id)
        let categoryID = try XCTUnwrap(before.categories.keys.first)
        let earlier = now.addingTimeInterval(-60)
        let plan = try engine.prepareClassification(
            .renameCategory(categoryID, to: "工程"),
            source: .userDirect,
            interactionID: UUID(uuidString: "33100000-0000-0000-0000-000000000001")!,
            now: earlier
        )

        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "43100000-0000-0000-0000-000000000001")!
            ),
            now: earlier
        )

        let state = engine.snapshot().classifications
        XCTAssertEqual(state.revision, before.revision)
        XCTAssertEqual(
            state.changeRecords.map(\.id),
            [receipt.changeRecordID, originalRecordID]
        )
        try state.validateIntegrity()
    }

    func testNoOpAuditRecordsCanonicalizeIndependentlyOfInsertionOrder() throws {
        let first = noOpRenameRecord(
            id: "10000000-0000-0000-0000-000000000001",
            planID: "20000000-0000-0000-0000-000000000001",
            interactionID: "30000000-0000-0000-0000-000000000001"
        )
        let second = noOpRenameRecord(
            id: "10000000-0000-0000-0000-000000000002",
            planID: "20000000-0000-0000-0000-000000000002",
            interactionID: "30000000-0000-0000-0000-000000000002"
        )

        let forward = try ClassificationAuditCanonicalOrder.changeRecords([first, second])
        let reverse = try ClassificationAuditCanonicalOrder.changeRecords([second, first])

        XCTAssertEqual(forward, [first, second])
        XCTAssertEqual(reverse, forward)
    }

    func testRelationHistoryCanonicalizesIndependentlyOfInsertionOrder() throws {
        let category = relationHistoryEntry(
            id: "50000000-0000-0000-0000-000000000002",
            kind: .category,
            chainID: "60000000-0000-0000-0000-000000000001",
            itemID: "70000000-0000-0000-0000-000000000001"
        )
        let label = relationHistoryEntry(
            id: "50000000-0000-0000-0000-000000000001",
            kind: .label,
            chainID: "60000000-0000-0000-0000-000000000001",
            itemID: "70000000-0000-0000-0000-000000000001"
        )

        let forward = try ClassificationAuditCanonicalOrder.relationHistory([category, label])
        let reverse = try ClassificationAuditCanonicalOrder.relationHistory([label, category])

        XCTAssertEqual(forward, [category, label])
        XCTAssertEqual(reverse, forward)
    }

    func testClassificationStateRejectsNonCanonicalAuditArrays() throws {
        let first = noOpRenameRecord(
            id: "11000000-0000-0000-0000-000000000001",
            planID: "21000000-0000-0000-0000-000000000001",
            interactionID: "31000000-0000-0000-0000-000000000001"
        )
        let second = noOpRenameRecord(
            id: "11000000-0000-0000-0000-000000000002",
            planID: "21000000-0000-0000-0000-000000000002",
            interactionID: "31000000-0000-0000-0000-000000000002"
        )
        let state = TaskClassificationState(changeRecords: [second, first])

        XCTAssertThrowsError(try state.validateIntegrity()) { error in
            XCTAssertTrue(
                decodingErrorDescription(error).contains(
                    "classification change records are not in canonical order"
                )
            )
        }

        let encoded = try JSONEncoder().encode(state)
        XCTAssertThrowsError(
            try JSONDecoder().decode(TaskClassificationState.self, from: encoded)
        ) { error in
            XCTAssertTrue(
                decodingErrorDescription(error).contains(
                    "classification change records are not in canonical order"
                )
            )
        }

        let category = relationHistoryEntry(
            id: "51000000-0000-0000-0000-000000000002",
            kind: .category,
            chainID: "61000000-0000-0000-0000-000000000001",
            itemID: "71000000-0000-0000-0000-000000000001"
        )
        let label = relationHistoryEntry(
            id: "51000000-0000-0000-0000-000000000001",
            kind: .label,
            chainID: "61000000-0000-0000-0000-000000000001",
            itemID: "71000000-0000-0000-0000-000000000001"
        )
        let historyState = TaskClassificationState(relationHistory: [label, category])
        XCTAssertThrowsError(try historyState.validateIntegrity()) { error in
            XCTAssertTrue(
                decodingErrorDescription(error).contains(
                    "classification relation history is not in canonical order"
                )
            )
        }

        let encodedHistory = try JSONEncoder().encode(historyState)
        XCTAssertThrowsError(
            try JSONDecoder().decode(TaskClassificationState.self, from: encodedHistory)
        ) { error in
            XCTAssertTrue(
                decodingErrorDescription(error).contains(
                    "classification relation history is not in canonical order"
                )
            )
        }
    }

    func testCanonicalAuditOrderingRejectsNonFiniteKeyDates() {
        let record = noOpRenameRecord(
            id: "12000000-0000-0000-0000-000000000001",
            planID: "22000000-0000-0000-0000-000000000001",
            interactionID: "32000000-0000-0000-0000-000000000001",
            committedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        let history = relationHistoryEntry(
            id: "52000000-0000-0000-0000-000000000001",
            kind: .category,
            chainID: "62000000-0000-0000-0000-000000000001",
            itemID: "72000000-0000-0000-0000-000000000001",
            removedAt: Date(timeIntervalSinceReferenceDate: -.infinity)
        )

        XCTAssertThrowsError(try ClassificationAuditCanonicalOrder.changeRecords([record]))
        XCTAssertThrowsError(try ClassificationAuditCanonicalOrder.relationHistory([history]))
        XCTAssertThrowsError(
            try TaskClassificationState(changeRecords: [record]).validateIntegrity()
        )
        XCTAssertThrowsError(
            try TaskClassificationState(relationHistory: [history]).validateIntegrity()
        )
    }

    func testRenamingLabelKeepsIdentityAndHistoricalName() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "标签改名", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: nil,
                labels: [.new(name: "待办", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "FFFF5555-0000-1111-2222-333344446666",
            decisionID: "00006666-1111-2222-3333-444455557777"
        )
        let labelID = try XCTUnwrap(engine.snapshot().classifications.labels.keys.first)
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        let renamePlan = try engine.prepareClassification(
            .renameLabel(labelID, to: "下一步"),
            source: .userDirect,
            interactionID: UUID(uuidString: "11117777-2222-3333-4444-555566668888")!,
            now: now.addingTimeInterval(60)
        )
        _ = try engine.commitClassification(
            renamePlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "22228888-3333-4444-5555-666677779999")!
            ),
            now: now.addingTimeInterval(60)
        )

        let current = try taskProjection(from: engine.classification(.task(chainID)))
        let historical = try historyProjection(from: engine.classification(.history(traceID)))
        XCTAssertEqual(current.labels.first?.id, labelID.description)
        XCTAssertEqual(current.labels.first?.name, "下一步")
        XCTAssertEqual(historical.labels.first?.name, "待办")
        XCTAssertEqual(engine.snapshot().classifications.labels[labelID]?.nameVersions.count, 2)
    }

    func testArchivedItemsStayVisibleOnExistingTaskButCannotBeNewlyAssignedUntilRestored() throws {
        let engine = NoonmarkEngine()
        let existingChainID = try engine.createPoolTask(title: "已有归档分类", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: existingChainID,
                category: .new(name: "旧项目", colorHex: "#2A6FDB"),
                labels: [.new(name: "旧标签", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "33339999-4444-5555-6666-77778888AAAA",
            decisionID: "4444AAAA-5555-6666-7777-88889999BBBB"
        )
        let state = engine.snapshot().classifications
        let categoryID = try XCTUnwrap(state.categories.keys.first)
        let labelID = try XCTUnwrap(state.labels.keys.first)

        try commitIntent(
            .archiveCategory(categoryID),
            to: engine,
            interactionID: "5555BBBB-6666-7777-8888-9999AAAACCCC",
            decisionID: "6666CCCC-7777-8888-9999-AAAABBBBDDDD"
        )
        try commitIntent(
            .archiveLabel(labelID),
            to: engine,
            interactionID: "7777DDDD-8888-9999-AAAA-BBBBCCCCEEEE",
            decisionID: "8888EEEE-9999-AAAA-BBBB-CCCCDDDDFFFF"
        )

        let existing = try taskProjection(from: engine.classification(.task(existingChainID)))
        XCTAssertEqual(existing.category?.name, "旧项目")
        XCTAssertEqual(existing.labels.map(\.name), ["旧标签"])

        let newChainID = try engine.createPoolTask(title: "新任务", now: now)
        XCTAssertThrowsError(
            try engine.prepareClassification(
                .setCurrent(
                    TaskClassificationDraft(
                        chainID: newChainID,
                        category: .existing(categoryID),
                        labels: [.existing(labelID)]
                    )
                ),
                source: .userDirect,
                interactionID: UUID(uuidString: "9999FFFF-AAAA-BBBB-CCCC-DDDDEEEE0000")!,
                now: now
            )
        )

        try commitIntent(
            .restoreCategory(categoryID),
            to: engine,
            interactionID: "AAAA0001-BBBB-CCCC-DDDD-EEEEFFFF1112",
            decisionID: "BBBB1112-CCCC-DDDD-EEEE-FFFF00002223"
        )
        try commitIntent(
            .restoreLabel(labelID),
            to: engine,
            interactionID: "CCCC2223-DDDD-EEEE-FFFF-000011113334",
            decisionID: "DDDD3334-EEEE-FFFF-0000-111122224445"
        )
        try commit(
            TaskClassificationDraft(
                chainID: newChainID,
                category: .existing(categoryID),
                labels: [.existing(labelID)]
            ),
            to: engine,
            interactionID: "EEEE4445-FFFF-0000-1111-222233335556",
            decisionID: "FFFF5556-0000-1111-2222-333344446667"
        )
        let restored = try taskProjection(from: engine.classification(.task(newChainID)))
        XCTAssertEqual(restored.category?.id, categoryID.description)
        XCTAssertEqual(restored.labels.first?.id, labelID.description)
    }

    func testEngineSnapshotRoundTripPreservesCurrentAndHistoricalClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "保存分类状态", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "项目", colorHex: "#2A6FDB"),
                labels: [.new(name: "持久化", colorHex: "#7C5CFF")]
            ),
            to: engine,
            interactionID: "77777777-7777-7777-7777-777777777777",
            decisionID: "88888888-8888-8888-8888-888888888888"
        )
        let traceID = try engine.scheduleFromPool(chainID: chainID, date: day1, today: day1, now: now)
        try engine.settleDays(upTo: day2, now: now)

        let restored = try NoonmarkEngine(snapshot: engine.snapshot())

        let current = try taskProjection(from: restored.classification(.task(chainID)))
        XCTAssertEqual(current.category?.name, "项目")
        XCTAssertEqual(current.labels.map(\.name), ["持久化"])

        let historical = try historyProjection(from: restored.classification(.history(traceID)))
        XCTAssertEqual(historical.category?.name, "项目")
        XCTAssertEqual(historical.labels.map(\.name), ["持久化"])
    }

    func testDuplicateNormalizedLabelsAreCollapsedAndDisclosed() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "去重标签", now: now)
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: nil,
                    labels: [
                        .new(name: "阅读", colorHex: "#0E9488"),
                        .new(name: "  阅读  ", colorHex: "#7C5CFF")
                    ]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            now: now
        )

        XCTAssertEqual(plan.notices, [.duplicateLabelCollapsed(name: "阅读")])

        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            now: now
        )
        let current = try taskProjection(from: engine.classification(.task(chainID)))

        XCTAssertEqual(current.labels.map(\.name), ["阅读"])
        XCTAssertEqual(receipt.notices, [.duplicateLabelCollapsed(name: "阅读")])
    }

    func testCanonicalNamesReuseEquivalentCaseAndWhitespaceVariantsWithinEachType() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(title: "规范名一", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: firstChainID,
                category: .new(name: "ＡＢＣ", colorHex: "#2A6FDB"),
                labels: [.new(name: "Straße", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "12341234-1234-1234-1234-123412341234",
            decisionID: "23452345-2345-2345-2345-234523452345"
        )
        let secondChainID = try engine.createPoolTask(title: "规范名二", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: secondChainID,
                category: .new(name: "abc", colorHex: "#D1477A"),
                labels: [.new(name: "STRASSE", colorHex: "#E0851B")]
            ),
            to: engine,
            interactionID: "34563456-3456-3456-3456-345634563456",
            decisionID: "45674567-4567-4567-4567-456745674567"
        )

        let state = engine.snapshot().classifications
        XCTAssertEqual(state.categories.count, 1)
        XCTAssertEqual(state.labels.count, 1)
        XCTAssertEqual(state.categories.values.first?.canonicalKey, "abc")
        XCTAssertEqual(state.labels.values.first?.canonicalKey, "strasse")
        XCTAssertEqual(
            ClassificationNameCanonicalizer.canonicalKey("foo\u{00AD}bar"),
            ClassificationNameCanonicalizer.canonicalKey("foobar")
        )
        XCTAssertTrue(
            ClassificationNameCanonicalizer.algorithmVersion.hasSuffix(
                "-nfkc-casefold-whitespace-v1"
            )
        )
        XCTAssertEqual(
            try taskProjection(from: engine.classification(.task(firstChainID))).category?.id,
            try taskProjection(from: engine.classification(.task(secondChainID))).category?.id
        )
    }

    func testClassificationIdentityDecodeRejectsUnpairedCanonicalKeyMetadata() throws {
        let category = TaskCategory(name: "工程", colorHex: "#2A6FDB", now: now)
        let encoded = try JSONEncoder().encode(category)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "canonicalKeyVersion")
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(TaskCategory.self, from: malformed))
    }

    func testPlanDigestAndNormalizedChangesCannotBeForged() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "计划内容对账", now: now)
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "可信计划", colorHex: "#2A6FDB"),
                    labels: [.new(name: "不可篡改", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "91910000-0000-0000-0000-000000000001")!,
            now: now
        )
        XCTAssertEqual(plan.digest.count, 64)
        XCTAssertTrue(plan.digest.allSatisfy { $0.isHexDigit })
        let before = engine.snapshot().classifications

        let forgedChanges = try ClassificationPlan(
            id: plan.id,
            baseRevision: plan.baseRevision,
            interactionID: plan.interactionID,
            intent: plan.intent,
            source: plan.source,
            changes: [
                .create(
                    kind: .label,
                    itemID: TaskLabelID().description,
                    name: "伪造审计",
                    colorHex: "#D1477A"
                )
            ],
            createdItemID: plan.createdItemID,
            plannedCreations: plan.plannedCreations,
            notices: plan.notices
        )
        XCTAssertThrowsError(
            try engine.commitClassification(
                forgedChanges,
                confirmation: .user(
                    decisionID: UUID(uuidString: "91910000-0000-0000-0000-000000000002")!
                ),
                now: now
            )
        )

        let forgedDigest = try ClassificationPlan(
            id: plan.id,
            baseRevision: plan.baseRevision,
            interactionID: plan.interactionID,
            intent: plan.intent,
            source: plan.source,
            changes: plan.changes,
            createdItemID: plan.createdItemID,
            plannedCreations: plan.plannedCreations,
            notices: plan.notices,
            digest: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(
            try engine.commitClassification(
                forgedDigest,
                confirmation: .user(
                    decisionID: UUID(uuidString: "91910000-0000-0000-0000-000000000002")!
                ),
                now: now
            )
        )
        XCTAssertEqual(engine.snapshot().classifications, before)

        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(
                decisionID: UUID(uuidString: "91910000-0000-0000-0000-000000000002")!
            ),
            now: now
        )
        let record = try XCTUnwrap(
            engine.snapshot().classifications.changeRecords.first(where: {
                $0.id == receipt.changeRecordID
            })
        )
        XCTAssertEqual(record.planDigest, plan.digest)
    }

    func testRetryingTheSameConfirmedPlanReturnsTheOriginalReceipt() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "幂等分类", now: now)
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "工程", colorHex: "#2A6FDB"),
                    labels: [.new(name: "幂等", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            now: now
        )
        let confirmation = ClassificationConfirmation.user(
            decisionID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        )

        let first = try engine.commitClassification(plan, confirmation: confirmation, now: now)
        let retried = try engine.commitClassification(plan, confirmation: confirmation, now: now)

        XCTAssertEqual(retried, first)
        let current = try taskProjection(from: engine.classification(.task(chainID)))
        XCTAssertEqual(current.category?.name, "工程")
        XCTAssertEqual(current.labels.map(\.name), ["幂等"])
        XCTAssertEqual(current.revision, first.revision)
    }

    func testUserConfirmationCapabilityIsBoundToOnePlan() throws {
        let engine = NoonmarkEngine()
        let firstPlan = try engine.prepareClassification(
            .createCategory(name: "计划一", colorHex: "#2A6FDB"),
            source: .userDirect,
            interactionID: UUID(uuidString: "91920000-0000-0000-0000-000000000001")!,
            now: now
        )
        let secondPlan = try engine.prepareClassification(
            .createCategory(name: "计划二", colorHex: "#0E9488"),
            source: .userDirect,
            interactionID: UUID(uuidString: "91920000-0000-0000-0000-000000000002")!,
            now: now
        )
        let confirmation = ClassificationConfirmation.user(
            confirming: firstPlan,
            decisionID: UUID(uuidString: "91920000-0000-0000-0000-000000000003")!
        )

        XCTAssertThrowsError(
            try engine.commitClassification(
                secondPlan,
                confirmation: confirmation,
                now: now
            )
        )
        XCTAssertTrue(engine.snapshot().classifications.categories.isEmpty)
        XCTAssertNoThrow(
            try engine.commitClassification(
                firstPlan,
                confirmation: confirmation,
                now: now
            )
        )
    }

    func testStaleAndInteractionIdempotencyRemainFailClosedAcrossLaterRevisions() throws {
        let engine = NoonmarkEngine()
        let staleChainID = try engine.createPoolTask(title: "过期计划", now: now)
        let committedChainID = try engine.createPoolTask(title: "已提交计划", now: now)
        let stalePlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: staleChainID,
                    category: .new(name: "过期", colorHex: "#2A6FDB"),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: UUID(uuidString: "92920000-0000-0000-0000-000000000001")!,
            now: now
        )
        let committedInteractionID = UUID(uuidString: "92920000-0000-0000-0000-000000000002")!
        let committedDecisionID = UUID(uuidString: "92920000-0000-0000-0000-000000000003")!
        let committedPlan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: committedChainID,
                    category: .new(name: "有效", colorHex: "#0E9488"),
                    labels: []
                )
            ),
            source: .userDirect,
            interactionID: committedInteractionID,
            now: now
        )
        let committedReceipt = try engine.commitClassification(
            committedPlan,
            confirmation: .user(decisionID: committedDecisionID),
            now: now
        )
        let afterFirstCommit = engine.snapshot().classifications

        XCTAssertThrowsError(
            try engine.commitClassification(
                stalePlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "92920000-0000-0000-0000-000000000004")!
                ),
                now: now
            )
        )
        XCTAssertEqual(engine.snapshot().classifications, afterFirstCommit)

        let laterPlan = try engine.prepareClassification(
            .createLabel(name: "推进 revision", colorHex: "#7C5CFF"),
            source: .userDirect,
            interactionID: UUID(uuidString: "92920000-0000-0000-0000-000000000005")!,
            now: now
        )
        _ = try engine.commitClassification(
            laterPlan,
            confirmation: .user(
                decisionID: UUID(uuidString: "92920000-0000-0000-0000-000000000006")!
            ),
            now: now
        )
        XCTAssertEqual(
            try engine.commitClassification(
                committedPlan,
                confirmation: .user(decisionID: committedDecisionID),
                now: now
            ),
            committedReceipt
        )
        XCTAssertThrowsError(
            try engine.commitClassification(
                committedPlan,
                confirmation: .user(
                    decisionID: UUID(uuidString: "92920000-0000-0000-0000-000000000007")!
                ),
                now: now
            )
        )

        let reusedInteractionPlan = try engine.prepareClassification(
            .createLabel(name: "重复 interaction", colorHex: "#D1477A"),
            source: .userDirect,
            interactionID: committedInteractionID,
            now: now
        )
        XCTAssertThrowsError(
            try engine.commitClassification(
                reusedInteractionPlan,
                confirmation: .user(decisionID: committedDecisionID),
                now: now
            )
        )
    }

    func testPlanAndChangeRecordExposeSourceDecisionAndBeforeAfter() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "白盒变更记录", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "旧分类", colorHex: "#2A6FDB"),
                labels: [.new(name: "旧标签", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "81818181-8181-8181-8181-818181818181",
            decisionID: "82828282-8282-8282-8282-828282828282"
        )
        let interactionID = UUID(uuidString: "83838383-8383-8383-8383-838383838383")!
        let decisionID = UUID(uuidString: "84848484-8484-8484-8484-848484848484")!

        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "新分类", colorHex: "#D1477A"),
                    labels: [.new(name: "新标签", colorHex: "#E0851B")]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(plan.source, .userDirect)
        guard case let .setCurrent(_, before, after) = try XCTUnwrap(plan.changes.first) else {
            return XCTFail("预期当前分类 before/after")
        }
        XCTAssertEqual(before.category?.name, "旧分类")
        XCTAssertEqual(before.labels.map(\.name), ["旧标签"])
        XCTAssertEqual(after.category?.name, "新分类")
        XCTAssertEqual(after.labels.map(\.name), ["新标签"])

        let receipt = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: decisionID),
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(receipt.decisionID, decisionID)

        let record = try XCTUnwrap(engine.snapshot().classifications.changeRecords.last)
        XCTAssertEqual(record.id, receipt.changeRecordID)
        XCTAssertEqual(record.planID, plan.id)
        XCTAssertEqual(record.interactionID, interactionID)
        XCTAssertEqual(record.source, .userDirect)
        XCTAssertEqual(record.decisionID, decisionID)
        XCTAssertEqual(record.changes.count, 1)
    }

    func testCatalogSeparatesTypesAndSortsByCanonicalName() throws {
        let engine = NoonmarkEngine()
        let firstChainID = try engine.createPoolTask(title: "目录一", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: firstChainID,
                category: .new(name: "Zulu", colorHex: "#2A6FDB"),
                labels: [
                    .new(name: "Beta", colorHex: "#0E9488"),
                    .new(name: "alpha", colorHex: "#7C5CFF")
                ]
            ),
            to: engine,
            interactionID: "85858585-8585-8585-8585-858585858585",
            decisionID: "86868686-8686-8686-8686-868686868686"
        )
        let secondChainID = try engine.createPoolTask(title: "目录二", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: secondChainID,
                category: .new(name: "alpha", colorHex: "#D1477A"),
                labels: []
            ),
            to: engine,
            interactionID: "87878787-8787-8787-8787-878787878787",
            decisionID: "88888888-8787-8787-8787-878787878787"
        )

        guard case let .catalog(catalog) = try engine.classification(.catalog) else {
            return XCTFail("预期分类目录")
        }
        XCTAssertEqual(catalog.categories.map(\.name), ["alpha", "Zulu"])
        XCTAssertEqual(catalog.labels.map(\.name), ["alpha", "Beta"])
        XCTAssertEqual(catalog.categories.map(\.currentUsageCount), [1, 1])
        XCTAssertEqual(catalog.labels.map(\.currentUsageCount), [1, 1])
    }

    func testRemovingClassifiedUnscheduledTaskClosesCurrentRelationsAndKeepsHistoryAnchor() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "移出已分类任务", now: now)
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "工程", colorHex: "#2A6FDB"),
                labels: [.new(name: "白盒", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "91000000-0000-0000-0000-000000000001",
            decisionID: "91000000-0000-0000-0000-000000000002"
        )

        let removedAt = now.addingTimeInterval(60)
        let outcome = try engine.removeTaskFromPool(
            chainID: chainID,
            now: removedAt
        )

        XCTAssertEqual(outcome, .removedKeepingHistory)
        XCTAssertEqual(engine.chains[chainID]?.state, .abandoned)
        XCTAssertFalse(engine.taskPool().contains { $0.chain.id == chainID })
        let projection = try taskProjection(from: engine.classification(.task(chainID)))
        XCTAssertNil(projection.category)
        XCTAssertTrue(projection.labels.isEmpty)

        let state = engine.snapshot().classifications
        XCTAssertEqual(state.relationHistory.count, 2)
        let removalRecord = try XCTUnwrap(state.changeRecords.last)
        XCTAssertEqual(
            removalRecord.source,
            .deterministicDomainAction(
                reason: "task removed from task pool while preserving classification history"
            )
        )
        XCTAssertNil(removalRecord.decisionID)
        XCTAssertNil(
            state.committedReceiptsByInteractionID[removalRecord.interactionID]
        )
        XCTAssertTrue(state.relationHistory.allSatisfy { history in
            history.chainID == chainID
                && history.removedAt == removedAt
                && history.removedBySource == .deterministicDomainAction(
                    reason: "task removed from task pool while preserving classification history"
                )
        })
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testRemovingUnclassifiedUnscheduledTaskRetainsHiddenIdentityFacts() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "删除无历史任务", now: now)
        let definitionID = try XCTUnwrap(
            engine.taskPool().first {
                $0.chain.id == chainID
            }?.definition.id
        )

        let outcome = try engine.removeTaskFromPool(
            chainID: chainID,
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(engine.chains[chainID]?.state, .abandoned)
        XCTAssertEqual(engine.definitions[definitionID]?.chainID, chainID)
        XCTAssertFalse(engine.taskPool().contains { $0.chain.id == chainID })
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testRemovingClassifiedCancelledFutureDraftClosesGhostCurrentRelations() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "移出已取消未来草稿",
            now: now
        )
        try commit(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "未来工程", colorHex: "#2A6FDB"),
                labels: [.new(name: "隐藏草稿", colorHex: "#0E9488")]
            ),
            to: engine,
            interactionID: "92000000-0000-0000-0000-000000000001",
            decisionID: "92000000-0000-0000-0000-000000000002"
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: day2,
            today: day1,
            now: now.addingTimeInterval(10)
        )
        try engine.returnToPool(
            traceID: traceID,
            today: day1,
            now: now.addingTimeInterval(20)
        )

        let outcome = try engine.removeTaskFromPool(
            chainID: chainID,
            now: now.addingTimeInterval(30)
        )

        XCTAssertEqual(outcome, .removedKeepingHistory)
        XCTAssertEqual(engine.chains[chainID]?.state, .abandoned)
        XCTAssertTrue(engine.taskPool().isEmpty)
        XCTAssertTrue(engine.futurePlans(today: day1).isEmpty)
        XCTAssertTrue(engine.getDayTodo(date: day2).traces.isEmpty)

        let projection = try taskProjection(
            from: engine.classification(.task(chainID))
        )
        XCTAssertNil(projection.category)
        XCTAssertTrue(projection.labels.isEmpty)
        guard case let .catalog(catalog) = try engine.classification(.catalog) else {
            return XCTFail("预期分类目录")
        }
        XCTAssertEqual(
            catalog.categories.first { $0.name == "未来工程" }?
                .currentUsageCount,
            0
        )
        XCTAssertEqual(
            catalog.labels.first { $0.name == "隐藏草稿" }?
                .currentUsageCount,
            0
        )
        XCTAssertEqual(
            engine.snapshot().classifications.relationHistory.count,
            2
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    private func noOpRenameRecord(
        id: String,
        planID: String,
        interactionID: String,
        committedAt: Date? = nil
    ) -> ClassificationChangeRecord {
        ClassificationChangeRecord(
            id: UUID(uuidString: id)!,
            planID: UUID(uuidString: planID)!,
            interactionID: UUID(uuidString: interactionID)!,
            source: .deterministicDomainAction(reason: "canonical ordering tracer"),
            decisionID: nil,
            changes: [
                .rename(
                    kind: .category,
                    itemID: "40000000-0000-0000-0000-000000000001",
                    beforeName: "工程",
                    afterName: "工程"
                )
            ],
            committedAt: committedAt ?? now,
            revision: 0,
            planDigest: String(repeating: "a", count: 64)
        )
    }

    private func relationHistoryEntry(
        id: String,
        kind: ClassificationItemKind,
        chainID: String,
        itemID: String,
        removedAt: Date? = nil
    ) -> ClassificationRelationHistoryEntry {
        ClassificationRelationHistoryEntry(
            id: UUID(uuidString: id)!,
            kind: kind,
            chainID: TaskChainID(UUID(uuidString: chainID)!),
            itemID: itemID,
            originSource: .deterministicDomainAction(reason: "canonical ordering origin"),
            originDecisionID: nil,
            createdAt: now.addingTimeInterval(-1),
            createdRevision: 0,
            removedBySource: .deterministicDomainAction(reason: "canonical ordering removal"),
            removedByDecisionID: nil,
            removedAt: removedAt ?? now,
            removedRevision: 1
        )
    }

    private func decodingErrorDescription(_ error: Error) -> String {
        guard case let DecodingError.dataCorrupted(context) = error else {
            return String(describing: error)
        }
        return context.debugDescription
    }

    private func taskProjection(from projection: ClassificationProjection) throws -> TaskClassificationProjection {
        guard case let .task(task) = projection else {
            throw XCTSkip("预期任务分类投影")
        }
        return task
    }

    private func historyProjection(from projection: ClassificationProjection) throws -> TraceClassificationProjection {
        guard case let .history(history) = projection else {
            throw XCTSkip("预期历史分类投影")
        }
        return history
    }

    private func commit(
        _ draft: TaskClassificationDraft,
        to engine: NoonmarkEngine,
        interactionID: String,
        decisionID: String
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(draft),
            source: .userDirect,
            interactionID: UUID(uuidString: interactionID)!,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID(uuidString: decisionID)!),
            now: now
        )
    }

    private func commitIntent(
        _ intent: ClassificationIntent,
        to engine: NoonmarkEngine,
        interactionID: String,
        decisionID: String
    ) throws {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(uuidString: interactionID)!,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID(uuidString: decisionID)!),
            now: now
        )
    }
}

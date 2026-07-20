@_spi(AutomaticClassificationJobAuthority) @testable import NoonmarkCore
import XCTest

final class AutomaticTaskClassificationTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_200_000)
    private let jobID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!

    func testAutomaticClassificationCommitsOneCategoryAndLabelsWhilePreservingExplicitLabels() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "准备季度预算",
            descriptionText: "星期五前完成初稿",
            now: base
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: nil,
                labels: [.new(name: "紧急", colorHex: "#D1477A")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )

        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        XCTAssertEqual(context.authority.chainID, chainID)
        XCTAssertEqual(context.authority.jobID, jobID)
        XCTAssertEqual(context.authority.generation, 1)
        XCTAssertEqual(context.authority.catalogDigest.count, 64)
        XCTAssertEqual(context.taskTitle, "准备季度预算")
        XCTAssertEqual(context.taskDescription, "星期五前完成初稿")
        XCTAssertEqual(context.currentClassification.labels.map(\.name), ["紧急"])
        XCTAssertEqual(context.catalog.labels.map(\.name), ["紧急"])
        XCTAssertEqual(context.authority.contentDigest.count, 64)
        XCTAssertEqual(context.authority.classificationFingerprint.count, 64)

        let plan = try engine.prepareAutomaticClassification(
            AutomaticClassificationApplicationProposal(
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "深度工作", colorHex: "#0E9488")]
            ),
            authority: context.authority,
            interactionID: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!
        )
        let receipt = try engine.commitAutomaticClassification(
            plan,
            authority: context.authority,
            now: base.addingTimeInterval(2)
        )

        let projection = try taskProjection(
            from: engine.classification(.task(chainID))
        )
        XCTAssertEqual(projection.category?.name, "工作")
        XCTAssertEqual(Set(projection.labels.map(\.name)), ["紧急", "深度工作"])
        XCTAssertEqual(receipt.revision, 2)
        XCTAssertNil(receipt.decisionID)

        let state = engine.snapshot().classifications
        let current = try XCTUnwrap(state.currentByChainID[chainID])
        XCTAssertEqual(
            current.category?.source,
            .automaticAI(jobID: jobID, generation: 1)
        )
        let explicitLabel = try XCTUnwrap(
            current.labels.first { state.labels[$0.labelID]?.name == "紧急" }
        )
        XCTAssertEqual(explicitLabel.source, .userDirect)
        let automaticLabel = try XCTUnwrap(
            current.labels.first { state.labels[$0.labelID]?.name == "深度工作" }
        )
        XCTAssertEqual(
            automaticLabel.source,
            .automaticAI(jobID: jobID, generation: 1)
        )
        let record = try XCTUnwrap(state.changeRecords.last)
        XCTAssertEqual(
            record.source,
            .automaticAI(jobID: jobID, generation: 1)
        )
        XCTAssertNil(record.decisionID)
        XCTAssertNil(state.committedReceiptsByInteractionID[record.interactionID])
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testEditedTaskContentSupersedesIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "整理发票", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        try engine.updatePoolTask(
            chainID: chainID,
            title: "整理报销发票",
            now: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.prepareAutomaticClassification(
                proposal(),
                authority: context.authority,
                interactionID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification task content changed")
            )
        }
        XCTAssertTrue(engine.snapshot().classifications.categories.isEmpty)
        XCTAssertTrue(engine.snapshot().classifications.labels.isEmpty)
    }

    func testSchedulingAndTaskNotesDoNotSupersedeIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "准备周会",
            descriptionText: "整理本周进度",
            now: base
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        let noteID = try engine.appendPoolNote(
            chainID: chainID,
            body: "提醒带上数据",
            now: base.addingTimeInterval(1)
        )
        try engine.editPoolNote(
            chainID: chainID,
            noteID: noteID,
            body: "提醒带上最新数据",
            now: base.addingTimeInterval(2)
        )
        _ = try engine.scheduleFromPool(
            chainID: chainID,
            date: LocalDate(year: 2026, month: 7, day: 20),
            today: LocalDate(year: 2026, month: 7, day: 20),
            now: base.addingTimeInterval(3)
        )

        let resumed = try engine.automaticClassificationContext(
            authority: context.authority
        )
        XCTAssertEqual(resumed.taskTitle, context.taskTitle)
        XCTAssertEqual(resumed.taskDescription, context.taskDescription)
    }

    func testNonPromptDefinitionTouchRequiresFreshAutomaticAuthorityGeneration() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "准备周会",
            descriptionText: "整理本周进度",
            now: base
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "导出报表",
            now: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.automaticClassificationContext(
                authority: context.authority
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification task content changed")
            )
        }

        let replacement = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: UUID(),
            generation: 2
        )
        XCTAssertNotEqual(
            replacement.authority.contentDigest,
            context.authority.contentDigest
        )
        XCTAssertNoThrow(
            try engine.automaticClassificationContext(
                authority: replacement.authority
            )
        )
    }

    func testReschedulingDoesNotSupersedeIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let today = LocalDate(year: 2026, month: 7, day: 20)
        let firstDate = LocalDate(year: 2026, month: 7, day: 21)
        let secondDate = LocalDate(year: 2026, month: 7, day: 22)
        let chainID = try engine.createPoolTask(
            title: "续订证书",
            descriptionText: "确认域名清单",
            now: base
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: firstDate,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        try engine.rescheduleFuturePlan(
            traceID: traceID,
            targetDate: secondDate,
            today: today,
            now: base.addingTimeInterval(2)
        )

        XCTAssertNoThrow(
            try engine.automaticClassificationContext(
                authority: context.authority
            )
        )
    }

    func testEditedTaskDescriptionSupersedesIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "整理发票",
            descriptionText: "个人报销",
            now: base
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        try engine.updatePoolTask(
            chainID: chainID,
            title: "整理发票",
            descriptionText: "客户项目报销",
            now: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.automaticClassificationContext(
                authority: context.authority
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification task content changed")
            )
        }
    }

    func testAbandonedTaskRejectsIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let today = LocalDate(year: 2026, month: 7, day: 20)
        let chainID = try engine.createPoolTask(title: "停止旧项目", now: base)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(1)
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        try engine.abandonChain(
            from: traceID,
            now: base.addingTimeInterval(2)
        )

        XCTAssertThrowsError(
            try engine.automaticClassificationContext(
                authority: context.authority
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .chainAbandoned)
        }
    }

    func testManualClassificationSupersedesIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "准备演示", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "个人", colorHex: "#D1477A"),
                labels: [.new(name: "演示", colorHex: "#7C5CFF")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.prepareAutomaticClassification(
                proposal(),
                authority: context.authority,
                interactionID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition(
                    "automatic classification was superseded by a classification change"
                )
            )
        }
        let projection = try taskProjection(
            from: engine.classification(.task(chainID))
        )
        XCTAssertEqual(projection.category?.name, "个人")
        XCTAssertEqual(projection.labels.map(\.name), ["演示"])
    }

    func testAutomaticClassificationProtectsExistingUserAndZhulongCategories() throws {
        let protectedSources: [ClassificationSource] = [
            .userDirect,
            .zhulongSuggestion(
                sessionID: UUID(uuidString: "A1100000-0000-0000-0000-000000000001")!,
                draftID: UUID(uuidString: "A1100000-0000-0000-0000-000000000002")!,
                draftVersion: 1,
                evidenceID: UUID(uuidString: "A1100000-0000-0000-0000-000000000003")!
            )
        ]

        for (offset, source) in protectedSources.enumerated() {
            let engine = NoonmarkEngine()
            let chainID = try engine.createPoolTask(
                title: "保护用户分类 \(offset)",
                now: base
            )
            try commitUserClassification(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "用户已选", colorHex: "#D1477A"),
                    labels: []
                ),
                source: source,
                to: engine,
                at: base.addingTimeInterval(1)
            )
            let context = try engine.issueAutomaticClassificationContext(
                for: chainID,
                jobID: jobID,
                generation: offset + 1
            )
            let plan = try engine.prepareAutomaticClassification(
                AutomaticClassificationApplicationProposal(
                    category: .new(name: "AI 不得覆盖", colorHex: "#2A6FDB"),
                    labels: [.new(name: "AI 标签", colorHex: "#0E9488")]
                ),
                authority: context.authority,
                interactionID: UUID()
            )
            _ = try engine.commitAutomaticClassification(
                plan,
                authority: context.authority,
                now: base.addingTimeInterval(2)
            )

            let state = engine.snapshot().classifications
            let current = try XCTUnwrap(state.currentByChainID[chainID])
            let protectedCategoryID = try XCTUnwrap(current.categoryID)
            XCTAssertEqual(
                state.categories[protectedCategoryID]?.name,
                "用户已选"
            )
            XCTAssertEqual(current.category?.source, source)
            XCTAssertFalse(
                state.categories.values.contains { $0.name == "AI 不得覆盖" }
            )
            XCTAssertEqual(
                Set(current.labels.compactMap { state.labels[$0.labelID]?.name }),
                ["AI 标签"]
            )
        }
    }

    func testCatalogMutationSupersedesIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "检查合同", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        try commitUserIntent(
            .createCategory(name: "法务", colorHex: "#2A6FDB"),
            to: engine,
            at: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.prepareAutomaticClassification(
                proposal(),
                authority: context.authority,
                interactionID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification catalog changed")
            )
        }
    }

    func testCatalogRenameAndArchiveSupersedeIssuedAutomaticAuthority() throws {
        let engine = NoonmarkEngine()
        let seedID = try engine.createPoolTask(title: "目录来源", now: base)
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: seedID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "行动", colorHex: "#0E9488")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )
        let state = engine.snapshot().classifications
        let categoryID = try XCTUnwrap(
            state.currentByChainID[seedID]?.categoryID
        )
        let targetID = try engine.createPoolTask(
            title: "观察目录变化",
            now: base.addingTimeInterval(2)
        )
        let beforeRename = try engine.issueAutomaticClassificationContext(
            for: targetID,
            jobID: jobID,
            generation: 1
        )
        try commitUserIntent(
            .renameCategory(categoryID, to: "职业"),
            to: engine,
            at: base.addingTimeInterval(3)
        )
        assertCatalogFenceRejects(
            beforeRename.authority,
            in: engine
        )

        let beforeArchive = try engine.issueAutomaticClassificationContext(
            for: targetID,
            jobID: jobID,
            generation: 2
        )
        try commitUserIntent(
            .archiveCategory(categoryID),
            to: engine,
            at: base.addingTimeInterval(4)
        )
        assertCatalogFenceRejects(
            beforeArchive.authority,
            in: engine
        )
    }

    func testUnrelatedTaskRelationCommitDoesNotInvalidatePreparedAutomaticPlan() throws {
        let engine = NoonmarkEngine()
        let seedID = try engine.createPoolTask(title: "目录种子", now: base)
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: seedID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "行动", colorHex: "#0E9488")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )
        let seed = try XCTUnwrap(
            engine.snapshot().classifications.currentByChainID[seedID]
        )
        let categoryID = try XCTUnwrap(seed.categoryID)
        let labelID = try XCTUnwrap(seed.labels.first?.labelID)
        let firstChainID = try engine.createPoolTask(
            title: "并行归类 A",
            now: base.addingTimeInterval(2)
        )
        let secondChainID = try engine.createPoolTask(
            title: "并行归类 B",
            now: base.addingTimeInterval(2)
        )
        let firstContext = try engine.issueAutomaticClassificationContext(
            for: firstChainID,
            jobID: UUID(),
            generation: 1
        )
        let secondContext = try engine.issueAutomaticClassificationContext(
            for: secondChainID,
            jobID: UUID(),
            generation: 1
        )
        XCTAssertEqual(
            firstContext.authority.catalogDigest,
            secondContext.authority.catalogDigest
        )
        let existingProposal = AutomaticClassificationApplicationProposal(
            category: .existing(categoryID),
            labels: [.existing(labelID)]
        )
        let firstPlan = try engine.prepareAutomaticClassification(
            existingProposal,
            authority: firstContext.authority,
            interactionID: UUID()
        )
        let secondPlan = try engine.prepareAutomaticClassification(
            existingProposal,
            authority: secondContext.authority,
            interactionID: UUID()
        )

        _ = try engine.commitAutomaticClassification(
            secondPlan,
            authority: secondContext.authority,
            now: base.addingTimeInterval(3)
        )
        XCTAssertNoThrow(
            try engine.commitAutomaticClassification(
                firstPlan,
                authority: firstContext.authority,
                now: base.addingTimeInterval(3)
            )
        )
        XCTAssertEqual(
            try taskProjection(from: engine.classification(.task(firstChainID)))
                .category?.name,
            "工作"
        )
    }

    func testPreparedAutomaticPlanCannotOverwriteLaterUserClassification() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "安排体检", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try engine.prepareAutomaticClassification(
            proposal(),
            authority: context.authority,
            interactionID: UUID()
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: .new(name: "健康", colorHex: "#0E9488"),
                labels: [.new(name: "预约", colorHex: "#7C5CFF")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try engine.commitAutomaticClassification(
                plan,
                authority: context.authority,
                now: base.addingTimeInterval(2)
            )
        )
        let projection = try taskProjection(
            from: engine.classification(.task(chainID))
        )
        XCTAssertEqual(projection.category?.name, "健康")
        XCTAssertEqual(projection.labels.map(\.name), ["预约"])
    }

    func testAutomaticCommitRejectsBackdatedMutationWithoutPublishingFacts() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "时间边界", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try engine.prepareAutomaticClassification(
            proposal(),
            authority: context.authority,
            interactionID: UUID()
        )

        XCTAssertThrowsError(
            try engine.commitAutomaticClassification(
                plan,
                authority: context.authority,
                now: base.addingTimeInterval(-1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput(
                    "automatic classification mutation time predates its task content"
                )
            )
        }
        XCTAssertTrue(engine.snapshot().classifications.changeRecords.isEmpty)
        XCTAssertTrue(engine.snapshot().classifications.categories.isEmpty)
        XCTAssertTrue(engine.snapshot().classifications.labels.isEmpty)
    }

    func testAutomaticPlanIsBoundToItsExactJobAndGenerationAuthority() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "更新简历", now: base)
        let first = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try engine.prepareAutomaticClassification(
            proposal(),
            authority: first.authority,
            interactionID: UUID()
        )
        let nextGeneration = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 2
        )

        XCTAssertThrowsError(
            try engine.commitAutomaticClassification(
                plan,
                authority: nextGeneration.authority,
                now: base.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput(
                    "automatic classification plan does not match its authority"
                )
            )
        }
        XCTAssertNil(
            try taskProjection(from: engine.classification(.task(chainID)))
                .category
        )
    }

    func testAutomaticProposalRequiresOneToThreeAILabels() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "分类边界", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )

        for labels in [
            [TaskLabelChoice](),
            [
                .new(name: "一", colorHex: "#2A6FDB"),
                .new(name: "二", colorHex: "#0E9488"),
                .new(name: "三", colorHex: "#7C5CFF"),
                .new(name: "四", colorHex: "#D1477A")
            ]
        ] {
            XCTAssertThrowsError(
                try engine.prepareAutomaticClassification(
                    AutomaticClassificationApplicationProposal(
                        category: .new(name: "工作", colorHex: "#2A6FDB"),
                        labels: labels
                    ),
                    authority: context.authority,
                    interactionID: UUID()
                )
            )
        }
    }

    func testPersistedAuthorityResumesTheSameBoundContextAfterRestart() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "重启后继续归类",
            descriptionText: "不重复建立新基线",
            now: base
        )
        let issued = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 3
        )
        let authorityData = try JSONEncoder().encode(issued.authority)
        let persistedAuthority = try JSONDecoder().decode(
            AutomaticTaskClassificationAuthority.self,
            from: authorityData
        )
        XCTAssertEqual(persistedAuthority, issued.authority)

        let restored = try NoonmarkEngine(snapshot: engine.snapshot())
        let resumed = try restored.automaticClassificationContext(
            authority: persistedAuthority
        )

        XCTAssertEqual(resumed, issued)
        let plan = try restored.prepareAutomaticClassification(
            proposal(),
            authority: persistedAuthority,
            interactionID: UUID()
        )
        XCTAssertNoThrow(
            try restored.commitAutomaticClassification(
                plan,
                authority: persistedAuthority,
                now: base.addingTimeInterval(1)
            )
        )
    }

    func testPersistedAuthorityRejectsTamperedGeneration() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "防止篡改 fence", now: base)
        let issued = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let data = try JSONEncoder().encode(issued.authority)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["generation"] = 2
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AutomaticTaskClassificationAuthority.self,
                from: tampered
            )
        )
    }

    func testClassificationStateRejectsNonpositiveAutomaticSourceGeneration() throws {
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(title: "来源代次完整性", now: base)
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try engine.prepareAutomaticClassification(
            proposal(),
            authority: context.authority,
            interactionID: UUID()
        )
        _ = try engine.commitAutomaticClassification(
            plan,
            authority: context.authority,
            now: base.addingTimeInterval(1)
        )

        let validState = engine.snapshot().classifications
        let validCurrent = try XCTUnwrap(validState.currentByChainID[chainID])
        let validCategory = try XCTUnwrap(validCurrent.category)
        var invalidRelationState = validState
        invalidRelationState.currentByChainID[chainID] = CurrentTaskClassification(
            category: TaskCategoryRelation(
                categoryID: validCategory.categoryID,
                source: .automaticAI(jobID: jobID, generation: 0),
                decisionID: validCategory.decisionID,
                createdAt: validCategory.createdAt,
                updatedAt: validCategory.updatedAt,
                revision: validCategory.revision
            ),
            labels: validCurrent.labels
        )
        XCTAssertThrowsError(try invalidRelationState.validateIntegrity())

        let validRecord = try XCTUnwrap(validState.changeRecords.first)
        var invalidRecordState = validState
        invalidRecordState.changeRecords = [
            ClassificationChangeRecord(
                id: validRecord.id,
                planID: validRecord.planID,
                interactionID: validRecord.interactionID,
                source: .automaticAI(jobID: jobID, generation: -1),
                decisionID: validRecord.decisionID,
                changes: validRecord.changes,
                notices: validRecord.notices,
                committedAt: validRecord.committedAt,
                revision: validRecord.revision,
                planDigest: validRecord.planDigest
            )
        ]
        XCTAssertThrowsError(try invalidRecordState.validateIntegrity())

        var invalidSnapshot = engine.snapshot()
        invalidSnapshot.classifications = invalidRelationState
        XCTAssertThrowsError(try invalidSnapshot.validateIntegrity())
    }

    func testSnapshotUndoCancelsNewTaskClassificationAndRedoRequestsReclassification() throws {
        let before = NoonmarkEngine().snapshot()
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "撤销新建任务",
            now: base
        )
        let context = try current.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try current.prepareAutomaticClassification(
            proposal(),
            authority: context.authority,
            interactionID: UUID()
        )
        _ = try current.commitAutomaticClassification(
            plan,
            authority: context.authority,
            now: base.addingTimeInterval(1)
        )
        let afterCreation = current.snapshot()

        let undone = try NoonmarkEngine(snapshot: before)
        let undoOutcome = try undone.prepareSnapshotUndo(
            replacing: afterCreation,
            now: base.addingTimeInterval(2)
        )

        XCTAssertEqual(
            undoOutcome.automaticClassificationCancelledChainIDs,
            [chainID]
        )
        XCTAssertTrue(
            undoOutcome.automaticClassificationRestoredChainIDs.isEmpty
        )
        XCTAssertEqual(undone.chains[chainID]?.state, .abandoned)
        let undoneProjection = try taskProjection(
            from: undone.classification(.task(chainID))
        )
        XCTAssertNil(undoneProjection.category)
        XCTAssertTrue(undoneProjection.labels.isEmpty)
        let undoneState = undone.snapshot().classifications
        XCTAssertEqual(undoneState.relationHistory.count, 2)
        XCTAssertTrue(undoneState.relationHistory.allSatisfy {
            $0.chainID == chainID
                && $0.originSource == .automaticAI(
                    jobID: jobID,
                    generation: 1
                )
                && $0.removedBySource == .deterministicDomainAction(
                    reason: "snapshot undo cancelled a new task classification"
                )
        })
        XCTAssertNoThrow(try undone.snapshot().validateIntegrity())

        let redone = try NoonmarkEngine(snapshot: afterCreation)
        let redoOutcome = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(3)
        )

        XCTAssertTrue(
            redoOutcome.automaticClassificationCancelledChainIDs.isEmpty
        )
        XCTAssertEqual(
            redoOutcome.automaticClassificationRestoredChainIDs,
            [chainID]
        )
        XCTAssertEqual(redone.chains[chainID]?.state, .active)
        let redoneProjection = try taskProjection(
            from: redone.classification(.task(chainID))
        )
        XCTAssertNil(redoneProjection.category)
        XCTAssertTrue(redoneProjection.labels.isEmpty)
        XCTAssertEqual(redone.snapshot().classifications.changeRecords.count, 2)
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }

    func testSnapshotUndoReportsPendingAutomaticJobWithoutInventingClassificationAudit() throws {
        let before = NoonmarkEngine().snapshot()
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "AI 尚未返回",
            now: base
        )
        let context = try current.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let afterCreation = current.snapshot()

        let undone = try NoonmarkEngine(snapshot: before)
        let undoOutcome = try undone.prepareSnapshotUndo(
            replacing: afterCreation,
            now: base.addingTimeInterval(1)
        )
        XCTAssertEqual(
            undoOutcome.automaticClassificationCancelledChainIDs,
            [chainID]
        )
        XCTAssertTrue(undone.snapshot().classifications.changeRecords.isEmpty)
        XCTAssertThrowsError(
            try undone.automaticClassificationContext(
                authority: context.authority
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .chainAbandoned)
        }

        let redone = try NoonmarkEngine(snapshot: afterCreation)
        let redoOutcome = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(2)
        )
        XCTAssertEqual(
            redoOutcome.automaticClassificationRestoredChainIDs,
            [chainID]
        )
        XCTAssertTrue(redone.snapshot().classifications.changeRecords.isEmpty)
        XCTAssertThrowsError(
            try redone.automaticClassificationContext(
                authority: context.authority
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification task content changed")
            )
        }
    }

    func testSnapshotUndoKeepsExplicitLabelsAndRedoDoesNotReviveAutomaticRelations() throws {
        let before = NoonmarkEngine().snapshot()
        let current = NoonmarkEngine()
        let chainID = try current.createPoolTask(
            title: "带显式标签的新任务",
            now: base
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: nil,
                labels: [.new(name: "紧急", colorHex: "#D1477A")]
            ),
            to: current,
            at: base.addingTimeInterval(1)
        )
        let context = try current.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let plan = try current.prepareAutomaticClassification(
            proposal(),
            authority: context.authority,
            interactionID: UUID()
        )
        _ = try current.commitAutomaticClassification(
            plan,
            authority: context.authority,
            now: base.addingTimeInterval(2)
        )
        let afterCreation = current.snapshot()

        let undone = try NoonmarkEngine(snapshot: before)
        let undoOutcome = try undone.prepareSnapshotUndo(
            replacing: afterCreation,
            now: base.addingTimeInterval(3)
        )
        XCTAssertEqual(
            undoOutcome.automaticClassificationCancelledChainIDs,
            [chainID]
        )
        let undoneProjection = try taskProjection(
            from: undone.classification(.task(chainID))
        )
        XCTAssertNil(undoneProjection.category)
        XCTAssertEqual(undoneProjection.labels.map(\.name), ["紧急"])
        let undoneState = undone.snapshot().classifications
        XCTAssertEqual(
            undoneState.currentByChainID[chainID]?.labels.first?.source,
            .userDirect
        )

        let redone = try NoonmarkEngine(snapshot: afterCreation)
        let redoOutcome = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(4)
        )

        XCTAssertEqual(
            redoOutcome.automaticClassificationRestoredChainIDs,
            [chainID]
        )
        let redoneProjection = try taskProjection(
            from: redone.classification(.task(chainID))
        )
        XCTAssertNil(redoneProjection.category)
        XCTAssertEqual(redoneProjection.labels.map(\.name), ["紧急"])
        let redoneState = redone.snapshot().classifications
        let currentRelations = try XCTUnwrap(
            redoneState.currentByChainID[chainID]
        )
        XCTAssertTrue(currentRelations.labels.allSatisfy {
            if case .automaticAI = $0.source { return false }
            return true
        })
        XCTAssertTrue(redoneState.relationHistory.contains {
            $0.chainID == chainID
                && $0.originSource == .automaticAI(
                    jobID: jobID,
                    generation: 1
                )
        })
        XCTAssertFalse(redoneState.changeRecords.contains {
            $0.source == .deterministicDomainAction(
                reason: "snapshot redo restored user-selected classification"
            )
        })
        XCTAssertNoThrow(try redone.snapshot().validateIntegrity())
    }

    func testSnapshotUndoRemovesOnlyCurrentAutomaticRelations() throws {
        let engine = NoonmarkEngine()
        let seedID = try engine.createPoolTask(title: "分类目录", now: base)
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: seedID,
                category: .new(name: "项目", colorHex: "#2A6FDB"),
                labels: [
                    .new(name: "领域", colorHex: "#0E9488"),
                    .new(name: "显式", colorHex: "#D1477A"),
                    .new(name: "烛龙", colorHex: "#7C5CFF"),
                    .new(name: "自动", colorHex: "#F59E0B")
                ]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )
        let catalogState = engine.snapshot().classifications
        let seed = try XCTUnwrap(catalogState.currentByChainID[seedID])
        let categoryID = try XCTUnwrap(seed.categoryID)
        let labelIDsByName = try Dictionary(
            uniqueKeysWithValues: seed.labels.map { relation in
                let label = try XCTUnwrap(
                    catalogState.labels[relation.labelID]
                )
                return (label.name, relation.labelID)
            }
        )
        let deterministicLabelID = try XCTUnwrap(labelIDsByName["领域"])
        let userLabelID = try XCTUnwrap(labelIDsByName["显式"])
        let zhulongLabelID = try XCTUnwrap(labelIDsByName["烛龙"])
        let automaticLabelID = try XCTUnwrap(labelIDsByName["自动"])
        let beforeCreation = engine.snapshot()

        let chainID = try engine.createPoolTask(
            title: "混合来源的新任务",
            now: base.addingTimeInterval(2)
        )
        try commitDeterministicClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: .existing(categoryID),
                labels: [.existing(deterministicLabelID)]
            ),
            to: engine,
            at: base.addingTimeInterval(3)
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: .existing(categoryID),
                labels: [
                    .existing(deterministicLabelID),
                    .existing(userLabelID)
                ]
            ),
            to: engine,
            at: base.addingTimeInterval(4)
        )
        let zhulongSource = ClassificationSource.zhulongSuggestion(
            sessionID: UUID(),
            draftID: UUID(),
            draftVersion: 1,
            evidenceID: UUID()
        )
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: chainID,
                category: .existing(categoryID),
                labels: [
                    .existing(deterministicLabelID),
                    .existing(userLabelID),
                    .existing(zhulongLabelID)
                ]
            ),
            source: zhulongSource,
            to: engine,
            at: base.addingTimeInterval(5)
        )
        let context = try engine.issueAutomaticClassificationContext(
            for: chainID,
            jobID: jobID,
            generation: 1
        )
        let automaticPlan = try engine.prepareAutomaticClassification(
            AutomaticClassificationApplicationProposal(
                category: .existing(categoryID),
                labels: [.existing(automaticLabelID)]
            ),
            authority: context.authority,
            interactionID: UUID()
        )
        _ = try engine.commitAutomaticClassification(
            automaticPlan,
            authority: context.authority,
            now: base.addingTimeInterval(6)
        )
        let afterCreation = engine.snapshot()

        let undone = try NoonmarkEngine(snapshot: beforeCreation)
        _ = try undone.prepareSnapshotUndo(
            replacing: afterCreation,
            now: base.addingTimeInterval(7)
        )
        let current = try XCTUnwrap(
            undone.snapshot().classifications.currentByChainID[chainID]
        )
        XCTAssertEqual(
            current.category?.source,
            .deterministicDomainAction(reason: "test domain classification")
        )
        XCTAssertEqual(Set(current.labels.map(\.labelID)), [
            deterministicLabelID,
            userLabelID,
            zhulongLabelID
        ])
        XCTAssertTrue(current.labels.contains {
            $0.labelID == deterministicLabelID
                && $0.source == .deterministicDomainAction(
                    reason: "test domain classification"
                )
        })
        XCTAssertTrue(current.labels.contains {
            $0.labelID == userLabelID && $0.source == .userDirect
        })
        XCTAssertTrue(current.labels.contains {
            $0.labelID == zhulongLabelID && $0.source == zhulongSource
        })
        XCTAssertFalse(current.labels.contains { $0.labelID == automaticLabelID })

        let redone = try NoonmarkEngine(snapshot: afterCreation)
        _ = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(8)
        )
        XCTAssertEqual(
            redone.snapshot().classifications.currentByChainID[chainID],
            current
        )
    }

    func testSnapshotUndoAndRedoKeepInheritedClassificationFromCopiedTask() throws {
        let engine = NoonmarkEngine()
        let today = LocalDate(year: 2026, month: 7, day: 20)
        let sourceChainID = try engine.createPoolTask(title: "复制来源", now: base)
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: sourceChainID,
                category: .new(name: "项目", colorHex: "#2A6FDB"),
                labels: [.new(name: "跟进", colorHex: "#0E9488")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(2)
        )
        let beforeCopy = engine.snapshot()
        let copiedChainID = try engine.copyAsNewTask(
            from: sourceTraceID,
            target: .taskPool,
            today: today,
            now: base.addingTimeInterval(3)
        )
        let afterCopy = engine.snapshot()

        let undone = try NoonmarkEngine(snapshot: beforeCopy)
        let undoOutcome = try undone.prepareSnapshotUndo(
            replacing: afterCopy,
            now: base.addingTimeInterval(4)
        )
        XCTAssertEqual(
            undoOutcome.automaticClassificationCancelledChainIDs,
            [copiedChainID]
        )
        let undoneCurrent = try XCTUnwrap(
            undone.snapshot().classifications.currentByChainID[copiedChainID]
        )
        XCTAssertEqual(
            undoneCurrent.category?.source,
            .inherited(fromChainID: sourceChainID)
        )
        XCTAssertTrue(undoneCurrent.labels.allSatisfy {
            $0.source == .inherited(fromChainID: sourceChainID)
        })

        let redone = try NoonmarkEngine(snapshot: afterCopy)
        let redoOutcome = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(5)
        )
        XCTAssertEqual(
            redoOutcome.automaticClassificationRestoredChainIDs,
            [copiedChainID]
        )
        XCTAssertEqual(
            redone.snapshot().classifications.currentByChainID[copiedChainID],
            undoneCurrent
        )
    }

    func testSnapshotUndoAndRedoKeepInheritedClassificationFromChangedTask() throws {
        let engine = NoonmarkEngine()
        let today = LocalDate(year: 2026, month: 7, day: 20)
        let sourceChainID = try engine.createPoolTask(title: "变更来源", now: base)
        try commitUserClassification(
            TaskClassificationDraft(
                chainID: sourceChainID,
                category: .new(name: "工作", colorHex: "#2A6FDB"),
                labels: [.new(name: "专注", colorHex: "#0E9488")]
            ),
            to: engine,
            at: base.addingTimeInterval(1)
        )
        let sourceTraceID = try engine.scheduleFromPool(
            chainID: sourceChainID,
            date: today,
            today: today,
            now: base.addingTimeInterval(2)
        )
        let beforeChange = engine.snapshot()
        let replacementTraceID = try engine.changeTrace(
            traceID: sourceTraceID,
            newTitle: "变更后的任务",
            today: today,
            now: base.addingTimeInterval(3)
        )
        let replacementChainID = try XCTUnwrap(
            engine.traces[replacementTraceID]?.chainID
        )
        let afterChange = engine.snapshot()

        let undone = try NoonmarkEngine(snapshot: beforeChange)
        _ = try undone.prepareSnapshotUndo(
            replacing: afterChange,
            now: base.addingTimeInterval(4)
        )
        let undoneCurrent = try XCTUnwrap(
            undone.snapshot().classifications.currentByChainID[replacementChainID]
        )
        XCTAssertEqual(
            undoneCurrent.category?.source,
            .inherited(fromChainID: sourceChainID)
        )
        XCTAssertTrue(undoneCurrent.labels.allSatisfy {
            $0.source == .inherited(fromChainID: sourceChainID)
        })

        let redone = try NoonmarkEngine(snapshot: afterChange)
        _ = try redone.prepareSnapshotUndo(
            replacing: undone.snapshot(),
            now: base.addingTimeInterval(5)
        )
        XCTAssertEqual(
            redone.snapshot().classifications.currentByChainID[replacementChainID],
            undoneCurrent
        )
    }

    private func proposal() -> AutomaticClassificationApplicationProposal {
        AutomaticClassificationApplicationProposal(
            category: .new(name: "工作", colorHex: "#2A6FDB"),
            labels: [.new(name: "行动", colorHex: "#0E9488")]
        )
    }

    private func assertCatalogFenceRejects(
        _ authority: AutomaticTaskClassificationAuthority,
        in engine: NoonmarkEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try engine.prepareAutomaticClassification(
                proposal(),
                authority: authority,
                interactionID: UUID()
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("automatic classification catalog changed"),
                file: file,
                line: line
            )
        }
    }

    private func commitUserClassification(
        _ draft: TaskClassificationDraft,
        source: ClassificationSource = .userDirect,
        to engine: NoonmarkEngine,
        at now: Date
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(draft),
            source: source,
            interactionID: UUID(),
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: now
        )
    }

    private func commitUserIntent(
        _ intent: ClassificationIntent,
        to engine: NoonmarkEngine,
        at now: Date
    ) throws {
        let plan = try engine.prepareClassification(
            intent,
            source: .userDirect,
            interactionID: UUID(),
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: UUID()),
            now: now
        )
    }

    private func commitDeterministicClassification(
        _ draft: TaskClassificationDraft,
        to engine: NoonmarkEngine,
        at now: Date
    ) throws {
        let plan = try engine.prepareClassification(
            .setCurrent(draft),
            source: .deterministicDomainAction(
                reason: "test domain classification"
            ),
            interactionID: UUID(),
            now: now
        )
        try engine.commitDeterministicDomainClassification(plan, now: now)
    }

    private func taskProjection(
        from projection: ClassificationProjection
    ) throws -> TaskClassificationProjection {
        guard case let .task(task) = projection else {
            throw NoonmarkError.invalidInput("expected task classification projection")
        }
        return task
    }
}

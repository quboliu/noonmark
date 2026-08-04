@testable import NoonmarkCore
import XCTest

final class IdeaEntryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    func testAppendIdeaNormalizesBodyAndDedupesLabels() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let labelID = try XCTUnwrap(catalog.labelIDs.first)

        let idea = try engine.appendIdea(
            body: "  把晨间灵感做成提醒\n",
            categoryID: catalog.categoryID,
            labelIDs: [labelID, labelID],
            now: now
        )

        XCTAssertEqual(idea.body, "把晨间灵感做成提醒")
        XCTAssertEqual(idea.categoryID, catalog.categoryID)
        XCTAssertEqual(idea.labelIDs, [labelID])
        XCTAssertEqual(idea.createdAt, now)
        XCTAssertEqual(idea.updatedAt, now)
        XCTAssertNil(idea.deletedAt)
        XCTAssertNil(idea.pinnedAt)
        XCTAssertFalse(idea.isDeleted)
        XCTAssertEqual(engine.ideas[idea.id], idea)
    }

    func testCopyingEnginePreservesIdeas() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "复制后仍在", now: now)

        let copy = NoonmarkEngine(copying: engine)

        XCTAssertEqual(copy.ideas, engine.ideas)
        XCTAssertEqual(copy.ideaTimeline(), [idea])
        XCTAssertEqual(copy.snapshot().ideas, engine.snapshot().ideas)
    }

    func testAppendIdeaRejectsEmptyBody() throws {
        let engine = NoonmarkEngine()

        XCTAssertThrowsError(
            try engine.appendIdea(body: "  \n ", now: now)
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("idea body cannot be empty")
            )
        }
        XCTAssertTrue(engine.ideas.isEmpty)
    }

    func testAppendIdeaRejectsMissingClassificationItems() throws {
        let engine = NoonmarkEngine()

        XCTAssertThrowsError(
            try engine.appendIdea(
                body: "未知分类",
                categoryID: TaskCategoryID(),
                now: now
            )
        )
        XCTAssertThrowsError(
            try engine.appendIdea(
                body: "未知标签",
                labelIDs: [TaskLabelID()],
                now: now
            )
        )
        XCTAssertTrue(engine.ideas.isEmpty)
    }

    func testEditIdeaUpdatesBodyAndContentClock() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "旧想法", now: now)
        let editAt = now.addingTimeInterval(10)

        try engine.editIdea(id: idea.id, body: " 新想法 ", now: editAt)

        let updated = try XCTUnwrap(engine.ideas[idea.id])
        XCTAssertEqual(updated.body, "新想法")
        XCTAssertEqual(updated.createdAt, now)
        XCTAssertEqual(updated.updatedAt, editAt)
    }

    func testEditIdeaRejectsEmptyBodyAndBackwardsClock() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "守住内容", now: now)

        XCTAssertThrowsError(
            try engine.editIdea(id: idea.id, body: " ", now: now)
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("idea body cannot be empty")
            )
        }
        XCTAssertThrowsError(
            try engine.editIdea(
                id: idea.id,
                body: "倒退",
                now: now.addingTimeInterval(-1)
            )
        )
        XCTAssertEqual(engine.ideas[idea.id]?.body, "守住内容")
    }

    func testDeleteIdeaTombstonesAndRejectsRepeatedMutation() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let idea = try engine.appendIdea(
            body: "待删除",
            categoryID: catalog.categoryID,
            labelIDs: catalog.labelIDs,
            now: now
        )
        let deleteAt = now.addingTimeInterval(10)

        try engine.deleteIdea(id: idea.id, now: deleteAt)

        let tombstone = try XCTUnwrap(engine.ideas[idea.id])
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertEqual(tombstone.deletedAt, deleteAt)
        XCTAssertEqual(tombstone.updatedAt, deleteAt)
        XCTAssertEqual(tombstone.body, "")
        XCTAssertNil(tombstone.categoryID)
        XCTAssertEqual(tombstone.labelIDs, [])
        XCTAssertTrue(engine.ideaTimeline().isEmpty)

        XCTAssertThrowsError(
            try engine.deleteIdea(id: idea.id, now: deleteAt.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }
        XCTAssertThrowsError(
            try engine.editIdea(
                id: idea.id,
                body: "复活",
                now: deleteAt.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }
        XCTAssertThrowsError(
            try engine.setIdeaClassification(
                id: idea.id,
                categoryID: catalog.categoryID,
                now: deleteAt.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }
    }

    func testSetIdeaClassificationAssignsClearsAndValidates() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let labelID = try XCTUnwrap(catalog.labelIDs.first)
        let idea = try engine.appendIdea(body: "可分类", now: now)
        let classifyAt = now.addingTimeInterval(10)

        try engine.setIdeaClassification(
            id: idea.id,
            categoryID: catalog.categoryID,
            labelIDs: [labelID, labelID],
            now: classifyAt
        )

        var updated = try XCTUnwrap(engine.ideas[idea.id])
        XCTAssertEqual(updated.categoryID, catalog.categoryID)
        XCTAssertEqual(updated.labelIDs, [labelID])
        XCTAssertEqual(updated.updatedAt, classifyAt)

        try engine.setIdeaClassification(
            id: idea.id,
            categoryID: nil,
            labelIDs: [],
            now: classifyAt.addingTimeInterval(1)
        )

        updated = try XCTUnwrap(engine.ideas[idea.id])
        XCTAssertNil(updated.categoryID)
        XCTAssertEqual(updated.labelIDs, [])

        XCTAssertThrowsError(
            try engine.setIdeaClassification(
                id: idea.id,
                categoryID: TaskCategoryID(),
                now: classifyAt.addingTimeInterval(2)
            )
        )
        XCTAssertThrowsError(
            try engine.setIdeaClassification(
                id: idea.id,
                categoryID: nil,
                labelIDs: [TaskLabelID()],
                now: classifyAt.addingTimeInterval(2)
            )
        )
    }

    func testIdeaTimelineOrdersNewestFirstAndFiltersCaseInsensitively() throws {
        let engine = NoonmarkEngine()
        let oldest = try engine.appendIdea(
            body: "alpha 提醒",
            now: now
        )
        let middle = try engine.appendIdea(
            body: "无关想法",
            now: now.addingTimeInterval(10)
        )
        let newest = try engine.appendIdea(
            body: "Alpha 续写",
            now: now.addingTimeInterval(20)
        )
        try engine.deleteIdea(
            id: middle.id,
            now: now.addingTimeInterval(30)
        )

        XCTAssertEqual(
            engine.ideaTimeline().map(\.id),
            [newest.id, oldest.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(filter: "ALPHA").map(\.id),
            [newest.id, oldest.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(filter: "提醒").map(\.id),
            [oldest.id]
        )
        XCTAssertTrue(engine.ideaTimeline(filter: "不存在的词").isEmpty)
        XCTAssertEqual(
            engine.ideaTimeline(filter: "  ").map(\.id),
            [newest.id, oldest.id]
        )
    }

    func testIdeaTimelineByDayGroupsDescending() throws {
        let engine = NoonmarkEngine()
        let dayOneAt = now
        let dayTwoAt = now.addingTimeInterval(86400)
        let first = try engine.appendIdea(body: "第一天早", now: dayOneAt)
        let second = try engine.appendIdea(
            body: "第一天晚",
            now: dayOneAt.addingTimeInterval(3600)
        )
        let third = try engine.appendIdea(body: "第二天", now: dayTwoAt)

        let groups = engine.ideaTimelineByDay(calendar: utcCalendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(
            groups[0].date,
            LocalDate("2027-01-16")
        )
        XCTAssertEqual(groups[0].ideas.map(\.id), [third.id])
        XCTAssertEqual(
            groups[1].date,
            LocalDate("2027-01-15")
        )
        XCTAssertEqual(groups[1].ideas.map(\.id), [second.id, first.id])
    }

    func testReviewCollectionExcludesRecentIdeasAndIsDeterministic() throws {
        let engine = NoonmarkEngine()
        let oldOne = try engine.appendIdea(
            body: "一个月前",
            now: Date(timeIntervalSince1970: 1_797_235_200)
        )
        let oldTwo = try engine.appendIdea(
            body: "两周前",
            now: Date(timeIntervalSince1970: 1_798_531_200)
        )
        _ = try engine.appendIdea(
            body: "昨天",
            now: Date(timeIntervalSince1970: 1_799_913_600)
        )
        let query = IdeaCollectionQuery.review(
            seed: 42,
            count: 2,
            excludingRecentDays: 7
        )

        let first = engine.ideaCollection(
            query,
            today: LocalDate("2027-01-15"),
            calendar: utcCalendar
        )
        let second = engine.ideaCollection(
            query,
            today: LocalDate("2027-01-15"),
            calendar: utcCalendar
        )

        XCTAssertEqual(first.ideas, second.ideas)
        XCTAssertEqual(Set(first.ideas.map(\.id)), Set([oldOne.id, oldTwo.id]))
        XCTAssertEqual(first.groups.flatMap(\.ideas), first.ideas)
    }

    func testFlylightCollectionKeepsStickyNotesInSourceTimeline() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let labelID = try XCTUnwrap(catalog.labelIDs.first)
        let regular = try engine.appendIdea(
            body: "正文命中",
            categoryID: catalog.categoryID,
            labelIDs: [labelID],
            now: now
        )
        let pinned = try engine.appendIdea(
            body: "另一个正文",
            categoryID: catalog.categoryID,
            labelIDs: [labelID],
            now: now.addingTimeInterval(1)
        )
        try engine.pinIdea(id: pinned.id, now: now.addingTimeInterval(2))

        let collection = engine.ideaCollection(
            .filtered(
                IdeaTimelineFilter(
                    text: "产品",
                    categoryID: catalog.categoryID,
                    labelID: labelID
                )
            ),
            today: LocalDate("2027-01-15"),
            calendar: utcCalendar
        )

        XCTAssertEqual(collection.ideas.map(\.id), [pinned.id, regular.id])
        XCTAssertEqual(collection.pinnedIdeas.map(\.id), [pinned.id])
        XCTAssertEqual(
            collection.groups.flatMap(\.ideas).map(\.id),
            [pinned.id, regular.id]
        )
    }

    func testNextMutationDateAdvancesPastPersistedIdeaClock() throws {
        let engine = NoonmarkEngine()
        let ideaAt = now.addingTimeInterval(100)
        _ = try engine.appendIdea(body: "未来写入", now: ideaAt)

        let next = try engine.nextMutationDate(reference: now)

        XCTAssertEqual(
            next.timeIntervalSinceReferenceDate,
            ideaAt.timeIntervalSinceReferenceDate.nextUp
        )
    }

    func testSnapshotCodableRoundTripPreservesIdeas() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let kept = try engine.appendIdea(
            body: "保留",
            categoryID: catalog.categoryID,
            labelIDs: catalog.labelIDs,
            now: now.addingTimeInterval(1)
        )
        let removed = try engine.appendIdea(
            body: "删除",
            now: now.addingTimeInterval(2)
        )
        try engine.deleteIdea(
            id: removed.id,
            now: now.addingTimeInterval(3)
        )
        try engine.pinIdea(
            id: kept.id,
            now: now.addingTimeInterval(4)
        )
        let snapshot = engine.snapshot()
        XCTAssertNoThrow(try snapshot.validateIntegrity())

        let decoded = try JSONDecoder().decode(
            NoonmarkSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        let restored = try NoonmarkEngine(snapshot: decoded)
        XCTAssertTrue(restored.ideaTimeline().isEmpty)
        XCTAssertEqual(restored.pinnedIdeas().map(\.id), [kept.id])
        XCTAssertEqual(
            restored.ideas[kept.id]?.pinnedAt,
            now.addingTimeInterval(4)
        )
        XCTAssertEqual(restored.ideas[removed.id]?.isDeleted, true)
    }

    func testSnapshotIntegrityRejectsIdeaReferencingMissingClassification() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        _ = try engine.appendIdea(
            body: "悬空引用",
            categoryID: catalog.categoryID,
            labelIDs: catalog.labelIDs,
            now: now.addingTimeInterval(1)
        )
        var snapshot = engine.snapshot()
        snapshot.classifications = TaskClassificationState()

        XCTAssertThrowsError(try snapshot.validateIntegrity()) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("idea references missing classification")
            )
        }
    }

    func testSnapshotIntegrityRejectsDuplicateIdeaIdentities() throws {
        let engine = NoonmarkEngine()
        _ = try engine.appendIdea(body: "唯一", now: now)
        let data = try JSONEncoder().encode(engine.snapshot())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var ideas = try XCTUnwrap(object["ideas"] as? [[String: Any]])
        ideas.append(try XCTUnwrap(ideas.first))
        object["ideas"] = ideas
        let forged = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(
            NoonmarkSnapshot.self,
            from: forged
        )

        XCTAssertThrowsError(try decoded.validateIntegrity()) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidInput("snapshot contains duplicate idea identities")
            )
        }
    }

    func testIdeaEntryDecodeRejectsInvalidContentFacts() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "可解码", now: now)
        let data = try JSONEncoder().encode(idea)
        let createdAtSeconds = now.timeIntervalSinceReferenceDate

        let backwardsClock = try tamper(data) { object in
            object["updatedAt"] = createdAtSeconds - 1
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: backwardsClock)
        )

        let paddedBody = try tamper(data) { object in
            object["body"] = " 可解码 "
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: paddedBody)
        )

        let duplicateLabels = try tamper(data) { object in
            let label = UUID().uuidString
            object["labelIDs"] = [label, label]
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: duplicateLabels)
        )
    }

    func testIdeaEntryDecodeRejectsTombstoneCarryingContent() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "将删除", now: now)
        try engine.deleteIdea(id: idea.id, now: now.addingTimeInterval(1))
        let tombstone = try XCTUnwrap(engine.ideas[idea.id])
        let data = try JSONEncoder().encode(tombstone)

        let bodyCarrying = try tamper(data) { object in
            object["body"] = "残留"
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: bodyCarrying)
        )
    }

    func testPinIdeaSurfacesInPinnedProjectionAndLeavesTimeline() throws {
        let engine = NoonmarkEngine()
        let first = try engine.appendIdea(body: "先置顶", now: now)
        let second = try engine.appendIdea(
            body: "后置顶",
            now: now.addingTimeInterval(1)
        )
        let plain = try engine.appendIdea(
            body: "普通",
            now: now.addingTimeInterval(2)
        )

        try engine.pinIdea(id: first.id, now: now.addingTimeInterval(3))
        try engine.pinIdea(id: second.id, now: now.addingTimeInterval(4))

        XCTAssertEqual(engine.pinnedIdeas().map(\.id), [second.id, first.id])
        XCTAssertEqual(engine.ideaTimeline().map(\.id), [plain.id])
        XCTAssertEqual(
            engine.ideas[first.id]?.pinnedAt,
            now.addingTimeInterval(3)
        )
        XCTAssertEqual(
            engine.ideas[first.id]?.updatedAt,
            now.addingTimeInterval(3)
        )

        try engine.unpinIdea(id: second.id, now: now.addingTimeInterval(5))

        XCTAssertEqual(engine.pinnedIdeas().map(\.id), [first.id])
        XCTAssertEqual(
            engine.ideaTimeline().map(\.id),
            [plain.id, second.id]
        )
        XCTAssertNil(engine.ideas[second.id]?.pinnedAt)
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testPinIdeaRejectsTombstoneAndBackwardsClock() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "会删除", now: now)
        try engine.deleteIdea(id: idea.id, now: now.addingTimeInterval(1))

        XCTAssertThrowsError(
            try engine.pinIdea(id: idea.id, now: now.addingTimeInterval(2))
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }
        XCTAssertThrowsError(
            try engine.unpinIdea(id: idea.id, now: now.addingTimeInterval(2))
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }

        let active = try engine.appendIdea(
            body: "活跃",
            now: now.addingTimeInterval(2)
        )
        XCTAssertThrowsError(
            try engine.pinIdea(id: active.id, now: now.addingTimeInterval(1))
        )
        XCTAssertNil(engine.ideas[active.id]?.pinnedAt)
    }

    func testDeleteIdeaClearsPinnedAt() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "置顶后删除", now: now)
        try engine.pinIdea(id: idea.id, now: now.addingTimeInterval(1))
        try engine.deleteIdea(id: idea.id, now: now.addingTimeInterval(2))

        let tombstone = try XCTUnwrap(engine.ideas[idea.id])
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertNil(tombstone.pinnedAt)
        XCTAssertTrue(engine.pinnedIdeas().isEmpty)
        XCTAssertTrue(engine.ideaTimeline().isEmpty)
        XCTAssertEqual(engine.ideaTrash().map(\.id), [idea.id])
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testRestoreIdeaReturnsToTimelineAndShrinksTrash() throws {
        let engine = NoonmarkEngine()
        let kept = try engine.appendIdea(body: "保留", now: now)
        let doomed = try engine.appendIdea(
            body: "删掉再恢复",
            now: now.addingTimeInterval(1)
        )
        try engine.pinIdea(id: doomed.id, now: now.addingTimeInterval(2))
        try engine.deleteIdea(id: doomed.id, now: now.addingTimeInterval(3))
        XCTAssertEqual(engine.ideaTrash().map(\.id), [doomed.id])

        try engine.restoreIdea(
            id: doomed.id,
            body: " 恢复后的正文 ",
            now: now.addingTimeInterval(4)
        )

        let restored = try XCTUnwrap(engine.ideas[doomed.id])
        XCTAssertFalse(restored.isDeleted)
        XCTAssertNil(restored.deletedAt)
        XCTAssertNil(restored.pinnedAt)
        XCTAssertEqual(restored.body, "恢复后的正文")
        XCTAssertEqual(restored.updatedAt, now.addingTimeInterval(4))
        XCTAssertTrue(engine.ideaTrash().isEmpty)
        XCTAssertTrue(engine.pinnedIdeas().isEmpty)
        XCTAssertEqual(
            engine.ideaTimeline().map(\.id),
            [doomed.id, kept.id]
        )
        XCTAssertNoThrow(try engine.snapshot().validateIntegrity())
    }

    func testRestoreIdeaRejectsActiveMissingAndEmptyBody() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "活着", now: now)

        XCTAssertThrowsError(
            try engine.restoreIdea(
                id: idea.id,
                body: "恢复",
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("only tombstoned ideas can be restored")
            )
        }
        XCTAssertThrowsError(
            try engine.restoreIdea(
                id: IdeaID(),
                body: "恢复",
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? NoonmarkError, .notFound("idea"))
        }

        try engine.deleteIdea(id: idea.id, now: now.addingTimeInterval(1))
        XCTAssertThrowsError(
            try engine.restoreIdea(
                id: idea.id,
                body: "  ",
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoonmarkError,
                .invalidTransition("idea body cannot be empty")
            )
        }
        XCTAssertEqual(engine.ideas[idea.id]?.isDeleted, true)
    }

    func testIdeaTrashOrdersNewestDeletionFirst() throws {
        let engine = NoonmarkEngine()
        let first = try engine.appendIdea(body: "甲", now: now)
        let second = try engine.appendIdea(
            body: "乙",
            now: now.addingTimeInterval(1)
        )
        let third = try engine.appendIdea(
            body: "丙",
            now: now.addingTimeInterval(2)
        )
        try engine.deleteIdea(id: second.id, now: now.addingTimeInterval(3))
        try engine.deleteIdea(id: third.id, now: now.addingTimeInterval(5))
        try engine.deleteIdea(id: first.id, now: now.addingTimeInterval(4))

        XCTAssertEqual(
            engine.ideaTrash().map(\.id),
            [third.id, first.id, second.id]
        )
        XCTAssertEqual(
            engine.ideaTrash().map(\.deletedAt),
            [
                now.addingTimeInterval(5),
                now.addingTimeInterval(4),
                now.addingTimeInterval(3)
            ]
        )
        XCTAssertTrue(engine.ideaTimeline().isEmpty)
        XCTAssertTrue(engine.pinnedIdeas().isEmpty)
    }

    func testIdeaTimelineFilterMatchesCategoryLabelAndText() throws {
        let engine = NoonmarkEngine()
        let catalog = try seedClassificationCatalog(in: engine)
        let labelID = try XCTUnwrap(catalog.labelIDs.first)
        let categorized = try engine.appendIdea(
            body: "alpha 分类想法",
            categoryID: catalog.categoryID,
            now: now
        )
        let labeled = try engine.appendIdea(
            body: "alpha 标签想法",
            labelIDs: [labelID],
            now: now.addingTimeInterval(1)
        )
        let both = try engine.appendIdea(
            body: "beta 双标想法",
            categoryID: catalog.categoryID,
            labelIDs: [labelID],
            now: now.addingTimeInterval(2)
        )
        let pinned = try engine.appendIdea(
            body: "alpha 置顶分类",
            categoryID: catalog.categoryID,
            now: now.addingTimeInterval(3)
        )
        try engine.pinIdea(id: pinned.id, now: now.addingTimeInterval(4))

        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(categoryID: catalog.categoryID)
            ).map(\.id),
            [both.id, categorized.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(labelID: labelID)
            ).map(\.id),
            [both.id, labeled.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(
                    text: "ALPHA",
                    categoryID: catalog.categoryID
                )
            ).map(\.id),
            [categorized.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(text: "alpha", labelID: labelID)
            ).map(\.id),
            [labeled.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(text: "产品")
            ).map(\.id),
            [both.id, labeled.id]
        )
        XCTAssertEqual(
            engine.ideaTimeline(
                filter: IdeaTimelineFilter(text: "灵感")
            ).map(\.id),
            [both.id, categorized.id]
        )
        XCTAssertEqual(
            engine.pinnedIdeas(
                filter: IdeaTimelineFilter(categoryID: catalog.categoryID)
            ).map(\.id),
            [pinned.id]
        )
        XCTAssertTrue(
            engine.pinnedIdeas(
                filter: IdeaTimelineFilter(labelID: labelID)
            ).isEmpty
        )

        let groups = engine.ideaTimelineByDay(
            filter: IdeaTimelineFilter(categoryID: catalog.categoryID),
            calendar: utcCalendar
        )
        XCTAssertEqual(
            groups.flatMap(\.ideas).map(\.id),
            [both.id, categorized.id]
        )
    }

    func testIdeaEntryDecodeRejectsInvalidPinFacts() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "可置顶", now: now)
        try engine.pinIdea(id: idea.id, now: now.addingTimeInterval(1))
        let pinned = try XCTUnwrap(engine.ideas[idea.id])
        let data = try JSONEncoder().encode(pinned)
        let createdAtSeconds = now.timeIntervalSinceReferenceDate

        let backwardsPin = try tamper(data) { object in
            object["pinnedAt"] = createdAtSeconds - 1
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: backwardsPin)
        )

        let pinAfterUpdate = try tamper(data) { object in
            object["pinnedAt"] = createdAtSeconds + 10
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: pinAfterUpdate)
        )
    }

    func testIdeaEntryDecodeRejectsTombstoneCarryingPin() throws {
        let engine = NoonmarkEngine()
        let idea = try engine.appendIdea(body: "将删除", now: now)
        try engine.deleteIdea(id: idea.id, now: now.addingTimeInterval(1))
        let tombstone = try XCTUnwrap(engine.ideas[idea.id])
        let data = try JSONEncoder().encode(tombstone)

        let pinnedTombstone = try tamper(data) { object in
            object["pinnedAt"] = now.addingTimeInterval(1)
                .timeIntervalSinceReferenceDate
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(IdeaEntry.self, from: pinnedTombstone)
        )
    }

    private func seedClassificationCatalog(
        in engine: NoonmarkEngine
    ) throws -> (categoryID: TaskCategoryID, labelIDs: [TaskLabelID]) {
        let chainID = try engine.createPoolTask(title: "分类目录锚点", now: now)
        let interactionID = UUID()
        let plan = try engine.prepareClassification(
            .setCurrent(
                TaskClassificationDraft(
                    chainID: chainID,
                    category: .new(name: "灵感", colorHex: "#2A6FDB"),
                    labels: [.new(name: "产品", colorHex: "#0E9488")]
                )
            ),
            source: .userDirect,
            interactionID: interactionID,
            now: now
        )
        _ = try engine.commitClassification(
            plan,
            confirmation: .user(decisionID: interactionID),
            now: now
        )
        let current = try XCTUnwrap(
            engine.snapshot().classifications.currentByChainID[chainID]
        )
        return try (
            XCTUnwrap(current.categoryID),
            Array(current.labelIDs)
        )
    }

    private func tamper(
        _ data: Data,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

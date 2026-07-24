@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongConversationArtifactTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let today = LocalDate("2026-07-24")

    func testPlainConversationRemainsAPlainMessage() throws {
        let turn = try ZhulongConversationTurnParser().parse(
            "我们先把目标和边界说清楚。"
        )

        XCTAssertEqual(turn.message, "我们先把目标和边界说清楚。")
        XCTAssertTrue(turn.artifacts.isEmpty)
    }

    func testTaskPlanArtifactPreservesParentSubtasksAndDestinations() throws {
        let response = """
        我整理成两项任务，你可以直接修改后提交。

        <noonmark-artifacts>
        {
          "artifacts": [
            {
              "kind": "taskPlan",
              "tasks": [
                {
                  "title": "重做烛龙",
                  "description": "让对话直接形成可执行任务",
                  "note": null,
                  "destination": { "kind": "today" },
                  "subtasks": [
                    { "title": "重构对话协议", "difficulty": "medium" },
                    { "title": "实现任务草稿卡", "difficulty": "hard" },
                    { "title": "验证一次提交", "difficulty": "simple" }
                  ]
                },
                {
                  "title": "整理后续想法",
                  "description": null,
                  "note": null,
                  "destination": { "kind": "pool" },
                  "subtasks": []
                },
                {
                  "title": "下周复查",
                  "description": null,
                  "note": null,
                  "destination": { "kind": "date", "date": "2026-07-30" },
                  "subtasks": []
                }
              ]
            }
          ]
        }
        </noonmark-artifacts>
        """

        let turn = try ZhulongConversationTurnParser().parse(response)

        XCTAssertEqual(turn.message, "我整理成两项任务，你可以直接修改后提交。")
        XCTAssertEqual(turn.artifacts.count, 1)
        guard case let .taskPlan(plan) = try XCTUnwrap(turn.artifacts.first) else {
            return XCTFail("Expected a task-plan artifact")
        }
        XCTAssertEqual(
            plan.tasks.map(\.title),
            ["重做烛龙", "整理后续想法", "下周复查"]
        )
        XCTAssertEqual(plan.tasks[0].destination, .today)
        XCTAssertEqual(plan.tasks[1].destination, .taskPool)
        XCTAssertEqual(
            plan.tasks[2].destination,
            .date(LocalDate("2026-07-30"))
        )
        XCTAssertEqual(
            plan.tasks[0].subtasks.map(\.title),
            ["重构对话协议", "实现任务草稿卡", "验证一次提交"]
        )
        XCTAssertEqual(
            plan.tasks[0].subtasks.map(\.difficulty),
            [.medium, .hard, .simple]
        )
    }

    func testDailyReviewArtifactUsesTheSameConversationEnvelope() throws {
        let response = """
        我把复盘整理好了，你可以修改后保存。
        <noonmark-artifacts>
        {
          "artifacts": [
            {
              "kind": "dailyReview",
              "summary": "今天完成了核心交互。",
              "tomorrowNote": "明天继续验证真实写入。"
            }
          ]
        }
        </noonmark-artifacts>
        """

        let turn = try ZhulongConversationTurnParser().parse(response)

        guard case let .dailyReview(review) = try XCTUnwrap(turn.artifacts.first) else {
            return XCTFail("Expected a daily-review artifact")
        }
        XCTAssertEqual(review.summary, "今天完成了核心交互。")
        XCTAssertEqual(review.tomorrowNote, "明天继续验证真实写入。")
    }

    func testMalformedTaggedArtifactFailsClosed() {
        XCTAssertThrowsError(
            try ZhulongConversationTurnParser().parse(
                """
                这里有一份计划。
                <noonmark-artifacts>{"artifacts":[{"kind":"taskPlan"}]}</noonmark-artifacts>
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongConversationArtifactError,
                .invalidArtifact
            )
        }
    }

    func testWrongOptionalFieldTypeFailsClosed() {
        XCTAssertThrowsError(
            try ZhulongConversationTurnParser().parse(
                """
                这里有一份计划。
                <noonmark-artifacts>
                {"artifacts":[{"kind":"taskPlan","tasks":[{"title":"任务","description":42,"note":null,"destination":{"kind":"pool"},"subtasks":[]}]}]}
                </noonmark-artifacts>
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongConversationArtifactError,
                .invalidArtifact
            )
        }
    }

    func testStreamingProjectionHidesArtifactProtocol() {
        let tag = ZhulongConversationTurnParser.openingTag
        for split in 1 ... tag.count {
            XCTAssertEqual(
                ZhulongConversationTurnParser.visibleMessage(
                    in: "先看计划。\n\(tag.prefix(split))"
                ),
                "先看计划。",
                "split \(split)"
            )
        }
    }

    func testInvalidCalendarDateFailsClosed() {
        XCTAssertThrowsError(
            try ZhulongConversationTurnParser().parse(
                """
                这里有一份计划。
                <noonmark-artifacts>
                {"artifacts":[{"kind":"taskPlan","tasks":[{"title":"任务","description":null,"note":null,"destination":{"kind":"date","date":"2026-02-31"},"subtasks":[]}]}]}
                </noonmark-artifacts>
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongConversationArtifactError,
                .invalidArtifact
            )
        }
    }

    func testConversationTaskPlanPublishesAndAppliesWithoutPlanningCeremony()
        throws
    {
        let identity = try makeProviderIdentity()
        let plan = try ZhulongConversationTaskPlan(
            tasks: [
                try ZhulongConversationTaskDraft(
                    title: "今天执行",
                    descriptionText: nil,
                    initialNoteBody: nil,
                    destination: .today,
                    subtasks: [
                        try ZhulongPlannedSubtaskDraft(
                            title: "第一步",
                            difficulty: .medium
                        )
                    ]
                ),
                try ZhulongConversationTaskDraft(
                    title: "稍后再排",
                    descriptionText: nil,
                    initialNoteBody: nil,
                    destination: .taskPool,
                    subtasks: []
                ),
                try ZhulongConversationTaskDraft(
                    title: "未来执行",
                    descriptionText: nil,
                    initialNoteBody: nil,
                    destination: .date(
                        LocalDate("2026-07-30")
                    ),
                    subtasks: []
                )
            ]
        )
        var session = try ZhulongSession(
            primaryIntent: "帮我规划今天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            expiresAt: now.addingTimeInterval(600),
            now: now.addingTimeInterval(1)
        )
        let request = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(
                content: "我整理好了，你可以直接修改后提交。",
                draftVersion: 1,
                artifacts: [.taskPlan(plan)]
            ),
            runID: request.runID,
            now: now.addingTimeInterval(3)
        )
        var engine = NoonmarkEngine()
        let draft = try ZhulongTodoDiffDraft(
            sessionID: session.id,
            conversationRunID: request.runID,
            planningDate: today,
            sourceSnapshot: engine.snapshot(),
            createdAt: now.addingTimeInterval(4),
            items: plan.todoDiffItems(planningDate: today)
        )

        try session.publishConversationTodoDiff(
            draft,
            now: now.addingTimeInterval(4)
        )
        let revision = try ZhulongTodoDiffDraft(
            revising: draft,
            createdAt: now.addingTimeInterval(5),
            items: draft.items.map { item in
                guard case let .createTask(
                    title,
                    descriptionText,
                    initialNoteBody,
                    subtasks,
                    targetDate
                ) = item.operation else {
                    return item
                }
                return ZhulongTodoDiffItem(
                    id: item.id,
                    operation: .createTask(
                        title: "\(title)（已编辑）",
                        descriptionText: descriptionText,
                        initialNoteBody: initialNoteBody,
                        plannedSubtasks: subtasks,
                        targetDate: targetDate
                    )
                )
            }
        )
        try session.reviseTodoDiff(
            revision,
            now: now.addingTimeInterval(5)
        )
        _ = try session.authorizeTodoWrite(
            against: engine,
            today: today,
            now: now.addingTimeInterval(6)
        )
        let receipt = try session.applyAuthorizedTodoDiff(
            to: &engine,
            today: today,
            now: now.addingTimeInterval(7)
        )

        XCTAssertEqual(receipt.items.count, 3)
        XCTAssertEqual(
            engine.getDayTodo(date: today).traces.count,
            1
        )
        XCTAssertEqual(engine.taskPool().count, 1)
        XCTAssertEqual(
            engine.futurePlans(today: today).map {
                $0.definition.title
            },
            ["未来执行（已编辑）"]
        )
        XCTAssertNil(session.currentTodoDiff)
        XCTAssertEqual(session.latestTodoDiff?.id, revision.id)
        XCTAssertEqual(
            session.applyReceipt(for: revision)?.id,
            receipt.id
        )
        XCTAssertNil(session.applyReceipt(for: draft))
    }

    private func makePayload() throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "自然对话并生成结构化产物。",
            userPrompt: "帮我规划今天",
            contextVersion: "context-v2",
            scopeContent: [.currentDayTodo: "今天暂无任务"]
        )
    }
}

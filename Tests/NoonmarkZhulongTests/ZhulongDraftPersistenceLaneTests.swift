import Foundation
@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongDraftPersistenceLaneTests:
    XCTestCase
{
    private let now = Date(
        timeIntervalSince1970: 1_800_000_000
    )
    private let date = LocalDate("2026-07-24")

    func testStaleTodoSourceRebasesAcrossOrderedUserRevisions()
        async throws
    {
        let fixture = try makeTodoSession()
        let repository = LockedSessionRepository(
            fixture.session
        )
        let lane = ZhulongDraftPersistenceLane(
            repository: repository
        )

        var firstItems = fixture.draft.items
        firstItems[0] = try item(
            replacing: firstItems[0],
            title: "第一次后台保存"
        )
        let first = try await lane.reviseTodoDiff(
            sessionID: fixture.session.id,
            sourceDraftID: fixture.draft.id,
            items: firstItems,
            now: now.addingTimeInterval(10)
        )

        var latestItems = firstItems
        latestItems[0] = try item(
            replacing: latestItems[0],
            title: "输入期间产生的更新版本"
        )
        let second = try await lane.reviseTodoDiff(
            sessionID: fixture.session.id,
            sourceDraftID: fixture.draft.id,
            items: latestItems,
            now: now.addingTimeInterval(11)
        )

        let persisted = try repository.load(
            fixture.session.id
        )
        XCTAssertEqual(
            persisted.currentTodoDiff?.id,
            second.draftID
        )
        XCTAssertEqual(
            persisted.currentTodoDiff?.items,
            latestItems
        )
        XCTAssertEqual(
            persisted.todoDiffDrafts.count,
            fixture.session.todoDiffDrafts.count + 2
        )
        XCTAssertNotEqual(first.draftID, second.draftID)
    }

    func testFailedDailyReviewCommitDoesNotLeakIntoNextCommit()
        async throws
    {
        let fixture = try makeDailyReviewSession()
        let repository = LockedSessionRepository(
            fixture.session
        )
        let lane = ZhulongDraftPersistenceLane(
            repository: repository
        )
        repository.failNextSave()

        do {
            _ = try await lane.reviseDailyReview(
                sessionID: fixture.session.id,
                sourceDraftID: fixture.draft.id,
                summary: "不得泄漏的失败版本",
                tomorrowNote: "失败版本",
                now: now.addingTimeInterval(10)
            )
            XCTFail("Expected injected save failure")
        } catch LockedSessionRepository.Failure.injected {
            // Expected.
        }

        let commit = try await lane.reviseDailyReview(
            sessionID: fixture.session.id,
            sourceDraftID: fixture.draft.id,
            summary: "最终可信版本",
            tomorrowNote: "继续验证",
            now: now.addingTimeInterval(11)
        )
        let persisted = try repository.load(
            fixture.session.id
        )
        XCTAssertEqual(
            persisted.dailyReviewDrafts.last?.id,
            commit.draftID
        )
        XCTAssertEqual(
            persisted.dailyReviewDrafts.last?.summary,
            "最终可信版本"
        )
        XCTAssertFalse(
            persisted.dailyReviewDrafts.contains {
                $0.summary == "不得泄漏的失败版本"
            }
        )
    }

    private func makeTodoSession() throws -> (
        session: ZhulongSession,
        draft: ZhulongTodoDiffDraft
    ) {
        var session = try authorizedSession(
            purpose: .taskShaping
        )
        let payload = try ZhulongProviderPayload(
            systemPrompt: "返回结构化任务草稿。",
            userPrompt: "形成一个测试任务。",
            contextVersion: "draft-lane-v1",
            scopeContent: [
                .currentDayTodo: "当前没有任务"
            ]
        )
        let request = try session.beginProviderRun(
            payload: payload,
            providerIdentity: try providerIdentity(),
            now: now.addingTimeInterval(2)
        )
        let task = try ZhulongConversationTaskDraft(
            title: "初始任务",
            descriptionText: "初始描述",
            initialNoteBody: nil,
            destination: .today,
            subtasks: []
        )
        let plan = try ZhulongConversationTaskPlan(
            tasks: [task]
        )
        let response = ZhulongProviderResponse(
            content: "已形成任务。",
            draftVersion: 1,
            artifacts: [.taskPlan(plan)]
        )
        try session.recordProviderResponse(
            response,
            runID: request.runID,
            now: now.addingTimeInterval(3)
        )
        let draft = try ZhulongTodoDiffDraft(
            sessionID: session.id,
            conversationRunID: request.runID,
            planningDate: date,
            sourceSnapshot: NoonmarkEngine().snapshot(),
            createdAt: now.addingTimeInterval(4),
            items: plan.todoDiffItems(
                planningDate: date
            )
        )
        try session.publishConversationTodoDiff(
            draft,
            now: now.addingTimeInterval(4)
        )
        return (session, draft)
    }

    private func makeDailyReviewSession() throws -> (
        session: ZhulongSession,
        draft: ZhulongDailyReviewDraft
    ) {
        var session = try authorizedSession(
            purpose: .dailyClose
        )
        let close = try session.captureDailyClose(
            date: date,
            from: NoonmarkEngine(),
            now: now.addingTimeInterval(2)
        )
        let draft = try session.publishDailyReviewDraft(
            dailyCloseID: close.id,
            summary: "初始复盘",
            tomorrowNote: "初始明日事项",
            causeResolutionIDs: [],
            now: now.addingTimeInterval(3)
        )
        return (session, draft)
    }

    private func authorizedSession(
        purpose: ZhulongSessionPurpose
    ) throws -> ZhulongSession {
        var session = try ZhulongSession(
            primaryIntent: "验证草稿后台保存",
            purpose: purpose,
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: try providerIdentity(),
            now: now.addingTimeInterval(1)
        )
        return session
    }

    private func providerIdentity() throws
        -> ZhulongProviderConfigurationIdentity
    {
        try ZhulongProviderConfigurationIdentity(
            providerID: "draft-lane-test",
            kind: .localModel,
            baseURL: nil,
            location: .local,
            model: "deterministic",
            dataCapabilities: [
                .structuredOutput,
                .taskContext
            ]
        )
    }

    private func item(
        replacing source: ZhulongTodoDiffItem,
        title: String
    ) throws -> ZhulongTodoDiffItem {
        guard case let .createTask(
            _,
            descriptionText,
            note,
            subtasks,
            targetDate
        ) = source.operation else {
            throw ZhulongTodoDiffError.invalidOperation
        }
        return ZhulongTodoDiffItem(
            id: source.id,
            operation: .createTask(
                title: title,
                descriptionText: descriptionText,
                initialNoteBody: note,
                plannedSubtasks: subtasks,
                targetDate: targetDate
            )
        )
    }
}

private final class LockedSessionRepository:
    ZhulongSessionRepository,
    @unchecked Sendable
{
    enum Failure: Error {
        case injected
    }

    private let lock = NSLock()
    private var session: ZhulongSession
    private var failsNextSave = false

    init(_ session: ZhulongSession) {
        self.session = session
    }

    func failNextSave() {
        lock.withLock {
            failsNextSave = true
        }
    }

    func save(_ session: ZhulongSession) throws {
        try lock.withLock {
            try consumeInjectedFailure()
            self.session = session
        }
    }

    func save(
        _ replacement: ZhulongSession,
        replacing expected: ZhulongSession
    ) throws {
        try lock.withLock {
            try consumeInjectedFailure()
            guard session == expected else {
                throw ZhulongSidecarRepositoryError
                    .sessionConflict
            }
            session = replacement
        }
    }

    func load(
        _ id: ZhulongSessionID
    ) throws -> ZhulongSession {
        try lock.withLock {
            guard session.id == id else {
                throw ZhulongSidecarRepositoryError
                    .missingSession
            }
            return session
        }
    }

    private func consumeInjectedFailure() throws {
        guard failsNextSave else { return }
        failsNextSave = false
        throw Failure.injected
    }
}

@testable import SuntraceZhulong
import XCTest

final class ZhulongPlanningBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBriefRequiresGoalCriteriaActivityAndAuthorizedProposalScopes() throws {
        XCTAssertThrowsError(
            try ZhulongPlanningBriefDraft(
                goal: " ",
                successCriteria: ["通过验收"],
                hardConstraints: [],
                userDecisions: [],
                delegatedActivities: [.taskDecomposition],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [ZhulongSessionEntryID()]
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .emptyGoal)
        }

        var session = try makeSession()
        let draft = try makeDraft(for: session, dataScopes: [.taskPool])
        XCTAssertThrowsError(
            try session.publishPlanningBrief(draft, now: now.addingTimeInterval(1))
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .scopeOutsideSessionProposal)
        }
        XCTAssertTrue(session.planningBriefs.isEmpty)
    }

    func testReviewAndDelegationAreSeparateAndBindExactBriefProviderAndScopes() throws {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(
            makeDraft(for: session),
            now: now.addingTimeInterval(2)
        )

        XCTAssertNil(session.reviewedPlanningBrief)
        XCTAssertThrowsError(
            try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(3))
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .briefNotReviewed)
        }

        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(
            for: brief.id,
            now: now.addingTimeInterval(4)
        )

        XCTAssertEqual(session.reviewedPlanningBrief?.id, brief.id)
        XCTAssertEqual(delegation.sessionID, session.id)
        XCTAssertEqual(delegation.briefID, brief.id)
        XCTAssertEqual(delegation.briefVersion, 1)
        XCTAssertEqual(delegation.providerIdentity, session.authorization?.providerIdentity)
        XCTAssertEqual(delegation.dataScopes, brief.dataScopes)
        XCTAssertEqual(session.activePlanningDelegation, delegation)
        XCTAssertEqual(
            session.events.suffix(3).map(\.kind),
            [.planningBriefPublished, .planningBriefReviewed, .planningDelegationGranted]
        )
    }

    func testBlockingQuestionPreventsDelegationWithoutPartialMutation() throws {
        var session = try makeAuthorizedSession()
        let draft = try ZhulongPlanningBriefDraft(
            goal: "发布稳定版",
            successCriteria: ["真实 App E2E 通过"],
            hardConstraints: ["普通 Todo 必须离线可用"],
            userDecisions: ["先完成 Mac 版"],
            delegatedActivities: [.taskDecomposition, .riskReview],
            assumptions: [],
            openQuestions: [try ZhulongPlanningOpenQuestion(content: "发布日期是什么？", isBlocking: true)],
            dataScopes: [.currentDayTodo],
            sourceEntryIDs: [session.entries[0].id]
        )
        let brief = try session.publishPlanningBrief(draft, now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let events = session.events

        XCTAssertThrowsError(
            try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .blockingQuestionsRemain)
        }
        XCTAssertEqual(session.events, events)
        XCTAssertTrue(session.planningDelegations.isEmpty)
    }

    func testDelegationIsSingleUseAndCanBeExplicitlyGrantedAgain() throws {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let first = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))

        XCTAssertThrowsError(
            try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(5))
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .activeDelegationAlreadyExists)
        }

        _ = try session.beginPlanningProviderRun(
            delegationID: first.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        XCTAssertNil(session.activePlanningDelegation)
        XCTAssertThrowsError(
            try session.beginPlanningProviderRun(
                delegationID: first.id,
                payload: makePayload(),
                providerIdentity: makeProviderIdentity(),
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .delegationNotActive)
        }
    }

    func testPublishingMaterialRevisionInvalidatesOldReviewAndDelegation() throws {
        var session = try makeAuthorizedSession()
        let first = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(first.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: first.id, now: now.addingTimeInterval(4))

        var revisedDraft = try makeDraft(for: session)
        revisedDraft = try revisedDraft.replacingGoal("发布可供外部用户使用的稳定版")
        let second = try session.publishPlanningBrief(revisedDraft, now: now.addingTimeInterval(5))

        XCTAssertEqual(second.version, 2)
        XCTAssertNil(session.reviewedPlanningBrief)
        XCTAssertNil(session.activePlanningDelegation)
        XCTAssertThrowsError(
            try session.beginPlanningProviderRun(
                delegationID: delegation.id,
                payload: makePayload(),
                providerIdentity: makeProviderIdentity(),
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .delegationNotActive)
        }
        XCTAssertEqual(
            session.events.suffix(2).map(\.kind),
            [.planningBriefPublished, .planningDelegationInvalidated]
        )
    }

    func testProviderReauthorizationInvalidatesBoundPlanningDelegation() throws {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))

        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(version: "v5"),
            expiresAt: now.addingTimeInterval(400),
            now: now.addingTimeInterval(5)
        )

        XCTAssertNil(session.activePlanningDelegation)
        let invalidationEvent = try XCTUnwrap(session.events.last)
        XCTAssertEqual(
            session.planningDelegationInvalidations.last,
            ZhulongPlanningDelegationInvalidation(
                delegationID: delegation.id,
                invalidatedAt: invalidationEvent.occurredAt,
                reason: .authorizationChanged
            )
        )
        XCTAssertEqual(
            session.events.suffix(2).map(\.kind),
            [.scopeAuthorized, .planningDelegationInvalidated]
        )
    }

    func testSubsetBriefCanDelegateWithinAuthorizedScopeCeiling() throws {
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo, .taskPool],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo, .taskPool],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        let brief = try session.publishPlanningBrief(
            makeDraft(for: session, dataScopes: [.currentDayTodo]),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))

        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))

        XCTAssertEqual(delegation.dataScopes, [.currentDayTodo])
    }

    func testCorrectingBriefSourceInvalidatesBriefAndUnconsumedDelegation() throws {
        var session = try makeAuthorizedSession()
        let sourceID = session.entries[0].id
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))

        _ = try session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(5)
        )

        XCTAssertNil(session.currentPlanningBrief)
        XCTAssertNil(session.activePlanningDelegation)
        XCTAssertEqual(session.planningBriefInvalidations.last?.briefID, brief.id)
        XCTAssertEqual(session.planningBriefInvalidations.last?.sourceEntryID, sourceID)
        XCTAssertEqual(session.planningDelegationInvalidations.last?.delegationID, delegation.id)
        XCTAssertEqual(
            session.events.suffix(3).map(\.kind),
            [.sessionCorrected, .planningBriefInvalidated, .planningDelegationInvalidated]
        )
    }

    func testPlanningStartChecksAuthorizationAtActualProviderStart() throws {
        let requestedAt = now.addingTimeInterval(5)
        let providerStartedAt = Date(
            timeIntervalSinceReferenceDate: requestedAt.timeIntervalSinceReferenceDate.nextUp
        )
        var session = try makeSession()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: providerStartedAt,
            now: now.addingTimeInterval(1)
        )
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let originalEvents = session.events

        XCTAssertThrowsError(
            try session.beginPlanningProviderRun(
                delegationID: delegation.id,
                payload: makePayload(),
                providerIdentity: makeProviderIdentity(),
                now: requestedAt
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .authorizationExpired)
        }
        XCTAssertEqual(session.events, originalEvents)
        XCTAssertTrue(session.planningDelegationConsumptions.isEmpty)
        XCTAssertTrue(session.providerSends.isEmpty)
    }

    func testReviewedBriefCanReceiveAnotherExplicitDelegationAfterDraftReview() throws {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let first = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let request = try session.beginPlanningProviderRun(
            delegationID: first.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "规划草稿 v1", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        let second = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(7))

        _ = try session.beginPlanningProviderRun(
            delegationID: second.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(8)
        )

        XCTAssertEqual(session.phase, .providerRunning)
        XCTAssertEqual(session.planningDelegations.map(\.id), [first.id, second.id])
    }

    func testCorrectingSourceInvalidatesCompletedPlanningRunAndEffectiveDraft() throws {
        var session = try makeAuthorizedSession()
        let sourceID = session.entries[0].id
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let request = try session.beginPlanningProviderRun(
            delegationID: delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "规划草稿 v1", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        XCTAssertEqual(session.effectiveDraftVersion, 1)

        _ = try session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(7)
        )

        XCTAssertNil(session.effectiveDraftVersion)
        XCTAssertEqual(session.draftVersion, 1)
        XCTAssertEqual(session.planningRunInvalidations.last?.runID, request.runID)
        XCTAssertEqual(session.events.last?.kind, .planningRunInvalidated)
    }

    func testMaterialBriefRevisionInvalidatesCompletedRunAndDraft() throws {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(makeDraft(for: session), now: now.addingTimeInterval(2))
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let request = try session.beginPlanningProviderRun(
            delegationID: delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "规划草稿 v1", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        let revised = try makeDraft(for: session).replacingGoal("发布外部稳定版")

        let second = try session.publishPlanningBrief(revised, now: now.addingTimeInterval(7))

        XCTAssertEqual(second.version, 2)
        XCTAssertNil(session.effectiveDraftVersion)
        XCTAssertEqual(session.planningRunInvalidations.last?.runID, request.runID)
        XCTAssertEqual(session.planningRunInvalidations.last?.reason, .briefRevised)
        XCTAssertEqual(
            session.events.suffix(2).map(\.kind),
            [.planningBriefPublished, .planningRunInvalidated]
        )
    }

    private func makeSession() throws -> ZhulongSession {
        try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
    }

    private func makeAuthorizedSession() throws -> ZhulongSession {
        var session = try makeSession()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        return session
    }

    private func makeDraft(
        for session: ZhulongSession,
        dataScopes: Set<ZhulongDataScope> = [.currentDayTodo]
    ) throws -> ZhulongPlanningBriefDraft {
        try ZhulongPlanningBriefDraft(
            goal: "发布稳定版",
            successCriteria: ["真实 App E2E 通过", "DMG 安装后可启动"],
            hardConstraints: ["普通 Todo 必须离线可用"],
            userDecisions: ["先完成 Mac 版"],
            delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
            assumptions: ["Provider 配置保持不变"],
            openQuestions: [],
            dataScopes: dataScopes,
            sourceEntryIDs: [session.entries[0].id]
        )
    }

    private func makePayload() throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "只执行委托 contract 中允许的规划活动。",
            userPrompt: "规划发布新版",
            contextVersion: "context-v1",
            scopeContent: [.currentDayTodo: "今日任务摘要"]
        )
    }
}

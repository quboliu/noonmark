@testable import SuntraceZhulong
import XCTest

final class ZhulongStructuredPlanningSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDelegatedRunCanStopAtDurableDecisionGateBoundToExactInputs() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let response = ZhulongProviderResponse(content: gateJSON(), draftVersion: nil)

        try prepared.session.recordPlanningProviderResponse(
            response,
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(prepared.session.phase, .decisionGate)
        XCTAssertNil(prepared.session.effectivePlanArtifact)
        let gate = try XCTUnwrap(prepared.session.currentDecisionGate)
        XCTAssertEqual(gate.runID, request.runID)
        XCTAssertEqual(gate.briefID, prepared.brief.id)
        XCTAssertEqual(gate.briefVersion, prepared.brief.version)
        XCTAssertEqual(gate.providerIdentity, try makeProviderIdentity())
        XCTAssertEqual(gate.contextVersion, "context-v1")
        XCTAssertEqual(prepared.session.events.last?.kind, .planningDecisionGateOpened)
        XCTAssertThrowsError(
            try prepared.session.delegatePlanning(
                for: prepared.brief.id,
                now: now.addingTimeInterval(7)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .decisionGateUnresolved)
        }
        let entries = prepared.session.entries
        XCTAssertThrowsError(
            try prepared.session.appendEntry(
                author: .user,
                kind: .decision,
                content: "绕过原子 gate resolution",
                now: now.addingTimeInterval(7)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSessionError,
                .decisionGateRequiresAtomicResolution
            )
        }
        XCTAssertEqual(prepared.session.entries, entries)

        XCTAssertThrowsError(
            try prepared.session.publishPlanningBrief(
                ZhulongPlanningBriefDraft(
                    goal: "发布稳定版并绕过 gate",
                    successCriteria: ["真实 App E2E 通过"],
                    hardConstraints: ["普通 Todo 必须离线可用"],
                    userDecisions: ["先完成 Mac 版"],
                    delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                    assumptions: [],
                    openQuestions: [],
                    dataScopes: [.currentDayTodo],
                    sourceEntryIDs: [prepared.session.entries[0].id]
                ),
                now: now.addingTimeInterval(7)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .decisionGateUnresolved)
        }
    }

    func testResolvingGateIsAppendOnlyAndRequiresMaterialBriefRevisionBeforeRedelegation() throws {
        var prepared = try makeSessionAtDecisionGate()
        let gate = try XCTUnwrap(prepared.session.currentDecisionGate)

        let resolution = try prepared.session.resolveDecisionGate(
            gate.id,
            selectedOptionID: "investigate",
            supplementalDecision: "只形成真实测量任务。",
            now: now.addingTimeInterval(7)
        )

        XCTAssertEqual(prepared.session.phase, .readyForProvider)
        XCTAssertNil(prepared.session.currentDecisionGate)
        XCTAssertEqual(resolution.gateID, gate.id)
        XCTAssertEqual(resolution.selectedOptionID, "investigate")
        XCTAssertEqual(
            prepared.session.effectiveContent(for: resolution.decisionEntryID),
            "先调查：只形成真实测量任务。"
        )
        XCTAssertEqual(
            prepared.session.events.suffix(2).map(\.kind),
            [.sessionDecisionRecorded, .planningDecisionGateResolved]
        )
        XCTAssertThrowsError(
            try prepared.session.delegatePlanning(
                for: prepared.brief.id,
                now: now.addingTimeInterval(8)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningBriefError, .briefRevisionRequired)
        }
        XCTAssertThrowsError(
            try prepared.session.publishPlanningBrief(
                ZhulongPlanningBriefDraft(
                    goal: "发布稳定版",
                    successCriteria: ["真实 App E2E 通过"],
                    hardConstraints: ["普通 Todo 必须离线可用"],
                    userDecisions: ["先完成 Mac 版", "只形成真实测量任务"],
                    delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                    assumptions: [],
                    openQuestions: [],
                    dataScopes: [.currentDayTodo],
                    sourceEntryIDs: [prepared.session.entries[0].id]
                ),
                now: now.addingTimeInterval(8)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPlanningBriefError,
                .decisionGateResolutionMissingFromRevision
            )
        }

        let revisedBrief = try prepared.session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用"],
                userDecisions: ["先完成 Mac 版", "先调查：只形成真实测量任务。"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [prepared.session.entries[0].id, resolution.decisionEntryID]
            ),
            now: now.addingTimeInterval(8)
        )
        try prepared.session.reviewPlanningBrief(revisedBrief.id, now: now.addingTimeInterval(9))
        let nextDelegation = try prepared.session.delegatePlanning(
            for: revisedBrief.id,
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(nextDelegation.briefVersion, 2)
        XCTAssertEqual(nextDelegation.briefID, revisedBrief.id)
    }

    func testCorrectingGateSourceInvalidatesUnresolvedGateAndAllowsFreshBrief() throws {
        var prepared = try makeSessionAtDecisionGate()
        let sourceID = prepared.session.entries[0].id

        _ = try prepared.session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版并先完成测量",
            now: now.addingTimeInterval(7)
        )

        XCTAssertEqual(prepared.session.phase, .readyForProvider)
        XCTAssertNil(prepared.session.currentDecisionGate)
        XCTAssertNil(prepared.session.currentPlanningBrief)
        let replacement = try prepared.session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版并先完成测量",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用"],
                userDecisions: ["先完成 Mac 版"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [sourceID]
            ),
            now: now.addingTimeInterval(8)
        )
        XCTAssertEqual(replacement.version, 2)
    }

    func testCorrectingResolvedGateSourceStillRequiresResolutionInFreshBrief() throws {
        var prepared = try makeSessionAtDecisionGate()
        let gate = try XCTUnwrap(prepared.session.currentDecisionGate)
        let resolution = try prepared.session.resolveDecisionGate(
            gate.id,
            selectedOptionID: "investigate",
            supplementalDecision: "只形成真实测量任务。",
            now: now.addingTimeInterval(7)
        )
        let sourceID = prepared.session.entries[0].id
        _ = try prepared.session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版并先完成测量",
            now: now.addingTimeInterval(8)
        )

        XCTAssertThrowsError(
            try prepared.session.publishPlanningBrief(
                ZhulongPlanningBriefDraft(
                    goal: "发布稳定版并先完成测量",
                    successCriteria: ["真实 App E2E 通过"],
                    hardConstraints: ["普通 Todo 必须离线可用"],
                    userDecisions: ["先完成 Mac 版"],
                    delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                    assumptions: [],
                    openQuestions: [],
                    dataScopes: [.currentDayTodo],
                    sourceEntryIDs: [sourceID]
                ),
                now: now.addingTimeInterval(9)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPlanningBriefError,
                .decisionGateResolutionMissingFromRevision
            )
        }

        let replacement = try prepared.session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版并先完成测量",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用"],
                userDecisions: ["先完成 Mac 版", "先调查：只形成真实测量任务。"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [sourceID, resolution.decisionEntryID]
            ),
            now: now.addingTimeInterval(9)
        )
        XCTAssertEqual(replacement.version, 2)
    }

    func testStructuredPlanArtifactBindsRunBriefProviderContextAndSessionVersion() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )

        try prepared.session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: planArtifactJSON(), draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(prepared.session.phase, .draftReview)
        XCTAssertEqual(prepared.session.draftVersion, 1)
        let draft = try XCTUnwrap(prepared.session.effectivePlanArtifact)
        XCTAssertEqual(draft.version, 1)
        XCTAssertEqual(draft.sessionID, prepared.session.id)
        XCTAssertEqual(draft.runID, request.runID)
        XCTAssertEqual(draft.briefID, prepared.brief.id)
        XCTAssertEqual(draft.briefVersion, prepared.brief.version)
        XCTAssertEqual(draft.providerIdentity, try makeProviderIdentity())
        XCTAssertEqual(draft.contextVersion, "context-v1")
        XCTAssertEqual(draft.proposal.stages.map(\.id), ["measure", "delivery"])
    }

    func testPlanningRunRejectsUnstructuredTextWithoutPartialMutation() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let sends = prepared.session.providerSends
        let events = prepared.session.events

        XCTAssertThrowsError(
            try prepared.session.recordPlanningProviderResponse(
                ZhulongProviderResponse(content: "这里是一段计划。", draftVersion: 1),
                runID: request.runID,
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongPlanningOutputError, .invalidJSON)
        }
        XCTAssertEqual(prepared.session.phase, .providerRunning)
        XCTAssertEqual(prepared.session.providerSends, sends)
        XCTAssertEqual(prepared.session.events, events)
        XCTAssertTrue(prepared.session.planArtifacts.isEmpty)
        XCTAssertTrue(prepared.session.decisionGates.isEmpty)
    }

    func testPlanningRunRejectsDisclosureOutsideExactBriefAndScopeWithoutMutation() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let sends = prepared.session.providerSends
        let events = prepared.session.events
        let output = planArtifactJSON().replacingOccurrences(
            of: "\"currentDayTodo\"",
            with: "\"taskPool\""
        )

        XCTAssertThrowsError(
            try prepared.session.recordPlanningProviderResponse(
                ZhulongProviderResponse(content: output, draftVersion: 1),
                runID: request.runID,
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPlanningOutputError,
                .explanationOutsidePlanningContract
            )
        }
        XCTAssertEqual(prepared.session.providerSends, sends)
        XCTAssertEqual(prepared.session.events, events)
        XCTAssertEqual(prepared.session.phase, .providerRunning)
    }

    func testPlanningRunAcceptsTypedPrecisionOnlyWhenBasisMatchesExactBrief() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let claim = """
        "precisionClaims":[{
          "kind":"targetDate","dateValue":"2026-08-01","numericValue":null,
          "basisSource":"hardConstraint","basis":"必须在 2026-08-01 前完成","basisValue":"2026-08-01","dataScope":null
        }]
        """
        let output = planArtifactJSON()
            .replacingOccurrences(
                of: "普通 Todo 必须离线可用",
                with: "必须在 2026-08-01 前完成"
            )
            .replacingOccurrences(of: "\"precisionClaims\":[]", with: claim)

        try prepared.session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: output, draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(
            prepared.session.effectivePlanArtifact?.proposal.precisionClaims.first?.dateValue,
            "2026-08-01"
        )
    }

    func testPlanningRunRejectsTypedPrecisionWithSelfAssertedBasisWithoutMutation() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let sends = prepared.session.providerSends
        let events = prepared.session.events
        let claim = """
        "precisionClaims":[{
          "kind":"targetDate","dateValue":"2026-08-01","numericValue":null,
          "basisSource":"hardConstraint","basis":"模型自称 2026-08-01 前完成","basisValue":"2026-08-01","dataScope":null
        }]
        """
        let output = planArtifactJSON()
            .replacingOccurrences(
                of: "普通 Todo 必须离线可用",
                with: "模型自称 2026-08-01 前完成"
            )
            .replacingOccurrences(of: "\"precisionClaims\":[]", with: claim)

        XCTAssertThrowsError(
            try prepared.session.recordPlanningProviderResponse(
                ZhulongProviderResponse(content: output, draftVersion: 1),
                runID: request.runID,
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPlanningOutputError,
                .explanationOutsidePlanningContract
            )
        }
        XCTAssertEqual(prepared.session.providerSends, sends)
        XCTAssertEqual(prepared.session.events, events)
        XCTAssertEqual(prepared.session.phase, .providerRunning)
    }

    func testDelegatedPlanningCannotBypassStructuredBoundaryThroughConversationRecorder() throws {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        let sends = prepared.session.providerSends
        let events = prepared.session.events

        XCTAssertThrowsError(
            try prepared.session.recordProviderResponse(
                ZhulongProviderResponse(content: planArtifactJSON(), draftVersion: 1),
                runID: request.runID,
                now: now.addingTimeInterval(6)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .invalidProviderResponse)
        }
        XCTAssertEqual(prepared.session.providerSends, sends)
        XCTAssertEqual(prepared.session.events, events)
        XCTAssertEqual(prepared.session.phase, .providerRunning)
    }

    private func makePreparedSession() throws -> (
        session: ZhulongSession,
        brief: ZhulongPlanningBrief,
        delegation: ZhulongPlanningDelegation
    ) {
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        let brief = try session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用", "必须在 2026-08-01 前完成"],
                userDecisions: ["先完成 Mac 版"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [session.entries[0].id]
            ),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        return (session, brief, delegation)
    }

    private func makeSessionAtDecisionGate() throws -> (
        session: ZhulongSession,
        brief: ZhulongPlanningBrief
    ) {
        var prepared = try makePreparedSession()
        let request = try prepared.session.beginPlanningProviderRun(
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try prepared.session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: gateJSON(), draftVersion: nil),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        return (prepared.session, prepared.brief)
    }

    private func makePayload() throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "只输出当前规划协议允许的结构化结果。",
            userPrompt: "规划发布新版",
            contextVersion: "context-v1",
            scopeContent: [.currentDayTodo: "今日任务摘要"]
        )
    }

    private func gateJSON() -> String {
        """
        {
          "kind":"decisionGate",
          "summary":"证据不足。",
          "prompt":"这次规划应该怎样继续？",
          "reason":"缺少真实工作量测量。",
          "evidenceGaps":["没有同度量实现历史"],
          "options":[
            {"id":"investigate","title":"先调查","impact":"先形成测量任务"},
            {"id":"stop","title":"保留未决","impact":"停止本轮规划"}
          ]
        }
        """
    }

    private func planArtifactJSON() -> String {
        """
        {
          "kind":"planArtifact",
          "summary":"先取得测量，再交付近期切片。",
          "stages":[
            {"id":"measure","title":"工程测量","objective":"取得真实数据","horizon":"nearTerm","dependencyIDs":[],"deliverables":["测量记录"],"triggerCondition":null},
            {"id":"delivery","title":"交付切片","objective":"完成任务成形闭环","horizon":"later","dependencyIDs":["measure"],"deliverables":[],"triggerCondition":"测量记录已审查"}
          ],
          "decisionExplanations":[
            {
              "subject":"为何先测量",
              "userDecisions":["先完成 Mac 版"],
              "assumptions":[],
              "dataScopes":["currentDayTodo"],
              "evidence":["当前没有同度量工程数据"],
              "constraints":["普通 Todo 必须离线可用"],
              "alternatives":[
                {"title":"直接排期","tradeoffs":["快，但没有证据"]},
                {"title":"先测量","tradeoffs":["较慢，但可校准"]}
              ],
              "counterexamples":["直接排期会隐藏证据缺口"],
              "rationale":"测量后才能形成可信承诺。",
              "uncertainties":["测量结果尚未知"],
              "expectedImpacts":["近期只生成调查任务"],
              "requiredAuthorizations":["todoWrite"]
            }
          ],
          "precisionClaims":[]
        }
        """
    }
}

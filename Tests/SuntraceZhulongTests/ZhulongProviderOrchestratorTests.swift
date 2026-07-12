import Foundation
@testable import SuntraceZhulong
import XCTest

final class ZhulongProviderOrchestratorTests: XCTestCase {
    private var directoryURL: URL!
    private let key = Data(repeating: 0x51, count: 32)
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhulong-provider-orchestrator-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testProviderIdentityMismatchRejectsBeforeCallWithoutMutation() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let probe = ProviderProbe(result: .success(makeResponse()))
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(version: "v5"), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let completedDate = baseDate.addingTimeInterval(3)

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: session.id,
                payload: try makePayload(),
                provider: provider,
                startedAt: baseDate.addingTimeInterval(2),
                completedAt: { completedDate }
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ZhulongProviderOrchestrationError, .providerIdentityMismatch)
        }

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testScopeMismatchRejectsBeforeSavingOrCallingProvider() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let probe = ProviderProbe(result: .success(makeResponse()))
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let completedDate = baseDate.addingTimeInterval(3)
        let payload = try ZhulongProviderPayload(
            systemPrompt: "只输出结构化规划草稿。",
            userPrompt: session.primaryIntent,
            contextVersion: "context-v1",
            scopeContent: [.taskPool: "任务池摘要"]
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: session.id,
                payload: payload,
                provider: provider,
                startedAt: baseDate.addingTimeInterval(2),
                completedAt: { completedDate }
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ZhulongSessionError, .providerPayloadScopeMismatch)
        }

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testRunPersistsActualRequestBeforeProviderCallThenPersistsResponse() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let inspection = ProviderInspection(repository: repository, sessionID: session.id)
        let probe = ProviderProbe(result: .success(makeResponse()), inspection: inspection)
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let payload = try makePayload()
        let completedDate = baseDate.addingTimeInterval(3)

        let completed = try await orchestrator.run(
            sessionID: session.id,
            payload: payload,
            provider: provider,
            startedAt: baseDate.addingTimeInterval(2),
            completedAt: { completedDate }
        )

        let requests = await probe.requests
        let observed = await inspection.observedState()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.payload, payload)
        XCTAssertEqual(request.providerIdentity, provider.configurationIdentity)
        XCTAssertEqual(observed.phase, .providerRunning)
        XCTAssertEqual(observed.sendStatus, .running)
        XCTAssertEqual(completed.phase, .draftReview)
        XCTAssertEqual(completed.draftVersion, 1)
        XCTAssertEqual(completed.providerSends.count, 1)
        XCTAssertEqual(completed.providerSends[0].status, .succeeded)
        XCTAssertEqual(completed.providerSends[0].response, makeResponse())
        XCTAssertEqual(try repository.load(session.id), completed)
    }

    func testConversationRunCannotBypassActivePlanningDelegation() async throws {
        let repository = makeRepository()
        let prepared = try makeDelegatedPlanningSession()
        try repository.save(prepared.session)
        let probe = ProviderProbe(result: .success(makeResponse()))
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let completedAt = baseDate.addingTimeInterval(6)

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: prepared.session.id,
                payload: try makePayload(),
                provider: provider,
                startedAt: baseDate.addingTimeInterval(5),
                completedAt: { completedAt }
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ZhulongSessionError, .planningDelegationRequired)
        }

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(try repository.load(prepared.session.id), prepared.session)
    }

    func testPlanningRunAtomicallyConsumesExactDelegationBeforeProviderCall() async throws {
        let repository = makeRepository()
        let prepared = try makeDelegatedPlanningSession()
        try repository.save(prepared.session)
        let inspection = ProviderInspection(repository: repository, sessionID: prepared.session.id)
        let probe = ProviderProbe(result: .success(makeResponse()), inspection: inspection)
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let completedAt = baseDate.addingTimeInterval(6)

        let completed = try await orchestrator.runPlanning(
            sessionID: prepared.session.id,
            delegationID: prepared.delegation.id,
            payload: makePayload(),
            provider: provider,
            startedAt: baseDate.addingTimeInterval(5),
            completedAt: { completedAt }
        )

        let requests = await probe.requests
        let request = try XCTUnwrap(requests.first)
        guard case let .delegatedPlanning(contract) = request.purpose else {
            return XCTFail("Expected delegated planning purpose")
        }
        XCTAssertEqual(contract.delegationID, prepared.delegation.id)
        XCTAssertEqual(contract.briefID, prepared.delegation.briefID)
        XCTAssertEqual(contract.activities, prepared.delegation.activities)
        XCTAssertEqual(completed.planningDelegationConsumptions.map(\.delegationID), [prepared.delegation.id])
        XCTAssertEqual(
            completed.events.suffix(3).map(\.kind),
            [.planningDelegationConsumed, .providerRunStarted, .draftReady]
        )
        XCTAssertEqual(try repository.load(prepared.session.id), completed)
    }

    func testCorrectingSourceCancelsInFlightPlanningAndRejectsLateProviderResult() async throws {
        let repository = makeRepository()
        let prepared = try makeDelegatedPlanningSession()
        try repository.save(prepared.session)
        let gate = ProviderGate(result: .success(makeResponse()))
        let provider = GatedZhulongProvider(identity: try makeProviderIdentity(), gate: gate)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let sessionID = prepared.session.id
        let delegationID = prepared.delegation.id
        let payload = try makePayload()
        let startedAt = baseDate.addingTimeInterval(5)
        let completedAt = baseDate.addingTimeInterval(9)

        let running = Task {
            try await orchestrator.runPlanning(
                sessionID: sessionID,
                delegationID: delegationID,
                payload: payload,
                provider: provider,
                startedAt: startedAt,
                completedAt: { completedAt }
            )
        }
        await gate.waitUntilCalled()

        let corrected = try await orchestrator.correctPlanningSource(
            sessionID: prepared.session.id,
            sourceEntryID: prepared.session.entries[0].id,
            replacementContent: "结束今天，但明天只安排一项任务",
            now: baseDate.addingTimeInterval(7)
        )
        XCTAssertEqual(corrected.providerSends.last?.failure?.code, "planning_source_corrected")
        XCTAssertEqual(corrected.planningRunInvalidations.count, 1)
        XCTAssertNil(corrected.currentPlanningBrief)

        await gate.release()
        do {
            _ = try await running.value
            XCTFail("Late Provider result must not overwrite the corrected session")
        } catch {
            XCTAssertEqual(
                error as? ZhulongProviderOrchestrationError,
                .providerRunSuperseded
            )
        }
        XCTAssertEqual(try repository.load(prepared.session.id), corrected)
    }

    func testUnrelatedCorrectionDoesNotCancelInFlightPlanningRun() async throws {
        let repository = makeRepository()
        var prepared = try makeDelegatedPlanningSession()
        let unrelated = try prepared.session.appendEntry(
            author: .user,
            kind: .statement,
            content: "与本次规划无关的备注",
            now: baseDate.addingTimeInterval(4.5)
        )
        try repository.save(prepared.session)
        let gate = ProviderGate(result: .success(makeResponse()))
        let provider = GatedZhulongProvider(identity: try makeProviderIdentity(), gate: gate)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let sessionID = prepared.session.id
        let delegationID = prepared.delegation.id
        let payload = try makePayload()
        let startedAt = baseDate.addingTimeInterval(5)
        let completedAt = baseDate.addingTimeInterval(9)

        let running = Task {
            try await orchestrator.runPlanning(
                sessionID: sessionID,
                delegationID: delegationID,
                payload: payload,
                provider: provider,
                startedAt: startedAt,
                completedAt: { completedAt }
            )
        }
        await gate.waitUntilCalled()

        let corrected = try await orchestrator.correctPlanningSource(
            sessionID: sessionID,
            sourceEntryID: unrelated.id,
            replacementContent: "修改无关备注",
            now: baseDate.addingTimeInterval(7)
        )
        XCTAssertEqual(corrected.phase, .providerRunning)
        XCTAssertEqual(corrected.effectiveContent(for: unrelated.id), "修改无关备注")
        XCTAssertEqual(corrected.providerSends.last?.status, .running)

        await gate.release()
        let completed = try await running.value
        XCTAssertEqual(completed.phase, .draftReview)
        XCTAssertTrue(completed.planningRunInvalidations.isEmpty)
        XCTAssertEqual(completed.effectiveContent(for: unrelated.id), "修改无关备注")
    }

    func testFailureIsAuditedAndSameAuthorizedProviderCanRetry() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let failure = ZhulongProviderFailure(code: "rate_limited", message: "Provider 暂时繁忙")
        let failedProbe = ProviderProbe(result: .failure(failure))
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: failedProbe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let failedAt = baseDate.addingTimeInterval(3)

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: session.id,
                payload: try makePayload(),
                provider: provider,
                startedAt: baseDate.addingTimeInterval(2),
                completedAt: { failedAt }
            )
        } errorHandler: { error in
            XCTAssertEqual(error as? ZhulongProviderOrchestrationError, .providerFailed("rate_limited"))
        }

        let failedSession = try repository.load(session.id)
        XCTAssertEqual(failedSession.phase, .readyForProvider)
        XCTAssertEqual(failedSession.providerSends.last?.status, .failed)
        XCTAssertEqual(failedSession.providerSends.last?.failure, failure)
        XCTAssertEqual(failedSession.events.last?.kind, .providerRunFailed)
        XCTAssertEqual(failedSession.events.last?.summary, "Provider 请求失败")
        XCTAssertFalse(failedSession.events.last?.summary.contains(failure.message) == true)

        let successProbe = ProviderProbe(result: .success(makeResponse(draftVersion: 2)))
        let retryProvider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: successProbe)
        let succeededAt = baseDate.addingTimeInterval(5)
        let retried = try await orchestrator.run(
            sessionID: session.id,
            payload: try makePayload(contextVersion: "context-v2"),
            provider: retryProvider,
            startedAt: baseDate.addingTimeInterval(4),
            completedAt: { succeededAt }
        )

        XCTAssertEqual(retried.phase, .draftReview)
        XCTAssertEqual(retried.draftVersion, 2)
        XCTAssertEqual(retried.providerSends.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(retried.events.map(\.sequence), Array(1 ... 6))
        XCTAssertEqual(try repository.load(session.id), retried)
    }

    func testInvalidProviderResponseBecomesAuditedRetryableFailure() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let invalidResponse = ZhulongProviderResponse(content: "  ", draftVersion: 0)
        let probe = ProviderProbe(result: .success(invalidResponse))
        let provider = StubZhulongProvider(identity: try makeProviderIdentity(), probe: probe)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let completedDate = baseDate.addingTimeInterval(3)

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: session.id,
                payload: try makePayload(),
                provider: provider,
                startedAt: baseDate.addingTimeInterval(2),
                completedAt: { completedDate }
            )
        } errorHandler: { error in
            XCTAssertEqual(
                error as? ZhulongProviderOrchestrationError,
                .providerFailed("invalid_provider_response")
            )
        }

        let restored = try repository.load(session.id)
        XCTAssertEqual(restored.phase, .readyForProvider)
        XCTAssertEqual(restored.providerSends.last?.status, .failed)
        XCTAssertEqual(restored.providerSends.last?.failure?.code, "invalid_provider_response")
    }

    func testImmediateProviderCompletionStillProducesStrictlyOrderedEvents() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let provider = StubZhulongProvider(
            identity: try makeProviderIdentity(),
            probe: ProviderProbe(result: .success(makeResponse()))
        )
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let startedAt = baseDate.addingTimeInterval(2)

        let completed = try await orchestrator.run(
            sessionID: session.id,
            payload: makePayload(),
            provider: provider,
            startedAt: startedAt,
            completedAt: { startedAt }
        )

        XCTAssertGreaterThan(
            try XCTUnwrap(completed.providerSends.last?.completedAt),
            startedAt
        )
    }

    func testConcurrentSecondRunIsRejectedBeforeDuplicateProviderCall() async throws {
        let repository = makeRepository()
        let session = try makeAuthorizedSession()
        try repository.save(session)
        let gate = ProviderGate(result: .success(makeResponse()))
        let provider = GatedZhulongProvider(identity: try makeProviderIdentity(), gate: gate)
        let orchestrator = ZhulongProviderOrchestrator(repository: repository)
        let firstStartedDate = baseDate.addingTimeInterval(2)
        let secondStartedDate = baseDate.addingTimeInterval(3)
        let firstCompletedDate = baseDate.addingTimeInterval(4)
        let secondCompletedDate = baseDate.addingTimeInterval(5)
        let payload = try makePayload()

        let firstRun = Task {
            try await orchestrator.run(
                sessionID: session.id,
                payload: payload,
                provider: provider,
                startedAt: firstStartedDate,
                completedAt: { firstCompletedDate }
            )
        }
        await gate.waitUntilCalled()

        await XCTAssertThrowsErrorAsync {
            _ = try await orchestrator.run(
                sessionID: session.id,
                payload: payload,
                provider: provider,
                startedAt: secondStartedDate,
                completedAt: { secondCompletedDate }
            )
        } errorHandler: { error in
            XCTAssertEqual(
                error as? ZhulongProviderOrchestrationError,
                .providerRunStillActive
            )
        }

        do {
            _ = try await orchestrator.recoverInterruptedRun(
                sessionID: session.id,
                now: secondCompletedDate
            )
            XCTFail("An in-flight request must not be marked interrupted")
        } catch {
            XCTAssertEqual(
                error as? ZhulongProviderOrchestrationError,
                .providerRunStillActive
            )
        }

        await gate.release()
        _ = try await firstRun.value
        let callCount = await gate.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testRestartRecoveryMarksPersistedRunningSendInterruptedAndRetryable() async throws {
        let repository = makeRepository()
        var session = try makeAuthorizedSession()
        let request = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: makeProviderIdentity(),
            now: baseDate.addingTimeInterval(2)
        )
        try repository.save(session)
        let restartedOrchestrator = ZhulongProviderOrchestrator(repository: repository)

        let recovered = try await restartedOrchestrator.recoverInterruptedRun(
            sessionID: session.id,
            now: baseDate.addingTimeInterval(3)
        )

        XCTAssertEqual(recovered.phase, .readyForProvider)
        XCTAssertEqual(recovered.providerSends.last?.failure?.code, "provider_run_interrupted")
        XCTAssertEqual(recovered.events.last?.providerRunID, request.runID)
        XCTAssertEqual(try repository.load(session.id), recovered)
    }

    private func makeRepository() -> EncryptedFileZhulongSessionRepository {
        EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: FixedProviderTestKeySource(key: key)
        )
    }

    private func makeAuthorizedSession() throws -> ZhulongSession {
        var session = try ZhulongSession(
            primaryIntent: "结束今天并安排明天",
            proposedScopes: [.currentDayTodo],
            now: baseDate
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: baseDate.addingTimeInterval(301),
            now: baseDate.addingTimeInterval(1)
        )
        return session
    }

    private func makeDelegatedPlanningSession() throws -> (
        session: ZhulongSession,
        delegation: ZhulongPlanningDelegation
    ) {
        var session = try makeAuthorizedSession()
        let brief = try session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "安排明日任务",
                successCriteria: ["形成可审查的明日计划"],
                hardConstraints: ["不写入 Todo"],
                userDecisions: ["先处理未完成任务"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: [],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [session.entries[0].id]
            ),
            now: baseDate.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: baseDate.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(
            for: brief.id,
            now: baseDate.addingTimeInterval(4)
        )
        return (session, delegation)
    }

    private func makePayload(contextVersion: String = "context-v1") throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "只输出结构化规划草稿。",
            userPrompt: "结束今天并安排明天",
            contextVersion: contextVersion,
            scopeContent: [.currentDayTodo: "完成 2 项，未完成 1 项"]
        )
    }

    private func makeResponse(draftVersion: Int = 1) -> ZhulongProviderResponse {
        ZhulongProviderResponse(
            content: """
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
                  "userDecisions":["先处理未完成任务"],
                  "assumptions":[],
                  "dataScopes":["currentDayTodo"],
                  "evidence":["当前没有同度量工程数据"],
                  "constraints":["不写入 Todo"],
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
            """,
            draftVersion: draftVersion
        )
    }
}

private actor ProviderProbe {
    private(set) var requests: [ZhulongProviderRequest] = []
    private(set) var callCount = 0
    private let result: ZhulongProviderResult
    private let inspection: ProviderInspection?

    init(result: ZhulongProviderResult, inspection: ProviderInspection? = nil) {
        self.result = result
        self.inspection = inspection
    }

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        callCount += 1
        requests.append(request)
        await inspection?.capture()
        return result
    }
}

private struct StubZhulongProvider: ZhulongProvider {
    let configurationIdentity: ZhulongProviderConfigurationIdentity
    let probe: ProviderProbe

    init(identity: ZhulongProviderConfigurationIdentity, probe: ProviderProbe) {
        configurationIdentity = identity
        self.probe = probe
    }

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        await probe.complete(request)
    }
}

private struct GatedZhulongProvider: ZhulongProvider {
    let configurationIdentity: ZhulongProviderConfigurationIdentity
    let gate: ProviderGate

    init(identity: ZhulongProviderConfigurationIdentity, gate: ProviderGate) {
        configurationIdentity = identity
        self.gate = gate
    }

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        await gate.complete(request)
    }
}

private actor ProviderGate {
    private let result: ZhulongProviderResult
    private var called = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(result: ZhulongProviderResult) {
        self.result = result
    }

    func complete(_: ZhulongProviderRequest) async -> ZhulongProviderResult {
        callCount += 1
        called = true
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        return result
    }

    func waitUntilCalled() async {
        guard called == false else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor ProviderInspection {
    private let repository: EncryptedFileZhulongSessionRepository
    private let sessionID: ZhulongSessionID
    private(set) var phaseObservedDuringCall: ZhulongSessionPhase?
    private(set) var sendStatusObservedDuringCall: ZhulongProviderSendStatus?

    init(repository: EncryptedFileZhulongSessionRepository, sessionID: ZhulongSessionID) {
        self.repository = repository
        self.sessionID = sessionID
    }

    func capture() {
        let session = try? repository.load(sessionID)
        phaseObservedDuringCall = session?.phase
        sendStatusObservedDuringCall = session?.providerSends.last?.status
    }

    func observedState() -> (phase: ZhulongSessionPhase?, sendStatus: ZhulongProviderSendStatus?) {
        (phaseObservedDuringCall, sendStatusObservedDuringCall)
    }
}

private struct FixedProviderTestKeySource: ZhulongSidecarKeySource {
    let key: Data

    func loadOrCreateKey() throws -> Data {
        key
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}

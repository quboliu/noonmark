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
            content: "{\"summary\":\"今日完成两项\"}",
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

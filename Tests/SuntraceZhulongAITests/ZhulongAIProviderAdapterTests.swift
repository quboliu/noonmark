import Foundation
import SuntraceAI
import SuntraceZhulong
@testable import SuntraceZhulongAI
import XCTest

final class ZhulongAIProviderAdapterTests: XCTestCase {
    func testConversationForwardsAuthorizedScopeAndMapsResponse() async throws {
        let recorder = AIRequestRecorder()
        let upstream = RecordingAIProvider(
            recorder: recorder,
            result: .success(AIProviderResponse(text: "可审查建议"))
        )
        let identity = try makeIdentity()
        let request = try makeConversationRequest(identity: identity)
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: upstream
        )

        let result = await adapter.complete(request)

        XCTAssertEqual(
            result,
            .success(ZhulongProviderResponse(content: "可审查建议", draftVersion: 1))
        )
        let recordedRequest = await recorder.request
        let forwarded = try XCTUnwrap(recordedRequest)
        XCTAssertTrue(forwarded.userPrompt.contains("[currentDayTodo]\n仅包含今天的任务事实"))
        XCTAssertEqual(forwarded.metadata["contextVersion"], "scope-v1")
        XCTAssertEqual(forwarded.metadata["zhulongSessionID"], request.sessionID.description)
        XCTAssertEqual(forwarded.responseSchemaName, "noonmark.zhulong.conversation-draft.v1")
    }

    func testUpstreamFailureBecomesRecordedDomainFailure() async throws {
        let upstream = RecordingAIProvider(
            recorder: AIRequestRecorder(),
            result: .failure(TestProviderError.offline)
        )
        let identity = try makeIdentity()
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: upstream
        )

        let result = await adapter.complete(try makeConversationRequest(identity: identity))

        guard case let .failure(failure) = result else {
            return XCTFail("expected domain failure")
        }
        XCTAssertEqual(failure.code, "upstream_provider_failed")
        XCTAssertFalse(failure.message.isEmpty)
    }

    private func makeConversationRequest(
        identity: ZhulongProviderConfigurationIdentity
    ) throws -> ZhulongProviderRequest {
        let now = Date(timeIntervalSince1970: 1000)
        var session = try ZhulongSession(
            primaryIntent: "结束今天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            expiresAt: now.addingTimeInterval(3600),
            now: now.addingTimeInterval(1)
        )
        let payload = try ZhulongProviderPayload(
            systemPrompt: "系统边界",
            userPrompt: "本次意图",
            contextVersion: "scope-v1",
            scopeContent: [.currentDayTodo: "仅包含今天的任务事实"]
        )
        return try session.beginProviderRun(
            payload: payload,
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )
    }

    private func makeIdentity() throws -> ZhulongProviderConfigurationIdentity {
        try ZhulongProviderConfigurationIdentity(
            providerID: "test-provider",
            kind: .openAICompatible,
            baseURL: URL(string: "https://provider.example/v1"),
            location: .remote,
            model: "test-model",
            dataCapabilities: [.structuredOutput, .taskContext]
        )
    }
}

private actor AIRequestRecorder {
    private(set) var request: AIRequest?

    func record(_ request: AIRequest) {
        self.request = request
    }
}

private enum TestProviderError: Error {
    case offline
}

private struct RecordingAIProvider: AIProvider {
    let config = AIProviderConfig(
        providerID: AIProviderID("recording"),
        displayName: "Recording",
        kind: .mock
    )
    let recorder: AIRequestRecorder
    let result: Result<AIProviderResponse, TestProviderError>

    func complete(_ request: AIRequest) async throws -> AIProviderResponse {
        await recorder.record(request)
        return try result.get()
    }

    func healthCheck() async -> AIProviderHealth {
        AIProviderHealth(status: .healthy)
    }
}

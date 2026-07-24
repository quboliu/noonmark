import Foundation
import NoonmarkAI
import NoonmarkZhulong
@testable import NoonmarkZhulongAI
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
        XCTAssertTrue(forwarded.userPrompt.contains("用户：结束今天"))
        XCTAssertEqual(forwarded.metadata["contextVersion"], "scope-v1")
        XCTAssertEqual(forwarded.metadata["zhulongSessionID"], request.sessionID.description)
        XCTAssertEqual(
            forwarded.responseSchemaName,
            "noonmark.zhulong.conversation-artifact.v2"
        )
    }

    func testConversationExtractsTaskArtifactFromNaturalReply()
        async throws
    {
        let upstream = RecordingAIProvider(
            recorder: AIRequestRecorder(),
            result: .success(
                AIProviderResponse(
                    text: """
                    我整理成一个可编辑任务。
                    <noonmark-artifacts>
                    {
                      "artifacts": [
                        {
                          "kind": "taskPlan",
                          "tasks": [
                            {
                              "title": "重做烛龙",
                              "description": null,
                              "note": null,
                              "destination": { "kind": "today" },
                              "subtasks": [
                                {
                                  "title": "实现任务草稿卡",
                                  "difficulty": "medium"
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }
                    </noonmark-artifacts>
                    """
                )
            )
        )
        let identity = try makeIdentity()
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: upstream
        )

        let result = await adapter.complete(
            try makeConversationRequest(identity: identity)
        )

        guard case let .success(response) = result else {
            return XCTFail("Expected a structured conversation response")
        }
        XCTAssertEqual(
            response.content,
            "我整理成一个可编辑任务。"
        )
        guard case let .taskPlan(plan) = try XCTUnwrap(
            response.artifacts.first
        ) else {
            return XCTFail("Expected task plan")
        }
        XCTAssertEqual(plan.tasks.first?.title, "重做烛龙")
        XCTAssertEqual(
            plan.tasks.first?.subtasks.first?.title,
            "实现任务草稿卡"
        )
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

    func testConversationForwardsStreamedDeltasBeforeItsFinalDomainResponse() async throws {
        let recorder = AIRequestRecorder()
        let upstream = StreamingRecordingAIProvider(
            recorder: recorder,
            fragments: ["先确认问题，", "再安排验证。"]
        )
        let identity = try makeIdentity()
        let request = try makeConversationRequest(identity: identity)
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: upstream
        )

        var events: [ZhulongProviderStreamEvent] = []
        for await event in adapter.stream(request) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .delta("先确认问题，"),
                .delta("再安排验证。"),
                .finished(
                    .success(
                        ZhulongProviderResponse(
                            content: "先确认问题，再安排验证。",
                            draftVersion: 1
                        )
                    )
                )
            ]
        )
        let recordedRequest = await recorder.request
        let forwarded = try XCTUnwrap(recordedRequest)
        XCTAssertTrue(forwarded.userPrompt.contains("[currentDayTodo]\n仅包含今天的任务事实"))
    }

    func testConversationFallsBackToCompletionWhenStreamingFailsBeforeAnyDelta() async throws {
        let identity = try makeIdentity()
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: StreamingFailureFallbackAIProvider(
                response: AIProviderResponse(text: "完整回复仍可用")
            )
        )

        var events: [ZhulongProviderStreamEvent] = []
        for await event in adapter.stream(try makeConversationRequest(identity: identity)) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .finished(
                    .success(
                        ZhulongProviderResponse(
                            content: "完整回复仍可用",
                            draftVersion: 1
                        )
                    )
                )
            ]
        )
    }

    func testConversationUsesCompletionWhenProviderDoesNotAdvertiseStreaming() async throws {
        let probe = StreamingInvocationProbe()
        let identity = try makeIdentity()
        let adapter = ZhulongAIProviderAdapter(
            configurationIdentity: identity,
            upstream: StreamingCapabilityDisabledProvider(probe: probe)
        )

        var events: [ZhulongProviderStreamEvent] = []
        for await event in adapter.stream(try makeConversationRequest(identity: identity)) {
            events.append(event)
        }

        XCTAssertEqual(
            events,
            [
                .finished(
                    .success(
                        ZhulongProviderResponse(
                            content: "Provider 未声明流式能力时使用完整回复。",
                            draftVersion: 1
                        )
                    )
                )
            ]
        )
        let streamCallCount = await probe.streamCallCount
        let completionCallCount = await probe.completionCallCount
        XCTAssertEqual(streamCallCount, 0)
        XCTAssertEqual(completionCallCount, 1)
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
            userPrompt: "会话记录：\n用户：结束今天",
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

private actor StreamingInvocationProbe {
    private(set) var streamCallCount = 0
    private(set) var completionCallCount = 0

    func recordStreamCall() {
        streamCallCount += 1
    }

    func recordCompletionCall() {
        completionCallCount += 1
    }
}

private enum TestProviderError: Error {
    case offline
}

private struct RecordingAIProvider: AIProvider {
    let config = AIProviderConfig(
        providerID: AIProviderID("recording"),
        displayName: "Recording",
        kind: .openAICompatible
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

private struct StreamingRecordingAIProvider: AIProvider, AIProviderStreaming {
    let config = AIProviderConfig(
        providerID: AIProviderID("streaming-recording"),
        displayName: "Streaming recording",
        kind: .openAICompatible,
        capabilities: AIProviderCapabilities(supportsStreaming: true)
    )
    let recorder: AIRequestRecorder
    let fragments: [String]

    func complete(_ request: AIRequest) async throws -> AIProviderResponse {
        await recorder.record(request)
        throw TestProviderError.offline
    }

    func stream(
        _ request: AIRequest
    ) async throws -> AsyncThrowingStream<String, Error> {
        await recorder.record(request)
        return AsyncThrowingStream { continuation in
            fragments.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func healthCheck() async -> AIProviderHealth {
        AIProviderHealth(status: .healthy)
    }
}

private struct StreamingFailureFallbackAIProvider: AIProvider, AIProviderStreaming {
    let config = AIProviderConfig(
        providerID: AIProviderID("streaming-fallback"),
        displayName: "Streaming fallback",
        kind: .openAICompatible,
        capabilities: AIProviderCapabilities(supportsStreaming: true)
    )
    let response: AIProviderResponse

    func complete(_: AIRequest) async throws -> AIProviderResponse {
        response
    }

    func stream(
        _: AIRequest
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw TestProviderError.offline
    }

    func healthCheck() async -> AIProviderHealth {
        AIProviderHealth(status: .healthy)
    }
}

private struct StreamingCapabilityDisabledProvider: AIProvider, AIProviderStreaming {
    let config = AIProviderConfig(
        providerID: AIProviderID("streaming-disabled"),
        displayName: "Streaming disabled",
        kind: .openAICompatible
    )
    let probe: StreamingInvocationProbe

    func complete(_: AIRequest) async throws -> AIProviderResponse {
        await probe.recordCompletionCall()
        return AIProviderResponse(text: "Provider 未声明流式能力时使用完整回复。")
    }

    func stream(_: AIRequest) async throws -> AsyncThrowingStream<String, Error> {
        await probe.recordStreamCall()
        return AsyncThrowingStream { continuation in
            continuation.yield("不应被调用")
            continuation.finish()
        }
    }

    func healthCheck() async -> AIProviderHealth {
        AIProviderHealth(status: .healthy)
    }
}

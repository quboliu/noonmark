import NoonmarkAI
import NoonmarkZhulong

public struct ZhulongAIProviderAdapter: ZhulongProvider, ZhulongStreamingProvider {
    public let configurationIdentity: ZhulongProviderConfigurationIdentity
    public let upstream: any AIProvider

    public init(
        configurationIdentity: ZhulongProviderConfigurationIdentity,
        upstream: any AIProvider
    ) {
        self.configurationIdentity = configurationIdentity
        self.upstream = upstream
    }

    public func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult {
        let upstreamRequest = upstreamRequest(for: request)

        do {
            let response = try await upstream.complete(upstreamRequest)
            return responseResult(response, for: request)
        } catch {
            return providerFailure(from: error)
        }
    }

    public func stream(
        _ request: ZhulongProviderRequest
    ) -> AsyncStream<ZhulongProviderStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard case .conversation = request.purpose,
                      upstream.config.capabilities.supportsStreaming,
                      let streamingUpstream = upstream as? any AIProviderStreaming
                else {
                    let result = await complete(request)
                    continuation.yield(.finished(result))
                    continuation.finish()
                    return
                }

                let upstreamRequest = upstreamRequest(for: request)
                var emittedDelta = false
                do {
                    let stream = try await streamingUpstream.stream(upstreamRequest)
                    var content = ""
                    for try await delta in stream {
                        try Task.checkCancellation()
                        guard delta.isEmpty == false else { continue }
                        emittedDelta = true
                        content += delta
                        continuation.yield(.delta(delta))
                    }
                    guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        continuation.yield(.finished(.failure(ZhulongProviderFailure(
                            code: "empty_streamed_response",
                            message: "Provider 未返回有效内容"
                        ))))
                        continuation.finish()
                        return
                    }
                    continuation.yield(
                        .finished(conversationResult(content))
                    )
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if emittedDelta {
                        continuation.yield(.finished(providerFailure(from: error)))
                    } else {
                        let result = await complete(request)
                        continuation.yield(.finished(result))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func upstreamRequest(for request: ZhulongProviderRequest) -> AIRequest {
        let scopeText = request.payload.scopeContent
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "[\($0.key.rawValue)]\n\($0.value)" }
            .joined(separator: "\n\n")
        return AIRequest(
            systemPrompt: request.payload.systemPrompt,
            userPrompt: "\(request.payload.userPrompt)\n\n授权数据：\n\(scopeText)",
            responseSchemaName: schemaName(for: request.purpose),
            metadata: [
                "zhulongRunID": request.runID.description,
                "zhulongSessionID": request.sessionID.description,
                "contextVersion": request.payload.contextVersion
            ]
        )
    }

    private func responseResult(
        _ response: AIProviderResponse,
        for request: ZhulongProviderRequest
    ) -> ZhulongProviderResult {
        switch request.purpose {
        case .conversation:
            return conversationResult(response.text)
        case .delegatedPlanning:
            guard let rawContent = response.rawContent else {
                return .failure(ZhulongProviderFailure(
                    code: "missing_structured_planning_output",
                    message: "Provider 未返回可验证的结构化规划内容"
                ))
            }
            do {
                let output = try ZhulongPlanningOutputParser().parse(rawContent)
                let draftVersion: Int? = switch output {
                case .decisionGate: nil
                case .planArtifact: request.expectedPlanArtifactVersion
                }
                return .success(ZhulongProviderResponse(
                    content: rawContent,
                    draftVersion: draftVersion
                ))
            } catch {
                return providerFailure(from: error)
            }
        }
    }

    private func providerFailure(from error: Error) -> ZhulongProviderResult {
        .failure(ZhulongProviderFailure(
            code: "upstream_provider_failed",
            message: String(describing: error)
        ))
    }

    private func conversationResult(
        _ content: String
    ) -> ZhulongProviderResult {
        do {
            let turn = try ZhulongConversationTurnParser().parse(content)
            return .success(
                ZhulongProviderResponse(
                    content: turn.message,
                    draftVersion: 1,
                    artifacts: turn.artifacts
                )
            )
        } catch {
            return .failure(
                ZhulongProviderFailure(
                    code: "invalid_conversation_artifact",
                    message: "Provider 返回的对话产物无法验证"
                )
            )
        }
    }

    private func schemaName(for purpose: ZhulongProviderRunPurpose) -> String {
        switch purpose {
        case .conversation:
            "noonmark.zhulong.conversation-artifact.v2"
        case .delegatedPlanning:
            "noonmark.zhulong.planning-output.v1"
        }
    }
}

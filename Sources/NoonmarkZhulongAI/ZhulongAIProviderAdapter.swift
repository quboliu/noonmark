import NoonmarkAI
import NoonmarkZhulong

public struct ZhulongAIProviderAdapter: ZhulongProvider {
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
        let scopeText = request.payload.scopeContent
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "[\($0.key.rawValue)]\n\($0.value)" }
            .joined(separator: "\n\n")
        let upstreamRequest = AIRequest(
            systemPrompt: request.payload.systemPrompt,
            userPrompt: "\(request.payload.userPrompt)\n\n授权数据：\n\(scopeText)",
            responseSchemaName: schemaName(for: request.purpose),
            metadata: [
                "zhulongRunID": request.runID.description,
                "zhulongSessionID": request.sessionID.description,
                "contextVersion": request.payload.contextVersion
            ]
        )

        do {
            let response = try await upstream.complete(upstreamRequest)
            switch request.purpose {
            case .conversation:
                return .success(ZhulongProviderResponse(content: response.text, draftVersion: 1))
            case .delegatedPlanning:
                guard let rawContent = response.rawContent else {
                    return .failure(ZhulongProviderFailure(
                        code: "missing_structured_planning_output",
                        message: "Provider 未返回可验证的结构化规划内容"
                    ))
                }
                let output = try ZhulongPlanningOutputParser().parse(rawContent)
                let draftVersion: Int? = switch output {
                case .decisionGate: nil
                case .planArtifact: request.expectedPlanArtifactVersion
                }
                return .success(ZhulongProviderResponse(
                    content: rawContent,
                    draftVersion: draftVersion
                ))
            }
        } catch {
            return .failure(ZhulongProviderFailure(
                code: "upstream_provider_failed",
                message: String(describing: error)
            ))
        }
    }

    private func schemaName(for purpose: ZhulongProviderRunPurpose) -> String {
        switch purpose {
        case .conversation:
            "noonmark.zhulong.conversation-draft.v1"
        case .delegatedPlanning:
            "noonmark.zhulong.planning-output.v1"
        }
    }
}

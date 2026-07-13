import Foundation

public struct ZhulongAgent {
    private let providerRegistry: AIProviderRegistry
    private let promptBuilder: AIPromptBuilder
    private let insightAnalyzer: LocalInsightAnalyzer

    public init(
        providerRegistry: AIProviderRegistry,
        promptBuilder: AIPromptBuilder = AIPromptBuilder(),
        insightAnalyzer: LocalInsightAnalyzer = LocalInsightAnalyzer()
    ) {
        self.providerRegistry = providerRegistry
        self.promptBuilder = promptBuilder
        self.insightAnalyzer = insightAnalyzer
    }

    public func generateDraft(
        task: ZhulongTask,
        scope: AIScopeSnapshot,
        providerID: AIProviderID? = nil,
        now: Date = Date()
    ) async throws -> AISuggestionDraft {
        guard scope.isEmpty == false else {
            throw ZhulongAIError.emptyScope
        }

        let report = insightAnalyzer.analyze(scope)
        let request = promptBuilder.buildRequest(task: task, scope: scope, report: report)
        let provider = try providerRegistry.provider(for: providerID)
        let response = try await provider.complete(request)

        return AISuggestionDraft(
            kind: task.suggestionKind,
            createdAt: now,
            sourceScope: scope,
            localReport: report,
            summary: response.text,
            proposedOperations: response.proposedOperations,
            confidence: response.confidence
        )
    }
}

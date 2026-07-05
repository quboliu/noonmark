import Foundation

public enum AIProviderKind: String, Codable, Hashable, Sendable {
    case openAICompatible
    case localModel
    case customHTTP
    case mock
}

public struct AIProviderCapabilities: Codable, Equatable, Sendable {
    public var supportsStreaming: Bool
    public var supportsToolCalls: Bool
    public var supportsStructuredOutput: Bool

    public init(
        supportsStreaming: Bool = false,
        supportsToolCalls: Bool = false,
        supportsStructuredOutput: Bool = true
    ) {
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalls = supportsToolCalls
        self.supportsStructuredOutput = supportsStructuredOutput
    }
}

public struct AIProviderConfig: Codable, Equatable, Sendable {
    public var providerID: AIProviderID
    public var displayName: String
    public var kind: AIProviderKind
    public var baseURL: URL?
    public var model: String?
    public var apiKeyRef: String?
    public var extraHeaders: [String: String]
    public var enabled: Bool
    public var requestTimeoutSeconds: TimeInterval
    public var chunkTimeoutSeconds: TimeInterval?
    public var capabilities: AIProviderCapabilities
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        providerID: AIProviderID,
        displayName: String,
        kind: AIProviderKind,
        baseURL: URL? = nil,
        model: String? = nil,
        apiKeyRef: String? = nil,
        extraHeaders: [String: String] = [:],
        enabled: Bool = true,
        requestTimeoutSeconds: TimeInterval = 60,
        chunkTimeoutSeconds: TimeInterval? = 20,
        capabilities: AIProviderCapabilities = AIProviderCapabilities(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.extraHeaders = extraHeaders
        self.enabled = enabled
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.chunkTimeoutSeconds = chunkTimeoutSeconds
        self.capabilities = capabilities
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AIRequest: Equatable, Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let responseSchemaName: String
    public let metadata: [String: String]

    public init(
        systemPrompt: String,
        userPrompt: String,
        responseSchemaName: String,
        metadata: [String: String] = [:]
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.responseSchemaName = responseSchemaName
        self.metadata = metadata
    }
}

public struct AIProviderResponse: Equatable, Sendable {
    public let text: String
    public let proposedOperations: [AIProposedOperation]
    public let confidence: Double?

    public init(
        text: String,
        proposedOperations: [AIProposedOperation] = [],
        confidence: Double? = nil
    ) {
        self.text = text
        self.proposedOperations = proposedOperations
        self.confidence = confidence
    }
}

public enum AIProviderHealthStatus: String, Codable, Hashable, Sendable {
    case healthy
    case unavailable
    case unconfigured
}

public struct AIProviderHealth: Codable, Equatable, Sendable {
    public let status: AIProviderHealthStatus
    public let message: String?
    public let checkedAt: Date

    public init(status: AIProviderHealthStatus, message: String? = nil, checkedAt: Date = Date()) {
        self.status = status
        self.message = message
        self.checkedAt = checkedAt
    }
}

public protocol AIProvider: Sendable {
    var config: AIProviderConfig { get }

    func complete(_ request: AIRequest) async throws -> AIProviderResponse
    func healthCheck() async -> AIProviderHealth
}

public enum ZhulongAIError: Error, Equatable, Sendable {
    case noEnabledProvider
    case providerUnavailable(AIProviderID)
    case providerDisabled(AIProviderID)
    case emptyScope
}

public struct AIProviderRegistry {
    private var providers: [AIProviderID: any AIProvider]

    public init(providers: [any AIProvider] = []) {
        self.providers = [:]
        for provider in providers {
            self.providers[provider.config.providerID] = provider
        }
    }

    public mutating func register(_ provider: any AIProvider) {
        providers[provider.config.providerID] = provider
    }

    public func provider(for providerID: AIProviderID? = nil) throws -> any AIProvider {
        if let providerID {
            guard let provider = providers[providerID] else {
                throw ZhulongAIError.providerUnavailable(providerID)
            }
            guard provider.config.enabled else {
                throw ZhulongAIError.providerDisabled(providerID)
            }
            return provider
        }

        guard let provider = providers.values
            .filter({ $0.config.enabled })
            .sorted(by: { $0.config.providerID.rawValue < $1.config.providerID.rawValue })
            .first
        else {
            throw ZhulongAIError.noEnabledProvider
        }
        return provider
    }

    public func allConfigs() -> [AIProviderConfig] {
        providers.values
            .map(\.config)
            .sorted { $0.providerID.rawValue < $1.providerID.rawValue }
    }
}

public struct MockAIProvider: AIProvider {
    public let config: AIProviderConfig
    private let responder: @Sendable (AIRequest) async throws -> AIProviderResponse

    public init(
        providerID: AIProviderID = AIProviderID("mock"),
        enabled: Bool = true,
        response: AIProviderResponse
    ) {
        self.config = AIProviderConfig(
            providerID: providerID,
            displayName: "Mock Provider",
            kind: .mock,
            enabled: enabled
        )
        self.responder = { _ in response }
    }

    public init(
        config: AIProviderConfig,
        responder: @escaping @Sendable (AIRequest) async throws -> AIProviderResponse
    ) {
        self.config = config
        self.responder = responder
    }

    public func complete(_ request: AIRequest) async throws -> AIProviderResponse {
        try await responder(request)
    }

    public func healthCheck() async -> AIProviderHealth {
        AIProviderHealth(status: config.enabled ? .healthy : .unconfigured)
    }
}

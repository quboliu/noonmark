import Foundation

public enum AIProviderKind: String, Codable, Hashable, Sendable {
    case openAICompatible
    case localModel
    case customHTTP
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

public enum AIResponseFormat: Equatable, Sendable {
    case text
    case jsonObject
}

public struct AIRequest: Equatable, Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let responseSchemaName: String
    public let responseFormat: AIResponseFormat
    public let metadata: [String: String]

    public init(
        systemPrompt: String,
        userPrompt: String,
        responseSchemaName: String,
        responseFormat: AIResponseFormat = .text,
        metadata: [String: String] = [:]
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.responseSchemaName = responseSchemaName
        self.responseFormat = responseFormat
        self.metadata = metadata
    }
}

public struct AIProviderResponse: Equatable, Sendable {
    public let text: String
    public let rawContent: String?

    public init(
        text: String,
        rawContent: String? = nil
    ) {
        self.text = text
        self.rawContent = rawContent
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

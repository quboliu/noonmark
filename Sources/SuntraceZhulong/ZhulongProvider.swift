import Foundation

public struct ZhulongProviderPayload: Codable, Equatable, Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let contextVersion: String
    public let scopeContent: [ZhulongDataScope: String]

    public init(
        systemPrompt: String,
        userPrompt: String,
        contextVersion: String,
        scopeContent: [ZhulongDataScope: String]
    ) throws {
        let normalizedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContextVersion = contextVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSystemPrompt.isEmpty == false,
              normalizedUserPrompt.isEmpty == false,
              normalizedContextVersion.isEmpty == false,
              scopeContent.isEmpty == false,
              scopeContent.values.allSatisfy({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
              })
        else {
            throw ZhulongProviderPayloadError.emptyRequiredContent
        }

        self.systemPrompt = normalizedSystemPrompt
        self.userPrompt = normalizedUserPrompt
        self.contextVersion = normalizedContextVersion
        self.scopeContent = scopeContent.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var scopes: Set<ZhulongDataScope> {
        Set(scopeContent.keys)
    }
}

public enum ZhulongProviderPayloadError: Error, Equatable, Sendable {
    case emptyRequiredContent
}

public struct ZhulongProviderRunID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct ZhulongProviderRequest: Equatable, Sendable {
    public let runID: ZhulongProviderRunID
    public let sessionID: ZhulongSessionID
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let payload: ZhulongProviderPayload
}

public struct ZhulongProviderResponse: Codable, Equatable, Sendable {
    public let content: String
    public let draftVersion: Int

    public init(content: String, draftVersion: Int) {
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.draftVersion = draftVersion
    }
}

public struct ZhulongProviderFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ZhulongProviderResult: Equatable, Sendable {
    case success(ZhulongProviderResponse)
    case failure(ZhulongProviderFailure)
}

public protocol ZhulongProvider: Sendable {
    var configurationIdentity: ZhulongProviderConfigurationIdentity { get }

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult
}

public enum ZhulongProviderSendStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
}

public enum ZhulongProviderSendResult: Codable, Equatable, Sendable {
    case running
    case succeeded(completedAt: Date, response: ZhulongProviderResponse)
    case failed(completedAt: Date, failure: ZhulongProviderFailure)
}

public struct ZhulongProviderSendRecord: Codable, Equatable, Sendable {
    public let runID: ZhulongProviderRunID
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let payload: ZhulongProviderPayload
    public let startedAt: Date
    public let result: ZhulongProviderSendResult

    init(
        runID: ZhulongProviderRunID,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        payload: ZhulongProviderPayload,
        startedAt: Date,
        result: ZhulongProviderSendResult = .running
    ) {
        self.runID = runID
        self.providerIdentity = providerIdentity
        self.payload = payload
        self.startedAt = startedAt
        self.result = result
    }

    public var status: ZhulongProviderSendStatus {
        switch result {
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
    }

    public var completedAt: Date? {
        switch result {
        case .running: nil
        case let .succeeded(completedAt, _), let .failed(completedAt, _): completedAt
        }
    }

    public var response: ZhulongProviderResponse? {
        guard case let .succeeded(_, response) = result else { return nil }
        return response
    }

    public var failure: ZhulongProviderFailure? {
        guard case let .failed(_, failure) = result else { return nil }
        return failure
    }

    func completing(with response: ZhulongProviderResponse, at date: Date) -> Self {
        Self(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            startedAt: startedAt,
            result: .succeeded(completedAt: date, response: response)
        )
    }

    func failing(with failure: ZhulongProviderFailure, at date: Date) -> Self {
        Self(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            startedAt: startedAt,
            result: .failed(completedAt: date, failure: failure)
        )
    }
}

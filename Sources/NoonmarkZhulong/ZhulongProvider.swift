import Foundation

public enum ZhulongProviderResponseContract:
    Codable,
    Equatable,
    Sendable
{
    case generalConversation
    case taskPoolAnalysis(
        evidence: [ZhulongTaskPoolAnalysisEvidence]
    )

    public func validate(
        _ response: ZhulongProviderResponse
    ) throws {
        switch self {
        case .generalConversation:
            guard response.artifacts.allSatisfy({
                if case .taskPoolAnalysis = $0 {
                    return false
                }
                return true
            }) else {
                throw ZhulongProviderResponseContractError
                    .unexpectedArtifact
            }
        case let .taskPoolAnalysis(evidence):
            guard response.draftVersion == nil,
                  response.artifacts.count == 1,
                  case let .taskPoolAnalysis(report) =
                  response.artifacts[0],
                  report.isGrounded(in: evidence)
            else {
                throw ZhulongProviderResponseContractError
                    .invalidTaskPoolAnalysis
            }
        }
    }
}

public enum ZhulongProviderResponseContractError:
    Error,
    Equatable,
    Sendable
{
    case unexpectedArtifact
    case invalidTaskPoolAnalysis
}

public struct ZhulongProviderPayload: Codable, Equatable, Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    public let contextVersion: String
    public let scopeContent: [ZhulongDataScope: String]
    public let responseContract: ZhulongProviderResponseContract

    public init(
        systemPrompt: String,
        userPrompt: String,
        contextVersion: String,
        scopeContent: [ZhulongDataScope: String],
        responseContract: ZhulongProviderResponseContract =
            .generalConversation
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
        switch responseContract {
        case .generalConversation:
            break
        case let .taskPoolAnalysis(evidence):
            let rebuiltEvidence = try evidence.map {
                try ZhulongTaskPoolAnalysisEvidence(
                    taskID: $0.taskID,
                    title: $0.title
                )
            }
            guard rebuiltEvidence == evidence,
                  Set(evidence.map(\.taskID)).count == evidence.count,
                  Set(scopeContent.keys) == [.taskPool]
            else {
                throw ZhulongProviderPayloadError
                    .invalidResponseContract
            }
        }

        self.systemPrompt = normalizedSystemPrompt
        self.userPrompt = normalizedUserPrompt
        self.contextVersion = normalizedContextVersion
        self.scopeContent = scopeContent.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.responseContract = responseContract
    }

    public var scopes: Set<ZhulongDataScope> {
        Set(scopeContent.keys)
    }
}

public enum ZhulongProviderPayloadError: Error, Equatable, Sendable {
    case emptyRequiredContent
    case invalidResponseContract
}

public struct ZhulongProviderRunID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct ZhulongPlanningRunContract: Codable, Equatable, Sendable {
    public let delegationID: ZhulongPlanningDelegationID
    public let briefID: ZhulongPlanningBriefID
    public let briefVersion: Int
    public let activities: Set<ZhulongPlanningActivity>
    public let dataScopes: Set<ZhulongDataScope>

    init(delegation: ZhulongPlanningDelegation) {
        delegationID = delegation.id
        briefID = delegation.briefID
        briefVersion = delegation.briefVersion
        activities = delegation.activities
        dataScopes = delegation.dataScopes
    }
}

public enum ZhulongProviderRunPurpose: Codable, Equatable, Sendable {
    case conversation
    case delegatedPlanning(ZhulongPlanningRunContract)
}

public struct ZhulongProviderRequest: Equatable, Sendable {
    public let runID: ZhulongProviderRunID
    public let sessionID: ZhulongSessionID
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let payload: ZhulongProviderPayload
    public let purpose: ZhulongProviderRunPurpose
    public let expectedPlanArtifactVersion: Int?
    public let startedAt: Date
}

public struct ZhulongProviderResponse: Codable, Equatable, Sendable {
    public let content: String
    public let draftVersion: Int?
    public let artifacts: [ZhulongConversationArtifactProposal]

    public init(
        content: String,
        draftVersion: Int? = nil,
        artifacts: [ZhulongConversationArtifactProposal] = []
    ) {
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.draftVersion = draftVersion
        self.artifacts = artifacts
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
    case stopped(ZhulongProviderResponse)
    case failure(ZhulongProviderFailure)
}

/// An ephemeral event emitted while a conversational Provider response is in
/// flight. Only the terminal result is eligible to become a session record.
public enum ZhulongProviderStreamEvent: Equatable, Sendable {
    case delta(String)
    case finished(ZhulongProviderResult)
}

public protocol ZhulongProvider: Sendable {
    var configurationIdentity: ZhulongProviderConfigurationIdentity { get }

    func complete(_ request: ZhulongProviderRequest) async -> ZhulongProviderResult
}

public protocol ZhulongStreamingProvider: ZhulongProvider {
    func stream(
        _ request: ZhulongProviderRequest
    ) -> AsyncStream<ZhulongProviderStreamEvent>
}

public enum ZhulongProviderSendStatus: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case stopped
    case failed
}

public enum ZhulongProviderSendResult: Codable, Equatable, Sendable {
    case running
    case succeeded(completedAt: Date, response: ZhulongProviderResponse)
    case stopped(completedAt: Date, response: ZhulongProviderResponse)
    case failed(completedAt: Date, failure: ZhulongProviderFailure)
}

public struct ZhulongProviderSendRecord: Codable, Equatable, Sendable {
    public let runID: ZhulongProviderRunID
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let payload: ZhulongProviderPayload
    public let purpose: ZhulongProviderRunPurpose
    public let startedAt: Date
    public let result: ZhulongProviderSendResult

    init(
        runID: ZhulongProviderRunID,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        payload: ZhulongProviderPayload,
        purpose: ZhulongProviderRunPurpose = .conversation,
        startedAt: Date,
        result: ZhulongProviderSendResult = .running
    ) {
        self.runID = runID
        self.providerIdentity = providerIdentity
        self.payload = payload
        self.purpose = purpose
        self.startedAt = startedAt
        self.result = result
    }

    public var status: ZhulongProviderSendStatus {
        switch result {
        case .running: .running
        case .succeeded: .succeeded
        case .stopped: .stopped
        case .failed: .failed
        }
    }

    public var completedAt: Date? {
        switch result {
        case .running: nil
        case let .succeeded(completedAt, _),
             let .stopped(completedAt, _),
             let .failed(completedAt, _):
            completedAt
        }
    }

    public var response: ZhulongProviderResponse? {
        switch result {
        case let .succeeded(_, response), let .stopped(_, response):
            response
        case .running, .failed:
            nil
        }
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
            purpose: purpose,
            startedAt: startedAt,
            result: .succeeded(completedAt: date, response: response)
        )
    }

    func failing(with failure: ZhulongProviderFailure, at date: Date) -> Self {
        Self(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            purpose: purpose,
            startedAt: startedAt,
            result: .failed(completedAt: date, failure: failure)
        )
    }

    func stopping(with response: ZhulongProviderResponse, at date: Date) -> Self {
        Self(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            purpose: purpose,
            startedAt: startedAt,
            result: .stopped(completedAt: date, response: response)
        )
    }

    var planningContract: ZhulongPlanningRunContract? {
        switch purpose {
        case .conversation: nil
        case let .delegatedPlanning(contract): contract
        }
    }
}

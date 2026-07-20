import Foundation
import NoonmarkCore

public enum AuthorityPayloadCodingError: Error, Equatable {
    case invalidLength
    case nonCanonical
}

public enum AutomaticClassificationAuthorityPayload {
    public static func encode(
        _ authority: AutomaticTaskClassificationAuthority
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(authority)
        guard (1 ... 65536).contains(payload.count) else {
            throw AuthorityPayloadCodingError.invalidLength
        }
        return payload
    }

    public static func decode(
        _ payload: Data
    ) throws -> AutomaticTaskClassificationAuthority {
        guard (1 ... 65536).contains(payload.count) else {
            throw AuthorityPayloadCodingError.invalidLength
        }
        let authority = try JSONDecoder().decode(
            AutomaticTaskClassificationAuthority.self,
            from: payload
        )
        guard try encode(authority) == payload else {
            throw AuthorityPayloadCodingError.nonCanonical
        }
        return authority
    }
}

public enum AutomaticClassificationJobState: String, CaseIterable, Codable, Sendable {
    case waitingForConfiguration
    case ready
    case running
    case proposalReady
    case completed
    case superseded
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .superseded, .cancelled, .failed:
            true
        case .waitingForConfiguration, .ready, .running, .proposalReady:
            false
        }
    }
}

public enum AutomaticClassificationJobErrorCode: String, CaseIterable, Codable, Sendable {
    case configurationUnavailable
    case providerUnavailable
    case providerRateLimited
    case providerRejected
    case invalidProviderResponse
    case invalidProposal
    case retryLimitReached
    case transientStorageFailure
    case cancelledByUndo
    case backlogSkippedByUser
    case manualClassificationWon
    case contentOrCatalogChanged
    case internalFailure
}

// swiftlint:disable:next type_name
public enum AutomaticClassificationDispatchAuthorization: String, Codable, Sendable {
    case automatic
    case pendingUserDecision
    case explicit
}

public struct AutomaticClassificationJobEnqueue: Equatable, Sendable {
    public let id: UUID
    public let chainID: TaskChainID
    public let contentDigest: String
    public let classificationFingerprint: String
    public let authorityPayload: Data
    public let catalogDigest: String
    public let generation: Int
    public let initialState: AutomaticClassificationJobState
    public let dispatchAuthorization: AutomaticClassificationDispatchAuthorization
    public let authorizationID: UUID?
    public let authorizedAt: Date?
    public let availableAt: Date
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        chainID: TaskChainID,
        contentDigest: String,
        classificationFingerprint: String,
        authorityPayload: Data,
        catalogDigest: String,
        generation: Int,
        initialState: AutomaticClassificationJobState,
        dispatchAuthorization: AutomaticClassificationDispatchAuthorization? = nil,
        authorizationID: UUID? = nil,
        authorizedAt: Date? = nil,
        availableAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.chainID = chainID
        self.contentDigest = contentDigest
        self.classificationFingerprint = classificationFingerprint
        self.authorityPayload = authorityPayload
        self.catalogDigest = catalogDigest
        self.generation = generation
        self.initialState = initialState
        self.dispatchAuthorization = dispatchAuthorization
            ?? (initialState == .waitingForConfiguration
                ? .pendingUserDecision
                : .automatic)
        self.authorizationID = authorizationID
        self.authorizedAt = authorizedAt
        self.availableAt = availableAt
        self.createdAt = createdAt
    }

    public init(
        authority: AutomaticTaskClassificationAuthority,
        initialState: AutomaticClassificationJobState,
        dispatchAuthorization: AutomaticClassificationDispatchAuthorization? = nil,
        authorizationID: UUID? = nil,
        authorizedAt: Date? = nil,
        availableAt: Date,
        createdAt: Date
    ) throws {
        self.init(
            id: authority.jobID,
            chainID: authority.chainID,
            contentDigest: authority.contentDigest,
            classificationFingerprint: authority.classificationFingerprint,
            authorityPayload: try AutomaticClassificationAuthorityPayload.encode(
                authority
            ),
            catalogDigest: authority.catalogDigest,
            generation: authority.generation,
            initialState: initialState,
            dispatchAuthorization: dispatchAuthorization,
            authorizationID: authorizationID,
            authorizedAt: authorizedAt,
            availableAt: availableAt,
            createdAt: createdAt
        )
    }
}

public struct AutomaticClassificationJobFence: Equatable, Hashable, Sendable {
    public let jobID: UUID
    public let generation: Int
    public let attempt: Int
    public let claimID: UUID?

    public init(
        jobID: UUID,
        generation: Int,
        attempt: Int,
        claimID: UUID?
    ) {
        self.jobID = jobID
        self.generation = generation
        self.attempt = attempt
        self.claimID = claimID
    }
}

public struct AutomaticClassificationJob: Equatable, Sendable {
    public let id: UUID
    public let chainID: TaskChainID
    public let contentDigest: String
    public let classificationFingerprint: String
    public let authorityPayload: Data
    public let catalogDigest: String
    public let generation: Int
    public let state: AutomaticClassificationJobState
    public let dispatchAuthorization: AutomaticClassificationDispatchAuthorization
    public let authorizationID: UUID?
    public let authorizedAt: Date?
    public let attempt: Int
    public let claimID: UUID?
    public let proposalCheckpoint: Data?
    public let errorCode: AutomaticClassificationJobErrorCode?
    public let availableAt: Date
    public let claimedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let terminalAt: Date?
    public let cancelledByUndo: Bool

    public var fence: AutomaticClassificationJobFence {
        AutomaticClassificationJobFence(
            jobID: id,
            generation: generation,
            attempt: attempt,
            claimID: claimID
        )
    }
}

public struct AutomaticClassificationJobClaim: Equatable, Sendable {
    public let jobID: UUID
    public let chainID: TaskChainID
    public let contentDigest: String
    public let classificationFingerprint: String
    public let authorityPayload: Data
    public let catalogDigest: String
    public let generation: Int
    public let dispatchAuthorization: AutomaticClassificationDispatchAuthorization
    public let attempt: Int
    public let claimID: UUID
    public let state: AutomaticClassificationJobState
    public let proposalCheckpoint: Data?

    public var fence: AutomaticClassificationJobFence {
        AutomaticClassificationJobFence(
            jobID: jobID,
            generation: generation,
            attempt: attempt,
            claimID: claimID
        )
    }
}

public struct AutomaticClassificationBacklogItem: Equatable, Sendable {
    public let fence: AutomaticClassificationJobFence
    public let chainID: TaskChainID
    public let contentDigest: String
    public let catalogDigest: String
    public let createdAt: Date
}

public struct AutomaticClassificationBacklogSnapshot: Equatable, Sendable {
    public let items: [AutomaticClassificationBacklogItem]
}

public enum AutomaticClassificationBacklogDecision: Equatable, Sendable {
    case authorize(decisionID: UUID)
    case skip
}

public struct AutomaticClassificationBacklogResolution: Equatable, Sendable {
    public let authorizedCount: Int
    public let skippedCount: Int
    public let ignoredCount: Int
}

public enum AutomaticClassificationProviderExecution: Equatable, Sendable {
    case unconfigured
    case configured(executionRevision: UUID)
}

// swiftlint:disable:next type_name
public enum AutomaticClassificationProviderCircuitState: String, Codable, Sendable {
    case unconfigured
    case closed
    case open
    case halfOpen
    case blocked
}

public struct AutomaticClassificationProviderCircuit: Equatable, Sendable {
    public let providerExecutionRevision: UUID?
    public let state: AutomaticClassificationProviderCircuitState
    public let failureCode: AutomaticClassificationJobErrorCode?
    public let consecutiveFailures: Int
    public let retryAt: Date?
    public let probeFence: AutomaticClassificationJobFence?
    public let openedAt: Date?
    public let updatedAt: Date
    public let transitionVersion: Int
}

public enum AutomaticClassificationNextDispatch: Equatable, Sendable {
    case claimed(AutomaticClassificationJobClaim)
    case idle(nextWakeAt: Date?)
    case waitingForProvider
    case providerBlocked(errorCode: AutomaticClassificationJobErrorCode)
    case backlogDecisionRequired(count: Int)
}

// swiftlint:disable:next type_name
public enum AutomaticClassificationProviderAttemptOutcome: Equatable, Sendable {
    case checkpoint(Data)
    case invalidResponse
    case credentialsRejected
    case rateLimited(retryAt: Date)
    case transientFailure(retryAt: Date)
}

public struct AutomaticClassificationJobRedo: Equatable, Sendable {
    public let cancelledJob: AutomaticClassificationJobFence
    public let replacement: AutomaticClassificationJobEnqueue

    public init(
        cancelledJob: AutomaticClassificationJobFence,
        replacement: AutomaticClassificationJobEnqueue
    ) {
        self.cancelledJob = cancelledJob
        self.replacement = replacement
    }
}

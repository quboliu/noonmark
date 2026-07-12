import Foundation

public struct ZhulongSessionID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct ZhulongProviderConfigurationIdentity: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ZhulongSessionError.emptyProviderIdentity
        }
        self.rawValue = normalized
    }
}

public enum ZhulongDataScope: String, Codable, CaseIterable, Hashable, Sendable {
    case currentDayTodo
    case taskPool
    case unfinishedPool
    case completedPool
    case taskClassifications
}

public enum ZhulongSessionPhase: String, Codable, Equatable, Sendable {
    case scopeReview
    case readyForProvider
    case providerRunning
    case draftReview
    case paused
    case archived
}

public enum ZhulongSessionEventKind: String, Codable, Equatable, Sendable {
    case sessionCreated
    case scopeAuthorized
    case providerRunStarted
    case providerRunFailed
    case draftReady
}

public struct ZhulongSessionEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let kind: ZhulongSessionEventKind
    public let occurredAt: Date
}

public struct ZhulongScopeAuthorization: Equatable, Sendable {
    public let scopes: Set<ZhulongDataScope>
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let grantedAt: Date
}

public enum ZhulongSessionError: Error, Equatable, Sendable {
    case emptyPrimaryIntent
    case emptyScopeProposal
    case emptyProviderIdentity
    case scopeNotAuthorized
    case scopeDoesNotMatchProposal
    case providerIdentityMismatch
    case providerPayloadScopeMismatch
    case providerRunMismatch
    case invalidDraftVersion
    case invalidProviderFailure
    case invalidProviderResponse
    case nonMonotonicEventTime
    case invalidTransition(from: ZhulongSessionPhase, to: ZhulongSessionPhase)
}

public struct ZhulongSession: Equatable, Sendable {
    public let id: ZhulongSessionID
    public let primaryIntent: String
    public let proposedScopes: Set<ZhulongDataScope>
    public private(set) var phase: ZhulongSessionPhase
    public private(set) var authorization: ZhulongScopeAuthorization?
    public private(set) var draftVersion: Int?
    public private(set) var providerSends: [ZhulongProviderSendRecord]
    public private(set) var events: [ZhulongSessionEvent]

    public init(
        id: ZhulongSessionID = ZhulongSessionID(),
        primaryIntent: String,
        proposedScopes: Set<ZhulongDataScope>,
        now: Date = Date()
    ) throws {
        let normalizedIntent = primaryIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedIntent.isEmpty == false else {
            throw ZhulongSessionError.emptyPrimaryIntent
        }
        guard proposedScopes.isEmpty == false else {
            throw ZhulongSessionError.emptyScopeProposal
        }

        self.id = id
        self.primaryIntent = normalizedIntent
        self.proposedScopes = proposedScopes
        phase = .scopeReview
        authorization = nil
        draftVersion = nil
        providerSends = []
        events = [
            ZhulongSessionEvent(
                sequence: 1,
                kind: .sessionCreated,
                occurredAt: now
            )
        ]
    }

    init(
        restoredID: ZhulongSessionID,
        primaryIntent: String,
        proposedScopes: Set<ZhulongDataScope>,
        phase: ZhulongSessionPhase,
        authorization: ZhulongScopeAuthorization?,
        draftVersion: Int?,
        providerSends: [ZhulongProviderSendRecord],
        events: [ZhulongSessionEvent]
    ) {
        id = restoredID
        self.primaryIntent = primaryIntent
        self.proposedScopes = proposedScopes
        self.phase = phase
        self.authorization = authorization
        self.draftVersion = draftVersion
        self.providerSends = providerSends
        self.events = events
    }

    public mutating func authorizeScope(
        _ scopes: Set<ZhulongDataScope>,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        now: Date = Date()
    ) throws {
        guard phase == .scopeReview else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .readyForProvider)
        }
        guard scopes == proposedScopes else {
            throw ZhulongSessionError.scopeDoesNotMatchProposal
        }
        try validateEventTime(now)

        authorization = ZhulongScopeAuthorization(
            scopes: scopes,
            providerIdentity: providerIdentity,
            grantedAt: now
        )
        phase = .readyForProvider
        appendEvent(.scopeAuthorized, now: now)
    }

    public mutating func beginProviderRun(
        payload: ZhulongProviderPayload,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        runID: ZhulongProviderRunID = ZhulongProviderRunID(),
        now: Date = Date()
    ) throws -> ZhulongProviderRequest {
        guard phase == .readyForProvider, let authorization else {
            if authorization == nil {
                throw ZhulongSessionError.scopeNotAuthorized
            }
            throw ZhulongSessionError.invalidTransition(from: phase, to: .providerRunning)
        }
        guard providerIdentity == authorization.providerIdentity else {
            throw ZhulongSessionError.providerIdentityMismatch
        }
        guard payload.scopes == authorization.scopes else {
            throw ZhulongSessionError.providerPayloadScopeMismatch
        }
        try validateEventTime(now)

        let send = ZhulongProviderSendRecord(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            startedAt: now
        )
        providerSends.append(send)
        phase = .providerRunning
        appendEvent(.providerRunStarted, now: now)
        return ZhulongProviderRequest(
            runID: runID,
            sessionID: id,
            providerIdentity: providerIdentity,
            payload: payload
        )
    }

    public mutating func recordProviderResponse(
        _ response: ZhulongProviderResponse,
        runID: ZhulongProviderRunID,
        now: Date = Date()
    ) throws {
        guard phase == .providerRunning else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .draftReview)
        }
        guard response.draftVersion > 0,
              response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ZhulongSessionError.invalidProviderResponse
        }
        try validateEventTime(now)
        let sendIndex = try activeSendIndex(runID: runID)

        providerSends[sendIndex] = providerSends[sendIndex].completing(with: response, at: now)
        draftVersion = response.draftVersion
        phase = .draftReview
        appendEvent(.draftReady, now: now)
    }

    public mutating func recordProviderFailure(
        _ failure: ZhulongProviderFailure,
        runID: ZhulongProviderRunID,
        now: Date = Date()
    ) throws {
        guard phase == .providerRunning else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .readyForProvider)
        }
        guard failure.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              failure.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ZhulongSessionError.invalidProviderFailure
        }
        try validateEventTime(now)
        let sendIndex = try activeSendIndex(runID: runID)

        providerSends[sendIndex] = providerSends[sendIndex].failing(with: failure, at: now)
        phase = .readyForProvider
        appendEvent(.providerRunFailed, now: now)
    }

    private mutating func appendEvent(_ kind: ZhulongSessionEventKind, now: Date) {
        events.append(
            ZhulongSessionEvent(
                sequence: UInt64(events.count + 1),
                kind: kind,
                occurredAt: now
            )
        )
    }

    private func validateEventTime(_ now: Date) throws {
        guard let lastEvent = events.last, now >= lastEvent.occurredAt else {
            throw ZhulongSessionError.nonMonotonicEventTime
        }
    }

    private func activeSendIndex(runID: ZhulongProviderRunID) throws -> Int {
        guard let index = providerSends.indices.last,
              providerSends[index].runID == runID,
              providerSends[index].status == .running
        else {
            throw ZhulongSessionError.providerRunMismatch
        }
        return index
    }
}

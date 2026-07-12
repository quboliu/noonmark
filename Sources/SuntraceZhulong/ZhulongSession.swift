import Foundation

public struct ZhulongSessionID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ZhulongProviderKind: String, Codable, Hashable, Sendable {
    case openAICompatible
    case localModel
    case customHTTP
}

public enum ZhulongProviderLocation: String, Codable, Hashable, Sendable {
    case local
    case remote
}

public enum ZhulongProviderDataCapability: String, Codable, Hashable, Sendable {
    case structuredOutput
    case taskContext
    case sessionSummary
    case memoryContext
}

public struct ZhulongProviderConfigurationIdentity: Codable, Hashable, Sendable {
    public let providerID: String
    public let kind: ZhulongProviderKind
    public let baseURL: URL?
    public let location: ZhulongProviderLocation
    public let model: String
    public let dataCapabilities: Set<ZhulongProviderDataCapability>

    public init(
        providerID: String,
        kind: ZhulongProviderKind,
        baseURL: URL?,
        location: ZhulongProviderLocation,
        model: String,
        dataCapabilities: Set<ZhulongProviderDataCapability>
    ) throws {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedProviderID.isEmpty == false,
              normalizedModel.isEmpty == false,
              dataCapabilities.isEmpty == false
        else {
            throw ZhulongSessionError.emptyProviderIdentity
        }
        guard location != .remote || baseURL != nil else {
            throw ZhulongSessionError.invalidProviderIdentity
        }
        if let components = baseURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
            guard components.user == nil, components.password == nil, components.fragment == nil else {
                throw ZhulongSessionError.invalidProviderIdentity
            }
        }

        self.providerID = normalizedProviderID
        self.kind = kind
        self.baseURL = baseURL
        self.location = location
        self.model = normalizedModel
        self.dataCapabilities = dataCapabilities
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
    public let summary: String
    public let providerRunID: ZhulongProviderRunID?
}

public struct ZhulongScopeAuthorization: Equatable, Sendable {
    public let scopes: Set<ZhulongDataScope>
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let grantedAt: Date
    public let expiresAt: Date

    public func isValid(at date: Date) -> Bool {
        date >= grantedAt && date < expiresAt
    }
}

public enum ZhulongSessionError: Error, Equatable, Sendable {
    case emptyPrimaryIntent
    case emptyScopeProposal
    case emptyProviderIdentity
    case invalidProviderIdentity
    case invalidAuthorizationExpiration
    case scopeNotAuthorized
    case scopeDoesNotMatchProposal
    case authorizationExpired
    case providerIdentityMismatch
    case providerPayloadScopeMismatch
    case providerRunMismatch
    case noInterruptedProviderRun
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
    public private(set) var authorizations: [ZhulongScopeAuthorization]
    public private(set) var draftVersion: Int?
    public private(set) var providerSends: [ZhulongProviderSendRecord]
    public private(set) var events: [ZhulongSessionEvent]

    public var authorization: ZhulongScopeAuthorization? { authorizations.last }

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
        authorizations = []
        draftVersion = nil
        providerSends = []
        events = [
            ZhulongSessionEvent(
                sequence: 1,
                kind: .sessionCreated,
                occurredAt: now,
                summary: "已建立烛龙会话",
                providerRunID: nil
            )
        ]
    }

    init(
        restoredID: ZhulongSessionID,
        primaryIntent: String,
        proposedScopes: Set<ZhulongDataScope>,
        phase: ZhulongSessionPhase,
        authorizations: [ZhulongScopeAuthorization],
        draftVersion: Int?,
        providerSends: [ZhulongProviderSendRecord],
        events: [ZhulongSessionEvent]
    ) {
        id = restoredID
        self.primaryIntent = primaryIntent
        self.proposedScopes = proposedScopes
        self.phase = phase
        self.authorizations = authorizations
        self.draftVersion = draftVersion
        self.providerSends = providerSends
        self.events = events
    }

    public mutating func authorizeScope(
        _ scopes: Set<ZhulongDataScope>,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        expiresAt: Date,
        now: Date = Date()
    ) throws {
        let canExplicitlyReauthorize = phase == .readyForProvider
        guard phase == .scopeReview || canExplicitlyReauthorize else {
            throw ZhulongSessionError.invalidTransition(from: phase, to: .readyForProvider)
        }
        guard scopes == proposedScopes else {
            throw ZhulongSessionError.scopeDoesNotMatchProposal
        }
        try validateEventTime(now)
        guard expiresAt > now else {
            throw ZhulongSessionError.invalidAuthorizationExpiration
        }

        authorizations.append(ZhulongScopeAuthorization(
            scopes: scopes,
            providerIdentity: providerIdentity,
            grantedAt: now,
            expiresAt: expiresAt
        ))
        phase = .readyForProvider
        appendEvent(
            .scopeAuthorized,
            summary: "已授权 \(scopes.count) 项数据范围",
            now: now
        )
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
        guard authorization.isValid(at: now) else {
            throw ZhulongSessionError.authorizationExpired
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
        appendEvent(
            .providerRunStarted,
            summary: "已向 Provider 发送授权内容",
            providerRunID: runID,
            now: now
        )
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
        appendEvent(
            .draftReady,
            summary: "Provider 已返回可审查草稿",
            providerRunID: runID,
            now: now
        )
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
        appendEvent(
            .providerRunFailed,
            summary: "Provider 请求失败",
            providerRunID: runID,
            now: now
        )
    }

    public mutating func recoverInterruptedProviderRun(now: Date = Date()) throws {
        guard phase == .providerRunning,
              let runID = providerSends.last?.runID,
              providerSends.last?.status == .running
        else {
            throw ZhulongSessionError.noInterruptedProviderRun
        }
        try recordProviderFailure(
            ZhulongProviderFailure(
                code: "provider_run_interrupted",
                message: "上次 Provider 请求因应用中断而停止"
            ),
            runID: runID,
            now: now
        )
    }

    private mutating func appendEvent(
        _ kind: ZhulongSessionEventKind,
        summary: String,
        providerRunID: ZhulongProviderRunID? = nil,
        now: Date
    ) {
        events.append(
            ZhulongSessionEvent(
                sequence: UInt64(events.count + 1),
                kind: kind,
                occurredAt: now,
                summary: summary,
                providerRunID: providerRunID
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

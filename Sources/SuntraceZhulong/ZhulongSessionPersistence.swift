import Foundation

enum ZhulongSessionRestorationError: Error, Equatable {
    case identityMismatch
    case emptyPrimaryIntent
    case emptyScopeProposal
    case invalidAuthorization
    case invalidDraftVersion
    case noncanonicalEventSequence
    case nonmonotonicEventTime
    case invalidEventsForPhase
}

struct ZhulongSessionEventRecord: Codable, Equatable {
    var sequence: UInt64
    var kind: ZhulongSessionEventKind
    var occurredAt: Date
}

struct ZhulongScopeAuthorizationRecord: Codable, Equatable {
    var scopes: Set<ZhulongDataScope>
    var providerIdentity: String
    var grantedAt: Date
}

struct ZhulongSessionRecord: Codable, Equatable {
    var id: ZhulongSessionID
    var primaryIntent: String
    var proposedScopes: Set<ZhulongDataScope>
    var phase: ZhulongSessionPhase
    var authorization: ZhulongScopeAuthorizationRecord?
    var draftVersion: Int?
    var providerSends: [ZhulongProviderSendRecord]
    var events: [ZhulongSessionEventRecord]

    init(_ session: ZhulongSession) {
        id = session.id
        primaryIntent = session.primaryIntent
        proposedScopes = session.proposedScopes
        phase = session.phase
        authorization = session.authorization.map {
            ZhulongScopeAuthorizationRecord(
                scopes: $0.scopes,
                providerIdentity: $0.providerIdentity.rawValue,
                grantedAt: $0.grantedAt
            )
        }
        draftVersion = session.draftVersion
        providerSends = session.providerSends
        events = session.events.map {
            ZhulongSessionEventRecord(
                sequence: $0.sequence,
                kind: $0.kind,
                occurredAt: $0.occurredAt
            )
        }
    }

    func restore(expectedID: ZhulongSessionID) throws -> ZhulongSession {
        try validateBase(expectedID: expectedID)
        let restoredAuthorization = try restoreAuthorization()
        try validateProviderSends(authorization: restoredAuthorization)
        try validatePhase(authorization: restoredAuthorization)
        try validateEvents(authorization: restoredAuthorization)

        return ZhulongSession(
            restoredID: id,
            primaryIntent: primaryIntent,
            proposedScopes: proposedScopes,
            phase: phase,
            authorization: restoredAuthorization,
            draftVersion: draftVersion,
            providerSends: providerSends,
            events: events.map {
                ZhulongSessionEvent(
                    sequence: $0.sequence,
                    kind: $0.kind,
                    occurredAt: $0.occurredAt
                )
            }
        )
    }

    private func validateBase(expectedID: ZhulongSessionID) throws {
        guard id == expectedID else {
            throw ZhulongSessionRestorationError.identityMismatch
        }
        let normalizedIntent = primaryIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedIntent.isEmpty == false, normalizedIntent == primaryIntent else {
            throw ZhulongSessionRestorationError.emptyPrimaryIntent
        }
        guard proposedScopes.isEmpty == false else {
            throw ZhulongSessionRestorationError.emptyScopeProposal
        }
        guard events.isEmpty == false,
              events.enumerated().allSatisfy({ offset, event in
                  event.sequence == UInt64(offset + 1)
              })
        else {
            throw ZhulongSessionRestorationError.noncanonicalEventSequence
        }
        guard zip(events, events.dropFirst()).allSatisfy({ earlier, later in
            earlier.occurredAt <= later.occurredAt
        }) else {
            throw ZhulongSessionRestorationError.nonmonotonicEventTime
        }
    }

    private func restoreAuthorization() throws -> ZhulongScopeAuthorization? {
        try authorization.map { record in
            guard record.scopes == proposedScopes else {
                throw ZhulongSessionRestorationError.invalidAuthorization
            }
            let identity: ZhulongProviderConfigurationIdentity
            do {
                identity = try ZhulongProviderConfigurationIdentity(record.providerIdentity)
            } catch {
                throw ZhulongSessionRestorationError.invalidAuthorization
            }
            return ZhulongScopeAuthorization(
                scopes: record.scopes,
                providerIdentity: identity,
                grantedAt: record.grantedAt
            )
        }
    }

    private func validateProviderSends(
        authorization: ZhulongScopeAuthorization?
    ) throws {
        guard let authorization else {
            guard providerSends.isEmpty else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            return
        }
        guard Set(providerSends.map(\.runID)).count == providerSends.count,
              providerSends.allSatisfy({ send in
                  send.providerIdentity == authorization.providerIdentity &&
                      send.payload.scopes == authorization.scopes &&
                      validPayload(send.payload) &&
                      validSendResult(send)
              })
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func validPayload(_ payload: ZhulongProviderPayload) -> Bool {
        guard let validated = try? ZhulongProviderPayload(
            systemPrompt: payload.systemPrompt,
            userPrompt: payload.userPrompt,
            contextVersion: payload.contextVersion,
            scopeContent: payload.scopeContent
        ) else {
            return false
        }
        return validated == payload
    }

    private func validSendResult(_ send: ZhulongProviderSendRecord) -> Bool {
        switch send.status {
        case .running:
            return send.completedAt == nil && send.response == nil && send.failure == nil
        case .succeeded:
            guard let completedAt = send.completedAt,
                  let response = send.response,
                  response.draftVersion > 0,
                  response.content.isEmpty == false,
                  response.content == response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return false
            }
            return completedAt >= send.startedAt && send.failure == nil
        case .failed:
            guard let completedAt = send.completedAt,
                  let failure = send.failure,
                  failure.code.isEmpty == false,
                  failure.message.isEmpty == false,
                  failure.code == failure.code.trimmingCharacters(in: .whitespacesAndNewlines),
                  failure.message == failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                return false
            }
            return completedAt >= send.startedAt && send.response == nil
        }
    }

    private func validateEvents(
        authorization: ZhulongScopeAuthorization?
    ) throws {
        let expected = expectedEvents(authorization: authorization)
        guard events.count == expected.count,
              zip(events, expected).allSatisfy({ event, expectedEvent in
                  event.kind == expectedEvent.kind && event.occurredAt == expectedEvent.occurredAt
              })
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func expectedEvents(
        authorization: ZhulongScopeAuthorization?
    ) -> [(kind: ZhulongSessionEventKind, occurredAt: Date)] {
        var expected = [(kind: ZhulongSessionEventKind, occurredAt: Date)]()
        if let createdAt = events.first?.occurredAt {
            expected.append((.sessionCreated, createdAt))
        }
        if let authorization {
            expected.append((.scopeAuthorized, authorization.grantedAt))
        }
        for send in providerSends {
            expected.append((.providerRunStarted, send.startedAt))
            if let completedAt = send.completedAt {
                let resultKind: ZhulongSessionEventKind = send.status == .succeeded
                    ? .draftReady
                    : .providerRunFailed
                expected.append((resultKind, completedAt))
            }
        }
        return expected
    }

    private func validatePhase(authorization: ZhulongScopeAuthorization?) throws {
        switch phase {
        case .scopeReview:
            guard authorization == nil, draftVersion == nil, providerSends.isEmpty else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .readyForProvider:
            guard authorization != nil,
                  draftVersion == nil,
                  providerSends.last?.status != .running,
                  providerSends.allSatisfy({ $0.status == .failed })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .providerRunning:
            guard authorization != nil,
                  draftVersion == nil,
                  providerSends.last?.status == .running,
                  providerSends.dropLast().allSatisfy({ $0.status == .failed })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .draftReview:
            guard authorization != nil,
                  let draftVersion,
                  draftVersion > 0,
                  providerSends.last?.status == .succeeded,
                  providerSends.last?.response?.draftVersion == draftVersion,
                  providerSends.dropLast().allSatisfy({ $0.status == .failed })
            else {
                throw ZhulongSessionRestorationError.invalidDraftVersion
            }
        case .paused, .archived:
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }
}

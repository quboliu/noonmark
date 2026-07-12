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
    var summary: String
    var providerRunID: ZhulongProviderRunID?
}

struct ZhulongScopeAuthorizationRecord: Codable, Equatable {
    var scopes: Set<ZhulongDataScope>
    var providerIdentity: ZhulongProviderConfigurationIdentity
    var grantedAt: Date
    var expiresAt: Date
}

struct ZhulongSessionRecord: Codable, Equatable {
    var id: ZhulongSessionID
    var primaryIntent: String
    var proposedScopes: Set<ZhulongDataScope>
    var phase: ZhulongSessionPhase
    var authorizations: [ZhulongScopeAuthorizationRecord]
    var draftVersion: Int?
    var providerSends: [ZhulongProviderSendRecord]
    var events: [ZhulongSessionEventRecord]

    init(_ session: ZhulongSession) {
        id = session.id
        primaryIntent = session.primaryIntent
        proposedScopes = session.proposedScopes
        phase = session.phase
        authorizations = session.authorizations.map {
            ZhulongScopeAuthorizationRecord(
                scopes: $0.scopes,
                providerIdentity: $0.providerIdentity,
                grantedAt: $0.grantedAt,
                expiresAt: $0.expiresAt
            )
        }
        draftVersion = session.draftVersion
        providerSends = session.providerSends
        events = session.events.map {
            ZhulongSessionEventRecord(
                sequence: $0.sequence,
                kind: $0.kind,
                occurredAt: $0.occurredAt,
                summary: $0.summary,
                providerRunID: $0.providerRunID
            )
        }
    }

    func restore(expectedID: ZhulongSessionID) throws -> ZhulongSession {
        try validateBase(expectedID: expectedID)
        let restoredAuthorizations = try restoreAuthorizations()
        try validateProviderSends()
        try validatePhase(authorizations: restoredAuthorizations)
        try validateEvents(authorizations: restoredAuthorizations)

        return ZhulongSession(
            restoredID: id,
            primaryIntent: primaryIntent,
            proposedScopes: proposedScopes,
            phase: phase,
            authorizations: restoredAuthorizations,
            draftVersion: draftVersion,
            providerSends: providerSends,
            events: events.map {
                ZhulongSessionEvent(
                    sequence: $0.sequence,
                    kind: $0.kind,
                    occurredAt: $0.occurredAt,
                    summary: $0.summary,
                    providerRunID: $0.providerRunID
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
                  event.sequence == UInt64(offset + 1) &&
                      event.occurredAt.timeIntervalSinceReferenceDate.isFinite
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

    private func restoreAuthorizations() throws -> [ZhulongScopeAuthorization] {
        try authorizations.map { record in
            guard record.scopes == proposedScopes,
                  record.grantedAt.timeIntervalSinceReferenceDate.isFinite,
                  record.expiresAt.timeIntervalSinceReferenceDate.isFinite,
                  record.expiresAt > record.grantedAt,
                  validIdentity(record.providerIdentity)
            else {
                throw ZhulongSessionRestorationError.invalidAuthorization
            }
            return ZhulongScopeAuthorization(
                scopes: record.scopes,
                providerIdentity: record.providerIdentity,
                grantedAt: record.grantedAt,
                expiresAt: record.expiresAt
            )
        }
    }

    private func validIdentity(_ identity: ZhulongProviderConfigurationIdentity) -> Bool {
        guard let rebuilt = try? ZhulongProviderConfigurationIdentity(
            providerID: identity.providerID,
            kind: identity.kind,
            baseURL: identity.baseURL,
            location: identity.location,
            model: identity.model,
            dataCapabilities: identity.dataCapabilities
        ) else {
            return false
        }
        return rebuilt == identity
    }

    private func validateProviderSends() throws {
        guard Set(providerSends.map(\.runID)).count == providerSends.count,
              providerSends.allSatisfy({ send in
                  validIdentity(send.providerIdentity) &&
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
        guard send.startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        switch send.result {
        case .running:
            return true
        case let .succeeded(completedAt, response):
            return validCompletionTime(completedAt, after: send.startedAt) &&
                response.draftVersion > 0 &&
                response.content.isEmpty == false &&
                response.content == response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .failed(completedAt, failure):
            return validCompletionTime(completedAt, after: send.startedAt) &&
                failure.code.isEmpty == false &&
                failure.message.isEmpty == false &&
                failure.code == failure.code.trimmingCharacters(in: .whitespacesAndNewlines) &&
                failure.message == failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func validCompletionTime(_ completedAt: Date, after startedAt: Date) -> Bool {
        completedAt.timeIntervalSinceReferenceDate.isFinite && completedAt >= startedAt
    }

    private func validateEvents(
        authorizations: [ZhulongScopeAuthorization]
    ) throws {
        guard events.first == ZhulongSessionEventRecord(
            sequence: 1,
            kind: .sessionCreated,
            occurredAt: events[0].occurredAt,
            summary: "已建立烛龙会话",
            providerRunID: nil
        ) else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }

        var authorizationIndex = 0
        var sendIndex = 0
        var waitingForSendResult = false
        var currentAuthorization: ZhulongScopeAuthorization?
        for event in events.dropFirst() {
            switch event.kind {
            case .sessionCreated:
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            case .scopeAuthorized:
                guard waitingForSendResult == false,
                      authorizationIndex < authorizations.count,
                      event == authorizationEvent(
                          authorizations[authorizationIndex],
                          sequence: event.sequence
                      )
                else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                currentAuthorization = authorizations[authorizationIndex]
                authorizationIndex += 1
            case .providerRunStarted:
                guard waitingForSendResult == false,
                      sendIndex < providerSends.count,
                      currentAuthorization?.isValid(at: providerSends[sendIndex].startedAt) == true,
                      currentAuthorization?.providerIdentity == providerSends[sendIndex].providerIdentity,
                      currentAuthorization?.scopes == providerSends[sendIndex].payload.scopes,
                      event == startedEvent(providerSends[sendIndex], sequence: event.sequence)
                else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                waitingForSendResult = true
            case .providerRunFailed, .draftReady:
                guard waitingForSendResult,
                      sendIndex < providerSends.count,
                      event == resultEvent(providerSends[sendIndex], sequence: event.sequence)
                else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                sendIndex += 1
                waitingForSendResult = false
            }
        }

        let hasRunningSend = providerSends.last?.status == .running
        guard authorizationIndex == authorizations.count,
              sendIndex == providerSends.count - (hasRunningSend ? 1 : 0),
              waitingForSendResult == hasRunningSend
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func authorizationEvent(
        _ authorization: ZhulongScopeAuthorization,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .scopeAuthorized,
            occurredAt: authorization.grantedAt,
            summary: "已授权 \(authorization.scopes.count) 项数据范围",
            providerRunID: nil
        )
    }

    private func startedEvent(
        _ send: ZhulongProviderSendRecord,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .providerRunStarted,
            occurredAt: send.startedAt,
            summary: "已向 Provider 发送授权内容",
            providerRunID: send.runID
        )
    }

    private func resultEvent(
        _ send: ZhulongProviderSendRecord,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord? {
        switch send.result {
        case .running:
            return nil
        case let .succeeded(completedAt, _):
            return ZhulongSessionEventRecord(
                sequence: sequence,
                kind: .draftReady,
                occurredAt: completedAt,
                summary: "Provider 已返回可审查草稿",
                providerRunID: send.runID
            )
        case let .failed(completedAt, _):
            return ZhulongSessionEventRecord(
                sequence: sequence,
                kind: .providerRunFailed,
                occurredAt: completedAt,
                summary: "Provider 请求失败",
                providerRunID: send.runID
            )
        }
    }

    private func validatePhase(authorizations: [ZhulongScopeAuthorization]) throws {
        switch phase {
        case .scopeReview:
            guard authorizations.isEmpty, draftVersion == nil, providerSends.isEmpty else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .readyForProvider:
            guard authorizations.isEmpty == false,
                  draftVersion == nil,
                  providerSends.last?.status != .running,
                  providerSends.allSatisfy({ $0.status == .failed })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .providerRunning:
            guard authorizations.isEmpty == false,
                  draftVersion == nil,
                  providerSends.last?.status == .running,
                  providerSends.dropLast().allSatisfy({ $0.status == .failed })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .draftReview:
            guard authorizations.isEmpty == false,
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

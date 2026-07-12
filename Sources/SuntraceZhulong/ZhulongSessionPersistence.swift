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
    var reference: ZhulongSessionEventReference?

    var providerRunID: ZhulongProviderRunID? {
        guard case let .providerRun(runID) = reference else { return nil }
        return runID
    }

    var sessionEntryID: ZhulongSessionEntryID? {
        guard case let .sessionEntry(entryID) = reference else { return nil }
        return entryID
    }
}

struct ZhulongScopeAuthorizationRecord: Codable, Equatable {
    var scopes: Set<ZhulongDataScope>
    var providerIdentity: ZhulongProviderConfigurationIdentity
    var grantedAt: Date
    var expiresAt: Date
}

private struct ZhulongEventReplayState {
    var authorizationIndex = 0
    var sendIndex = 0
    var waitingForSendResult = false
    var currentAuthorization: ZhulongScopeAuthorization?
    var workspaceStatus = ZhulongWorkspaceStatus.active
    var correctionIndex = 0
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
    var workspaceStatus: ZhulongWorkspaceStatus
    var entries: [ZhulongSessionEntry]

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
                reference: $0.reference
            )
        }
        workspaceStatus = session.workspaceStatus
        entries = session.entries
    }

    func restore(expectedID: ZhulongSessionID) throws -> ZhulongSession {
        try validateBase(expectedID: expectedID)
        try validateEntries()
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
                    reference: $0.reference
                )
            },
            workspaceStatus: workspaceStatus,
            entries: entries
        )
    }

    private func validateEntries() throws {
        guard let firstEntry = entries.first,
              firstEntry.author == .user,
              firstEntry.kind == .statement,
              firstEntry.content == primaryIntent,
              firstEntry.correctsEntryID == nil,
              firstEntry.createdAt == events[0].occurredAt,
              Set(entries.map(\.id)).count == entries.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }

        var originals = Set<ZhulongSessionEntryID>()
        for entry in entries {
            let normalized = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  normalized.isEmpty == false,
                  normalized == entry.content
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            if let targetID = entry.correctsEntryID {
                guard entry.kind == .correction, originals.contains(targetID) else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
            } else {
                guard entry.kind != .correction else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                originals.insert(entry.id)
            }
        }
        guard zip(entries, entries.dropFirst()).allSatisfy({ earlier, later in
            earlier.createdAt < later.createdAt
        }) else {
            throw ZhulongSessionRestorationError.nonmonotonicEventTime
        }
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
            reference: nil
        ) else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }

        var state = ZhulongEventReplayState()
        let corrections = entries.filter { $0.correctsEntryID != nil }
        for event in events.dropFirst() {
            try consumeEvent(
                event,
                state: &state,
                authorizations: authorizations,
                corrections: corrections
            )
        }

        let hasRunningSend = providerSends.last?.status == .running
        guard state.authorizationIndex == authorizations.count,
              state.sendIndex == providerSends.count - (hasRunningSend ? 1 : 0),
              state.waitingForSendResult == hasRunningSend,
              state.correctionIndex == corrections.count,
              state.workspaceStatus == workspaceStatus,
              entriesAllowedByWorkspaceEvents()
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func consumeEvent(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        authorizations: [ZhulongScopeAuthorization],
        corrections: [ZhulongSessionEntry]
    ) throws {
        switch event.kind {
        case .sessionCreated:
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        case .scopeAuthorized:
            try consumeAuthorization(event, state: &state, authorizations: authorizations)
        case .providerRunStarted:
            try consumeProviderStart(event, state: &state)
        case .providerRunFailed, .draftReady:
            try consumeProviderResult(event, state: &state)
        case .sessionCorrected:
            try consumeCorrection(event, state: &state, corrections: corrections)
        case .sessionPaused:
            try consumePause(event, state: &state)
        case .sessionResumed:
            try consumeResume(event, state: &state)
        case .sessionArchived:
            try consumeArchive(event, state: &state)
        }
    }

    private func consumeAuthorization(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        authorizations: [ZhulongScopeAuthorization]
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.authorizationIndex < authorizations.count,
              event == authorizationEvent(
                  authorizations[state.authorizationIndex],
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.currentAuthorization = authorizations[state.authorizationIndex]
        state.authorizationIndex += 1
    }

    private func consumeProviderStart(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.sendIndex < providerSends.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let send = providerSends[state.sendIndex]
        guard state.currentAuthorization?.isValid(at: send.startedAt) == true,
              state.currentAuthorization?.providerIdentity == send.providerIdentity,
              state.currentAuthorization?.scopes == send.payload.scopes,
              event == startedEvent(send, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.waitingForSendResult = true
    }

    private func consumeProviderResult(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult,
              state.sendIndex < providerSends.count,
              event == resultEvent(providerSends[state.sendIndex], sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.sendIndex += 1
        state.waitingForSendResult = false
    }

    private func consumeCorrection(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        corrections: [ZhulongSessionEntry]
    ) throws {
        guard state.workspaceStatus == .active,
              state.correctionIndex < corrections.count,
              event == correctionEvent(corrections[state.correctionIndex], sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.correctionIndex += 1
    }

    private func consumePause(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        try consumeWorkspaceEvent(
            event,
            expectedStatus: .active,
            nextStatus: .paused,
            summary: "会话已暂停",
            state: &state
        )
    }

    private func consumeResume(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        try consumeWorkspaceEvent(
            event,
            expectedStatus: .paused,
            nextStatus: .active,
            summary: "会话已恢复",
            state: &state
        )
    }

    private func consumeArchive(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus != .archived else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        try consumeWorkspaceEvent(
            event,
            expectedStatus: state.workspaceStatus,
            nextStatus: .archived,
            summary: "会话已归档",
            state: &state
        )
    }

    private func consumeWorkspaceEvent(
        _ event: ZhulongSessionEventRecord,
        expectedStatus: ZhulongWorkspaceStatus,
        nextStatus: ZhulongWorkspaceStatus,
        summary: String,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == expectedStatus,
              state.waitingForSendResult == false,
              event == workspaceEvent(
                  kind: event.kind,
                  summary: summary,
                  sequence: event.sequence,
                  occurredAt: event.occurredAt
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.workspaceStatus = nextStatus
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
            reference: nil
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
            reference: .providerRun(send.runID)
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
                reference: .providerRun(send.runID)
            )
        case let .failed(completedAt, _):
            return ZhulongSessionEventRecord(
                sequence: sequence,
                kind: .providerRunFailed,
                occurredAt: completedAt,
                summary: "Provider 请求失败",
                reference: .providerRun(send.runID)
            )
        }
    }

    private func correctionEvent(
        _ correction: ZhulongSessionEntry,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .sessionCorrected,
            occurredAt: correction.createdAt,
            summary: "已追加会话更正",
            reference: .sessionEntry(correction.id)
        )
    }

    private func workspaceEvent(
        kind: ZhulongSessionEventKind,
        summary: String,
        sequence: UInt64,
        occurredAt: Date
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: kind,
            occurredAt: occurredAt,
            summary: summary,
            reference: nil
        )
    }

    private func entriesAllowedByWorkspaceEvents() -> Bool {
        entries.dropFirst().filter { $0.correctsEntryID == nil }.allSatisfy { entry in
            var status = ZhulongWorkspaceStatus.active
            for event in events where event.occurredAt < entry.createdAt {
                switch event.kind {
                case .sessionPaused: status = .paused
                case .sessionResumed: status = .active
                case .sessionArchived: status = .archived
                default: break
                }
            }
            return status == .active
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
        }
    }
}

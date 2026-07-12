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

struct ZhulongProviderSendRecordV2: Codable, Equatable {
    var runID: ZhulongProviderRunID
    var providerIdentity: ZhulongProviderConfigurationIdentity
    var payload: ZhulongProviderPayload
    var startedAt: Date
    var result: ZhulongProviderSendResult

    init(_ send: ZhulongProviderSendRecord) {
        runID = send.runID
        providerIdentity = send.providerIdentity
        payload = send.payload
        startedAt = send.startedAt
        result = send.result
    }

    var migrated: ZhulongProviderSendRecord {
        ZhulongProviderSendRecord(
            runID: runID,
            providerIdentity: providerIdentity,
            payload: payload,
            purpose: .conversation,
            startedAt: startedAt,
            result: result
        )
    }
}

struct ZhulongSessionEventRecordV1: Codable, Equatable {
    var sequence: UInt64
    var kind: ZhulongSessionEventKind
    var occurredAt: Date
    var summary: String
    var providerRunID: ZhulongProviderRunID?
}

struct ZhulongSessionRecordV1: Codable, Equatable {
    var id: ZhulongSessionID
    var primaryIntent: String
    var proposedScopes: Set<ZhulongDataScope>
    var phase: ZhulongSessionPhase
    var authorizations: [ZhulongScopeAuthorizationRecord]
    var draftVersion: Int?
    var providerSends: [ZhulongProviderSendRecordV2]
    var events: [ZhulongSessionEventRecordV1]

    init(_ session: ZhulongSession) {
        id = session.id
        primaryIntent = session.initialPrimaryIntent
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
        providerSends = session.providerSends.map(ZhulongProviderSendRecordV2.init)
        events = session.events.map {
            ZhulongSessionEventRecordV1(
                sequence: $0.sequence,
                kind: $0.kind,
                occurredAt: $0.occurredAt,
                summary: $0.summary,
                providerRunID: $0.providerRunID
            )
        }
    }
}

struct ZhulongSessionRecordV2: Codable, Equatable {
    var id: ZhulongSessionID
    var primaryIntent: String
    var proposedScopes: Set<ZhulongDataScope>
    var phase: ZhulongSessionPhase
    var authorizations: [ZhulongScopeAuthorizationRecord]
    var draftVersion: Int?
    var providerSends: [ZhulongProviderSendRecordV2]
    var events: [ZhulongSessionEventRecord]
    var workspaceStatus: ZhulongWorkspaceStatus
    var entries: [ZhulongSessionEntry]

    init(_ session: ZhulongSession) {
        id = session.id
        primaryIntent = session.initialPrimaryIntent
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
        providerSends = session.providerSends.map(ZhulongProviderSendRecordV2.init)
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
}

struct ZhulongSessionRecordV3: Codable, Equatable {
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
    var planningBriefs: [ZhulongPlanningBrief]
    var planningBriefReviews: [ZhulongPlanningBriefReview]
    var planningBriefInvalidations: [ZhulongPlanningBriefInvalidation]
    var planningDelegations: [ZhulongPlanningDelegation]
    var planningDelegationConsumptions: [ZhulongPlanningDelegationConsumption]
    var planningDelegationInvalidations: [ZhulongPlanningDelegationInvalidation]
    var planningRunInvalidations: [ZhulongPlanningRunInvalidation]

    init(_ session: ZhulongSession) {
        let record = ZhulongSessionRecord(session)
        id = record.id
        primaryIntent = record.primaryIntent
        proposedScopes = record.proposedScopes
        phase = record.phase
        authorizations = record.authorizations
        draftVersion = record.draftVersion
        providerSends = record.providerSends
        events = record.events
        workspaceStatus = record.workspaceStatus
        entries = record.entries
        planningBriefs = record.planningBriefs
        planningBriefReviews = record.planningBriefReviews
        planningBriefInvalidations = record.planningBriefInvalidations
        planningDelegations = record.planningDelegations
        planningDelegationConsumptions = record.planningDelegationConsumptions
        planningDelegationInvalidations = record.planningDelegationInvalidations
        planningRunInvalidations = record.planningRunInvalidations
    }
}

private struct ZhulongEventReplayState {
    var phase = ZhulongSessionPhase.scopeReview
    var authorizationIndex = 0
    var sendIndex = 0
    var waitingForSendResult = false
    var currentAuthorization: ZhulongScopeAuthorization?
    var workspaceStatus = ZhulongWorkspaceStatus.active
    var correctionIndex = 0
    var decisionIndex = 0
    var briefIndex = 0
    var reviewIndex = 0
    var briefInvalidationIndex = 0
    var delegationIndex = 0
    var consumptionIndex = 0
    var invalidationIndex = 0
    var runInvalidationIndex = 0
    var decisionGateIndex = 0
    var decisionGateResolutionIndex = 0
    var planArtifactIndex = 0
    var currentBriefID: ZhulongPlanningBriefID?
    var reviewedBriefID: ZhulongPlanningBriefID?
    var activeDelegationID: ZhulongPlanningDelegationID?
    var pendingInvalidationID: ZhulongPlanningDelegationID?
    var pendingInvalidationReason: ZhulongDelegationInvalidationReason?
    var pendingBriefInvalidationID: ZhulongPlanningBriefID?
    var pendingBriefInvalidationSourceID: ZhulongSessionEntryID?
    var pendingPlanningRunDelegationID: ZhulongPlanningDelegationID?
    var pendingRunInvalidationIDs: [ZhulongProviderRunID] = []
    var currentDecisionGateID: ZhulongDecisionGateID?
    var pendingDecisionGateResolutionID: ZhulongDecisionGateID?
    var latestDecisionGateResolutionEntryID: ZhulongSessionEntryID?
    var requiredDecisionGateRevisionEntryID: ZhulongSessionEntryID?
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
    var planningBriefs: [ZhulongPlanningBrief]
    var planningBriefReviews: [ZhulongPlanningBriefReview]
    var planningBriefInvalidations: [ZhulongPlanningBriefInvalidation]
    var planningDelegations: [ZhulongPlanningDelegation]
    var planningDelegationConsumptions: [ZhulongPlanningDelegationConsumption]
    var planningDelegationInvalidations: [ZhulongPlanningDelegationInvalidation]
    var planningRunInvalidations: [ZhulongPlanningRunInvalidation]
    var decisionGates: [ZhulongDecisionGate]
    var decisionGateResolutions: [ZhulongDecisionGateResolution]
    var planArtifacts: [ZhulongPlanArtifact]

    init(_ session: ZhulongSession) {
        id = session.id
        primaryIntent = session.initialPrimaryIntent
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
        planningBriefs = session.planningBriefs
        planningBriefReviews = session.planningBriefReviews
        planningBriefInvalidations = session.planningBriefInvalidations
        planningDelegations = session.planningDelegations
        planningDelegationConsumptions = session.planningDelegationConsumptions
        planningDelegationInvalidations = session.planningDelegationInvalidations
        planningRunInvalidations = session.planningRunInvalidations
        decisionGates = session.decisionGates
        decisionGateResolutions = session.decisionGateResolutions
        planArtifacts = session.planArtifacts
    }

    init(migrating record: ZhulongSessionRecordV1) {
        id = record.id
        primaryIntent = record.primaryIntent
        proposedScopes = record.proposedScopes
        phase = record.phase
        authorizations = record.authorizations
        draftVersion = record.draftVersion
        providerSends = record.providerSends.map(\.migrated)
        events = record.events.map {
            ZhulongSessionEventRecord(
                sequence: $0.sequence,
                kind: $0.kind,
                occurredAt: $0.occurredAt,
                summary: $0.summary,
                reference: $0.providerRunID.map(ZhulongSessionEventReference.providerRun)
            )
        }
        workspaceStatus = .active
        let createdAt = record.events.first?.occurredAt ?? .distantPast
        entries = [
            ZhulongSessionEntry(
                id: ZhulongSessionEntryID(record.id.rawValue),
                author: .user,
                kind: .statement,
                content: record.primaryIntent,
                createdAt: createdAt,
                correctsEntryID: nil
            )
        ]
        planningBriefs = []
        planningBriefReviews = []
        planningBriefInvalidations = []
        planningDelegations = []
        planningDelegationConsumptions = []
        planningDelegationInvalidations = []
        planningRunInvalidations = []
        decisionGates = []
        decisionGateResolutions = []
        planArtifacts = []
    }

    init(migrating record: ZhulongSessionRecordV2) {
        id = record.id
        primaryIntent = record.primaryIntent
        proposedScopes = record.proposedScopes
        phase = record.phase
        authorizations = record.authorizations
        draftVersion = record.draftVersion
        providerSends = record.providerSends.map(\.migrated)
        events = record.events
        workspaceStatus = record.workspaceStatus
        entries = record.entries
        planningBriefs = []
        planningBriefReviews = []
        planningBriefInvalidations = []
        planningDelegations = []
        planningDelegationConsumptions = []
        planningDelegationInvalidations = []
        planningRunInvalidations = []
        decisionGates = []
        decisionGateResolutions = []
        planArtifacts = []
    }

    init(migrating record: ZhulongSessionRecordV3) {
        id = record.id
        primaryIntent = record.primaryIntent
        proposedScopes = record.proposedScopes
        phase = record.phase
        authorizations = record.authorizations
        draftVersion = record.draftVersion
        providerSends = record.providerSends.map(\.migratedFromVersionThree)
        events = record.events
        workspaceStatus = record.workspaceStatus
        entries = record.entries
        planningBriefs = record.planningBriefs
        planningBriefReviews = record.planningBriefReviews
        planningBriefInvalidations = record.planningBriefInvalidations
        planningDelegations = record.planningDelegations
        planningDelegationConsumptions = record.planningDelegationConsumptions
        planningDelegationInvalidations = record.planningDelegationInvalidations
        planningRunInvalidations = record.planningRunInvalidations
        decisionGates = []
        decisionGateResolutions = []
        planArtifacts = []
    }

    func restore(
        expectedID: ZhulongSessionID,
        allowsMigratedLegacyPlanning: Bool
    ) throws -> ZhulongSession {
        let containsMigratedLegacyPlanning = providerSends.contains { send in
            if case .migratedLegacyPlanning = send.purpose { return true }
            return false
        }
        guard allowsMigratedLegacyPlanning || containsMigratedLegacyPlanning == false else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        try validateBase(expectedID: expectedID)
        try validateEntries()
        let restoredAuthorizations = try restoreAuthorizations()
        try validateProviderSends()
        try validatePlanningArtifacts()
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
            entries: entries,
            planningBriefs: planningBriefs,
            planningBriefReviews: planningBriefReviews,
            planningBriefInvalidations: planningBriefInvalidations,
            planningDelegations: planningDelegations,
            planningDelegationConsumptions: planningDelegationConsumptions,
            planningDelegationInvalidations: planningDelegationInvalidations,
            planningRunInvalidations: planningRunInvalidations,
            decisionGates: decisionGates,
            decisionGateResolutions: decisionGateResolutions,
            planArtifacts: planArtifacts,
            hasAuthenticatedLegacyPlanningProvenance: allowsMigratedLegacyPlanning &&
                containsMigratedLegacyPlanning
        )
    }

    private func validatePlanningArtifacts() throws {
        let briefsAreValid = planningBriefs.enumerated().allSatisfy { offset, brief in
            brief.version == offset + 1 &&
                brief.publishedAt.timeIntervalSinceReferenceDate.isFinite &&
                brief.dataScopes.isSubset(of: proposedScopes) &&
                brief.sourceEntryIDs.allSatisfy { sourceID in
                    entries.contains {
                        $0.id == sourceID && $0.correctsEntryID == nil
                    }
                } &&
                validBriefContent(brief)
        }
        guard Set(planningBriefs.map(\.id)).count == planningBriefs.count,
              briefsAreValid,
              Set(planningBriefReviews.map(\.briefID)).count == planningBriefReviews.count,
              planningBriefReviews.allSatisfy({ review in
                  review.reviewedAt.timeIntervalSinceReferenceDate.isFinite &&
                      planningBriefs.contains(where: { $0.id == review.briefID })
              }),
              Set(planningBriefInvalidations.map(\.briefID)).count == planningBriefInvalidations.count,
              planningBriefInvalidations.allSatisfy({ invalidation in
                  invalidation.invalidatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      planningBriefs.contains(where: {
                          $0.id == invalidation.briefID &&
                              $0.sourceEntryIDs.contains(invalidation.sourceEntryID)
                      })
              }),
              Set(planningDelegations.map(\.id)).count == planningDelegations.count,
              planningDelegations.allSatisfy({ delegation in
                  delegation.sessionID == id &&
                      delegation.grantedAt.timeIntervalSinceReferenceDate.isFinite &&
                      planningBriefs.contains(where: {
                          $0.id == delegation.briefID &&
                              $0.version == delegation.briefVersion &&
                              $0.dataScopes == delegation.dataScopes &&
                              $0.delegatedActivities == delegation.activities
                      }) &&
                      validIdentity(delegation.providerIdentity)
              }),
              Set(planningDelegationConsumptions.map(\.delegationID)).count ==
              planningDelegationConsumptions.count,
              planningDelegationConsumptions.allSatisfy({ consumption in
                  consumption.consumedAt.timeIntervalSinceReferenceDate.isFinite &&
                      planningDelegations.contains(where: { $0.id == consumption.delegationID })
              }),
              Set(planningDelegationInvalidations.map(\.delegationID)).count ==
              planningDelegationInvalidations.count,
              planningDelegationInvalidations.allSatisfy({ invalidation in
                  invalidation.invalidatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      planningDelegations.contains(where: { $0.id == invalidation.delegationID })
              }),
              Set(planningRunInvalidations.map(\.runID)).count == planningRunInvalidations.count,
              planningRunInvalidations.allSatisfy({ invalidation in
                  invalidation.invalidatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      providerSends.contains(where: { send in
                          guard send.runID == invalidation.runID,
                                let contract = send.planningContract
                          else { return false }
                          return contract.briefID == invalidation.briefID
                      }) &&
                      validPlanningRunInvalidation(invalidation)
              }),
              Set(decisionGates.map(\.id)).count == decisionGates.count,
              Set(decisionGates.map(\.runID)).count == decisionGates.count,
              decisionGates.allSatisfy(validDecisionGate),
              Set(decisionGateResolutions.map(\.gateID)).count == decisionGateResolutions.count,
              decisionGateResolutions.allSatisfy(validDecisionGateResolution),
              Set(planArtifacts.map(\.id)).count == planArtifacts.count,
              Set(planArtifacts.map(\.runID)).count == planArtifacts.count,
              planArtifacts.enumerated().allSatisfy({ offset, artifact in
                  artifact.version == offset + 1 && validPlanArtifact(artifact)
              })
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func validDecisionGate(_ gate: ZhulongDecisionGate) -> Bool {
        guard gate.sessionID == id,
              gate.openedAt.timeIntervalSinceReferenceDate.isFinite,
              let send = providerSends.first(where: { $0.runID == gate.runID }),
              send.providerIdentity == gate.providerIdentity,
              send.payload.contextVersion == gate.contextVersion,
              send.completedAt == gate.openedAt,
              send.response?.draftVersion == nil,
              case let .delegatedPlanning(contract) = send.purpose,
              contract.briefID == gate.briefID,
              contract.briefVersion == gate.briefVersion,
              let parsed = try? ZhulongPlanningOutputParser().parse(send.response?.content ?? ""),
              case let .decisionGate(parsedDraft) = parsed
        else { return false }
        return parsedDraft == gate.draft
    }

    private func validDecisionGateResolution(_ resolution: ZhulongDecisionGateResolution) -> Bool {
        guard resolution.resolvedAt.timeIntervalSinceReferenceDate.isFinite,
              let gate = decisionGates.first(where: { $0.id == resolution.gateID }),
              let option = gate.draft.options.first(where: {
                  $0.id == resolution.selectedOptionID
              }),
              let entry = entries.first(where: { $0.id == resolution.decisionEntryID }),
              entry.kind == .decision,
              entry.author == .user,
              entry.createdAt > gate.openedAt,
              resolution.resolvedAt == Date(
                  timeIntervalSinceReferenceDate: entry.createdAt.timeIntervalSinceReferenceDate.nextUp
              ),
              entry.content == option.title ||
              entry.content.hasPrefix("\(option.title)：") &&
              entry.content.count > option.title.count + 1
        else { return false }
        return true
    }

    private func validPlanArtifact(_ artifact: ZhulongPlanArtifact) -> Bool {
        guard artifact.sessionID == id,
              artifact.createdAt.timeIntervalSinceReferenceDate.isFinite,
              let send = providerSends.first(where: { $0.runID == artifact.runID }),
              send.providerIdentity == artifact.providerIdentity,
              send.payload.contextVersion == artifact.contextVersion,
              send.completedAt == artifact.createdAt,
              send.response?.draftVersion == artifact.version,
              case let .delegatedPlanning(contract) = send.purpose,
              contract.briefID == artifact.briefID,
              contract.briefVersion == artifact.briefVersion,
              let brief = planningBriefs.first(where: {
                  $0.id == contract.briefID && $0.version == contract.briefVersion
              }),
              let parsed = try? ZhulongPlanningOutputParser().parse(send.response?.content ?? ""),
              case let .planArtifact(parsedProposal) = parsed,
              parsedProposal.isBound(to: brief, contract: contract, payload: send.payload)
        else { return false }
        return parsedProposal == artifact.proposal
    }

    private func validPlanningRunInvalidation(
        _ invalidation: ZhulongPlanningRunInvalidation
    ) -> Bool {
        guard let brief = planningBriefs.first(where: { $0.id == invalidation.briefID }) else {
            return false
        }
        switch invalidation.reason {
        case .briefRevised:
            return invalidation.sourceEntryID == nil
        case .sourceCorrected:
            guard let sourceEntryID = invalidation.sourceEntryID else { return false }
            return brief.sourceEntryIDs.contains(sourceEntryID)
        }
    }

    private func validBriefContent(_ brief: ZhulongPlanningBrief) -> Bool {
        (try? ZhulongPlanningBriefDraft(
            goal: brief.goal,
            successCriteria: brief.successCriteria,
            hardConstraints: brief.hardConstraints,
            userDecisions: brief.userDecisions,
            delegatedActivities: brief.delegatedActivities,
            assumptions: brief.assumptions,
            openQuestions: brief.openQuestions,
            dataScopes: brief.dataScopes,
            sourceEntryIDs: brief.sourceEntryIDs
        )) != nil
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
            earlier.occurredAt < later.occurredAt
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
                (response.draftVersion.map { $0 > 0 } ?? true) &&
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
        completedAt.timeIntervalSinceReferenceDate.isFinite && completedAt > startedAt
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
        let decisions = entries.filter { $0.kind == .decision }
        for event in events.dropFirst() {
            try consumeEvent(
                event,
                state: &state,
                authorizations: authorizations,
                corrections: corrections,
                decisions: decisions
            )
        }

        let hasRunningSend = providerSends.last?.status == .running
        guard state.authorizationIndex == authorizations.count,
              state.sendIndex == providerSends.count - (hasRunningSend ? 1 : 0),
              state.waitingForSendResult == hasRunningSend,
              state.correctionIndex == corrections.count,
              state.decisionIndex == decisions.count,
              state.briefIndex == planningBriefs.count,
              state.reviewIndex == planningBriefReviews.count,
              state.briefInvalidationIndex == planningBriefInvalidations.count,
              state.delegationIndex == planningDelegations.count,
              state.consumptionIndex == planningDelegationConsumptions.count,
              state.invalidationIndex == planningDelegationInvalidations.count,
              state.runInvalidationIndex == planningRunInvalidations.count,
              state.decisionGateIndex == decisionGates.count,
              state.decisionGateResolutionIndex == decisionGateResolutions.count,
              state.planArtifactIndex == planArtifacts.count,
              state.pendingInvalidationID == nil,
              state.pendingInvalidationReason == nil,
              state.pendingBriefInvalidationID == nil,
              state.pendingBriefInvalidationSourceID == nil,
              state.pendingPlanningRunDelegationID == nil,
              state.pendingDecisionGateResolutionID == nil,
              state.pendingRunInvalidationIDs.isEmpty,
              state.phase == phase,
              state.currentBriefID == currentPlanningBriefID(),
              state.reviewedBriefID == currentReviewedBriefID(),
              state.activeDelegationID == currentActiveDelegationID(),
              state.currentDecisionGateID == currentDecisionGateID(),
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
        corrections: [ZhulongSessionEntry],
        decisions: [ZhulongSessionEntry]
    ) throws {
        try validatePendingEventKind(event.kind, state: state)
        switch event.kind {
        case .planningBriefPublished:
            try consumePlanningBrief(event, state: &state)
        case .planningBriefReviewed:
            try consumePlanningBriefReview(event, state: &state)
        case .planningBriefInvalidated:
            try consumePlanningBriefInvalidation(event, state: &state)
        case .planningDelegationGranted:
            try consumePlanningDelegation(event, state: &state)
        case .planningDelegationConsumed:
            try consumePlanningDelegationConsumption(event, state: &state)
        case .planningDelegationInvalidated:
            try consumePlanningDelegationInvalidation(event, state: &state)
        case .planningRunInvalidated:
            try consumePlanningRunInvalidation(event, state: &state)
        case .planningDecisionGateResolved:
            try consumeDecisionGateResolution(event, state: &state)
        default:
            try consumeSessionEvent(
                event,
                state: &state,
                authorizations: authorizations,
                corrections: corrections,
                decisions: decisions
            )
        }
    }

    private func validatePendingEventKind(
        _ kind: ZhulongSessionEventKind,
        state: ZhulongEventReplayState
    ) throws {
        let expectedKind: ZhulongSessionEventKind? = if state.pendingBriefInvalidationID != nil {
            .planningBriefInvalidated
        } else if state.pendingDecisionGateResolutionID != nil {
            .planningDecisionGateResolved
        } else if state.pendingRunInvalidationIDs.isEmpty == false {
            .planningRunInvalidated
        } else if state.pendingInvalidationID != nil {
            .planningDelegationInvalidated
        } else if state.pendingPlanningRunDelegationID != nil {
            .providerRunStarted
        } else {
            nil
        }
        guard expectedKind == nil || expectedKind == kind else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func consumeSessionEvent(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        authorizations: [ZhulongScopeAuthorization],
        corrections: [ZhulongSessionEntry],
        decisions: [ZhulongSessionEntry]
    ) throws {
        switch event.kind {
        case .sessionCreated:
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        case .scopeAuthorized:
            try consumeAuthorization(event, state: &state, authorizations: authorizations)
        case .providerRunStarted:
            try consumeProviderStart(event, state: &state)
        case .providerRunFailed, .draftReady, .planningDecisionGateOpened:
            try consumeProviderResult(event, state: &state)
        case .sessionCorrected:
            try consumeCorrection(event, state: &state, corrections: corrections)
        case .sessionDecisionRecorded:
            try consumeDecision(event, state: &state, decisions: decisions)
        case .sessionPaused:
            try consumePause(event, state: &state)
        case .sessionResumed:
            try consumeResume(event, state: &state)
        case .sessionArchived:
            try consumeArchive(event, state: &state)
        case .planningBriefPublished, .planningBriefReviewed,
             .planningBriefInvalidated,
             .planningDelegationGranted, .planningDelegationConsumed,
             .planningDelegationInvalidated, .planningRunInvalidated,
             .planningDecisionGateResolved:
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
    }

    private func consumeAuthorization(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        authorizations: [ZhulongScopeAuthorization]
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase == .scopeReview || state.phase == .readyForProvider,
              state.authorizationIndex < authorizations.count,
              event == authorizationEvent(
                  authorizations[state.authorizationIndex],
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.currentAuthorization = authorizations[state.authorizationIndex]
        if let activeDelegationID = state.activeDelegationID {
            state.pendingInvalidationID = activeDelegationID
            state.pendingInvalidationReason = .authorizationChanged
            state.activeDelegationID = nil
        }
        state.phase = .readyForProvider
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
              send.payload.scopes.isSubset(of: state.currentAuthorization?.scopes ?? []),
              validPhaseForRun(send, phase: state.phase),
              validRunAuthority(send, state: state),
              event == startedEvent(send, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.pendingPlanningRunDelegationID = nil
        state.phase = .providerRunning
        state.waitingForSendResult = true
    }

    private func consumeProviderResult(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult,
              state.phase == .providerRunning,
              state.sendIndex < providerSends.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let send = providerSends[state.sendIndex]
        switch send.result {
        case .running:
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        case .failed:
            guard event == resultEvent(send, sequence: event.sequence) else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            state.phase = .readyForProvider
        case let .succeeded(_, response):
            try consumeSucceededProviderResult(
                event,
                send: send,
                response: response,
                state: &state
            )
        }
        state.sendIndex += 1
        state.waitingForSendResult = false
    }

    private func consumeSucceededProviderResult(
        _ event: ZhulongSessionEventRecord,
        send: ZhulongProviderSendRecord,
        response: ZhulongProviderResponse,
        state: inout ZhulongEventReplayState
    ) throws {
        switch send.purpose {
        case .delegatedPlanning:
            guard let output = try? ZhulongPlanningOutputParser().parse(response.content) else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            switch output {
            case .decisionGate:
                guard response.draftVersion == nil else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                try consumeDecisionGateResult(event, send: send, state: &state)
            case .planArtifact:
                guard response.draftVersion != nil else {
                    throw ZhulongSessionRestorationError.invalidEventsForPhase
                }
                try consumePlanArtifactResult(event, send: send, state: &state)
            }
        case .conversation, .migratedLegacyPlanning:
            guard event == resultEvent(send, sequence: event.sequence) else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            state.phase = .draftReview
        }
    }

    private func consumeDecisionGateResult(
        _ event: ZhulongSessionEventRecord,
        send: ZhulongProviderSendRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.decisionGateIndex < decisionGates.count else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let gate = decisionGates[state.decisionGateIndex]
        guard gate.runID == send.runID,
              validDecisionGate(gate),
              event == decisionGateOpenedEvent(gate, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.currentDecisionGateID = gate.id
        state.decisionGateIndex += 1
        state.phase = .decisionGate
    }

    private func consumePlanArtifactResult(
        _ event: ZhulongSessionEventRecord,
        send: ZhulongProviderSendRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.planArtifactIndex < planArtifacts.count else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let artifact = planArtifacts[state.planArtifactIndex]
        guard artifact.runID == send.runID,
              validPlanArtifact(artifact),
              event == planArtifactReadyEvent(artifact, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.planArtifactIndex += 1
        state.phase = .draftReview
    }

    private func validRunAuthority(
        _ send: ZhulongProviderSendRecord,
        state: ZhulongEventReplayState
    ) -> Bool {
        switch send.purpose {
        case .conversation:
            return state.pendingPlanningRunDelegationID == nil &&
                state.activeDelegationID == nil
        case let .delegatedPlanning(contract), let .migratedLegacyPlanning(contract):
            guard state.pendingPlanningRunDelegationID == contract.delegationID,
                  let delegation = planningDelegations.first(where: {
                      $0.id == contract.delegationID
                  })
            else { return false }
            return contract == ZhulongPlanningRunContract(delegation: delegation) &&
                send.payload.scopes == contract.dataScopes
        }
    }

    private func validPhaseForRun(
        _ send: ZhulongProviderSendRecord,
        phase: ZhulongSessionPhase
    ) -> Bool {
        switch send.purpose {
        case .conversation: phase == .readyForProvider
        case .delegatedPlanning, .migratedLegacyPlanning:
            phase == .readyForProvider || phase == .draftReview
        }
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
        let correction = corrections[state.correctionIndex]
        let invalidation = planningInvalidation(for: correction, currentBriefID: state.currentBriefID)
        guard state.phase != .providerRunning ||
            canCorrectDuringDelegatedPlanning(correction, invalidation: invalidation, state: state)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        if let invalidation {
            state.pendingBriefInvalidationID = invalidation.briefID
            state.pendingBriefInvalidationSourceID = invalidation.sourceEntryID
        }
        state.correctionIndex += 1
    }

    private func canCorrectDuringDelegatedPlanning(
        _: ZhulongSessionEntry,
        invalidation: (briefID: ZhulongPlanningBriefID, sourceEntryID: ZhulongSessionEntryID)?,
        state: ZhulongEventReplayState
    ) -> Bool {
        guard state.waitingForSendResult,
              state.sendIndex < providerSends.count,
              let contract = providerSends[state.sendIndex].planningContract,
              contract.briefID == state.currentBriefID
        else { return false }
        return invalidation == nil
    }

    private func planningInvalidation(
        for correction: ZhulongSessionEntry,
        currentBriefID: ZhulongPlanningBriefID?
    ) -> (briefID: ZhulongPlanningBriefID, sourceEntryID: ZhulongSessionEntryID)? {
        guard let sourceEntryID = correction.correctsEntryID,
              let briefID = currentBriefID,
              planningBriefs.first(where: { $0.id == briefID })?
              .sourceEntryIDs.contains(sourceEntryID) == true
        else { return nil }
        return (briefID, sourceEntryID)
    }

    private func consumeDecision(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState,
        decisions: [ZhulongSessionEntry]
    ) throws {
        guard state.workspaceStatus == .active,
              state.decisionIndex < decisions.count,
              event == decisionEvent(decisions[state.decisionIndex], sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        if let gateID = state.currentDecisionGateID {
            guard state.decisionGateResolutionIndex < decisionGateResolutions.count,
                  decisionGateResolutions[state.decisionGateResolutionIndex].gateID == gateID,
                  decisionGateResolutions[state.decisionGateResolutionIndex].decisionEntryID ==
                  decisions[state.decisionIndex].id
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
            state.pendingDecisionGateResolutionID = gateID
        }
        state.decisionIndex += 1
    }

    private func consumeDecisionGateResolution(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.phase == .decisionGate,
              let gateID = state.pendingDecisionGateResolutionID,
              state.decisionGateResolutionIndex < decisionGateResolutions.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let resolution = decisionGateResolutions[state.decisionGateResolutionIndex]
        guard resolution.gateID == gateID,
              event == decisionGateResolutionEvent(resolution, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.pendingDecisionGateResolutionID = nil
        state.currentDecisionGateID = nil
        state.latestDecisionGateResolutionEntryID = resolution.decisionEntryID
        state.requiredDecisionGateRevisionEntryID = resolution.decisionEntryID
        state.decisionGateResolutionIndex += 1
        state.phase = .readyForProvider
    }

    private func consumePlanningBrief(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase != .providerRunning,
              state.phase != .decisionGate,
              state.briefIndex < planningBriefs.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let brief = planningBriefs[state.briefIndex]
        guard event == planningBriefEvent(brief, sequence: event.sequence),
              validDecisionGateRevision(brief, requiredEntryID: state.requiredDecisionGateRevisionEntryID)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        if let previousBriefID = state.currentBriefID {
            state.pendingRunInvalidationIDs = pendingRunInvalidationIDs(
                briefID: previousBriefID,
                completedSendCount: state.sendIndex,
                invalidationIndex: state.runInvalidationIndex
            )
        }
        state.requiredDecisionGateRevisionEntryID = nil
        state.pendingInvalidationID = state.activeDelegationID
        state.pendingInvalidationReason = state.activeDelegationID == nil ? nil : .briefRevised
        state.currentBriefID = brief.id
        state.reviewedBriefID = nil
        state.activeDelegationID = nil
        state.briefIndex += 1
    }

    private func validDecisionGateRevision(
        _ brief: ZhulongPlanningBrief,
        requiredEntryID: ZhulongSessionEntryID?
    ) -> Bool {
        guard let requiredEntryID else { return true }
        guard brief.sourceEntryIDs.contains(requiredEntryID),
              let decision = entries.first(where: { $0.id == requiredEntryID }),
              decision.kind == .decision,
              decision.author == .user
        else { return false }
        let effectiveDecision = entries.last(where: {
            $0.correctsEntryID == requiredEntryID
        })?.content ?? decision.content
        return brief.userDecisions.contains(effectiveDecision)
    }

    private func consumePlanningBriefReview(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase != .providerRunning,
              state.pendingInvalidationID == nil,
              state.reviewIndex < planningBriefReviews.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let review = planningBriefReviews[state.reviewIndex]
        guard state.currentBriefID == review.briefID,
              state.reviewedBriefID == nil,
              event == planningBriefReviewEvent(review, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.reviewedBriefID = review.briefID
        state.reviewIndex += 1
    }

    private func consumePlanningBriefInvalidation(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase != .providerRunning,
              let briefID = state.pendingBriefInvalidationID,
              let sourceEntryID = state.pendingBriefInvalidationSourceID,
              state.briefInvalidationIndex < planningBriefInvalidations.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let invalidation = planningBriefInvalidations[state.briefInvalidationIndex]
        guard invalidation.briefID == briefID,
              invalidation.sourceEntryID == sourceEntryID,
              event == planningBriefInvalidationEvent(
                  invalidation,
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        if let activeDelegationID = state.activeDelegationID {
            state.pendingInvalidationID = activeDelegationID
            state.pendingInvalidationReason = .briefSourceCorrected
            state.activeDelegationID = nil
        }
        state.pendingRunInvalidationIDs = pendingRunInvalidationIDs(
            briefID: briefID,
            completedSendCount: state.sendIndex,
            invalidationIndex: state.runInvalidationIndex
        )
        state.currentBriefID = nil
        state.reviewedBriefID = nil
        state.requiredDecisionGateRevisionEntryID = state.latestDecisionGateResolutionEntryID
        state.pendingBriefInvalidationID = nil
        state.pendingBriefInvalidationSourceID = nil
        state.briefInvalidationIndex += 1
    }

    private func pendingRunInvalidationIDs(
        briefID: ZhulongPlanningBriefID,
        completedSendCount: Int,
        invalidationIndex: Int
    ) -> [ZhulongProviderRunID] {
        let alreadyInvalidated = Set(
            planningRunInvalidations.prefix(invalidationIndex).map(\.runID)
        )
        return providerSends.prefix(completedSendCount).compactMap { send in
            guard alreadyInvalidated.contains(send.runID) == false,
                  let contract = send.planningContract,
                  contract.briefID == briefID
            else { return nil }
            return send.runID
        }
    }

    private func consumePlanningRunInvalidation(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard let runID = state.pendingRunInvalidationIDs.first,
              state.runInvalidationIndex < planningRunInvalidations.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let invalidation = planningRunInvalidations[state.runInvalidationIndex]
        guard invalidation.runID == runID,
              event == planningRunInvalidationEvent(
                  invalidation,
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.pendingRunInvalidationIDs.removeFirst()
        let invalidatesDecisionGate = state.currentDecisionGateID.map { gateID in
            decisionGates.first(where: { $0.id == gateID })?.runID == runID
        } ?? false
        if invalidatesDecisionGate {
            state.currentDecisionGateID = nil
            state.phase = .readyForProvider
        }
        state.runInvalidationIndex += 1
    }

    private func consumePlanningDelegation(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase != .providerRunning,
              state.pendingInvalidationID == nil,
              state.activeDelegationID == nil,
              state.requiredDecisionGateRevisionEntryID == nil,
              state.delegationIndex < planningDelegations.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let delegation = planningDelegations[state.delegationIndex]
        guard state.currentBriefID == delegation.briefID,
              state.reviewedBriefID == delegation.briefID,
              let brief = planningBriefs.first(where: { $0.id == delegation.briefID }),
              brief.openQuestions.contains(where: \.isBlocking) == false,
              state.currentAuthorization?.isValid(at: delegation.grantedAt) == true,
              state.currentAuthorization?.providerIdentity == delegation.providerIdentity,
              delegation.dataScopes.isSubset(of: state.currentAuthorization?.scopes ?? []),
              event == planningDelegationEvent(delegation, sequence: event.sequence)
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.activeDelegationID = delegation.id
        state.delegationIndex += 1
    }

    private func consumePlanningDelegationConsumption(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              state.phase != .providerRunning,
              state.pendingInvalidationID == nil,
              state.consumptionIndex < planningDelegationConsumptions.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let consumption = planningDelegationConsumptions[state.consumptionIndex]
        guard state.activeDelegationID == consumption.delegationID,
              event == planningDelegationConsumptionEvent(
                  consumption,
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.activeDelegationID = nil
        state.pendingPlanningRunDelegationID = consumption.delegationID
        state.consumptionIndex += 1
    }

    private func consumePlanningDelegationInvalidation(
        _ event: ZhulongSessionEventRecord,
        state: inout ZhulongEventReplayState
    ) throws {
        guard state.workspaceStatus == .active,
              state.waitingForSendResult == false,
              let delegationID = state.pendingInvalidationID,
              let reason = state.pendingInvalidationReason,
              state.invalidationIndex < planningDelegationInvalidations.count
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        let invalidation = planningDelegationInvalidations[state.invalidationIndex]
        guard invalidation.delegationID == delegationID,
              invalidation.reason == reason,
              event == planningDelegationInvalidationEvent(
                  invalidation,
                  sequence: event.sequence
              )
        else {
            throw ZhulongSessionRestorationError.invalidEventsForPhase
        }
        state.pendingInvalidationID = nil
        state.pendingInvalidationReason = nil
        state.invalidationIndex += 1
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
        return ZhulongSessionEventRecord(
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

    private func decisionGateOpenedEvent(
        _ gate: ZhulongDecisionGate,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningDecisionGateOpened,
            occurredAt: gate.openedAt,
            summary: "规划运行已停在用户决策门",
            reference: .decisionGate(gate.id)
        )
    }

    private func decisionGateResolutionEvent(
        _ resolution: ZhulongDecisionGateResolution,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningDecisionGateResolved,
            occurredAt: resolution.resolvedAt,
            summary: "用户已处置规划决策门，必须修订简报后重新委托",
            reference: .decisionGate(resolution.gateID)
        )
    }

    private func planArtifactReadyEvent(
        _ artifact: ZhulongPlanArtifact,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .draftReady,
            occurredAt: artifact.createdAt,
            summary: "Provider 已返回可审查结构化计划产物",
            reference: .planArtifact(artifact.id)
        )
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

    private func decisionEvent(
        _ decision: ZhulongSessionEntry,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .sessionDecisionRecorded,
            occurredAt: decision.createdAt,
            summary: "已记录用户决定",
            reference: .sessionEntry(decision.id)
        )
    }

    private func planningBriefEvent(
        _ brief: ZhulongPlanningBrief,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningBriefPublished,
            occurredAt: brief.publishedAt,
            summary: "已发布规划简报 v\(brief.version)",
            reference: .planningBrief(brief.id)
        )
    }

    private func planningBriefReviewEvent(
        _ review: ZhulongPlanningBriefReview,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningBriefReviewed,
            occurredAt: review.reviewedAt,
            summary: "用户已审查规划简报",
            reference: .planningBrief(review.briefID)
        )
    }

    private func planningBriefInvalidationEvent(
        _ invalidation: ZhulongPlanningBriefInvalidation,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningBriefInvalidated,
            occurredAt: invalidation.invalidatedAt,
            summary: "来源更正已使规划简报失效",
            reference: .planningBrief(invalidation.briefID)
        )
    }

    private func planningDelegationEvent(
        _ delegation: ZhulongPlanningDelegation,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningDelegationGranted,
            occurredAt: delegation.grantedAt,
            summary: "已建立单次规划委托，不包含 Todo 写入",
            reference: .planningDelegation(delegation.id)
        )
    }

    private func planningDelegationConsumptionEvent(
        _ consumption: ZhulongPlanningDelegationConsumption,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningDelegationConsumed,
            occurredAt: consumption.consumedAt,
            summary: "单次规划委托已消费",
            reference: .planningDelegation(consumption.delegationID)
        )
    }

    private func planningDelegationInvalidationEvent(
        _ invalidation: ZhulongPlanningDelegationInvalidation,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        let summary = switch invalidation.reason {
        case .briefRevised: "简报修订已使旧规划委托失效"
        case .briefSourceCorrected: "来源更正已使规划委托失效"
        case .authorizationChanged: "授权变更已使旧规划委托失效"
        }
        return ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningDelegationInvalidated,
            occurredAt: invalidation.invalidatedAt,
            summary: summary,
            reference: .planningDelegation(invalidation.delegationID)
        )
    }

    private func planningRunInvalidationEvent(
        _ invalidation: ZhulongPlanningRunInvalidation,
        sequence: UInt64
    ) -> ZhulongSessionEventRecord {
        ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .planningRunInvalidated,
            occurredAt: invalidation.invalidatedAt,
            summary: invalidation.reason == .briefRevised
                ? "简报修订已使旧规划运行与草稿失效"
                : "来源更正已使规划运行与草稿失效",
            reference: .providerRun(invalidation.runID)
        )
    }

    private func currentReviewedBriefID() -> ZhulongPlanningBriefID? {
        guard let briefID = currentPlanningBriefID(),
              planningBriefReviews.contains(where: { $0.briefID == briefID })
        else { return nil }
        return briefID
    }

    private func currentPlanningBriefID() -> ZhulongPlanningBriefID? {
        guard let briefID = planningBriefs.last?.id,
              planningBriefInvalidations.contains(where: { $0.briefID == briefID }) == false
        else { return nil }
        return briefID
    }

    private func currentActiveDelegationID() -> ZhulongPlanningDelegationID? {
        guard let briefID = currentPlanningBriefID(),
              let delegation = planningDelegations.last(where: { $0.briefID == briefID }),
              planningDelegationConsumptions.contains(where: {
                  $0.delegationID == delegation.id
              }) == false,
              planningDelegationInvalidations.contains(where: {
                  $0.delegationID == delegation.id
              }) == false
        else { return nil }
        return delegation.id
    }

    private func currentDecisionGateID() -> ZhulongDecisionGateID? {
        guard phase == .decisionGate,
              let gate = decisionGates.last,
              decisionGateResolutions.contains(where: { $0.gateID == gate.id }) == false,
              currentPlanningBriefID() == gate.briefID,
              planningRunInvalidations.contains(where: { $0.runID == gate.runID }) == false
        else { return nil }
        return gate.id
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
            for event in events where event.occurredAt <= entry.createdAt {
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
                  providerSends.allSatisfy({ $0.status != .running })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .providerRunning:
            guard authorizations.isEmpty == false,
                  draftVersion == nil,
                  providerSends.last?.status == .running,
                  providerSends.dropLast().allSatisfy({ $0.status != .running })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .decisionGate:
            guard authorizations.isEmpty == false,
                  draftVersion == nil,
                  providerSends.last?.status == .succeeded,
                  providerSends.last?.response?.draftVersion == nil,
                  decisionGates.last?.runID == providerSends.last?.runID,
                  decisionGateResolutions.contains(where: {
                      $0.gateID == decisionGates.last?.id
                  }) == false,
                  providerSends.dropLast().allSatisfy({ $0.status != .running })
            else {
                throw ZhulongSessionRestorationError.invalidEventsForPhase
            }
        case .draftReview:
            guard authorizations.isEmpty == false,
                  let draftVersion,
                  draftVersion > 0,
                  providerSends.last?.status == .succeeded,
                  providerSends.last?.response?.draftVersion == draftVersion,
                  validDraftReviewProjection(draftVersion: draftVersion),
                  providerSends.dropLast().allSatisfy({ $0.status != .running })
            else {
                throw ZhulongSessionRestorationError.invalidDraftVersion
            }
        }
    }

    private func validDraftReviewProjection(draftVersion: Int) -> Bool {
        guard let send = providerSends.last,
              let response = send.response
        else { return false }
        switch send.purpose {
        case .conversation, .migratedLegacyPlanning:
            return true
        case .delegatedPlanning:
            guard let parsed = try? ZhulongPlanningOutputParser().parse(response.content),
                  case .planArtifact = parsed
            else { return false }
            return planArtifacts.last?.runID == send.runID &&
                planArtifacts.last?.version == draftVersion
        }
    }
}

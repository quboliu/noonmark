import Foundation

public enum ZhulongPlanningOutputError: Error, Equatable, Sendable {
    case emptyRequiredContent
    case invalidStageGraph
    case invalidStageDetail
    case incompleteDecisionExplanation
    case invalidDecisionGate
    case invalidJSON
    case unknownField
    case unsupportedKind
    case unboundPrecision
    case invalidPrecisionClaim
    case explanationOutsidePlanningContract
}

public enum ZhulongPlanningHorizon: String, Codable, Equatable, Sendable {
    case nearTerm
    case later
}

public enum ZhulongPlanningAuthorizationRequirement: String, Codable, Hashable, Sendable {
    case todoWrite
    case scopeExpansion
    case memoryWrite
    case externalAction
}

public enum ZhulongPlanningPrecisionKind: String, Codable, Equatable, Sendable {
    case targetDate
    case effortPoints
    case probability
}

public enum ZhulongPlanningPrecisionBasisSource: String, Codable, Equatable, Sendable {
    case userDecision
    case hardConstraint
    case localEvidence
}

public struct ZhulongPlanningPrecisionClaimDraft: Codable, Equatable, Sendable {
    public let kind: ZhulongPlanningPrecisionKind
    public let dateValue: String?
    public let numericValue: Double?
    public let basisSource: ZhulongPlanningPrecisionBasisSource
    public let basis: String
    public let basisValue: String
    public let dataScope: ZhulongDataScope?

    public init(
        kind: ZhulongPlanningPrecisionKind,
        dateValue: String?,
        numericValue: Double?,
        basisSource: ZhulongPlanningPrecisionBasisSource,
        basis: String,
        basisValue: String,
        dataScope: ZhulongDataScope?
    ) throws {
        let normalizedDate = try normalizedOptionalPlanningOutputText(dateValue)
        let normalizedBasis = try normalizedPlanningOutputText(basis)
        let normalizedBasisValue = try normalizedPlanningOutputText(basisValue)
        switch kind {
        case .targetDate:
            guard let normalizedDate,
                  numericValue == nil,
                  isValidGregorianDate(normalizedDate),
                  normalizedPlanningDate(normalizedBasisValue) == normalizedDate,
                  normalizedBasis.contains(normalizedBasisValue)
            else {
                throw ZhulongPlanningOutputError.invalidPrecisionClaim
            }
        case .effortPoints:
            guard normalizedDate == nil,
                  let numericValue,
                  numericValue.isFinite,
                  numericValue > 0,
                  normalizedPlanningNumber(normalizedBasisValue) == numericValue,
                  basisContainsExactValue(normalizedBasisValue, in: normalizedBasis),
                  basisSupportsEffortPoints(normalizedBasisValue, in: normalizedBasis)
            else {
                throw ZhulongPlanningOutputError.invalidPrecisionClaim
            }
        case .probability:
            guard normalizedDate == nil,
                  let numericValue,
                  numericValue.isFinite,
                  numericValue >= 0,
                  numericValue <= 1,
                  normalizedPlanningProbability(normalizedBasisValue) == numericValue,
                  basisContainsExactValue(normalizedBasisValue, in: normalizedBasis),
                  basisSupportsProbability(normalizedBasisValue, in: normalizedBasis)
            else {
                throw ZhulongPlanningOutputError.invalidPrecisionClaim
            }
        }
        guard (basisSource == .localEvidence) == (dataScope != nil) else {
            throw ZhulongPlanningOutputError.invalidPrecisionClaim
        }
        self.kind = kind
        self.dateValue = normalizedDate
        self.numericValue = numericValue
        self.basisSource = basisSource
        self.basis = normalizedBasis
        self.basisValue = normalizedBasisValue
        self.dataScope = dataScope
    }
}

public struct ZhulongDecisionGateID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongPlanArtifactID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongPlanStageDraft: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let objective: String
    public let horizon: ZhulongPlanningHorizon
    public let dependencyIDs: [String]
    public let deliverables: [String]
    public let triggerCondition: String?

    public init(
        id: String,
        title: String,
        objective: String,
        horizon: ZhulongPlanningHorizon,
        dependencyIDs: [String],
        deliverables: [String],
        triggerCondition: String?
    ) throws {
        let normalizedID = try normalizedPlanningOutputText(id)
        let normalizedTitle = try normalizedPlanningOutputText(title)
        let normalizedObjective = try normalizedPlanningOutputText(objective)
        let normalizedDependencies = try normalizedPlanningOutputList(dependencyIDs)
        let normalizedDeliverables = try normalizedPlanningOutputList(deliverables)
        let normalizedTrigger = try normalizedOptionalPlanningOutputText(triggerCondition)
        guard Set(normalizedDependencies).count == normalizedDependencies.count,
              normalizedDependencies.contains(normalizedID) == false
        else {
            throw ZhulongPlanningOutputError.invalidStageDetail
        }
        switch horizon {
        case .nearTerm:
            guard normalizedDeliverables.isEmpty == false, normalizedTrigger == nil else {
                throw ZhulongPlanningOutputError.invalidStageDetail
            }
        case .later:
            guard normalizedDeliverables.isEmpty, normalizedTrigger != nil else {
                throw ZhulongPlanningOutputError.invalidStageDetail
            }
        }
        self.id = normalizedID
        self.title = normalizedTitle
        self.objective = normalizedObjective
        self.horizon = horizon
        self.dependencyIDs = normalizedDependencies
        self.deliverables = normalizedDeliverables
        self.triggerCondition = normalizedTrigger
    }
}

public struct ZhulongDecisionAlternativeDraft: Codable, Equatable, Sendable {
    public let title: String
    public let tradeoffs: [String]

    public init(title: String, tradeoffs: [String]) throws {
        self.title = try normalizedPlanningOutputText(title)
        self.tradeoffs = try normalizedPlanningOutputList(tradeoffs)
        guard self.tradeoffs.isEmpty == false else {
            throw ZhulongPlanningOutputError.incompleteDecisionExplanation
        }
    }
}

public struct ZhulongDecisionExplanationDraft: Codable, Equatable, Sendable {
    public let subject: String
    public let userDecisions: [String]
    public let assumptions: [String]
    public let dataScopes: Set<ZhulongDataScope>
    public let evidence: [String]
    public let constraints: [String]
    public let alternatives: [ZhulongDecisionAlternativeDraft]
    public let counterexamples: [String]
    public let rationale: String
    public let uncertainties: [String]
    public let expectedImpacts: [String]
    public let requiredAuthorizations: Set<ZhulongPlanningAuthorizationRequirement>

    public init(
        subject: String,
        userDecisions: [String],
        assumptions: [String],
        dataScopes: Set<ZhulongDataScope>,
        evidence: [String],
        constraints: [String],
        alternatives: [ZhulongDecisionAlternativeDraft],
        counterexamples: [String],
        rationale: String,
        uncertainties: [String],
        expectedImpacts: [String],
        requiredAuthorizations: Set<ZhulongPlanningAuthorizationRequirement>
    ) throws {
        self.subject = try normalizedPlanningOutputText(subject)
        self.userDecisions = try normalizedPlanningOutputList(userDecisions)
        self.assumptions = try normalizedPlanningOutputList(assumptions)
        self.dataScopes = dataScopes
        self.evidence = try normalizedPlanningOutputList(evidence)
        self.constraints = try normalizedPlanningOutputList(constraints)
        self.alternatives = alternatives
        self.counterexamples = try normalizedPlanningOutputList(counterexamples)
        self.rationale = try normalizedPlanningOutputText(rationale)
        self.uncertainties = try normalizedPlanningOutputList(uncertainties)
        self.expectedImpacts = try normalizedPlanningOutputList(expectedImpacts)
        self.requiredAuthorizations = requiredAuthorizations
        guard dataScopes.isEmpty == false,
              self.evidence.isEmpty == false,
              self.constraints.isEmpty == false,
              alternatives.count >= 2,
              Set(alternatives.map(\.title)).count == alternatives.count,
              self.counterexamples.isEmpty == false,
              self.uncertainties.isEmpty == false,
              self.expectedImpacts.isEmpty == false,
              requiredAuthorizations.isEmpty == false
        else {
            throw ZhulongPlanningOutputError.incompleteDecisionExplanation
        }
    }
}

public struct ZhulongPlanArtifactProposal: Codable, Equatable, Sendable {
    public let summary: String
    public let stages: [ZhulongPlanStageDraft]
    public let decisionExplanations: [ZhulongDecisionExplanationDraft]
    public let precisionClaims: [ZhulongPlanningPrecisionClaimDraft]

    public init(
        summary: String,
        stages: [ZhulongPlanStageDraft],
        decisionExplanations: [ZhulongDecisionExplanationDraft],
        precisionClaims: [ZhulongPlanningPrecisionClaimDraft]
    ) throws {
        self.summary = try normalizedPlanningOutputText(summary)
        self.stages = stages
        self.decisionExplanations = decisionExplanations
        self.precisionClaims = precisionClaims
        guard stages.isEmpty == false,
              stages.contains(where: { $0.horizon == .nearTerm }),
              decisionExplanations.isEmpty == false,
              Self.hasValidGraph(stages)
        else {
            throw ZhulongPlanningOutputError.invalidStageGraph
        }
        try rejectUnboundPrecision(in: assertionTexts)
        let provenance = precisionProvenanceTexts
        let provenanceSet = Set(provenance)
        guard precisionClaims.allSatisfy({ provenanceSet.contains($0.basis) }) else {
            throw ZhulongPlanningOutputError.unboundPrecision
        }
        guard provenance.allSatisfy({ value in
            hasCompletePrecisionCoverage(in: value, claims: precisionClaims)
        }) else {
            throw ZhulongPlanningOutputError.unboundPrecision
        }
    }

    private var assertionTexts: [String] {
        var values = [summary]
        for stage in stages {
            values.append(contentsOf: [stage.id, stage.title, stage.objective])
            values.append(contentsOf: stage.dependencyIDs)
            values.append(contentsOf: stage.deliverables)
            if let triggerCondition = stage.triggerCondition {
                values.append(triggerCondition)
            }
        }
        for explanation in decisionExplanations {
            values.append(contentsOf: [explanation.subject, explanation.rationale])
            for alternative in explanation.alternatives {
                values.append(alternative.title)
                values.append(contentsOf: alternative.tradeoffs)
            }
            values.append(contentsOf: explanation.counterexamples)
            values.append(contentsOf: explanation.uncertainties)
            values.append(contentsOf: explanation.expectedImpacts)
        }
        return values
    }

    private var precisionProvenanceTexts: [String] {
        decisionExplanations.flatMap { explanation in
            explanation.userDecisions + explanation.assumptions + explanation.evidence +
                explanation.constraints
        }
    }

    private static func hasValidGraph(_ stages: [ZhulongPlanStageDraft]) -> Bool {
        let stageIDs = stages.map(\.id)
        guard Set(stageIDs).count == stageIDs.count else { return false }
        let knownIDs = Set(stageIDs)
        guard stages.allSatisfy({ Set($0.dependencyIDs).isSubset(of: knownIDs) }) else {
            return false
        }
        let horizonByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0.horizon) })
        guard stages.allSatisfy({ stage in
            stage.horizon != .nearTerm || stage.dependencyIDs.allSatisfy {
                horizonByID[$0] == .nearTerm
            }
        }) else {
            return false
        }
        var pendingDependencies = Dictionary(uniqueKeysWithValues: stages.map {
            ($0.id, Set($0.dependencyIDs))
        })
        var resolved: Set<String> = []
        while let next = stageIDs.first(where: {
            resolved.contains($0) == false &&
                (pendingDependencies[$0] ?? []).isSubset(of: resolved)
        }) {
            resolved.insert(next)
            pendingDependencies.removeValue(forKey: next)
        }
        return resolved.count == stages.count
    }

    func isBound(
        to brief: ZhulongPlanningBrief,
        contract: ZhulongPlanningRunContract,
        payload: ZhulongProviderPayload
    ) -> Bool {
        let briefDecisions = Set(brief.userDecisions)
        let briefAssumptions = Set(brief.assumptions)
        let briefConstraints = Set(brief.hardConstraints)
        return decisionExplanations.allSatisfy { explanation in
            explanation.dataScopes.isSubset(of: contract.dataScopes) &&
                Set(explanation.userDecisions).isSubset(of: briefDecisions) &&
                Set(explanation.assumptions).isSubset(of: briefAssumptions) &&
                Set(explanation.constraints).isSubset(of: briefConstraints)
        } && precisionClaims.allSatisfy { claim in
            precisionClaimIsBound(claim, to: brief, contract: contract, payload: payload)
        }
    }

    private func precisionClaimIsBound(
        _ claim: ZhulongPlanningPrecisionClaimDraft,
        to brief: ZhulongPlanningBrief,
        contract: ZhulongPlanningRunContract,
        payload: ZhulongProviderPayload
    ) -> Bool {
        switch claim.basisSource {
        case .userDecision:
            return brief.userDecisions.contains(claim.basis)
        case .hardConstraint:
            return brief.hardConstraints.contains(claim.basis)
        case .localEvidence:
            guard let scope = claim.dataScope,
                  contract.dataScopes.contains(scope),
                  let localContent = payload.scopeContent[scope]
            else { return false }
            return localContent == claim.basis
        }
    }
}

public struct ZhulongDecisionGateOptionDraft: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let impact: String

    public init(id: String, title: String, impact: String) throws {
        self.id = try normalizedPlanningOutputText(id)
        self.title = try normalizedPlanningOutputText(title)
        self.impact = try normalizedPlanningOutputText(impact)
    }
}

public struct ZhulongDecisionGateDraft: Codable, Equatable, Sendable {
    public let summary: String
    public let prompt: String
    public let reason: String
    public let evidenceGaps: [String]
    public let options: [ZhulongDecisionGateOptionDraft]

    public init(
        summary: String,
        prompt: String,
        reason: String,
        evidenceGaps: [String],
        options: [ZhulongDecisionGateOptionDraft]
    ) throws {
        self.summary = try normalizedPlanningOutputText(summary)
        self.prompt = try normalizedPlanningOutputText(prompt)
        self.reason = try normalizedPlanningOutputText(reason)
        self.evidenceGaps = try normalizedPlanningOutputList(evidenceGaps)
        self.options = options
        guard self.evidenceGaps.isEmpty == false,
              options.count >= 2,
              Set(options.map(\.id)).count == options.count,
              Set(options.map(\.title)).count == options.count
        else {
            throw ZhulongPlanningOutputError.invalidDecisionGate
        }
        try rejectUnboundPrecision(
            in: [self.summary, self.prompt, self.reason] + self.evidenceGaps +
                options.flatMap { [$0.id, $0.title, $0.impact] }
        )
    }
}

public enum ZhulongPlanningOutputDraft: Equatable, Sendable {
    case decisionGate(ZhulongDecisionGateDraft)
    case planArtifact(ZhulongPlanArtifactProposal)
}

public struct ZhulongDecisionGate: Codable, Equatable, Sendable {
    public let id: ZhulongDecisionGateID
    public let sessionID: ZhulongSessionID
    public let runID: ZhulongProviderRunID
    public let briefID: ZhulongPlanningBriefID
    public let briefVersion: Int
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let contextVersion: String
    public let openedAt: Date
    public let draft: ZhulongDecisionGateDraft
}

public struct ZhulongDecisionGateResolution: Codable, Equatable, Sendable {
    public let gateID: ZhulongDecisionGateID
    public let selectedOptionID: String
    public let decisionEntryID: ZhulongSessionEntryID
    public let resolvedAt: Date
}

public struct ZhulongPlanArtifact: Codable, Equatable, Sendable {
    public let id: ZhulongPlanArtifactID
    public let sessionID: ZhulongSessionID
    public let runID: ZhulongProviderRunID
    public let briefID: ZhulongPlanningBriefID
    public let briefVersion: Int
    public let providerIdentity: ZhulongProviderConfigurationIdentity
    public let contextVersion: String
    public let version: Int
    public let createdAt: Date
    public let proposal: ZhulongPlanArtifactProposal
}

public struct ZhulongPlanningOutputParser: Sendable {
    public init() {}

    public func parse(_ content: String) throws -> ZhulongPlanningOutputDraft {
        guard let data = content.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let kind = dictionary["kind"] as? String
        else {
            throw ZhulongPlanningOutputError.invalidJSON
        }
        switch kind {
        case "decisionGate":
            try validateGateShape(dictionary)
            let raw = try decode(RawDecisionGate.self, from: data)
            return .decisionGate(try raw.materialize())
        case "planArtifact":
            try validatePlanShape(dictionary)
            let raw = try decode(RawPlanArtifact.self, from: data)
            return .planArtifact(try raw.materialize())
        default:
            throw ZhulongPlanningOutputError.unsupportedKind
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ZhulongPlanningOutputError.invalidJSON
        }
    }

    private func validateGateShape(_ object: [String: Any]) throws {
        try validateKeys(
            object,
            allowed: ["kind", "summary", "prompt", "reason", "evidenceGaps", "options"]
        )
        try dictionaries(in: object["options"]).forEach {
            try validateKeys($0, allowed: ["id", "title", "impact"])
        }
    }

    private func validatePlanShape(_ object: [String: Any]) throws {
        try validateKeys(
            object,
            allowed: ["kind", "summary", "stages", "decisionExplanations", "precisionClaims"]
        )
        try dictionaries(in: object["stages"]).forEach {
            try validateKeys(
                $0,
                allowed: [
                    "id", "title", "objective", "horizon", "dependencyIDs",
                    "deliverables", "triggerCondition"
                ]
            )
        }
        try dictionaries(in: object["decisionExplanations"]).forEach { explanation in
            try validateKeys(
                explanation,
                allowed: [
                    "subject", "userDecisions", "assumptions", "dataScopes", "evidence",
                    "constraints", "alternatives", "counterexamples", "rationale",
                    "uncertainties", "expectedImpacts", "requiredAuthorizations"
                ]
            )
            try dictionaries(in: explanation["alternatives"]).forEach {
                try validateKeys($0, allowed: ["title", "tradeoffs"])
            }
        }
        try dictionaries(in: object["precisionClaims"]).forEach {
            try validateKeys(
                $0,
                allowed: [
                    "kind", "dateValue", "numericValue", "basisSource", "basis", "basisValue",
                    "dataScope"
                ]
            )
        }
    }

    private func validateKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw ZhulongPlanningOutputError.unknownField
        }
    }

    private func dictionaries(in value: Any?) throws -> [[String: Any]] {
        guard let dictionaries = value as? [[String: Any]] else {
            throw ZhulongPlanningOutputError.invalidJSON
        }
        return dictionaries
    }
}

public extension ZhulongSession {
    var currentDecisionGate: ZhulongDecisionGate? {
        guard phase == .decisionGate,
              let gate = decisionGates.last,
              decisionGateResolutions.contains(where: { $0.gateID == gate.id }) == false,
              currentPlanningBrief?.id == gate.briefID,
              currentPlanningBrief?.version == gate.briefVersion,
              planningRunInvalidations.contains(where: { $0.runID == gate.runID }) == false
        else { return nil }
        return gate
    }

    var effectivePlanArtifact: ZhulongPlanArtifact? {
        guard let effectiveDraftVersion,
              let draft = planArtifacts.last,
              draft.version == effectiveDraftVersion,
              currentPlanningBrief?.id == draft.briefID,
              currentPlanningBrief?.version == draft.briefVersion,
              planningRunInvalidations.contains(where: { $0.runID == draft.runID }) == false
        else { return nil }
        return draft
    }

    var currentBriefRequiresDecisionGateRevision: Bool {
        latestDecisionGateResolutionRequiringBriefRevision != nil
    }

    var latestDecisionGateResolutionRequiringBriefRevision: ZhulongDecisionGateResolution? {
        guard let gate = decisionGates.last,
              let resolution = decisionGateResolutions.last(where: { $0.gateID == gate.id })
        else { return nil }
        guard let brief = currentPlanningBrief,
              let decision = effectiveContent(for: resolution.decisionEntryID)
        else { return resolution }
        let incorporatesResolution = brief.id != gate.briefID &&
            brief.sourceEntryIDs.contains(resolution.decisionEntryID) &&
            brief.userDecisions.contains(decision)
        if incorporatesResolution {
            return nil
        }
        return resolution
    }
}

private struct RawDecisionGate: Decodable {
    let summary: String
    let prompt: String
    let reason: String
    let evidenceGaps: [String]
    let options: [RawDecisionGateOption]

    func materialize() throws -> ZhulongDecisionGateDraft {
        try ZhulongDecisionGateDraft(
            summary: summary,
            prompt: prompt,
            reason: reason,
            evidenceGaps: evidenceGaps,
            options: try options.map { try $0.materialize() }
        )
    }
}

private struct RawDecisionGateOption: Decodable {
    let id: String
    let title: String
    let impact: String

    func materialize() throws -> ZhulongDecisionGateOptionDraft {
        try ZhulongDecisionGateOptionDraft(id: id, title: title, impact: impact)
    }
}

private struct RawPlanArtifact: Decodable {
    let summary: String
    let stages: [RawPlanStage]
    let decisionExplanations: [RawDecisionExplanation]
    let precisionClaims: [RawPrecisionClaim]

    func materialize() throws -> ZhulongPlanArtifactProposal {
        try ZhulongPlanArtifactProposal(
            summary: summary,
            stages: try stages.map { try $0.materialize() },
            decisionExplanations: try decisionExplanations.map { try $0.materialize() },
            precisionClaims: try precisionClaims.map { try $0.materialize() }
        )
    }
}

private struct RawPrecisionClaim: Decodable {
    let kind: ZhulongPlanningPrecisionKind
    let dateValue: String?
    let numericValue: Double?
    let basisSource: ZhulongPlanningPrecisionBasisSource
    let basis: String
    let basisValue: String
    let dataScope: ZhulongDataScope?

    func materialize() throws -> ZhulongPlanningPrecisionClaimDraft {
        try ZhulongPlanningPrecisionClaimDraft(
            kind: kind,
            dateValue: dateValue,
            numericValue: numericValue,
            basisSource: basisSource,
            basis: basis,
            basisValue: basisValue,
            dataScope: dataScope
        )
    }
}

private struct RawPlanStage: Decodable {
    let id: String
    let title: String
    let objective: String
    let horizon: ZhulongPlanningHorizon
    let dependencyIDs: [String]
    let deliverables: [String]
    let triggerCondition: String?

    func materialize() throws -> ZhulongPlanStageDraft {
        try ZhulongPlanStageDraft(
            id: id,
            title: title,
            objective: objective,
            horizon: horizon,
            dependencyIDs: dependencyIDs,
            deliverables: deliverables,
            triggerCondition: triggerCondition
        )
    }
}

private struct RawDecisionExplanation: Decodable {
    let subject: String
    let userDecisions: [String]
    let assumptions: [String]
    let dataScopes: Set<ZhulongDataScope>
    let evidence: [String]
    let constraints: [String]
    let alternatives: [RawDecisionAlternative]
    let counterexamples: [String]
    let rationale: String
    let uncertainties: [String]
    let expectedImpacts: [String]
    let requiredAuthorizations: Set<ZhulongPlanningAuthorizationRequirement>

    func materialize() throws -> ZhulongDecisionExplanationDraft {
        try ZhulongDecisionExplanationDraft(
            subject: subject,
            userDecisions: userDecisions,
            assumptions: assumptions,
            dataScopes: dataScopes,
            evidence: evidence,
            constraints: constraints,
            alternatives: try alternatives.map { try $0.materialize() },
            counterexamples: counterexamples,
            rationale: rationale,
            uncertainties: uncertainties,
            expectedImpacts: expectedImpacts,
            requiredAuthorizations: requiredAuthorizations
        )
    }
}

private struct RawDecisionAlternative: Decodable {
    let title: String
    let tradeoffs: [String]

    func materialize() throws -> ZhulongDecisionAlternativeDraft {
        try ZhulongDecisionAlternativeDraft(title: title, tradeoffs: tradeoffs)
    }
}

private func normalizedPlanningOutputText(_ value: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else {
        throw ZhulongPlanningOutputError.emptyRequiredContent
    }
    return normalized
}

private func normalizedOptionalPlanningOutputText(_ value: String?) throws -> String? {
    guard let value else { return nil }
    return try normalizedPlanningOutputText(value)
}

private func normalizedPlanningOutputList(_ values: [String]) throws -> [String] {
    try values.map(normalizedPlanningOutputText)
}

private func rejectUnboundPrecision(in values: [String]) throws {
    guard values.allSatisfy({ containsPlanningPrecision($0) == false }) else {
        throw ZhulongPlanningOutputError.unboundPrecision
    }
}

private func containsPlanningPrecision(_ value: String) -> Bool {
    if value.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
        return true
    }
    let englishNumber = "(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|" +
        "eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|" +
        "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|" +
        "million|billion|trillion)"
    let englishNumberExpression = "\(englishNumber)(?:[\\s-]+(?:and[\\s-]+)?\(englishNumber))*"
    let chineseNumber = "[零〇一二两三四五六七八九十百千万亿点]+"
    let patterns = [
        "\\b\(englishNumberExpression)\\s+(?:story\\s+points?|points?|percent|percentage)\\b",
        "\\b(?:probability|likelihood|chance|success\\s+rate)(?:\\s+(?:of|is|at))?\\s+" +
            "\(englishNumberExpression)\\b",
        "(?:百分之|概率(?:为|是)?|成功率)\\s*\(chineseNumber)",
        "\(chineseNumber)\\s*(?:个)?(?:故事点|点工作量)"
    ]
    return patterns.contains { pattern in
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private func hasCompletePrecisionCoverage(
    in value: String,
    claims: [ZhulongPlanningPrecisionClaimDraft]
) -> Bool {
    guard containsPlanningPrecision(value) else { return true }
    let fullRange = NSRange(value.startIndex ..< value.endIndex, in: value)
    let digitPattern = try? NSRegularExpression(pattern: #"\p{Nd}+"#)
    let digitRanges = digitPattern?.matches(in: value, range: fullRange).map(\.range) ?? []
    guard digitRanges.isEmpty == false else { return false }

    var claimedRanges: [NSRange] = []
    let matchingClaims = claims
        .filter { $0.basis == value }
        .sorted { $0.basisValue.utf16.count > $1.basisValue.utf16.count }
    for claim in matchingClaims {
        let availableRange = precisionValueRanges(for: claim, in: value)
            .first { candidate in
                claimedRanges.allSatisfy { NSIntersectionRange($0, candidate).length == 0 }
            }
        guard let availableRange else { return false }
        claimedRanges.append(availableRange)
    }

    return digitRanges.allSatisfy { digitRange in
        claimedRanges.contains { claimRange in
            NSLocationInRange(digitRange.location, claimRange) &&
                NSMaxRange(digitRange) <= NSMaxRange(claimRange)
        }
    }
}

private func isValidGregorianDate(_ value: String) -> Bool {
    let components = value.split(separator: "-", omittingEmptySubsequences: false)
    guard components.count == 3,
          components[0].count == 4,
          components[1].count == 2,
          components[2].count == 2,
          let year = Int(components[0]),
          let month = Int(components[1]),
          let day = Int(components[2])
    else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
        return false
    }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    return resolved.year == year && resolved.month == month && resolved.day == day
}

private func normalizedPlanningDate(_ value: String) -> String? {
    if isValidGregorianDate(value) {
        return value
    }
    let separated = value
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: "年", with: "-")
        .replacingOccurrences(of: "月", with: "-")
        .replacingOccurrences(of: "日", with: "")
    let components = separated.split(separator: "-", omittingEmptySubsequences: false)
    let numericComponents = components.compactMap { Int($0) }
    if components.count == 3, numericComponents.count == 3 {
        let year = numericComponents[0]
        let month = numericComponents[1]
        let day = numericComponents[2]
        let candidate = String(format: "%04d-%02d-%02d", year, month, day)
        if isValidGregorianDate(candidate) {
            return candidate
        }
    }
    for format in ["MMMM d, yyyy", "MMM d, yyyy"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        if let date = formatter.date(from: value) {
            let output = DateFormatter()
            output.locale = Locale(identifier: "en_US_POSIX")
            output.calendar = Calendar(identifier: .gregorian)
            output.timeZone = TimeZone(secondsFromGMT: 0)
            output.dateFormat = "yyyy-MM-dd"
            return output.string(from: date)
        }
    }
    return nil
}

private func normalizedPlanningNumber(_ value: String) -> Double? {
    guard let number = Double(value), number.isFinite else { return nil }
    return number
}

private func normalizedPlanningProbability(_ value: String) -> Double? {
    let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let number = if normalized.hasSuffix("%") {
        Double(normalized.dropLast()).map { $0 / 100 }
    } else if normalized.hasSuffix("percent") {
        Double(normalized.dropLast("percent".count).trimmingCharacters(in: .whitespaces))
            .map { $0 / 100 }
    } else {
        Double(normalized)
    }
    guard let number, number.isFinite, number >= 0, number <= 1 else { return nil }
    return number
}

private func basisContainsExactValue(_ value: String, in basis: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: value)
    let pattern = "(^|[^0-9.])\(escaped)([^0-9.]|$)"
    return basis.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

private func basisSupportsEffortPoints(_ value: String, in basis: String) -> Bool {
    effortPointValueRanges(value, in: basis).isEmpty == false
}

private func effortPointValueRanges(_ value: String, in basis: String) -> [NSRange] {
    let escaped = boundedPlanningValuePattern(value)
    let connector = "(?:\\s+(?:is|of|at|equals?|approximately|about))?\\s*[:=：]?\\s*"
    let patterns = [
        "\\b\(escaped)\\s*(?:story\\s+points?|effort\\s+points?|points?)\\b",
        "\\b(?:effort|workload)\(connector)\(escaped)(?:\\s*(?:story\\s+points?|points?))?\\b",
        "(?:工作量|投入点数|故事点)(?:为|是|约为|约|等于|上限为|上限是)?\\s*[:=：]?\\s*" +
            "\(escaped)(?:\\s*(?:点|个故事点))?",
        "\(escaped)\\s*(?:个)?(?:故事点|点工作量)"
    ]
    return contextualPlanningValueRanges(value, in: basis, patterns: patterns)
}

private func basisSupportsProbability(_ value: String, in basis: String) -> Bool {
    probabilityValueRanges(value, in: basis).isEmpty == false
}

private func probabilityValueRanges(_ value: String, in basis: String) -> [NSRange] {
    let escaped = boundedPlanningValuePattern(value)
    let englishSemantic = "\\b(?:probability|likelihood|chance|success\\s+rate|completion\\s+rate)\\b"
    let chineseSemantic = "(?:概率|成功率|完成率|置信度)"
    let englishConnector = "(?:\\s+(?:of|is|at|equals?|approximately|about))?\\s*[:=：]?\\s*"
    let chineseConnector = "(?:为|是|约为|约|等于)?\\s*[:=：]?\\s*"
    let patterns = [
        "\(englishSemantic)\(englishConnector)\(escaped)",
        "\(chineseSemantic)\(chineseConnector)\(escaped)",
        "\(escaped)\(englishConnector)\(englishSemantic)",
        "\(escaped)\(chineseConnector)\(chineseSemantic)(?![\\p{L}\\p{N}_])"
    ]
    return contextualPlanningValueRanges(value, in: basis, patterns: patterns)
}

private func precisionValueRanges(
    for claim: ZhulongPlanningPrecisionClaimDraft,
    in basis: String
) -> [NSRange] {
    switch claim.kind {
    case .targetDate:
        exactPlanningValueRanges(claim.basisValue, in: basis)
    case .effortPoints:
        effortPointValueRanges(claim.basisValue, in: basis)
    case .probability:
        probabilityValueRanges(claim.basisValue, in: basis)
    }
}

private func contextualPlanningValueRanges(
    _ value: String,
    in basis: String,
    patterns: [String]
) -> [NSRange] {
    let fullRange = NSRange(basis.startIndex ..< basis.endIndex, in: basis)
    let contextRanges = patterns.flatMap { pattern -> [NSRange] in
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        return expression.matches(in: basis, range: fullRange).map(\.range)
    }
    return exactPlanningValueRanges(value, in: basis).filter { valueRange in
        contextRanges.contains { contextRange in
            NSLocationInRange(valueRange.location, contextRange) &&
                NSMaxRange(valueRange) <= NSMaxRange(contextRange)
        }
    }
}

private func exactPlanningValueRanges(_ value: String, in basis: String) -> [NSRange] {
    let fullRange = NSRange(basis.startIndex ..< basis.endIndex, in: basis)
    guard let expression = try? NSRegularExpression(
        pattern: boundedPlanningValuePattern(value),
        options: .caseInsensitive
    ) else { return [] }
    return expression.matches(in: basis, range: fullRange).map(\.range)
}

private func boundedPlanningValuePattern(_ value: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: value)
    return "(?<![0-9.])\(escaped)(?![0-9.])"
}

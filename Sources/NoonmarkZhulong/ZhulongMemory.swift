import Foundation

public struct ZhulongMemoryID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongMemoryCandidateID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongMemoryConflictID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ZhulongMemorySuppressionRuleID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ZhulongMemoryEvidenceReference: Codable, Hashable, Sendable {
    case sessionEntry(ZhulongSessionEntryID)
    case dailyClose(ZhulongDailyCloseID)
    case causeResolution(ZhulongUnfinishedCauseResolutionID)
    case todoReceipt(ZhulongTodoApplyReceiptID)
}

public enum ZhulongMemoryCandidateSource: Codable, Equatable, Sendable {
    case userStatement
    case zhulongInference
}

public struct ZhulongMemoryVersionReference: Codable, Hashable, Sendable {
    public let memoryID: ZhulongMemoryID
    public let version: Int

    public init(memoryID: ZhulongMemoryID, version: Int) {
        self.memoryID = memoryID
        self.version = version
    }
}

public struct ZhulongMemoryCandidate: Codable, Equatable, Sendable {
    public let id: ZhulongMemoryCandidateID
    public let topicKey: String
    public let content: String
    public let source: ZhulongMemoryCandidateSource
    public let evidenceWindowStart: Date
    public let evidenceWindowEnd: Date
    public let evidenceReferences: [ZhulongMemoryEvidenceReference]
    public let confidence: Double
    public let counterexamples: [String]
    public let conflictsWith: [ZhulongMemoryVersionReference]
    public let createdAt: Date

    public init(
        id: ZhulongMemoryCandidateID = ZhulongMemoryCandidateID(),
        topicKey: String,
        content: String,
        source: ZhulongMemoryCandidateSource,
        evidenceWindowStart: Date,
        evidenceWindowEnd: Date,
        evidenceReferences: [ZhulongMemoryEvidenceReference],
        confidence: Double,
        counterexamples: [String],
        conflictsWith: [ZhulongMemoryVersionReference] = [],
        createdAt: Date = Date()
    ) throws {
        let normalizedTopic = topicKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCounterexamples = counterexamples.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedTopic.isEmpty == false,
              normalizedContent.isEmpty == false,
              evidenceWindowStart.timeIntervalSinceReferenceDate.isFinite,
              evidenceWindowEnd.timeIntervalSinceReferenceDate.isFinite,
              evidenceWindowStart <= evidenceWindowEnd,
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              createdAt >= evidenceWindowEnd,
              evidenceReferences.isEmpty == false,
              confidence.isFinite,
              confidence >= 0,
              confidence <= 1,
              normalizedCounterexamples.isEmpty == false,
              normalizedCounterexamples.allSatisfy({ $0.isEmpty == false }),
              Set(evidenceReferences).count == evidenceReferences.count,
              Set(conflictsWith).count == conflictsWith.count
        else {
            throw ZhulongMemoryError.invalidCandidate
        }
        self.id = id
        self.topicKey = normalizedTopic
        self.content = normalizedContent
        self.source = source
        self.evidenceWindowStart = evidenceWindowStart
        self.evidenceWindowEnd = evidenceWindowEnd
        self.evidenceReferences = evidenceReferences
        self.confidence = confidence
        self.counterexamples = normalizedCounterexamples
        self.conflictsWith = conflictsWith
        self.createdAt = createdAt
    }
}

public enum ZhulongMemoryVersionStatus: String, Codable, Equatable, Sendable {
    case active
    case superseded
    case disabled
}

public struct ZhulongConfirmedMemoryVersion: Codable, Equatable, Sendable {
    public let memoryID: ZhulongMemoryID
    public let version: Int
    public let topicKey: String
    public let content: String
    public let source: ZhulongMemoryCandidateSource
    public let sourceCandidateID: ZhulongMemoryCandidateID
    public let effectiveAt: Date
    public internal(set) var status: ZhulongMemoryVersionStatus

    public var reference: ZhulongMemoryVersionReference {
        ZhulongMemoryVersionReference(memoryID: memoryID, version: version)
    }
}

public enum ZhulongMemoryCandidateDecision: Codable, Equatable, Sendable {
    case confirmed(memory: ZhulongMemoryVersionReference, decidedAt: Date)
    case rejected(decidedAt: Date)
}

public struct ZhulongMemoryConflict: Codable, Equatable, Sendable {
    public let id: ZhulongMemoryConflictID
    public let candidateID: ZhulongMemoryCandidateID
    public let existingMemory: ZhulongMemoryVersionReference
    public let openedAt: Date
    public internal(set) var resolution: ZhulongMemoryConflictResolution?
}

public enum ZhulongMemoryConflictChoice: Codable, Equatable, Sendable {
    case keepExisting
    case acceptCandidate
    case merge(content: String)
}

public struct ZhulongMemoryConflictResolution: Codable, Equatable, Sendable {
    public let choice: ZhulongMemoryConflictChoice
    public let resultingMemory: ZhulongMemoryVersionReference?
    public let resolvedAt: Date
}

public struct ZhulongMemorySuppressionRule: Codable, Equatable, Sendable {
    public let id: ZhulongMemorySuppressionRuleID
    public let topicKey: String
    public let createdAt: Date
}

public enum ZhulongMemoryError: Error, Equatable, Sendable {
    case disabled
    case invalidCandidate
    case suppressedTopic
    case candidateAlreadyDecided
    case conflictRequired
    case invalidConflict
    case conflictAlreadyResolved
    case memoryNotFound
    case invalidTime
    case invalidLedger
}

public struct ZhulongMemoryLedger: Codable, Equatable, Sendable {
    public private(set) var isEnabled: Bool
    public private(set) var candidates: [ZhulongMemoryCandidate]
    public private(set) var candidateDecisions: [ZhulongMemoryCandidateID: ZhulongMemoryCandidateDecision]
    public private(set) var memories: [ZhulongConfirmedMemoryVersion]
    public private(set) var conflicts: [ZhulongMemoryConflict]
    public private(set) var suppressionRules: [ZhulongMemorySuppressionRule]

    public init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
        candidates = []
        candidateDecisions = [:]
        memories = []
        conflicts = []
        suppressionRules = []
    }

    public var usableMemories: [ZhulongConfirmedMemoryVersion] {
        guard isEnabled else { return [] }
        return memories.filter { memory in
            memory.status == .active && conflicts.contains(where: {
                $0.existingMemory == memory.reference && $0.resolution == nil
            }) == false
        }
    }

    public mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    public mutating func propose(_ candidate: ZhulongMemoryCandidate) throws {
        guard isEnabled else { throw ZhulongMemoryError.disabled }
        guard candidate.source != .zhulongInference || suppressionRules.contains(where: {
            $0.topicKey == candidate.topicKey
        }) == false else {
            throw ZhulongMemoryError.suppressedTopic
        }
        let activeForTopic = memories.filter {
            $0.topicKey == candidate.topicKey && $0.status == .active
        }
        guard candidates.contains(where: { $0.id == candidate.id }) == false,
              Set(candidate.conflictsWith) == Set(activeForTopic.map(\.reference)),
              candidate.conflictsWith.allSatisfy({ reference in
                  memories.contains {
                      $0.reference == reference &&
                          $0.status == .active &&
                          $0.topicKey == candidate.topicKey
                  } && conflicts.contains {
                      $0.existingMemory == reference && $0.resolution == nil
                  } == false
              })
        else {
            throw ZhulongMemoryError.invalidCandidate
        }
        candidates.append(candidate)
        for reference in candidate.conflictsWith {
            conflicts.append(ZhulongMemoryConflict(
                id: ZhulongMemoryConflictID(),
                candidateID: candidate.id,
                existingMemory: reference,
                openedAt: candidate.createdAt,
                resolution: nil
            ))
        }
    }

    @discardableResult
    public mutating func confirmCandidate(
        _ candidateID: ZhulongMemoryCandidateID,
        now: Date = Date()
    ) throws -> ZhulongConfirmedMemoryVersion {
        guard isEnabled else { throw ZhulongMemoryError.disabled }
        guard candidateDecisions[candidateID] == nil else {
            throw ZhulongMemoryError.candidateAlreadyDecided
        }
        guard let candidate = candidates.first(where: { $0.id == candidateID }) else {
            throw ZhulongMemoryError.invalidCandidate
        }
        guard conflicts.contains(where: {
            $0.candidateID == candidateID && $0.resolution == nil
        }) == false else {
            throw ZhulongMemoryError.conflictRequired
        }
        try validateDecisionTime(now, after: candidate.createdAt)
        let memory = ZhulongConfirmedMemoryVersion(
            memoryID: ZhulongMemoryID(),
            version: 1,
            topicKey: candidate.topicKey,
            content: candidate.content,
            source: candidate.source,
            sourceCandidateID: candidate.id,
            effectiveAt: now,
            status: .active
        )
        memories.append(memory)
        candidateDecisions[candidate.id] = .confirmed(memory: memory.reference, decidedAt: now)
        return memory
    }

    public mutating func rejectCandidate(
        _ candidateID: ZhulongMemoryCandidateID,
        now: Date = Date()
    ) throws {
        guard isEnabled else { throw ZhulongMemoryError.disabled }
        guard candidateDecisions[candidateID] == nil,
              let candidate = candidates.first(where: { $0.id == candidateID })
        else {
            throw ZhulongMemoryError.candidateAlreadyDecided
        }
        try validateDecisionTime(now, after: candidate.createdAt)
        candidateDecisions[candidateID] = .rejected(decidedAt: now)
        for index in conflicts.indices where conflicts[index].candidateID == candidateID {
            conflicts[index].resolution = ZhulongMemoryConflictResolution(
                choice: .keepExisting,
                resultingMemory: nil,
                resolvedAt: now
            )
        }
    }

    @discardableResult
    public mutating func resolveConflicts(
        for candidateID: ZhulongMemoryCandidateID,
        choice: ZhulongMemoryConflictChoice,
        now: Date = Date()
    ) throws -> ZhulongConfirmedMemoryVersion? {
        guard isEnabled else { throw ZhulongMemoryError.disabled }
        let context = try validatedConflictContext(for: candidateID)
        let candidate = context.candidate
        let conflictIndices = context.conflictIndices
        let latestOpenedAt = conflictIndices.map { conflicts[$0].openedAt }.max() ?? candidate.createdAt
        try validateDecisionTime(now, after: max(latestOpenedAt, candidate.createdAt))

        let resultingMemory: ZhulongConfirmedMemoryVersion?
        switch choice {
        case .keepExisting:
            resultingMemory = nil
            candidateDecisions[candidate.id] = .rejected(decidedAt: now)
        case .acceptCandidate, .merge:
            let next = try replaceConflictingMemories(
                context.memoryIndices,
                with: candidate,
                choice: choice,
                now: now
            )
            candidateDecisions[candidate.id] = .confirmed(memory: next.reference, decidedAt: now)
            resultingMemory = next
        }
        for index in conflictIndices {
            conflicts[index].resolution = ZhulongMemoryConflictResolution(
                choice: choice,
                resultingMemory: resultingMemory?.reference,
                resolvedAt: now
            )
        }
        return resultingMemory
    }

    public mutating func setMemoryEnabled(
        _ reference: ZhulongMemoryVersionReference,
        enabled: Bool
    ) throws {
        guard let index = memories.firstIndex(where: { $0.reference == reference }) else {
            throw ZhulongMemoryError.memoryNotFound
        }
        guard memories[index].status != .superseded else {
            throw ZhulongMemoryError.memoryNotFound
        }
        memories[index].status = enabled ? .active : .disabled
    }

    public mutating func forget(
        memoryID: ZhulongMemoryID,
        suppressFutureInference: Bool,
        now: Date = Date()
    ) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ZhulongMemoryError.invalidTime
        }
        let forgotten = memories.filter { $0.memoryID == memoryID }
        guard let topicKey = forgotten.last?.topicKey else {
            throw ZhulongMemoryError.memoryNotFound
        }
        let sourceCandidateIDs = Set(forgotten.map(\.sourceCandidateID))
        memories.removeAll { $0.memoryID == memoryID }
        candidates.removeAll { sourceCandidateIDs.contains($0.id) }
        for candidateID in sourceCandidateIDs {
            candidateDecisions.removeValue(forKey: candidateID)
        }
        conflicts.removeAll {
            $0.existingMemory.memoryID == memoryID || sourceCandidateIDs.contains($0.candidateID)
        }
        let topicIsAlreadySuppressed = suppressionRules.contains { $0.topicKey == topicKey }
        if suppressFutureInference && topicIsAlreadySuppressed == false {
            suppressionRules.append(ZhulongMemorySuppressionRule(
                id: ZhulongMemorySuppressionRuleID(),
                topicKey: topicKey,
                createdAt: now
            ))
        }
    }

    private func validatedConflictContext(
        for candidateID: ZhulongMemoryCandidateID
    ) throws -> (
        candidate: ZhulongMemoryCandidate,
        conflictIndices: [Int],
        memoryIndices: [Int]
    ) {
        guard candidateDecisions[candidateID] == nil,
              let candidate = candidates.first(where: { $0.id == candidateID })
        else {
            throw ZhulongMemoryError.candidateAlreadyDecided
        }
        let conflictIndices = conflicts.indices.filter {
            conflicts[$0].candidateID == candidateID
        }
        guard conflictIndices.isEmpty == false else {
            throw ZhulongMemoryError.invalidConflict
        }
        guard conflictIndices.allSatisfy({ conflicts[$0].resolution == nil }) else {
            throw ZhulongMemoryError.conflictAlreadyResolved
        }
        let memoryIndices = try conflictIndices.map { conflictIndex in
            guard let memoryIndex = memories.firstIndex(where: {
                $0.reference == conflicts[conflictIndex].existingMemory &&
                    $0.status == .active &&
                    $0.topicKey == candidate.topicKey
            }) else {
                throw ZhulongMemoryError.invalidConflict
            }
            return memoryIndex
        }
        return (candidate, conflictIndices, memoryIndices)
    }

    private mutating func replaceConflictingMemories(
        _ memoryIndices: [Int],
        with candidate: ZhulongMemoryCandidate,
        choice: ZhulongMemoryConflictChoice,
        now: Date
    ) throws -> ZhulongConfirmedMemoryVersion {
        let content: String
        if case let .merge(mergedContent) = choice {
            content = mergedContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard content.isEmpty == false else { throw ZhulongMemoryError.invalidConflict }
        } else {
            content = candidate.content
        }
        guard let canonicalIndex = memoryIndices.min(by: { lhs, rhs in
            memories[lhs].memoryID.rawValue.uuidString < memories[rhs].memoryID.rawValue.uuidString
        }) else {
            throw ZhulongMemoryError.invalidConflict
        }
        let canonicalID = memories[canonicalIndex].memoryID
        let nextVersion = (memories
            .filter { $0.memoryID == canonicalID }
            .map(\.version)
            .max() ?? 0) + 1
        let next = ZhulongConfirmedMemoryVersion(
            memoryID: canonicalID,
            version: nextVersion,
            topicKey: candidate.topicKey,
            content: content,
            source: candidate.source,
            sourceCandidateID: candidate.id,
            effectiveAt: now,
            status: .active
        )
        for index in memoryIndices {
            memories[index].status = .superseded
        }
        memories.append(next)
        return next
    }

    func validateForPersistence() throws {
        guard Set(candidates.map(\.id)).count == candidates.count,
              Set(memories.map(\.reference)).count == memories.count,
              Set(conflicts.map(\.id)).count == conflicts.count,
              Set(suppressionRules.map(\.id)).count == suppressionRules.count,
              Set(suppressionRules.map(\.topicKey)).count == suppressionRules.count
        else {
            throw ZhulongMemoryError.invalidLedger
        }
        try validatePersistedCandidates()
        try validatePersistedMemories()
        try validatePersistedConflictsAndDecisions()
        guard suppressionRules.allSatisfy({ rule in
            rule.topicKey.isEmpty == false &&
                rule.topicKey == rule.topicKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() &&
                rule.createdAt.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw ZhulongMemoryError.invalidLedger
        }
    }

    private func validatePersistedCandidates() throws {
        for candidate in candidates {
            guard (try? ZhulongMemoryCandidate(
                id: candidate.id,
                topicKey: candidate.topicKey,
                content: candidate.content,
                source: candidate.source,
                evidenceWindowStart: candidate.evidenceWindowStart,
                evidenceWindowEnd: candidate.evidenceWindowEnd,
                evidenceReferences: candidate.evidenceReferences,
                confidence: candidate.confidence,
                counterexamples: candidate.counterexamples,
                conflictsWith: candidate.conflictsWith,
                createdAt: candidate.createdAt
            )) == candidate else {
                throw ZhulongMemoryError.invalidLedger
            }
        }
    }

    private func validatePersistedMemories() throws {
        for group in Dictionary(grouping: memories, by: \.memoryID).values {
            let ordered = group.sorted { $0.version < $1.version }
            guard ordered.map(\.version) == Array(1 ... ordered.count),
                  ordered.dropLast().allSatisfy({ $0.status == .superseded }),
                  ordered.last?.status != .superseded
            else {
                throw ZhulongMemoryError.invalidLedger
            }
            for memory in ordered {
                guard let candidate = candidates.first(where: { $0.id == memory.sourceCandidateID }),
                      memory.topicKey == candidate.topicKey,
                      memory.source == candidate.source,
                      memory.content.trimmingCharacters(in: .whitespacesAndNewlines) == memory.content,
                      memory.content.isEmpty == false,
                      memory.effectiveAt.timeIntervalSinceReferenceDate.isFinite,
                      memory.effectiveAt > candidate.createdAt
                else {
                    throw ZhulongMemoryError.invalidLedger
                }
            }
        }
    }

    private func validatePersistedConflictsAndDecisions() throws {
        guard Set(candidateDecisions.keys).isSubset(of: Set(candidates.map(\.id))) else {
            throw ZhulongMemoryError.invalidLedger
        }
        for candidate in candidates {
            let candidateConflicts = conflicts.filter { $0.candidateID == candidate.id }
            guard Set(candidateConflicts.map(\.existingMemory)) == Set(candidate.conflictsWith) else {
                throw ZhulongMemoryError.invalidLedger
            }
            try validateDecision(candidateDecisions[candidate.id], for: candidate, conflicts: candidateConflicts)
        }
    }

    private func validateDecision(
        _ decision: ZhulongMemoryCandidateDecision?,
        for candidate: ZhulongMemoryCandidate,
        conflicts candidateConflicts: [ZhulongMemoryConflict]
    ) throws {
        let unresolved = candidateConflicts.filter { $0.resolution == nil }
        guard unresolved.isEmpty || decision == nil else {
            throw ZhulongMemoryError.invalidLedger
        }
        try validateConflictFacts(candidateConflicts, for: candidate)
        switch decision {
        case nil:
            guard candidateConflicts.allSatisfy({ $0.resolution == nil }) else {
                throw ZhulongMemoryError.invalidLedger
            }
        case let .rejected(decidedAt):
            guard decidedAt > candidate.createdAt,
                  candidateConflicts.allSatisfy({ conflict in
                      conflict.resolution?.choice == .keepExisting &&
                          conflict.resolution?.resultingMemory == nil
                  })
            else {
                throw ZhulongMemoryError.invalidLedger
            }
        case let .confirmed(reference, decidedAt):
            guard let memory = memories.first(where: { $0.reference == reference }),
                  memory.sourceCandidateID == candidate.id,
                  memory.effectiveAt == decidedAt,
                  conflictsConfirm(candidateConflicts, resultingIn: reference)
            else {
                throw ZhulongMemoryError.invalidLedger
            }
        }
    }

    private func validateConflictFacts(
        _ candidateConflicts: [ZhulongMemoryConflict],
        for candidate: ZhulongMemoryCandidate
    ) throws {
        for conflict in candidateConflicts {
            guard let existing = memories.first(where: { $0.reference == conflict.existingMemory }),
                  existing.topicKey == candidate.topicKey,
                  conflict.openedAt == candidate.createdAt
            else {
                throw ZhulongMemoryError.invalidLedger
            }
            let resolutionIsBackdated = conflict.resolution.map {
                $0.resolvedAt <= conflict.openedAt
            } ?? false
            if resolutionIsBackdated {
                throw ZhulongMemoryError.invalidLedger
            }
        }
    }

    private func conflictsConfirm(
        _ candidateConflicts: [ZhulongMemoryConflict],
        resultingIn reference: ZhulongMemoryVersionReference
    ) -> Bool {
        candidateConflicts.allSatisfy { conflict in
            guard let resolution = conflict.resolution else { return false }
            switch resolution.choice {
            case .acceptCandidate, .merge:
                return resolution.resultingMemory == reference
            case .keepExisting:
                return false
            }
        }
    }

    private func validateDecisionTime(_ now: Date, after earlier: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite, now > earlier else {
            throw ZhulongMemoryError.invalidTime
        }
    }
}

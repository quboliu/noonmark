import CryptoKit
import Foundation
import NoonmarkCore

/// 一次已提交分类事实的 current wire format。
///
/// Envelope 携带 operation-typed exact delta、审计事实、可选 receipt 与完整性摘要，
/// 并以显式 base/result revision 定义一次可重放的分类提交。
public struct ClassificationCommitEnvelope: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case senderBaseRevision
        case senderResultRevision
        case delta
        case changeRecord
        case receipt
        case integrityDigest
    }

    public let formatVersion: Int
    public let senderBaseRevision: UInt64
    public let senderResultRevision: UInt64
    public let delta: ClassificationCommitDelta
    public let changeRecord: ClassificationChangeRecord
    public let receipt: ClassificationReceipt?
    public let integrityDigest: String

    public init(
        before: TaskClassificationState,
        after: TaskClassificationState,
        changeRecord: ClassificationChangeRecord
    ) throws {
        try Self.validateCommitBoundary(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        let receipt = try Self.receipt(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        let delta = try Self.makeDelta(
            before: before,
            after: after,
            changeRecord: changeRecord
        )
        try self.init(
            senderBaseRevision: before.revision,
            senderResultRevision: after.revision,
            delta: delta,
            changeRecord: changeRecord,
            receipt: receipt
        )

        let reconstructed = try ClassificationCommitTransition.applyExactly(
            delta,
            changeRecord: changeRecord,
            receipt: receipt,
            senderResultRevision: after.revision,
            to: before
        )
        guard reconstructed == after else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "before to after contains facts outside the typed classification delta"
            )
        }
    }

    init(
        senderBaseRevision: UInt64,
        senderResultRevision: UInt64,
        delta: ClassificationCommitDelta,
        changeRecord: ClassificationChangeRecord,
        receipt: ClassificationReceipt?
    ) throws {
        formatVersion = Self.currentFormatVersion
        self.senderBaseRevision = senderBaseRevision
        self.senderResultRevision = senderResultRevision
        self.delta = delta
        self.changeRecord = changeRecord
        self.receipt = receipt
        integrityDigest = canonicalSHA256(
            CommitEnvelopeDigestPayload(
                formatVersion: formatVersion,
                senderBaseRevision: senderBaseRevision,
                senderResultRevision: senderResultRevision,
                delta: delta,
                changeRecord: changeRecord,
                receipt: receipt
            )
        )
        try validateStandaloneFacts()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw ClassificationCommitEnvelopeError.unsupportedFormatVersion(formatVersion)
        }
        self.formatVersion = formatVersion
        senderBaseRevision = try container.decode(UInt64.self, forKey: .senderBaseRevision)
        senderResultRevision = try container.decode(UInt64.self, forKey: .senderResultRevision)
        delta = try container.decode(ClassificationCommitDelta.self, forKey: .delta)
        changeRecord = try container.decode(ClassificationChangeRecord.self, forKey: .changeRecord)
        receipt = try container.decodeIfPresent(ClassificationReceipt.self, forKey: .receipt)
        integrityDigest = try container.decode(String.self, forKey: .integrityDigest)

        guard try hasValidIntegrityDigest() else {
            throw ClassificationCommitEnvelopeError.integrityDigestMismatch
        }
        try validateStandaloneFacts()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(senderBaseRevision, forKey: .senderBaseRevision)
        try container.encode(senderResultRevision, forKey: .senderResultRevision)
        try container.encode(delta, forKey: .delta)
        try container.encode(changeRecord, forKey: .changeRecord)
        try container.encodeIfPresent(receipt, forKey: .receipt)
        try container.encode(integrityDigest, forKey: .integrityDigest)
    }

    public static func decode(_ data: Data) throws -> ClassificationCommitEnvelope {
        let decoded = try JSONDecoder().decode(ClassificationCommitEnvelope.self, from: data)
        guard try decoded.canonicalData() == data else {
            throw ClassificationCommitEnvelopeError.nonCanonicalEncoding
        }
        return decoded
    }

    public func canonicalData() throws -> Data {
        guard try hasValidIntegrityDigest() else {
            throw ClassificationCommitEnvelopeError.integrityDigestMismatch
        }
        try validateStandaloneFacts()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func hasValidIntegrityDigest() throws -> Bool {
        guard formatVersion == Self.currentFormatVersion,
              integrityDigest.isLowercaseSHA256
        else {
            return false
        }
        return integrityDigest == canonicalSHA256(
            CommitEnvelopeDigestPayload(
                formatVersion: formatVersion,
                senderBaseRevision: senderBaseRevision,
                senderResultRevision: senderResultRevision,
                delta: delta,
                changeRecord: changeRecord,
                receipt: receipt
            )
        )
    }
}

extension ClassificationCommitEnvelope {
    /// A wire-verifiable rename that records the user's confirmed observation but changes no fact.
    var isAuditOnlyNoOpRename: Bool {
        guard case .rename = delta,
              changeRecord.changes.count == 1,
              case let .rename(_, _, beforeName, afterName) = changeRecord.changes[0]
        else {
            return false
        }
        return beforeName == afterName
    }
}

public enum ClassificationCurrentFact: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case presence
        case value
    }

    private enum Presence: String, Codable {
        case absent
        case present
    }

    case absent
    case present(CurrentTaskClassification)

    init(_ value: CurrentTaskClassification?) {
        self = value.map(Self.present) ?? .absent
    }

    var value: CurrentTaskClassification? {
        switch self {
        case .absent:
            nil
        case let .present(value):
            value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Presence.self, forKey: .presence) {
        case .absent:
            guard container.contains(.value) == false else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "absent current fact must not carry a value"
                )
            }
            self = .absent
        case .present:
            self = .present(
                try container.decode(CurrentTaskClassification.self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Presence.absent, forKey: .presence)
        case let .present(value):
            try container.encode(Presence.present, forKey: .presence)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct ClassificationSetCurrentFact: Codable, Equatable, Sendable {
    public let chainID: TaskChainID
    public let expectedBase: ClassificationCurrentFact
    public let expectedBaseIntegrityDigest: String
    public let postState: CurrentTaskClassification

    init(
        chainID: TaskChainID,
        expectedBase: ClassificationCurrentFact,
        postState: CurrentTaskClassification
    ) {
        self.chainID = chainID
        self.expectedBase = expectedBase
        expectedBaseIntegrityDigest = Self.baseIntegrityDigest(
            chainID: chainID,
            expectedBase: expectedBase
        )
        self.postState = postState
    }

    func hasValidBaseIntegrityDigest() -> Bool {
        expectedBaseIntegrityDigest.isLowercaseSHA256
            && expectedBaseIntegrityDigest == Self.baseIntegrityDigest(
                chainID: chainID,
                expectedBase: expectedBase
            )
    }

    func canMerge(into local: CurrentTaskClassification?) -> Bool {
        let expected = expectedBase.value
        let categoryConflicts = expected?.category != postState.category
            && local?.category != expected?.category
        if categoryConflicts {
            return false
        }

        let expectedLabels = Dictionary(
            uniqueKeysWithValues: (expected?.labels ?? []).map { ($0.labelID, $0) }
        )
        let postLabels = Dictionary(
            uniqueKeysWithValues: postState.labels.map { ($0.labelID, $0) }
        )
        let localLabels = Dictionary(
            uniqueKeysWithValues: (local?.labels ?? []).map { ($0.labelID, $0) }
        )
        for removedID in Set(expectedLabels.keys).subtracting(postLabels.keys)
        where localLabels[removedID] != expectedLabels[removedID] {
            return false
        }
        for addedID in Set(postLabels.keys).subtracting(expectedLabels.keys) {
            if let local = localLabels[addedID], local != postLabels[addedID] {
                return false
            }
        }
        return true
    }

    func merging(into local: CurrentTaskClassification?) -> CurrentTaskClassification {
        let expected = expectedBase.value
        let category = expected?.category == postState.category
            ? local?.category
            : postState.category
        let expectedLabels = Dictionary(
            uniqueKeysWithValues: (expected?.labels ?? []).map { ($0.labelID, $0) }
        )
        let postLabels = Dictionary(
            uniqueKeysWithValues: postState.labels.map { ($0.labelID, $0) }
        )
        var mergedLabels = Dictionary(
            uniqueKeysWithValues: (local?.labels ?? []).map { ($0.labelID, $0) }
        )
        for removedID in Set(expectedLabels.keys).subtracting(postLabels.keys) {
            mergedLabels.removeValue(forKey: removedID)
        }
        for addedID in Set(postLabels.keys).subtracting(expectedLabels.keys) {
            mergedLabels[addedID] = postLabels[addedID]
        }
        return CurrentTaskClassification(
            category: category,
            labels: Array(mergedLabels.values)
        )
    }

    private static func baseIntegrityDigest(
        chainID: TaskChainID,
        expectedBase: ClassificationCurrentFact
    ) -> String {
        canonicalSHA256(
            ClassificationBaseIntegrityPayload(
                formatVersion: 1,
                chainID: chainID,
                expectedBase: expectedBase
            )
        )
    }
}

public enum ClassificationCommitDependency: Codable, Equatable, Hashable, Sendable {
    case taskChain(TaskChainID)
    case category(TaskCategoryID)
    case label(TaskLabelID)
    case classificationCommit(UUID)
    case classificationRevision(UInt64)
    case dayTrace(DayTraceID)
    case classificationEvent(UUID)
}

public enum ClassificationCommitConflictReason: Equatable, Sendable {
    case invalidEnvelope(String)
    case invalidLocalSnapshot(String)
    case changeRecordIdentityCollision(UUID)
    case planIdentityCollision(UUID)
    case interactionIdentityCollision(UUID)
    case expectedBaseMismatch(TaskChainID)
    case expectedItemBaseMismatch(kind: ClassificationItemKind, itemID: String)
    case managementFactBaseMismatch(kind: ClassificationItemKind, itemID: String)
    case dependencyPermanentlyDeleted(kind: ClassificationItemKind, itemID: String)
    case classificationIdentityCollision(kind: ClassificationItemKind, itemID: String)
    case canonicalNameCollision(kind: ClassificationItemKind, itemID: String, ownerID: String)
    case inactiveDependency(kind: ClassificationItemKind, itemID: String)
    case itemStillReferenced(
        kind: ClassificationItemKind,
        itemID: String,
        references: ClassificationReferenceSummary
    )
    case relationHistoryIdentityCollision(UUID)
    case resultingSnapshotInvalid(String)
}

public enum ClassificationCommitApplyResult: Equatable, Sendable {
    case applied(NoonmarkSnapshot)
    case duplicate(NoonmarkSnapshot)
    case waiting([ClassificationCommitDependency])
    case conflicted(ClassificationCommitConflictReason)
}

public struct ClassificationCommitEnvelopeReceiver: Sendable {
    public init() {}

    public func apply(
        _ envelope: ClassificationCommitEnvelope,
        to snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult {
        ClassificationCommitTransition.receive(envelope, into: snapshot)
    }
}

public enum ClassificationCommitEnvelopeError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case unsupportedCommit(String)
    case malformedCommit(String)
    case integrityDigestMismatch
    case nonCanonicalEncoding
}

private extension ClassificationCommitEnvelope {
    static func validateCommitBoundary(
        before: TaskClassificationState,
        after: TaskClassificationState,
        changeRecord: ClassificationChangeRecord
    ) throws {
        do {
            try before.validateIntegrity()
            try after.validateIntegrity()
        } catch {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification commit boundary contains an invalid state: \(error)"
            )
        }
        let expectedResult: UInt64
        if changeRecord.advancesStateRevision {
            let (next, overflow) = before.revision.addingReportingOverflow(1)
            guard overflow == false else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "classification revision overflow"
                )
            }
            expectedResult = next
        } else {
            expectedResult = before.revision
        }
        guard after.revision == expectedResult,
              changeRecord.revision == after.revision,
              before.changeRecords.contains(where: { $0.id == changeRecord.id }) == false
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification commit revision or audit boundary is inconsistent"
            )
        }
    }

    static func receipt(
        before: TaskClassificationState,
        after: TaskClassificationState,
        changeRecord: ClassificationChangeRecord
    ) throws -> ClassificationReceipt? {
        let interactionID = changeRecord.interactionID
        guard before.committedReceiptsByInteractionID[interactionID] == nil else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification interaction already has a receipt before the commit"
            )
        }
        let receipt = after.committedReceiptsByInteractionID[interactionID]
        switch changeRecord.source {
        case .userDirect, .zhulongSuggestion:
            guard receipt != nil else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "user-authorized classification commit is missing its receipt"
                )
            }
        case .inherited, .deterministicDomainAction:
            guard receipt == nil else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "deterministic classification commit must not carry a user receipt"
                )
            }
        }
        return receipt
    }

    static func makeDelta(
        before: TaskClassificationState,
        after: TaskClassificationState,
        changeRecord: ClassificationChangeRecord
    ) throws -> ClassificationCommitDelta {
        guard changeRecord.changes.count == 1, let change = changeRecord.changes.first else {
            throw ClassificationCommitEnvelopeError.unsupportedCommit(
                "classification envelope requires exactly one typed operation"
            )
        }

        var mutation = try stateMutation(before: before, after: after)
        switch change {
        case .setCurrent:
            return .setCurrent(mutation.withPredecessors(from: before))
        case .create:
            return .create(mutation.withPredecessors(from: before))
        case let .rename(kind, itemID, beforeName, afterName):
            mutation = try mutation.addingNoOpRenameIfNeeded(
                kind: kind,
                itemID: itemID,
                beforeName: beforeName,
                afterName: afterName,
                state: before
            )
            return .rename(mutation.withPredecessors(from: before))
        case .lifecycle:
            return .lifecycle(mutation.withPredecessors(from: before))
        case let .merge(kind, _, _, targetID, _, _, _):
            mutation = try mutation.requiringMergeTarget(
                kind: kind,
                targetID: targetID,
                state: before
            )
            return .merge(mutation.withPredecessors(from: before))
        case .hardDelete:
            return .hardDelete(mutation.withPredecessors(from: before))
        }
    }

    static func stateMutation(
        before: TaskClassificationState,
        after: TaskClassificationState
    ) throws -> ClassificationStateMutationDelta {
        let beforeHistory = Dictionary(
            uniqueKeysWithValues: before.relationHistory.map { ($0.id, $0) }
        )
        let afterHistory = Dictionary(
            uniqueKeysWithValues: after.relationHistory.map { ($0.id, $0) }
        )
        guard beforeHistory.allSatisfy({ afterHistory[$0.key] == $0.value }) else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification relation history is not append-only"
            )
        }
        let appendedHistory = try ClassificationAuditCanonicalOrder.relationHistory(
            after.relationHistory.filter { beforeHistory[$0.id] == nil }
        )

        return ClassificationStateMutationDelta(
            categoryMutations: dictionaryMutations(
                before: before.categories,
                after: after.categories,
                order: { $0.description < $1.description }
            ),
            labelMutations: dictionaryMutations(
                before: before.labels,
                after: after.labels,
                order: { $0.description < $1.description }
            ),
            currentMutations: dictionaryMutations(
                before: before.currentByChainID,
                after: after.currentByChainID,
                order: { $0.description < $1.description }
            ),
            categoryMergeMutations: dictionaryMutations(
                before: before.categoryMerges,
                after: after.categoryMerges,
                order: { $0.description < $1.description }
            ),
            labelMergeMutations: dictionaryMutations(
                before: before.labelMerges,
                after: after.labelMerges,
                order: { $0.description < $1.description }
            ),
            categoryTombstoneMutations: dictionaryMutations(
                before: before.categoryDeletionTombstones,
                after: after.categoryDeletionTombstones,
                order: { $0.description < $1.description }
            ),
            labelTombstoneMutations: dictionaryMutations(
                before: before.labelDeletionTombstones,
                after: after.labelDeletionTombstones,
                order: { $0.description < $1.description }
            ),
            appendedRelationHistory: appendedHistory
        )
    }

    func validateStandaloneFacts() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ClassificationCommitEnvelopeError.unsupportedFormatVersion(formatVersion)
        }
        let expectedResult: UInt64
        if changeRecord.advancesStateRevision {
            let (next, overflow) = senderBaseRevision.addingReportingOverflow(1)
            guard overflow == false else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "classification sender revision overflow"
                )
            }
            expectedResult = next
        } else {
            expectedResult = senderBaseRevision
        }
        guard senderResultRevision == expectedResult,
              changeRecord.revision == senderResultRevision,
              changeRecord.committedAt.timeIntervalSinceReferenceDate.isFinite,
              changeRecord.planDigest.isLowercaseSHA256,
              changeRecord.integrityDigest.isLowercaseSHA256,
              changeRecord.integrityDigest == computedChangeRecordIntegrityDigest(changeRecord)
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification sender revision, date, or audit digest is invalid"
            )
        }
        try validateReceipt()
        try delta.validateCanonicalShape(changeRecord: changeRecord)
    }

    func validateReceipt() throws {
        switch changeRecord.source {
        case .userDirect, .zhulongSuggestion:
            guard changeRecord.decisionID != nil,
                  let receipt,
                  receipt.planID == changeRecord.planID,
                  receipt.revision == changeRecord.revision,
                  receipt.notices == changeRecord.notices,
                  receipt.changeRecordID == changeRecord.id,
                  receipt.decisionID == changeRecord.decisionID,
                  receipt.changeRecordIntegrityDigest == changeRecord.integrityDigest
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "user-authorized classification audit or receipt is inconsistent"
                )
            }
        case .inherited, .deterministicDomainAction:
            guard changeRecord.decisionID == nil, receipt == nil else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "deterministic classification audit must not carry decision authority"
                )
            }
        }
    }
}

private extension ClassificationStateMutationDelta {
    func requiringMergeTarget(
        kind: ClassificationItemKind,
        targetID: String,
        state: TaskClassificationState
    ) throws -> ClassificationStateMutationDelta {
        switch kind {
        case .category:
            let id = try categoryID(targetID)
            guard let target = state.categories[id] else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "classification merge target is missing from the sender base"
                )
            }
            return requiring(category: target)
        case .label:
            let id = try labelID(targetID)
            guard let target = state.labels[id] else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "classification merge target is missing from the sender base"
                )
            }
            return requiring(label: target)
        }
    }

    func addingNoOpRenameIfNeeded(
        kind: ClassificationItemKind,
        itemID: String,
        beforeName: String,
        afterName: String,
        state: TaskClassificationState
    ) throws -> ClassificationStateMutationDelta {
        guard beforeName == afterName else { return self }
        switch kind {
        case .category:
            let id = try categoryID(itemID)
            guard let item = state.categories[id] else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "no-op category rename is missing its exact item base"
                )
            }
            return addingNoOp(category: item)
        case .label:
            let id = try labelID(itemID)
            guard let item = state.labels[id] else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "no-op label rename is missing its exact item base"
                )
            }
            return addingNoOp(label: item)
        }
    }

    func addingNoOp(category: TaskCategory) -> ClassificationStateMutationDelta {
        ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: predecessorChangeRecordIDs,
            categoryMutations: categoryMutations + [
                ClassificationCategoryMutation(
                    id: category.id,
                    expected: .present(category),
                    post: .present(category)
                )
            ],
            labelMutations: labelMutations,
            currentMutations: currentMutations,
            categoryMergeMutations: categoryMergeMutations,
            labelMergeMutations: labelMergeMutations,
            categoryTombstoneMutations: categoryTombstoneMutations,
            labelTombstoneMutations: labelTombstoneMutations,
            requiredCategories: requiredCategories,
            requiredLabels: requiredLabels,
            appendedRelationHistory: appendedRelationHistory
        )
    }

    func addingNoOp(label: TaskLabel) -> ClassificationStateMutationDelta {
        ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: predecessorChangeRecordIDs,
            categoryMutations: categoryMutations,
            labelMutations: labelMutations + [
                ClassificationLabelMutation(
                    id: label.id,
                    expected: .present(label),
                    post: .present(label)
                )
            ],
            currentMutations: currentMutations,
            categoryMergeMutations: categoryMergeMutations,
            labelMergeMutations: labelMergeMutations,
            categoryTombstoneMutations: categoryTombstoneMutations,
            labelTombstoneMutations: labelTombstoneMutations,
            requiredCategories: requiredCategories,
            requiredLabels: requiredLabels,
            appendedRelationHistory: appendedRelationHistory
        )
    }

    func withPredecessors(
        from state: TaskClassificationState
    ) -> ClassificationStateMutationDelta {
        let categoryIDs = Set(categoryMutations.map(\.id) + requiredCategories.map(\.id))
        let labelIDs = Set(labelMutations.map(\.id) + requiredLabels.map(\.id))
        let chainIDs = Set(currentMutations.map(\.id))
        var predecessors: Set<UUID> = []

        for id in categoryIDs {
            if let record = state.changeRecords.last(where: {
                $0.establishes(categoryID: id)
            }) {
                predecessors.insert(record.id)
            }
        }
        for id in labelIDs {
            if let record = state.changeRecords.last(where: {
                $0.establishes(labelID: id)
            }) {
                predecessors.insert(record.id)
            }
        }
        for id in chainIDs {
            predecessors.formUnion(state.currentFactCausalFrontier(for: id))
        }
        for mutation in categoryMutations
        where mutation.expected.value == nil {
            guard let created = mutation.post.value else { continue }
            predecessors.formUnion(
                state.hardDeletePredecessors(
                    releasing: created.canonicalOwnershipKeys,
                    kind: .category
                )
            )
        }
        for mutation in labelMutations
        where mutation.expected.value == nil {
            guard let created = mutation.post.value else { continue }
            predecessors.formUnion(
                state.hardDeletePredecessors(
                    releasing: created.canonicalOwnershipKeys,
                    kind: .label
                )
            )
        }

        return replacingPredecessors(
            predecessors.sorted { $0.uuidString < $1.uuidString }
        )
    }

    func replacingPredecessors(_ ids: [UUID]) -> ClassificationStateMutationDelta {
        ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: ids,
            categoryMutations: categoryMutations,
            labelMutations: labelMutations,
            currentMutations: currentMutations,
            categoryMergeMutations: categoryMergeMutations,
            labelMergeMutations: labelMergeMutations,
            categoryTombstoneMutations: categoryTombstoneMutations,
            labelTombstoneMutations: labelTombstoneMutations,
            requiredCategories: requiredCategories,
            requiredLabels: requiredLabels,
            appendedRelationHistory: appendedRelationHistory
        )
    }

    func requiring(category: TaskCategory) -> ClassificationStateMutationDelta {
        ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: predecessorChangeRecordIDs,
            categoryMutations: categoryMutations,
            labelMutations: labelMutations,
            currentMutations: currentMutations,
            categoryMergeMutations: categoryMergeMutations,
            labelMergeMutations: labelMergeMutations,
            categoryTombstoneMutations: categoryTombstoneMutations,
            labelTombstoneMutations: labelTombstoneMutations,
            requiredCategories: requiredCategories + [
                ClassificationRequiredCategoryFact(id: category.id, expected: category)
            ],
            requiredLabels: requiredLabels,
            appendedRelationHistory: appendedRelationHistory
        )
    }

    func requiring(label: TaskLabel) -> ClassificationStateMutationDelta {
        ClassificationStateMutationDelta(
            predecessorChangeRecordIDs: predecessorChangeRecordIDs,
            categoryMutations: categoryMutations,
            labelMutations: labelMutations,
            currentMutations: currentMutations,
            categoryMergeMutations: categoryMergeMutations,
            labelMergeMutations: labelMergeMutations,
            categoryTombstoneMutations: categoryTombstoneMutations,
            labelTombstoneMutations: labelTombstoneMutations,
            requiredCategories: requiredCategories,
            requiredLabels: requiredLabels + [
                ClassificationRequiredLabelFact(id: label.id, expected: label)
            ],
            appendedRelationHistory: appendedRelationHistory
        )
    }
}

private enum ClassificationCommitTransition {
    static func applyExactly(
        _ delta: ClassificationCommitDelta,
        changeRecord: ClassificationChangeRecord,
        receipt: ClassificationReceipt?,
        senderResultRevision: UInt64,
        to state: TaskClassificationState
    ) throws -> TaskClassificationState {
        var result = state
        let mutation = delta.mutation
        apply(mutation.categoryMutations, to: &result.categories)
        apply(mutation.labelMutations, to: &result.labels)
        apply(mutation.currentMutations, to: &result.currentByChainID)
        apply(mutation.categoryMergeMutations, to: &result.categoryMerges)
        apply(mutation.labelMergeMutations, to: &result.labelMerges)
        apply(
            mutation.categoryTombstoneMutations,
            to: &result.categoryDeletionTombstones
        )
        apply(
            mutation.labelTombstoneMutations,
            to: &result.labelDeletionTombstones
        )
        result.relationHistory = try ClassificationAuditCanonicalOrder.relationHistory(
            result.relationHistory + mutation.appendedRelationHistory
        )
        result.changeRecords = try ClassificationAuditCanonicalOrder.changeRecords(
            result.changeRecords + [changeRecord]
        )
        if let receipt {
            result.committedReceiptsByInteractionID[changeRecord.interactionID] = receipt
        }
        result.revision = senderResultRevision
        return result
    }

    static func receive(
        _ envelope: ClassificationCommitEnvelope,
        into snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult {
        if let disposition = validate(envelope, snapshot: snapshot) {
            return disposition
        }
        if let disposition = identityDisposition(envelope, snapshot: snapshot) {
            return disposition
        }
        if let disposition = dependencyDisposition(envelope, snapshot: snapshot) {
            return disposition
        }
        if let disposition = baseDisposition(envelope, snapshot: snapshot) {
            return disposition
        }
        if let disposition = operationDisposition(envelope, snapshot: snapshot) {
            return disposition
        }
        return materialize(envelope, snapshot: snapshot)
    }

    private static func validate(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult? {
        do {
            guard try envelope.hasValidIntegrityDigest() else {
                return .conflicted(.invalidEnvelope("envelope integrity digest mismatch"))
            }
            try envelope.validateStandaloneFacts()
        } catch {
            return .conflicted(.invalidEnvelope(String(describing: error)))
        }
        do {
            try snapshot.validateIntegrity()
        } catch {
            return .conflicted(.invalidLocalSnapshot(String(describing: error)))
        }
        return nil
    }

    private static func identityDisposition(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult? {
        let state = snapshot.classifications
        if let existing = state.changeRecords.first(where: {
            $0.id == envelope.changeRecord.id
        }) {
            guard existing == envelope.changeRecord,
                  existing.integrityDigest == envelope.changeRecord.integrityDigest,
                  state.committedReceiptsByInteractionID[existing.interactionID]
                  == envelope.receipt
            else {
                return .conflicted(
                    .changeRecordIdentityCollision(envelope.changeRecord.id)
                )
            }
            return .duplicate(snapshot)
        }
        if state.changeRecords.contains(where: {
            $0.planID == envelope.changeRecord.planID
        }) {
            return .conflicted(.planIdentityCollision(envelope.changeRecord.planID))
        }
        if state.changeRecords.contains(where: {
            $0.interactionID == envelope.changeRecord.interactionID
        }) || state.committedReceiptsByInteractionID[envelope.changeRecord.interactionID] != nil {
            return .conflicted(
                .interactionIdentityCollision(envelope.changeRecord.interactionID)
            )
        }
        return nil
    }

    private static func dependencyDisposition(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult? {
        let state = snapshot.classifications
        if let conflict = permanentDeletionConflict(envelope, state: state) {
            return .conflicted(conflict)
        }
        let missing = missingDependencies(envelope, snapshot: snapshot)
        guard missing.isEmpty else {
            return .waiting(missing.sorted(by: dependencyComesBefore))
        }
        guard envelope.senderBaseRevision <= state.revision else {
            return .waiting([.classificationRevision(envelope.senderBaseRevision)])
        }
        return nil
    }

    private static func baseDisposition(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult? {
        guard envelope.isAuditOnlyNoOpRename == false else { return nil }
        let state = snapshot.classifications
        let mutation = envelope.delta.mutation
        if let conflict = itemBaseConflict(mutation, state: state) {
            return .conflicted(conflict)
        }
        if let conflict = currentBaseConflict(mutation, state: state) {
            return .conflicted(conflict)
        }
        if let conflict = managementBaseConflict(mutation, state: state) {
            return .conflicted(conflict)
        }
        if let collision = mutation.appendedRelationHistory.first(where: { incoming in
            state.relationHistory.contains { $0.id == incoming.id }
        }) {
            return .conflicted(.relationHistoryIdentityCollision(collision.id))
        }
        return nil
    }

    private static func itemBaseConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        for item in mutation.categoryMutations
        where ClassificationFact(state.categories[item.id]) != item.expected {
            return .expectedItemBaseMismatch(
                kind: .category,
                itemID: item.id.description
            )
        }
        for item in mutation.labelMutations
        where ClassificationFact(state.labels[item.id]) != item.expected {
            return .expectedItemBaseMismatch(
                kind: .label,
                itemID: item.id.description
            )
        }
        for required in mutation.requiredCategories
        where state.categories[required.id] != required.expected {
            return .expectedItemBaseMismatch(
                kind: .category,
                itemID: required.id.description
            )
        }
        for required in mutation.requiredLabels
        where state.labels[required.id] != required.expected {
            return .expectedItemBaseMismatch(
                kind: .label,
                itemID: required.id.description
            )
        }
        return nil
    }

    private static func currentBaseConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        for fact in mutation.currentMutations {
            guard let post = fact.post.value else {
                return .expectedBaseMismatch(fact.id)
            }
            let setCurrent = ClassificationSetCurrentFact(
                chainID: fact.id,
                expectedBase: ClassificationCurrentFact(fact.expected.value),
                postState: post
            )
            guard setCurrent.canMerge(into: state.currentByChainID[fact.id]) else {
                return .expectedBaseMismatch(fact.id)
            }
        }
        return nil
    }

    private static func operationDisposition(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult? {
        guard envelope.isAuditOnlyNoOpRename == false else { return nil }
        if let conflict = inactiveDependencyConflict(
            envelope.delta.mutation,
            state: snapshot.classifications
        ) {
            return .conflicted(conflict)
        }
        if let conflict = canonicalNameConflict(
            envelope.delta.mutation,
            state: snapshot.classifications
        ) {
            return .conflicted(conflict)
        }
        let hardDeleteConflict: ClassificationCommitConflictReason? = if case .hardDelete = envelope.delta {
            hardDeleteReferenceConflict(
                envelope.delta.mutation,
                state: snapshot.classifications
            )
        } else {
            nil
        }
        if let conflict = hardDeleteConflict {
            return .conflicted(conflict)
        }
        return nil
    }

    private static func materialize(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> ClassificationCommitApplyResult {
        var result = snapshot
        let mutation = envelope.delta.mutation
        if envelope.isAuditOnlyNoOpRename == false {
            apply(mutation.categoryMutations, to: &result.classifications.categories)
            apply(mutation.labelMutations, to: &result.classifications.labels)
            apply(
                mutation.categoryMergeMutations,
                to: &result.classifications.categoryMerges
            )
            apply(mutation.labelMergeMutations, to: &result.classifications.labelMerges)
            apply(
                mutation.categoryTombstoneMutations,
                to: &result.classifications.categoryDeletionTombstones
            )
            apply(
                mutation.labelTombstoneMutations,
                to: &result.classifications.labelDeletionTombstones
            )
            for fact in mutation.currentMutations {
                guard let post = fact.post.value else {
                    return .conflicted(.expectedBaseMismatch(fact.id))
                }
                let setCurrent = ClassificationSetCurrentFact(
                    chainID: fact.id,
                    expectedBase: ClassificationCurrentFact(fact.expected.value),
                    postState: post
                )
                result.classifications.currentByChainID[fact.id] = setCurrent.merging(
                    into: result.classifications.currentByChainID[fact.id]
                )
            }
        }
        do {
            if envelope.isAuditOnlyNoOpRename == false {
                result.classifications.relationHistory = try ClassificationAuditCanonicalOrder
                    .relationHistory(
                        result.classifications.relationHistory
                            + mutation.appendedRelationHistory
                    )
            }
            result.classifications.changeRecords = try ClassificationAuditCanonicalOrder
                .changeRecords(
                    result.classifications.changeRecords + [envelope.changeRecord]
                )
        } catch {
            return .conflicted(.resultingSnapshotInvalid(String(describing: error)))
        }
        if let receipt = envelope.receipt {
            result.classifications.committedReceiptsByInteractionID[
                envelope.changeRecord.interactionID
            ] = receipt
        }
        if envelope.changeRecord.advancesStateRevision {
            let (revision, overflow) = result.classifications.revision
                .addingReportingOverflow(1)
            guard overflow == false else {
                return .conflicted(
                    .resultingSnapshotInvalid("classification revision overflow")
                )
            }
            result.classifications.revision = revision
        }

        do {
            try result.validateIntegrity()
        } catch {
            return .conflicted(.resultingSnapshotInvalid(String(describing: error)))
        }
        return .applied(result)
    }
}

private func apply<ID: Codable & Hashable & Sendable, Value: Codable & Equatable & Sendable>(
    _ mutations: [ClassificationValueMutation<ID, Value>],
    to dictionary: inout [ID: Value]
) {
    for mutation in mutations {
        dictionary[mutation.id] = mutation.post.value
    }
}

private extension ClassificationCommitTransition {
    static func inactiveDependencyConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        var categories = state.categories
        var labels = state.labels
        apply(mutation.categoryMutations, to: &categories)
        apply(mutation.labelMutations, to: &labels)

        for current in mutation.currentMutations {
            let expected = current.expected.value
            guard let post = current.post.value else { continue }

            if let categoryID = post.categoryID {
                if categoryID != expected?.categoryID {
                    guard categories[categoryID]?.lifecycle == .active else {
                        return .inactiveDependency(
                            kind: .category,
                            itemID: categoryID.description
                        )
                    }
                }
            }

            let addedLabelIDs = post.labelIDs.subtracting(expected?.labelIDs ?? [])
            for labelID in addedLabelIDs.sorted(by: {
                $0.description < $1.description
            }) where labels[labelID]?.lifecycle != .active {
                return .inactiveDependency(
                    kind: .label,
                    itemID: labelID.description
                )
            }
        }
        return nil
    }

    static func permanentDeletionConflict(
        _ envelope: ClassificationCommitEnvelope,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        guard envelope.isAuditOnlyNoOpRename == false else { return nil }
        for id in envelope.referencedCategoryIDs
        where state.categoryDeletionTombstones[id] != nil {
            return .dependencyPermanentlyDeleted(
                kind: .category,
                itemID: id.description
            )
        }
        for id in envelope.referencedLabelIDs
        where state.labelDeletionTombstones[id] != nil {
            return .dependencyPermanentlyDeleted(
                kind: .label,
                itemID: id.description
            )
        }
        return nil
    }

    static func missingDependencies(
        _ envelope: ClassificationCommitEnvelope,
        snapshot: NoonmarkSnapshot
    ) -> [ClassificationCommitDependency] {
        let state = snapshot.classifications
        let mutation = envelope.delta.mutation
        let chainIDs = Set(snapshot.chains.map(\.id))
        let createdCategoryIDs = Set(mutation.categoryMutations.compactMap {
            $0.expected.value == nil ? $0.post.value?.id : nil
        })
        let createdLabelIDs = Set(mutation.labelMutations.compactMap {
            $0.expected.value == nil ? $0.post.value?.id : nil
        })
        var missing: Set<ClassificationCommitDependency> = []

        for id in envelope.referencedChainIDs where chainIDs.contains(id) == false {
            missing.insert(.taskChain(id))
        }
        if envelope.isAuditOnlyNoOpRename == false {
            for id in envelope.referencedCategoryIDs
            where state.categories[id] == nil && createdCategoryIDs.contains(id) == false {
                missing.insert(.category(id))
            }
            for id in envelope.referencedLabelIDs
            where state.labels[id] == nil && createdLabelIDs.contains(id) == false {
                missing.insert(.label(id))
            }
        }
        let knownRecordIDs = Set(state.changeRecords.map(\.id))
        for id in mutation.predecessorChangeRecordIDs
        where knownRecordIDs.contains(id) == false {
            missing.insert(.classificationCommit(id))
        }
        return Array(missing)
    }

    static func managementBaseConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        for fact in mutation.categoryMergeMutations
        where ClassificationFact(state.categoryMerges[fact.id]) != fact.expected {
            return .managementFactBaseMismatch(
                kind: .category,
                itemID: fact.id.description
            )
        }
        for fact in mutation.labelMergeMutations
        where ClassificationFact(state.labelMerges[fact.id]) != fact.expected {
            return .managementFactBaseMismatch(
                kind: .label,
                itemID: fact.id.description
            )
        }
        for fact in mutation.categoryTombstoneMutations
        where ClassificationFact(state.categoryDeletionTombstones[fact.id]) != fact.expected {
            return .managementFactBaseMismatch(
                kind: .category,
                itemID: fact.id.description
            )
        }
        for fact in mutation.labelTombstoneMutations
        where ClassificationFact(state.labelDeletionTombstones[fact.id]) != fact.expected {
            return .managementFactBaseMismatch(
                kind: .label,
                itemID: fact.id.description
            )
        }
        return nil
    }

    static func canonicalNameConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        var categories = state.categories
        var labels = state.labels
        apply(mutation.categoryMutations, to: &categories)
        apply(mutation.labelMutations, to: &labels)

        let changedCategoryIDs = Set(mutation.categoryMutations.map(\.id))
        for id in changedCategoryIDs.sorted(by: { $0.description < $1.description }) {
            guard let item = categories[id] else { continue }
            let keys = item.canonicalOwnershipKeys
            let owner = categories.values
                .filter { $0.id != id }
                .sorted(by: { $0.id.description < $1.id.description })
                .first(where: { keys.isDisjoint(with: $0.canonicalOwnershipKeys) == false })
            if let owner {
                return .canonicalNameCollision(
                    kind: .category,
                    itemID: id.description,
                    ownerID: owner.id.description
                )
            }
        }

        let changedLabelIDs = Set(mutation.labelMutations.map(\.id))
        for id in changedLabelIDs.sorted(by: { $0.description < $1.description }) {
            guard let item = labels[id] else { continue }
            let keys = item.canonicalOwnershipKeys
            let owner = labels.values
                .filter { $0.id != id }
                .sorted(by: { $0.id.description < $1.id.description })
                .first(where: { keys.isDisjoint(with: $0.canonicalOwnershipKeys) == false })
            if let owner {
                return .canonicalNameCollision(
                    kind: .label,
                    itemID: id.description,
                    ownerID: owner.id.description
                )
            }
        }
        return nil
    }

    static func hardDeleteReferenceConflict(
        _ mutation: ClassificationStateMutationDelta,
        state: TaskClassificationState
    ) -> ClassificationCommitConflictReason? {
        for item in mutation.categoryMutations where item.post.value == nil {
            let references = categoryReferenceSummary(item.id, in: state)
            if references.isEmpty == false {
                return .itemStillReferenced(
                    kind: .category,
                    itemID: item.id.description,
                    references: references
                )
            }
        }
        for item in mutation.labelMutations where item.post.value == nil {
            let references = labelReferenceSummary(item.id, in: state)
            if references.isEmpty == false {
                return .itemStillReferenced(
                    kind: .label,
                    itemID: item.id.description,
                    references: references
                )
            }
        }
        return nil
    }
}

extension ClassificationCommitEnvelope {
    var referencedChainIDs: Set<TaskChainID> {
        var result = Set(delta.mutation.currentMutations.map(\.id))
        for source in classificationSources {
            if case let .inherited(fromChainID) = source {
                result.insert(fromChainID)
            }
        }
        return result
    }

    var referencedCategoryIDs: Set<TaskCategoryID> {
        let mutation = delta.mutation
        var result = Set(mutation.categoryMutations.map(\.id))
        result.formUnion(mutation.requiredCategories.map(\.id))
        for current in mutation.currentMutations {
            if let id = current.expected.value?.categoryID {
                result.insert(id)
            }
            if let id = current.post.value?.categoryID {
                result.insert(id)
            }
        }
        return result
    }

    var referencedLabelIDs: Set<TaskLabelID> {
        let mutation = delta.mutation
        var result = Set(mutation.labelMutations.map(\.id))
        result.formUnion(mutation.requiredLabels.map(\.id))
        for current in mutation.currentMutations {
            result.formUnion(current.expected.value?.labelIDs ?? [])
            result.formUnion(current.post.value?.labelIDs ?? [])
        }
        return result
    }

    var classificationSources: [ClassificationSource] {
        var result = [changeRecord.source]
        for current in delta.mutation.currentMutations {
            if let category = current.expected.value?.category {
                result.append(category.source)
            }
            result.append(contentsOf: current.expected.value?.labels.map(\.source) ?? [])
            if let category = current.post.value?.category {
                result.append(category.source)
            }
            result.append(contentsOf: current.post.value?.labels.map(\.source) ?? [])
        }
        for history in delta.mutation.appendedRelationHistory {
            result.append(history.originSource)
            result.append(history.removedBySource)
        }
        return result
    }
}

private struct ClassificationIDs: Equatable {
    let categoryID: TaskCategoryID?
    let labelIDs: Set<TaskLabelID>
}

private struct ClassificationRelationOrigin {
    let itemID: String
    let source: ClassificationSource
    let decisionID: UUID?
    let createdAt: Date
    let revision: UInt64
}

private func classificationIDs(
    in current: CurrentTaskClassification?
) throws -> ClassificationIDs {
    ClassificationIDs(
        categoryID: current?.categoryID,
        labelIDs: current?.labelIDs ?? []
    )
}

private func classificationIDs(
    in preview: ClassificationSelectionPreview
) throws -> ClassificationIDs {
    let category: TaskCategoryID?
    if let value = preview.category {
        guard value.kind == .category else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification preview category has the wrong kind"
            )
        }
        category = try categoryID(value.id)
    } else {
        category = nil
    }
    let labels = try preview.labels.map { value -> TaskLabelID in
        guard value.kind == .label else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification preview label has the wrong kind"
            )
        }
        return try labelID(value.id)
    }
    guard Set(labels).count == labels.count else {
        throw ClassificationCommitEnvelopeError.malformedCommit(
            "classification preview label identities are duplicated"
        )
    }
    return ClassificationIDs(categoryID: category, labelIDs: Set(labels))
}

private func removedClassificationIDs(
    from mutation: ClassificationCurrentMutation
) -> [(ClassificationItemKind, String)] {
    let expected = mutation.expected.value
    let post = mutation.post.value
    var removed: [(ClassificationItemKind, String)] = []
    let removedCategory = expected?.category.flatMap { category in
        category.categoryID != post?.categoryID ? category : nil
    }
    if let category = removedCategory {
        removed.append((.category, category.categoryID.description))
    }
    let removedLabels = (expected?.labelIDs ?? []).subtracting(post?.labelIDs ?? [])
    removed.append(contentsOf: removedLabels.map { (.label, $0.description) })
    return removed
}

private func categoryID(_ value: String?) throws -> TaskCategoryID {
    guard let value, let raw = UUID(uuidString: value) else {
        throw ClassificationCommitEnvelopeError.malformedCommit(
            "task category identity is not a UUID"
        )
    }
    return TaskCategoryID(raw)
}

private func categoryID(_ value: String) throws -> TaskCategoryID {
    try categoryID(Optional(value))
}

private func labelID(_ value: String?) throws -> TaskLabelID {
    guard let value, let raw = UUID(uuidString: value) else {
        throw ClassificationCommitEnvelopeError.malformedCommit(
            "task label identity is not a UUID"
        )
    }
    return TaskLabelID(raw)
}

private func labelID(_ value: String) throws -> TaskLabelID {
    try labelID(Optional(value))
}

private func idsAreCanonical(_ ids: [String]) -> Bool {
    Set(ids).count == ids.count && ids == ids.sorted()
}

private extension ClassificationChangeRecord {
    func establishes(categoryID: TaskCategoryID) -> Bool {
        changes.contains { change in
            switch change {
            case let .create(kind, itemID, _, _),
                 let .lifecycle(kind, itemID, _, _, _),
                 let .hardDelete(kind, itemID, _, _, _):
                kind == .category && itemID == categoryID.description
            case let .rename(kind, itemID, beforeName, afterName):
                kind == .category
                    && itemID == categoryID.description
                    && beforeName != afterName
            case let .merge(kind, sourceID, _, targetID, _, _, _):
                kind == .category
                    && (sourceID == categoryID.description
                        || targetID == categoryID.description)
            case .setCurrent:
                false
            }
        }
    }

    func establishes(labelID: TaskLabelID) -> Bool {
        changes.contains { change in
            switch change {
            case let .create(kind, itemID, _, _),
                 let .lifecycle(kind, itemID, _, _, _),
                 let .hardDelete(kind, itemID, _, _, _):
                kind == .label && itemID == labelID.description
            case let .rename(kind, itemID, beforeName, afterName):
                kind == .label
                    && itemID == labelID.description
                    && beforeName != afterName
            case let .merge(kind, sourceID, _, targetID, _, _, _):
                kind == .label
                    && (sourceID == labelID.description
                        || targetID == labelID.description)
            case .setCurrent:
                false
            }
        }
    }
}

private struct ClassificationPresenceCausalFact {
    var isPresent: Bool
    var headID: UUID
}

/// 从 immutable audit 重建某条任务链的 selection fact provenance。
///
/// sender `before` 匹配的 fact 已被本次提交观察，可由新 head 收束；不匹配的 fact
/// 来自未被 sender 观察的并发分支，必须保留为独立 head。absence 也是事实，避免分页时
/// 漏掉「先移除、后追加」的前驱。
private struct ClassificationCurrentCausalFrontier {
    var categoryID: String?
    var categoryHeadID: UUID?
    var labelsByID: [String: ClassificationPresenceCausalFact] = [:]

    var headIDs: Set<UUID> {
        var result = Set(labelsByID.values.map(\.headID))
        if let categoryHeadID {
            result.insert(categoryHeadID)
        }
        return result
    }

    mutating func absorbSetCurrent(
        recordID: UUID,
        before: ClassificationSelectionPreview,
        after: ClassificationSelectionPreview
    ) {
        let expectedCategoryID = before.category?.id
        let postCategoryID = after.category?.id
        let observesCategory = categoryID == expectedCategoryID
        if expectedCategoryID != postCategoryID {
            categoryID = postCategoryID
            categoryHeadID = recordID
        } else if observesCategory, categoryHeadID != nil {
            categoryHeadID = recordID
        }

        let expectedLabelIDs = Set(before.labels.compactMap(\.id))
        let postLabelIDs = Set(after.labels.compactMap(\.id))
        let knownLabelIDs = Set(labelsByID.keys)
            .union(expectedLabelIDs)
            .union(postLabelIDs)
        for id in knownLabelIDs {
            let expectedPresence = expectedLabelIDs.contains(id)
            let postPresence = postLabelIDs.contains(id)
            let existing = labelsByID[id]
            let localPresence = existing?.isPresent ?? false
            if expectedPresence != postPresence {
                labelsByID[id] = ClassificationPresenceCausalFact(
                    isPresent: postPresence,
                    headID: recordID
                )
            } else if let existing, localPresence == expectedPresence {
                labelsByID[id] = ClassificationPresenceCausalFact(
                    isPresent: existing.isPresent,
                    headID: recordID
                )
            }
        }
    }

    mutating func absorbMerge(
        recordID: UUID,
        kind: ClassificationItemKind,
        sourceID: String,
        targetID: String
    ) {
        if categoryHeadID != nil {
            categoryHeadID = recordID
        }
        for id in Array(labelsByID.keys) {
            labelsByID[id]?.headID = recordID
        }

        switch kind {
        case .category:
            guard categoryID == sourceID else { return }
            categoryID = targetID
            categoryHeadID = recordID
        case .label:
            labelsByID[sourceID] = ClassificationPresenceCausalFact(
                isPresent: false,
                headID: recordID
            )
            labelsByID[targetID] = ClassificationPresenceCausalFact(
                isPresent: true,
                headID: recordID
            )
        }
    }
}

private extension TaskClassificationState {
    func currentFactCausalFrontier(for chainID: TaskChainID) -> Set<UUID> {
        var frontier = ClassificationCurrentCausalFrontier()
        for record in changeRecords {
            for change in record.changes {
                switch change {
                case let .setCurrent(id, before, after) where id == chainID:
                    frontier.absorbSetCurrent(
                        recordID: record.id,
                        before: before,
                        after: after
                    )
                case let .merge(
                    kind,
                    sourceID,
                    _,
                    targetID,
                    _,
                    _,
                    impact
                ) where impact.currentChainIDs.contains(chainID):
                    frontier.absorbMerge(
                        recordID: record.id,
                        kind: kind,
                        sourceID: sourceID,
                        targetID: targetID
                    )
                case .create, .rename, .lifecycle, .hardDelete, .setCurrent, .merge:
                    continue
                }
            }
        }
        return frontier.headIDs
    }
}

private struct ClassificationCanonicalOwnershipKey: Hashable {
    let version: String
    let key: String
}

private extension TaskClassificationState {
    func hardDeletePredecessors(
        releasing ownershipKeys: Set<ClassificationCanonicalOwnershipKey>,
        kind: ClassificationItemKind
    ) -> Set<UUID> {
        Set(changeRecords.compactMap { hardDeleteRecord in
            let deletedItemIDs = hardDeleteRecord.changes.compactMap { change in
                change.hardDeletedItemID(of: kind)
            }
            guard deletedItemIDs.contains(where: { itemID in
                let releasedKeys = Set(changeRecords.flatMap { record in
                    record.changes.flatMap {
                        $0.ownershipNames(of: kind, itemID: itemID)
                    }
                }.map { name in
                    ClassificationCanonicalOwnershipKey(
                        version: ClassificationNameCanonicalizer.algorithmVersion,
                        key: ClassificationNameCanonicalizer.canonicalKey(name)
                    )
                })
                return ownershipKeys.isDisjoint(with: releasedKeys) == false
            }) else {
                return nil
            }
            return hardDeleteRecord.id
        })
    }
}

private extension ClassificationPlanChange {
    func hardDeletedItemID(of expectedKind: ClassificationItemKind) -> String? {
        guard case let .hardDelete(kind, itemID, _, _, _) = self,
              kind == expectedKind
        else {
            return nil
        }
        return itemID
    }

    func ownershipNames(
        of expectedKind: ClassificationItemKind,
        itemID expectedItemID: String
    ) -> [String] {
        switch self {
        case let .create(kind, itemID, name, _):
            return kind == expectedKind && itemID == expectedItemID ? [name] : []
        case let .rename(kind, itemID, beforeName, afterName):
            return kind == expectedKind && itemID == expectedItemID
                ? [beforeName, afterName]
                : []
        case let .lifecycle(kind, itemID, name, _, _),
             let .hardDelete(kind, itemID, name, _, _):
            return kind == expectedKind && itemID == expectedItemID ? [name] : []
        case let .merge(
            kind,
            sourceID,
            sourceName,
            targetID,
            targetName,
            _,
            _
        ):
            guard kind == expectedKind else { return [] }
            var names: [String] = []
            if sourceID == expectedItemID {
                names.append(sourceName)
            }
            if targetID == expectedItemID {
                names.append(targetName)
            }
            return names
        case let .setCurrent(_, before, after):
            let items = [before.category, after.category].compactMap { $0 }
                + before.labels
                + after.labels
            return items.compactMap { item in
                item.kind == expectedKind && item.id == expectedItemID
                    ? item.name
                    : nil
            }
        }
    }
}

private extension TaskCategory {
    var canonicalOwnershipKeys: Set<ClassificationCanonicalOwnershipKey> {
        Set(nameVersions.map {
            ClassificationCanonicalOwnershipKey(
                version: $0.canonicalKeyVersion,
                key: $0.canonicalKey
            )
        }).union([
            ClassificationCanonicalOwnershipKey(
                version: canonicalKeyVersion,
                key: canonicalKey
            )
        ])
    }
}

private extension TaskLabel {
    var canonicalOwnershipKeys: Set<ClassificationCanonicalOwnershipKey> {
        Set(nameVersions.map {
            ClassificationCanonicalOwnershipKey(
                version: $0.canonicalKeyVersion,
                key: $0.canonicalKey
            )
        }).union([
            ClassificationCanonicalOwnershipKey(
                version: canonicalKeyVersion,
                key: canonicalKey
            )
        ])
    }
}

private func categoryReferenceSummary(
    _ id: TaskCategoryID,
    in state: TaskClassificationState
) -> ClassificationReferenceSummary {
    let historicalIDs = Set(state.snapshotEventsByTraceID.values
        .flatMap { $0 }
        .compactMap { event in event.category?.id == id ? event.id : nil })
    return ClassificationReferenceSummary(
        currentRelationCount: state.currentByChainID.values.count {
            $0.categoryID == id
        },
        relationHistoryCount: state.relationHistory.count {
            $0.kind == .category && $0.itemID == id.description
        },
        historicalEventCount: historicalIDs.count,
        mergeSourceCount: state.categoryMerges[id] == nil ? 0 : 1,
        mergeTargetCount: state.categoryMerges.values.count { $0.targetID == id }
    )
}

private func labelReferenceSummary(
    _ id: TaskLabelID,
    in state: TaskClassificationState
) -> ClassificationReferenceSummary {
    let historicalIDs = Set(state.snapshotEventsByTraceID.values
        .flatMap { $0 }
        .compactMap { event in
            event.labels.contains(where: { $0.id == id }) ? event.id : nil
        })
    return ClassificationReferenceSummary(
        currentRelationCount: state.currentByChainID.values.count {
            $0.labelIDs.contains(id)
        },
        relationHistoryCount: state.relationHistory.count {
            $0.kind == .label && $0.itemID == id.description
        },
        historicalEventCount: historicalIDs.count,
        mergeSourceCount: state.labelMerges[id] == nil ? 0 : 1,
        mergeTargetCount: state.labelMerges.values.count { $0.targetID == id }
    )
}

private struct ClassificationBaseIntegrityPayload: Encodable {
    let formatVersion: Int
    let chainID: TaskChainID
    let expectedBase: ClassificationCurrentFact
}

private struct CommitEnvelopeDigestPayload: Encodable {
    let formatVersion: Int
    let senderBaseRevision: UInt64
    let senderResultRevision: UInt64
    let delta: ClassificationCommitDelta
    let changeRecord: ClassificationChangeRecord
    let receipt: ClassificationReceipt?
}

private struct ChangeRecordDigestPayload: Encodable {
    let formatVersion: Int
    let id: UUID
    let planID: UUID
    let interactionID: UUID
    let source: ClassificationSource
    let decisionID: UUID?
    let changes: [ClassificationPlanChange]
    let notices: [ClassificationNotice]
    let committedAtBitPattern: UInt64
    let revision: UInt64
    let planDigest: String
}

private func computedChangeRecordIntegrityDigest(
    _ record: ClassificationChangeRecord
) -> String {
    canonicalSHA256(
        ChangeRecordDigestPayload(
            formatVersion: 1,
            id: record.id,
            planID: record.planID,
            interactionID: record.interactionID,
            source: record.source,
            decisionID: record.decisionID,
            changes: record.changes,
            notices: record.notices,
            committedAtBitPattern: record.committedAt.timeIntervalSinceReferenceDate.bitPattern,
            revision: record.revision,
            planDigest: record.planDigest
        )
    )
}

private func canonicalSHA256(_ payload: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload) else {
        preconditionFailure("classification commit canonical payload cannot be encoded")
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func dependencyComesBefore(
    _ lhs: ClassificationCommitDependency,
    _ rhs: ClassificationCommitDependency
) -> Bool {
    func key(_ dependency: ClassificationCommitDependency) -> (Int, String) {
        switch dependency {
        case let .taskChain(id):
            (0, id.description)
        case let .category(id):
            (1, id.description)
        case let .label(id):
            (2, id.description)
        case let .classificationCommit(id):
            (3, id.uuidString)
        case let .classificationRevision(revision):
            (4, String(format: "%020llu", revision))
        case let .dayTrace(id):
            (5, id.description)
        case let .classificationEvent(id):
            (6, id.uuidString)
        }
    }
    return key(lhs) < key(rhs)
}

private extension String {
    var isLowercaseSHA256: Bool {
        utf8.count == 64 && utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

private func dictionaryMutations<ID: Codable & Hashable & Sendable, Value: Codable & Equatable & Sendable>(
    before: [ID: Value],
    after: [ID: Value],
    order: (ID, ID) -> Bool
) -> [ClassificationValueMutation<ID, Value>] {
    Set(before.keys).union(after.keys)
        .filter { before[$0] != after[$0] }
        .sorted(by: order)
        .map {
            ClassificationValueMutation(
                id: $0,
                expected: ClassificationFact(before[$0]),
                post: ClassificationFact(after[$0])
            )
        }
}

private struct ClassificationLifecycleAuditFact {
    let kind: ClassificationItemKind
    let itemID: String
    let name: String
    let before: ClassificationLifecycle
    let after: ClassificationLifecycle
}

private struct ClassificationMergeAuditFact {
    let kind: ClassificationItemKind
    let sourceID: String
    let sourceName: String
    let targetID: String
    let targetName: String
    let sourceLifecycle: ClassificationLifecycle
    let impact: ClassificationMergeImpact
}

private struct ClassificationHardDeleteAuditFact {
    let kind: ClassificationItemKind
    let itemID: String
    let name: String
    let lifecycle: ClassificationLifecycle
    let references: ClassificationReferenceSummary
}

private struct ClassificationRelationProvenanceFact {
    let source: ClassificationSource
    let decisionID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let revision: UInt64
}

private extension ClassificationCommitDelta {
    func validateCanonicalShape(
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard changeRecord.changes.count == 1, let change = changeRecord.changes.first else {
            throw ClassificationCommitEnvelopeError.unsupportedCommit(
                "classification delta requires exactly one audit operation"
            )
        }
        try mutation.validateCanonicalCollections()

        switch (self, change) {
        case let (.setCurrent(mutation), .setCurrent(chainID, before, after)):
            try mutation.validateSetCurrent(
                chainID: chainID,
                beforePreview: before,
                afterPreview: after,
                changeRecord: changeRecord
            )
        case let (.create(mutation), .create(kind, itemID, name, colorHex)):
            try mutation.validateCreate(
                kind: kind,
                itemID: itemID,
                name: name,
                colorHex: colorHex,
                changeRecord: changeRecord
            )
        case let (.rename(mutation), .rename(kind, itemID, beforeName, afterName)):
            try mutation.validateRename(
                kind: kind,
                itemID: itemID,
                beforeName: beforeName,
                afterName: afterName,
                changeRecord: changeRecord
            )
        case let (.lifecycle(mutation), .lifecycle(kind, itemID, name, before, after)):
            try mutation.validateLifecycle(
                ClassificationLifecycleAuditFact(
                    kind: kind,
                    itemID: itemID,
                    name: name,
                    before: before,
                    after: after
                ),
                changeRecord: changeRecord
            )
        case let (
            .merge(mutation),
            .merge(kind, sourceID, sourceName, targetID, targetName, sourceLifecycle, impact)
        ):
            try mutation.validateMerge(
                ClassificationMergeAuditFact(
                    kind: kind,
                    sourceID: sourceID,
                    sourceName: sourceName,
                    targetID: targetID,
                    targetName: targetName,
                    sourceLifecycle: sourceLifecycle,
                    impact: impact
                ),
                changeRecord: changeRecord
            )
        case let (
            .hardDelete(mutation),
            .hardDelete(kind, itemID, name, lifecycle, references)
        ):
            try mutation.validateHardDelete(
                ClassificationHardDeleteAuditFact(
                    kind: kind,
                    itemID: itemID,
                    name: name,
                    lifecycle: lifecycle,
                    references: references
                ),
                changeRecord: changeRecord
            )
        default:
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification delta kind does not match its audit operation"
            )
        }
    }
}

private extension ClassificationStateMutationDelta {
    func validateCanonicalCollections() throws {
        try validateCanonicalOrdering()
        try validateMutationIdentities(
            categoryMutations,
            identity: \.id,
            description: "category"
        )
        try validateMutationIdentities(
            labelMutations,
            identity: \.id,
            description: "label"
        )
        try validateMutationIdentities(
            categoryMergeMutations,
            identity: \.sourceID,
            description: "category merge"
        )
        try validateMutationIdentities(
            labelMergeMutations,
            identity: \.sourceID,
            description: "label merge"
        )
        try validateMutationIdentities(
            categoryTombstoneMutations,
            identity: \.itemID,
            description: "category tombstone"
        )
        try validateMutationIdentities(
            labelTombstoneMutations,
            identity: \.itemID,
            description: "label tombstone"
        )
        try validateRequiredFactIdentities()
    }

    func validateCanonicalOrdering() throws {
        guard Set(predecessorChangeRecordIDs).count == predecessorChangeRecordIDs.count,
              predecessorChangeRecordIDs == predecessorChangeRecordIDs.sorted(by: {
                  $0.uuidString < $1.uuidString
              })
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification predecessor facts are duplicated or not canonical"
            )
        }
        try validateCanonicalIDs(categoryMutations.map { $0.id.description })
        try validateCanonicalIDs(labelMutations.map { $0.id.description })
        try validateCanonicalIDs(currentMutations.map { $0.id.description })
        try validateCanonicalIDs(categoryMergeMutations.map { $0.id.description })
        try validateCanonicalIDs(labelMergeMutations.map { $0.id.description })
        try validateCanonicalIDs(categoryTombstoneMutations.map { $0.id.description })
        try validateCanonicalIDs(labelTombstoneMutations.map { $0.id.description })
        try validateCanonicalIDs(requiredCategories.map { $0.id.description })
        try validateCanonicalIDs(requiredLabels.map { $0.id.description })

        guard try ClassificationAuditCanonicalOrder.relationHistory(appendedRelationHistory)
            == appendedRelationHistory,
            Set(appendedRelationHistory.map(\.id)).count == appendedRelationHistory.count
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification relation history is duplicated or not canonical"
            )
        }
    }

    func validateCanonicalIDs(_ ids: [String]) throws {
        guard idsAreCanonical(ids) else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification delta item facts are duplicated or not canonical"
            )
        }
    }

    func validateMutationIdentities<
        ID: Codable & Equatable & Sendable,
        Value: Codable & Equatable & Sendable
    >(
        _ mutations: [ClassificationValueMutation<ID, Value>],
        identity: (Value) -> ID,
        description: String
    ) throws {
        for mutation in mutations {
            let expectedID = mutation.expected.value.map(identity)
            let postID = mutation.post.value.map(identity)
            guard expectedID == nil || expectedID == mutation.id,
                  postID == nil || postID == mutation.id,
                  expectedID != nil || postID != nil
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "\(description) mutation identity is inconsistent"
                )
            }
        }
    }

    func validateRequiredFactIdentities() throws {
        guard requiredCategories.allSatisfy({ $0.id == $0.expected.id }),
              requiredLabels.allSatisfy({ $0.id == $0.expected.id })
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "required classification fact identity is inconsistent"
            )
        }
    }

    func validateSetCurrent(
        chainID: TaskChainID,
        beforePreview: ClassificationSelectionPreview,
        afterPreview: ClassificationSelectionPreview,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard currentMutations.count == 1,
              let current = currentMutations.first,
              current.id == chainID,
              let post = current.post.value,
              categoryMergeMutations.isEmpty,
              labelMergeMutations.isEmpty,
              categoryTombstoneMutations.isEmpty,
              labelTombstoneMutations.isEmpty,
              requiredCategories.isEmpty,
              requiredLabels.isEmpty,
              categoryMutations.allSatisfy({
                  $0.expected.value == nil && $0.post.value != nil
              }),
              labelMutations.allSatisfy({
                  $0.expected.value == nil && $0.post.value != nil
              }),
              try classificationIDs(in: current.expected.value)
              == classificationIDs(in: beforePreview),
              try classificationIDs(in: post) == classificationIDs(in: afterPreview)
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "setCurrent typed facts do not match the audit preview"
            )
        }
        try validateCurrentRewrite(current, changeRecord: changeRecord)
        try validateCreatedItems(afterPreview: afterPreview, changeRecord: changeRecord)
        try validateRemovalHistory(
            currentMutation: current,
            changeRecord: changeRecord,
            expectedKindAndItemIDs: removedClassificationIDs(from: current)
        )
    }

    func validateCreate(
        kind: ClassificationItemKind,
        itemID: String,
        name: String,
        colorHex: String,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard currentMutations.isEmpty,
              categoryMergeMutations.isEmpty,
              labelMergeMutations.isEmpty,
              categoryTombstoneMutations.isEmpty,
              labelTombstoneMutations.isEmpty,
              requiredCategories.isEmpty,
              requiredLabels.isEmpty,
              appendedRelationHistory.isEmpty
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "create delta contains unrelated classification facts"
            )
        }
        switch kind {
        case .category:
            let id = try categoryID(itemID)
            guard categoryMutations.count == 1,
                  labelMutations.isEmpty,
                  let mutation = categoryMutations.first,
                  mutation.id == id,
                  mutation.expected.value == nil,
                  let item = mutation.post.value,
                  item.name == name,
                  item.colorHex == colorHex
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category create delta does not match its audit"
                )
            }
            try validateCreatedCategory(item, changeRecord: changeRecord)
        case .label:
            let id = try labelID(itemID)
            guard labelMutations.count == 1,
                  categoryMutations.isEmpty,
                  let mutation = labelMutations.first,
                  mutation.id == id,
                  mutation.expected.value == nil,
                  let item = mutation.post.value,
                  item.name == name,
                  item.colorHex == colorHex
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label create delta does not match its audit"
                )
            }
            try validateCreatedLabel(item, changeRecord: changeRecord)
        }
    }

    func validateRename(
        kind: ClassificationItemKind,
        itemID: String,
        beforeName: String,
        afterName: String,
        changeRecord: ClassificationChangeRecord
    ) throws {
        try requireOnlyOneItemReplacement(kind: kind)
        switch kind {
        case .category:
            let id = try categoryID(itemID)
            guard let mutation = categoryMutations.first,
                  mutation.id == id,
                  let before = mutation.expected.value,
                  let after = mutation.post.value,
                  before.name == beforeName,
                  after.name == afterName
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category rename delta does not match its audit"
                )
            }
            try validateRename(before: before, after: after, changeRecord: changeRecord)
        case .label:
            let id = try labelID(itemID)
            guard let mutation = labelMutations.first,
                  mutation.id == id,
                  let before = mutation.expected.value,
                  let after = mutation.post.value,
                  before.name == beforeName,
                  after.name == afterName
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label rename delta does not match its audit"
                )
            }
            try validateRename(before: before, after: after, changeRecord: changeRecord)
        }
    }

    func validateLifecycle(
        _ audit: ClassificationLifecycleAuditFact,
        changeRecord: ClassificationChangeRecord
    ) throws {
        let kind = audit.kind
        let itemID = audit.itemID
        let name = audit.name
        let before = audit.before
        let after = audit.after
        try requireOnlyOneItemReplacement(kind: kind)
        guard (before == .active && after == .archived)
            || (before == .archived && after == .active)
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification lifecycle transition is unsupported"
            )
        }
        switch kind {
        case .category:
            let id = try categoryID(itemID)
            guard let mutation = categoryMutations.first,
                  mutation.id == id,
                  let expected = mutation.expected.value,
                  let post = mutation.post.value,
                  expected.name == name,
                  expected.lifecycle == before,
                  post.lifecycle == after
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category lifecycle delta does not match its audit"
                )
            }
            var projected = expected
            projected.lifecycle = after
            projected.updatedAt = changeRecord.committedAt
            guard projected == post else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category lifecycle delta changes unrelated item facts"
                )
            }
        case .label:
            let id = try labelID(itemID)
            guard let mutation = labelMutations.first,
                  mutation.id == id,
                  let expected = mutation.expected.value,
                  let post = mutation.post.value,
                  expected.name == name,
                  expected.lifecycle == before,
                  post.lifecycle == after
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label lifecycle delta does not match its audit"
                )
            }
            var projected = expected
            projected.lifecycle = after
            projected.updatedAt = changeRecord.committedAt
            guard projected == post else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label lifecycle delta changes unrelated item facts"
                )
            }
        }
    }

    func validateMerge(
        _ audit: ClassificationMergeAuditFact,
        changeRecord: ClassificationChangeRecord
    ) throws {
        let kind = audit.kind
        let sourceID = audit.sourceID
        let sourceName = audit.sourceName
        let targetID = audit.targetID
        let targetName = audit.targetName
        let sourceLifecycle = audit.sourceLifecycle
        let impact = audit.impact
        guard categoryTombstoneMutations.isEmpty,
              labelTombstoneMutations.isEmpty,
              Set(currentMutations.map(\.id)) == Set(impact.currentChainIDs),
              currentMutations.count == impact.currentChainIDs.count,
              impact.migratedRelationCount + impact.deduplicatedRelationCount
              == currentMutations.count,
              kind == .label || impact.deduplicatedRelationCount == 0
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "merge delta current impact does not match its audit"
            )
        }

        switch kind {
        case .category:
            let source = try categoryID(sourceID)
            let target = try categoryID(targetID)
            guard categoryMutations.count == 1,
                  labelMutations.isEmpty,
                  categoryMergeMutations.count == 1,
                  labelMergeMutations.isEmpty,
                  requiredCategories.count == 1,
                  requiredLabels.isEmpty,
                  let itemMutation = categoryMutations.first,
                  itemMutation.id == source,
                  let before = itemMutation.expected.value,
                  let after = itemMutation.post.value,
                  before.name == sourceName,
                  before.lifecycle == sourceLifecycle,
                  requiredCategories.first?.id == target,
                  requiredCategories.first?.expected.name == targetName,
                  requiredCategories.first?.expected.lifecycle == .active,
                  let mergeMutation = categoryMergeMutations.first,
                  mergeMutation.id == source,
                  mergeMutation.expected.value == nil,
                  let merge = mergeMutation.post.value,
                  merge.sourceID == source,
                  merge.targetID == target,
                  merge.mergedAt == changeRecord.committedAt,
                  merge.revision == changeRecord.revision,
                  merge.changeRecordID == changeRecord.id
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category merge delta does not match its audit"
                )
            }
            var projected = before
            projected.lifecycle = .merged
            projected.updatedAt = changeRecord.committedAt
            guard projected == after else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category merge mutates unrelated source facts"
                )
            }
            try validateMergeCurrentRewrites(
                kind: .category,
                sourceID: sourceID,
                targetID: targetID,
                changeRecord: changeRecord
            )
        case .label:
            let source = try labelID(sourceID)
            let target = try labelID(targetID)
            guard labelMutations.count == 1,
                  categoryMutations.isEmpty,
                  labelMergeMutations.count == 1,
                  categoryMergeMutations.isEmpty,
                  requiredLabels.count == 1,
                  requiredCategories.isEmpty,
                  let itemMutation = labelMutations.first,
                  itemMutation.id == source,
                  let before = itemMutation.expected.value,
                  let after = itemMutation.post.value,
                  before.name == sourceName,
                  before.lifecycle == sourceLifecycle,
                  requiredLabels.first?.id == target,
                  requiredLabels.first?.expected.name == targetName,
                  requiredLabels.first?.expected.lifecycle == .active,
                  let mergeMutation = labelMergeMutations.first,
                  mergeMutation.id == source,
                  mergeMutation.expected.value == nil,
                  let merge = mergeMutation.post.value,
                  merge.sourceID == source,
                  merge.targetID == target,
                  merge.mergedAt == changeRecord.committedAt,
                  merge.revision == changeRecord.revision,
                  merge.changeRecordID == changeRecord.id
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label merge delta does not match its audit"
                )
            }
            var projected = before
            projected.lifecycle = .merged
            projected.updatedAt = changeRecord.committedAt
            guard projected == after else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label merge mutates unrelated source facts"
                )
            }
            try validateMergeCurrentRewrites(
                kind: .label,
                sourceID: sourceID,
                targetID: targetID,
                changeRecord: changeRecord
            )
        }
    }

    func validateHardDelete(
        _ audit: ClassificationHardDeleteAuditFact,
        changeRecord: ClassificationChangeRecord
    ) throws {
        let kind = audit.kind
        let itemID = audit.itemID
        let name = audit.name
        let lifecycle = audit.lifecycle
        let references = audit.references
        guard references.isEmpty,
              currentMutations.isEmpty,
              categoryMergeMutations.isEmpty,
              labelMergeMutations.isEmpty,
              requiredCategories.isEmpty,
              requiredLabels.isEmpty,
              appendedRelationHistory.isEmpty,
              lifecycle == .active || lifecycle == .archived
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "hard-delete audit is referenced or contains unrelated facts"
            )
        }
        switch kind {
        case .category:
            let id = try categoryID(itemID)
            guard categoryMutations.count == 1,
                  labelMutations.isEmpty,
                  categoryTombstoneMutations.count == 1,
                  labelTombstoneMutations.isEmpty,
                  let itemMutation = categoryMutations.first,
                  itemMutation.id == id,
                  itemMutation.expected.value?.name == name,
                  itemMutation.expected.value?.lifecycle == lifecycle,
                  itemMutation.post.value == nil,
                  let tombstoneMutation = categoryTombstoneMutations.first,
                  tombstoneMutation.id == id,
                  tombstoneMutation.expected.value == nil,
                  let tombstone = tombstoneMutation.post.value,
                  tombstone.itemID == id,
                  tombstone.deletedAt == changeRecord.committedAt,
                  tombstone.revision == changeRecord.revision,
                  tombstone.changeRecordID == changeRecord.id
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category hard-delete delta does not match its audit"
                )
            }
        case .label:
            let id = try labelID(itemID)
            guard labelMutations.count == 1,
                  categoryMutations.isEmpty,
                  labelTombstoneMutations.count == 1,
                  categoryTombstoneMutations.isEmpty,
                  let itemMutation = labelMutations.first,
                  itemMutation.id == id,
                  itemMutation.expected.value?.name == name,
                  itemMutation.expected.value?.lifecycle == lifecycle,
                  itemMutation.post.value == nil,
                  let tombstoneMutation = labelTombstoneMutations.first,
                  tombstoneMutation.id == id,
                  tombstoneMutation.expected.value == nil,
                  let tombstone = tombstoneMutation.post.value,
                  tombstone.itemID == id,
                  tombstone.deletedAt == changeRecord.committedAt,
                  tombstone.revision == changeRecord.revision,
                  tombstone.changeRecordID == changeRecord.id
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label hard-delete delta does not match its audit"
                )
            }
        }
    }

    func requireOnlyOneItemReplacement(kind: ClassificationItemKind) throws {
        let validItemCount = switch kind {
        case .category:
            categoryMutations.count == 1 && labelMutations.isEmpty
        case .label:
            labelMutations.count == 1 && categoryMutations.isEmpty
        }
        guard validItemCount,
              currentMutations.isEmpty,
              categoryMergeMutations.isEmpty,
              labelMergeMutations.isEmpty,
              categoryTombstoneMutations.isEmpty,
              labelTombstoneMutations.isEmpty,
              requiredCategories.isEmpty,
              requiredLabels.isEmpty,
              appendedRelationHistory.isEmpty
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "item replacement delta contains unrelated classification facts"
            )
        }
    }

    func validateCreatedItems(
        afterPreview: ClassificationSelectionPreview,
        changeRecord: ClassificationChangeRecord
    ) throws {
        let previewCategoryIDs = Set(try [afterPreview.category]
            .compactMap { $0 }
            .filter { $0.resolution == .new }
            .map { try categoryID($0.id) })
        let previewLabelIDs = Set(try afterPreview.labels
            .filter { $0.resolution == .new }
            .map { try labelID($0.id) })
        guard previewCategoryIDs == Set(categoryMutations.map(\.id)),
              previewLabelIDs == Set(labelMutations.map(\.id))
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "setCurrent created facts do not match new preview identities"
            )
        }
        for mutation in categoryMutations {
            guard let item = mutation.post.value,
                  let preview = afterPreview.category,
                  preview.id == item.id.description,
                  preview.name == item.name,
                  preview.colorHex == item.colorHex
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "setCurrent created category does not match its preview"
                )
            }
            try validateCreatedCategory(item, changeRecord: changeRecord)
        }
        for mutation in labelMutations {
            guard let item = mutation.post.value,
                  afterPreview.labels.contains(where: {
                      $0.id == item.id.description
                          && $0.name == item.name
                          && $0.colorHex == item.colorHex
                          && $0.resolution == .new
                  })
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "setCurrent created label does not match its preview"
                )
            }
            try validateCreatedLabel(item, changeRecord: changeRecord)
        }
    }

    func validateCreatedCategory(
        _ item: TaskCategory,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard item.lifecycle == .active,
              item.createdAt == changeRecord.committedAt,
              item.updatedAt == changeRecord.committedAt,
              item.nameVersions.count == 1,
              item.nameVersions.first?.validFrom == changeRecord.committedAt
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "created category facts are not tied to the classification audit"
            )
        }
    }

    func validateCreatedLabel(
        _ item: TaskLabel,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard item.lifecycle == .active,
              item.createdAt == changeRecord.committedAt,
              item.updatedAt == changeRecord.committedAt,
              item.nameVersions.count == 1,
              item.nameVersions.first?.validFrom == changeRecord.committedAt
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "created label facts are not tied to the classification audit"
            )
        }
    }

    func validateRename(
        before: TaskCategory,
        after: TaskCategory,
        changeRecord: ClassificationChangeRecord
    ) throws {
        if before.name == after.name {
            guard before == after, changeRecord.advancesStateRevision == false else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "category no-op rename changes state or advances revision"
                )
            }
            return
        }
        guard changeRecord.advancesStateRevision,
              before.colorHex == after.colorHex,
              before.lifecycle == after.lifecycle,
              before.createdAt == after.createdAt,
              after.updatedAt == changeRecord.committedAt,
              after.nameVersions.count == before.nameVersions.count + 1,
              let appended = after.nameVersions.last,
              appended.name == after.name,
              appended.canonicalKey == after.canonicalKey,
              appended.canonicalKeyVersion == after.canonicalKeyVersion,
              appended.validFrom == changeRecord.committedAt,
              appended.validUntil == nil
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "category rename facts are inconsistent"
            )
        }
        var projected = before
        guard var closed = projected.nameVersions.popLast() else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "category rename base has no current name version"
            )
        }
        closed.validUntil = changeRecord.committedAt
        projected.nameVersions.append(closed)
        projected.nameVersions.append(appended)
        projected.name = after.name
        projected.canonicalKey = after.canonicalKey
        projected.canonicalKeyVersion = after.canonicalKeyVersion
        projected.updatedAt = changeRecord.committedAt
        guard projected == after else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "category rename mutates unrelated item facts"
            )
        }
    }

    func validateRename(
        before: TaskLabel,
        after: TaskLabel,
        changeRecord: ClassificationChangeRecord
    ) throws {
        if before.name == after.name {
            guard before == after, changeRecord.advancesStateRevision == false else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "label no-op rename changes state or advances revision"
                )
            }
            return
        }
        guard changeRecord.advancesStateRevision,
              before.colorHex == after.colorHex,
              before.lifecycle == after.lifecycle,
              before.createdAt == after.createdAt,
              after.updatedAt == changeRecord.committedAt,
              after.nameVersions.count == before.nameVersions.count + 1,
              let appended = after.nameVersions.last,
              appended.name == after.name,
              appended.canonicalKey == after.canonicalKey,
              appended.canonicalKeyVersion == after.canonicalKeyVersion,
              appended.validFrom == changeRecord.committedAt,
              appended.validUntil == nil
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "label rename facts are inconsistent"
            )
        }
        var projected = before
        guard var closed = projected.nameVersions.popLast() else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "label rename base has no current name version"
            )
        }
        closed.validUntil = changeRecord.committedAt
        projected.nameVersions.append(closed)
        projected.nameVersions.append(appended)
        projected.name = after.name
        projected.canonicalKey = after.canonicalKey
        projected.canonicalKeyVersion = after.canonicalKeyVersion
        projected.updatedAt = changeRecord.committedAt
        guard projected == after else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "label rename mutates unrelated item facts"
            )
        }
    }

    func validateCurrentRewrite(
        _ mutation: ClassificationCurrentMutation,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard let post = mutation.post.value else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification current mutation must have a post state"
            )
        }
        let expected = mutation.expected.value
        if expected?.categoryID == post.categoryID {
            guard expected?.category == post.category else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "retained category relation provenance was rewritten"
                )
            }
        } else if let added = post.category {
            try validateAddedRelation(
                ClassificationRelationProvenanceFact(
                    source: added.source,
                    decisionID: added.decisionID,
                    createdAt: added.createdAt,
                    updatedAt: added.updatedAt,
                    revision: added.revision
                ),
                changeRecord: changeRecord
            )
        }

        let expectedLabels = Dictionary(
            uniqueKeysWithValues: (expected?.labels ?? []).map { ($0.labelID, $0) }
        )
        for relation in post.labels {
            if let retained = expectedLabels[relation.labelID] {
                guard retained == relation else {
                    throw ClassificationCommitEnvelopeError.malformedCommit(
                        "retained label relation provenance was rewritten"
                    )
                }
            } else {
                try validateAddedRelation(
                    ClassificationRelationProvenanceFact(
                        source: relation.source,
                        decisionID: relation.decisionID,
                        createdAt: relation.createdAt,
                        updatedAt: relation.updatedAt,
                        revision: relation.revision
                    ),
                    changeRecord: changeRecord
                )
            }
        }
    }

    func validateAddedRelation(
        _ fact: ClassificationRelationProvenanceFact,
        changeRecord: ClassificationChangeRecord
    ) throws {
        guard fact.source == changeRecord.source,
              fact.decisionID == changeRecord.decisionID,
              fact.createdAt == changeRecord.committedAt,
              fact.updatedAt == changeRecord.committedAt,
              fact.revision == changeRecord.revision
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "added relation provenance does not match the classification audit"
            )
        }
    }

    func validateMergeCurrentRewrites(
        kind: ClassificationItemKind,
        sourceID: String,
        targetID: String,
        changeRecord: ClassificationChangeRecord
    ) throws {
        for mutation in currentMutations {
            guard let expected = mutation.expected.value,
                  let post = mutation.post.value
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "merge current rewrite is missing its exact base or post state"
                )
            }
            switch kind {
            case .category:
                guard expected.categoryID?.description == sourceID,
                      post.categoryID?.description == targetID,
                      expected.labelIDs == post.labelIDs
                else {
                    throw ClassificationCommitEnvelopeError.malformedCommit(
                        "category merge rewrite does not replace source with target"
                    )
                }
            case .label:
                guard expected.labelIDs.contains(where: { $0.description == sourceID }),
                      post.labelIDs.contains(where: { $0.description == sourceID }) == false,
                      post.labelIDs.contains(where: { $0.description == targetID }),
                      expected.category == post.category
                else {
                    throw ClassificationCommitEnvelopeError.malformedCommit(
                        "label merge rewrite does not replace source with target"
                    )
                }
            }
            try validateCurrentRewrite(mutation, changeRecord: changeRecord)
        }
        try validateRemovalHistory(
            currentMutations: currentMutations,
            changeRecord: changeRecord,
            kind: kind,
            itemID: sourceID
        )
    }

    func validateRemovalHistory(
        currentMutation: ClassificationCurrentMutation,
        changeRecord: ClassificationChangeRecord,
        expectedKindAndItemIDs: [(ClassificationItemKind, String)]
    ) throws {
        guard appendedRelationHistory.count == expectedKindAndItemIDs.count else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "setCurrent removal history count is inconsistent"
            )
        }
        for (kind, itemID) in expectedKindAndItemIDs {
            let matches = appendedRelationHistory.filter {
                $0.kind == kind && $0.chainID == currentMutation.id && $0.itemID == itemID
            }
            guard matches.count == 1,
                  let history = matches.first
            else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "setCurrent removal history is missing"
                )
            }
            try validateRemovalHistoryEntry(
                history,
                expected: currentMutation.expected.value,
                changeRecord: changeRecord
            )
        }
    }

    func validateRemovalHistory(
        currentMutations: [ClassificationCurrentMutation],
        changeRecord: ClassificationChangeRecord,
        kind: ClassificationItemKind,
        itemID: String
    ) throws {
        guard appendedRelationHistory.count == currentMutations.count else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "merge removal history count is inconsistent"
            )
        }
        for mutation in currentMutations {
            let matches = appendedRelationHistory.filter {
                $0.kind == kind && $0.chainID == mutation.id && $0.itemID == itemID
            }
            guard matches.count == 1, let history = matches.first else {
                throw ClassificationCommitEnvelopeError.malformedCommit(
                    "merge removal history is missing"
                )
            }
            try validateRemovalHistoryEntry(
                history,
                expected: mutation.expected.value,
                changeRecord: changeRecord
            )
        }
    }

    func validateRemovalHistoryEntry(
        _ history: ClassificationRelationHistoryEntry,
        expected: CurrentTaskClassification?,
        changeRecord: ClassificationChangeRecord
    ) throws {
        let origin: ClassificationRelationOrigin? = switch history.kind {
        case .category:
            expected?.category.map {
                ClassificationRelationOrigin(
                    itemID: $0.categoryID.description,
                    source: $0.source,
                    decisionID: $0.decisionID,
                    createdAt: $0.createdAt,
                    revision: $0.revision
                )
            }
        case .label:
            expected?.labels.first(where: {
                $0.labelID.description == history.itemID
            }).map {
                ClassificationRelationOrigin(
                    itemID: $0.labelID.description,
                    source: $0.source,
                    decisionID: $0.decisionID,
                    createdAt: $0.createdAt,
                    revision: $0.revision
                )
            }
        }
        guard let origin,
              history.itemID == origin.itemID,
              history.originSource == origin.source,
              history.originDecisionID == origin.decisionID,
              history.createdAt == origin.createdAt,
              history.createdRevision == origin.revision,
              history.removedBySource == changeRecord.source,
              history.removedByDecisionID == changeRecord.decisionID,
              history.removedAt == changeRecord.committedAt,
              history.removedRevision == changeRecord.revision
        else {
            throw ClassificationCommitEnvelopeError.malformedCommit(
                "classification removal history provenance is inconsistent"
            )
        }
    }
}

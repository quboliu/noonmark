import Foundation
import NoonmarkCore

public enum ClassificationFact<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case presence
        case value
    }

    private enum Presence: String, Codable {
        case absent
        case present
    }

    case absent
    case present(Value)

    public init(_ value: Value?) {
        self = value.map(Self.present) ?? .absent
    }

    public var value: Value? {
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
                    "absent classification fact must not carry a value"
                )
            }
            self = .absent
        case .present:
            self = .present(try container.decode(Value.self, forKey: .value))
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

public struct ClassificationValueMutation<ID: Codable & Equatable & Sendable, Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let id: ID
    public let expected: ClassificationFact<Value>
    public let post: ClassificationFact<Value>

    public init(
        id: ID,
        expected: ClassificationFact<Value>,
        post: ClassificationFact<Value>
    ) {
        self.id = id
        self.expected = expected
        self.post = post
    }
}

public typealias ClassificationCategoryMutation =
    ClassificationValueMutation<TaskCategoryID, TaskCategory>
public typealias ClassificationLabelMutation =
    ClassificationValueMutation<TaskLabelID, TaskLabel>
public typealias ClassificationCurrentMutation =
    ClassificationValueMutation<TaskChainID, CurrentTaskClassification>
public typealias ClassificationCategoryMergeMutation =
    ClassificationValueMutation<TaskCategoryID, TaskCategoryMerge>
public typealias ClassificationLabelMergeMutation =
    ClassificationValueMutation<TaskLabelID, TaskLabelMerge>
public typealias ClassificationCategoryTombstoneMutation =
    ClassificationValueMutation<TaskCategoryID, TaskCategoryDeletionTombstone>
public typealias ClassificationLabelTombstoneMutation =
    ClassificationValueMutation<TaskLabelID, TaskLabelDeletionTombstone>

public struct ClassificationRequiredCategoryFact: Codable, Equatable, Sendable {
    public let id: TaskCategoryID
    public let expected: TaskCategory

    public init(id: TaskCategoryID, expected: TaskCategory) {
        self.id = id
        self.expected = expected
    }
}

public struct ClassificationRequiredLabelFact: Codable, Equatable, Sendable {
    public let id: TaskLabelID
    public let expected: TaskLabel

    public init(id: TaskLabelID, expected: TaskLabel) {
        self.id = id
        self.expected = expected
    }
}

public struct ClassificationStateMutationDelta: Codable, Equatable, Sendable {
    public let predecessorChangeRecordIDs: [UUID]
    public let categoryMutations: [ClassificationCategoryMutation]
    public let labelMutations: [ClassificationLabelMutation]
    public let currentMutations: [ClassificationCurrentMutation]
    public let categoryMergeMutations: [ClassificationCategoryMergeMutation]
    public let labelMergeMutations: [ClassificationLabelMergeMutation]
    public let categoryTombstoneMutations: [ClassificationCategoryTombstoneMutation]
    public let labelTombstoneMutations: [ClassificationLabelTombstoneMutation]
    public let requiredCategories: [ClassificationRequiredCategoryFact]
    public let requiredLabels: [ClassificationRequiredLabelFact]
    public let appendedRelationHistory: [ClassificationRelationHistoryEntry]

    public init(
        predecessorChangeRecordIDs: [UUID] = [],
        categoryMutations: [ClassificationCategoryMutation] = [],
        labelMutations: [ClassificationLabelMutation] = [],
        currentMutations: [ClassificationCurrentMutation] = [],
        categoryMergeMutations: [ClassificationCategoryMergeMutation] = [],
        labelMergeMutations: [ClassificationLabelMergeMutation] = [],
        categoryTombstoneMutations: [ClassificationCategoryTombstoneMutation] = [],
        labelTombstoneMutations: [ClassificationLabelTombstoneMutation] = [],
        requiredCategories: [ClassificationRequiredCategoryFact] = [],
        requiredLabels: [ClassificationRequiredLabelFact] = [],
        appendedRelationHistory: [ClassificationRelationHistoryEntry] = []
    ) {
        self.predecessorChangeRecordIDs = predecessorChangeRecordIDs
        self.categoryMutations = categoryMutations
        self.labelMutations = labelMutations
        self.currentMutations = currentMutations
        self.categoryMergeMutations = categoryMergeMutations
        self.labelMergeMutations = labelMergeMutations
        self.categoryTombstoneMutations = categoryTombstoneMutations
        self.labelTombstoneMutations = labelTombstoneMutations
        self.requiredCategories = requiredCategories
        self.requiredLabels = requiredLabels
        self.appendedRelationHistory = appendedRelationHistory
    }
}

public enum ClassificationCommitDelta: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case setCurrent
        case create
        case rename
        case categoryPresentationApproval
        case lifecycle
        case merge
        case hardDelete
    }

    case setCurrent(ClassificationStateMutationDelta)
    case create(ClassificationStateMutationDelta)
    case rename(ClassificationStateMutationDelta)
    case categoryPresentationApproval(ClassificationStateMutationDelta)
    case lifecycle(ClassificationStateMutationDelta)
    case merge(ClassificationStateMutationDelta)
    case hardDelete(ClassificationStateMutationDelta)

    public var mutation: ClassificationStateMutationDelta {
        switch self {
        case let .setCurrent(mutation),
             let .create(mutation),
             let .rename(mutation),
             let .categoryPresentationApproval(mutation),
             let .lifecycle(mutation),
             let .merge(mutation),
             let .hardDelete(mutation):
            mutation
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decode(
            ClassificationStateMutationDelta.self,
            forKey: .payload
        )
        self = switch try container.decode(Kind.self, forKey: .kind) {
        case .setCurrent:
            .setCurrent(payload)
        case .create:
            .create(payload)
        case .rename:
            .rename(payload)
        case .categoryPresentationApproval:
            .categoryPresentationApproval(payload)
        case .lifecycle:
            .lifecycle(payload)
        case .merge:
            .merge(payload)
        case .hardDelete:
            .hardDelete(payload)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind = switch self {
        case .setCurrent:
            .setCurrent
        case .create:
            .create
        case .rename:
            .rename
        case .categoryPresentationApproval:
            .categoryPresentationApproval
        case .lifecycle:
            .lifecycle
        case .merge:
            .merge
        case .hardDelete:
            .hardDelete
        }
        try container.encode(kind, forKey: .kind)
        try container.encode(mutation, forKey: .payload)
    }
}

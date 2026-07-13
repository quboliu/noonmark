import Foundation

public enum AIAuthorityMode: String, Codable, Hashable, Sendable {
    case suggestOnly
    case confirmEachOperation
    case delegatedHousekeeper
}

public enum AIOperationPermission: String, Codable, Hashable, Sendable {
    case createPoolTask
    case addSubtask
    case scheduleFromPool
    case continueTrace
    case abandonChain
    case assignLabel
    case updateDailyReview
}

public struct AIDelegationPolicy: Codable, Equatable, Sendable {
    public var mode: AIAuthorityMode
    public var allowedOperations: Set<AIOperationPermission>
    public var maxOperationsPerRun: Int
    public var expiresAt: Date?
    public var requiresPostRunReview: Bool

    public init(
        mode: AIAuthorityMode,
        allowedOperations: Set<AIOperationPermission> = [],
        maxOperationsPerRun: Int = 0,
        expiresAt: Date? = nil,
        requiresPostRunReview: Bool = true
    ) {
        self.mode = mode
        self.allowedOperations = allowedOperations
        self.maxOperationsPerRun = maxOperationsPerRun
        self.expiresAt = expiresAt
        self.requiresPostRunReview = requiresPostRunReview
    }

    public static var suggestOnly: AIDelegationPolicy {
        AIDelegationPolicy(mode: .suggestOnly)
    }

    public static var confirmEachOperation: AIDelegationPolicy {
        AIDelegationPolicy(mode: .confirmEachOperation)
    }

    public static func delegatedHousekeeper(
        allowedOperations: Set<AIOperationPermission>,
        maxOperationsPerRun: Int,
        expiresAt: Date?,
        requiresPostRunReview: Bool = true
    ) -> AIDelegationPolicy {
        AIDelegationPolicy(
            mode: .delegatedHousekeeper,
            allowedOperations: allowedOperations,
            maxOperationsPerRun: maxOperationsPerRun,
            expiresAt: expiresAt,
            requiresPostRunReview: requiresPostRunReview
        )
    }

    public func allowsAutomaticExecution(of operation: AIProposedOperation, at now: Date = Date()) -> Bool {
        guard mode == .delegatedHousekeeper else {
            return false
        }
        guard maxOperationsPerRun > 0 else {
            return false
        }
        if let expiresAt, now >= expiresAt {
            return false
        }
        return allowedOperations.contains(operation.permission)
    }
}

public extension AIProposedOperation {
    var permission: AIOperationPermission {
        switch self {
        case .createPoolTask:
            return .createPoolTask
        case .addSubtask:
            return .addSubtask
        case .scheduleFromPool:
            return .scheduleFromPool
        case .continueTrace:
            return .continueTrace
        case .abandonChain:
            return .abandonChain
        case .assignLabel:
            return .assignLabel
        case .updateDailyReview:
            return .updateDailyReview
        }
    }
}

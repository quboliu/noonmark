import Foundation
import NoonmarkCore

public enum ZhulongApplicationMutationClockError: Error, Equatable {
    case invalidFrontier
    case unrepresentableNextInstant
}

public struct ZhulongApplicationMutationTimeline: Equatable, Sendable {
    public let authorizationAt: Date?
    public let applyAt: Date

    public init(
        reference: Date,
        engine: NoonmarkEngine,
        selectedSession: ZhulongSession,
        pendingApplication: ZhulongPendingApplication?,
        requiresAuthorization: Bool
    ) throws {
        var sidecarFrontiers = [
            reference,
            selectedSession.latestActivityAt
        ]
        var engineCandidates = [
            try engine.nextMutationDate(reference: reference)
        ]
        if let pendingApplication {
            let pendingEngine = try NoonmarkEngine(
                snapshot: pendingApplication.afterSnapshot
            )
            sidecarFrontiers.append(contentsOf: [
                pendingApplication.createdAt,
                pendingApplication.afterSession.latestActivityAt
            ])
            engineCandidates.append(
                try pendingEngine.nextMutationDate(reference: reference)
            )
        }
        guard sidecarFrontiers.allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }), engineCandidates.allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }), let sidecarFrontier = sidecarFrontiers.max(),
              let engineCandidate = engineCandidates.max()
        else {
            throw ZhulongApplicationMutationClockError.invalidFrontier
        }
        let firstApplicationInstant = max(
            try Self.nextInstant(after: sidecarFrontier),
            engineCandidate
        )

        if requiresAuthorization {
            authorizationAt = firstApplicationInstant
            applyAt = try Self.nextInstant(after: firstApplicationInstant)
        } else {
            authorizationAt = nil
            applyAt = firstApplicationInstant
        }
    }

    private static func nextInstant(after frontier: Date) throws -> Date {
        let seconds = frontier.timeIntervalSinceReferenceDate
        let nextSeconds = seconds.nextUp
        guard seconds.isFinite, nextSeconds.isFinite else {
            throw ZhulongApplicationMutationClockError
                .unrepresentableNextInstant
        }
        let next = Date(timeIntervalSinceReferenceDate: nextSeconds)
        guard next > frontier else {
            throw ZhulongApplicationMutationClockError
                .unrepresentableNextInstant
        }
        return next
    }
}

public enum ZhulongPendingApplicationRecoveryError: Error, Equatable {
    case applicationAlreadyPending
    case snapshotConflict
}

public struct ZhulongPendingApplicationRecoveryPlan: Equatable, Sendable {
    public let recoveredSnapshot: NoonmarkSnapshot
    public let persistenceChangedAt: Date?

    public init(
        currentEngine: NoonmarkEngine,
        pendingApplication: ZhulongPendingApplication
    ) throws {
        switch try ZhulongEnginePersistenceInspector.resolve(
            persistedEngine: currentEngine,
            pendingApplication: pendingApplication
        ) {
        case .after:
            recoveredSnapshot = currentEngine.snapshot()
            persistenceChangedAt = nil
        case .before:
            recoveredSnapshot = pendingApplication.afterSnapshot
            persistenceChangedAt = pendingApplication.createdAt
        case .conflict:
            throw ZhulongPendingApplicationRecoveryError.snapshotConflict
        }
    }
}

public enum ZhulongPendingSessionRecoveryAction: Equatable, Sendable {
    case replaceExpectedBefore
    case alreadyAfter
}

public struct ZhulongPendingSessionRecoveryPlan: Equatable, Sendable {
    public let action: ZhulongPendingSessionRecoveryAction

    public init(
        persistedSession: ZhulongSession,
        pendingApplication: ZhulongPendingApplication
    ) throws {
        if persistedSession == pendingApplication.afterSession {
            action = .alreadyAfter
        } else if persistedSession == pendingApplication.beforeSession {
            action = .replaceExpectedBefore
        } else {
            throw ZhulongSidecarRepositoryError.sessionConflict
        }
    }
}

public enum ZhulongPendingSessionReconciler {
    @discardableResult
    public static func reconcile(
        pendingApplication: ZhulongPendingApplication,
        loadPersistedSession: () throws -> ZhulongSession,
        replaceExpectedSession: (
            _ replacement: ZhulongSession,
            _ expected: ZhulongSession
        ) throws -> Void
    ) throws -> ZhulongPendingSessionRecoveryAction {
        let plan = try ZhulongPendingSessionRecoveryPlan(
            persistedSession: try loadPersistedSession(),
            pendingApplication: pendingApplication
        )
        if plan.action == .replaceExpectedBefore {
            try replaceExpectedSession(
                pendingApplication.afterSession,
                pendingApplication.beforeSession
            )
        }
        return plan.action
    }
}

public enum ZhulongPendingApplicationMutationGate {
    public static func validate(
        _ pendingApplication: ZhulongPendingApplication?
    ) throws {
        guard pendingApplication == nil else {
            throw ZhulongPendingApplicationRecoveryError
                .applicationAlreadyPending
        }
    }
}

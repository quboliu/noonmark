import Foundation

public protocol ZhulongSessionRepository: Sendable {
    func save(_ session: ZhulongSession) throws
    func save(
        _ replacement: ZhulongSession,
        replacing expected: ZhulongSession
    ) throws
    func load(_ id: ZhulongSessionID) throws -> ZhulongSession
}

public enum ZhulongProviderOrchestrationError: Error, Equatable, Sendable {
    case providerIdentityMismatch
    case providerFailed(String)
    case providerRunStillActive
    case providerRunSuperseded
}

private enum ZhulongProviderRunAuthority {
    case conversation
    case planning(ZhulongPlanningDelegationID)
}

private struct ZhulongProviderRunTiming {
    let startedAt: Date
    let completedAt: @Sendable () -> Date
}

public actor ZhulongProviderOrchestrator {
    private let repository: any ZhulongSessionRepository
    private var activeSessionIDs: Set<ZhulongSessionID> = []

    public init(repository: any ZhulongSessionRepository) {
        self.repository = repository
    }

    public func run(
        sessionID: ZhulongSessionID,
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider,
        startedAt: Date = Date(),
        completedAt: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ZhulongSession {
        try await execute(
            sessionID: sessionID,
            payload: payload,
            provider: provider,
            authority: .conversation,
            timing: ZhulongProviderRunTiming(startedAt: startedAt, completedAt: completedAt)
        )
    }

    public func runPlanning(
        sessionID: ZhulongSessionID,
        delegationID: ZhulongPlanningDelegationID,
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider,
        startedAt: Date = Date(),
        completedAt: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ZhulongSession {
        try await execute(
            sessionID: sessionID,
            payload: payload,
            provider: provider,
            authority: .planning(delegationID),
            timing: ZhulongProviderRunTiming(startedAt: startedAt, completedAt: completedAt)
        )
    }

    private func execute(
        sessionID: ZhulongSessionID,
        payload: ZhulongProviderPayload,
        provider: any ZhulongProvider,
        authority: ZhulongProviderRunAuthority,
        timing: ZhulongProviderRunTiming
    ) async throws -> ZhulongSession {
        guard activeSessionIDs.contains(sessionID) == false else {
            throw ZhulongProviderOrchestrationError.providerRunStillActive
        }
        let sessionBeforeRun = try repository.load(sessionID)
        var session = sessionBeforeRun
        guard session.authorization?.providerIdentity == provider.configurationIdentity else {
            throw ZhulongProviderOrchestrationError.providerIdentityMismatch
        }

        let request = try beginRun(
            authority: authority,
            session: &session,
            payload: payload,
            providerIdentity: provider.configurationIdentity,
            startedAt: timing.startedAt
        )
        try repository.save(session, replacing: sessionBeforeRun)
        activeSessionIDs.insert(sessionID)
        defer { activeSessionIDs.remove(sessionID) }

        let result = await provider.complete(request)
        let sessionBeforeResponse = try repository.load(sessionID)
        session = sessionBeforeResponse
        guard session.providerSends.last(where: { $0.runID == request.runID })?.status == .running else {
            throw ZhulongProviderOrchestrationError.providerRunSuperseded
        }
        let resultDate = strictlyLaterDate(
            timing.completedAt(),
            than: max(request.startedAt, session.latestActivityAt)
        )
        switch result {
        case let .success(response):
            do {
                switch authority {
                case .conversation:
                    try session.recordProviderResponse(
                        response,
                        runID: request.runID,
                        now: resultDate
                    )
                case .planning:
                    try session.recordPlanningProviderResponse(
                        response,
                        runID: request.runID,
                        now: resultDate
                    )
                }
            } catch {
                let failure = ZhulongProviderFailure(
                    code: "invalid_provider_response",
                    message: "Provider 返回了无效内容"
                )
                try session.recordProviderFailure(failure, runID: request.runID, now: resultDate)
                try repository.save(
                    session,
                    replacing: sessionBeforeResponse
                )
                throw ZhulongProviderOrchestrationError.providerFailed(failure.code)
            }
            try repository.save(
                session,
                replacing: sessionBeforeResponse
            )
            return session
        case let .failure(failure):
            let recordedFailure = validatedFailure(failure)
            try session.recordProviderFailure(
                recordedFailure,
                runID: request.runID,
                now: resultDate
            )
            try repository.save(
                session,
                replacing: sessionBeforeResponse
            )
            throw ZhulongProviderOrchestrationError.providerFailed(recordedFailure.code)
        }
    }

    public func correctPlanningSource(
        sessionID: ZhulongSessionID,
        sourceEntryID: ZhulongSessionEntryID,
        replacementContent: String,
        now: Date = Date()
    ) throws -> ZhulongSession {
        let persistedSession = try repository.load(sessionID)
        var session = persistedSession
        var correctionDate = now
        if session.phase == .providerRunning {
            guard let send = session.providerSends.last,
                  let contract = send.planningContract
            else {
                throw ZhulongProviderOrchestrationError.providerRunStillActive
            }
            let sourceIsBound = session.currentPlanningBrief?.id == contract.briefID &&
                session.currentPlanningBrief?.sourceEntryIDs.contains(sourceEntryID) == true
            if sourceIsBound {
                try session.recordProviderFailure(
                    ZhulongProviderFailure(
                        code: "planning_source_corrected",
                        message: "规划来源已被用户更正"
                    ),
                    runID: send.runID,
                    now: now
                )
                correctionDate = strictlyLaterDate(now, than: now)
            }
        }
        _ = try session.correctEntry(
            sourceEntryID,
            author: .user,
            replacementContent: replacementContent,
            now: correctionDate
        )
        try repository.save(session, replacing: persistedSession)
        return session
    }

    private func beginRun(
        authority: ZhulongProviderRunAuthority,
        session: inout ZhulongSession,
        payload: ZhulongProviderPayload,
        providerIdentity: ZhulongProviderConfigurationIdentity,
        startedAt: Date
    ) throws -> ZhulongProviderRequest {
        switch authority {
        case .conversation:
            try session.beginProviderRun(
                payload: payload,
                providerIdentity: providerIdentity,
                now: startedAt
            )
        case let .planning(delegationID):
            try session.beginPlanningProviderRun(
                delegationID: delegationID,
                payload: payload,
                providerIdentity: providerIdentity,
                now: startedAt
            )
        }
    }

    public func recoverInterruptedRun(
        sessionID: ZhulongSessionID,
        now: Date = Date()
    ) throws -> ZhulongSession {
        guard activeSessionIDs.contains(sessionID) == false else {
            throw ZhulongProviderOrchestrationError.providerRunStillActive
        }
        let persistedSession = try repository.load(sessionID)
        var session = persistedSession
        try session.recoverInterruptedProviderRun(now: now)
        try repository.save(session, replacing: persistedSession)
        return session
    }

    private func validatedFailure(_ failure: ZhulongProviderFailure) -> ZhulongProviderFailure {
        guard failure.code.isEmpty == false, failure.message.isEmpty == false else {
            return ZhulongProviderFailure(
                code: "provider_failed",
                message: "Provider 请求失败"
            )
        }
        return failure
    }

    private func strictlyLaterDate(_ candidate: Date, than earlier: Date) -> Date {
        guard candidate <= earlier else { return candidate }
        return Date(
            timeIntervalSinceReferenceDate: earlier.timeIntervalSinceReferenceDate.nextUp
        )
    }
}

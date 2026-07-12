import Foundation

public protocol ZhulongSessionRepository: Sendable {
    func save(_ session: ZhulongSession) throws
    func load(_ id: ZhulongSessionID) throws -> ZhulongSession
}

public enum ZhulongProviderOrchestrationError: Error, Equatable, Sendable {
    case providerIdentityMismatch
    case providerFailed(String)
}

public actor ZhulongProviderOrchestrator {
    private let repository: any ZhulongSessionRepository

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
        var session = try repository.load(sessionID)
        guard session.authorization?.providerIdentity == provider.configurationIdentity else {
            throw ZhulongProviderOrchestrationError.providerIdentityMismatch
        }

        let request = try session.beginProviderRun(
            payload: payload,
            providerIdentity: provider.configurationIdentity,
            now: startedAt
        )
        try repository.save(session)

        let result = await provider.complete(request)
        let resultDate = max(completedAt(), startedAt)
        switch result {
        case let .success(response):
            do {
                try session.recordProviderResponse(
                    response,
                    runID: request.runID,
                    now: resultDate
                )
            } catch ZhulongSessionError.invalidProviderResponse {
                let failure = ZhulongProviderFailure(
                    code: "invalid_provider_response",
                    message: "Provider 返回了无效内容"
                )
                try session.recordProviderFailure(failure, runID: request.runID, now: resultDate)
                try repository.save(session)
                throw ZhulongProviderOrchestrationError.providerFailed(failure.code)
            }
            try repository.save(session)
            return session
        case let .failure(failure):
            let recordedFailure = validatedFailure(failure)
            try session.recordProviderFailure(
                recordedFailure,
                runID: request.runID,
                now: resultDate
            )
            try repository.save(session)
            throw ZhulongProviderOrchestrationError.providerFailed(recordedFailure.code)
        }
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
}

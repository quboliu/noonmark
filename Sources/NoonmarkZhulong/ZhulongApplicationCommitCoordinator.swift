public enum ZhulongApplicationCommitProgress: Equatable, Sendable {
    case beforeEngine
    case enginePersistenceUnresolved
    case enginePersisted
    case sessionPersisted
    case completed
}

public enum ZhulongEnginePersistenceResolution: Equatable, Sendable {
    case before
    case after
    case conflict
}

public enum ZhulongApplicationCommitFailureStage: Equatable, Sendable {
    case enginePersistence
    case sessionPersistence
    case journalClear
}

public struct ZhulongApplicationCommitOutcome {
    public let progress: ZhulongApplicationCommitProgress
    public let failureStage: ZhulongApplicationCommitFailureStage?
    public let underlyingError: (any Error)?
    public let cleanupError: (any Error)?
    public let enginePersistenceFailureResolution:
        ZhulongEnginePersistenceResolution?
    public let recoveredEnginePersistenceError: (any Error)?
    public let reconciliationError: (any Error)?
    public let prepareJournal: ZhulongApplicationJournalCommitOutcome
    public let clearJournal: ZhulongApplicationJournalCommitOutcome?

    public var durableEngineIsAfter: Bool {
        switch progress {
        case .beforeEngine, .enginePersistenceUnresolved:
            false
        case .enginePersisted, .sessionPersisted, .completed:
            true
        }
    }

    public var commitCompleted: Bool {
        progress == .completed
            && failureStage == nil
            && recoveredEnginePersistenceError == nil
            && recoveredJournalMutation == false
    }

    public var recoveredJournalMutation: Bool {
        Self.isRecovered(prepareJournal)
            || clearJournal.map(Self.isRecovered) == true
    }

    fileprivate init(
        progress: ZhulongApplicationCommitProgress,
        failureStage: ZhulongApplicationCommitFailureStage? = nil,
        underlyingError: (any Error)? = nil,
        cleanupError: (any Error)? = nil,
        enginePersistenceFailureResolution:
        ZhulongEnginePersistenceResolution? = nil,
        recoveredEnginePersistenceError: (any Error)? = nil,
        reconciliationError: (any Error)? = nil,
        prepareJournal: ZhulongApplicationJournalCommitOutcome,
        clearJournal: ZhulongApplicationJournalCommitOutcome? = nil
    ) {
        self.progress = progress
        self.failureStage = failureStage
        self.underlyingError = underlyingError
        self.cleanupError = cleanupError
        self.enginePersistenceFailureResolution =
            enginePersistenceFailureResolution
        self.recoveredEnginePersistenceError = recoveredEnginePersistenceError
        self.reconciliationError = reconciliationError
        self.prepareJournal = prepareJournal
        self.clearJournal = clearJournal
    }

    private static func isRecovered(
        _ outcome: ZhulongApplicationJournalCommitOutcome
    ) -> Bool {
        if case .recoveredCommitted = outcome { return true }
        return false
    }
}

public enum ZhulongApplicationCommitCoordinator {
    public static func finish(
        prepareJournal: ZhulongApplicationJournalCommitOutcome = .committed,
        engineAlreadyPersisted: Bool,
        persistEngine: () throws -> Void,
        reconcileEnginePersistenceFailure: () throws ->
            ZhulongEnginePersistenceResolution = {
                throw ZhulongCommitReconciliationError
                    .durableEngineStateUnavailable
        },
        persistSession: () throws -> Void,
        clearJournal: (
            ZhulongJournalClearRequirement
        ) throws -> ZhulongApplicationJournalCommitOutcome
    ) -> ZhulongApplicationCommitOutcome {
        var recoveredEnginePersistenceError: (any Error)?
        var enginePersistenceFailureResolution:
            ZhulongEnginePersistenceResolution?
        if engineAlreadyPersisted == false {
            do {
                try persistEngine()
            } catch let engineError {
                let resolution: ZhulongEnginePersistenceResolution
                do {
                    resolution = try reconcileEnginePersistenceFailure()
                    enginePersistenceFailureResolution = resolution
                } catch let reconciliationError {
                    return ZhulongApplicationCommitOutcome(
                        progress: .enginePersistenceUnresolved,
                        failureStage: .enginePersistence,
                        underlyingError: engineError,
                        reconciliationError: reconciliationError,
                        prepareJournal: prepareJournal
                    )
                }
                guard resolution != .conflict else {
                    return ZhulongApplicationCommitOutcome(
                        progress: .enginePersistenceUnresolved,
                        failureStage: .enginePersistence,
                        underlyingError: engineError,
                        enginePersistenceFailureResolution: resolution,
                        prepareJournal: prepareJournal
                    )
                }
                if resolution == .after {
                    recoveredEnginePersistenceError = engineError
                } else {
                    let cleanupError: (any Error)?
                    let cleanupOutcome: ZhulongApplicationJournalCommitOutcome?
                    do {
                        cleanupOutcome = try clearJournal(.beforeSession)
                        cleanupError = nil
                    } catch let journalError {
                        cleanupOutcome = nil
                        cleanupError = journalError
                    }
                    return ZhulongApplicationCommitOutcome(
                        progress: .beforeEngine,
                        failureStage: .enginePersistence,
                        underlyingError: engineError,
                        cleanupError: cleanupError,
                        enginePersistenceFailureResolution: resolution,
                        prepareJournal: prepareJournal,
                        clearJournal: cleanupOutcome
                    )
                }
            }
        }

        do {
            try persistSession()
        } catch {
            return ZhulongApplicationCommitOutcome(
                progress: .enginePersisted,
                failureStage: .sessionPersistence,
                underlyingError: error,
                enginePersistenceFailureResolution:
                enginePersistenceFailureResolution,
                recoveredEnginePersistenceError:
                recoveredEnginePersistenceError,
                prepareJournal: prepareJournal
            )
        }

        let clearOutcome: ZhulongApplicationJournalCommitOutcome
        do {
            clearOutcome = try clearJournal(.afterSession)
        } catch {
            return ZhulongApplicationCommitOutcome(
                progress: .sessionPersisted,
                failureStage: .journalClear,
                underlyingError: error,
                enginePersistenceFailureResolution:
                enginePersistenceFailureResolution,
                recoveredEnginePersistenceError:
                recoveredEnginePersistenceError,
                prepareJournal: prepareJournal
            )
        }

        return ZhulongApplicationCommitOutcome(
            progress: .completed,
            enginePersistenceFailureResolution:
            enginePersistenceFailureResolution,
            recoveredEnginePersistenceError: recoveredEnginePersistenceError,
            prepareJournal: prepareJournal,
            clearJournal: clearOutcome
        )
    }
}

public enum ZhulongCommitReconciliationError: Error, Equatable {
    case durableEngineStateUnavailable
}

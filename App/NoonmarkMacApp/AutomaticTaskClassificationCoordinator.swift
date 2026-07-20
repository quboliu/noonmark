import CryptoKit
import Foundation
import NoonmarkAI
@_spi(AutomaticClassificationJobAuthority) import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkStorage

struct AutomaticClassificationOperationalClock {
    static let system = Self(now: { Date() })

    private let nowValue: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        nowValue = now
    }

    func now() -> Date {
        nowValue()
    }
}

enum AutomaticClassificationPresentationStatus: Equatable {
    case working
    case waitingForConfiguration
    case waitingForDecision
    case providerPaused
    case failed
}

struct AutomaticClassificationBacklogPrompt: Equatable {
    let count: Int
}

struct AutomaticClassificationCircuitPresentation: Equatable {
    let waitingCount: Int
    let failureCode: AutomaticClassificationJobErrorCode
}

enum AutomaticClassificationBacklogUserDecision {
    case startExisting
    case futureOnly
    case later
}

enum AutomaticClassificationAppError: Error {
    case persistenceUnavailable
    case providerUnavailable
    case invalidCatalog
    case invalidCheckpoint
    case staleContext
}

@MainActor
enum AutomaticClassificationContentionE2EEvidence {
    enum Step: String {
        case providerReconciliation = "provider-reconciliation"
        case proposalCheckpoint = "proposal-checkpoint"
        case workerStorage = "worker-storage"
    }

    static func record(_ step: Step) {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              AppLaunchArguments.contains(
                  "--e2e-automatic-classification-contention"
              ),
              let path = AppLaunchArguments.value(
                  after: "--e2e-automatic-classification-contention-marker-url"
              ),
              path.isEmpty == false
        else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try step.rawValue.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("Noonmark automatic classification E2E marker write failed")
        }
    }
}

private struct AutomaticClassificationProposalCheckpoint: Codable {
    static let currentVersion = 1

    let version: Int
    let proposal: AutomaticTaskClassificationProposal

    private init(proposal: AutomaticTaskClassificationProposal) {
        version = Self.currentVersion
        self.proposal = proposal
    }

    static func encode(
        _ proposal: AutomaticTaskClassificationProposal
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Self(proposal: proposal))
    }

    static func decode(_ data: Data) throws -> AutomaticTaskClassificationProposal {
        let checkpoint = try JSONDecoder().decode(Self.self, from: data)
        guard checkpoint.version == Self.currentVersion,
              try encode(checkpoint.proposal) == data
        else {
            throw AutomaticClassificationAppError.invalidCheckpoint
        }
        return checkpoint.proposal
    }
}

private enum AutomaticClassificationProviderFailureResolution {
    case invalidResponse
    case credentialsRejected
    case rateLimited(retryDelay: TimeInterval)
    case transientFailure(retryDelay: TimeInterval)

    func storageOutcome(
        now: Date
    ) -> AutomaticClassificationProviderAttemptOutcome {
        switch self {
        case .invalidResponse:
            .invalidResponse
        case .credentialsRejected:
            .credentialsRejected
        case let .rateLimited(retryDelay):
            .rateLimited(retryAt: now.addingTimeInterval(retryDelay))
        case let .transientFailure(retryDelay):
            .transientFailure(retryAt: now.addingTimeInterval(retryDelay))
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalidResponse: "invalid-response"
        case .credentialsRejected: "credentials-rejected"
        case .rateLimited: "rate-limited"
        case .transientFailure: "transient-failure"
        }
    }
}

private enum AutomaticClassificationWorkerDirective {
    case proceed
    case restartLoop
    case stop
}

private struct AutomaticClassificationCatalogHandles {
    let input: AutomaticTaskClassificationInput
    let categoryIDsByHandle: [String: TaskCategoryID]
    let labelIDsByHandle: [String: TaskLabelID]

    init(context: AutomaticTaskClassificationContext) throws {
        let categories = context.catalog.categories.sorted { $0.id < $1.id }
        let labels = context.catalog.labels.sorted { $0.id < $1.id }

        var categoryIDsByHandle: [String: TaskCategoryID] = [:]
        let categoryItems = try categories.enumerated().map { index, item in
            guard let id = UUID(uuidString: item.id) else {
                throw AutomaticClassificationAppError.invalidCatalog
            }
            let handle = "c\(index + 1)"
            categoryIDsByHandle[handle] = TaskCategoryID(id)
            return AutomaticTaskClassificationCatalogItem(
                handle: handle,
                displayName: item.name
            )
        }

        var labelIDsByHandle: [String: TaskLabelID] = [:]
        let labelItems = try labels.enumerated().map { index, item in
            guard let id = UUID(uuidString: item.id) else {
                throw AutomaticClassificationAppError.invalidCatalog
            }
            let handle = "l\(index + 1)"
            labelIDsByHandle[handle] = TaskLabelID(id)
            return AutomaticTaskClassificationCatalogItem(
                handle: handle,
                displayName: item.name
            )
        }

        input = AutomaticTaskClassificationInput(
            title: context.taskTitle,
            description: context.taskDescription,
            catalog: AutomaticTaskClassificationCatalog(
                revision: context.authority.catalogDigest,
                categories: categoryItems,
                labels: labelItems
            )
        )
        self.categoryIDsByHandle = categoryIDsByHandle
        self.labelIDsByHandle = labelIDsByHandle
    }

    func applicationProposal(
        from proposal: AutomaticTaskClassificationProposal
    ) throws -> AutomaticClassificationApplicationProposal {
        let category: TaskCategoryChoice = switch proposal.category {
        case let .reuse(handle):
            if let id = categoryIDsByHandle[handle] {
                .existing(id)
            } else {
                throw AutomaticClassificationAppError.invalidCatalog
            }
        case let .create(name):
            .new(
                name: name,
                colorHex: Self.color(for: name, palette: Self.categoryPalette)
            )
        }
        let labels: [TaskLabelChoice] = try proposal.labels.map { choice in
            switch choice {
            case let .reuse(handle):
                if let id = labelIDsByHandle[handle] {
                    return .existing(id)
                }
                throw AutomaticClassificationAppError.invalidCatalog
            case let .create(name):
                return .new(
                    name: name,
                    colorHex: Self.color(for: name, palette: Self.labelPalette)
                )
            }
        }
        return AutomaticClassificationApplicationProposal(
            category: category,
            labels: labels
        )
    }

    private static let categoryPalette = [
        "#D87831", "#2A6FDB", "#7A5AF8", "#0E9488", "#C0446E"
    ]
    private static let labelPalette = [
        "#0E9488", "#2A6FDB", "#7A5AF8", "#D87831", "#C0446E"
    ]

    private static func color(for name: String, palette: [String]) -> String {
        let canonical = ClassificationNameCanonicalizer.displayName(name)
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let firstByte = Array(digest)[0]
        return palette[Int(firstByte) % palette.count]
    }
}

@MainActor
extension NoonmarkStore {
    private static var automaticClassificationClaimLease: TimeInterval { 15 }
    private static var automaticClassificationContentionInitialDelay: TimeInterval { 0.05 }
    private static var automaticClassificationContentionMaximumDelay: TimeInterval { 1 }

    func automaticClassificationStatus(
        for chainID: TaskChainID
    ) -> AutomaticClassificationPresentationStatus? {
        automaticClassificationStatusByChainID[chainID]
    }

    func retryAutomaticClassification(for chainID: TaskChainID) {
        guard let automaticClassificationJobRepository else { return }
        do {
            let failed = try automaticClassificationJobRepository
                .jobs(states: [.failed])
                .filter { $0.chainID == chainID }
                .max { $0.generation < $1.generation }
            guard let failed else { return }
            let now = automaticClassificationOperationalClock.now()
            try automaticClassificationJobRepository.retry(
                failed.fence,
                to: automaticClassificationProviderIsReady
                    ? .ready
                    : .waitingForConfiguration,
                availableAt: now,
                now: now
            )
            recordAutomaticClassificationDiagnostic(
                "event=manual-retry job_id=\(failed.id.uuidString) generation=\(failed.generation) prior_attempt=\(failed.attempt)"
            )
            automaticClassificationJobsDidChange()
        } catch {
            refreshAutomaticClassificationStatuses()
        }
    }

    func restoreAutomaticClassificationWork() {
        requestAutomaticClassificationProviderReconciliation(
            currentAutomaticClassificationProviderExecution
        )
        refreshAutomaticClassificationStatuses()
        restartAutomaticClassificationWorker()
    }

    func automaticClassificationJobsDidChange() {
        refreshAutomaticClassificationStatuses()
        restartAutomaticClassificationWorker()
    }

    func automaticClassificationProviderConfigurationDidChange(
        _ transition: ZhulongProviderSettingsTransition
    ) {
        guard transition.revisionChanged || transition.readinessChanged else {
            return
        }
        let execution: AutomaticClassificationProviderExecution =
            if transition.currentReadiness,
               let executionRevision = transition.currentExecutionRevision
            {
                .configured(executionRevision: executionRevision)
            } else {
                .unconfigured
            }
        automaticClassificationProviderExecution = execution
        automaticClassificationBacklogDeferredForSession = false
        requestAutomaticClassificationProviderReconciliation(
            execution
        )
        refreshAutomaticClassificationStatuses()
    }

    private func requestAutomaticClassificationProviderReconciliation(
        _ execution: AutomaticClassificationProviderExecution
    ) {
        pendingAutomaticClassificationProviderReconciliation = execution
        if automaticClassificationWorkerTask != nil {
            automaticClassificationWorkerRestartRequested = true
            automaticClassificationWorkerTask?.cancel()
        } else {
            restartAutomaticClassificationWorker()
        }
    }

    private func reconcilePendingAutomaticClassificationProviderState() throws {
        guard let execution = pendingAutomaticClassificationProviderReconciliation,
              let automaticClassificationJobRepository
        else { return }
        _ = try automaticClassificationJobRepository.reconcileProviderExecution(
            execution,
            now: automaticClassificationOperationalClock.now()
        )
        pendingAutomaticClassificationProviderReconciliation = nil
    }

    func automaticClassificationMutationPlan(
        for policy: EngineMutationAutomaticClassificationPolicy,
        candidate: NoonmarkEngine,
        originalSnapshot: NoonmarkSnapshot
    ) throws -> AutomaticClassificationJobMutationPlan {
        guard case .none = policy else {
            guard let automaticClassificationJobRepository,
                  syncDeviceIdentity != nil
            else {
                return AutomaticClassificationJobMutationPlan(
                    enqueues: [],
                    mutations: []
                )
            }
            let storagePolicy: AutomaticClassificationJobMutationPolicy =
                switch policy {
                case .none:
                    .reconcileExisting
                case let .taskDefinitionChanged(chainID):
                    .taskDefinitionChanged(chainID)
                case .classificationCatalogChanged:
                    .classificationCatalogChanged
                case .newlyCreatedTaskChains:
                    .newlyCreatedTaskChains
                case let .taskBecameIneligible(chainID):
                    .taskBecameIneligible(chainID)
                case let .taskBecameEligible(chainID):
                    .taskBecameEligible(chainID)
                case let .userClassificationWins(chainID):
                    .userClassificationWins(chainID)
                }
            return try AutomaticClassificationJobMutationPlanner().plan(
                policy: storagePolicy,
                candidate: candidate,
                originalSnapshot: originalSnapshot,
                existingJobs: automaticClassificationJobRepository.jobs(),
                providerIsReady: automaticClassificationProviderIsReady,
                operationalNow: automaticClassificationOperationalClock.now()
            )
        }
        return AutomaticClassificationJobMutationPlan(
            enqueues: [],
            mutations: []
        )
    }

    func automaticClassificationRedo(
        for outcome: SnapshotUndoOutcome,
        candidate: NoonmarkEngine
    ) throws -> AutomaticClassificationJobRedo? {
        guard outcome.automaticClassificationRestoredChainIDs.count <= 1 else {
            throw NoonmarkError.invalidTransition(
                "one redo operation cannot restore multiple automatic classification jobs"
            )
        }
        guard let chainID = outcome
            .automaticClassificationRestoredChainIDs.first,
            let automaticClassificationJobRepository,
            syncDeviceIdentity != nil
        else { return nil }
        let cancelledJobs = try automaticClassificationJobRepository
            .jobs(states: [.cancelled])
            .filter {
                $0.chainID == chainID
                    && $0.cancelledByUndo
                    && $0.errorCode == .cancelledByUndo
            }
        guard let cancelled = cancelledJobs.max(by: {
            $0.generation < $1.generation
        })
        else { return nil }
        let (generation, overflow) = cancelled.generation
            .addingReportingOverflow(1)
        guard overflow == false else {
            throw NoonmarkError.invalidTransition(
                "automatic classification generation is exhausted"
            )
        }
        let context = try candidate.issueAutomaticClassificationContext(
            for: chainID,
            jobID: UUID(),
            generation: generation
        )
        let operationalNow = automaticClassificationOperationalClock.now()
        let providerIsReady = automaticClassificationProviderIsReady
        return AutomaticClassificationJobRedo(
            cancelledJob: cancelled.fence,
            replacement: try AutomaticClassificationJobEnqueue(
                authority: context.authority,
                initialState: providerIsReady
                    ? .ready
                    : .waitingForConfiguration,
                availableAt: operationalNow,
                createdAt: operationalNow
            )
        )
    }

    private var currentAutomaticClassificationProviderExecution:
        AutomaticClassificationProviderExecution
    {
        automaticClassificationProviderExecution
    }

    private var automaticClassificationProviderIsReady: Bool {
        if case .configured = currentAutomaticClassificationProviderExecution {
            true
        } else {
            false
        }
    }

    private func persistedAutomaticClassificationProviderExecution() throws
        -> AutomaticClassificationProviderExecution
    {
        guard let executionRevision = try ZhulongProviderSettingsStore
            .readPersistedReadyExecutionRevision()
        else { return .unconfigured }
        return .configured(executionRevision: executionRevision)
    }

    private func automaticClassificationDispatchIsPending(
        _ authorization: AutomaticClassificationDispatchAuthorization
    ) -> Bool {
        if case .pendingUserDecision = authorization {
            true
        } else {
            false
        }
    }

    private func makeAutomaticClassificationProvider(
        executionRevision: UUID
    ) throws -> OpenAICompatibleProvider {
        guard let config = try ZhulongProviderSettingsStore.makePersistedConfig(
            expectedExecutionRevision: executionRevision
        )
        else {
            throw AutomaticClassificationAppError.providerUnavailable
        }
        return OpenAICompatibleProvider(
            config: config,
            apiKeyResolver: { ref in
                try ZhulongProviderKeychain.resolveAPIKey(
                    ref,
                    expectedExecutionRevision: executionRevision
                )
            }
        )
    }

    private func refreshAutomaticClassificationStatuses() {
        guard let automaticClassificationJobRepository else {
            automaticClassificationStatusByChainID = [:]
            automaticClassificationBacklogSnapshot = nil
            automaticClassificationBacklogPrompt = nil
            automaticClassificationCircuitPresentation = nil
            automaticClassificationDiagnosticSnapshotFingerprint = nil
            return
        }
        do {
            let jobs = try automaticClassificationJobRepository.jobs(
                states: [
                    .waitingForConfiguration,
                    .ready,
                    .running,
                    .proposalReady,
                    .failed
                ]
            )
            let circuit = try automaticClassificationJobRepository.providerCircuit()
            let backlog = try automaticClassificationJobRepository.pendingBacklog()
            automaticClassificationBacklogSnapshot = backlog

            if automaticClassificationProviderIsReady,
               backlog.items.isEmpty == false,
               automaticClassificationBacklogDeferredForSession == false,
               automaticClassificationBacklogDecisionTask == nil
            {
                automaticClassificationBacklogPrompt = AutomaticClassificationBacklogPrompt(
                    count: backlog.items.count
                )
            } else {
                automaticClassificationBacklogPrompt = nil
            }

            let configuredRevision: UUID? =
                if case let .configured(executionRevision) =
                currentAutomaticClassificationProviderExecution {
                    executionRevision
                } else {
                    nil
                }
            let circuitIsBlocked = circuit?.state == .blocked
                && circuit?.providerExecutionRevision == configuredRevision
            if circuitIsBlocked {
                automaticClassificationCircuitPresentation =
                    AutomaticClassificationCircuitPresentation(
                        waitingCount: jobs.filter {
                            automaticClassificationDispatchIsPending(
                                $0.dispatchAuthorization
                            ) == false
                                && $0.state != .proposalReady
                                && $0.state != .failed
                        }.count,
                        failureCode: circuit?.failureCode ?? .providerUnavailable
                    )
            } else {
                automaticClassificationCircuitPresentation = nil
            }

            var statuses: [
                TaskChainID: AutomaticClassificationPresentationStatus
            ] = [:]
            for job in jobs.sorted(by: { $0.generation < $1.generation }) {
                let status: AutomaticClassificationPresentationStatus? =
                    if job.state == .failed {
                        .failed
                    } else if automaticClassificationDispatchIsPending(
                        job.dispatchAuthorization
                    ) {
                        automaticClassificationProviderIsReady
                            ? .waitingForDecision
                            : .waitingForConfiguration
                    } else if automaticClassificationProviderIsReady == false,
                              job.state != .proposalReady
                    {
                        .waitingForConfiguration
                    } else if circuitIsBlocked, job.state != .proposalReady {
                        .providerPaused
                    } else {
                        switch job.state {
                        case .waitingForConfiguration:
                            .waitingForConfiguration
                        case .ready, .running, .proposalReady:
                            .working
                        case .failed:
                            .failed
                        case .completed, .superseded, .cancelled:
                            nil
                        }
                    }
                statuses[job.chainID] = status
            }
            automaticClassificationStatusByChainID = statuses
            recordAutomaticClassificationDiagnosticSnapshot(
                repository: automaticClassificationJobRepository,
                circuit: circuit
            )
        } catch {
            automaticClassificationStatusByChainID = [:]
            automaticClassificationBacklogSnapshot = nil
            automaticClassificationBacklogPrompt = nil
            automaticClassificationCircuitPresentation = nil
            recordAutomaticClassificationDiagnostic("event=snapshot-read-failed")
        }
    }

    func resolveAutomaticClassificationBacklog(
        _ decision: AutomaticClassificationBacklogUserDecision
    ) {
        guard let snapshot = automaticClassificationBacklogSnapshot,
              snapshot.items.isEmpty == false
        else { return }
        switch decision {
        case .later:
            recordAutomaticClassificationDiagnostic(
                "event=backlog-decision decision=later item_count=\(snapshot.items.count)"
            )
            automaticClassificationBacklogDeferredForSession = true
            automaticClassificationBacklogPrompt = nil
        case .startExisting:
            guard automaticClassificationProviderIsReady else {
                refreshAutomaticClassificationStatuses()
                return
            }
            recordAutomaticClassificationDiagnostic(
                "event=backlog-decision decision=start-existing item_count=\(snapshot.items.count)"
            )
            resolveAutomaticClassificationBacklog(
                snapshot,
                storageDecision: .authorize(decisionID: UUID())
            )
        case .futureOnly:
            recordAutomaticClassificationDiagnostic(
                "event=backlog-decision decision=future-only item_count=\(snapshot.items.count)"
            )
            resolveAutomaticClassificationBacklog(
                snapshot,
                storageDecision: .skip
            )
        }
    }

    private func resolveAutomaticClassificationBacklog(
        _ snapshot: AutomaticClassificationBacklogSnapshot,
        storageDecision: AutomaticClassificationBacklogDecision
    ) {
        guard automaticClassificationBacklogDecisionTask == nil,
              automaticClassificationJobRepository != nil
        else { return }
        automaticClassificationBacklogPrompt = nil
        automaticClassificationBacklogDecisionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var shouldRestartWorker = false
            defer {
                automaticClassificationBacklogDecisionTask = nil
                if shouldRestartWorker {
                    automaticClassificationJobsDidChange()
                } else {
                    refreshAutomaticClassificationStatuses()
                }
            }
            guard let automaticClassificationJobRepository else { return }
            var contentionAttempt = 0
            while Task.isCancelled == false {
                do {
                    _ = try automaticClassificationJobRepository.resolveBacklog(
                        snapshot,
                        decision: storageDecision,
                        now: automaticClassificationOperationalClock.now()
                    )
                    automaticClassificationBacklogDeferredForSession = false
                    shouldRestartWorker = true
                    return
                } catch let error as SQLiteRepositoryError
                    where error.isTransientContention
                {
                    contentionAttempt += 1
                    do {
                        try await waitForAutomaticClassificationContentionRetry(
                            attempt: contentionAttempt
                        )
                    } catch {
                        return
                    }
                } catch {
                    showOperationFailure(.persistence, error: error)
                    return
                }
            }
        }
    }

    func retryAutomaticClassificationProviderCircuit() {
        guard automaticClassificationCircuitRetryTask == nil,
              case let .configured(executionRevision) =
              currentAutomaticClassificationProviderExecution
        else { return }
        automaticClassificationCircuitRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            recordAutomaticClassificationDiagnostic(
                "event=circuit-manual-retry phase=started execution_revision=\(executionRevision.uuidString)"
            )
            defer { automaticClassificationCircuitRetryTask = nil }
            do {
                guard let circuit = try automaticClassificationJobRepository?
                    .providerCircuit(),
                    circuit.state == .blocked,
                    circuit.providerExecutionRevision == executionRevision
                else {
                    refreshAutomaticClassificationStatuses()
                    return
                }
                let provider = try makeAutomaticClassificationProvider(
                    executionRevision: executionRevision
                )
                let health = await provider.healthCheck()
                try Task.checkCancellation()
                guard health.status == .healthy else {
                    showToast(
                        AppPresentation(language: engine.preferences.language)
                            .zhulong.providerActionNotice(.connectionFailed)
                    )
                    return
                }
                guard currentAutomaticClassificationProviderExecution
                    == .configured(executionRevision: executionRevision)
                else { return }
                try await resetAutomaticClassificationProviderCircuit(
                    executionRevision: executionRevision
                )
                recordAutomaticClassificationDiagnostic(
                    "event=circuit-manual-retry phase=succeeded execution_revision=\(executionRevision.uuidString)"
                )
                automaticClassificationJobsDidChange()
                showToast(
                    AppPresentation(language: engine.preferences.language)
                        .zhulong.providerActionNotice(.connectionSucceeded)
                )
            } catch is CancellationError {
                recordAutomaticClassificationDiagnostic(
                    "event=circuit-manual-retry phase=cancelled execution_revision=\(executionRevision.uuidString)"
                )
                return
            } catch {
                recordAutomaticClassificationDiagnostic(
                    "event=circuit-manual-retry phase=failed execution_revision=\(executionRevision.uuidString)"
                )
                refreshAutomaticClassificationStatuses()
                showToast(
                    AppPresentation(language: engine.preferences.language)
                        .zhulong.providerActionNotice(.connectionFailed)
                )
            }
        }
    }

    private func resetAutomaticClassificationProviderCircuit(
        executionRevision: UUID
    ) async throws {
        guard let automaticClassificationJobRepository else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        var contentionAttempt = 0
        while true {
            try Task.checkCancellation()
            do {
                _ = try automaticClassificationJobRepository.resetProviderCircuit(
                    executionRevision: executionRevision,
                    now: automaticClassificationOperationalClock.now()
                )
                return
            } catch let error as SQLiteRepositoryError
                where error.isTransientContention
            {
                contentionAttempt += 1
                try await waitForAutomaticClassificationContentionRetry(
                    attempt: contentionAttempt
                )
            }
        }
    }

    private func restartAutomaticClassificationWorker() {
        guard automaticClassificationJobRepository != nil else {
            automaticClassificationWorkerTask = nil
            pendingAutomaticClassificationProviderReconciliation = nil
            return
        }
        guard automaticClassificationWorkerTask == nil else { return }
        automaticClassificationWorkerTask = Task { @MainActor [weak self] in
            await self?.runAutomaticClassificationWorker()
        }
    }

    private func runAutomaticClassificationWorker() async {
        guard let automaticClassificationJobRepository else { return }
        defer {
            let shouldRestart = automaticClassificationWorkerRestartRequested
            automaticClassificationWorkerRestartRequested = false
            automaticClassificationWorkerTask = nil
            if shouldRestart {
                restartAutomaticClassificationWorker()
            }
        }
        var contentionAttempt = 0
        while Task.isCancelled == false {
            let providerDirective = await reconcileAutomaticClassificationProvider(
                contentionAttempt: &contentionAttempt
            )
            if providerDirective == .stop { return }
            if providerDirective == .restartLoop { continue }

            let executionDirective = await reconcileAutomaticClassificationExecution(
                repository: automaticClassificationJobRepository,
                contentionAttempt: &contentionAttempt
            )
            if executionDirective == .stop { return }
            if executionDirective == .restartLoop { continue }

            let dispatchDirective = await runNextAutomaticClassificationDispatch(
                repository: automaticClassificationJobRepository,
                contentionAttempt: &contentionAttempt
            )
            if dispatchDirective == .stop { return }
        }
    }

    private func reconcileAutomaticClassificationProvider(
        contentionAttempt: inout Int
    ) async -> AutomaticClassificationWorkerDirective {
        guard pendingAutomaticClassificationProviderReconciliation != nil else {
            return .proceed
        }
        do {
            try reconcilePendingAutomaticClassificationProviderState()
            contentionAttempt = 0
            refreshAutomaticClassificationStatuses()
            return .proceed
        } catch let error as SQLiteRepositoryError
            where error.isTransientContention
        {
            return await automaticClassificationContentionDirective(
                evidence: .providerReconciliation,
                contentionAttempt: &contentionAttempt
            )
        } catch {
            pendingAutomaticClassificationProviderReconciliation = nil
            NSLog("Noonmark automatic classification provider transition failed")
            return .stop
        }
    }

    private func reconcileAutomaticClassificationExecution(
        repository: SQLiteAutomaticClassificationJobRepository,
        contentionAttempt: inout Int
    ) async -> AutomaticClassificationWorkerDirective {
        do {
            let persistedExecution = try
                persistedAutomaticClassificationProviderExecution()
            guard persistedExecution
                == currentAutomaticClassificationProviderExecution
            else {
                automaticClassificationProviderExecution = persistedExecution
                automaticClassificationBacklogDeferredForSession = false
                pendingAutomaticClassificationProviderReconciliation =
                    persistedExecution
                return .restartLoop
            }
            let circuit = try repository.providerCircuit()
            guard automaticClassificationProviderExecution(
                persistedExecution,
                matches: circuit
            ) else {
                pendingAutomaticClassificationProviderReconciliation =
                    persistedExecution
                return .restartLoop
            }
            contentionAttempt = 0
            return .proceed
        } catch let error as SQLiteRepositoryError
            where error.isTransientContention
        {
            return await automaticClassificationContentionDirective(
                evidence: .workerStorage,
                contentionAttempt: &contentionAttempt
            )
        } catch is ZhulongProviderSettingsError {
            automaticClassificationProviderExecution = .unconfigured
            pendingAutomaticClassificationProviderReconciliation = .unconfigured
            refreshAutomaticClassificationStatuses()
            return await automaticClassificationContentionDirective(
                evidence: nil,
                contentionAttempt: &contentionAttempt
            )
        } catch {
            NSLog("Noonmark automatic classification circuit read failed")
            return .stop
        }
    }

    private func runNextAutomaticClassificationDispatch(
        repository: SQLiteAutomaticClassificationJobRepository,
        contentionAttempt: inout Int
    ) async -> AutomaticClassificationWorkerDirective {
        let now = automaticClassificationOperationalClock.now()
        do {
            let dispatch = try repository.nextDispatch(
                now: now,
                staleBefore: now.addingTimeInterval(
                    -Self.automaticClassificationClaimLease
                )
            )
            switch dispatch {
            case let .claimed(claim):
                contentionAttempt = 0
                refreshAutomaticClassificationStatuses()
                await processAutomaticClassificationClaim(claim)
                return .restartLoop
            case let .idle(nextWakeAt):
                guard let wakeDate = nextWakeAt else { return .stop }
                let delay = max(0.05, wakeDate.timeIntervalSince(now))
                try await Task.sleep(
                    nanoseconds: UInt64(min(delay, 1) * 1_000_000_000)
                )
                return .restartLoop
            case .waitingForProvider, .providerBlocked,
                 .backlogDecisionRequired:
                refreshAutomaticClassificationStatuses()
                return .stop
            }
        } catch is CancellationError {
            return .stop
        } catch let error as SQLiteRepositoryError
            where error.isTransientContention
        {
            return await automaticClassificationContentionDirective(
                evidence: .workerStorage,
                contentionAttempt: &contentionAttempt
            )
        } catch {
            NSLog("Noonmark automatic classification worker storage step failed")
            return .stop
        }
    }

    private func automaticClassificationContentionDirective(
        evidence: AutomaticClassificationContentionE2EEvidence.Step?,
        contentionAttempt: inout Int
    ) async -> AutomaticClassificationWorkerDirective {
        if let evidence {
            AutomaticClassificationContentionE2EEvidence.record(evidence)
        }
        contentionAttempt += 1
        do {
            try await waitForAutomaticClassificationContentionRetry(
                attempt: contentionAttempt
            )
            return .restartLoop
        } catch {
            return .stop
        }
    }

    private func automaticClassificationProviderExecution(
        _ execution: AutomaticClassificationProviderExecution,
        matches circuit: AutomaticClassificationProviderCircuit?
    ) -> Bool {
        switch execution {
        case .unconfigured:
            circuit?.state == .unconfigured
                && circuit?.providerExecutionRevision == nil
        case let .configured(executionRevision):
            circuit?.providerExecutionRevision == executionRevision
                && circuit?.state != .unconfigured
        }
    }

    private func waitForAutomaticClassificationContentionRetry(
        attempt: Int
    ) async throws {
        let exponent = min(max(attempt - 1, 0), 8)
        let delay = min(
            Self.automaticClassificationContentionInitialDelay
                * pow(2, Double(exponent)),
            Self.automaticClassificationContentionMaximumDelay
        )
        try await Task.sleep(
            nanoseconds: UInt64(delay * 1_000_000_000)
        )
    }

    private func processAutomaticClassificationClaim(
        _ claim: AutomaticClassificationJobClaim
    ) async {
        guard let automaticClassificationJobRepository else { return }
        let authority: AutomaticTaskClassificationAuthority
        do {
            authority = try AutomaticClassificationAuthorityPayload.decode(
                claim.authorityPayload
            )
        } catch {
            try? automaticClassificationJobRepository.fail(
                claim.fence,
                errorCode: .internalFailure,
                now: automaticClassificationOperationalClock.now()
            )
            refreshAutomaticClassificationStatuses()
            return
        }

        let context: AutomaticTaskClassificationContext
        do {
            context = try engine.automaticClassificationContext(
                authority: authority
            )
        } catch {
            resolveAutomaticClassificationStaleness(
                claim: claim,
                authority: authority
            )
            return
        }

        var checkpointIsDurable = claim.proposalCheckpoint != nil
        do {
            let handles = try AutomaticClassificationCatalogHandles(
                context: context
            )
            let proposal: AutomaticTaskClassificationProposal
            if let checkpoint = claim.proposalCheckpoint {
                proposal = try AutomaticClassificationProposalCheckpoint
                    .decode(checkpoint)
            } else {
                guard automaticClassificationProviderIsReady else {
                    requestAutomaticClassificationProviderReconciliation(
                        currentAutomaticClassificationProviderExecution
                    )
                    return
                }
                let request = try AutomaticTaskClassificationPromptBuilder()
                    .makeRequest(for: handles.input)
                let providerExecution = currentAutomaticClassificationProviderExecution
                guard case let .configured(executionRevision) = providerExecution else {
                    requestAutomaticClassificationProviderReconciliation(
                        providerExecution
                    )
                    return
                }
                let response: AIProviderResponse
                do {
                    response = try await makeAutomaticClassificationProvider(
                        executionRevision: executionRevision
                    )
                        .complete(request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    let persistedExecution: AutomaticClassificationProviderExecution
                    do {
                        persistedExecution = try
                            persistedAutomaticClassificationProviderExecution()
                    } catch {
                        await handleAutomaticClassificationProviderFailure(
                            error,
                            claim: claim
                        )
                        return
                    }
                    guard persistedExecution == providerExecution else {
                        automaticClassificationProviderExecution =
                            persistedExecution
                        requestAutomaticClassificationProviderReconciliation(
                            persistedExecution
                        )
                        return
                    }
                    await handleAutomaticClassificationProviderFailure(
                        error,
                        claim: claim
                    )
                    return
                }
                try Task.checkCancellation()
                guard ZhulongProviderSettingsStore
                    .persistedConfiguredExecutionRevision() == executionRevision
                else {
                    let persistedExecution = (try?
                        persistedAutomaticClassificationProviderExecution())
                        ?? .unconfigured
                    automaticClassificationProviderExecution = persistedExecution
                    requestAutomaticClassificationProviderReconciliation(
                        persistedExecution
                    )
                    return
                }
                do {
                    proposal = try AutomaticTaskClassificationDecoder().decode(
                        response,
                        against: handles.input
                    )
                } catch {
                    await resolveAutomaticClassificationProviderOutcome(
                        .invalidResponse,
                        claim: claim
                    )
                    return
                }
                let checkpoint = try AutomaticClassificationProposalCheckpoint.encode(
                    proposal
                )
                try await checkpointAutomaticClassificationProposal(
                    checkpoint,
                    for: claim
                )
                checkpointIsDurable = true
                if AutomaticClassificationCheckpointE2EInterruption
                    .interruptIfRequested(jobID: claim.jobID)
                {
                    return
                }
            }

            try Task.checkCancellation()
            let moment = try prepareStoreMutationForAutomaticClassification()
            let candidate = try NoonmarkEngine(snapshot: engine.snapshot())
            let currentContext = try candidate.automaticClassificationContext(
                authority: authority
            )
            let currentHandles = try AutomaticClassificationCatalogHandles(
                context: currentContext
            )
            let plan = try candidate.prepareAutomaticClassification(
                currentHandles.applicationProposal(from: proposal),
                authority: authority,
                interactionID: UUID(),
                now: moment.instant
            )
            _ = try candidate.commitAutomaticClassification(
                plan,
                authority: authority,
                now: moment.instant
            )
            try saveAutomaticClassificationCompletion(
                candidate,
                claim: claim,
                mutationAt: moment.instant
            )
            engine = candidate
            refreshAutomaticClassificationStatuses()
        } catch is CancellationError {
            return
        } catch {
            if (try? engine.automaticClassificationContext(
                authority: authority
            )) == nil {
                resolveAutomaticClassificationStaleness(
                    claim: claim,
                    authority: authority
                )
                return
            }
            if checkpointIsDurable {
                if error is NoonmarkError
                    || error is AutomaticClassificationAppError
                    || error is AutomaticTaskClassificationContractError
                    || error is DecodingError
                {
                    try? automaticClassificationJobRepository.fail(
                        claim.fence,
                        errorCode: .invalidProposal,
                        now: automaticClassificationOperationalClock.now()
                    )
                    refreshAutomaticClassificationStatuses()
                } else {
                    // Keep proposalReady and its exact claim untouched. Lease
                    // recovery will reuse the canonical checkpoint without
                    // another Provider request.
                    NSLog(
                        "Noonmark automatic classification checkpoint retained job=%@",
                        claim.jobID.uuidString
                    )
                }
                return
            }
            if error is NoonmarkError
                || error is AutomaticClassificationAppError
                || error is AutomaticTaskClassificationContractError
                || error is DecodingError
            {
                try? automaticClassificationJobRepository.fail(
                    claim.fence,
                    errorCode: .invalidProposal,
                    now: automaticClassificationOperationalClock.now()
                )
                refreshAutomaticClassificationStatuses()
            } else {
                // A storage/CAS failure is not a Provider failure. Leave the
                // claim durable for lease recovery instead of changing the
                // global Provider circuit on false evidence.
                NSLog(
                    "Noonmark automatic classification claim retained job=%@",
                    claim.jobID.uuidString
                )
            }
        }
    }

    private func checkpointAutomaticClassificationProposal(
        _ checkpoint: Data,
        for claim: AutomaticClassificationJobClaim
    ) async throws {
        guard let automaticClassificationJobRepository else {
            throw AutomaticClassificationAppError.persistenceUnavailable
        }
        var contentionAttempt = 0
        while true {
            try Task.checkCancellation()
            do {
                try automaticClassificationJobRepository.resolveProviderAttempt(
                    .checkpoint(checkpoint),
                    for: claim,
                    now: automaticClassificationOperationalClock.now()
                )
                return
            } catch let error as SQLiteRepositoryError
                where error.isTransientContention
            {
                AutomaticClassificationContentionE2EEvidence.record(
                    .proposalCheckpoint
                )
                contentionAttempt += 1
                try await waitForAutomaticClassificationContentionRetry(
                    attempt: contentionAttempt
                )
            }
        }
    }

    private func resolveAutomaticClassificationStaleness(
        claim: AutomaticClassificationJobClaim,
        authority: AutomaticTaskClassificationAuthority
    ) {
        guard let automaticClassificationJobRepository else { return }
        let now = automaticClassificationOperationalClock.now()
        do {
            guard let chain = engine.chains[claim.chainID], chain.state == .active else {
                try automaticClassificationJobRepository.cancel(
                    claim.fence,
                    now: now
                )
                refreshAutomaticClassificationStatuses()
                return
            }
            let (nextGeneration, generationOverflow) = claim.generation
                .addingReportingOverflow(1)
            guard generationOverflow == false else {
                try automaticClassificationJobRepository.fail(
                    claim.fence,
                    errorCode: .internalFailure,
                    now: now
                )
                refreshAutomaticClassificationStatuses()
                return
            }
            let replacementContext = try engine.issueAutomaticClassificationContext(
                for: claim.chainID,
                jobID: UUID(),
                generation: nextGeneration
            )
            if replacementContext.authority.classificationFingerprint
                != authority.classificationFingerprint
            {
                _ = try automaticClassificationJobRepository.supersedeJobs(
                    forChain: claim.chainID,
                    now: now
                )
            } else if replacementContext.authority.contentDigest
                != authority.contentDigest
                || replacementContext.authority.catalogDigest
                != authority.catalogDigest
            {
                let providerIsReady = automaticClassificationProviderIsReady
                let replacement = try AutomaticClassificationJobEnqueue(
                    authority: replacementContext.authority,
                    initialState: providerIsReady
                        ? .ready
                        : .waitingForConfiguration,
                    availableAt: now,
                    createdAt: now
                )
                try automaticClassificationJobRepository.replace(
                    claim.fence,
                    with: replacement,
                    now: now
                )
            } else {
                try automaticClassificationJobRepository.fail(
                    claim.fence,
                    errorCode: .internalFailure,
                    now: now
                )
            }
        } catch {
            // A competing user/undo/provider transition may have already consumed
            // this exact claim. The persisted queue is authoritative.
        }
        refreshAutomaticClassificationStatuses()
    }

    private func handleAutomaticClassificationProviderFailure(
        _ error: Error,
        claim: AutomaticClassificationJobClaim
    ) async {
        let retryDelay = ClassificationRetryE2EOverride
            .delay(forAttempt: claim.attempt)
        let resolution: AutomaticClassificationProviderFailureResolution = if let providerError = error as? AIProviderHTTPError {
            switch providerError {
            case .missingBaseURL, .missingModel, .missingAPIKey:
                .transientFailure(retryDelay: retryDelay)
            case let .httpStatus(status, _):
                if status == 429 {
                    .rateLimited(retryDelay: retryDelay)
                } else if [408, 409, 423, 424, 425].contains(status) {
                    .transientFailure(retryDelay: retryDelay)
                } else if 400 ..< 500 ~= status {
                    .credentialsRejected
                } else {
                    .transientFailure(retryDelay: retryDelay)
                }
            case .invalidResponse, .emptyResponse:
                .invalidResponse
            }
        } else if error is DecodingError {
            .invalidResponse
        } else if error is ZhulongProviderSettingsError
            || error is AutomaticClassificationAppError
        {
            .transientFailure(retryDelay: retryDelay)
        } else {
            .transientFailure(retryDelay: retryDelay)
        }
        await resolveAutomaticClassificationProviderOutcome(
            resolution,
            claim: claim
        )
    }

    private func resolveAutomaticClassificationProviderOutcome(
        _ resolution: AutomaticClassificationProviderFailureResolution,
        claim: AutomaticClassificationJobClaim
    ) async {
        guard let automaticClassificationJobRepository else { return }
        var contentionAttempt = 0
        while Task.isCancelled == false {
            do {
                let now = automaticClassificationOperationalClock.now()
                let outcome = resolution.storageOutcome(now: now)
                try automaticClassificationJobRepository.resolveProviderAttempt(
                    outcome,
                    for: claim,
                    now: now
                )
                let retryAtBits = switch outcome {
                case let .rateLimited(retryAt), let .transientFailure(retryAt):
                    String(retryAt.timeIntervalSinceReferenceDate.bitPattern)
                case .checkpoint, .invalidResponse, .credentialsRejected:
                    "none"
                }
                recordAutomaticClassificationDiagnostic(
                    "event=provider-outcome code=\(resolution.diagnosticCode) job_id=\(claim.jobID.uuidString) generation=\(claim.generation) attempt=\(claim.attempt) retry_at_bits=\(retryAtBits)"
                )
                refreshAutomaticClassificationStatuses()
                return
            } catch let error as SQLiteRepositoryError
                where error.isTransientContention
            {
                contentionAttempt += 1
                do {
                    try await waitForAutomaticClassificationContentionRetry(
                        attempt: contentionAttempt
                    )
                } catch {
                    return
                }
            } catch {
                // A user edit, undo, or Provider transition may already have
                // consumed the exact claim. Persisted state is authoritative.
                refreshAutomaticClassificationStatuses()
                return
            }
        }
    }
}

@MainActor
extension NoonmarkStore {
    func recordAutomaticClassificationMutationDiagnostics(
        _ plan: AutomaticClassificationJobMutationPlan
    ) {
        if plan.enqueues.isEmpty == false {
            recordAutomaticClassificationDiagnostic(
                "event=job-mutation kind=enqueue count=\(plan.enqueues.count)"
            )
        }
        for mutation in plan.mutations {
            let detail = switch mutation {
            case let .replace(fence, replacement):
                "kind=replace job_id=\(fence.jobID.uuidString) generation=\(fence.generation) replacement_job_id=\(replacement.id.uuidString) replacement_generation=\(replacement.generation)"
            case let .invalidateChain(chainID):
                "kind=fence-invalidated reason=task-ineligible chain_id=\(chainID.description)"
            case let .supersedeChain(chainID):
                "kind=fence-invalidated reason=user-classification-won chain_id=\(chainID.description)"
            case let .restoreEligibility(fence, replacement):
                "kind=restore-eligibility job_id=\(fence.jobID.uuidString) generation=\(fence.generation) replacement_job_id=\(replacement.id.uuidString) replacement_generation=\(replacement.generation)"
            case let .cancelForUndo(chainID):
                "kind=fence-invalidated reason=snapshot-undo chain_id=\(chainID.description)"
            case let .requeueCancelledByUndo(redo):
                "kind=requeue-redo job_id=\(redo.cancelledJob.jobID.uuidString) generation=\(redo.cancelledJob.generation) replacement_job_id=\(redo.replacement.id.uuidString) replacement_generation=\(redo.replacement.generation)"
            }
            recordAutomaticClassificationDiagnostic(
                "event=job-mutation \(detail)"
            )
        }
    }

    func recordAutomaticClassificationDiagnostic(_ fields: String) {
        NSLog("NoonmarkAutomaticClassificationDiagnostic %@", fields)
    }

    private func recordAutomaticClassificationDiagnosticSnapshot(
        repository: SQLiteAutomaticClassificationJobRepository,
        circuit: AutomaticClassificationProviderCircuit?
    ) {
        guard let jobs = try? repository.jobs() else {
            recordAutomaticClassificationDiagnostic("event=snapshot-read-failed")
            return
        }
        let stateCounts = AutomaticClassificationJobState.allCases.map { state in
            "\(state.rawValue):\(jobs.count { $0.state == state })"
        }.joined(separator: ",")
        let authorizationCounts = [
            AutomaticClassificationDispatchAuthorization.automatic,
            .pendingUserDecision,
            .explicit
        ].map { authorization in
            "\(authorization.rawValue):\(jobs.count { $0.dispatchAuthorization == authorization })"
        }.joined(separator: ",")
        let errorCounts = AutomaticClassificationJobErrorCode.allCases.compactMap {
            code -> String? in
            let count = jobs.count { $0.errorCode == code }
            return count == 0 ? nil : "\(code.rawValue):\(count)"
        }.joined(separator: ",")
        let circuitFields: String = if let circuit {
            [
                "state=\(circuit.state.rawValue)",
                "failure=\(circuit.failureCode?.rawValue ?? "none")",
                "failures=\(circuit.consecutiveFailures)",
                "retry_at_bits=\(diagnosticDateBits(circuit.retryAt))",
                "opened_at_bits=\(diagnosticDateBits(circuit.openedAt))",
                "transition_version=\(circuit.transitionVersion)",
                "probe=\(circuit.probeFence == nil ? "none" : "claimed")"
            ].joined(separator: " ")
        } else {
            "state=none failure=none failures=0 retry_at_bits=none opened_at_bits=none transition_version=0 probe=none"
        }
        let fingerprint = [
            "states=\(stateCounts)",
            "authorizations=\(authorizationCounts)",
            "max_attempt=\(jobs.map(\.attempt).max() ?? 0)",
            "errors=\(errorCounts.isEmpty ? "none" : errorCounts)",
            circuitFields
        ].joined(separator: " ")
        guard fingerprint != automaticClassificationDiagnosticSnapshotFingerprint else {
            return
        }
        automaticClassificationDiagnosticSnapshotFingerprint = fingerprint
        recordAutomaticClassificationDiagnostic("event=snapshot \(fingerprint)")
    }

    private func diagnosticDateBits(_ date: Date?) -> String {
        guard let date else { return "none" }
        return String(date.timeIntervalSinceReferenceDate.bitPattern)
    }
}

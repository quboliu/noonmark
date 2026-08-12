import Foundation
import NoonmarkCore
import NoonmarkSync

public enum LocalFirstReplicationCommand: Sendable {
    case reconcile(now: Date)
    case resolveForkConflicts(
        resolutionID: ReplicationDigest,
        decisions: [ReplicationForkConflictDecisionSelection],
        now: Date
    )
    case disable
    case enable
}

public enum LocalFirstReplicationWorkerState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case idle
    case running
    case stopping
    case stoppingDelayed
    case disabled
}

public enum LocalFirstReplicationConvergence:
    String,
    Codable,
    Equatable,
    Sendable
{
    case converged
    case waitingForEndpoint
    case blocked
}

public enum LocalFirstReplicationIncident:
    String,
    Codable,
    Equatable,
    Sendable
{
    case endpointRequiresUserAttention
    case endpointCorruption
    case producerForkDetected
    case repairBaselineRejected
    case runtimeFailure
}

public struct LocalFirstReplicationForkConflictSummary:
    Codable,
    Equatable,
    Sendable
{
    public let conflictID: UUID
    public let type: SyncConflictType
    public let entityType: SyncEntityType
    public let allowedDecisions: [ReplicationForkConflictDecision]

    public init(
        conflictID: UUID,
        type: SyncConflictType,
        entityType: SyncEntityType,
        allowedDecisions: [ReplicationForkConflictDecision]
    ) {
        self.conflictID = conflictID
        self.type = type
        self.entityType = entityType
        self.allowedDecisions = allowedDecisions
    }
}

public struct LocalFirstReplicationActionableForkConflict:
    Codable,
    Equatable,
    Sendable
{
    public let resolutionID: ReplicationDigest
    public let conflicts: [LocalFirstReplicationForkConflictSummary]

    public init(
        resolutionID: ReplicationDigest,
        conflicts: [LocalFirstReplicationForkConflictSummary]
    ) {
        precondition(
            conflicts.isEmpty == false,
            "actionable fork conflict cannot be empty"
        )
        self.resolutionID = resolutionID
        self.conflicts = conflicts
    }
}

public struct LocalFirstReplicationState: Codable, Equatable, Sendable {
    public let worker: LocalFirstReplicationWorkerState
    public let convergence: LocalFirstReplicationConvergence
    public let incident: LocalFirstReplicationIncident?
    public let actionableForkConflict:
        LocalFirstReplicationActionableForkConflict?
    public let pendingLocalPublicationCount: Int
    public let confirmedLocalPublicationCount: Int
    public let appliedRemotePublicationCount: Int
    public let waitingRecordCount: Int
    public let lastSyncedAt: Date?
    public let lastEffectiveSyncedAt: Date?

    public init(
        worker: LocalFirstReplicationWorkerState,
        convergence: LocalFirstReplicationConvergence,
        incident: LocalFirstReplicationIncident?,
        actionableForkConflict:
            LocalFirstReplicationActionableForkConflict? = nil,
        pendingLocalPublicationCount: Int,
        confirmedLocalPublicationCount: Int,
        appliedRemotePublicationCount: Int,
        waitingRecordCount: Int,
        lastSyncedAt: Date?,
        lastEffectiveSyncedAt: Date?
    ) {
        self.worker = worker
        self.convergence = convergence
        self.incident = incident
        self.actionableForkConflict = actionableForkConflict
        self.pendingLocalPublicationCount = pendingLocalPublicationCount
        self.confirmedLocalPublicationCount = confirmedLocalPublicationCount
        self.appliedRemotePublicationCount = appliedRemotePublicationCount
        self.waitingRecordCount = waitingRecordCount
        self.lastSyncedAt = lastSyncedAt
        self.lastEffectiveSyncedAt = lastEffectiveSyncedAt
    }
}

public actor LocalFirstReplication {
    private static let stateMetadataKey =
        "localFirst.replication.v2.state"

    private let endpoint: any ReplicationEndpoint
    private let generationID: UUID
    private var producerID: UUID
    private let engineRepository: SQLiteEngineRepository
    private let syncRepository: SQLiteSyncRepository
    private let ledger: SQLiteReplicationLedger
    private let publicationWatermarkStore:
        any ReplicationPublicationWatermarkStore
    private let downloadCoordinator: SQLiteSyncDownloadCoordinator
    private let builder: ReplicationPublicationBuilder
    private let stoppingDelay: Duration
    private var control: LocalFirstReplicationControl
    private var enabled: Bool
    private var workerTask: Task<LocalFirstReplicationState, Error>?
    private var workerGeneration: UInt64?
    private var automaticTask: Task<Void, Never>?
    private var automaticGeneration: UInt64?
    private var acceptsCommands = true
    private var retirementInProgress = false
    private var state: LocalFirstReplicationState
    private var continuations: [UUID: AsyncStream<LocalFirstReplicationState>.Continuation] = [:]

    public nonisolated static func persistedState(
        databaseURL: URL
    ) throws -> LocalFirstReplicationState? {
        guard let metadata = try SQLiteSyncRepository(
            databaseURL: databaseURL
        ).metadata(for: stateMetadataKey) else {
            return nil
        }
        do {
            let decoded = try ReplicationPublicationBuilder
                .canonicalDecoder().decode(
                    LocalFirstReplicationState.self,
                    from: metadata.value
                )
            guard try ReplicationPublicationBuilder.canonicalEncoder()
                .encode(decoded) == metadata.value
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication runtime state is not canonical"
                )
            }
            return decoded
        } catch let error as SQLiteRepositoryError {
            throw error
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication runtime state is invalid"
            )
        }
    }

    public init(
        databaseURL: URL,
        endpoint: any ReplicationEndpoint,
        generationID: UUID,
        producerID: UUID,
        publicationWatermarkStore:
            any ReplicationPublicationWatermarkStore,
        builder: ReplicationPublicationBuilder = ReplicationPublicationBuilder(),
        stoppingDelay: Duration = .seconds(2)
    ) throws {
        let syncRepository = SQLiteSyncRepository(databaseURL: databaseURL)
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        guard let authority = try ledger.cleanCutAuthority() else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication V2 clean-cut authority is missing"
            )
        }
        guard authority.generationID == generationID else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication authority generation differs from runtime"
            )
        }
        let activeProducerID = try ledger.loadOrInstallActiveProducerID(
            suggestedProducerID: producerID,
            installedAt: Date()
        )
        let control = try syncRepository
            .loadOrInstallLocalFirstReplicationControl(
                installedAt: Date()
            )
        self.endpoint = endpoint
        self.generationID = generationID
        self.producerID = activeProducerID
        self.publicationWatermarkStore = publicationWatermarkStore
        self.builder = builder
        self.stoppingDelay = stoppingDelay
        self.control = control
        enabled = control.policy == .enabled
        engineRepository = SQLiteEngineRepository(databaseURL: databaseURL)
        self.syncRepository = syncRepository
        self.ledger = ledger
        downloadCoordinator = SQLiteSyncDownloadCoordinator(
            databaseURL: databaseURL,
            transport: InMemorySyncTransport()
        )
        state = try Self.restoreState(
            syncRepository: syncRepository,
            ledger: ledger,
            generationID: generationID,
            producerID: activeProducerID,
            control: control
        )
    }

    public static func openCleanCut(
        databaseURL: URL,
        endpoint: any ReplicationEndpoint,
        generationID: UUID,
        producerID: UUID,
        publicationWatermarkStore:
            any ReplicationPublicationWatermarkStore,
        builder: ReplicationPublicationBuilder = ReplicationPublicationBuilder(),
        stoppingDelay: Duration = .seconds(2),
        repositoryWasCreated: Bool = false,
        installedAt: Date = Date()
    ) throws -> LocalFirstReplication {
        let ledger = SQLiteReplicationLedger(databaseURL: databaseURL)
        if let authority = try ledger.cleanCutAuthority() {
            guard authority.generationID == generationID else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication endpoint generation differs from local authority"
                )
            }
            if repositoryWasCreated {
                let activeProducerID = try ledger
                    .loadOrInstallActiveProducerID(
                        suggestedProducerID: producerID,
                        installedAt: installedAt
                    )
                let observation = try SQLiteEngineRepository(
                    databaseURL: databaseURL
                ).loadObservedSnapshot()
                let records = try ReplicationSnapshotRecordBuilder().records(
                    from: observation.snapshot,
                    modifiedBy: SyncDeviceID("replication-reseed-v2"),
                    createdAt: installedAt
                )
                guard records.isEmpty == false else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "replacement repository baseline produced no records"
                    )
                }
                let replacementProducerID = UUID()
                let baseline = try builder.seal(
                    records: records,
                    generationID: generationID,
                    producerID: replacementProducerID,
                    sequence: 1,
                    previousSealDigest: nil
                )
                let control = try SQLiteSyncRepository(
                    databaseURL: databaseURL
                ).loadOrInstallLocalFirstReplicationControl(
                    installedAt: installedAt
                )
                try ledger.rotateActiveProducerAndSealBaseline(
                    retiringProducerID: activeProducerID,
                    replacementProducerID: replacementProducerID,
                    publication: SQLiteSealedLocalPublication(
                        publication: baseline,
                        journalEntryIDs: try SQLiteSyncRepository(
                            databaseURL: databaseURL
                        ).pendingReplicationOutboxEntryIDs(
                            generationID: generationID
                        )
                    ),
                    sealedAt: installedAt,
                    expectedReplicationControl: control
                )
                try publicationWatermarkStore.compareAndSet(
                    expected: nil,
                    replacement: baseline.reference.publicationWatermark,
                    in: ReplicationPublicationWatermarkScope(
                        generationID: generationID,
                        producerID: replacementProducerID
                    )
                )
            }
        } else {
            let observation = try SQLiteEngineRepository(
                databaseURL: databaseURL
            ).loadObservedSnapshot()
            let records = try ReplicationSnapshotRecordBuilder().records(
                from: observation.snapshot,
                modifiedBy: SyncDeviceID("replication-clean-cut-v2"),
                createdAt: installedAt
            )
            guard records.isEmpty == false else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "clean-cut replication baseline produced no records"
                )
            }
            let baseline = try builder.seal(
                records: records,
                generationID: generationID,
                producerID: producerID,
                sequence: 1,
                previousSealDigest: nil
            )
            try ledger.installCleanCutAuthorityAndBaseline(
                baseline,
                observedEngineGeneration: observation.generation,
                installedAt: installedAt
            )
            try publicationWatermarkStore.compareAndSet(
                expected: nil,
                replacement: baseline.reference.publicationWatermark,
                in: ReplicationPublicationWatermarkScope(
                    generationID: generationID,
                    producerID: producerID
                )
            )
        }
        return try LocalFirstReplication(
            databaseURL: databaseURL,
            endpoint: endpoint,
            generationID: generationID,
            producerID: producerID,
            publicationWatermarkStore: publicationWatermarkStore,
            builder: builder,
            stoppingDelay: stoppingDelay
        )
    }

    public func states() -> AsyncStream<LocalFirstReplicationState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func startAutomatic(interval: Duration) throws {
        guard interval > .zero else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication automatic interval must be positive"
            )
        }
        guard acceptsCommands else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication runtime is shut down"
            )
        }
        guard enabled else { return }
        guard automaticTask == nil else { return }
        let generation = control.generation
        automaticGeneration = generation
        automaticTask = Task { [weak self] in
            await self?.runAutomaticLoop(
                interval: interval,
                generation: generation
            )
        }
    }

    public func stopAutomatic() async {
        let task = automaticTask
        automaticTask = nil
        automaticGeneration = nil
        task?.cancel()
        if let task {
            _ = await task.result
        }
    }

    @discardableResult
    public func shutdown() async throws -> LocalFirstReplicationState {
        guard acceptsCommands else { return state }
        guard retirementInProgress == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication runtime retirement is already in progress"
            )
        }
        retirementInProgress = true
        do {
            let retired = try await retire(
                preserving: control.policy,
                terminalWorker: control.policy == .enabled ? .idle : .disabled
            )
            acceptsCommands = false
            retirementInProgress = false
            return retired
        } catch {
            retirementInProgress = false
            throw error
        }
    }

    @discardableResult
    public func send(
        _ command: LocalFirstReplicationCommand
    ) async throws -> LocalFirstReplicationState {
        guard acceptsCommands, retirementInProgress == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication runtime is shut down or retiring"
            )
        }
        switch command {
        case .enable:
            guard enabled == false else { return state }
            control = try syncRepository
                .transitionLocalFirstReplicationControl(
                    expectedGeneration: control.generation,
                    policy: .enabled,
                    updatedAt: Date()
                )
            enabled = true
            let enabledState = stateWith(worker: .idle)
            try persist(enabledState, at: control.updatedAt)
            install(enabledState)
            return state
        case .disable:
            guard enabled else { return state }
            retirementInProgress = true
            do {
                let retired = try await retire(
                    preserving: .disabled,
                    terminalWorker: .disabled
                )
                retirementInProgress = false
                return retired
            } catch {
                retirementInProgress = false
                throw error
            }
        case let .reconcile(now):
            guard enabled else { return state }
            return try await runOwnedReconcile(now: now)
        case let .resolveForkConflicts(resolutionID, decisions, now):
            guard enabled else { return state }
            return try await resolveForkConflicts(
                resolutionID: resolutionID,
                decisions: decisions,
                now: now
            )
        }
    }
}

private extension LocalFirstReplication {
    func runAutomaticLoop(
        interval: Duration,
        generation: UInt64
    ) async {
        defer {
            if automaticGeneration == generation {
                automaticTask = nil
                automaticGeneration = nil
            }
        }
        while Task.isCancelled == false,
              acceptsCommands,
              retirementInProgress == false,
              enabled,
              control.generation == generation
        {
            do {
                _ = try await runOwnedReconcile(now: Date())
            } catch is CancellationError {
                return
            } catch {
                // performReconcile persists the typed failure state. The
                // scheduler waits for the configured interval before retrying.
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func retire(
        preserving policy: LocalFirstReplicationPolicy,
        terminalWorker: LocalFirstReplicationWorkerState
    ) async throws -> LocalFirstReplicationState {
        let task = workerTask
        let retiringGeneration = workerGeneration
        let scheduler = automaticTask
        automaticTask = nil
        automaticGeneration = nil
        scheduler?.cancel()
        control = try syncRepository.transitionLocalFirstReplicationControl(
            expectedGeneration: control.generation,
            policy: policy,
            updatedAt: Date()
        )
        enabled = false
        task?.cancel()
        let stopping = stateWith(worker: .stopping)
        try persist(stopping, at: control.updatedAt)
        install(stopping)
        let stoppingGeneration = control.generation
        let delay = stoppingDelay
        let stoppingMonitor = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.markStoppingDelayed(
                    generation: stoppingGeneration
                )
            } catch {}
        }
        await endpoint.cancelAndJoin()
        if let task {
            _ = await task.result
        }
        if let scheduler {
            _ = await scheduler.result
        }
        stoppingMonitor.cancel()
        _ = await stoppingMonitor.result
        if workerGeneration == retiringGeneration {
            workerTask = nil
            workerGeneration = nil
        }
        let terminal = stateWith(worker: terminalWorker)
        try persist(terminal, at: Date())
        install(terminal)
        return state
    }

    static func restoreState(
        syncRepository: SQLiteSyncRepository,
        ledger: SQLiteReplicationLedger,
        generationID: UUID,
        producerID: UUID,
        control: LocalFirstReplicationControl
    ) throws -> LocalFirstReplicationState {
        let persisted: LocalFirstReplicationState?
        if let metadata = try syncRepository.metadata(for: stateMetadataKey) {
            do {
                persisted = try ReplicationPublicationBuilder
                    .canonicalDecoder().decode(
                        LocalFirstReplicationState.self,
                        from: metadata.value
                    )
            } catch {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication runtime state is invalid"
                )
            }
        } else {
            persisted = nil
        }
        let pendingCount = try ledger.pendingLocalPublications(
            generationID: generationID,
            producerID: producerID
        ).count
        guard try ledger.cleanCutAuthority()?.generationID == generationID else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication authority generation differs from runtime"
            )
        }
        let unfinishedJournalCount = try ledger.outboxSnapshot(
            generationID: generationID
        ).pendingCount
        let pendingRepairBaselineCount = try ledger
            .closedForkResolutionsAwaitingBaseline(
                generationID: generationID,
                producerID: producerID
            ).count
        let hasDurableWork = pendingCount > 0
            || unfinishedJournalCount > 0
            || pendingRepairBaselineCount > 0
        let actionableForkConflict = try syncRepository
            .latestReplicationForkConflictSet(
                generationID: generationID
            ).map(Self.actionableForkConflict)
        let previous = persisted ?? LocalFirstReplicationState(
            worker: .idle,
            convergence: .waitingForEndpoint,
            incident: nil,
            pendingLocalPublicationCount: 0,
            confirmedLocalPublicationCount: 0,
            appliedRemotePublicationCount: 0,
            waitingRecordCount: 0,
            lastSyncedAt: nil,
            lastEffectiveSyncedAt: nil
        )
        return LocalFirstReplicationState(
            worker: control.policy == .disabled ? .disabled : .idle,
            convergence: actionableForkConflict != nil
                ? .blocked
                : hasDurableWork
                ? .waitingForEndpoint
                : previous.convergence,
            incident: actionableForkConflict != nil
                ? .producerForkDetected
                : previous.incident == .producerForkDetected
                ? nil
                : previous.incident,
            actionableForkConflict: actionableForkConflict,
            pendingLocalPublicationCount: pendingCount,
            confirmedLocalPublicationCount: previous
                .confirmedLocalPublicationCount,
            appliedRemotePublicationCount: previous
                .appliedRemotePublicationCount,
            waitingRecordCount: previous.waitingRecordCount,
            lastSyncedAt: previous.lastSyncedAt,
            lastEffectiveSyncedAt: previous.lastEffectiveSyncedAt
        )
    }

    func runOwnedReconcile(
        now: Date
    ) async throws -> LocalFirstReplicationState {
        if let workerTask {
            return try await workerTask.value
        }
        let generation = control.generation
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performReconcile(
                now: now,
                generation: generation
            )
        }
        workerTask = task
        workerGeneration = generation
        do {
            let result = try await task.value
            if workerGeneration == generation {
                workerTask = nil
                workerGeneration = nil
            }
            return result
        } catch {
            if workerGeneration == generation {
                workerTask = nil
                workerGeneration = nil
            }
            throw error
        }
    }

    func performReconcile(
        now: Date,
        generation: UInt64
    ) async throws -> LocalFirstReplicationState {
        try assertActiveGeneration(generation)
        install(
            LocalFirstReplicationState(
                worker: .running,
                convergence: .waitingForEndpoint,
                incident: nil,
                pendingLocalPublicationCount: state.pendingLocalPublicationCount,
                confirmedLocalPublicationCount: 0,
                appliedRemotePublicationCount: 0,
                waitingRecordCount: 0,
                lastSyncedAt: state.lastSyncedAt,
                lastEffectiveSyncedAt: state.lastEffectiveSyncedAt
            )
        )
        do {
            try Task.checkCancellation()
            try assertActiveGeneration(generation)
            try recoverPublicationWatermarkMismatch(now: now)
            try assertActiveGeneration(generation)
            try sealUnsealedJournal(now: now)
            var confirmation = try await publishAndObserve(
                now: now,
                generation: generation
            )
            try assertActiveGeneration(generation)
            var remote = try await applyRemoteUntilStable(
                now: now,
                generation: generation
            )
            try assertActiveGeneration(generation)
            if confirmation.incident == nil,
               remote.incident == nil,
               try sealRepairBaselines(now: now) > 0
            {
                let repairConfirmation = try await publishAndObserve(
                    now: now,
                    generation: generation
                )
                try assertActiveGeneration(generation)
                let verification = try await applyRemoteUntilStable(
                    now: now,
                    generation: generation
                )
                try assertActiveGeneration(generation)
                confirmation = (
                    confirmation.confirmedCount
                        + repairConfirmation.confirmedCount,
                    repairConfirmation.incident
                )
                remote = (
                    remote.appliedPublicationCount
                        + verification.appliedPublicationCount,
                    remote.appliedRecordCount + verification.appliedRecordCount,
                    verification.waitingRecordCount,
                    verification.endpointWaiting,
                    verification.incident
                )
            }
            let incident = confirmation.incident ?? remote.incident
            let stillPending = try ledger.pendingLocalPublications(
                generationID: generationID,
                producerID: producerID
            ).count
            guard try ledger.cleanCutAuthority()?.generationID == generationID else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication authority generation differs from runtime"
                )
            }
            let unfinishedJournal = try ledger.outboxSnapshot(
                generationID: generationID
            ).pendingCount
            let converged = stillPending == 0
                && unfinishedJournal == 0
                && remote.waitingRecordCount == 0
                && remote.endpointWaiting == false
                && incident == nil
            let effective = confirmation.confirmedCount > 0
                || remote.appliedRecordCount > 0
            let actionableForkConflict = incident == .producerForkDetected
                ? try syncRepository.latestReplicationForkConflictSet(
                    generationID: generationID
                ).map(Self.actionableForkConflict)
                : nil
            let completed = LocalFirstReplicationState(
                worker: .idle,
                convergence: converged
                    ? .converged
                    : incident == nil
                    ? .waitingForEndpoint
                    : .blocked,
                incident: incident,
                actionableForkConflict: actionableForkConflict,
                pendingLocalPublicationCount: stillPending,
                confirmedLocalPublicationCount: confirmation.confirmedCount,
                appliedRemotePublicationCount: remote.appliedPublicationCount,
                waitingRecordCount: remote.waitingRecordCount,
                lastSyncedAt: converged ? now : state.lastSyncedAt,
                lastEffectiveSyncedAt: effective
                    ? now
                    : state.lastEffectiveSyncedAt
            )
            try assertActiveGeneration(generation)
            try persist(completed, at: now)
            install(completed)
            return completed
        } catch is CancellationError {
            if enabled, control.generation == generation {
                install(stateWith(worker: .idle))
            }
            throw CancellationError()
        } catch {
            let failed = LocalFirstReplicationState(
                worker: .idle,
                convergence: .blocked,
                incident: .runtimeFailure,
                pendingLocalPublicationCount: state.pendingLocalPublicationCount,
                confirmedLocalPublicationCount: 0,
                appliedRemotePublicationCount: 0,
                waitingRecordCount: state.waitingRecordCount,
                lastSyncedAt: state.lastSyncedAt,
                lastEffectiveSyncedAt: state.lastEffectiveSyncedAt
            )
            try? persist(failed, at: now)
            install(failed)
            throw error
        }
    }

    func resolveForkConflicts(
        resolutionID: ReplicationDigest,
        decisions: [ReplicationForkConflictDecisionSelection],
        now: Date
    ) async throws -> LocalFirstReplicationState {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let actionable = state.actionableForkConflict,
              actionable.resolutionID == resolutionID,
              decisions.isEmpty == false,
              Set(decisions.map(\.conflictID)).count == decisions.count,
              Set(decisions.map(\.conflictID))
              == Set(actionable.conflicts.map(\.conflictID)),
              decisions.allSatisfy({ selection in
                  actionable.conflicts.first {
                      $0.conflictID == selection.conflictID
                  }?.allowedDecisions.contains(selection.decision) == true
              }),
              let resolution = try ledger.forkResolution(
                  resolutionID: resolutionID
              ), resolution.state == .branchesValidated
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "fork conflict command does not match current durable action"
            )
        }
        let resolvedCursor = try loadCursor().resolving(
            resolution.evidence
        )
        let result = try downloadCoordinator
            .resolveReplicationForkConflicts(
                resolution.evidence,
                decisions: decisions,
                decidedAt: now,
                cursorMetadata: try cursorMetadata(
                    resolvedCursor,
                    updatedAt: now
                ),
                expectedReplicationControl: control
            )
        guard result.closed,
              result.result.waitingCount == 0,
              result.conflicts.isEmpty
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "fork conflict decision did not produce a closed repair"
            )
        }
        install(
            LocalFirstReplicationState(
                worker: .idle,
                convergence: .waitingForEndpoint,
                incident: nil,
                pendingLocalPublicationCount: state
                    .pendingLocalPublicationCount,
                confirmedLocalPublicationCount: 0,
                appliedRemotePublicationCount: result.result.appliedCount,
                waitingRecordCount: 0,
                lastSyncedAt: state.lastSyncedAt,
                lastEffectiveSyncedAt: result.result.appliedCount > 0
                    ? now
                    : state.lastEffectiveSyncedAt
            )
        )
        return try await runOwnedReconcile(now: now)
    }

    func recoverPublicationWatermarkMismatch(now: Date) throws {
        let sqliteWatermark = try ledger.latestSealedReference(
            generationID: generationID,
            producerID: producerID
        )?.publicationWatermark
        let externalWatermark = try publicationWatermarkStore.load(
            in: publicationWatermarkScope(producerID: producerID)
        )
        guard sqliteWatermark != externalWatermark else { return }

        let snapshot = try engineRepository.load().snapshot()
        let records = try ReplicationSnapshotRecordBuilder().records(
            from: snapshot,
            modifiedBy: SyncDeviceID("replication-rollback-v2"),
            createdAt: now
        )
        guard records.isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "rollback recovery baseline snapshot produced no records"
            )
        }
        let retiringProducerID = producerID
        let replacementProducerID = UUID()
        let publication = try builder.seal(
            records: records,
            generationID: generationID,
            producerID: replacementProducerID,
            sequence: 1,
            previousSealDigest: nil
        )
        try ledger.rotateActiveProducerAndSealBaseline(
            retiringProducerID: retiringProducerID,
            replacementProducerID: replacementProducerID,
            publication: SQLiteSealedLocalPublication(
                publication: publication,
                journalEntryIDs: try syncRepository
                    .pendingReplicationOutboxEntryIDs(
                        generationID: generationID
                    )
            ),
            sealedAt: now,
            expectedReplicationControl: control
        )
        producerID = replacementProducerID
        try publicationWatermarkStore.compareAndSet(
            expected: nil,
            replacement: publication.reference.publicationWatermark,
            in: publicationWatermarkScope(
                producerID: replacementProducerID
            )
        )
    }

    func validatePublicationWatermark() throws {
        let sqliteWatermark = try ledger.latestSealedReference(
            generationID: generationID,
            producerID: producerID
        )?.publicationWatermark
        let externalWatermark = try publicationWatermarkStore.load(
            in: publicationWatermarkScope(producerID: producerID)
        )
        guard sqliteWatermark == externalWatermark else {
            throw ReplicationPublicationWatermarkStoreError.comparisonFailed
        }
    }

    func publicationWatermarkScope(
        producerID: UUID
    ) -> ReplicationPublicationWatermarkScope {
        ReplicationPublicationWatermarkScope(
            generationID: generationID,
            producerID: producerID
        )
    }

    func sealUnsealedJournal(now: Date) throws {
        guard try ledger.cleanCutAuthority()?.generationID == generationID else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication authority generation differs from sealing runtime"
            )
        }
        guard try ledger.producerBaselineIsConfirmed(
            generationID: generationID,
            producerID: producerID
        ) else { return }
        let entries = try syncRepository.unsealedReplicationOutboxEntries(
            generationID: generationID
        )
        guard entries.isEmpty == false else { return }
        let snapshot = try engineRepository.load().snapshot()
        let materialized = try SyncRecordMaterializer().records(
            for: entries,
            in: snapshot
        )
        guard materialized.isEmpty == false else { return }
        let predecessor = try ledger.latestSealedReference(
            generationID: generationID,
            producerID: producerID
        )
        let publication = try builder.seal(
            records: materialized,
            generationID: generationID,
            producerID: producerID,
            sequence: (predecessor?.sequence ?? 0) + 1,
            previousSealDigest: predecessor?.sealDigest
        )
        try ledger.recordSealedLocalPublications(
            [
                SQLiteSealedLocalPublication(
                    publication: publication,
                    journalEntryIDs: entries.map(\.id)
                ),
            ],
            sealedAt: now,
            expectedReplicationControl: control
        )
        try publicationWatermarkStore.compareAndSet(
            expected: predecessor?.publicationWatermark,
            replacement: publication.reference.publicationWatermark,
            in: publicationWatermarkScope(producerID: producerID)
        )
    }

    func sealRepairBaselines(now: Date) throws -> Int {
        let resolutions = try ledger.closedForkResolutionsAwaitingBaseline(
            generationID: generationID,
            producerID: producerID
        )
        guard resolutions.isEmpty == false else { return 0 }
        let snapshot = try engineRepository.load().snapshot()
        let records = try ReplicationSnapshotRecordBuilder().records(
            from: snapshot,
            modifiedBy: SyncDeviceID("replication-repair-v2"),
            createdAt: now
        )
        guard records.isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "repair baseline snapshot produced no records"
            )
        }
        for resolution in resolutions {
            let manifest = try resolutionManifest(for: resolution)
            if resolution.evidence.producerID == producerID {
                let retiringProducerID = producerID
                let replacementProducerID = UUID()
                let publication = try builder.seal(
                    records: records,
                    generationID: generationID,
                    producerID: replacementProducerID,
                    sequence: 1,
                    previousSealDigest: nil,
                    basedOnResolutionID: resolution.resolutionID,
                    resolutionManifest: manifest
                )
                try ledger.rotateActiveProducerAndSealBaseline(
                    retiringProducerID: retiringProducerID,
                    replacementProducerID: replacementProducerID,
                    publication: SQLiteSealedLocalPublication(
                        publication: publication,
                        journalEntryIDs: try syncRepository
                            .pendingReplicationOutboxEntryIDs(
                                generationID: generationID
                            )
                    ),
                    sealedAt: now,
                    expectedReplicationControl: control
                )
                producerID = replacementProducerID
                try publicationWatermarkStore.compareAndSet(
                    expected: nil,
                    replacement: publication.reference
                        .publicationWatermark,
                    in: publicationWatermarkScope(
                        producerID: replacementProducerID
                    )
                )
                continue
            }
            let predecessor = try ledger.latestSealedReference(
                generationID: generationID,
                producerID: producerID
            )
            let publication = try builder.seal(
                records: records,
                generationID: generationID,
                producerID: producerID,
                sequence: (predecessor?.sequence ?? 0) + 1,
                previousSealDigest: predecessor?.sealDigest,
                basedOnResolutionID: resolution.resolutionID,
                resolutionManifest: manifest
            )
            try ledger.recordSealedLocalPublications(
                [
                    SQLiteSealedLocalPublication(
                        publication: publication,
                        journalEntryIDs: []
                    ),
                ],
                sealedAt: now,
                expectedReplicationControl: control
            )
            try publicationWatermarkStore.compareAndSet(
                expected: predecessor?.publicationWatermark,
                replacement: publication.reference.publicationWatermark,
                in: publicationWatermarkScope(producerID: producerID)
            )
        }
        return resolutions.count
    }

    func publishAndObserve(
        now: Date,
        generation: UInt64
    ) async throws -> (
        confirmedCount: Int,
        incident: LocalFirstReplicationIncident?
    ) {
        try validatePublicationWatermark()
        let pending = try ledger.pendingLocalPublications(
            generationID: generationID,
            producerID: producerID
        )
        var receipts: [ReplicationPublicationReceipt] = []
        for publication in pending {
            try Task.checkCancellation()
            try assertActiveGeneration(generation)
            await receipts.append(try endpoint.publish(sealed: publication))
            try assertActiveGeneration(generation)
        }
        let observations = try await endpoint.observe(pending: receipts)
        try assertActiveGeneration(generation)
        var confirmed = 0
        var incident: LocalFirstReplicationIncident?
        for observation in observations {
            switch observation.state {
            case .confirmed:
                _ = try ledger.recordConfirmation(
                    for: observation.reference,
                    confirmedAt: now,
                    expectedReplicationControl: control
                )
                confirmed += 1
            case .awaiting:
                break
            case .blockedUserAttention:
                incident = .endpointRequiresUserAttention
            case .blockedCorruption:
                incident = .endpointCorruption
            }
        }
        return (confirmed, incident)
    }

    func applyRemoteUntilStable(
        now: Date,
        generation: UInt64
    ) async throws -> (
        appliedPublicationCount: Int,
        appliedRecordCount: Int,
        waitingRecordCount: Int,
        endpointWaiting: Bool,
        incident: LocalFirstReplicationIncident?
    ) {
        var cursor = try loadCursor()
        var appliedPublications = 0
        var appliedRecords = 0
        var waitingRecords = 0
        while true {
            try Task.checkCancellation()
            let previousCursor = cursor
            let page = try await endpoint.read(
                after: cursor,
                budget: ReplicationReadBudget(
                    maximumPublications: 64,
                    maximumBytes: 8 * 1024 * 1024
                )
            )
            try assertActiveGeneration(generation)
            if page.state == .awaitingMaterialization {
                return (
                    appliedPublications,
                    appliedRecords,
                    waitingRecords,
                    true,
                    nil
                )
            }
            if case let .blockedProducerFork(evidence) = page.state {
                let resolution = try ledger.recordValidatedForkEvidence(
                    evidence,
                    detectedAt: now,
                    expectedReplicationControl: control
                )
                guard resolution.state == .branchesValidated else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "fork resolution is not ready for branch apply"
                    )
                }
                install(
                    LocalFirstReplicationState(
                        worker: .running,
                        convergence: .blocked,
                        incident: .producerForkDetected,
                        actionableForkConflict: Self.actionableForkConflict(
                            try syncRepository.replicationForkConflictSet(
                                resolutionID: evidence.resolutionID
                            )
                        ),
                        pendingLocalPublicationCount: state
                            .pendingLocalPublicationCount,
                        confirmedLocalPublicationCount: 0,
                        appliedRemotePublicationCount: appliedPublications,
                        waitingRecordCount: waitingRecords,
                        lastSyncedAt: state.lastSyncedAt,
                        lastEffectiveSyncedAt: state.lastEffectiveSyncedAt
                    )
                )
                let resolvedCursor = cursor.resolving(evidence)
                let result = try downloadCoordinator
                    .downloadAndMergeReplicationFork(
                        evidence,
                        detectedAt: now,
                        cursorMetadata: try cursorMetadata(
                            resolvedCursor,
                            updatedAt: now
                        ),
                        expectedReplicationControl: control
                    )
                if result.closed == false {
                    let candidate: ReceivedReplicationPublication?
                    do {
                        candidate = try exactResolutionBaseline(
                            page.resolutionBaselines,
                            for: evidence.resolutionID
                        )
                    } catch {
                        return (
                            appliedPublications,
                            appliedRecords,
                            result.result.waitingCount,
                            false,
                            .repairBaselineRejected
                        )
                    }
                    guard let candidate else {
                        return (
                            appliedPublications,
                            appliedRecords,
                            result.result.waitingCount,
                            false,
                            .producerForkDetected
                        )
                    }
                    guard let manifest = candidate.resolutionManifest,
                          let decidedAt = manifest.decidedAt
                    else {
                        return (
                            appliedPublications,
                            appliedRecords,
                            result.result.waitingCount,
                            false,
                            .repairBaselineRejected
                        )
                    }
                    let replayed: SQLiteReplicationForkApplyResult
                    do {
                        replayed = try downloadCoordinator
                            .resolveReplicationForkConflicts(
                                evidence,
                                decisions: manifest.outcomes.map {
                                    ReplicationForkConflictDecisionSelection(
                                        conflictID: $0.conflictID,
                                        decision: decision(from: $0.decision)
                                    )
                                },
                                decidedAt: decidedAt,
                                cursorMetadata: try cursorMetadata(
                                    resolvedCursor,
                                    updatedAt: now
                                ),
                                repairBaselineRecords: candidate.records,
                                expectedManifest: manifest,
                                expectedReplicationControl: control
                            )
                    } catch {
                        return (
                            appliedPublications,
                            appliedRecords,
                            result.result.waitingCount,
                            false,
                            .repairBaselineRejected
                        )
                    }
                    guard replayed.closed,
                          replayed.result.waitingCount == 0,
                          replayed.conflicts.isEmpty
                    else {
                        return (
                            appliedPublications,
                            appliedRecords,
                            replayed.result.waitingCount,
                            false,
                            .repairBaselineRejected
                        )
                    }
                    appliedPublications += evidence.branches.count + 1
                    appliedRecords += replayed.result.appliedCount
                    waitingRecords = 0
                    cursor = resolvedCursor
                    continue
                }
                guard result.closed else {
                    return (
                        appliedPublications,
                        appliedRecords,
                        result.result.waitingCount,
                        false,
                        .producerForkDetected
                    )
                }
                appliedPublications += evidence.branches.count
                appliedRecords += result.result.appliedCount
                waitingRecords = result.result.waitingCount
                cursor = resolvedCursor
                continue
            }
            let remote = page.publications.filter {
                $0.reference.producerID != producerID
            }
            guard try repairBaselinesAreAuthorized(remote) else {
                return (
                    appliedPublications,
                    appliedRecords,
                    waitingRecords,
                    false,
                    .repairBaselineRejected
                )
            }
            let metadata = try cursorMetadata(page.cursor, updatedAt: now)
            if remote.isEmpty {
                try syncRepository.saveMetadata(
                    metadata,
                    expectedReplicationControl: control
                )
            } else {
                let result = try downloadCoordinator
                    .downloadAndMergeReplicationRecords(
                        remote.flatMap(\.records),
                        detectedAt: now,
                        cursorMetadata: metadata,
                        expectedReplicationControl: control
                    )
                appliedPublications += remote.count
                appliedRecords += result.appliedCount
                waitingRecords = result.waitingCount
            }
            cursor = page.cursor
            if page.publications.isEmpty, page.hasMore == false {
                return (
                    appliedPublications,
                    appliedRecords,
                    waitingRecords,
                    false,
                    nil
                )
            }
            guard page.cursor != previousCursor || page.hasMore == false else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication endpoint cursor did not advance"
                )
            }
        }
    }

    var cursorMetadataKey: String {
        "localFirst.replication.v2.cursor.\(endpoint.namespace)"
    }

    func loadCursor() throws -> ReplicationReadCursor {
        guard let metadata = try syncRepository.metadata(
            for: cursorMetadataKey
        ) else { return .origin }
        do {
            return try ReplicationPublicationBuilder.canonicalDecoder().decode(
                ReplicationReadCursor.self,
                from: metadata.value
            )
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication read cursor is invalid"
            )
        }
    }

    func cursorMetadata(
        _ cursor: ReplicationReadCursor,
        updatedAt: Date
    ) throws -> SyncMetadataEntry {
        SyncMetadataEntry(
            key: cursorMetadataKey,
            value: try ReplicationPublicationBuilder.canonicalEncoder().encode(
                cursor
            ),
            updatedAt: updatedAt
        )
    }

    func assertActiveGeneration(_ generation: UInt64) throws {
        guard enabled,
              control.policy == .enabled,
              control.generation == generation,
              try syncRepository.localFirstReplicationControl()
              == control
        else {
            throw CancellationError()
        }
    }

    func markStoppingDelayed(generation: UInt64) {
        guard enabled == false,
              control.policy == .disabled,
              control.generation == generation,
              state.worker == .stopping
        else { return }
        let delayed = stateWith(worker: .stoppingDelayed)
        do {
            try persist(delayed, at: Date())
            install(delayed)
        } catch {}
    }

    func repairBaselinesAreAuthorized(
        _ publications: [ReceivedReplicationPublication]
    ) throws -> Bool {
        for publication in publications {
            guard let resolutionID = publication.reference
                .basedOnResolutionID
            else {
                guard publication.resolutionManifest == nil else {
                    return false
                }
                continue
            }
            guard let resolution = try ledger.forkResolution(
                resolutionID: resolutionID
            ), resolution.state == .closed,
                resolution.evidence.generationID
                == publication.reference.generationID,
                publication.resolutionManifest
                == (try resolutionManifest(for: resolution))
            else {
                return false
            }
        }
        return true
    }

    func resolutionManifest(
        for resolution: SQLiteReplicationForkResolution
    ) throws -> ReplicationForkResolutionManifest {
        guard resolution.state == .closed else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "an open fork resolution cannot publish a manifest"
            )
        }
        guard let conflictSet = try syncRepository
            .replicationForkConflictSet(
                resolutionID: resolution.resolutionID
            )
        else {
            return ReplicationForkResolutionManifest(
                resolutionID: resolution.resolutionID,
                decidedAt: nil,
                outcomes: []
            )
        }
        let dates = conflictSet.conflicts.compactMap(\.decidedAt)
        guard dates.count == conflictSet.conflicts.count,
              let decidedAt = dates.first,
              dates.allSatisfy({
                  $0.timeIntervalSinceReferenceDate.bitPattern
                      == decidedAt.timeIntervalSinceReferenceDate.bitPattern
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "a closed fork conflict set has no exact decision time"
            )
        }
        let outcomes = try conflictSet.conflicts.map { stored in
            guard let decision = stored.decision else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "a closed fork conflict set has an unresolved outcome"
                )
            }
            return ReplicationForkResolutionOutcome(
                conflictID: stored.conflict.id,
                decision: protocolDecision(from: decision),
                resultReference: stored.resultReference.map {
                    ReplicationForkResolutionResultReference(
                        entityType: $0.entityType,
                        entityID: $0.entityID
                    )
                }
            )
        }
        return ReplicationForkResolutionManifest(
            resolutionID: resolution.resolutionID,
            decidedAt: decidedAt,
            outcomes: outcomes
        )
    }

    func exactResolutionBaseline(
        _ candidates: [ReceivedReplicationPublication],
        for resolutionID: ReplicationDigest
    ) throws -> ReceivedReplicationPublication? {
        guard let first = candidates.first else { return nil }
        guard let manifest = first.resolutionManifest,
              first.reference.basedOnResolutionID == resolutionID,
              manifest.resolutionID == resolutionID,
              candidates.allSatisfy({
                  $0.reference.basedOnResolutionID == resolutionID
                      && $0.resolutionManifest == manifest
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "fork repair baselines contain competing manifests"
            )
        }
        return first
    }

    func protocolDecision(
        from decision: ReplicationForkConflictDecision
    ) -> ReplicationForkResolutionDecision {
        switch decision {
        case .keepCurrent: .keepCurrent
        case .acceptRemote: .acceptRemote
        case .copyAsNew: .copyAsNew
        }
    }

    func decision(
        from decision: ReplicationForkResolutionDecision
    ) -> ReplicationForkConflictDecision {
        switch decision {
        case .keepCurrent: .keepCurrent
        case .acceptRemote: .acceptRemote
        case .copyAsNew: .copyAsNew
        }
    }

    func journalEntryComesBefore(
        _ lhs: SyncJournalEntry,
        _ rhs: SyncJournalEntry
    ) -> Bool {
        if lhs.entityType.dependencyOrder != rhs.entityType.dependencyOrder {
            return lhs.entityType.dependencyOrder
                < rhs.entityType.dependencyOrder
        }
        if lhs.changedAt != rhs.changedAt {
            return lhs.changedAt < rhs.changedAt
        }
        if lhs.entityID != rhs.entityID {
            return lhs.entityID < rhs.entityID
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func persist(_ state: LocalFirstReplicationState, at date: Date) throws {
        try syncRepository.saveMetadata(
            SyncMetadataEntry(
                key: Self.stateMetadataKey,
                value: try ReplicationPublicationBuilder.canonicalEncoder()
                    .encode(state),
                updatedAt: date
            ),
            expectedReplicationControl: control
        )
    }

    func stateWith(
        worker: LocalFirstReplicationWorkerState
    ) -> LocalFirstReplicationState {
        LocalFirstReplicationState(
            worker: worker,
            convergence: state.convergence,
            incident: state.incident,
            actionableForkConflict: state.actionableForkConflict,
            pendingLocalPublicationCount: state.pendingLocalPublicationCount,
            confirmedLocalPublicationCount: state.confirmedLocalPublicationCount,
            appliedRemotePublicationCount: state.appliedRemotePublicationCount,
            waitingRecordCount: state.waitingRecordCount,
            lastSyncedAt: state.lastSyncedAt,
            lastEffectiveSyncedAt: state.lastEffectiveSyncedAt
        )
    }

    func install(_ next: LocalFirstReplicationState) {
        state = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
    }

    func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    static func actionableForkConflict(
        _ set: SQLiteReplicationForkConflictSet
    ) -> LocalFirstReplicationActionableForkConflict {
        LocalFirstReplicationActionableForkConflict(
            resolutionID: set.resolutionID,
            conflicts: set.conflicts.map {
                LocalFirstReplicationForkConflictSummary(
                    conflictID: $0.conflict.id,
                    type: $0.conflict.type,
                    entityType: $0.conflict.entityType,
                    allowedDecisions: ReplicationForkConflictDecision
                        .allowedDecisions(
                        for: $0.conflict
                        )
                )
            }
        )
    }

    static func actionableForkConflict(
        _ set: SQLiteReplicationForkConflictSet?
    ) -> LocalFirstReplicationActionableForkConflict? {
        set.map(actionableForkConflict)
    }
}

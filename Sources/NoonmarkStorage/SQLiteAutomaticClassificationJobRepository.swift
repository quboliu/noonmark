import Foundation
import NoonmarkCore
import SQLite3

// swiftlint:disable:next type_name
public final class SQLiteAutomaticClassificationJobRepository {
    private static let busyTimeoutMilliseconds: Int32 = 250

    private let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func job(id: UUID) throws -> AutomaticClassificationJob? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try SQLiteSchema.installOrValidate(on: database)
        return try SQLiteAutomaticClassificationJobSQL.job(id: id, in: database)
    }

    public func jobs(
        states: Set<AutomaticClassificationJobState> = Set(
            AutomaticClassificationJobState.allCases
        )
    ) throws -> [AutomaticClassificationJob] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try SQLiteSchema.installOrValidate(on: database)
        return try SQLiteAutomaticClassificationJobSQL.jobs(
            states: states,
            in: database
        )
    }

    public func providerCircuit() throws -> AutomaticClassificationProviderCircuit? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try SQLiteSchema.installOrValidate(on: database)
        return try SQLiteAutomaticClassificationJobSQL.providerCircuit(in: database)
    }

    @discardableResult
    public func reconcileProviderExecution(
        _ execution: AutomaticClassificationProviderExecution,
        now: Date
    ) throws -> AutomaticClassificationProviderCircuit {
        try validateTransitionDate(now, label: "provider reconciliation now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.reconcileProviderExecution(
                execution,
                now: now,
                in: database
            )
        }
    }

    @discardableResult
    public func resetProviderCircuit(
        executionRevision: UUID,
        now: Date
    ) throws -> AutomaticClassificationProviderCircuit {
        try validateTransitionDate(now, label: "provider circuit reset now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.resetProviderCircuit(
                executionRevision: executionRevision,
                now: now,
                in: database
            )
        }
    }

    public func pendingBacklog() throws -> AutomaticClassificationBacklogSnapshot {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try SQLiteSchema.installOrValidate(on: database)
        return try SQLiteAutomaticClassificationJobSQL.pendingBacklog(in: database)
    }

    @discardableResult
    public func resolveBacklog(
        _ snapshot: AutomaticClassificationBacklogSnapshot,
        decision: AutomaticClassificationBacklogDecision,
        now: Date
    ) throws -> AutomaticClassificationBacklogResolution {
        try validateTransitionDate(now, label: "backlog decision now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.resolveBacklog(
                snapshot,
                decision: decision,
                now: now,
                in: database
            )
        }
    }

    public func nextDispatch(
        now: Date,
        staleBefore: Date,
        claimID: UUID = UUID()
    ) throws -> AutomaticClassificationNextDispatch {
        try SQLiteAutomaticClassificationJobSQL.validateDate(now, label: "dispatch now")
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            staleBefore,
            label: "dispatch staleBefore"
        )
        guard staleBefore <= now else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification staleBefore must not follow now"
            )
        }
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.nextDispatch(
                now: now,
                staleBefore: staleBefore,
                claimID: claimID,
                in: database
            )
        }
    }

    public func resolveProviderAttempt(
        _ outcome: AutomaticClassificationProviderAttemptOutcome,
        for claim: AutomaticClassificationJobClaim,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "provider outcome now")
        switch outcome {
        case let .checkpoint(proposal):
            try SQLiteAutomaticClassificationJobSQL.validateProposal(proposal)
        case let .rateLimited(retryAt), let .transientFailure(retryAt):
            try validateTransitionDate(retryAt, label: "provider retryAt")
            guard retryAt > now else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "provider circuit retryAt must follow now"
                )
            }
        case .invalidResponse, .credentialsRejected:
            break
        }
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.resolveProviderAttempt(
                outcome,
                for: claim,
                now: now,
                in: database
            )
        }
    }

    public func claimNext(
        now: Date,
        staleBefore: Date,
        claimID: UUID = UUID()
    ) throws -> AutomaticClassificationJobClaim? {
        try SQLiteAutomaticClassificationJobSQL.validateDate(now, label: "claim now")
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            staleBefore,
            label: "claim staleBefore"
        )
        guard staleBefore <= now else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification staleBefore must not follow now"
            )
        }
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.claimNext(
                now: now,
                staleBefore: staleBefore,
                claimID: claimID,
                in: database
            )
        }
    }

    public func checkpointProposal(
        _ proposal: Data,
        for claim: AutomaticClassificationJobClaim,
        now: Date
    ) throws {
        try SQLiteAutomaticClassificationJobSQL.validateProposal(proposal)
        try SQLiteAutomaticClassificationJobSQL.validateDate(
            now,
            label: "proposal checkpoint now"
        )
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.checkpointProposal(
                proposal,
                for: claim,
                now: now,
                in: database
            )
        }
    }

    public func supersede(
        _ fence: AutomaticClassificationJobFence,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "supersede now")
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.supersede(
                fence,
                errorCode: .contentOrCatalogChanged,
                now: now,
                in: database
            )
        }
    }

    public func fail(
        _ fence: AutomaticClassificationJobFence,
        errorCode: AutomaticClassificationJobErrorCode,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "failure now")
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.fail(
                fence,
                errorCode: errorCode,
                now: now,
                in: database
            )
        }
    }

    public func retry(
        _ fence: AutomaticClassificationJobFence,
        to state: AutomaticClassificationJobState,
        availableAt: Date,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "retry now")
        try validateTransitionDate(availableAt, label: "retry availableAt")
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.retry(
                fence,
                to: state,
                availableAt: availableAt,
                now: now,
                in: database
            )
        }
    }

    public func reschedule(
        _ fence: AutomaticClassificationJobFence,
        errorCode: AutomaticClassificationJobErrorCode,
        availableAt: Date,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "reschedule now")
        try validateTransitionDate(availableAt, label: "reschedule availableAt")
        guard availableAt > now else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification reschedule must target a future date"
            )
        }
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.reschedule(
                fence,
                errorCode: errorCode,
                availableAt: availableAt,
                now: now,
                in: database
            )
        }
    }

    public func cancel(
        _ fence: AutomaticClassificationJobFence,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "cancel now")
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.cancel(
                fence,
                now: now,
                in: database
            )
        }
    }

    @discardableResult
    public func supersedeJobs(
        forChain chainID: TaskChainID,
        now: Date
    ) throws -> Int {
        try validateTransitionDate(now, label: "manual supersede now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.supersedeJobs(
                forChain: chainID,
                now: now,
                in: database
            )
        }
    }

    @discardableResult
    public func cancelJobs(
        forUndoneChain chainID: TaskChainID,
        now: Date
    ) throws -> Int {
        try validateTransitionDate(now, label: "undo cancellation now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.cancelJobs(
                forUndoneChain: chainID,
                now: now,
                in: database
            )
        }
    }

    @discardableResult
    public func makeProviderDependentJobsWaitForConfiguration(
        now: Date
    ) throws -> Int {
        try validateTransitionDate(now, label: "provider disabled now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL
                .makeProviderDependentJobsWaitForConfiguration(
                    now: now,
                    in: database
                )
        }
    }

    @discardableResult
    public func makeWaitingForConfigurationJobsReady(
        now: Date
    ) throws -> Int {
        try validateTransitionDate(now, label: "provider enabled now")
        return try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL
                .makeWaitingForConfigurationJobsReady(
                    now: now,
                    in: database
                )
        }
    }

    public func replace(
        _ fence: AutomaticClassificationJobFence,
        with replacement: AutomaticClassificationJobEnqueue,
        now: Date
    ) throws {
        try validateTransitionDate(now, label: "replacement now")
        try SQLiteAutomaticClassificationJobSQL.validate(replacement)
        try withImmediateTransaction { database in
            try SQLiteAutomaticClassificationJobSQL.replace(
                fence,
                with: replacement,
                now: now,
                in: database
            )
        }
    }

    private func validateTransitionDate(_ date: Date, label: String) throws {
        try SQLiteAutomaticClassificationJobSQL.validateDate(date, label: label)
    }

    private func withImmediateTransaction<T>(
        _ body: (OpaquePointer?) throws -> T
    ) throws -> T {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try SQLiteSchema.installOrValidate(on: database)
        try SQLiteAutomaticClassificationJobSQL.execute(
            "BEGIN IMMEDIATE TRANSACTION",
            on: database
        )
        do {
            let result = try body(database)
            try SQLiteAutomaticClassificationJobSQL.execute("COMMIT", on: database)
            return result
        } catch {
            try? SQLiteAutomaticClassificationJobSQL.execute("ROLLBACK", on: database)
            throw error
        }
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let openResult = sqlite3_open(databaseURL.path, &database)
        guard openResult == SQLITE_OK else {
            let error = SQLiteAutomaticClassificationJobSQL.repositoryError(
                for: openResult,
                database: database,
                otherwise: SQLiteRepositoryError.openFailed
            )
            sqlite3_close(database)
            throw error
        }
        let extendedResult = sqlite3_extended_result_codes(database, 1)
        guard extendedResult == SQLITE_OK else {
            let error = SQLiteAutomaticClassificationJobSQL.repositoryError(
                for: extendedResult,
                database: database,
                otherwise: SQLiteRepositoryError.openFailed
            )
            sqlite3_close(database)
            throw error
        }
        let timeoutResult = sqlite3_busy_timeout(
            database,
            Self.busyTimeoutMilliseconds
        )
        guard timeoutResult == SQLITE_OK else {
            let error = SQLiteAutomaticClassificationJobSQL.repositoryError(
                for: timeoutResult,
                database: database,
                otherwise: SQLiteRepositoryError.openFailed
            )
            sqlite3_close(database)
            throw error
        }
        let foreignKeysResult = sqlite3_exec(
            database,
            "PRAGMA foreign_keys = ON",
            nil,
            nil,
            nil
        )
        guard foreignKeysResult == SQLITE_OK else {
            let error = SQLiteAutomaticClassificationJobSQL.repositoryError(
                for: foreignKeysResult,
                database: database,
                otherwise: SQLiteRepositoryError.openFailed
            )
            sqlite3_close(database)
            throw error
        }
        return database
    }
}

enum SQLiteAutomaticClassificationJobSQL {
    static func enqueue(
        _ enqueue: AutomaticClassificationJobEnqueue,
        into database: OpaquePointer?
    ) throws {
        try validate(enqueue)
        let sql = """
        INSERT INTO automatic_classification_jobs(
            id, chain_id, content_digest, classification_fingerprint,
            authority_payload, catalog_digest, generation, state,
            dispatch_authorization, authorization_id, authorized_at,
            attempt, claim_id,
            proposal_checkpoint, error_code, available_at, claimed_at,
            created_at, updated_at, terminal_at, cancelled_by_undo
        )
        VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
            0, NULL, NULL, NULL, ?, NULL, ?, ?, NULL, 0
        )
        """
        try run(sql, on: database) { statement in
            bind(enqueue.id.uuidString, to: 1, in: statement)
            bind(enqueue.chainID.rawValue.uuidString, to: 2, in: statement)
            bind(enqueue.contentDigest, to: 3, in: statement)
            bind(enqueue.classificationFingerprint, to: 4, in: statement)
            bind(enqueue.authorityPayload, to: 5, in: statement)
            bind(enqueue.catalogDigest, to: 6, in: statement)
            bind(enqueue.generation, to: 7, in: statement)
            bind(enqueue.initialState.rawValue, to: 8, in: statement)
            bind(enqueue.dispatchAuthorization.rawValue, to: 9, in: statement)
            bind(enqueue.authorizationID?.uuidString, to: 10, in: statement)
            bind(enqueue.authorizedAt, to: 11, in: statement)
            bind(enqueue.availableAt, to: 12, in: statement)
            bind(enqueue.createdAt, to: 13, in: statement)
            bind(enqueue.createdAt, to: 14, in: statement)
        }
    }

    static func job(
        id: UUID,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationJob? {
        let rows = try query(
            """
            SELECT \(selectionColumns)
            FROM automatic_classification_jobs
            WHERE id = ?
            """,
            on: database,
            bind: { statement in
                bind(id.uuidString, to: 1, in: statement)
            },
            row: decodeJob
        )
        guard rows.count <= 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification job identity is duplicated"
            )
        }
        return rows.first
    }

    static func jobs(
        states: Set<AutomaticClassificationJobState>,
        in database: OpaquePointer?
    ) throws -> [AutomaticClassificationJob] {
        guard states.isEmpty == false else { return [] }
        let orderedStates = states.sorted { $0.rawValue < $1.rawValue }
        let placeholders = Array(repeating: "?", count: orderedStates.count)
            .joined(separator: ", ")
        return try query(
            """
            SELECT \(selectionColumns)
            FROM automatic_classification_jobs
            WHERE state IN (\(placeholders))
            ORDER BY created_at, id
            """,
            on: database,
            bind: { statement in
                for (index, state) in orderedStates.enumerated() {
                    bind(state.rawValue, to: Int32(index + 1), in: statement)
                }
            },
            row: decodeJob
        )
    }

    static func providerCircuit(
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationProviderCircuit? {
        let rows = try query(
            """
            SELECT provider_execution_revision, state, failure_code,
                consecutive_failures, retry_at, probe_job_id, probe_generation,
                probe_attempt, probe_claim_id, opened_at, updated_at,
                transition_version
            FROM automatic_classification_provider_circuit
            WHERE singleton_id = 1
            """,
            on: database,
            bind: { _ in },
            row: decodeProviderCircuit
        )
        guard rows.count <= 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification provider circuit is duplicated"
            )
        }
        return rows.first
    }

    static func reconcileProviderExecution(
        _ execution: AutomaticClassificationProviderExecution,
        now: Date,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationProviderCircuit {
        let current = try providerCircuit(in: database)
        switch execution {
        case .unconfigured:
            _ = try makeProviderDependentJobsWaitForConfiguration(
                now: now,
                in: database
            )
            if let current, current.state == .unconfigured {
                return current
            }
            let circuit = makeCircuit(
                revision: nil,
                state: .unconfigured,
                now: now,
                transitionVersion: try nextTransitionVersion(after: current)
            )
            try writeProviderCircuit(circuit, in: database)
            return circuit
        case let .configured(executionRevision):
            // swiftlint:disable opening_brace
            if let current,
               current.providerExecutionRevision == executionRevision,
               current.state != .unconfigured
            {
                if current.state == .closed {
                    _ = try makeAuthorizedWaitingJobsReady(now: now, in: database)
                }
                return current
            }
            // swiftlint:enable opening_brace
            _ = try makeProviderDependentJobsWaitForConfiguration(
                now: now,
                in: database
            )
            let circuit = makeCircuit(
                revision: executionRevision,
                state: .closed,
                now: now,
                transitionVersion: try nextTransitionVersion(after: current)
            )
            try writeProviderCircuit(circuit, in: database)
            _ = try makeAuthorizedWaitingJobsReady(now: now, in: database)
            return circuit
        }
    }

    static func resetProviderCircuit(
        executionRevision: UUID,
        now: Date,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationProviderCircuit {
        guard let current = try providerCircuit(in: database),
              current.providerExecutionRevision == executionRevision,
              current.state == .blocked
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "provider circuit reset does not match the configured execution"
            )
        }
        _ = try makeProviderDependentJobsWaitForConfiguration(now: now, in: database)
        let circuit = makeCircuit(
            revision: executionRevision,
            state: .closed,
            now: now,
            transitionVersion: try nextTransitionVersion(after: current)
        )
        try writeProviderCircuit(circuit, in: database)
        _ = try makeAuthorizedWaitingJobsReady(now: now, in: database)
        return circuit
    }

    static func pendingBacklog(
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationBacklogSnapshot {
        let jobs = try query(
            """
            SELECT \(selectionColumns)
            FROM automatic_classification_jobs
            WHERE dispatch_authorization = 'pendingUserDecision'
                AND state = 'waitingForConfiguration'
            ORDER BY created_at, id
            """,
            on: database,
            bind: { _ in },
            row: decodeJob
        )
        return AutomaticClassificationBacklogSnapshot(
            items: jobs.map {
                AutomaticClassificationBacklogItem(
                    fence: $0.fence,
                    chainID: $0.chainID,
                    contentDigest: $0.contentDigest,
                    catalogDigest: $0.catalogDigest,
                    createdAt: $0.createdAt
                )
            }
        )
    }

    static func resolveBacklog(
        _ snapshot: AutomaticClassificationBacklogSnapshot,
        decision: AutomaticClassificationBacklogDecision,
        now: Date,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationBacklogResolution {
        guard Set(snapshot.items.map(\.fence)).count == snapshot.items.count else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification backlog snapshot contains duplicate fences"
            )
        }
        let circuit = try providerCircuit(in: database)
        let providerIsConfigured = circuit?.state != nil
            && circuit?.state != .unconfigured
        var authorizedCount = 0
        var skippedCount = 0
        var ignoredCount = 0
        for item in snapshot.items {
            guard let current = try job(id: item.fence.jobID, in: database),
                  current.fence == item.fence,
                  current.chainID == item.chainID,
                  current.contentDigest == item.contentDigest,
                  current.catalogDigest == item.catalogDigest,
                  current.dispatchAuthorization == .pendingUserDecision,
                  current.state == .waitingForConfiguration
            else {
                ignoredCount += 1
                continue
            }
            switch decision {
            case let .authorize(decisionID):
                try run(
                    """
                    UPDATE automatic_classification_jobs
                    SET dispatch_authorization = 'explicit', authorization_id = ?,
                        authorized_at = ?, state = ?, error_code = NULL,
                        available_at = ?, updated_at = ?
                    WHERE id = ? AND generation = ? AND attempt = ?
                        AND claim_id IS NULL
                        AND state = 'waitingForConfiguration'
                        AND dispatch_authorization = 'pendingUserDecision'
                    """,
                    on: database
                ) { statement in
                    bind(decisionID.uuidString, to: 1, in: statement)
                    bind(now, to: 2, in: statement)
                    bind(
                        providerIsConfigured
                            ? AutomaticClassificationJobState.ready.rawValue
                            : AutomaticClassificationJobState.waitingForConfiguration.rawValue,
                        to: 3,
                        in: statement
                    )
                    bind(now, to: 4, in: statement)
                    bind(now, to: 5, in: statement)
                    bindFence(item.fence, startingAt: 6, in: statement)
                }
                try requireSingleCASChange(in: database)
                authorizedCount += 1
            case .skip:
                try run(
                    """
                    UPDATE automatic_classification_jobs
                    SET state = 'cancelled', error_code = 'backlogSkippedByUser',
                        updated_at = ?, terminal_at = ?, cancelled_by_undo = 0
                    WHERE id = ? AND generation = ? AND attempt = ?
                        AND claim_id IS NULL
                        AND state = 'waitingForConfiguration'
                        AND dispatch_authorization = 'pendingUserDecision'
                    """,
                    on: database
                ) { statement in
                    bind(now, to: 1, in: statement)
                    bind(now, to: 2, in: statement)
                    bindFence(item.fence, startingAt: 3, in: statement)
                }
                try requireSingleCASChange(in: database)
                skippedCount += 1
            }
        }
        return AutomaticClassificationBacklogResolution(
            authorizedCount: authorizedCount,
            skippedCount: skippedCount,
            ignoredCount: ignoredCount
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    static func nextDispatch(
        now: Date,
        staleBefore: Date,
        claimID: UUID,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationNextDispatch {
        if let proposal = try firstJob(
            where: "state = 'proposalReady' AND claimed_at <= ?",
            orderBy: "claimed_at, created_at, id",
            in: database,
            bind: { statement in bind(staleBefore, to: 1, in: statement) }
        ) {
            return .claimed(
                try claim(proposal, now: now, claimID: claimID, in: database)
            )
        }

        guard var circuit = try providerCircuit(in: database) else {
            return try noProviderDispatch(
                now: now,
                staleBefore: staleBefore,
                in: database
            )
        }
        switch circuit.state {
        case .unconfigured:
            return try noProviderDispatch(
                now: now,
                staleBefore: staleBefore,
                in: database
            )
        case .blocked:
            return .providerBlocked(errorCode: circuit.failureCode ?? .providerRejected)
        case .open:
            guard let retryAt = circuit.retryAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "open provider circuit has no retry date"
                )
            }
            guard retryAt <= now else { return .idle(nextWakeAt: retryAt) }
            guard let candidate = try nextProviderCandidate(
                now: now,
                staleBefore: staleBefore,
                in: database
            ) else {
                return .idle(
                    nextWakeAt: try nextProviderWakeDate(
                        now: now,
                        staleBefore: staleBefore,
                        in: database
                    )
                )
            }
            let claim = try claim(candidate, now: now, claimID: claimID, in: database)
            circuit = AutomaticClassificationProviderCircuit(
                providerExecutionRevision: circuit.providerExecutionRevision,
                state: .halfOpen,
                failureCode: circuit.failureCode,
                consecutiveFailures: circuit.consecutiveFailures,
                retryAt: nil,
                probeFence: claim.fence,
                openedAt: circuit.openedAt,
                updatedAt: now,
                transitionVersion: try nextTransitionVersion(after: circuit)
            )
            try writeProviderCircuit(circuit, in: database)
            return .claimed(claim)
        case .halfOpen:
            guard let probeFence = circuit.probeFence,
                  let probe = try job(id: probeFence.jobID, in: database),
                  probe.fence == probeFence,
                  probe.state == .running
            else {
                let reopened = AutomaticClassificationProviderCircuit(
                    providerExecutionRevision: circuit.providerExecutionRevision,
                    state: .open,
                    failureCode: circuit.failureCode,
                    consecutiveFailures: circuit.consecutiveFailures,
                    retryAt: now,
                    probeFence: nil,
                    openedAt: circuit.openedAt,
                    updatedAt: now,
                    transitionVersion: try nextTransitionVersion(after: circuit)
                )
                try writeProviderCircuit(reopened, in: database)
                return try nextDispatch(
                    now: now,
                    staleBefore: staleBefore,
                    claimID: claimID,
                    in: database
                )
            }
            guard let claimedAt = probe.claimedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "half-open provider canary has no claim date"
                )
            }
            guard claimedAt <= staleBefore else {
                return .idle(
                    nextWakeAt: claimedAt.addingTimeInterval(
                        now.timeIntervalSince(staleBefore)
                    )
                )
            }
            let recovered = try claim(probe, now: now, claimID: claimID, in: database)
            let recoveredCircuit = AutomaticClassificationProviderCircuit(
                providerExecutionRevision: circuit.providerExecutionRevision,
                state: .halfOpen,
                failureCode: circuit.failureCode,
                consecutiveFailures: circuit.consecutiveFailures,
                retryAt: nil,
                probeFence: recovered.fence,
                openedAt: circuit.openedAt,
                updatedAt: now,
                transitionVersion: try nextTransitionVersion(after: circuit)
            )
            try writeProviderCircuit(recoveredCircuit, in: database)
            return .claimed(recovered)
        case .closed:
            if let running = try firstJob(
                where: "state = 'running' AND dispatch_authorization != 'pendingUserDecision'",
                orderBy: "claimed_at, created_at, id",
                in: database,
                bind: { _ in }
            ) {
                guard let claimedAt = running.claimedAt else {
                    throw SQLiteRepositoryError.invalidStoredValue(
                        "running provider job has no claim date"
                    )
                }
                guard claimedAt <= staleBefore else {
                    return .idle(
                        nextWakeAt: claimedAt.addingTimeInterval(
                            now.timeIntervalSince(staleBefore)
                        )
                    )
                }
                return .claimed(
                    try claim(running, now: now, claimID: claimID, in: database)
                )
            }
            if let ready = try firstJob(
                where: "state = 'ready' AND dispatch_authorization != 'pendingUserDecision' AND available_at <= ?",
                orderBy: "available_at, created_at, id",
                in: database,
                bind: { statement in bind(now, to: 1, in: statement) }
            ) {
                return .claimed(
                    try claim(ready, now: now, claimID: claimID, in: database)
                )
            }
            let backlogCount = try pendingBacklogCount(in: database)
            if backlogCount > 0 { return .backlogDecisionRequired(count: backlogCount) }
            return .idle(
                nextWakeAt: try nextProviderWakeDate(
                    now: now,
                    staleBefore: staleBefore,
                    in: database
                )
            )
        }
    }

    static func resolveProviderAttempt(
        _ outcome: AutomaticClassificationProviderAttemptOutcome,
        for claim: AutomaticClassificationJobClaim,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        guard let circuit = try providerCircuit(in: database),
              let revision = circuit.providerExecutionRevision,
              circuit.state == .closed
              || (circuit.state == .halfOpen && circuit.probeFence == claim.fence)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "provider outcome does not own the active circuit"
            )
        }
        switch outcome {
        case let .checkpoint(proposal):
            try checkpointProposal(proposal, for: claim, now: now, in: database)
        case .invalidResponse:
            try fail(
                claim.fence,
                errorCode: .invalidProviderResponse,
                now: now,
                in: database
            )
        case .credentialsRejected:
            try releaseProviderClaim(
                claim,
                state: .waitingForConfiguration,
                errorCode: .providerRejected,
                availableAt: now,
                now: now,
                in: database
            )
            let blocked = AutomaticClassificationProviderCircuit(
                providerExecutionRevision: revision,
                state: .blocked,
                failureCode: .providerRejected,
                consecutiveFailures: try incrementFailures(circuit.consecutiveFailures),
                retryAt: nil,
                probeFence: nil,
                openedAt: circuit.openedAt ?? now,
                updatedAt: now,
                transitionVersion: try nextTransitionVersion(after: circuit)
            )
            try writeProviderCircuit(blocked, in: database)
        case let .rateLimited(retryAt):
            try recordTransientProviderFailure(
                claim,
                code: .providerRateLimited,
                retryAt: retryAt,
                now: now,
                circuit: circuit,
                revision: revision,
                in: database
            )
        case let .transientFailure(retryAt):
            try recordTransientProviderFailure(
                claim,
                code: .providerUnavailable,
                retryAt: retryAt,
                now: now,
                circuit: circuit,
                revision: revision,
                in: database
            )
        }
    }

    private static func decodeProviderCircuit(
        _ statement: OpaquePointer?
    ) throws -> AutomaticClassificationProviderCircuit {
        let revision = try optionalUUID(statement, 0)
        guard let state = AutomaticClassificationProviderCircuitState(
            rawValue: try string(statement, 1)
        ) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification provider circuit state is invalid"
            )
        }
        let failureCode: AutomaticClassificationJobErrorCode?
        if let rawFailure = try optionalString(statement, 2) {
            guard let parsed = AutomaticClassificationJobErrorCode(rawValue: rawFailure)
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "automatic classification provider failure code is invalid"
                )
            }
            failureCode = parsed
        } else {
            failureCode = nil
        }
        let probeJobID = try optionalUUID(statement, 5)
        let probeGeneration = try optionalInt(statement, 6)
        let probeAttempt = try optionalInt(statement, 7)
        let probeClaimID = try optionalUUID(statement, 8)
        let probeFence: AutomaticClassificationJobFence?
        switch (probeJobID, probeGeneration, probeAttempt, probeClaimID) {
        case (nil, nil, nil, nil):
            probeFence = nil
        case let (.some(jobID), .some(generation), .some(attempt), .some(claimID)):
            probeFence = AutomaticClassificationJobFence(
                jobID: jobID,
                generation: generation,
                attempt: attempt,
                claimID: claimID
            )
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification provider canary fence is incomplete"
            )
        }
        return AutomaticClassificationProviderCircuit(
            providerExecutionRevision: revision,
            state: state,
            failureCode: failureCode,
            consecutiveFailures: try int(statement, 3),
            retryAt: try optionalDate(statement, 4),
            probeFence: probeFence,
            openedAt: try optionalDate(statement, 9),
            updatedAt: try date(statement, 10),
            transitionVersion: try int(statement, 11)
        )
    }

    private static func writeProviderCircuit(
        _ circuit: AutomaticClassificationProviderCircuit,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            INSERT INTO automatic_classification_provider_circuit(
                singleton_id, provider_execution_revision, state, failure_code,
                consecutive_failures, retry_at, probe_job_id, probe_generation,
                probe_attempt, probe_claim_id, opened_at, updated_at,
                transition_version
            )
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(singleton_id) DO UPDATE SET
                provider_execution_revision = excluded.provider_execution_revision,
                state = excluded.state,
                failure_code = excluded.failure_code,
                consecutive_failures = excluded.consecutive_failures,
                retry_at = excluded.retry_at,
                probe_job_id = excluded.probe_job_id,
                probe_generation = excluded.probe_generation,
                probe_attempt = excluded.probe_attempt,
                probe_claim_id = excluded.probe_claim_id,
                opened_at = excluded.opened_at,
                updated_at = excluded.updated_at,
                transition_version = excluded.transition_version
            """,
            on: database
        ) { statement in
            bind(circuit.providerExecutionRevision?.uuidString, to: 1, in: statement)
            bind(circuit.state.rawValue, to: 2, in: statement)
            bind(circuit.failureCode?.rawValue, to: 3, in: statement)
            bind(circuit.consecutiveFailures, to: 4, in: statement)
            bind(circuit.retryAt, to: 5, in: statement)
            bind(circuit.probeFence?.jobID.uuidString, to: 6, in: statement)
            bind(circuit.probeFence?.generation, to: 7, in: statement)
            bind(circuit.probeFence?.attempt, to: 8, in: statement)
            bind(circuit.probeFence?.claimID?.uuidString, to: 9, in: statement)
            bind(circuit.openedAt, to: 10, in: statement)
            bind(circuit.updatedAt, to: 11, in: statement)
            bind(circuit.transitionVersion, to: 12, in: statement)
        }
        try requireSingleCASChange(in: database)
    }

    private static func makeCircuit(
        revision: UUID?,
        state: AutomaticClassificationProviderCircuitState,
        now: Date,
        transitionVersion: Int
    ) -> AutomaticClassificationProviderCircuit {
        AutomaticClassificationProviderCircuit(
            providerExecutionRevision: revision,
            state: state,
            failureCode: nil,
            consecutiveFailures: 0,
            retryAt: nil,
            probeFence: nil,
            openedAt: nil,
            updatedAt: now,
            transitionVersion: transitionVersion
        )
    }

    private static func nextTransitionVersion(
        after circuit: AutomaticClassificationProviderCircuit?
    ) throws -> Int {
        let current = circuit?.transitionVersion ?? 0
        guard current < Int.max else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification provider circuit version is exhausted"
            )
        }
        return current + 1
    }

    private static func incrementFailures(_ current: Int) throws -> Int {
        guard current < Int.max else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification provider failure count is exhausted"
            )
        }
        return current + 1
    }

    private static func pendingBacklogCount(
        in database: OpaquePointer?
    ) throws -> Int {
        let rows = try query(
            """
            SELECT COUNT(*)
            FROM automatic_classification_jobs
            WHERE dispatch_authorization = 'pendingUserDecision'
                AND state = 'waitingForConfiguration'
            """,
            on: database,
            bind: { _ in },
            row: { statement in try int(statement, 0) }
        )
        guard rows.count == 1, let count = rows.first else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification backlog count is invalid"
            )
        }
        return count
    }

    private static func noProviderDispatch(
        now: Date,
        staleBefore: Date,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationNextDispatch {
        if let checkpoint = try firstJob(
            where: "state = 'proposalReady'",
            orderBy: "claimed_at, created_at, id",
            in: database,
            bind: { _ in }
        ) {
            guard let claimedAt = checkpoint.claimedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "proposal-ready job has no claim date"
                )
            }
            return .idle(
                nextWakeAt: claimedAt.addingTimeInterval(
                    now.timeIntervalSince(staleBefore)
                )
            )
        }
        let backlogCount = try pendingBacklogCount(in: database)
        if backlogCount > 0 { return .backlogDecisionRequired(count: backlogCount) }
        let rows = try query(
            """
            SELECT COUNT(*)
            FROM automatic_classification_jobs
            WHERE dispatch_authorization != 'pendingUserDecision'
                AND state IN ('waitingForConfiguration', 'ready', 'running')
            """,
            on: database,
            bind: { _ in },
            row: { statement in try int(statement, 0) }
        )
        return rows == [0] ? .idle(nextWakeAt: nil) : .waitingForProvider
    }

    private static func firstJob(
        where predicate: String,
        orderBy: String,
        in database: OpaquePointer?,
        bind: (OpaquePointer?) throws -> Void
    ) throws -> AutomaticClassificationJob? {
        try query(
            """
            SELECT \(selectionColumns)
            FROM automatic_classification_jobs
            WHERE \(predicate)
            ORDER BY \(orderBy)
            LIMIT 1
            """,
            on: database,
            bind: bind,
            row: decodeJob
        ).first
    }

    private static func nextProviderCandidate(
        now: Date,
        staleBefore: Date,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationJob? {
        if let running = try firstJob(
            where: "state = 'running' AND dispatch_authorization != 'pendingUserDecision'",
            orderBy: "claimed_at, created_at, id",
            in: database,
            bind: { _ in }
        ) {
            guard let claimedAt = running.claimedAt, claimedAt <= staleBefore else {
                return nil
            }
            return running
        }
        return try firstJob(
            where: "state = 'ready' AND dispatch_authorization != 'pendingUserDecision' AND available_at <= ?",
            orderBy: "CASE WHEN error_code IN ('providerUnavailable', 'providerRateLimited') THEN 0 ELSE 1 END, available_at, created_at, id",
            in: database,
            bind: { statement in bind(now, to: 1, in: statement) }
        )
    }

    private static func nextProviderWakeDate(
        now: Date,
        staleBefore: Date,
        in database: OpaquePointer?
    ) throws -> Date? {
        let lease = now.timeIntervalSince(staleBefore)
        return try jobs(
            states: [.ready, .running, .proposalReady],
            in: database
        ).compactMap { job in
            switch job.state {
            case .ready where job.dispatchAuthorization != .pendingUserDecision:
                job.availableAt
            case .running, .proposalReady:
                job.claimedAt?.addingTimeInterval(lease)
            case .waitingForConfiguration, .ready, .completed, .superseded,
                 .cancelled, .failed:
                nil
            }
        }.min()
    }

    private static func claim(
        _ candidate: AutomaticClassificationJob,
        now: Date,
        claimID: UUID,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationJobClaim {
        guard candidate.dispatchAuthorization != .pendingUserDecision
            || candidate.state == .proposalReady
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending backlog cannot be claimed"
            )
        }
        guard candidate.attempt < Int.max else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification attempt is exhausted"
            )
        }
        let attempt = candidate.attempt + 1
        let claimedState: AutomaticClassificationJobState = candidate.state == .proposalReady
            ? .proposalReady
            : .running
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = ?, attempt = ?, claim_id = ?, claimed_at = ?, updated_at = ?
            WHERE id = ? AND generation = ? AND attempt = ?
                AND state = ? AND claim_id IS ?
            """,
            on: database
        ) { statement in
            bind(claimedState.rawValue, to: 1, in: statement)
            bind(attempt, to: 2, in: statement)
            bind(claimID.uuidString, to: 3, in: statement)
            bind(now, to: 4, in: statement)
            bind(now, to: 5, in: statement)
            bind(candidate.id.uuidString, to: 6, in: statement)
            bind(candidate.generation, to: 7, in: statement)
            bind(candidate.attempt, to: 8, in: statement)
            bind(candidate.state.rawValue, to: 9, in: statement)
            bind(candidate.claimID?.uuidString, to: 10, in: statement)
        }
        try requireSingleCASChange(in: database)
        return AutomaticClassificationJobClaim(
            jobID: candidate.id,
            chainID: candidate.chainID,
            contentDigest: candidate.contentDigest,
            classificationFingerprint: candidate.classificationFingerprint,
            authorityPayload: candidate.authorityPayload,
            catalogDigest: candidate.catalogDigest,
            generation: candidate.generation,
            dispatchAuthorization: candidate.dispatchAuthorization,
            attempt: attempt,
            claimID: claimID,
            state: claimedState,
            proposalCheckpoint: candidate.proposalCheckpoint
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func releaseProviderClaim(
        _ claim: AutomaticClassificationJobClaim,
        state: AutomaticClassificationJobState,
        errorCode: AutomaticClassificationJobErrorCode,
        availableAt: Date,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        guard state == .ready || state == .waitingForConfiguration else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "provider claim release target is invalid"
            )
        }
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = ?, claim_id = NULL, proposal_checkpoint = NULL,
                error_code = ?, available_at = ?, claimed_at = NULL,
                updated_at = ?, terminal_at = NULL, cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id = ? AND state = 'running'
            """,
            on: database
        ) { statement in
            bind(state.rawValue, to: 1, in: statement)
            bind(errorCode.rawValue, to: 2, in: statement)
            bind(availableAt, to: 3, in: statement)
            bind(now, to: 4, in: statement)
            bind(claim.jobID.uuidString, to: 5, in: statement)
            bind(claim.generation, to: 6, in: statement)
            bind(claim.attempt, to: 7, in: statement)
            bind(claim.claimID.uuidString, to: 8, in: statement)
        }
        try requireSingleCASChange(in: database)
    }

    // swiftlint:disable:next function_parameter_count
    private static func recordTransientProviderFailure(
        _ claim: AutomaticClassificationJobClaim,
        code: AutomaticClassificationJobErrorCode,
        retryAt: Date,
        now: Date,
        circuit: AutomaticClassificationProviderCircuit,
        revision: UUID,
        in database: OpaquePointer?
    ) throws {
        try releaseProviderClaim(
            claim,
            state: .ready,
            errorCode: code,
            availableAt: retryAt,
            now: now,
            in: database
        )
        let failures = try incrementFailures(circuit.consecutiveFailures)
        let next = AutomaticClassificationProviderCircuit(
            providerExecutionRevision: revision,
            state: failures >= 3 ? .blocked : .open,
            failureCode: code,
            consecutiveFailures: failures,
            retryAt: failures >= 3 ? nil : retryAt,
            probeFence: nil,
            openedAt: circuit.openedAt ?? now,
            updatedAt: now,
            transitionVersion: try nextTransitionVersion(after: circuit)
        )
        try writeProviderCircuit(next, in: database)
    }

    private static func closeCircuitIfProbeMatches(
        _ fence: AutomaticClassificationJobFence,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        guard let circuit = try providerCircuit(in: database),
              circuit.state == .halfOpen,
              circuit.probeFence == fence,
              let revision = circuit.providerExecutionRevision
        else { return }
        let closed = makeCircuit(
            revision: revision,
            state: .closed,
            now: now,
            transitionVersion: try nextTransitionVersion(after: circuit)
        )
        try writeProviderCircuit(closed, in: database)
    }

    private static func reopenCircuitIfCanaryIsNoLongerActive(
        retryAt: Date,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        guard let circuit = try providerCircuit(in: database),
              circuit.state == .halfOpen,
              let probeFence = circuit.probeFence
        else { return }
        // swiftlint:disable opening_brace
        if let probe = try job(id: probeFence.jobID, in: database),
           probe.fence == probeFence,
           probe.state == .running
        {
            return
        }
        // swiftlint:enable opening_brace
        guard circuit.providerExecutionRevision != nil,
              circuit.failureCode == .providerRateLimited
              || circuit.failureCode == .providerUnavailable
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "half-open provider circuit cannot be reopened"
            )
        }
        let reopened = AutomaticClassificationProviderCircuit(
            providerExecutionRevision: circuit.providerExecutionRevision,
            state: .open,
            failureCode: circuit.failureCode,
            consecutiveFailures: circuit.consecutiveFailures,
            retryAt: retryAt,
            probeFence: nil,
            openedAt: circuit.openedAt,
            updatedAt: now,
            transitionVersion: try nextTransitionVersion(after: circuit)
        )
        try writeProviderCircuit(reopened, in: database)
    }

    static func claimNext(
        now: Date,
        staleBefore: Date,
        claimID: UUID,
        in database: OpaquePointer?
    ) throws -> AutomaticClassificationJobClaim? {
        let candidates = try query(
            """
            SELECT \(selectionColumns)
            FROM automatic_classification_jobs
            WHERE
                (state = 'ready' AND available_at <= ?)
                OR (
                    state IN ('running', 'proposalReady')
                    AND claimed_at <= ?
                )
            ORDER BY
                CASE state
                    WHEN 'proposalReady' THEN 0
                    WHEN 'ready' THEN 1
                    ELSE 2
                END,
                available_at,
                created_at,
                id
            LIMIT 1
            """,
            on: database,
            bind: { statement in
                bind(now, to: 1, in: statement)
                bind(staleBefore, to: 2, in: statement)
            },
            row: decodeJob
        )
        guard let candidate = candidates.first else { return nil }
        guard candidate.attempt < Int.max else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification attempt is exhausted"
            )
        }
        let attempt = candidate.attempt + 1
        let claimedState: AutomaticClassificationJobState = candidate.state == .proposalReady
            ? .proposalReady
            : .running
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = ?, attempt = ?, claim_id = ?, claimed_at = ?, updated_at = ?
            WHERE id = ? AND generation = ? AND attempt = ?
                AND state = ? AND claim_id IS ?
            """,
            on: database
        ) { statement in
            bind(claimedState.rawValue, to: 1, in: statement)
            bind(attempt, to: 2, in: statement)
            bind(claimID.uuidString, to: 3, in: statement)
            bind(now, to: 4, in: statement)
            bind(now, to: 5, in: statement)
            bind(candidate.id.uuidString, to: 6, in: statement)
            bind(candidate.generation, to: 7, in: statement)
            bind(candidate.attempt, to: 8, in: statement)
            bind(candidate.state.rawValue, to: 9, in: statement)
            bind(candidate.claimID?.uuidString, to: 10, in: statement)
        }
        try requireSingleCASChange(in: database)
        return AutomaticClassificationJobClaim(
            jobID: candidate.id,
            chainID: candidate.chainID,
            contentDigest: candidate.contentDigest,
            classificationFingerprint: candidate.classificationFingerprint,
            authorityPayload: candidate.authorityPayload,
            catalogDigest: candidate.catalogDigest,
            generation: candidate.generation,
            dispatchAuthorization: candidate.dispatchAuthorization,
            attempt: attempt,
            claimID: claimID,
            state: claimedState,
            proposalCheckpoint: candidate.proposalCheckpoint
        )
    }

    static func checkpointProposal(
        _ proposal: Data,
        for claim: AutomaticClassificationJobClaim,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try validateProposal(proposal)
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'proposalReady', proposal_checkpoint = ?, updated_at = ?
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id = ? AND state = 'running'
            """,
            on: database
        ) { statement in
            bind(proposal, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(claim.jobID.uuidString, to: 3, in: statement)
            bind(claim.generation, to: 4, in: statement)
            bind(claim.attempt, to: 5, in: statement)
            bind(claim.claimID.uuidString, to: 6, in: statement)
        }
        try requireSingleCASChange(in: database)
        try closeCircuitIfProbeMatches(claim.fence, now: now, in: database)
    }

    static func complete(
        _ claim: AutomaticClassificationJobClaim,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'completed', proposal_checkpoint = NULL,
                error_code = NULL, updated_at = ?, terminal_at = ?,
                cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ? AND state = 'proposalReady'
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(claim.jobID.uuidString, to: 3, in: statement)
            bind(claim.generation, to: 4, in: statement)
            bind(claim.attempt, to: 5, in: statement)
            bind(claim.claimID.uuidString, to: 6, in: statement)
        }
        try requireSingleCASChange(in: database)
    }

    static func supersede(
        _ fence: AutomaticClassificationJobFence,
        errorCode: AutomaticClassificationJobErrorCode,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'superseded', proposal_checkpoint = NULL,
                error_code = ?, updated_at = ?, terminal_at = ?,
                cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ?
                AND state IN (
                    'waitingForConfiguration', 'ready', 'running', 'proposalReady'
                )
            """,
            on: database
        ) { statement in
            bind(errorCode.rawValue, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(now, to: 3, in: statement)
            bindFence(fence, startingAt: 4, in: statement)
        }
        try requireSingleCASChange(in: database)
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
    }

    static func fail(
        _ fence: AutomaticClassificationJobFence,
        errorCode: AutomaticClassificationJobErrorCode,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'failed', proposal_checkpoint = NULL,
                error_code = ?, updated_at = ?, terminal_at = ?,
                cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ? AND state IN ('running', 'proposalReady')
            """,
            on: database
        ) { statement in
            bind(errorCode.rawValue, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(now, to: 3, in: statement)
            bindFence(fence, startingAt: 4, in: statement)
        }
        try requireSingleCASChange(in: database)
        try closeCircuitIfProbeMatches(fence, now: now, in: database)
    }

    static func retry(
        _ fence: AutomaticClassificationJobFence,
        to state: AutomaticClassificationJobState,
        availableAt: Date,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        guard state == .waitingForConfiguration || state == .ready else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification retry target must be waiting or ready"
            )
        }
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = ?, claim_id = NULL, proposal_checkpoint = NULL,
                available_at = ?, claimed_at = NULL, updated_at = ?,
                terminal_at = NULL, cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ? AND state = 'failed'
            """,
            on: database
        ) { statement in
            bind(state.rawValue, to: 1, in: statement)
            bind(availableAt, to: 2, in: statement)
            bind(now, to: 3, in: statement)
            bindFence(fence, startingAt: 4, in: statement)
        }
        try requireSingleCASChange(in: database)
    }

    static func reschedule(
        _ fence: AutomaticClassificationJobFence,
        errorCode: AutomaticClassificationJobErrorCode,
        availableAt: Date,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'ready', claim_id = NULL, proposal_checkpoint = NULL,
                error_code = ?, available_at = ?, claimed_at = NULL,
                updated_at = ?, terminal_at = NULL, cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ? AND state = 'running'
            """,
            on: database
        ) { statement in
            bind(errorCode.rawValue, to: 1, in: statement)
            bind(availableAt, to: 2, in: statement)
            bind(now, to: 3, in: statement)
            bindFence(fence, startingAt: 4, in: statement)
        }
        try requireSingleCASChange(in: database)
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: availableAt,
            now: now,
            in: database
        )
    }

    static func cancel(
        _ fence: AutomaticClassificationJobFence,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'cancelled', proposal_checkpoint = NULL,
                error_code = NULL, updated_at = ?, terminal_at = ?,
                cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ?
                AND state IN (
                    'waitingForConfiguration', 'ready', 'running', 'proposalReady'
                )
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bindFence(fence, startingAt: 3, in: statement)
        }
        try requireSingleCASChange(in: database)
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
    }

    static func supersedeJobs(
        forChain chainID: TaskChainID,
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'superseded', proposal_checkpoint = NULL,
                error_code = 'manualClassificationWon', updated_at = ?,
                terminal_at = ?, cancelled_by_undo = 0
            WHERE chain_id = ?
                AND state IN (
                    'waitingForConfiguration', 'ready', 'running', 'proposalReady',
                    'completed', 'failed'
                )
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(chainID.rawValue.uuidString, to: 3, in: statement)
        }
        let changed = Int(sqlite3_changes(database))
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
        return changed
    }

    static func invalidateJobs(
        forChain chainID: TaskChainID,
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'superseded', proposal_checkpoint = NULL,
                error_code = 'taskBecameIneligible', updated_at = ?,
                terminal_at = ?, cancelled_by_undo = 0
            WHERE chain_id = ?
                AND state IN (
                    'waitingForConfiguration', 'ready', 'running',
                    'proposalReady', 'failed'
                )
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(chainID.rawValue.uuidString, to: 3, in: statement)
        }
        let changed = Int(sqlite3_changes(database))
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
        return changed
    }

    static func cancelJobs(
        forUndoneChain chainID: TaskChainID,
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'cancelled', proposal_checkpoint = NULL,
                error_code = 'cancelledByUndo', updated_at = ?,
                terminal_at = ?, cancelled_by_undo = 1
            WHERE chain_id = ? AND state NOT IN ('superseded', 'cancelled')
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bind(chainID.rawValue.uuidString, to: 3, in: statement)
        }
        let changed = Int(sqlite3_changes(database))
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
        return changed
    }

    static func makeProviderDependentJobsWaitForConfiguration(
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'waitingForConfiguration', claim_id = NULL,
                proposal_checkpoint = NULL,
                error_code = 'configurationUnavailable', claimed_at = NULL,
                updated_at = ?, terminal_at = NULL, cancelled_by_undo = 0
            WHERE state IN ('ready', 'running')
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
        }
        return Int(sqlite3_changes(database))
    }

    static func makeWaitingForConfigurationJobsReady(
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'ready', error_code = NULL, available_at = ?,
                updated_at = ?
            WHERE state = 'waitingForConfiguration'
                AND dispatch_authorization != 'pendingUserDecision'
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
        }
        return Int(sqlite3_changes(database))
    }

    private static func makeAuthorizedWaitingJobsReady(
        now: Date,
        in database: OpaquePointer?
    ) throws -> Int {
        try makeWaitingForConfigurationJobsReady(now: now, in: database)
    }

    static func replace(
        _ fence: AutomaticClassificationJobFence,
        with replacement: AutomaticClassificationJobEnqueue,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try validate(replacement)
        guard let current = try job(id: fence.jobID, in: database),
              current.fence == fence,
              [
                  .waitingForConfiguration,
                  .ready,
                  .running,
                  .proposalReady,
                  .failed
              ].contains(current.state),
              replacement.id != current.id,
              replacement.chainID == current.chainID,
              replacement.generation > current.generation,
              replacement.classificationFingerprint
              == current.classificationFingerprint,
              replacement.contentDigest != current.contentDigest
              || replacement.catalogDigest != current.catalogDigest
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification replacement fence is invalid"
            )
        }
        try supersedeForReplacement(
            fence,
            now: now,
            in: database
        )
        try enqueue(
            replacement.preservingDispatchAuthorization(from: current),
            into: database
        )
    }

    static func restoreEligibility(
        _ fence: AutomaticClassificationJobFence,
        with replacement: AutomaticClassificationJobEnqueue,
        in database: OpaquePointer?
    ) throws {
        try validate(replacement)
        guard let source = try job(id: fence.jobID, in: database),
              source.fence == fence,
              source.state == .superseded,
              source.errorCode == .taskBecameIneligible,
              replacement.id != source.id,
              replacement.chainID == source.chainID,
              source.generation < Int.max,
              replacement.generation == source.generation + 1,
              replacement.classificationFingerprint
              == source.classificationFingerprint
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification eligibility restoration fence is invalid"
            )
        }
        let laterGenerations = try query(
            """
            SELECT COUNT(*)
            FROM automatic_classification_jobs
            WHERE chain_id = ? AND generation > ?
            """,
            on: database,
            bind: { statement in
                bind(source.chainID.rawValue.uuidString, to: 1, in: statement)
                bind(source.generation, to: 2, in: statement)
            },
            row: { statement in
                try int(statement, 0)
            }
        )
        guard laterGenerations == [0] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification eligibility restoration was already consumed"
            )
        }
        try enqueue(
            replacement.preservingDispatchAuthorization(from: source),
            into: database
        )
    }

    private static func supersedeForReplacement(
        _ fence: AutomaticClassificationJobFence,
        now: Date,
        in database: OpaquePointer?
    ) throws {
        try run(
            """
            UPDATE automatic_classification_jobs
            SET state = 'superseded', proposal_checkpoint = NULL,
                error_code = 'contentOrCatalogChanged', updated_at = ?,
                terminal_at = ?, cancelled_by_undo = 0
            WHERE id = ? AND generation = ? AND attempt = ?
                AND claim_id IS ?
                AND state IN (
                    'waitingForConfiguration', 'ready', 'running',
                    'proposalReady', 'failed'
                )
            """,
            on: database
        ) { statement in
            bind(now, to: 1, in: statement)
            bind(now, to: 2, in: statement)
            bindFence(fence, startingAt: 3, in: statement)
        }
        try requireSingleCASChange(in: database)
        try reopenCircuitIfCanaryIsNoLongerActive(
            retryAt: now,
            now: now,
            in: database
        )
    }

    static func requeueCancelledByUndo(
        _ redo: AutomaticClassificationJobRedo,
        in database: OpaquePointer?
    ) throws {
        try validate(redo.replacement)
        guard let cancelled = try job(
            id: redo.cancelledJob.jobID,
            in: database
        ),
            cancelled.fence == redo.cancelledJob,
            cancelled.state == .cancelled,
            cancelled.cancelledByUndo,
            cancelled.errorCode == .cancelledByUndo,
            redo.replacement.id != cancelled.id,
            redo.replacement.chainID == cancelled.chainID,
            redo.replacement.generation > cancelled.generation,
            redo.replacement.classificationFingerprint
            == cancelled.classificationFingerprint
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification redo cancellation fence is invalid"
            )
        }
        let laterGenerations = try query(
            """
            SELECT COUNT(*)
            FROM automatic_classification_jobs
            WHERE chain_id = ? AND generation > ?
            """,
            on: database,
            bind: { statement in
                bind(cancelled.chainID.rawValue.uuidString, to: 1, in: statement)
                bind(cancelled.generation, to: 2, in: statement)
            },
            row: { statement in
                try int(statement, 0)
            }
        )
        guard laterGenerations == [0] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification redo was already consumed"
            )
        }
        try enqueue(
            redo.replacement.preservingDispatchAuthorization(from: cancelled),
            into: database
        )
    }

    static func bindFence(
        _ fence: AutomaticClassificationJobFence,
        startingAt index: Int32,
        in statement: OpaquePointer?
    ) {
        bind(fence.jobID.uuidString, to: index, in: statement)
        bind(fence.generation, to: index + 1, in: statement)
        bind(fence.attempt, to: index + 2, in: statement)
        bind(fence.claimID?.uuidString, to: index + 3, in: statement)
    }

    static let selectionColumns = """
    id, chain_id, content_digest, classification_fingerprint,
    authority_payload, catalog_digest, generation, state,
    dispatch_authorization, authorization_id, authorized_at,
    attempt, claim_id, proposal_checkpoint, error_code, available_at, claimed_at,
    created_at, updated_at, terminal_at, cancelled_by_undo
    """

    static func validate(_ enqueue: AutomaticClassificationJobEnqueue) throws {
        guard enqueue.initialState == .waitingForConfiguration
            || enqueue.initialState == .ready
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification job must start waiting or ready"
            )
        }
        switch enqueue.dispatchAuthorization {
        case .automatic, .pendingUserDecision:
            guard enqueue.authorizationID == nil, enqueue.authorizedAt == nil else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "implicit automatic classification authorization has decision metadata"
                )
            }
        case .explicit:
            guard enqueue.authorizationID != nil, let authorizedAt = enqueue.authorizedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "explicit automatic classification authorization is incomplete"
                )
            }
            try validateDate(authorizedAt, label: "authorization timestamp")
        }
        // swiftlint:disable opening_brace
        if enqueue.dispatchAuthorization == .pendingUserDecision,
           enqueue.initialState != .waitingForConfiguration
        {
            throw SQLiteRepositoryError.invalidStoredValue(
                "pending automatic classification authorization must wait"
            )
        }
        // swiftlint:enable opening_brace
        try validateDigest(enqueue.contentDigest, label: "content digest")
        try validateDigest(
            enqueue.classificationFingerprint,
            label: "classification fingerprint"
        )
        guard (1 ... 65536).contains(enqueue.authorityPayload.count) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification authority payload must be bounded and nonempty"
            )
        }
        try validateDigest(enqueue.catalogDigest, label: "catalog digest")
        guard enqueue.generation > 0 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification generation must be positive"
            )
        }
        try validateDate(enqueue.availableAt, label: "availableAt")
        try validateDate(enqueue.createdAt, label: "createdAt")
        try validateAuthorityPayload(
            enqueue.authorityPayload,
            matching: AuthorityIndex(enqueue)
        )
    }

    static func validateProposal(_ proposal: Data) throws {
        guard (1 ... 262_144).contains(proposal.count) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification proposal checkpoint must be bounded and nonempty"
            )
        }
    }

    static func decodeJob(_ statement: OpaquePointer?) throws -> AutomaticClassificationJob {
        guard let id = UUID(uuidString: try string(statement, 0)),
              let chainUUID = UUID(uuidString: try string(statement, 1)),
              let state = AutomaticClassificationJobState(
                  rawValue: try string(statement, 7)
              ),
              let dispatchAuthorization = AutomaticClassificationDispatchAuthorization(
                  rawValue: try string(statement, 8)
              )
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification job contains an invalid identity or enum"
            )
        }
        let authorizationID = try optionalUUID(statement, 9)
        let authorizedAt = try optionalDate(statement, 10)
        let claimID = try optionalUUID(statement, 12)
        let errorCode: AutomaticClassificationJobErrorCode?
        if let rawErrorCode = try optionalString(statement, 14) {
            guard let parsedErrorCode = AutomaticClassificationJobErrorCode(
                rawValue: rawErrorCode
            ) else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "automatic classification job error code is invalid"
                )
            }
            errorCode = parsedErrorCode
        } else {
            errorCode = nil
        }
        let cancelledByUndo = try strictBool(statement, 20)
        let job = AutomaticClassificationJob(
            id: id,
            chainID: TaskChainID(chainUUID),
            contentDigest: try string(statement, 2),
            classificationFingerprint: try string(statement, 3),
            authorityPayload: try data(statement, 4),
            catalogDigest: try string(statement, 5),
            generation: try int(statement, 6),
            state: state,
            dispatchAuthorization: dispatchAuthorization,
            authorizationID: authorizationID,
            authorizedAt: authorizedAt,
            attempt: try int(statement, 11),
            claimID: claimID,
            proposalCheckpoint: optionalData(statement, 13),
            errorCode: errorCode,
            availableAt: try date(statement, 15),
            claimedAt: try optionalDate(statement, 16),
            createdAt: try date(statement, 17),
            updatedAt: try date(statement, 18),
            terminalAt: try optionalDate(statement, 19),
            cancelledByUndo: cancelledByUndo
        )
        try validateStored(job)
        return job
    }

    static func validateStored(_ job: AutomaticClassificationJob) throws {
        try validateDigest(job.contentDigest, label: "stored content digest")
        try validateDigest(
            job.classificationFingerprint,
            label: "stored classification fingerprint"
        )
        guard (1 ... 65536).contains(job.authorityPayload.count) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "stored automatic classification authority payload is invalid"
            )
        }
        try validateAuthorityPayload(
            job.authorityPayload,
            matching: AuthorityIndex(job)
        )
        try validateDate(job.availableAt, label: "stored availableAt")
        try validateDate(job.createdAt, label: "stored createdAt")
        try validateDate(job.updatedAt, label: "stored updatedAt")
        if let claimedAt = job.claimedAt {
            try validateDate(claimedAt, label: "stored claimedAt")
        }
        if let terminalAt = job.terminalAt {
            try validateDate(terminalAt, label: "stored terminalAt")
        }
        switch job.dispatchAuthorization {
        case .automatic, .pendingUserDecision:
            guard job.authorizationID == nil, job.authorizedAt == nil else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "stored automatic classification authorization is inconsistent"
                )
            }
        case .explicit:
            guard job.authorizationID != nil, let authorizedAt = job.authorizedAt else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "stored explicit automatic classification authorization is incomplete"
                )
            }
            try validateDate(authorizedAt, label: "stored authorization timestamp")
        }
        guard (job.claimID == nil) == (job.claimedAt == nil),
              job.state.isTerminal == (job.terminalAt != nil),
              (job.state == .proposalReady) == (job.proposalCheckpoint != nil),
              job.cancelledByUndo == false || job.state == .cancelled,
              job.dispatchAuthorization != .pendingUserDecision
              || [.waitingForConfiguration, .superseded, .cancelled, .failed]
              .contains(job.state)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification job state payload is inconsistent"
            )
        }
    }

    static func validateAuthorityPayload(
        _ payload: Data,
        matching index: AuthorityIndex
    ) throws {
        let authority: AutomaticTaskClassificationAuthority
        do {
            authority = try AutomaticClassificationAuthorityPayload.decode(payload)
        } catch {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification authority payload is not canonical"
            )
        }
        guard authority.jobID == index.jobID,
              authority.chainID == index.chainID,
              authority.contentDigest == index.contentDigest,
              authority.classificationFingerprint == index.classificationFingerprint,
              authority.catalogDigest == index.catalogDigest,
              authority.generation == index.generation
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification authority payload does not match indexed fields"
            )
        }
    }

    struct AuthorityIndex {
        let jobID: UUID
        let chainID: TaskChainID
        let contentDigest: String
        let classificationFingerprint: String
        let catalogDigest: String
        let generation: Int

        init(_ enqueue: AutomaticClassificationJobEnqueue) {
            jobID = enqueue.id
            chainID = enqueue.chainID
            contentDigest = enqueue.contentDigest
            classificationFingerprint = enqueue.classificationFingerprint
            catalogDigest = enqueue.catalogDigest
            generation = enqueue.generation
        }

        init(_ job: AutomaticClassificationJob) {
            jobID = job.id
            chainID = job.chainID
            contentDigest = job.contentDigest
            classificationFingerprint = job.classificationFingerprint
            catalogDigest = job.catalogDigest
            generation = job.generation
        }
    }

    static func validateDigest(_ value: String, label: String) throws {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification \(label) must be lowercase SHA-256 hex"
            )
        }
    }

    static func validateDate(_ value: Date, label: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification \(label) must be finite"
            )
        }
    }

    static func run(
        _ sql: String,
        on database: OpaquePointer?,
        bind: (OpaquePointer?) throws -> Void
    ) throws {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw repositoryError(
                for: result,
                database: database,
                otherwise: SQLiteRepositoryError.stepFailed
            )
        }
    }

    static func execute(_ sql: String, on database: OpaquePointer?) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw repositoryError(
                for: result,
                database: database,
                otherwise: SQLiteRepositoryError.executeFailed
            )
        }
    }

    static func requireSingleCASChange(in database: OpaquePointer?) throws {
        guard sqlite3_changes(database) == 1 else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification job compare-and-swap failed"
            )
        }
    }

    static func query<T>(
        _ sql: String,
        on database: OpaquePointer?,
        bind: (OpaquePointer?) throws -> Void,
        row: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql, on: database)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(try row(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw repositoryError(
                    for: result,
                    database: database,
                    otherwise: SQLiteRepositoryError.stepFailed
                )
            }
        }
    }

    static func prepare(
        _ sql: String,
        on database: OpaquePointer?
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw repositoryError(
                for: result,
                database: database,
                otherwise: SQLiteRepositoryError.prepareFailed
            )
        }
        return statement
    }

    static func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withCString { bytes in
            sqlite3_bind_text64(
                statement,
                index,
                bytes,
                UInt64(value.utf8.count),
                SQLITE_TRANSIENT,
                UInt8(SQLITE_UTF8)
            )
        }
    }

    static func bind(_ value: Int, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    static func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(value, to: index, in: statement)
    }

    static func bind(_ value: Data, to index: Int32, in statement: OpaquePointer?) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                statement,
                index,
                buffer.baseAddress,
                Int32(value.count),
                SQLITE_TRANSIENT
            )
        }
    }

    static func bind(_ value: Date, to index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_double(statement, index, value.timeIntervalSinceReferenceDate)
    }

    static func bind(_ value: Date?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bind(value, to: index, in: statement)
    }

    static func string(_ statement: OpaquePointer?, _ index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index)
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification SQLite text value is invalid"
            )
        }
        return String(cString: value)
    }

    static func optionalString(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try string(statement, index)
    }

    static func optionalUUID(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) throws -> UUID? {
        guard let value = try optionalString(statement, index) else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification UUID is invalid"
            )
        }
        return uuid
    }

    static func int(_ statement: OpaquePointer?, _ index: Int32) throws -> Int {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification integer is invalid"
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0, let result = Int(exactly: value) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification integer is outside Int range"
            )
        }
        return result
    }

    static func optionalInt(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) throws -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try int(statement, index)
    }

    static func date(_ statement: OpaquePointer?, _ index: Int32) throws -> Date {
        guard sqlite3_column_type(statement, index) == SQLITE_FLOAT
            || sqlite3_column_type(statement, index) == SQLITE_INTEGER
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification date is invalid"
            )
        }
        let date = Date(
            timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index)
        )
        try validateDate(date, label: "stored date")
        return date
    }

    static func optionalDate(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) throws -> Date? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return try date(statement, index)
    }

    static func optionalData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index)
        else {
            return nil
        }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    static func data(_ statement: OpaquePointer?, _ index: Int32) throws -> Data {
        guard let value = optionalData(statement, index), value.isEmpty == false else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification data is missing"
            )
        }
        return value
    }

    static func strictBool(_ statement: OpaquePointer?, _ index: Int32) throws -> Bool {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification Boolean is invalid"
            )
        }
        switch sqlite3_column_int(statement, index) {
        case 0: return false
        case 1: return true
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "automatic classification Boolean is outside 0 or 1"
            )
        }
    }

    static func lastError(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "unknown SQLite error"
    }

    static func repositoryError(
        for result: Int32,
        database: OpaquePointer?,
        otherwise: (String) -> SQLiteRepositoryError
    ) -> SQLiteRepositoryError {
        if isTransientContention(result: result, database: database) {
            return .transientContention
        }
        return otherwise(lastError(database))
    }

    private static func isTransientContention(
        result: Int32,
        database: OpaquePointer?
    ) -> Bool {
        let resultPrimaryCode = result & 0xFF
        let extendedPrimaryCode = database.map(sqlite3_extended_errcode) ?? result
        let databasePrimaryCode = extendedPrimaryCode & 0xFF
        return resultPrimaryCode == SQLITE_BUSY
            || resultPrimaryCode == SQLITE_LOCKED
            || databasePrimaryCode == SQLITE_BUSY
            || databasePrimaryCode == SQLITE_LOCKED
    }
}

private extension AutomaticClassificationJobEnqueue {
    func preservingDispatchAuthorization(
        from job: AutomaticClassificationJob
    ) -> AutomaticClassificationJobEnqueue {
        AutomaticClassificationJobEnqueue(
            id: id,
            chainID: chainID,
            contentDigest: contentDigest,
            classificationFingerprint: classificationFingerprint,
            authorityPayload: authorityPayload,
            catalogDigest: catalogDigest,
            generation: generation,
            initialState: job.dispatchAuthorization == .pendingUserDecision
                ? .waitingForConfiguration
                : initialState,
            dispatchAuthorization: job.dispatchAuthorization,
            authorizationID: job.authorizationID,
            authorizedAt: job.authorizedAt,
            availableAt: availableAt,
            createdAt: createdAt
        )
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

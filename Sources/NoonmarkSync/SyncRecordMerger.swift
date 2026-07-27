import Foundation
import NoonmarkCore

public struct SyncRecordMerger: Sendable {
    private let mapper: SyncRecordMapper
    private let currentRecordMerger: CurrentSyncRecordMerger

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
        currentRecordMerger = CurrentSyncRecordMerger(mapper: mapper)
    }

    public func merge(
        records incomingRecords: [SyncRecord],
        into snapshot: ValidatedSyncSnapshot,
        knownTerminalRejections: [SyncTerminalRejection] = [],
        detectedAt: Date = Date()
    ) -> SyncMergeResult {
        mergeValidated(
            records: incomingRecords,
            into: snapshot.snapshot,
            knownTerminalRejections: knownTerminalRejections,
            detectedAt: detectedAt
        )
    }

    func merge(
        records incomingRecords: [SyncRecord],
        into snapshot: NoonmarkSnapshot,
        knownTerminalRejections: [SyncTerminalRejection] = [],
        detectedAt: Date = Date()
    ) throws -> SyncMergeResult {
        merge(
            records: incomingRecords,
            into: try ValidatedSyncSnapshot(snapshot),
            knownTerminalRejections: knownTerminalRejections,
            detectedAt: detectedAt
        )
    }

    private func mergeValidated(
        records incomingRecords: [SyncRecord],
        into snapshot: NoonmarkSnapshot,
        knownTerminalRejections: [SyncTerminalRejection] = [],
        detectedAt: Date = Date()
    ) -> SyncMergeResult {
        let inputEvidence = SyncRecordEvidenceCanonicalizer.uniqueEvidence(
            incomingRecords
        )
        let canonicalization = canonicalInputPlan(
            incomingRecords,
            snapshot: snapshot,
            detectedAt: detectedAt
        )
        let reactivationAuthorizations = currentRecordMerger
            .reactivationAuthorizations(
                existingRecords: reactivationRecords(from: snapshot),
                incomingRecords: canonicalization.records
            )
        let knownTerminalProviderDependencies = Set(
            knownTerminalRejections.flatMap {
                terminalProviderDependencies(
                    from: $0.conflict.remoteRecord
                )
            }
        )
        var context = MergeContext(
            working: SnapshotIndex(snapshot),
            knownTerminalRejections: knownTerminalRejections,
            knownTerminalProviderDependencies: knownTerminalProviderDependencies,
            authorizedReactivationChainIDs: reactivationAuthorizations.chainIDs,
            authorizedTraceReactivations: reactivationAuthorizations.tracePairs,
            detectedAt: detectedAt
        )
        context.conflicts.append(contentsOf: canonicalization.conflicts)
        for conflict in canonicalization.conflicts {
            if let terminal = SyncTerminalRejection(conflict: conflict) {
                registerTerminalRejection(terminal, context: &context)
            }
        }
        let plan = orderingPlan(
            canonicalization.records,
            knownClassificationCommitIDs: Set(
                snapshot.classifications.changeRecords.map(\.id)
            )
        )

        for rejection in plan.rejected {
            reject(
                rejection.type,
                record: rejection.record,
                message: rejection.message,
                context: &context
            )
        }

        applyCurrentComponents(
            plan.ordered.filter {
                $0.entityType.requiresImmutableRecordPayload == false
            },
            context: &context
        )
        for record in plan.ordered
        where record.entityType.requiresImmutableRecordPayload {
            applyIntegrityGuarded(record, context: &context)
        }
        retryWaitingRecords(context: &context)

        var result = validatedResult(
            context: context,
            originalSnapshot: snapshot,
            orderedRecords: plan.ordered
        )
        result.provenanceGroups = canonicalization.provenanceGroups.sorted {
            $0.canonicalEvidenceID.rawValue < $1.canonicalEvidenceID.rawValue
        }
        result.outcomes = mergeOutcomes(
            inputEvidence: inputEvidence,
            result: result
        )
        return result
    }

    private func canonicalInputPlan(
        _ records: [SyncRecord],
        snapshot: NoonmarkSnapshot,
        detectedAt: Date
    ) -> InputCanonicalizationPlan {
        let partition = partitionInputRecords(
            records,
            detectedAt: detectedAt
        )
        let currentPlan = canonicalCurrentInputPlan(
            partition.currentRecords,
            existingRecords: currentSnapshotRecords(from: snapshot),
            detectedAt: detectedAt
        )
        return InputCanonicalizationPlan(
            records: partition.immutableRecords + currentPlan.records,
            conflicts: canonicalConflicts(
                partition.conflicts + currentPlan.conflicts
            ),
            provenanceGroups: partition.provenanceGroups
                + currentPlan.provenanceGroups
        )
    }

    private func partitionInputRecords(
        _ records: [SyncRecord],
        detectedAt: Date
    ) -> InputRecordPartition {
        var partition = InputRecordPartition()
        let orderedIDs = records.reduce(into: [SyncRecordID]()) {
            if $0.contains($1.id) == false {
                $0.append($1.id)
            }
        }
        let recordsByID = Dictionary(grouping: records, by: \.id)

        for recordID in orderedIDs {
            guard let grouped = recordsByID[recordID] else { continue }
            let variants = uniqueExactRecords(grouped)
            switch canonicalRecordGroup(
                variants,
                detectedAt: detectedAt
            ) {
            case let .immutable(record):
                partition.immutableRecords.append(record)
                partition.provenanceGroups.append(
                    SyncRecordProvenanceGroup(
                        canonicalRecord: record,
                        sourceEvidenceIDs: variants.map {
                            SyncRecordEvidenceID(record: $0)
                        }
                    )
                )
            case let .current(currentRecords, conflicts):
                partition.currentRecords.append(contentsOf: currentRecords)
                partition.conflicts.append(contentsOf: conflicts)
            case let .conflicts(conflicts):
                partition.conflicts.append(contentsOf: conflicts)
            case .empty:
                continue
            }
        }
        return partition
    }

    private func canonicalRecordGroup(
        _ variants: [SyncRecord],
        detectedAt: Date
    ) -> CanonicalRecordGroup {
        guard variants.isEmpty == false else { return .empty }
        let hasImmutableVariant = variants.contains {
            $0.entityType.requiresImmutableRecordPayload
        }
        let hasIdentityCollision = Set(
            variants.map {
                "\($0.entityType.rawValue)|\($0.entityID)|"
                    + $0.operation.rawValue
            }
        ).count > 1
        let collidesWithImmutableIdentity = hasImmutableVariant
            && variants.count > 1
        if hasIdentityCollision || collidesWithImmutableIdentity {
            return .conflicts(variants.map {
                conflict(
                    identityCollisionConflictType(for: $0),
                    record: $0,
                    detectedAt: detectedAt,
                    message: "sync record identity collided with different exact evidence"
                )
            })
        }
        if hasImmutableVariant, let record = variants.first {
            guard recordPassesSyncBoundary(record) else {
                return .conflicts([
                    conflict(
                        .invalidRecordPayload,
                        record: record,
                        detectedAt: detectedAt,
                        message: "immutable record failed the sync boundary contract"
                    )
                ])
            }
            return .immutable(record)
        }
        let valid = variants.filter(recordPassesSyncBoundary)
        let invalid = variants.filter {
            recordPassesSyncBoundary($0) == false
        }
        let invalidConflicts = invalid.map {
            conflict(
                .invalidRecordPayload,
                record: $0,
                detectedAt: detectedAt,
                message: "same-ID current record variant failed the sync boundary contract"
            )
        }
        guard invalid.isEmpty else {
            let validConflicts = valid.map {
                conflict(
                    .invalidRecordPayload,
                    record: $0,
                    detectedAt: detectedAt,
                    message: "same-ID current record peer failed the sync boundary contract"
                )
            }
            return .conflicts(invalidConflicts + validConflicts)
        }
        guard valid.isEmpty == false else {
            return .conflicts(invalidConflicts)
        }
        return .current(valid, conflicts: [])
    }

    private func recordPassesSyncBoundary(_ record: SyncRecord) -> Bool {
        do {
            try currentRecordMerger.validate(record)
            return true
        } catch {
            return false
        }
    }

    private func canonicalCurrentInputPlan(
        _ currentRecords: [SyncRecord],
        existingRecords: [SyncRecord],
        detectedAt: Date
    ) -> InputCanonicalizationPlan {
        var remaining = currentRecords
        var conflicts: [SyncConflict] = []
        while remaining.isEmpty == false {
            do {
                let batch = try currentRecordMerger.prepareTransportBatch(
                    existingRecords: existingRecords,
                    incomingRecords: remaining
                )
                return InputCanonicalizationPlan(
                    records: batch.records,
                    conflicts: conflicts,
                    provenanceGroups: batch.provenanceGroups
                )
            } catch let error as SyncRecordTransportError {
                let recordID: SyncRecordID = switch error {
                case let .invalidCurrentRecordMerge(invalidID),
                     let .immutableRecordCollision(invalidID):
                    invalidID
                }
                let rejected = uniqueExactRecords(
                    remaining.filter { $0.id == recordID }
                )
                guard rejected.isEmpty == false else {
                    conflicts.append(contentsOf: remaining.map {
                        conflict(
                            .invalidRecordPayload,
                            record: $0,
                            detectedAt: detectedAt,
                            message: "current record batch returned an unknown collision"
                        )
                    })
                    remaining.removeAll()
                    break
                }
                conflicts.append(contentsOf: rejected.map {
                    conflict(
                        .invalidRecordPayload,
                        record: $0,
                        detectedAt: detectedAt,
                        message: "same-ID current records could not be merged exactly"
                    )
                })
                remaining.removeAll { $0.id == recordID }
            } catch {
                conflicts.append(contentsOf: remaining.map {
                    conflict(
                        .invalidRecordPayload,
                        record: $0,
                        detectedAt: detectedAt,
                        message: "current record batch failed canonical validation"
                    )
                })
                remaining.removeAll()
            }
        }

        return InputCanonicalizationPlan(
            records: [],
            conflicts: conflicts,
            provenanceGroups: []
        )
    }

    private func identityCollisionConflictType(
        for record: SyncRecord
    ) -> SyncConflictType {
        switch record.entityType {
        case .classificationCommit:
            return .classificationCommitRejected
        case .traceClassificationEvent:
            return .traceClassificationEventRejected
        case .day, .taskCycleSeries, .taskChain, .taskDefinition, .dayTrace, .subtask,
             .appPreferences:
            return .invalidRecordPayload
        }
    }

    private func currentSnapshotRecords(
        from snapshot: NoonmarkSnapshot
    ) -> [SyncRecord] {
        let localDeviceID = SyncDeviceID("local-materialized")
        var records = snapshot.days.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += snapshot.taskCycleSeries.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += snapshot.chains.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += snapshot.definitions.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += snapshot.traces.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += snapshot.subtasks.compactMap {
            try? mapper.record(for: $0, modifiedBy: localDeviceID)
        }
        records += [
            try? mapper.record(
                for: AppPreferencesEnvelope(preferences: snapshot.preferences),
                modifiedBy: SyncDeviceID(
                    snapshot.preferences.themeLanguageWriterID
                )
            )
        ].compactMap { $0 }
        return records
    }

    private func uniqueExactRecords(
        _ records: [SyncRecord]
    ) -> [SyncRecord] {
        records.reduce(into: []) { unique, record in
            if unique.contains(where: { $0.exactlyMatches(record) }) == false {
                unique.append(record)
            }
        }.sorted {
            $0.currentRecordLWWOrder(comparedTo: $1) == .before
        }
    }

    private func canonicalConflicts(
        _ conflicts: [SyncConflict]
    ) -> [SyncConflict] {
        conflicts.reduce(into: []) { unique, conflict in
            if unique.contains(where: { $0.id == conflict.id }) == false {
                unique.append(conflict)
            }
        }.sorted(by: conflictComesBefore)
    }

    private func conflictComesBefore(
        _ lhs: SyncConflict,
        _ rhs: SyncConflict
    ) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private func mergeOutcomes(
        inputEvidence: [SyncRecordEvidence],
        result: SyncMergeResult
    ) -> [SyncRecordMergeOutcome] {
        let provenanceBySource = result.provenanceGroups.reduce(
            into: [SyncRecordEvidenceID: SyncRecordProvenanceGroup]()
        ) { index, group in
            for sourceID in group.sourceEvidenceIDs {
                index[sourceID] = group
            }
        }
        let appliedEvidenceIDs = Set(result.appliedEvidenceIDs)

        return inputEvidence.map { evidence in
            let group = provenanceBySource[evidence.id]
            let canonicalEvidenceID = group?.canonicalEvidenceID ?? evidence.id
            if group?.supersededEvidenceIDs.contains(evidence.id) == true {
                return SyncRecordMergeOutcome(
                    evidence: evidence,
                    canonicalEvidenceID: canonicalEvidenceID,
                    disposition: .ignored
                )
            }
            let exactConflict = result.conflicts.first {
                SyncRecordEvidenceID(record: $0.remoteRecord)
                    == canonicalEvidenceID
            } ?? result.conflicts.first {
                SyncRecordEvidenceID(record: $0.remoteRecord) == evidence.id
            }
            if let exactConflict {
                return SyncRecordMergeOutcome(
                    evidence: evidence,
                    canonicalEvidenceID: canonicalEvidenceID,
                    disposition: .conflict,
                    conflictID: exactConflict.id
                )
            }
            if let waiting = result.waitingRecords.first(where: {
                SyncRecordEvidenceID(record: $0.record) == canonicalEvidenceID
            }) {
                return SyncRecordMergeOutcome(
                    evidence: evidence,
                    canonicalEvidenceID: canonicalEvidenceID,
                    disposition: .waiting,
                    dependencies: waiting.dependencies
                )
            }
            guard appliedEvidenceIDs.contains(canonicalEvidenceID) else {
                return SyncRecordMergeOutcome(
                    evidence: evidence,
                    canonicalEvidenceID: canonicalEvidenceID,
                    disposition: .ignored
                )
            }

            return SyncRecordMergeOutcome(
                evidence: evidence,
                canonicalEvidenceID: canonicalEvidenceID,
                disposition: .merged
            )
        }.sorted {
            $0.evidence.id.rawValue < $1.evidence.id.rawValue
        }
    }

    private func canonicalResult(
        snapshot: NoonmarkSnapshot,
        appliedRecordIDs: [SyncRecordID],
        appliedRecordIDByEvidence: [SyncRecordEvidenceID: SyncRecordID],
        waitingRecords: [SyncWaitingRecord],
        conflicts: [SyncConflict]
    ) -> SyncMergeResult {
        let canonicalConflictList = canonicalConflicts(conflicts)
        let conflictEvidenceIDs = Set(canonicalConflictList.map {
            SyncRecordEvidenceID(record: $0.remoteRecord)
        })
        var waitingByID: [SyncRecordID: SyncWaitingRecord] = [:]
        var waitingOrder: [SyncRecordID] = []
        for waiting in waitingRecords
        where conflictEvidenceIDs.contains(
            SyncRecordEvidenceID(record: waiting.record)
        ) == false {
            if let existing = waitingByID[waiting.remoteRecordID] {
                let record = existing.record.exactlyMatches(waiting.record)
                    ? existing.record
                    : (
                        existing.record.currentRecordLWWOrder(
                            comparedTo: waiting.record
                        ) == .after
                            ? existing.record
                            : waiting.record
                    )
                waitingByID[waiting.remoteRecordID] = SyncWaitingRecord(
                    record: record,
                    dependencies: Array(
                        Set(existing.dependencies + waiting.dependencies)
                    ).sorted(by: syncDependencyComesBefore)
                )
            } else {
                waitingOrder.append(waiting.remoteRecordID)
                waitingByID[waiting.remoteRecordID] = SyncWaitingRecord(
                    record: waiting.record,
                    dependencies: Array(Set(waiting.dependencies)).sorted(
                        by: syncDependencyComesBefore
                    )
                )
            }
        }
        let canonicalWaiting = waitingOrder.compactMap {
            waitingByID[$0]
        }
        let waitingEvidenceIDs = Set(canonicalWaiting.map {
            SyncRecordEvidenceID(record: $0.record)
        })
        let unavailableEvidenceIDs = conflictEvidenceIDs.union(
            waitingEvidenceIDs
        )
        let availableAppliedRecordIDs = Set(
            appliedRecordIDByEvidence.compactMap { evidenceID, recordID in
                unavailableEvidenceIDs.contains(evidenceID) ? nil : recordID
            }
        )
        var seenApplied: Set<SyncRecordID> = []
        let canonicalApplied = appliedRecordIDs.filter {
            availableAppliedRecordIDs.contains($0)
                && seenApplied.insert($0).inserted
        }
        return SyncMergeResult(
            snapshot: snapshot,
            appliedRecordIDs: canonicalApplied,
            appliedEvidenceIDs: Set(appliedRecordIDByEvidence.keys)
                .subtracting(unavailableEvidenceIDs)
                .sorted { $0.rawValue < $1.rawValue },
            waitingRecords: canonicalWaiting,
            conflicts: canonicalConflictList
        )
    }

    private func validatedResult(
        context: MergeContext,
        originalSnapshot: NoonmarkSnapshot,
        orderedRecords: [SyncRecord]
    ) -> SyncMergeResult {
        let mergedSnapshot = context.working.snapshot()
        do {
            try mergedSnapshot.validateIntegrity()
            return canonicalResult(
                snapshot: mergedSnapshot,
                appliedRecordIDs: context.applied,
                appliedRecordIDByEvidence: context.appliedRecordIDByEvidence,
                waitingRecords: context.waiting,
                conflicts: context.conflicts
            )
        } catch {
            var conflicts = context.conflicts
            let represented = Set(conflicts.map(\.remoteRecordID))
            for record in orderedRecords where represented.contains(record.id) == false {
                conflicts.append(
                    conflict(
                        .invalidRecordPayload,
                        record: record,
                        detectedAt: context.detectedAt,
                        message: "merged snapshot failed its final integrity gate"
                    )
                )
            }
            return canonicalResult(
                snapshot: originalSnapshot,
                appliedRecordIDs: [],
                appliedRecordIDByEvidence: [:],
                waitingRecords: [],
                conflicts: conflicts
            )
        }
    }

    private func applyCurrentComponents(
        _ records: [SyncRecord],
        context: inout MergeContext
    ) {
        guard records.isEmpty == false else { return }
        for component in currentStructuralComponents(records) {
            applyCurrentComponent(component, context: &context)
        }
    }

    private func applyCurrentComponent(
        _ records: [SyncRecord],
        context: inout MergeContext
    ) {
        if definitionTopologyIsIrreparable(
            afterProjecting: records,
            onto: context.working
        ) {
            for record in records {
                reject(
                    .invalidRecordPayload,
                    record: record,
                    message: "current component contains an irreparable definition topology",
                    context: &context
                )
            }
            return
        }
        if let conflictType = trajectoryTopologyConflictType(
            afterProjecting: records,
            onto: context.working
        ) {
            for record in records {
                reject(
                    conflictType,
                    record: record,
                    message: "current component contains an irreparable trajectory topology",
                    context: &context
                )
            }
            return
        }

        var candidate = context
        let conflictStart = candidate.conflicts.count
        let waitingStart = candidate.waiting.count
        for record in records {
            process(record, context: &candidate)
        }
        retryCurrentStageWaiting(
            startingAt: waitingStart,
            context: &candidate
        )

        let componentConflicts = Array(
            candidate.conflicts.dropFirst(conflictStart)
        )
        if componentConflicts.isEmpty == false {
            context.conflicts.append(contentsOf: componentConflicts)
            let conflictedEvidence = Set(componentConflicts.map {
                SyncRecordEvidenceID(record: $0.remoteRecord)
            })
            for record in records
            where conflictedEvidence.contains(
                SyncRecordEvidenceID(record: record)
            ) == false {
                reject(
                    .invalidReference,
                    record: record,
                    message: "current component peer was rejected; component rolled back atomically",
                    context: &context
                )
            }
            return
        }

        let componentWaiting = Array(candidate.waiting.dropFirst(waitingStart))
        if componentWaiting.isEmpty == false {
            let dependencies = Array(
                Set(componentWaiting.flatMap(\.dependencies))
            ).sorted(by: syncDependencyComesBefore)
            for record in records {
                context.waiting.append(
                    SyncWaitingRecord(
                        record: record,
                        dependencies: dependencies
                    )
                )
            }
            return
        }

        do {
            try candidate.working.snapshot().validateIntegrity()
            context = candidate
            return
        } catch {
            classifyRolledBackComponent(
                records,
                failedCandidate: candidate.working,
                context: &context
            )
        }
    }

    private func applyIntegrityGuarded(
        _ record: SyncRecord,
        context: inout MergeContext
    ) {
        var candidate = context
        process(record, context: &candidate)
        do {
            try candidate.working.snapshot().validateIntegrity()
            context = candidate
        } catch {
            reject(
                .invalidRecordPayload,
                record: record,
                message: "record would break whole-snapshot integrity",
                context: &context
            )
        }
    }

    private func currentStructuralComponents(
        _ records: [SyncRecord]
    ) -> [[SyncRecord]] {
        var adjacency = Array(
            repeating: Set<Int>(),
            count: records.count
        )
        var firstIndexByToken: [CurrentStructuralToken: Int] = [:]
        for (index, record) in records.enumerated() {
            for token in currentStructuralTokens(for: record) {
                if let peer = firstIndexByToken[token] {
                    adjacency[index].insert(peer)
                    adjacency[peer].insert(index)
                } else {
                    firstIndexByToken[token] = index
                }
            }
        }

        var visited: Set<Int> = []
        var components: [[SyncRecord]] = []
        for start in records.indices where visited.contains(start) == false {
            var pending = [start]
            var indices: [Int] = []
            visited.insert(start)
            while let index = pending.popLast() {
                indices.append(index)
                for peer in adjacency[index].sorted()
                where visited.insert(peer).inserted {
                    pending.append(peer)
                }
            }
            components.append(
                indices.sorted().map { records[$0] }
            )
        }
        return components
    }

    private func currentStructuralTokens(
        for record: SyncRecord
    ) -> Set<CurrentStructuralToken> {
        do {
            switch record.entityType {
            case .taskCycleSeries:
                let series = try mapper.decodeTaskCycleSeries(record)
                return [.taskCycleSeries(series.id)]
            case .taskChain:
                let chain = try mapper.decodeTaskChain(record)
                var tokens: Set<CurrentStructuralToken> = [
                    .taskChain(chain.id)
                ]
                if let seriesID = chain.cycleMembership?.seriesID {
                    tokens.insert(.taskCycleSeries(seriesID))
                }
                return tokens
            case .taskDefinition:
                return try taskDefinitionStructuralTokens(record)
            case .day:
                let day = try mapper.decodeDay(record)
                return [.day(day.date), .dayIdentity(day.id)]
            case .dayTrace:
                return try dayTraceStructuralTokens(record)
            case .subtask:
                return try subtaskStructuralTokens(record)
            case .appPreferences:
                return [.legacy("preferences:default")]
            case .classificationCommit, .traceClassificationEvent:
                return [.isolated(record.id)]
            }
        } catch {
            return [.isolated(record.id)]
        }
    }

    private func taskDefinitionStructuralTokens(
        _ record: SyncRecord
    ) throws -> Set<CurrentStructuralToken> {
        let definition = try mapper.decodeTaskDefinition(record)
        var tokens: Set<CurrentStructuralToken> = [
            .taskChain(definition.chainID),
            .taskDefinition(definition.id)
        ]
        if let successorID = definition.supersededByDefinitionID {
            tokens.insert(.taskDefinition(successorID))
        }
        return tokens
    }

    private func dayTraceStructuralTokens(
        _ record: SyncRecord
    ) throws -> Set<CurrentStructuralToken> {
        let trace = try mapper.decodeDayTrace(record)
        var tokens: Set<CurrentStructuralToken> = [
            .taskChain(trace.chainID),
            .taskDefinition(trace.definitionID),
            .day(trace.date),
            .dayTrace(trace.id)
        ]
        if let sourceID = trace.carriedFromTraceID {
            tokens.insert(.dayTrace(sourceID))
        }
        if let targetID = trace.changedToTraceID {
            tokens.insert(.dayTrace(targetID))
        }
        if trace.formsDayHistory {
            tokens.insert(
                .visiblePriority(trace.date, trace.priority)
            )
        }
        if let cancellationID = trace.draftCancellationID {
            tokens.insert(.draftCancellation(cancellationID))
        }
        return tokens
    }

    private func subtaskStructuralTokens(
        _ record: SyncRecord
    ) throws -> Set<CurrentStructuralToken> {
        let subtask = try mapper.decodeSubtask(record)
        var tokens: Set<CurrentStructuralToken> = [
            .dayTrace(subtask.traceID),
            .subtask(subtask.id)
        ]
        if let sourceID = subtask.carriedFromSubtaskID {
            tokens.insert(.subtask(sourceID))
        }
        if let cancellationID = subtask.draftCancellationID {
            tokens.insert(.draftCancellation(cancellationID))
        }
        return tokens
    }

    private func classifyRolledBackComponent(
        _ records: [SyncRecord],
        failedCandidate: SnapshotIndex,
        context: inout MergeContext
    ) {
        if componentHasIrreparableCollision(
            records,
            candidate: failedCandidate
        ) {
            for record in records {
                reject(
                    .invalidRecordPayload,
                    record: record,
                    message: "current component contains an irreparable topology collision",
                    context: &context
                )
            }
            return
        }

        for record in records {
            var probe = context
            let appliedStart = probe.applied.count
            let waitingStart = probe.waiting.count
            let conflictStart = probe.conflicts.count
            process(record, context: &probe)
            retryCurrentStageWaiting(
                startingAt: waitingStart,
                context: &probe
            )

            let probeConflicts = Array(
                probe.conflicts.dropFirst(conflictStart)
            )
            if probeConflicts.isEmpty == false {
                context.conflicts.append(contentsOf: probeConflicts)
                continue
            }
            let probeWaiting = Array(
                probe.waiting.dropFirst(waitingStart)
            )
            if probeWaiting.isEmpty == false {
                context.waiting.append(contentsOf: probeWaiting)
                continue
            }
            guard probe.applied.count > appliedStart else {
                continue
            }

            do {
                try probe.working.snapshot().validateIntegrity()
                reject(
                    .invalidRecordPayload,
                    record: record,
                    message: "current record conflicts with another record in its structural component",
                    context: &context
                )
            } catch {
                if recordCanWaitForMissingIntegrityFact(
                    record,
                    candidate: probe.working
                ) {
                    wait(
                        for: record,
                        dependencies: [.currentSnapshotIntegrity],
                        context: &context
                    )
                } else {
                    reject(
                        .invalidRecordPayload,
                        record: record,
                        message: "current record contains irreparable snapshot facts",
                        context: &context
                    )
                }
            }
        }
    }

    private func componentHasIrreparableCollision(
        _ records: [SyncRecord],
        candidate: SnapshotIndex
    ) -> Bool {
        let entityTypes = Set(records.map(\.entityType))
        if entityTypes == [.day] {
            let IDs = records.compactMap { try? mapper.decodeDay($0).id }
            return IDs.contains { dayID in
                candidate.days.values.filter { $0.id == dayID }.count > 1
            }
        }

        if entityTypes.isSubset(of: [.taskChain, .taskDefinition]) {
            return definitionTopologyHasIrreparableIssue(candidate)
        }

        let containsTrajectoryRecords = entityTypes.contains(.dayTrace)
            || entityTypes.contains(.subtask)
        if containsTrajectoryRecords {
            return trajectoryTopologyHasIrreparableIssue(candidate)
        }

        return false
    }

    private func definitionTopologyIsIrreparable(
        afterProjecting records: [SyncRecord],
        onto snapshot: SnapshotIndex
    ) -> Bool {
        let entityTypes = Set(records.map(\.entityType))
        guard entityTypes.isSubset(of: [.taskChain, .taskDefinition]) else {
            return false
        }
        var projection = snapshot
        for record in records {
            do {
                switch record.entityType {
                case .taskChain:
                    let chain = try mapper.decodeTaskChain(record)
                    projection.chains[chain.id] = chain
                case .taskDefinition:
                    let incoming = try mapper.decodeTaskDefinition(record)
                    if let existing = projection.definitions[incoming.id] {
                        let localRecord = try mapper.record(
                            for: existing,
                            modifiedBy: SyncDeviceID("local-materialized")
                        )
                        let mergedRecord = try currentRecordMerger.merge(
                            existing: localRecord,
                            incoming: record
                        )
                        projection.definitions[incoming.id] = try mapper
                            .decodeTaskDefinition(mergedRecord)
                    } else {
                        projection.definitions[incoming.id] = incoming
                    }
                case .day, .taskCycleSeries, .dayTrace, .subtask, .appPreferences,
                     .classificationCommit, .traceClassificationEvent:
                    break
                }
            } catch {
                return true
            }
        }
        return definitionTopologyHasIrreparableIssue(projection)
    }

    private func definitionTopologyHasIrreparableIssue(
        _ snapshot: SnapshotIndex
    ) -> Bool {
        for definition in snapshot.definitions.values {
            let chainCreatedAt = snapshot.chains[definition.chainID]?.createdAt
            if TaskDefinitionValidator.firstSelfContainedIssue(
                in: definition,
                chainCreatedAt: chainCreatedAt
            ) != nil {
                return true
            }
        }
        return TaskDefinitionValidator.topologyIssues(
            definitions: Array(snapshot.definitions.values),
            chainIDs: Set(snapshot.chains.keys),
            completeness: .permittingMissingSuccessors
        ).contains { topologyIssueIsMissingDependency($0) == false }
    }

    private func trajectoryTopologyConflictType(
        afterProjecting records: [SyncRecord],
        onto snapshot: SnapshotIndex
    ) -> SyncConflictType? {
        guard records.contains(where: {
            $0.entityType == .dayTrace || $0.entityType == .subtask
        }) else {
            return nil
        }
        var projection = snapshot
        do {
            for record in records {
                switch record.entityType {
                case .dayTrace:
                    let trace = try mapper.decodeDayTrace(record)
                    projection.traces[trace.id] = trace
                case .subtask:
                    let subtask = try mapper.decodeSubtask(record)
                    projection.subtasks[subtask.id] = subtask
                case .day, .taskCycleSeries, .taskChain, .taskDefinition, .appPreferences,
                     .classificationCommit, .traceClassificationEvent:
                    break
                }
            }
        } catch {
            return .invalidRecordPayload
        }
        let issue = TrajectoryTopologyValidator.topologyIssues(
            traces: Array(projection.traces.values),
            subtasks: Array(projection.subtasks.values)
        ).first { trajectoryIssueIsMissingDependency($0) == false }
        return switch issue {
        case .duplicateActiveTrace:
            .duplicateActiveTrace
        case .some:
            .invalidRecordPayload
        case nil:
            nil
        }
    }

    private func trajectoryTopologyHasIrreparableIssue(
        _ snapshot: SnapshotIndex
    ) -> Bool {
        TrajectoryTopologyValidator.topologyIssues(
            traces: Array(snapshot.traces.values),
            subtasks: Array(snapshot.subtasks.values)
        ).contains { trajectoryIssueIsMissingDependency($0) == false }
    }

    private func topologyIssueIsMissingDependency(
        _ issue: TaskDefinitionValidationIssue
    ) -> Bool {
        switch issue {
        case .missingDefinitionForChain, .missingSuccessor:
            return true
        case .invalidContentClock, .invalidTitle, .invalidPlannedSubtasks,
             .invalidSequence, .incompleteSupersession, .selfSuccessor,
             .duplicateSequence, .invalidCurrentCount,
             .crossChainSuccessor, .successorCycle:
            return false
        }
    }

    private func trajectoryIssueIsMissingDependency(
        _ issue: TrajectoryTopologyValidationIssue
    ) -> Bool {
        switch issue {
        case .missingTraceContinuationSource,
             .missingTraceContinuationTarget,
             .missingChangedTraceTarget,
             .noncontiguousSubtaskPosition,
             .missingSubtaskParent,
             .missingSubtaskContinuationSource,
             .missingSubtaskContinuationTarget:
            return true
        case .invalidTraceClock, .invalidTraceStatusFacts,
             .invalidTraceProgress, .invalidTraceSequence,
             .duplicateActiveTrace, .duplicateVisiblePriority,
             .reusedTraceContinuationSource,
             .invalidTraceContinuation, .reusedChangedTraceTarget,
             .invalidChangedTraceLink, .traceCausalCycle,
             .duplicateSubtaskPosition, .duplicateSubtaskLineage,
             .reusedSubtaskContinuationSource,
             .invalidSubtaskContinuation,
             .subtaskContinuationCycle,
             .reusedDraftCancellationIdentity:
            return false
        }
    }

    private func recordCanWaitForMissingIntegrityFact(
        _ record: SyncRecord,
        candidate: SnapshotIndex
    ) -> Bool {
        switch record.entityType {
        case .taskChain, .taskDefinition:
            let issues = TaskDefinitionValidator.topologyIssues(
                definitions: Array(candidate.definitions.values),
                chainIDs: Set(candidate.chains.keys),
                completeness: .permittingMissingSuccessors
            )
            return issues.isEmpty == false
                && issues.allSatisfy(topologyIssueIsMissingDependency)
        case .subtask, .dayTrace:
            let issues = TrajectoryTopologyValidator.topologyIssues(
                traces: Array(candidate.traces.values),
                subtasks: Array(candidate.subtasks.values)
            )
            return issues.isEmpty == false
                && issues.allSatisfy(
                    trajectoryIssueIsMissingDependency
                )
        case .day, .taskCycleSeries, .appPreferences,
             .classificationCommit, .traceClassificationEvent:
            return false
        }
    }

    private func retryCurrentStageWaiting(
        startingAt waitingStart: Int,
        context: inout MergeContext
    ) {
        var pending = Array(context.waiting.dropFirst(waitingStart))
        context.waiting.removeSubrange(waitingStart...)

        while pending.isEmpty == false {
            var unresolved: [SyncWaitingRecord] = []
            var resolvedAny = false
            for waiting in pending {
                let waitingCount = context.waiting.count
                process(waiting.record, context: &context)
                if context.waiting.count > waitingCount {
                    unresolved.append(context.waiting.removeLast())
                } else {
                    resolvedAny = true
                }
            }
            if unresolved.isEmpty {
                return
            }
            guard resolvedAny else {
                context.waiting.append(contentsOf: unresolved)
                return
            }
            pending = unresolved
        }
    }

    private func reactivationRecords(
        from snapshot: NoonmarkSnapshot
    ) -> [SyncRecord] {
        snapshot.chains.compactMap {
            try? mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("local-materialized")
            )
        } + snapshot.traces.compactMap {
            try? mapper.record(
                for: $0,
                modifiedBy: SyncDeviceID("local-materialized")
            )
        }
    }

    private func process(
        _ record: SyncRecord,
        context: inout MergeContext
    ) {
        if let identity = SyncTerminalRecordIdentity(record: record), let known = context.terminalRejections[identity] {
            if known.conflict.remoteRecord.exactlyMatches(record) {
                context.conflicts.append(known.conflict)
            } else {
                let type: SyncConflictType = switch identity {
                case .classificationCommit:
                    .classificationCommitRejected
                case .traceClassificationEvent:
                    .traceClassificationEventRejected
                }
                reject(
                    type,
                    record: record,
                    message: "terminal immutable record identity collided with different evidence",
                    context: &context
                )
            }
            return
        }

        guard record.operation == .upsert else {
            reject(
                .unsupportedDelete,
                record: record,
                message: "delete is not supported by the first sync foundation",
                context: &context
            )
            return
        }

        do {
            apply(try mapper.payload(from: record), record: record, context: &context)
        } catch {
            reject(
                .invalidRecordPayload,
                record: record,
                message: "record payload could not be decoded",
                context: &context
            )
        }
    }

    private func apply(
        _ payload: SyncRecordPayload,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        switch payload {
        case let .day(day):
            apply(day, record: record, context: &context)
        case let .taskCycleSeries(series):
            apply(series, record: record, context: &context)
        case let .taskChain(chain):
            apply(chain, record: record, context: &context)
        case let .taskDefinition(definition):
            apply(definition, record: record, context: &context)
        case let .dayTrace(trace):
            apply(trace, record: record, context: &context)
        case let .subtask(subtask):
            apply(subtask, record: record, context: &context)
        case let .appPreferences(envelope):
            apply(envelope, record: record, context: &context)
        case let .classificationCommit(envelope):
            apply(envelope, record: record, context: &context)
        case let .traceClassificationEvent(envelope):
            apply(envelope, record: record, context: &context)
        }
    }

    private func retryWaitingRecords(context: inout MergeContext) {
        var pending = context.waiting
        context.waiting.removeAll()

        while pending.isEmpty == false {
            var unresolved: [SyncWaitingRecord] = []
            var resolvedAny = false
            for records in retryUnits(for: pending) {
                let waitingCount = context.waiting.count
                if records.count == 1, let record = records.first, record.entityType.requiresImmutableRecordPayload {
                    applyIntegrityGuarded(
                        record,
                        context: &context
                    )
                } else {
                    applyCurrentComponents(
                        records,
                        context: &context
                    )
                }
                let newlyWaiting = Array(
                    context.waiting.dropFirst(waitingCount)
                )
                context.waiting.removeSubrange(waitingCount...)
                if newlyWaiting.isEmpty {
                    resolvedAny = true
                }
                for unresolvedRecord in newlyWaiting {
                    unresolved.append(unresolvedRecord)
                }
            }
            if unresolved.isEmpty {
                return
            }
            guard resolvedAny else {
                context.waiting.append(contentsOf: unresolved)
                return
            }
            pending = unresolved
        }
    }

    private func retryUnits(
        for pending: [SyncWaitingRecord]
    ) -> [[SyncRecord]] {
        let currentRecords = pending.map(\.record).filter {
            $0.entityType.requiresImmutableRecordPayload == false
        }
        var units = currentStructuralComponents(currentRecords)
        units.append(contentsOf: pending.compactMap { waiting in
            waiting.record.entityType.requiresImmutableRecordPayload
                ? [waiting.record]
                : nil
        })
        let positionByEvidence = Dictionary(
            uniqueKeysWithValues: pending.enumerated().map {
                (SyncRecordEvidenceID(record: $0.element.record), $0.offset)
            }
        )
        return units.sorted { lhs, rhs in
            let lhsPosition = lhs.compactMap {
                positionByEvidence[SyncRecordEvidenceID(record: $0)]
            }.min() ?? .max
            let rhsPosition = rhs.compactMap {
                positionByEvidence[SyncRecordEvidenceID(record: $0)]
            }.min() ?? .max
            return lhsPosition < rhsPosition
        }
    }

    private func orderingPlan(
        _ records: [SyncRecord],
        knownClassificationCommitIDs: Set<UUID>
    ) -> RecordOrderingPlan {
        let groups = Dictionary(grouping: records, by: { $0.entityType.dependencyOrder })
        var ordered: [SyncRecord] = []
        var rejected: [RecordOrderingRejection] = []

        for rank in groups.keys.sorted() {
            guard let group = groups[rank], let type = group.first?.entityType else {
                continue
            }
            let plan: RecordOrderingPlan = switch type {
            case .classificationCommit:
                classificationOrderingPlan(
                    group,
                    knownCommitIDs: knownClassificationCommitIDs
                )
            case .dayTrace:
                dayTraceOrderingPlan(group)
            case .traceClassificationEvent:
                traceClassificationEventOrderingPlan(group)
            case .appPreferences:
                RecordOrderingPlan(
                    ordered: group.sorted(by: currentRecordComesBefore),
                    rejected: []
                )
            default:
                RecordOrderingPlan(
                    ordered: group.sorted(by: recordIDComesBefore),
                    rejected: []
                )
            }
            ordered.append(contentsOf: plan.ordered)
            rejected.append(contentsOf: plan.rejected)
        }
        return RecordOrderingPlan(
            ordered: ordered,
            rejected: rejected.sorted {
                recordIDComesBefore($0.record, $1.record)
            }
        )
    }

    private func currentRecordComesBefore(
        _ lhs: SyncRecord,
        _ rhs: SyncRecord
    ) -> Bool {
        lhs.currentRecordLWWOrder(comparedTo: rhs) == .before
    }

    private func classificationOrderingPlan(
        _ records: [SyncRecord],
        knownCommitIDs: Set<UUID>
    ) -> RecordOrderingPlan {
        let envelopes = records.map { try? mapper.decodeClassificationCommit($0) }
        let unresolvedPredecessorIndices = unresolvedClassificationPredecessorIndices(
            envelopes,
            knownCommitIDs: knownCommitIDs
        )
        let allEdges = classificationDependencyEdges(
            envelopes,
            excluding: []
        )
        let cycleBlockedIndices = classificationCycleBlockedIndices(
            envelopes,
            edges: allEdges
        )
        let forkRejectedIndices = unsafeClassificationForkIndices(
            envelopes,
            causalEdges: allEdges,
            excluding: unresolvedPredecessorIndices.union(cycleBlockedIndices)
        )
        let initialRejectedIndices = cycleBlockedIndices.union(forkRejectedIndices)
        let rejectedIndices = classificationTerminalClosure(
            from: initialRejectedIndices,
            edges: allEdges
        )
        let dependencyRejectedIndices = rejectedIndices
            .subtracting(initialRejectedIndices)
        let edges = allEdges.filter {
            rejectedIndices.contains($0.predecessor) == false
                && rejectedIndices.contains($0.successor) == false
        }

        var plan = topologicalPlan(
            records,
            excluding: rejectedIndices,
            edges: edges,
            cycleConflictType: .classificationCommitRejected,
            cycleMessage: "classification commit causal dependency cycle"
        )
        plan.rejected.append(contentsOf: forkRejectedIndices
            .sorted { recordIDComesBefore(records[$0], records[$1]) }
            .map {
                RecordOrderingRejection(
                    record: records[$0],
                    type: .classificationCommitRejected,
                    message: "unsafe same-base classification fork"
                )
            })
        plan.rejected.append(contentsOf: cycleBlockedIndices
            .sorted { recordIDComesBefore(records[$0], records[$1]) }
            .map {
                RecordOrderingRejection(
                    record: records[$0],
                    type: .classificationCommitRejected,
                    message: "classification commit cycle or dependency on cycle"
                )
            })
        plan.rejected.append(contentsOf: dependencyRejectedIndices
            .sorted { recordIDComesBefore(records[$0], records[$1]) }
            .map {
                RecordOrderingRejection(
                    record: records[$0],
                    type: .classificationCommitRejected,
                    message: "classification commit depends on a terminal rejected commit"
                )
            })
        return plan
    }

    private func classificationTerminalClosure(
        from initiallyRejected: Set<Int>,
        edges: Set<RecordDependencyEdge>
    ) -> Set<Int> {
        var rejected = initiallyRejected
        var pending = Array(initiallyRejected)
        while let predecessor = pending.popLast() {
            for edge in edges where edge.predecessor == predecessor {
                if rejected.insert(edge.successor).inserted {
                    pending.append(edge.successor)
                }
            }
        }
        return rejected
    }

    private func classificationCycleBlockedIndices(
        _ envelopes: [ClassificationCommitEnvelope?],
        edges: Set<RecordDependencyEdge>
    ) -> Set<Int> {
        let included = Set(envelopes.indices.filter { envelopes[$0] != nil })
        var outgoing = Dictionary(uniqueKeysWithValues: included.map { ($0, Set<Int>()) })
        var indegree = Dictionary(uniqueKeysWithValues: included.map { ($0, 0) })
        for edge in edges
        where included.contains(edge.predecessor) && included.contains(edge.successor) {
            guard outgoing[edge.predecessor, default: []].insert(edge.successor).inserted else {
                continue
            }
            indegree[edge.successor, default: 0] += 1
        }
        var ready = Array(included.filter { indegree[$0] == 0 })
        var processed: Set<Int> = []
        while let current = ready.popLast() {
            processed.insert(current)
            for successor in outgoing[current, default: []] {
                indegree[successor, default: 0] -= 1
                if indegree[successor] == 0 {
                    ready.append(successor)
                }
            }
        }
        return included.subtracting(processed)
    }

    private func unsafeClassificationForkIndices(
        _ envelopes: [ClassificationCommitEnvelope?],
        causalEdges: Set<RecordDependencyEdge>,
        excluding deferred: Set<Int>
    ) -> Set<Int> {
        var rejected: Set<Int> = []
        for lhs in envelopes.indices {
            guard deferred.contains(lhs) == false,
                  let lhsEnvelope = envelopes[lhs]
            else { continue }
            for rhs in envelopes.indices where lhs < rhs {
                guard deferred.contains(rhs) == false,
                      let rhsEnvelope = envelopes[rhs],
                      classificationEnvelopesConflict(
                          lhsEnvelope,
                          at: lhs,
                          rhsEnvelope,
                          at: rhs,
                          causalEdges: causalEdges
                      )
                else {
                    continue
                }
                rejected.insert(lhs)
                rejected.insert(rhs)
            }
        }
        return rejected
    }

    private func unresolvedClassificationPredecessorIndices(
        _ envelopes: [ClassificationCommitEnvelope?],
        knownCommitIDs: Set<UUID>
    ) -> Set<Int> {
        let availableIDs = knownCommitIDs.union(
            envelopes.compactMap { $0?.changeRecord.id }
        )
        return Set(envelopes.indices.filter { index in
            guard let envelope = envelopes[index] else { return false }
            return Set(envelope.delta.mutation.predecessorChangeRecordIDs)
                .isSubset(of: availableIDs) == false
        })
    }

    private func classificationEnvelopesConflict(
        _ lhs: ClassificationCommitEnvelope,
        at lhsIndex: Int,
        _ rhs: ClassificationCommitEnvelope,
        at rhsIndex: Int,
        causalEdges: Set<RecordDependencyEdge>
    ) -> Bool {
        guard lhs != rhs,
              classificationCausalPath(
                  from: lhsIndex,
                  to: rhsIndex,
                  edges: causalEdges
              ) == false,
              classificationCausalPath(
                  from: rhsIndex,
                  to: lhsIndex,
                  edges: causalEdges
              ) == false
        else {
            return false
        }
        return classificationForksCommute(lhs, rhs) == false
    }

    private func classificationCausalPath(
        from start: Int,
        to target: Int,
        edges: Set<RecordDependencyEdge>
    ) -> Bool {
        var pending = [start]
        var visited: Set<Int> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            for edge in edges where edge.predecessor == current {
                if edge.successor == target { return true }
                pending.append(edge.successor)
            }
        }
        return false
    }

    private func classificationDependencyEdges(
        _ envelopes: [ClassificationCommitEnvelope?],
        excluding rejected: Set<Int>
    ) -> Set<RecordDependencyEdge> {
        var edges: Set<RecordDependencyEdge> = []
        for predecessor in envelopes.indices {
            guard rejected.contains(predecessor) == false,
                  let predecessorEnvelope = envelopes[predecessor]
            else { continue }
            for successor in envelopes.indices where predecessor != successor {
                guard rejected.contains(successor) == false,
                      let successorEnvelope = envelopes[successor],
                      classificationCommit(
                          successorEnvelope,
                          directlyDependsOn: predecessorEnvelope
                      )
                else {
                    continue
                }
                edges.insert(
                    RecordDependencyEdge(
                        predecessor: predecessor,
                        successor: successor
                    )
                )
            }
        }
        return edges
    }

    private func classificationForksCommute(
        _ lhs: ClassificationCommitEnvelope,
        _ rhs: ClassificationCommitEnvelope
    ) -> Bool {
        guard lhs.changeRecord.id != rhs.changeRecord.id,
              lhs.changeRecord.planID != rhs.changeRecord.planID,
              lhs.changeRecord.interactionID != rhs.changeRecord.interactionID
        else {
            return false
        }
        if lhs.isAuditOnlyNoOpRename || rhs.isAuditOnlyNoOpRename {
            return true
        }
        guard postItemsDoNotCollide(lhs, rhs),
              relationHistoryDoesNotCollide(lhs, rhs)
        else {
            return false
        }

        let lhsMutation = lhs.delta.mutation
        let rhsMutation = rhs.delta.mutation
        let overlappingChains = Set(lhsMutation.currentMutations.map(\.id))
            .intersection(rhsMutation.currentMutations.map(\.id))
        let hasNoncommutingChainOverlap = overlappingChains.isEmpty == false
            && setCurrentForksCommute(lhs, rhs) == false
        if hasNoncommutingChainOverlap {
            return false
        }

        let lhsCategoryWrites = relationBlockingCategoryWriteIDs(lhs, against: rhs)
        let rhsCategoryWrites = relationBlockingCategoryWriteIDs(rhs, against: lhs)
        let lhsCategoryFacts = lhs.referencedCategoryIDs.union(lhsCategoryWrites)
        let rhsCategoryFacts = rhs.referencedCategoryIDs.union(rhsCategoryWrites)
        guard lhsCategoryWrites.isDisjoint(with: rhsCategoryFacts),
              rhsCategoryWrites.isDisjoint(with: lhsCategoryFacts)
        else {
            return false
        }

        let lhsLabelWrites = relationBlockingLabelWriteIDs(lhs, against: rhs)
        let rhsLabelWrites = relationBlockingLabelWriteIDs(rhs, against: lhs)
        let lhsLabelFacts = lhs.referencedLabelIDs.union(lhsLabelWrites)
        let rhsLabelFacts = rhs.referencedLabelIDs.union(rhsLabelWrites)
        guard lhsLabelWrites.isDisjoint(with: rhsLabelFacts),
              rhsLabelWrites.isDisjoint(with: lhsLabelFacts)
        else {
            return false
        }
        return true
    }

    private func classificationCommit(
        _ successor: ClassificationCommitEnvelope,
        directlyDependsOn predecessor: ClassificationCommitEnvelope
    ) -> Bool {
        if successor.delta.mutation.predecessorChangeRecordIDs.contains(
            predecessor.changeRecord.id
        ) {
            return true
        }
        if setCurrentCommit(successor, directlyDependsOn: predecessor) {
            return true
        }
        let createdCategoryIDs = Set(
            predecessor.delta.mutation.categoryMutations.compactMap { mutation in
                mutation.expected.value == nil ? mutation.post.value?.id : nil
            }
        )
        if createdCategoryIDs.isDisjoint(with: successor.referencedCategoryIDs) == false {
            return true
        }
        let createdLabelIDs = Set(
            predecessor.delta.mutation.labelMutations.compactMap { mutation in
                mutation.expected.value == nil ? mutation.post.value?.id : nil
            }
        )
        return createdLabelIDs.isDisjoint(with: successor.referencedLabelIDs) == false
    }

    private func setCurrentCommit(
        _ successor: ClassificationCommitEnvelope,
        directlyDependsOn predecessor: ClassificationCommitEnvelope
    ) -> Bool {
        guard let predecessorCurrent = setCurrentFact(predecessor),
              let successorCurrent = setCurrentFact(successor),
              predecessorCurrent.chainID == successorCurrent.chainID
        else {
            return false
        }
        return successorCurrent.expectedBase.value == predecessorCurrent.postState
    }

    private func setCurrentForksCommute(
        _ lhs: ClassificationCommitEnvelope,
        _ rhs: ClassificationCommitEnvelope
    ) -> Bool {
        guard let lhsFact = setCurrentFact(lhs),
              let rhsFact = setCurrentFact(rhs),
              lhsFact.chainID == rhsFact.chainID,
              lhsFact.expectedBase == rhsFact.expectedBase
        else {
            return false
        }
        let lhsPost = lhsFact.postState
        let rhsPost = rhsFact.postState
        return rhsFact.canMerge(into: lhsPost)
            && lhsFact.canMerge(into: rhsPost)
            && rhsFact.merging(into: lhsPost) == lhsFact.merging(into: rhsPost)
    }

    private func setCurrentFact(
        _ envelope: ClassificationCommitEnvelope
    ) -> ClassificationSetCurrentFact? {
        guard case let .setCurrent(mutation) = envelope.delta,
              mutation.currentMutations.count == 1,
              let current = mutation.currentMutations.first,
              let postState = current.post.value
        else {
            return nil
        }
        return ClassificationSetCurrentFact(
            chainID: current.id,
            expectedBase: ClassificationCurrentFact(current.expected.value),
            postState: postState
        )
    }

    private func relationBlockingCategoryWriteIDs(
        _ envelope: ClassificationCommitEnvelope,
        against other: ClassificationCommitEnvelope
    ) -> Set<TaskCategoryID> {
        let mutation = envelope.delta.mutation
        var ids = Set(
            mutation.categoryMergeMutations.map(\.id)
                + mutation.categoryTombstoneMutations.map(\.id)
        )
        if case .rename = envelope.delta, case .setCurrent = other.delta {
            return ids
        }
        ids.formUnion(mutation.categoryMutations.map(\.id))
        return ids
    }

    private func relationBlockingLabelWriteIDs(
        _ envelope: ClassificationCommitEnvelope,
        against other: ClassificationCommitEnvelope
    ) -> Set<TaskLabelID> {
        let mutation = envelope.delta.mutation
        var ids = Set(
            mutation.labelMergeMutations.map(\.id)
                + mutation.labelTombstoneMutations.map(\.id)
        )
        if case .rename = envelope.delta, case .setCurrent = other.delta {
            return ids
        }
        ids.formUnion(mutation.labelMutations.map(\.id))
        return ids
    }

    private func relationHistoryDoesNotCollide(
        _ lhs: ClassificationCommitEnvelope,
        _ rhs: ClassificationCommitEnvelope
    ) -> Bool {
        Set(lhs.delta.mutation.appendedRelationHistory.map(\.id)).isDisjoint(
            with: rhs.delta.mutation.appendedRelationHistory.map(\.id)
        )
    }

    private func postItemsDoNotCollide(
        _ lhs: ClassificationCommitEnvelope,
        _ rhs: ClassificationCommitEnvelope
    ) -> Bool {
        let lhsCategories = lhs.delta.mutation.categoryMutations.compactMap(\.post.value)
        let rhsCategories = rhs.delta.mutation.categoryMutations.compactMap(\.post.value)
        for left in lhsCategories {
            for right in rhsCategories {
                if left.id == right.id, left != right { return false }
                let reusesCanonicalName = Set(
                    left.nameVersions.map(\.canonicalKey) + [left.canonicalKey]
                ).isDisjoint(with: Set(
                    right.nameVersions.map(\.canonicalKey) + [right.canonicalKey]
                )) == false
                if left.id != right.id, reusesCanonicalName {
                    return false
                }
            }
        }
        let lhsLabels = lhs.delta.mutation.labelMutations.compactMap(\.post.value)
        let rhsLabels = rhs.delta.mutation.labelMutations.compactMap(\.post.value)
        for left in lhsLabels {
            for right in rhsLabels {
                if left.id == right.id, left != right { return false }
                let reusesCanonicalName = Set(
                    left.nameVersions.map(\.canonicalKey) + [left.canonicalKey]
                ).isDisjoint(with: Set(
                    right.nameVersions.map(\.canonicalKey) + [right.canonicalKey]
                )) == false
                if left.id != right.id, reusesCanonicalName {
                    return false
                }
            }
        }
        return true
    }

    private func dayTraceOrderingPlan(
        _ records: [SyncRecord]
    ) -> RecordOrderingPlan {
        let traces = records.map { try? mapper.decodeDayTrace($0) }
        var indicesByTraceID: [DayTraceID: [Int]] = [:]
        for index in records.indices {
            if let id = traces[index]?.id {
                indicesByTraceID[id, default: []].append(index)
            }
        }
        var edges: Set<RecordDependencyEdge> = []
        for successor in records.indices {
            guard let trace = traces[successor] else { continue }
            let dependencyIDs = [trace.carriedFromTraceID, trace.changedToTraceID]
                .compactMap { $0 }
            for dependencyID in dependencyIDs {
                for predecessor in indicesByTraceID[dependencyID] ?? [] {
                    edges.insert(
                        RecordDependencyEdge(
                            predecessor: predecessor,
                            successor: successor
                        )
                    )
                }
            }
        }
        return topologicalPlan(
            records,
            excluding: [],
            edges: edges,
            cycleConflictType: .invalidReference,
            cycleMessage: "day trace causal dependency cycle"
        )
    }

    private func traceClassificationEventOrderingPlan(
        _ records: [SyncRecord]
    ) -> RecordOrderingPlan {
        let envelopes = records.map {
            try? mapper.decodeTraceClassificationEvent($0)
        }
        var rejectedIndices: Set<Int> = []

        for lhs in records.indices {
            guard let lhsEnvelope = envelopes[lhs] else { continue }
            for rhs in records.indices where lhs < rhs {
                guard let rhsEnvelope = envelopes[rhs] else { continue }
                let identityCollision = lhsEnvelope.event.id == rhsEnvelope.event.id
                    && lhsEnvelope != rhsEnvelope
                let predecessorFork =
                    lhsEnvelope.event.traceID == rhsEnvelope.event.traceID
                    && lhsEnvelope.predecessorEventID
                    == rhsEnvelope.predecessorEventID
                    && lhsEnvelope.event.id != rhsEnvelope.event.id
                if identityCollision || predecessorFork {
                    rejectedIndices.insert(lhs)
                    rejectedIndices.insert(rhs)
                }
            }
        }

        var indicesByEventID: [UUID: [Int]] = [:]
        for index in records.indices where rejectedIndices.contains(index) == false {
            if let id = envelopes[index]?.event.id {
                indicesByEventID[id, default: []].append(index)
            }
        }
        var edges: Set<RecordDependencyEdge> = []
        for successor in records.indices where rejectedIndices.contains(successor) == false {
            guard let predecessorID = envelopes[successor]?.predecessorEventID else {
                continue
            }
            for predecessor in indicesByEventID[predecessorID] ?? [] {
                edges.insert(
                    RecordDependencyEdge(
                        predecessor: predecessor,
                        successor: successor
                    )
                )
            }
        }

        var plan = topologicalPlan(
            records,
            excluding: rejectedIndices,
            edges: edges,
            cycleConflictType: .traceClassificationEventRejected,
            cycleMessage: "trace classification event causal dependency cycle"
        )
        plan.rejected.append(contentsOf: rejectedIndices
            .sorted { recordIDComesBefore(records[$0], records[$1]) }
            .map {
                RecordOrderingRejection(
                    record: records[$0],
                    type: .traceClassificationEventRejected,
                    message: "trace classification event identity collision or predecessor fork"
                )
            })
        return plan
    }

    private func topologicalPlan(
        _ records: [SyncRecord],
        excluding excluded: Set<Int>,
        edges: Set<RecordDependencyEdge>,
        cycleConflictType: SyncConflictType,
        cycleMessage: String
    ) -> RecordOrderingPlan {
        let included = Set(records.indices).subtracting(excluded)
        var outgoing = Dictionary(uniqueKeysWithValues: included.map { ($0, Set<Int>()) })
        var indegree = Dictionary(uniqueKeysWithValues: included.map { ($0, 0) })
        for edge in edges
        where included.contains(edge.predecessor) && included.contains(edge.successor) {
            guard outgoing[edge.predecessor, default: []]
                .insert(edge.successor).inserted
            else { continue }
            indegree[edge.successor, default: 0] += 1
        }

        var ready = Set(included.filter { indegree[$0] == 0 })
        var orderedIndices: [Int] = []
        while let next = ready.min(by: {
            recordIDComesBefore(records[$0], records[$1])
        }) {
            ready.remove(next)
            orderedIndices.append(next)
            for successor in outgoing[next, default: []] {
                indegree[successor, default: 0] -= 1
                if indegree[successor] == 0 {
                    ready.insert(successor)
                }
            }
        }

        let unresolved = included.subtracting(Set(orderedIndices))
        return RecordOrderingPlan(
            ordered: orderedIndices.map { records[$0] },
            rejected: unresolved
                .sorted { recordIDComesBefore(records[$0], records[$1]) }
                .map {
                    RecordOrderingRejection(
                        record: records[$0],
                        type: cycleConflictType,
                        message: cycleMessage
                    )
                }
        )
    }

    private func recordIDComesBefore(
        _ lhs: SyncRecord,
        _ rhs: SyncRecord
    ) -> Bool {
        lhs.id.rawValue < rhs.id.rawValue
    }

    private func apply(_ day: Day, record: SyncRecord, context: inout MergeContext) {
        guard let existing = context.working.days[day.date] else {
            do {
                try currentRecordMerger.validate(record)
            } catch {
                context.conflicts.append(
                    conflict(
                        .invalidRecordPayload,
                        record: record,
                        detectedAt: context.detectedAt,
                        message: "day contains invalid current facts"
                    )
                )
                return
            }
            context.working.days[day.date] = day
            markApplied(record, context: &context)
            return
        }
        guard existing != day else { return }
        let merged: Day
        do {
            let localRecord = try mapper.record(
                for: existing,
                modifiedBy: SyncDeviceID("local-materialized")
            )
            let mergedRecord = try currentRecordMerger.merge(
                existing: localRecord,
                incoming: record,
                context: CurrentSyncRecordMergeContext(
                    authorizedReactivationChainIDs: context
                        .authorizedReactivationChainIDs
                )
            )
            merged = try mapper.decodeDay(mergedRecord)
        } catch {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "day contains invalid or colliding current facts"
                )
            )
            return
        }
        guard merged != existing else { return }
        context.working.days[day.date] = merged
        markApplied(record, context: &context)
    }

    private func apply(
        _ series: TaskCycleSeries,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        do {
            try series.validateIntegrity()
            try currentRecordMerger.validate(record)
        } catch {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "task cycle series contains invalid current facts"
                )
            )
            return
        }
        let missingClassificationDependencies =
            taskCycleClassificationDependencies(
                missingFrom: series,
                in: context.working
            )
        guard missingClassificationDependencies.isEmpty else {
            wait(
                for: record,
                dependencies: missingClassificationDependencies,
                context: &context
            )
            return
        }
        guard let existing = context.working.taskCycleSeries[series.id]
        else {
            context.working.taskCycleSeries[series.id] = series
            markApplied(record, context: &context)
            return
        }
        guard existing != series else { return }
        do {
            let localRecord = try mapper.record(
                for: existing,
                modifiedBy: SyncDeviceID("local-materialized")
            )
            let mergedRecord = try currentRecordMerger.merge(
                existing: localRecord,
                incoming: record
            )
            let merged = try mapper.decodeTaskCycleSeries(mergedRecord)
            guard merged != existing else { return }
            context.working.taskCycleSeries[series.id] = merged
            markApplied(record, context: &context)
        } catch {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "task cycle series contains colliding current facts"
                )
            )
        }
    }

    private func taskCycleClassificationDependencies(
        missingFrom series: TaskCycleSeries,
        in snapshot: SnapshotIndex
    ) -> [SyncRecordDependency] {
        let categoryDependencies = Set(
            series.classificationRevisions.compactMap(\.categoryID)
        )
            .subtracting(snapshot.classifications.categories.keys)
            .map(SyncRecordDependency.category)
        let labelDependencies = Set(
            series.classificationRevisions.flatMap(\.labelIDs)
        )
            .subtracting(snapshot.classifications.labels.keys)
            .map(SyncRecordDependency.label)
        return categoryDependencies + labelDependencies
    }

    private func apply(_ chain: TaskChain, record: SyncRecord, context: inout MergeContext) {
        guard TaskNoteEntryValidator.firstIssue(in: chain.noteEntries) == nil,
              taskChainClockIsValid(chain)
        else {
            context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "task chain contains invalid current facts"))
            return
        }
        guard let existing = context.working.chains[chain.id] else {
            context.working.chains[chain.id] = chain
            markApplied(record, context: &context)
            return
        }
        guard existing != chain else { return }
        let merged: TaskChain
        do {
            let localRecord = try mapper.record(
                for: existing,
                modifiedBy: SyncDeviceID("local-materialized")
            )
            let mergedRecord = try currentRecordMerger.merge(
                existing: localRecord,
                incoming: record,
                context: CurrentSyncRecordMergeContext(
                    authorizedReactivationChainIDs: context
                        .authorizedReactivationChainIDs
                )
            )
            merged = try mapper.decodeTaskChain(mergedRecord)
        } catch {
            context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "task chain contains invalid or colliding current facts"))
            return
        }
        guard merged != existing else { return }
        context.working.chains[chain.id] = merged
        markApplied(record, context: &context)
    }

    private func apply(
        _ definition: TaskDefinition,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        var missingDependencies: [SyncRecordDependency] = []
        if context.working.chains[definition.chainID] == nil {
            missingDependencies.append(.taskChain(definition.chainID))
        }
        if let successorID = definition.supersededByDefinitionID {
            if context.working.definitions[successorID] == nil {
                missingDependencies.append(.taskDefinition(successorID))
            }
        }
        guard missingDependencies.isEmpty else {
            wait(
                for: record,
                dependencies: missingDependencies,
                context: &context
            )
            return
        }
        guard let existing = context.working.definitions[definition.id] else {
            guard definitionContentClockIsValid(definition) else {
                context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "task definition contains invalid current facts"))
                return
            }
            context.working.definitions[definition.id] = definition
            markApplied(record, context: &context)
            return
        }
        guard existing != definition else { return }

        let merged: TaskDefinition
        do {
            let localRecord = try mapper.record(
                for: existing,
                modifiedBy: SyncDeviceID("local-materialized")
            )
            let mergedRecord = try currentRecordMerger.merge(
                existing: localRecord,
                incoming: record
            )
            merged = try mapper.decodeTaskDefinition(mergedRecord)
        } catch {
            context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "task definition contains invalid or colliding current facts"))
            return
        }
        guard taskDefinitionUpdateIsAllowed(
            from: existing,
            to: merged,
            in: context.working
        ) else {
            context.conflicts.append(conflict(.taskDefinitionMutation, record: record, detectedAt: context.detectedAt, message: "existing historical task definition fields are immutable"))
            return
        }
        guard merged != existing else { return }
        context.working.definitions[definition.id] = merged
        markApplied(record, context: &context)
    }

    private func apply(
        _ trace: DayTrace,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        guard TaskNoteEntryValidator.firstIssue(in: trace.noteEntries) == nil,
              dayTraceContentClockIsValid(trace)
        else {
            context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "day trace contains invalid note entries"))
            return
        }
        let existing = context.working.traces[trace.id]
        if traceAttemptsHistoricalMutation(
            existing: existing,
            incoming: trace,
            context: context
        ) {
            context.conflicts.append(conflict(.historicalTraceMutation, record: record, detectedAt: context.detectedAt, message: "historical or settled traces cannot be silently overwritten"))
            return
        }
        let merged: DayTrace
        do {
            merged = try mergedTrace(
                trace,
                existing: existing,
                record: record,
                context: context
            )
        } catch {
            context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: context.detectedAt, message: "day trace contains invalid or colliding current facts"))
            return
        }
        let missingDependencies = traceMissingDependencies(
            for: merged,
            in: context.working
        )
        guard missingDependencies.isEmpty else {
            wait(
                for: record,
                dependencies: missingDependencies,
                context: &context
            )
            return
        }
        guard context.working.definitions[merged.definitionID]?.chainID
                == merged.chainID
        else {
            context.conflicts.append(
                conflict(
                    .invalidReference,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "day trace definition belongs to a different task chain"
                )
            )
            return
        }
        if let active = conflictingActiveTrace(
            for: merged,
            in: context.working
        ) {
            context.conflicts.append(
                conflict(
                    .duplicateActiveTrace,
                    record: record,
                    localRecordID: SyncRecordID("trace:\(active.id.rawValue.uuidString)"),
                    detectedAt: context.detectedAt,
                    message: "task chain would have more than one active pending trace"
                )
            )
            return
        }
        if traceCancellationIDIsInUse(merged, in: context.working) {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "future draft cancellation identity is already in use"
                )
            )
            return
        }
        context.working.traces[merged.id] = merged
        if existing != merged {
            markApplied(record, context: &context)
        }
    }

    private func traceAttemptsHistoricalMutation(
        existing: DayTrace?,
        incoming: DayTrace,
        context: MergeContext
    ) -> Bool {
        guard let existing else { return false }
        return existing != incoming
            && (existing.status != .pending || existing.settledAt != nil)
            && isSanctionedHistoricalInverse(
                from: existing,
                to: incoming,
                in: context.working,
                authorizedTraceReactivations: context
                    .authorizedTraceReactivations
            ) == false
            && isConcurrentPendingNoteBranch(
                from: existing,
                to: incoming
            ) == false
    }

    private func mergedTrace(
        _ incoming: DayTrace,
        existing: DayTrace?,
        record: SyncRecord,
        context: MergeContext
    ) throws -> DayTrace {
        guard let existing else { return incoming }
        let localRecord = try mapper.record(
            for: existing,
            modifiedBy: SyncDeviceID("local-materialized")
        )
        let mergedRecord = try currentRecordMerger.merge(
            existing: localRecord,
            incoming: record,
            context: CurrentSyncRecordMergeContext(
                daysByDate: context.working.days,
                chainsByID: context.working.chains,
                authorizedReactivationChainIDs: context
                    .authorizedReactivationChainIDs,
                authorizedTraceReactivations: context
                    .authorizedTraceReactivations
            )
        )
        return try mapper.decodeDayTrace(mergedRecord)
    }

    private func traceMissingDependencies(
        for trace: DayTrace,
        in snapshot: SnapshotIndex
    ) -> [SyncRecordDependency] {
        var dependencies: [SyncRecordDependency] = []
        if snapshot.days[trace.date] == nil {
            dependencies.append(.day(trace.date))
        }
        if snapshot.chains[trace.chainID] == nil {
            dependencies.append(.taskChain(trace.chainID))
        }
        if snapshot.definitions[trace.definitionID] == nil {
            dependencies.append(.taskDefinition(trace.definitionID))
        }
        if let sourceID = trace.carriedFromTraceID {
            if snapshot.traces[sourceID] == nil {
                dependencies.append(.dayTrace(sourceID))
            }
        }
        if let targetID = trace.changedToTraceID {
            if snapshot.traces[targetID] == nil {
                dependencies.append(.dayTrace(targetID))
            }
        }
        return dependencies
    }

    private func conflictingActiveTrace(
        for trace: DayTrace,
        in snapshot: SnapshotIndex
    ) -> DayTrace? {
        guard trace.status == .pending else { return nil }
        return snapshot.traces.values.first {
            $0.chainID == trace.chainID
                && $0.status == .pending
                && $0.id != trace.id
        }
    }

    private func traceCancellationIDIsInUse(
        _ trace: DayTrace,
        in snapshot: SnapshotIndex
    ) -> Bool {
        guard let cancellationID = trace.draftCancellationID else {
            return false
        }
        return snapshot.traces.values.contains {
            $0.id != trace.id && $0.draftCancellationID == cancellationID
        }
    }

    private func isSanctionedHistoricalInverse(
        from existing: DayTrace,
        to incoming: DayTrace,
        in snapshot: SnapshotIndex,
        authorizedTraceReactivations: [TraceReactivationAuthorization]
    ) -> Bool {
        guard snapshot.chains[incoming.chainID]?.state == .active else {
            return false
        }
        guard incoming.contentUpdatedAt > existing.contentUpdatedAt else {
            return false
        }

        if existing.status == .abandoned {
            return authorizedTraceReactivations.contains {
                $0.abandoned == existing
                    && $0.restoredSuccessor == incoming
            }
        }

        let isUnlockedCompletionUndo = existing.status == .completed
            && existing.completedAt != nil
            && incoming.status == .pending
            && incoming.completedAt == nil
            && incoming.settledAt == existing.settledAt
            && snapshot.days[existing.date].map { $0.lockedAt == nil } == true
        if isUnlockedCompletionUndo {
            var permitted = existing
            permitted.status = .pending
            permitted.completedAt = nil
            return dayTraceMatchesIgnoringContentClock(permitted, incoming)
        }

        let isUnlockedCancelledDraftUndo = existing.status == .cancelledDraft
            && existing.draftCancellationID != nil
            && existing.draftCancelledOn != nil
            && existing.completedAt == nil
            && existing.settledAt != nil
            && incoming.status == .pending
            && incoming.draftCancellationID == existing.draftCancellationID
            && incoming.draftCancelledOn == nil
            && incoming.completedAt == nil
            && incoming.settledAt == nil
            && snapshot.days[existing.date].map { $0.lockedAt == nil } == true
        if isUnlockedCancelledDraftUndo {
            var permitted = existing
            permitted.status = .pending
            permitted.settledAt = nil
            permitted.draftCancelledOn = nil
            return dayTraceMatchesIgnoringContentClock(permitted, incoming)
        }

        return false
    }

    private func isConcurrentPendingNoteBranch(
        from historical: DayTrace,
        to pending: DayTrace
    ) -> Bool {
        pending.status == .pending
            && pending.draftCancellationID == historical.draftCancellationID
            && pending.draftCancelledOn == nil
            && pending.completedAt == nil
            && pending.settledAt == nil
            && pending.contentUpdatedAt < historical.contentUpdatedAt
            && pending.id == historical.id
            && pending.chainID == historical.chainID
            && pending.definitionID == historical.definitionID
            && pending.date == historical.date
            && pending.priority == historical.priority
            && pending.continuationSeq == historical.continuationSeq
            && pending.descriptionText == historical.descriptionText
            && pending.manualProgressPercent == historical.manualProgressPercent
            && pending.carriedFromTraceID == historical.carriedFromTraceID
            && pending.changedToTraceID == historical.changedToTraceID
            && pending.createdAt == historical.createdAt
    }

    private func definitionContentClockIsValid(
        _ definition: TaskDefinition
    ) -> Bool {
        definition.createdAt.timeIntervalSinceReferenceDate.isFinite
            && definition.contentUpdatedAt.timeIntervalSinceReferenceDate.isFinite
            && definition.contentUpdatedAt >= definition.createdAt
            && definition.supersededAt.map {
                $0.timeIntervalSinceReferenceDate.isFinite
                    && $0 >= definition.createdAt
                    && $0 <= definition.contentUpdatedAt
            } ?? true
    }

    private func taskChainClockIsValid(_ chain: TaskChain) -> Bool {
        chain.createdAt.timeIntervalSinceReferenceDate.isFinite
            && chain.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && chain.updatedAt >= chain.createdAt
    }

    private func dayTraceContentClockIsValid(_ trace: DayTrace) -> Bool {
        let contentClockIsValid = trace.createdAt.timeIntervalSinceReferenceDate.isFinite
            && trace.contentUpdatedAt.timeIntervalSinceReferenceDate.isFinite
            && trace.contentUpdatedAt >= trace.createdAt
            && [trace.completedAt, trace.settledAt].compactMap { $0 }.allSatisfy {
                $0.timeIntervalSinceReferenceDate.isFinite
                    && $0 >= trace.createdAt
                    && $0 <= trace.contentUpdatedAt
            }
        guard contentClockIsValid else { return false }
        if trace.status == .cancelledDraft {
            guard trace.draftCancellationID != nil,
                  let draftCancelledOn = trace.draftCancelledOn
            else {
                return false
            }
            let isSnapshotUndoCancellation =
                trace.date == draftCancelledOn
            let isFutureDraftCancellation =
                trace.date > draftCancelledOn
                    && trace.manualProgressPercent == nil
                    && trace.carriedFromTraceID == nil
            return (isSnapshotUndoCancellation
                || isFutureDraftCancellation)
                && trace.completedAt == nil
                && trace.settledAt != nil
                && trace.changedToTraceID == nil
        }
        return trace.draftCancelledOn == nil
    }

    private func taskDefinitionUpdateIsAllowed(
        from existing: TaskDefinition,
        to incoming: TaskDefinition,
        in snapshot: SnapshotIndex
    ) -> Bool {
        if taskDefinitionContentMatches(existing, incoming) {
            return true
        }
        let isHistorical = snapshot.traces.values.contains {
            $0.definitionID == existing.id && $0.formsDayHistory
        }
        guard isHistorical else { return true }
        let isSupersessionUndo =
            existing.supersededAt != nil
                && existing.supersededByDefinitionID != nil
                && incoming.supersededAt == nil
                && incoming.supersededByDefinitionID
                == existing.supersededByDefinitionID
                && incoming.contentUpdatedAt > existing.contentUpdatedAt
                && existing.id == incoming.id
                && existing.chainID == incoming.chainID
                && existing.sequence == incoming.sequence
                && existing.title == incoming.title
                && existing.descriptionText == incoming.descriptionText
                && existing.plannedSubtasks == incoming.plannedSubtasks
                && existing.createdAt == incoming.createdAt
        if isSupersessionUndo {
            return true
        }
        guard existing.supersededAt == nil,
              incoming.supersededAt != nil,
              incoming.supersededByDefinitionID != nil,

                  existing.supersededByDefinitionID == nil
                      || existing.supersededByDefinitionID
                      == incoming.supersededByDefinitionID,

              incoming.contentUpdatedAt > existing.contentUpdatedAt
        else {
            return false
        }
        return existing.id == incoming.id
            && existing.chainID == incoming.chainID
            && existing.sequence == incoming.sequence
            && existing.title == incoming.title
            && existing.descriptionText == incoming.descriptionText
            && existing.plannedSubtasks == incoming.plannedSubtasks
            && existing.createdAt == incoming.createdAt
    }

    private func taskDefinitionContentMatches(
        _ lhs: TaskDefinition,
        _ rhs: TaskDefinition
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.sequence == rhs.sequence
            && lhs.title == rhs.title
            && lhs.descriptionText == rhs.descriptionText
            && lhs.plannedSubtasks == rhs.plannedSubtasks
            && lhs.createdAt == rhs.createdAt
            && lhs.contentUpdatedAt == rhs.contentUpdatedAt
            && lhs.supersededAt == rhs.supersededAt
            && lhs.supersededByDefinitionID == rhs.supersededByDefinitionID
    }

    private func dayTraceMatchesIgnoringContentClock(
        _ lhs: DayTrace,
        _ rhs: DayTrace
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.definitionID == rhs.definitionID
            && lhs.date == rhs.date
            && lhs.status == rhs.status
            && lhs.priority == rhs.priority
            && lhs.continuationSeq == rhs.continuationSeq
            && lhs.descriptionText == rhs.descriptionText
            && lhs.noteEntries == rhs.noteEntries
            && lhs.manualProgressPercent == rhs.manualProgressPercent
            && lhs.carriedFromTraceID == rhs.carriedFromTraceID
            && lhs.changedToTraceID == rhs.changedToTraceID
            && lhs.createdAt == rhs.createdAt
            && lhs.completedAt == rhs.completedAt
            && lhs.settledAt == rhs.settledAt
            && lhs.draftCancellationID == rhs.draftCancellationID
            && lhs.draftCancelledOn == rhs.draftCancelledOn
    }

    private func apply(
        _ subtask: Subtask,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        do {
            try currentRecordMerger.validate(record)
        } catch {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "subtask contains invalid current facts"
                )
            )
            return
        }
        guard let parentTrace = context.working.traces[subtask.traceID] else {
            wait(
                for: record,
                dependencies: [.dayTrace(subtask.traceID)],
                context: &context
            )
            return
        }
        if let missingSourceID = missingContinuationSourceID(
            for: subtask,
            in: context.working
        ) {
            wait(
                for: record,
                dependencies: [.subtask(missingSourceID)],
                context: &context
            )
            return
        }
        guard let existing = context.working.subtasks[subtask.id] else {
            guard subtaskCancellationIDIsAvailable(
                subtask,
                in: context.working
            ) else {
                context.conflicts.append(
                    conflict(
                        .invalidRecordPayload,
                        record: record,
                        detectedAt: context.detectedAt,
                        message: "subtask cancellation identity is already in use"
                    )
                )
                return
            }
            context.working.subtasks[subtask.id] = subtask
            markApplied(record, context: &context)
            return
        }
        guard existing != subtask else { return }
        let merged: Subtask
        do {
            let localRecord = try mapper.record(
                for: existing,
                modifiedBy: SyncDeviceID("local-materialized")
            )
            let mergedRecord = try currentRecordMerger.merge(
                existing: localRecord,
                incoming: record
            )
            merged = try mapper.decodeSubtask(mergedRecord)
        } catch {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "subtask current records could not be merged"
                )
            )
            return
        }
        guard merged != existing else { return }
        guard parentTrace.status == .pending, parentTrace.settledAt == nil else {
            context.conflicts.append(conflict(.historicalSubtaskMutation, record: record, detectedAt: context.detectedAt, message: "subtasks under historical or settled traces cannot be silently overwritten"))
            return
        }
        guard subtaskCancellationIDIsAvailable(
            merged,
            in: context.working
        ) else {
            context.conflicts.append(
                conflict(
                    .invalidRecordPayload,
                    record: record,
                    detectedAt: context.detectedAt,
                    message: "subtask cancellation identity is already in use"
                )
            )
            return
        }
        context.working.subtasks[merged.id] = merged
        markApplied(record, context: &context)
    }

    private func missingContinuationSourceID(
        for subtask: Subtask,
        in snapshot: SnapshotIndex
    ) -> SubtaskID? {
        guard let sourceID = subtask.carriedFromSubtaskID else {
            return nil
        }
        return snapshot.subtasks[sourceID] == nil ? sourceID : nil
    }

    private func subtaskCancellationIDIsAvailable(
        _ candidate: Subtask,
        in snapshot: SnapshotIndex
    ) -> Bool {
        guard let cancellationID = candidate.draftCancellationID else {
            return true
        }
        return snapshot.subtasks.values.contains {
            $0.id != candidate.id
                && $0.draftCancellationID == cancellationID
        } == false
    }

    private func apply(_ envelope: AppPreferencesEnvelope, record: SyncRecord, context: inout MergeContext) {
        let current = context.working.preferences
        guard let order = AppPreferences.themeLanguageVersionOrder(
            clock: envelope.updatedAt,
            writerID: envelope.writerDeviceID.rawValue,
            comparedToClock: current.themeLanguageUpdatedAt,
            writerID: current.themeLanguageWriterID
        ) else {
            reject(
                .invalidRecordPayload,
                record: record,
                message: "app preferences version is invalid",
                context: &context
            )
            return
        }
        if order == .orderedAscending { return }
        if order == .orderedSame {
            guard envelope.theme == current.theme,
                  envelope.language == current.language
            else {
                reject(
                    .invalidRecordPayload,
                    record: record,
                    message: "app preferences version diverged",
                    context: &context
                )
                return
            }
            return
        }
        do {
            context.working.preferences = try current
                .applyingSyncedThemeLanguage(
                    theme: envelope.theme,
                    language: envelope.language,
                    updatedAt: envelope.updatedAt,
                    writerID: envelope.writerDeviceID.rawValue
                )
            markApplied(record, context: &context)
        } catch {
            reject(
                .invalidRecordPayload,
                record: record,
                message: "app preferences clock could not be applied",
                context: &context
            )
        }
    }

    private func apply(
        _ envelope: TraceClassificationEventEnvelope,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        if let predecessorID = terminalRejectedPredecessorID(
            for: envelope,
            context: context
        ) {
            rejectTraceClassificationEvent(
                record,
                message: "trace classification event depends on terminal rejected event \(predecessorID.uuidString)",
                context: &context
            )
            return
        }

        let event = envelope.event
        let allStreams = context.working.classifications.snapshotEventsByTraceID
        if let existing = existingTraceClassificationEvent(
            event.id,
            in: allStreams
        ) {
            let isExactDuplicate = existing.event == event
                && existing.predecessorID == envelope.predecessorEventID
            if isExactDuplicate { return }
            rejectTraceClassificationEvent(
                record,
                message: "trace classification event identity collision",
                context: &context
            )
            return
        }

        if let message = traceClassificationDeletionConflict(
            event,
            state: context.working.classifications
        ) {
            rejectTraceClassificationEvent(record, message: message, context: &context)
            return
        }

        let missing = missingTraceClassificationDependencies(
            envelope,
            context: context
        )
        guard missing.isEmpty else {
            let dependencies = missing.sorted(
                by: dependencyComesBefore
            ).map(SyncRecordDependency.init)
            if dependencies.contains(where: {
                context.terminalProviderDependencies.contains($0)
            }) {
                rejectTraceClassificationEvent(
                    record,
                    message: "trace classification event depends on a fact supplied only by terminally rejected evidence",
                    context: &context
                )
                return
            }
            context.waiting.append(
                SyncWaitingRecord(
                    record: record,
                    dependencies: dependencies
                )
            )
            return
        }

        let localEvents = allStreams[event.traceID] ?? []
        if let message = traceClassificationSequenceConflict(
            envelope,
            localEvents: localEvents
        ) {
            rejectTraceClassificationEvent(record, message: message, context: &context)
            return
        }

        let localRevision = context.working.classifications.revision
        let waitsForRevision = localRevision < UInt64.max
            && event.revision > localRevision + 1
        if waitsForRevision {
            context.waiting.append(
                SyncWaitingRecord(
                    record: record,
                    dependencies: [
                        .classificationRevision(event.revision - 1)
                    ]
                )
            )
            return
        }
        guard localRevision < UInt64.max else {
            rejectTraceClassificationEvent(
                record,
                message: "classification revision is exhausted",
                context: &context
            )
            return
        }

        var candidate = context
        candidate.working.classifications.snapshotEventsByTraceID[
            event.traceID,
            default: []
        ].append(event)
        candidate.working.classifications.snapshotsByTraceID[event.traceID] = event
        candidate.working.classifications.revision += 1
        do {
            try candidate.working.snapshot().validateIntegrity()
        } catch {
            rejectTraceClassificationEvent(
                record,
                message: "trace classification event is invalid: \(error)",
                context: &context
            )
            return
        }
        context = candidate
        markApplied(record, context: &context)
    }

    private func terminalRejectedPredecessorID(
        for envelope: TraceClassificationEventEnvelope,
        context: MergeContext
    ) -> UUID? {
        guard let predecessorID = envelope.predecessorEventID,
              context.terminalRejections[
                  .traceClassificationEvent(predecessorID)
              ] != nil
        else { return nil }
        return predecessorID
    }

    private func existingTraceClassificationEvent(
        _ id: UUID,
        in streams: [DayTraceID: [TraceClassificationSnapshot]]
    ) -> (event: TraceClassificationSnapshot, predecessorID: UUID?)? {
        for events in streams.values {
            guard let index = events.firstIndex(where: { $0.id == id }) else {
                continue
            }
            let predecessorID = index == events.startIndex
                ? nil
                : events[events.index(before: index)].id
            return (events[index], predecessorID)
        }
        return nil
    }

    private func traceClassificationDeletionConflict(
        _ event: TraceClassificationSnapshot,
        state: TaskClassificationState
    ) -> String? {
        let deletedCategoryID = (event.category?.id).flatMap {
            state.categoryDeletionTombstones[$0] == nil ? nil : $0
        }
        if deletedCategoryID != nil {
            return "trace classification event category was permanently deleted"
        }
        if let labelID = event.labels.map(\.id).first(where: {
            state.labelDeletionTombstones[$0] != nil
        }) {
            return "trace classification event label \(labelID) was permanently deleted"
        }
        return nil
    }

    private func missingTraceClassificationDependencies(
        _ envelope: TraceClassificationEventEnvelope,
        context: MergeContext
    ) -> Set<ClassificationCommitDependency> {
        let event = envelope.event
        let classifications = context.working.classifications
        var missing: Set<ClassificationCommitDependency> = []
        if context.working.traces[event.traceID] == nil {
            missing.insert(.dayTrace(event.traceID))
        }
        if let categoryID = event.category?.id {
            if classifications.categories[categoryID] == nil {
                missing.insert(.category(categoryID))
            }
        }
        for labelID in Set(event.labels.map(\.id))
        where classifications.labels[labelID] == nil {
            missing.insert(.label(labelID))
        }
        let eventIDs = classifications.snapshotEventsByTraceID.values
            .joined()
            .map(\.id)
        if let predecessorID = envelope.predecessorEventID {
            if eventIDs.contains(predecessorID) == false {
                missing.insert(.classificationEvent(predecessorID))
            }
        }
        return missing
    }

    private func traceClassificationSequenceConflict(
        _ envelope: TraceClassificationEventEnvelope,
        localEvents: [TraceClassificationSnapshot]
    ) -> String? {
        guard envelope.predecessorEventID == localEvents.last?.id else {
            return "trace classification event predecessor fork"
        }
        let revisionDidNotAdvance = localEvents.last.map {
            envelope.event.revision <= $0.revision
        } ?? false
        if revisionDidNotAdvance {
            return "trace classification event revision is not increasing"
        }
        return nil
    }

    private func rejectTraceClassificationEvent(
        _ record: SyncRecord,
        message: String,
        context: inout MergeContext
    ) {
        reject(
            .traceClassificationEventRejected,
            record: record,
            message: message,
            context: &context
        )
    }

    private func apply(
        _ envelope: ClassificationCommitEnvelope,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        let terminalPredecessors = envelope.delta.mutation.predecessorChangeRecordIDs
            .filter {
                context.terminalRejections[.classificationCommit($0)] != nil
            }
            .sorted { $0.uuidString < $1.uuidString }
        guard terminalPredecessors.isEmpty else {
            reject(
                .classificationCommitRejected,
                record: record,
                message: "classification commit depends on terminal rejected commit \(terminalPredecessors[0].uuidString)",
                context: &context
            )
            return
        }

        switch ClassificationCommitEnvelopeReceiver().apply(
            envelope,
            to: context.working.snapshot()
        ) {
        case let .applied(snapshot):
            context.working.classifications = snapshot.classifications
            markApplied(record, context: &context)
        case .duplicate:
            return
        case let .waiting(dependencies):
            let syncDependencies = dependencies.map(
                SyncRecordDependency.init
            )
            if syncDependencies.contains(where: {
                context.terminalProviderDependencies.contains($0)
            }) {
                reject(
                    .classificationCommitRejected,
                    record: record,
                    message: "classification commit depends on a fact supplied only by terminally rejected evidence",
                    context: &context
                )
                return
            }
            context.waiting.append(
                SyncWaitingRecord(
                    record: record,
                    dependencies: syncDependencies
                )
            )
        case let .conflicted(reason):
            reject(
                .classificationCommitRejected,
                record: record,
                message: String(describing: reason),
                context: &context
            )
        }
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

    private func conflict(
        _ type: SyncConflictType,
        record: SyncRecord,
        localRecordID: SyncRecordID? = nil,
        detectedAt: Date,
        message: String
    ) -> SyncConflict {
        SyncConflict(
            type: type,
            entityType: record.entityType,
            entityID: record.entityID,
            localRecordID: localRecordID,
            remoteRecord: record,
            detectedAt: detectedAt,
            message: message
        )
    }

    private func wait(
        for record: SyncRecord,
        dependencies: [SyncRecordDependency],
        context: inout MergeContext
    ) {
        let canonicalDependencies = Array(Set(dependencies)).sorted(
            by: syncDependencyComesBefore
        )
        if canonicalDependencies.contains(where: {
            dependencyWasRejected($0, context: context)
        }) {
            reject(
                .invalidReference,
                record: record,
                message: "record depends on a current fact rejected in this merge",
                context: &context
            )
            return
        }
        context.waiting.append(
            SyncWaitingRecord(
                record: record,
                dependencies: canonicalDependencies
            )
        )
    }

    private func dependencyWasRejected(
        _ dependency: SyncRecordDependency,
        context: MergeContext
    ) -> Bool {
        if context.terminalProviderDependencies.contains(dependency) {
            return true
        }
        return context.conflicts.contains {
            rejectedRecord($0.remoteRecord, provides: dependency)
        }
    }

    private func rejectedRecord(
        _ record: SyncRecord,
        provides dependency: SyncRecordDependency
    ) -> Bool {
        switch dependency {
        case let .day(date):
            return record.entityType == .day
                && (try? mapper.decodeDay(record).date) == date
        case let .taskChain(id):
            return record.entityType == .taskChain
                && record.entityID == id.description
        case let .taskDefinition(id):
            return record.entityType == .taskDefinition
                && record.entityID == id.description
        case let .dayTrace(id):
            return record.entityType == .dayTrace
                && record.entityID == id.description
        case let .subtask(id):
            return record.entityType == .subtask
                && record.entityID == id.description
        case let .classificationEvent(id):
            return record.entityType == .traceClassificationEvent
                && record.entityID == id.uuidString
        case let .classificationCommit(id):
            return record.entityType == .classificationCommit
                && record.entityID == id.uuidString
        case .category, .label, .classificationRevision,
             .currentSnapshotIntegrity:
            return false
        }
    }

    private func syncDependencyComesBefore(
        _ lhs: SyncRecordDependency,
        _ rhs: SyncRecordDependency
    ) -> Bool {
        syncDependencySortKey(lhs) < syncDependencySortKey(rhs)
    }

    private func syncDependencySortKey(
        _ dependency: SyncRecordDependency
    ) -> (Int, String) {
        switch dependency {
        case let .day(date):
            (0, date.description)
        case let .taskChain(id):
            (1, id.description)
        case let .taskDefinition(id):
            (2, id.description)
        case let .dayTrace(id):
            (3, id.description)
        case let .subtask(id):
            (4, id.description)
        case .category, .label, .classificationEvent,
             .classificationCommit, .classificationRevision,
             .currentSnapshotIntegrity:
            classificationDependencySortKey(dependency)
        }
    }

    private func classificationDependencySortKey(
        _ dependency: SyncRecordDependency
    ) -> (Int, String) {
        switch dependency {
        case let .category(id):
            (5, id.description)
        case let .label(id):
            (6, id.description)
        case let .classificationEvent(id):
            (7, id.uuidString)
        case let .classificationCommit(id):
            (8, id.uuidString)
        case let .classificationRevision(revision):
            (9, String(format: "%020llu", revision))
        case .currentSnapshotIntegrity:
            (10, "current-snapshot-integrity")
        case .day, .taskChain, .taskDefinition, .dayTrace, .subtask:
            preconditionFailure("unexpected structural sync dependency")
        }
    }

    private func reject(
        _ type: SyncConflictType,
        record: SyncRecord,
        message: String,
        context: inout MergeContext
    ) {
        context.conflicts.append(
            conflict(
                type,
                record: record,
                detectedAt: context.detectedAt,
                message: message
            )
        )
        if let conflict = context.conflicts.last, let terminal = SyncTerminalRejection(conflict: conflict) {
            registerTerminalRejection(terminal, context: &context)
        }
    }

    private func markApplied(
        _ record: SyncRecord,
        context: inout MergeContext
    ) {
        context.applied.append(record.id)
        context.appliedRecordIDByEvidence[
            SyncRecordEvidenceID(record: record)
        ] = record.id
    }

    private func registerTerminalRejection(
        _ rejection: SyncTerminalRejection,
        context: inout MergeContext
    ) {
        context.terminalProviderDependencies.formUnion(
            terminalProviderDependencies(
                from: rejection.conflict.remoteRecord
            )
        )
        guard let existing = context.terminalRejections[rejection.identity] else {
            context.terminalRejections[rejection.identity] = rejection
            return
        }
        if rejection.conflict.id.uuidString < existing.conflict.id.uuidString {
            context.terminalRejections[rejection.identity] = rejection
        }
    }

    private func terminalProviderDependencies(
        from record: SyncRecord
    ) -> Set<SyncRecordDependency> {
        switch record.entityType {
        case .classificationCommit:
            guard let envelope = try? mapper.decodeClassificationCommit(record)
            else { return [] }
            var dependencies: Set<SyncRecordDependency> = [
                .classificationCommit(envelope.changeRecord.id)
            ]
            for mutation in envelope.delta.mutation.categoryMutations
            where mutation.expected.value == nil && mutation.post.value != nil {
                dependencies.insert(.category(mutation.id))
            }
            for mutation in envelope.delta.mutation.labelMutations
            where mutation.expected.value == nil && mutation.post.value != nil {
                dependencies.insert(.label(mutation.id))
            }
            return dependencies
        case .traceClassificationEvent:
            guard let envelope = try? mapper.decodeTraceClassificationEvent(record)
            else { return [] }
            return [.classificationEvent(envelope.event.id)]
        case .day, .taskCycleSeries, .taskChain, .taskDefinition, .dayTrace, .subtask,
             .appPreferences:
            return []
        }
    }
}

private struct RecordOrderingPlan {
    var ordered: [SyncRecord]
    var rejected: [RecordOrderingRejection]
}

private struct InputCanonicalizationPlan {
    var records: [SyncRecord]
    var conflicts: [SyncConflict]
    var provenanceGroups: [SyncRecordProvenanceGroup]
}

private struct InputRecordPartition {
    var immutableRecords: [SyncRecord] = []
    var currentRecords: [SyncRecord] = []
    var conflicts: [SyncConflict] = []
    var provenanceGroups: [SyncRecordProvenanceGroup] = []
}

private enum CanonicalRecordGroup {
    case immutable(SyncRecord)
    case current([SyncRecord], conflicts: [SyncConflict])
    case conflicts([SyncConflict])
    case empty
}

private struct RecordOrderingRejection {
    var record: SyncRecord
    var type: SyncConflictType
    var message: String
}

private struct RecordDependencyEdge: Hashable {
    var predecessor: Int
    var successor: Int
}

private enum CurrentStructuralToken: Hashable {
    case taskChain(TaskChainID)
    case taskCycleSeries(TaskCycleSeriesID)
    case taskDefinition(TaskDefinitionID)
    case day(LocalDate)
    case dayIdentity(DayID)
    case dayTrace(DayTraceID)
    case subtask(SubtaskID)
    case visiblePriority(LocalDate, Int)
    case draftCancellation(UUID)
    case legacy(String)
    case isolated(SyncRecordID)
}

private struct MergeContext {
    var working: SnapshotIndex
    var conflicts: [SyncConflict]
    var applied: [SyncRecordID]
    var appliedRecordIDByEvidence: [SyncRecordEvidenceID: SyncRecordID]
    var waiting: [SyncWaitingRecord]
    var terminalRejections: [SyncTerminalRecordIdentity: SyncTerminalRejection]
    var terminalProviderDependencies: Set<SyncRecordDependency>
    var authorizedReactivationChainIDs: Set<TaskChainID>
    var authorizedTraceReactivations: [TraceReactivationAuthorization]
    var detectedAt: Date

    init(
        working: SnapshotIndex,
        knownTerminalRejections: [SyncTerminalRejection],
        knownTerminalProviderDependencies: Set<SyncRecordDependency>,
        authorizedReactivationChainIDs: Set<TaskChainID>,
        authorizedTraceReactivations: [TraceReactivationAuthorization],
        detectedAt: Date
    ) {
        self.working = working
        self.conflicts = []
        self.applied = []
        self.appliedRecordIDByEvidence = [:]
        self.waiting = []
        self.terminalRejections = knownTerminalRejections.reduce(into: [:]) {
            if let existing = $0[$1.identity] {
                if $1.conflict.id.uuidString < existing.conflict.id.uuidString {
                    $0[$1.identity] = $1
                }
            } else {
                $0[$1.identity] = $1
            }
        }
        self.terminalProviderDependencies = knownTerminalProviderDependencies
        self.authorizedReactivationChainIDs = authorizedReactivationChainIDs
        self.authorizedTraceReactivations = authorizedTraceReactivations
        self.detectedAt = detectedAt
    }
}

private struct SnapshotIndex {
    var days: [LocalDate: Day]
    var taskCycleSeries: [TaskCycleSeriesID: TaskCycleSeries]
    var chains: [TaskChainID: TaskChain]
    var definitions: [TaskDefinitionID: TaskDefinition]
    var traces: [DayTraceID: DayTrace]
    var subtasks: [SubtaskID: Subtask]
    var preferences: AppPreferences
    var classifications: TaskClassificationState

    init(_ snapshot: NoonmarkSnapshot) {
        days = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) })
        taskCycleSeries = Dictionary(
            uniqueKeysWithValues: snapshot.taskCycleSeries.map {
                ($0.id, $0)
            }
        )
        chains = Dictionary(uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) })
        definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        traces = Dictionary(uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) })
        subtasks = Dictionary(uniqueKeysWithValues: snapshot.subtasks.map { ($0.id, $0) })
        preferences = snapshot.preferences
        classifications = snapshot.classifications
    }

    func snapshot() -> NoonmarkSnapshot {
        NoonmarkSnapshot(
            days: days.values.sorted { $0.date < $1.date },
            taskCycleSeries: taskCycleSeries.values.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.description < $1.id.description
            },
            chains: chains.values.sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.description < $1.id.description
                }
                return $0.createdAt < $1.createdAt
            },
            definitions: definitions.values.sorted {
                if $0.chainID == $1.chainID {
                    return $0.sequence < $1.sequence
                }
                return $0.chainID.description < $1.chainID.description
            },
            traces: traces.values.sorted {
                if $0.date != $1.date {
                    return $0.date < $1.date
                }
                if $0.continuationSeq != $1.continuationSeq {
                    return $0.continuationSeq < $1.continuationSeq
                }
                if $0.priority != $1.priority {
                    return $0.priority < $1.priority
                }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.description < $1.id.description
            },
            subtasks: subtasks.values.sorted {
                if $0.traceID == $1.traceID {
                    return $0.position < $1.position
                }
                return $0.traceID.description < $1.traceID.description
            },
            preferences: preferences,
            classifications: classifications
        )
    }
}

import Foundation
import NoonmarkCore

enum CurrentSyncRecordMergeError: Error, Equatable {
    case taskCycleSeriesIdentityCollision
    case taskChainIdentityCollision
    case taskDefinitionIdentityCollision
    case dayTraceIdentityCollision
    case invalidContentClock
    case invalidReactivationWitnesses
}

enum CurrentSyncRecordBatchError: Error, Equatable {
    case invalidCurrentRecord(
        recordID: SyncRecordID,
        reason: SyncRecordMergeFailureReason
    )
}

extension SyncRecordMergeFailureReason {
    /// Classifies an error thrown inside current-record validation or merging
    /// into a privacy-safe reason. Untyped errors collapse to `.unknown` so
    /// diagnostics never carry free text, identity, or payload content.
    init(underlying error: Error) {
        switch error {
        case let mergeError as CurrentSyncRecordMergeError:
            self = switch mergeError {
            case .taskCycleSeriesIdentityCollision:
                .taskCycleSeriesIdentityCollision
            case .taskChainIdentityCollision:
                .taskChainIdentityCollision
            case .taskDefinitionIdentityCollision:
                .taskDefinitionIdentityCollision
            case .dayTraceIdentityCollision:
                .dayTraceIdentityCollision
            case .invalidContentClock:
                .invalidContentClock
            case .invalidReactivationWitnesses:
                .invalidReactivationWitnesses
            }
        case let noteError as TaskNoteEntryMergeError:
            self = switch noteError {
            case .invalidEntries:
                .invalidNoteEntries
            case .createdAtCollision:
                .noteEntryCreatedAtCollision
            }
        case is ChainReactivationEnvelopeError:
            self = .invalidReactivationWitnesses
        case let domainError as NoonmarkError:
            self = switch domainError {
            case .invalidInput:
                .invalidRecordPayload
            default:
                .unknown
            }
        case let batchError as CurrentSyncRecordBatchError:
            switch batchError {
            case let .invalidCurrentRecord(_, reason):
                self = reason
            }
        case is SyncRecordMapperError, is SyncRecordMaterializerError:
            self = .invalidRecordPayload
        default:
            self = .unknown
        }
    }
}

struct CurrentSyncRecordMergeContext {
    static let empty = CurrentSyncRecordMergeContext()

    var daysByDate: [LocalDate: Day]
    var chainsByID: [TaskChainID: TaskChain]
    var authorizedReactivationChainIDs: Set<TaskChainID>
    var authorizedTraceReactivations: [TraceReactivationAuthorization]

    init(
        daysByDate: [LocalDate: Day] = [:],
        chainsByID: [TaskChainID: TaskChain] = [:],
        authorizedReactivationChainIDs: Set<TaskChainID> = [],
        authorizedTraceReactivations: [TraceReactivationAuthorization] = []
    ) {
        self.daysByDate = daysByDate
        self.chainsByID = chainsByID
        self.authorizedReactivationChainIDs = authorizedReactivationChainIDs
        self.authorizedTraceReactivations = authorizedTraceReactivations
    }
}

struct TraceReactivationAuthorization: Equatable {
    var abandoned: DayTrace
    var restoredSuccessor: DayTrace
}

struct CurrentSyncReactivationAuthorizations {
    var chainIDs: Set<TaskChainID> = []
    var tracePairs: [TraceReactivationAuthorization] = []
}

struct CurrentSyncTransportBatch {
    var records: [SyncRecord]
    var mergeContext: CurrentSyncRecordMergeContext
    var provenanceGroups: [SyncRecordProvenanceGroup]
}

private struct CurrentSyncReactivationEvidence {
    var chains: [TaskChain] = []
    var traces: [DayTrace] = []
    var witnesses: [ChainReactivationEnvelope] = []
}

struct ImmutableSyncRecordCASCandidate {
    var record: SyncRecord
    var exactData: Data?
}

enum ImmutableSyncRecordCASPreflight {
    static func validate(
        existing: [ImmutableSyncRecordCASCandidate],
        incoming: [ImmutableSyncRecordCASCandidate]
    ) throws {
        var staged: [SyncRecordID: ImmutableSyncRecordCASCandidate] = [:]
        for candidate in existing {
            staged[candidate.record.id] = candidate
        }

        for candidate in incoming {
            let record = candidate.record
            guard let existing = staged[record.id] else {
                staged[record.id] = candidate
                continue
            }
            let requiresImmutableCAS = existing.record.entityType
                .requiresImmutableRecordPayload
                || record.entityType.requiresImmutableRecordPayload
            guard requiresImmutableCAS else { continue }
            guard record.exactlyMatches(existing.record),
                  candidate.exactData == existing.exactData
            else {
                throw SyncRecordTransportError.immutableRecordCollision(
                    recordID: record.id
                )
            }
        }
    }
}

struct CurrentSyncRecordMerger {
    private let mapper: SyncRecordMapper
    private let noteEntryMerger: TaskNoteEntryMerger

    init(
        mapper: SyncRecordMapper = SyncRecordMapper(),
        noteEntryMerger: TaskNoteEntryMerger = TaskNoteEntryMerger()
    ) {
        self.mapper = mapper
        self.noteEntryMerger = noteEntryMerger
    }

    func validate(_ record: SyncRecord) throws {
        guard record.entityType == .taskChain
            || record.reactivationWitnesses.isEmpty
        else {
            throw CurrentSyncRecordMergeError.invalidReactivationWitnesses
        }
        guard record.operation == .upsert else { return }
        try validateUpsert(record)
    }

    private func validateUpsert(_ record: SyncRecord) throws {
        switch record.entityType {
        case .day:
            try validateDayRecord(record)
        case .taskCycleSeries:
            try validateTaskCycleSeriesRecord(record)
        case .taskChain:
            try validateTaskChainRecord(record)
        case .taskDefinition:
            try validateTaskDefinitionRecord(record)
        case .dayTrace:
            try validateDayTraceRecord(record)
        case .subtask, .ideaEntry, .appPreferences:
            try validateLeafCurrentRecord(record)
        case .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            return
        }
    }

    private func validateDayRecord(_ record: SyncRecord) throws {
        let day = try mapper.decodeDay(record)
        try validateContentClock(
            createdAt: day.createdAt,
            contentUpdatedAt: day.updatedAt,
            terminalDates: [day.lockedAt]
        )
        try validateRecordMutationClock(
            record,
            canonicalMutationClock: day.updatedAt
        )
    }

    private func validateTaskCycleSeriesRecord(
        _ record: SyncRecord
    ) throws {
        let series = try mapper.decodeTaskCycleSeries(record)
        // Whole-series schedule integrity is checked after the parent and all
        // occurrence records enter one structural component. Rejecting the
        // parent here would strand otherwise related children as waiting.
        try validateRecordMutationClock(
            record,
            canonicalMutationClock: series.updatedAt
        )
    }

    private func validateTaskChainRecord(_ record: SyncRecord) throws {
        let chain = try mapper.decodeTaskChain(record)
        try validateContentClock(
            createdAt: chain.createdAt,
            contentUpdatedAt: chain.updatedAt,
            terminalDates: []
        )
        if let issue = TaskNoteEntryValidator.firstIssue(
            in: chain.noteEntries
        ) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        try validateRecordMutationClock(
            record,
            canonicalMutationClock: chain.noteEntries.reduce(
                chain.updatedAt
            ) { max($0, $1.updatedAt) }
        )
        _ = try reactivationWitnesses(in: record, for: chain)
    }

    private func validateTaskDefinitionRecord(_ record: SyncRecord) throws {
        let definition = try mapper.decodeTaskDefinition(record)
        guard TaskDefinitionValidator.firstSelfContainedIssue(
            in: definition
        ) == nil else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        try validateRecordMutationClock(
            record,
            canonicalMutationClock: definition.contentUpdatedAt
        )
    }

    private func validateDayTraceRecord(_ record: SyncRecord) throws {
        let trace = try mapper.decodeDayTrace(record)
        guard TrajectoryTopologyValidator.firstSelfContainedIssue(
            in: trace
        ) == nil else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        if let issue = TaskNoteEntryValidator.firstIssue(in: trace.noteEntries) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        try validateRecordMutationClock(
            record,
            canonicalMutationClock: trace.noteEntries.reduce(
                trace.contentUpdatedAt
            ) { max($0, $1.updatedAt) }
        )
    }

    private func validateLeafCurrentRecord(_ record: SyncRecord) throws {
        switch record.entityType {
        case .subtask:
            try validateSubtaskRecord(record)
        case .ideaEntry:
            try validateIdeaEntryRecord(record)
        case .appPreferences:
            _ = try mapper.decodeAppPreferences(record)
        case .day, .taskCycleSeries, .taskChain, .taskDefinition, .dayTrace,
             .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            preconditionFailure("unexpected current record validation type")
        }
    }

    private func validateSubtaskRecord(_ record: SyncRecord) throws {
        let subtask = try mapper.decodeSubtask(record)
        try subtask.validateIntegrity()
        guard record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
                == subtask.updatedAt.timeIntervalSinceReferenceDate.bitPattern
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
    }

    private func validateIdeaEntryRecord(_ record: SyncRecord) throws {
        let idea = try mapper.decodeIdeaEntry(record)
        guard IdeaEntryValidator.firstIssue(in: [idea]) == nil,
              record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
                == idea.updatedAt.timeIntervalSinceReferenceDate.bitPattern
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
    }

    func prepareTransportBatch(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord]
    ) throws -> CurrentSyncTransportBatch {
        do {
            let mergeContext = try prepareContext(
                existingRecords: existingRecords,
                incomingRecords: incomingRecords
            )
            let canonical = try canonicalIncomingRecords(
                publishingOrder(incomingRecords),
                existingRecords: existingRecords,
                context: mergeContext
            )
            try preflightCurrentMerges(
                existingRecords: existingRecords,
                incomingRecords: canonical.records,
                context: mergeContext
            )
            return CurrentSyncTransportBatch(
                records: canonical.records,
                mergeContext: mergeContext,
                provenanceGroups: canonical.provenanceGroups
            )
        } catch let error as CurrentSyncRecordBatchError {
            switch error {
            case let .invalidCurrentRecord(recordID, reason):
                throw SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: recordID,
                    reason: reason
                )
            }
        }
    }

    private func canonicalIncomingRecords(
        _ records: [SyncRecord],
        existingRecords: [SyncRecord],
        context: CurrentSyncRecordMergeContext
    ) throws -> (
        records: [SyncRecord],
        provenanceGroups: [SyncRecordProvenanceGroup]
    ) {
        var canonicalRecords: [SyncRecord] = []
        var provenanceGroups: [SyncRecordProvenanceGroup] = []

        for group in SyncRecordEvidenceCanonicalizer.groups(records) {
            let candidates = group.evidence.map(\.record)
            guard let first = candidates.first else { continue }
            let headersAreConsistent = candidates.allSatisfy {
                $0.entityType == first.entityType
                    && $0.entityID == first.entityID
                    && $0.operation == first.operation
            }
            guard headersAreConsistent else {
                throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                    recordID: group.recordID,
                    reason: .inconsistentRecordHeaders
                )
            }

            let hasImmutable = candidates.contains {
                $0.entityType.requiresImmutableRecordPayload
            }
            if hasImmutable, candidates.count > 1 {
                throw SyncRecordTransportError.immutableRecordCollision(
                    recordID: group.recordID
                )
            }

            let canonical: SyncRecord
            let contributingEvidenceIDs: Set<SyncRecordEvidenceID>
            let supersededEvidenceIDs: Set<SyncRecordEvidenceID>
            if candidates.count == 1 {
                canonical = first
                contributingEvidenceIDs = [group.evidence[0].id]
                supersededEvidenceIDs = []
            } else {
                let ordered = group.evidence.sorted {
                    let order = $0.record.currentRecordLWWOrder(
                        comparedTo: $1.record
                    )
                    if order == .equivalent {
                        return $0.id.rawValue < $1.id.rawValue
                    }
                    return order == .before
                }
                do {
                    // Validate every source pair before folding. Otherwise a later
                    // record can hide two contradictory facts at the same semantic
                    // version and make acceptance depend on caller order.
                    for leftIndex in ordered.indices {
                        for rightIndex in ordered.indices where rightIndex > leftIndex {
                            _ = try merge(
                                existing: ordered[leftIndex].record,
                                incoming: ordered[rightIndex].record,
                                context: context
                            )
                        }
                    }
                    canonical = try foldCurrentEvidence(
                        ordered,
                        context: context
                    )
                    let provenance = try minimalLiveProvenance(
                        ordered,
                        canonical: canonical,
                        allIncomingRecords: records,
                        existingRecords: existingRecords
                    )
                    contributingEvidenceIDs = provenance.contributing
                    supersededEvidenceIDs = provenance.superseded
                } catch {
                    throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                        recordID: group.recordID,
                        reason: SyncRecordMergeFailureReason(underlying: error)
                    )
                }
            }

            canonicalRecords.append(canonical)
            provenanceGroups.append(
                SyncRecordProvenanceGroup(
                    canonicalRecord: canonical,
                    contributingEvidenceIDs: Array(contributingEvidenceIDs),
                    supersededEvidenceIDs: Array(supersededEvidenceIDs)
                )
            )
        }

        return (canonicalRecords, provenanceGroups)
    }

    private func foldCurrentEvidence(
        _ evidence: [SyncRecordEvidence],
        context: CurrentSyncRecordMergeContext
    ) throws -> SyncRecord {
        guard var folded = evidence.first?.record else {
            preconditionFailure("current evidence fold requires one record")
        }
        for incoming in evidence.dropFirst() {
            folded = try merge(
                existing: folded,
                incoming: incoming.record,
                context: context
            )
        }
        return folded
    }

    private func minimalLiveProvenance(
        _ evidence: [SyncRecordEvidence],
        canonical: SyncRecord,
        allIncomingRecords: [SyncRecord],
        existingRecords: [SyncRecord]
    ) throws -> (
        contributing: Set<SyncRecordEvidenceID>,
        superseded: Set<SyncRecordEvidenceID>
    ) {
        var live = evidence
        var superseded: Set<SyncRecordEvidenceID> = []
        let groupEvidenceIDs = Set(evidence.map(\.id))
        // Greedy removal is deterministic and performs at most n(n - 1) / 2
        // merge operations after the pairwise preflight above. Rebuilding the
        // context from the retained exact facts prevents a removed witness from
        // authorizing the very fold used to declare that witness superseded.
        for candidate in evidence.reversed() {
            guard live.count > 1,
                  let index = live.firstIndex(where: { $0.id == candidate.id })
            else { continue }
            var withoutCandidate = live
            withoutCandidate.remove(at: index)
            let retainedEvidenceIDs = Set(withoutCandidate.map(\.id))
            let reducedIncomingRecords = allIncomingRecords.filter { record in
                let evidenceID = SyncRecordEvidenceID(record: record)
                return groupEvidenceIDs.contains(evidenceID) == false
                    || retainedEvidenceIDs.contains(evidenceID)
            }
            do {
                let reducedContext = try prepareContext(
                    existingRecords: existingRecords,
                    incomingRecords: reducedIncomingRecords
                )
                let folded = try foldCurrentEvidence(
                    withoutCandidate,
                    context: reducedContext
                )
                if folded.exactlyMatches(canonical) {
                    live = withoutCandidate
                    superseded.insert(candidate.id)
                }
            } catch {
                // A subset which cannot reproduce a legal fold proves that the
                // removed exact source is live provenance; the full-set batch
                // was already validated above and must remain publishable.
                continue
            }
        }
        return (Set(live.map(\.id)), superseded)
    }

    private func preflightCurrentMerges(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord],
        context: CurrentSyncRecordMergeContext
    ) throws {
        var staged: [SyncRecordID: SyncRecord] = [:]
        for record in existingRecords {
            staged[record.id] = record
        }

        for record in incomingRecords {
            guard let existing = staged[record.id] else {
                staged[record.id] = record
                continue
            }
            let requiresImmutableCAS = existing.entityType.requiresImmutableRecordPayload
                || record.entityType.requiresImmutableRecordPayload
            guard requiresImmutableCAS == false else { continue }
            do {
                staged[record.id] = try merge(
                    existing: existing,
                    incoming: record,
                    context: context
                )
            } catch {
                throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                    recordID: record.id,
                    reason: SyncRecordMergeFailureReason(underlying: error)
                )
            }
        }
    }

    private func prepareContext(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord]
    ) throws -> CurrentSyncRecordMergeContext {
        for record in existingRecords {
            try validateBatchRecord(record)
        }
        for record in incomingRecords {
            try validateBatchRecord(record)
        }

        let reactivationAuthorizations = reactivationAuthorizations(
            existingRecords: existingRecords,
            incomingRecords: incomingRecords
        )
        let authorizationContext = CurrentSyncRecordMergeContext(
            authorizedReactivationChainIDs: reactivationAuthorizations.chainIDs,
            authorizedTraceReactivations: reactivationAuthorizations.tracePairs
        )

        var canonicalRecords: [SyncRecordID: SyncRecord] = [:]
        for record in existingRecords where record.isMergeAuthorizationContext {
            try mergeAuthorizationRecord(
                record,
                into: &canonicalRecords,
                context: authorizationContext
            )
        }
        for record in incomingRecords where record.isMergeAuthorizationContext {
            try mergeAuthorizationRecord(
                record,
                into: &canonicalRecords,
                context: authorizationContext
            )
        }

        return try mergeContext(
            from: Array(canonicalRecords.values),
            reactivationAuthorizations: reactivationAuthorizations
        )
    }

    func reactivationAuthorizations(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord]
    ) -> CurrentSyncReactivationAuthorizations {
        let existing = reactivationEvidence(from: existingRecords)
        let incoming = reactivationEvidence(from: incomingRecords)
        let allChains = existing.chains + incoming.chains
        let allTraces = existing.traces + incoming.traces
        let allWitnesses = existing.witnesses + incoming.witnesses

        var authorizations = CurrentSyncReactivationAuthorizations()
        for witness in allWitnesses {
            guard allChains.contains(witness.abandonedChain) else {
                continue
            }
            for chain in allChains {
                let authorizesChainOnly =
                    witness.abandonedTrace == nil
                        && witness.authorizesRestoredSuccessor(
                            chain: chain,
                            trace: nil
                        )
                if authorizesChainOnly {
                    authorizations.chainIDs.insert(witness.restoredChain.id)
                    continue
                }
                guard let abandonedTrace = witness.abandonedTrace,
                      allTraces.contains(abandonedTrace)
                else {
                    continue
                }
                for trace in allTraces
                where witness.authorizesRestoredSuccessor(
                    chain: chain,
                    trace: trace
                ) {
                    authorizations.chainIDs.insert(
                        witness.restoredChain.id
                    )
                    let traceAuthorization =
                        TraceReactivationAuthorization(
                            abandoned: abandonedTrace,
                            restoredSuccessor: trace
                        )
                    if authorizations.tracePairs.contains(
                        traceAuthorization
                    ) == false {
                        authorizations.tracePairs.append(
                            traceAuthorization
                        )
                    }
                }
            }
        }
        return authorizations
    }

    private func reactivationEvidence(
        from records: [SyncRecord]
    ) -> CurrentSyncReactivationEvidence {
        var evidence = CurrentSyncReactivationEvidence()
        for record in records where record.operation == .upsert {
            do {
                try validate(record)
                switch record.entityType {
                case .taskChain:
                    let chain = try mapper.decodeTaskChain(record)
                    evidence.chains.append(chain)
                    evidence.witnesses.append(contentsOf: try reactivationWitnesses(
                        in: record,
                        for: chain
                    ))
                case .dayTrace:
                    evidence.traces.append(try mapper.decodeDayTrace(record))
                case .day, .taskCycleSeries, .taskDefinition, .subtask, .ideaEntry,
                     .appPreferences,
                     .classificationBaseline, .classificationCommit,
                     .traceClassificationEvent:
                    break
                }
            } catch {
                continue
            }
        }
        return evidence
    }

    private func validateBatchRecord(_ record: SyncRecord) throws {
        do {
            try validate(record)
        } catch {
            throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                recordID: record.id,
                reason: SyncRecordMergeFailureReason(underlying: error)
            )
        }
    }

    private func mergeAuthorizationRecord(
        _ record: SyncRecord,
        into canonicalRecords: inout [SyncRecordID: SyncRecord],
        context: CurrentSyncRecordMergeContext
    ) throws {
        do {
            try validate(record)
            guard let existing = canonicalRecords[record.id] else {
                canonicalRecords[record.id] = record
                return
            }
            canonicalRecords[record.id] = try merge(
                existing: existing,
                incoming: record,
                context: context
            )
        } catch {
            throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                recordID: record.id,
                reason: SyncRecordMergeFailureReason(underlying: error)
            )
        }
    }

    private func mergeContext(
        from canonicalRecords: [SyncRecord],
        reactivationAuthorizations: CurrentSyncReactivationAuthorizations
    ) throws -> CurrentSyncRecordMergeContext {
        var context = CurrentSyncRecordMergeContext(
            authorizedReactivationChainIDs: reactivationAuthorizations.chainIDs,
            authorizedTraceReactivations: reactivationAuthorizations.tracePairs
        )
        for record in canonicalRecords where record.operation == .upsert {
            do {
                switch record.entityType {
                case .day:
                    let day = try mapper.decodeDay(record)
                    context.daysByDate[day.date] = day
                case .taskChain:
                    let chain = try mapper.decodeTaskChain(record)
                    context.chainsByID[chain.id] = chain
                case .taskCycleSeries, .taskDefinition, .dayTrace, .subtask, .ideaEntry,
                     .appPreferences,
                     .classificationBaseline, .classificationCommit,
                     .traceClassificationEvent:
                    break
                }
            } catch {
                throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                    recordID: record.id,
                    reason: SyncRecordMergeFailureReason(underlying: error)
                )
            }
        }
        return context
    }

    private func publishingOrder(_ records: [SyncRecord]) -> [SyncRecord] {
        records.filter(\.isMergeAuthorizationContext)
            + records.filter { $0.isMergeAuthorizationContext == false }
    }

    func merge(
        existing: SyncRecord,
        incoming: SyncRecord,
        context: CurrentSyncRecordMergeContext = .empty
    ) throws -> SyncRecord {
        precondition(existing.id == incoming.id, "current records must have the same identity")

        guard existing.entityType == incoming.entityType,
              existing.operation == .upsert,
              incoming.operation == .upsert
        else {
            return lwwWinner(existing, incoming)
        }

        switch existing.entityType {
        case .day:
            return try mergeDay(existing: existing, incoming: incoming)
        case .taskCycleSeries:
            return try mergeTaskCycleSeries(
                existing: existing,
                incoming: incoming
            )
        case .taskChain:
            return try mergeTaskChain(
                existing: existing,
                incoming: incoming,
                context: context
            )
        case .taskDefinition:
            return try mergeTaskDefinition(existing: existing, incoming: incoming)
        case .dayTrace:
            return try mergeTrace(
                existing: existing,
                incoming: incoming,
                context: context
            )
        case .subtask:
            return try mergeSubtask(
                existing: existing,
                incoming: incoming
            )
        case .ideaEntry:
            return try mergeIdeaEntry(
                existing: existing,
                incoming: incoming
            )
        case .appPreferences:
            return try mergeAppPreferences(
                existing: existing,
                incoming: incoming
            )
        case .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            return lwwWinner(existing, incoming)
        }
    }

    private func mergeTaskCycleSeries(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingSeries = try mapper.decodeTaskCycleSeries(existing)
        let incomingSeries = try mapper.decodeTaskCycleSeries(incoming)
        guard existingSeries.id == incomingSeries.id,
              existingSeries.startDate == incomingSeries.startDate,
              existingSeries.createdAt.timeIntervalSinceReferenceDate.bitPattern
              == incomingSeries.createdAt.timeIntervalSinceReferenceDate.bitPattern
        else {
            throw CurrentSyncRecordMergeError
                .taskCycleSeriesIdentityCollision
        }
        let sameVersion =
            existingSeries.updatedAt.timeIntervalSinceReferenceDate.bitPattern
                == incomingSeries.updatedAt
                .timeIntervalSinceReferenceDate.bitPattern
        if sameVersion {
            guard existingSeries.title == incomingSeries.title,
                  existingSeries.descriptionText
                  == incomingSeries.descriptionText,
                  existingSeries.plannedSubtasks
                  == incomingSeries.plannedSubtasks,
                  existingSeries.endDate == incomingSeries.endDate,
                  existingSeries.schedule == incomingSeries.schedule,
                  existingSeries.endCondition
                  == incomingSeries.endCondition
            else {
                throw CurrentSyncRecordMergeError.invalidContentClock
            }
        }
        var revisionsByID = Dictionary(
            uniqueKeysWithValues: existingSeries.planRevisions.map {
                ($0.id, $0)
            }
        )
        for revision in incomingSeries.planRevisions {
            if let existingRevision = revisionsByID[revision.id],
               existingRevision != revision
            {
                throw CurrentSyncRecordMergeError
                    .taskCycleSeriesIdentityCollision
            }
            revisionsByID[revision.id] = revision
        }
        let mergedRevisions = revisionsByID.values.sorted {
            if $0.recordedAt != $1.recordedAt {
                return $0.recordedAt < $1.recordedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard let latestRevision = mergedRevisions.last else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        var classificationRevisionsByID = Dictionary(
            uniqueKeysWithValues:
            existingSeries.classificationRevisions.map {
                ($0.id, $0)
            }
        )
        for revision in incomingSeries.classificationRevisions {
            if let existingRevision =
                classificationRevisionsByID[revision.id],
               existingRevision != revision
            {
                throw CurrentSyncRecordMergeError
                    .taskCycleSeriesIdentityCollision
            }
            classificationRevisionsByID[revision.id] = revision
        }
        let mergedClassificationRevisions =
            classificationRevisionsByID.values.sorted {
                if $0.recordedAt != $1.recordedAt {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard let currentClassificationRevision =
            TaskCycleSeries.resolveCurrentClassificationRevision(
                in: mergedClassificationRevisions
            )
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        var factsByID = Dictionary(
            uniqueKeysWithValues: existingSeries.cancellationFacts.map {
                ($0.id, $0)
            }
        )
        for fact in incomingSeries.cancellationFacts {
            if let existingFact = factsByID[fact.id],
               existingFact != fact
            {
                throw CurrentSyncRecordMergeError
                    .taskCycleSeriesIdentityCollision
            }
            factsByID[fact.id] = fact
        }
        let winner = lwwWinner(existing, incoming)
        let winnerSeries = try mapper.decodeTaskCycleSeries(winner)
        let mergedSeries = TaskCycleSeries(
            id: winnerSeries.id,
            title: winnerSeries.title,
            descriptionText: winnerSeries.descriptionText,
            plannedSubtasks: winnerSeries.plannedSubtasks,
            categoryID: currentClassificationRevision.categoryID,
            labelIDs: currentClassificationRevision.labelIDs,
            startDate: winnerSeries.startDate,
            endDate: try latestRevision.endCondition.resolvedEndDate(
                from: winnerSeries.startDate
            ),
            schedule: latestRevision.schedule,
            endCondition: latestRevision.endCondition,
            planRevisions: mergedRevisions,
            classificationRevisions: mergedClassificationRevisions,
            cancellationFacts: factsByID.values.sorted {
                if $0.recordedAt != $1.recordedAt {
                    return $0.recordedAt < $1.recordedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            },
            createdAt: winnerSeries.createdAt,
            updatedAt: max(
                existingSeries.updatedAt,
                incomingSeries.updatedAt
            )
        )
        return try mapper.record(
            for: mergedSeries,
            modifiedBy: winner.modifiedByDeviceID
        )
    }

    private func mergeAppPreferences(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingEnvelope = try mapper.decodeAppPreferences(existing)
        let incomingEnvelope = try mapper.decodeAppPreferences(incoming)
        let sameVersion =
            existingEnvelope.updatedAt.timeIntervalSinceReferenceDate
            .bitPattern
                == incomingEnvelope.updatedAt
                .timeIntervalSinceReferenceDate.bitPattern
                && existingEnvelope.writerDeviceID
                == incomingEnvelope.writerDeviceID
        if sameVersion {
            guard existingEnvelope.theme == incomingEnvelope.theme,
                  existingEnvelope.language == incomingEnvelope.language
            else {
                throw CurrentSyncRecordMergeError.invalidContentClock
            }
        }
        return lwwWinner(existing, incoming)
    }

    private func mergeDay(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingDay = try mapper.decodeDay(existing)
        let incomingDay = try mapper.decodeDay(incoming)
        try validateContentClock(
            createdAt: existingDay.createdAt,
            contentUpdatedAt: existingDay.updatedAt,
            terminalDates: [existingDay.lockedAt]
        )
        try validateContentClock(
            createdAt: incomingDay.createdAt,
            contentUpdatedAt: incomingDay.updatedAt,
            terminalDates: [incomingDay.lockedAt]
        )

        let winnerRecord = lwwWinner(existing, incoming)
        var mergedDay = winnerRecord.exactlyMatches(incoming)
            ? incomingDay
            : existingDay
        let identityDay = canonicalDayIdentity(existingDay, incomingDay)
        mergedDay.id = identityDay.id
        mergedDay.createdAt = identityDay.createdAt
        mergedDay.lockedAt = [existingDay.lockedAt, incomingDay.lockedAt]
            .compactMap { $0 }
            .min()
        mergedDay.updatedAt = max(existingDay.updatedAt, incomingDay.updatedAt)

        try validateContentClock(
            createdAt: mergedDay.createdAt,
            contentUpdatedAt: mergedDay.updatedAt,
            terminalDates: [mergedDay.lockedAt]
        )
        return try mapper.record(
            for: mergedDay,
            modifiedBy: winnerRecord.modifiedByDeviceID
        )
    }

    private func mergeTaskChain(
        existing: SyncRecord,
        incoming: SyncRecord,
        context: CurrentSyncRecordMergeContext
    ) throws -> SyncRecord {
        let existingChain = try mapper.decodeTaskChain(existing)
        let incomingChain = try mapper.decodeTaskChain(incoming)
        guard existingChain.createdAt == incomingChain.createdAt else {
            throw CurrentSyncRecordMergeError.taskChainIdentityCollision
        }
        let cycleMembership = try mergedCycleMembership(
            existingChain.cycleMembership,
            incomingChain.cycleMembership
        )
        try validateContentClock(
            createdAt: existingChain.createdAt,
            contentUpdatedAt: existingChain.updatedAt,
            terminalDates: []
        )
        try validateContentClock(
            createdAt: incomingChain.createdAt,
            contentUpdatedAt: incomingChain.updatedAt,
            terminalDates: []
        )
        if let issue = TaskNoteEntryValidator.firstIssue(
            in: existingChain.noteEntries
        ) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        if let issue = TaskNoteEntryValidator.firstIssue(
            in: incomingChain.noteEntries
        ) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        let noteEntries = try noteEntryMerger.merge(
            existingChain.noteEntries,
            incomingChain.noteEntries
        )
        let winner = try taskChainStateWinner(
            existing: (existing, existingChain),
            incoming: (incoming, incomingChain),
            context: context
        )
        var mergedChain = winner.chain
        mergedChain.noteEntries = noteEntries
        mergedChain.cycleMembership = cycleMembership
        let witnesses = try reactivationWitnesses(
            in: existing,
            for: existingChain
        ) + reactivationWitnesses(
            in: incoming,
            for: incomingChain
        )
        return try mapper.record(
            for: mergedChain,
            modifiedBy: winner.record.modifiedByDeviceID,
            reactivationWitnesses: witnesses
        )
    }

    private func mergedCycleMembership(
        _ existing: TaskCycleMembership?,
        _ incoming: TaskCycleMembership?
    ) throws -> TaskCycleMembership? {
        switch (existing, incoming) {
        case (nil, nil):
            nil
        case let (membership?, nil), let (nil, membership?):
            membership
        case let (existing?, incoming?)
            where existing == incoming:
            existing
        case (.some, .some):
            throw CurrentSyncRecordMergeError
                .taskChainIdentityCollision
        }
    }

    private func mergeTaskDefinition(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingDefinition = try mapper.decodeTaskDefinition(existing)
        let incomingDefinition = try mapper.decodeTaskDefinition(incoming)
        guard existingDefinition.chainID == incomingDefinition.chainID,
              existingDefinition.sequence == incomingDefinition.sequence,
              existingDefinition.createdAt == incomingDefinition.createdAt
        else {
            throw CurrentSyncRecordMergeError.taskDefinitionIdentityCollision
        }
        try validateContentClock(
            createdAt: existingDefinition.createdAt,
            contentUpdatedAt: existingDefinition.contentUpdatedAt,
            terminalDates: [existingDefinition.supersededAt]
        )
        try validateContentClock(
            createdAt: incomingDefinition.createdAt,
            contentUpdatedAt: incomingDefinition.contentUpdatedAt,
            terminalDates: [incomingDefinition.supersededAt]
        )
        let winner = try taskDefinitionBaseWinner(
            existing: (existing, existingDefinition),
            incoming: (incoming, incomingDefinition)
        )
        return try mergedRecord(
            definition: winner.definition,
            baseWinner: winner.record
        )
    }

    private func mergeTrace(
        existing: SyncRecord,
        incoming: SyncRecord,
        context: CurrentSyncRecordMergeContext
    ) throws -> SyncRecord {
        let existingTrace = try mapper.decodeDayTrace(existing)
        let incomingTrace = try mapper.decodeDayTrace(incoming)
        guard existingTrace.chainID == incomingTrace.chainID,
              existingTrace.createdAt == incomingTrace.createdAt,
              existingTrace.continuationSeq == incomingTrace.continuationSeq,
              existingTrace.carriedFromTraceID == incomingTrace.carriedFromTraceID
        else {
            throw CurrentSyncRecordMergeError.dayTraceIdentityCollision
        }
        guard TrajectoryTopologyValidator.firstSelfContainedIssue(
            in: existingTrace
        ) == nil,
              TrajectoryTopologyValidator.firstSelfContainedIssue(
                  in: incomingTrace
              ) == nil
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        if let issue = TaskNoteEntryValidator.firstIssue(in: existingTrace.noteEntries) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        if let issue = TaskNoteEntryValidator.firstIssue(in: incomingTrace.noteEntries) {
            throw TaskNoteEntryMergeError.invalidEntries(issue)
        }
        let baseWinner = try traceBaseWinner(
            existing: (existing, existingTrace),
            incoming: (incoming, incomingTrace)
        )
        let winner = terminalAwareTraceWinner(
            existing: (existing, existingTrace),
            incoming: (incoming, incomingTrace),
            baseWinner: baseWinner,
            context: context
        )
        let existingIsPending = existingTrace.status == .pending
            && existingTrace.settledAt == nil
        let incomingIsPending = incomingTrace.status == .pending
            && incomingTrace.settledAt == nil
        guard existingIsPending || incomingIsPending else {
            return try mergedRecord(
                trace: winner.trace,
                baseWinner: winner.record
            )
        }

        let noteEntries = try noteEntryMerger.merge(
            existingTrace.noteEntries,
            incomingTrace.noteEntries
        )
        var mergedTrace = winner.trace
        mergedTrace.noteEntries = noteEntries
        return try mergedRecord(trace: mergedTrace, baseWinner: winner.record)
    }

    private func mergeSubtask(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingSubtask = try mapper.decodeSubtask(existing)
        let incomingSubtask = try mapper.decodeSubtask(incoming)
        try existingSubtask.validateIntegrity()
        try incomingSubtask.validateIntegrity()
        // Only lineage and creation are immutable identity. Title, position,
        // trace membership and carry provenance are legitimate content:
        // updateSubtaskTitle renames, withdrawDeferral rewrites trace
        // membership and position, and recurring template propagation rewrites
        // titles — all through ordinary domain operations that advance the
        // mutation clock. Treating them as identity rejects the next upload
        // against the previously synced version and poisons the queue
        // (FAIL-2026-08-06-18A651A2).
        guard existingSubtask.lineageID == incomingSubtask.lineageID,
              existingSubtask.createdAt == incomingSubtask.createdAt
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }

        if isSanctionedCancelledSubtaskUndo(
            from: existingSubtask,
            to: incomingSubtask
        ) {
            return incoming
        }
        if isSanctionedCancelledSubtaskUndo(
            from: incomingSubtask,
            to: existingSubtask
        ) {
            return existing
        }
        let hasCancellationFact =
            existingSubtask.status == .cancelledDraft
                || incomingSubtask.status == .cancelledDraft
        if hasCancellationFact {
            return existingSubtask.status == .cancelledDraft
                ? existing
                : incoming
        }
        return lwwWinner(existing, incoming)
    }

    private func mergeIdeaEntry(
        existing: SyncRecord,
        incoming: SyncRecord
    ) throws -> SyncRecord {
        let existingIdea = try mapper.decodeIdeaEntry(existing)
        let incomingIdea = try mapper.decodeIdeaEntry(incoming)
        guard IdeaEntryValidator.firstIssue(in: [existingIdea]) == nil,
              IdeaEntryValidator.firstIssue(in: [incomingIdea]) == nil,
              existingIdea.createdAt == incomingIdea.createdAt
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
        return lwwWinner(existing, incoming)
    }

    private func isSanctionedCancelledSubtaskUndo(
        from cancelled: Subtask,
        to restored: Subtask
    ) -> Bool {
        cancelled.status == .cancelledDraft
            && cancelled.draftCancellationID != nil
            && cancelled.completedAt == nil
            && cancelled.settledAt != nil
            && restored.status == .pending
            && restored.draftCancellationID
            == cancelled.draftCancellationID
            && restored.completedAt == nil
            && restored.settledAt == nil
            && restored.updatedAt > cancelled.updatedAt
            && restored.id == cancelled.id
            && restored.lineageID == cancelled.lineageID
            && restored.traceID == cancelled.traceID
            && restored.title == cancelled.title
            && restored.difficulty == cancelled.difficulty
            && restored.position == cancelled.position
            && restored.carriedFromSubtaskID
            == cancelled.carriedFromSubtaskID
            && restored.createdAt == cancelled.createdAt
    }

    private func terminalAwareTraceWinner(
        existing: (record: SyncRecord, trace: DayTrace),
        incoming: (record: SyncRecord, trace: DayTrace),
        baseWinner: (record: SyncRecord, trace: DayTrace),
        context: CurrentSyncRecordMergeContext
    ) -> (record: SyncRecord, trace: DayTrace) {
        if isSanctionedHistoricalInverse(
            from: existing.trace,
            to: incoming.trace,
            context: context
        ) {
            return incoming
        }
        if isSanctionedHistoricalInverse(
            from: incoming.trace,
            to: existing.trace,
            context: context
        ) {
            return existing
        }
        let existingIsHistorical = existing.trace.status != .pending
            || existing.trace.settledAt != nil
        let incomingIsHistorical = incoming.trace.status != .pending
            || incoming.trace.settledAt != nil
        if existingIsHistorical != incomingIsHistorical {
            return existingIsHistorical ? existing : incoming
        }
        return baseWinner
    }

    private func isSanctionedHistoricalInverse(
        from historical: DayTrace,
        to restored: DayTrace,
        context: CurrentSyncRecordMergeContext
    ) -> Bool {
        guard restored.contentUpdatedAt > historical.contentUpdatedAt else {
            return false
        }
        let isCompletionUndo = historical.status == .completed
            && historical.completedAt != nil
            && restored.status == .pending
            && restored.completedAt == nil
            && restored.settledAt == historical.settledAt
        if isCompletionUndo {
            guard let day = context.daysByDate[historical.date],
                  day.lockedAt == nil
            else {
                return false
            }
            return traceFieldsMatch(
                historical,
                restored,
                exceptions: .completionUndo
            )
        }
        let isCancelledDraftUndo = historical.status == .cancelledDraft
            && historical.draftCancellationID != nil
            && historical.draftCancelledOn != nil
            && historical.completedAt == nil
            && historical.settledAt != nil
            && restored.status == .pending
            && restored.draftCancellationID == historical.draftCancellationID
            && restored.draftCancelledOn == nil
            && restored.completedAt == nil
            && restored.settledAt == nil
        if isCancelledDraftUndo {
            guard let day = context.daysByDate[historical.date],
                  day.lockedAt == nil
            else {
                return false
            }
            return traceFieldsMatch(
                historical,
                restored,
                exceptions: .cancelledDraftUndo
            )
        }
        if historical.status == .abandoned {
            guard context.chainsByID[historical.chainID]?.state == .active else {
                return false
            }
            return context.authorizedTraceReactivations.contains {
                $0.abandoned == historical
                    && $0.restoredSuccessor == restored
            }
        }
        return false
    }

    private func traceFieldsMatch(
        _ lhs: DayTrace,
        _ rhs: DayTrace,
        exceptions: TraceFieldMatchExceptions
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.definitionID == rhs.definitionID
            && lhs.date == rhs.date
            && (exceptions.status || lhs.status == rhs.status)
            && lhs.priority == rhs.priority
            && lhs.continuationSeq == rhs.continuationSeq
            && lhs.descriptionText == rhs.descriptionText
            && lhs.noteEntries == rhs.noteEntries
            && lhs.manualProgressPercent == rhs.manualProgressPercent
            && lhs.carriedFromTraceID == rhs.carriedFromTraceID
            && lhs.changedToTraceID == rhs.changedToTraceID
            && lhs.createdAt == rhs.createdAt
            && (exceptions.completedAt || lhs.completedAt == rhs.completedAt)
            && (exceptions.settledAt || lhs.settledAt == rhs.settledAt)
            && lhs.draftCancellationID == rhs.draftCancellationID
            && (
                exceptions.draftCancelledOn
                    || lhs.draftCancelledOn == rhs.draftCancelledOn
            )
    }

    private func taskDefinitionBaseWinner(
        existing: (record: SyncRecord, definition: TaskDefinition),
        incoming: (record: SyncRecord, definition: TaskDefinition)
    ) throws -> (record: SyncRecord, definition: TaskDefinition) {
        let existingProjection = try taskDefinitionBaseProjection(existing)
        let incomingProjection = try taskDefinitionBaseProjection(incoming)
        return baseProjectionOrder(incomingProjection, existingProjection) == .after
            ? incoming
            : existing
    }

    private func canonicalDayIdentity(_ lhs: Day, _ rhs: Day) -> Day {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt ? lhs : rhs
        }
        return lhs.id.description < rhs.id.description ? lhs : rhs
    }

    private func taskChainBaseWinner(
        existing: (record: SyncRecord, chain: TaskChain),
        incoming: (record: SyncRecord, chain: TaskChain)
    ) throws -> (record: SyncRecord, chain: TaskChain) {
        let existingProjection = try taskChainBaseProjection(existing)
        let incomingProjection = try taskChainBaseProjection(incoming)
        return baseProjectionOrder(incomingProjection, existingProjection) == .after
            ? incoming
            : existing
    }

    private func taskChainStateWinner(
        existing: (record: SyncRecord, chain: TaskChain),
        incoming: (record: SyncRecord, chain: TaskChain),
        context: CurrentSyncRecordMergeContext
    ) throws -> (record: SyncRecord, chain: TaskChain) {
        guard existing.chain.state != incoming.chain.state else {
            return try taskChainBaseWinner(
                existing: existing,
                incoming: incoming
            )
        }

        let active = existing.chain.state == .active ? existing : incoming
        let abandoned = existing.chain.state == .abandoned ? existing : incoming
        return context.authorizedReactivationChainIDs.contains(active.chain.id)
            ? active
            : abandoned
    }

    private func traceBaseWinner(
        existing: (record: SyncRecord, trace: DayTrace),
        incoming: (record: SyncRecord, trace: DayTrace)
    ) throws -> (record: SyncRecord, trace: DayTrace) {
        let existingProjection = try traceBaseProjection(existing)
        let incomingProjection = try traceBaseProjection(incoming)
        return baseProjectionOrder(incomingProjection, existingProjection) == .after
            ? incoming
            : existing
    }

    private func taskDefinitionBaseProjection(
        _ value: (record: SyncRecord, definition: TaskDefinition)
    ) throws -> SyncRecord {
        return try mapper.record(
            for: value.definition,
            modifiedBy: value.record.modifiedByDeviceID
        )
    }

    private func taskChainBaseProjection(
        _ value: (record: SyncRecord, chain: TaskChain)
    ) throws -> SyncRecord {
        var chain = value.chain
        chain.noteEntries = []
        return try mapper.record(
            for: chain,
            modifiedBy: value.record.modifiedByDeviceID
        )
    }

    private func traceBaseProjection(
        _ value: (record: SyncRecord, trace: DayTrace)
    ) throws -> SyncRecord {
        var trace = value.trace
        trace.noteEntries = []
        return try mapper.record(
            for: trace,
            modifiedBy: value.record.modifiedByDeviceID
        )
    }

    private func mergedRecord(
        definition: TaskDefinition,
        baseWinner: SyncRecord
    ) throws -> SyncRecord {
        try mapper.record(
            for: definition,
            modifiedBy: baseWinner.modifiedByDeviceID
        )
    }

    private func mergedRecord(
        trace: DayTrace,
        baseWinner: SyncRecord
    ) throws -> SyncRecord {
        try mapper.record(
            for: trace,
            modifiedBy: baseWinner.modifiedByDeviceID
        )
    }

    private func baseProjectionOrder(
        _ lhs: SyncRecord,
        _ rhs: SyncRecord
    ) -> SyncRecordLWWOrder {
        let lhsSeconds = lhs.modifiedAt.timeIntervalSinceReferenceDate
        let rhsSeconds = rhs.modifiedAt.timeIntervalSinceReferenceDate
        if lhsSeconds < rhsSeconds { return .before }
        if lhsSeconds > rhsSeconds { return .after }
        if lhsSeconds.bitPattern < rhsSeconds.bitPattern { return .before }
        if lhsSeconds.bitPattern > rhsSeconds.bitPattern { return .after }
        if lhs.payload != rhs.payload {
            return lhs.payload.lexicographicallyPrecedes(rhs.payload) ? .before : .after
        }
        let lhsDevice = Data(lhs.modifiedByDeviceID.rawValue.utf8)
        let rhsDevice = Data(rhs.modifiedByDeviceID.rawValue.utf8)
        if lhsDevice != rhsDevice {
            return lhsDevice.lexicographicallyPrecedes(rhsDevice) ? .before : .after
        }
        return .equivalent
    }

    private func validateContentClock(
        createdAt: Date,
        contentUpdatedAt: Date,
        terminalDates: [Date?]
    ) throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              contentUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
              contentUpdatedAt >= createdAt,
              terminalDates.compactMap({ $0 }).allSatisfy({ terminalDate in
                  terminalDate.timeIntervalSinceReferenceDate.isFinite
                      && terminalDate >= createdAt
                      && terminalDate <= contentUpdatedAt
              })
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
    }

    private func validateRecordMutationClock(
        _ record: SyncRecord,
        canonicalMutationClock: Date
    ) throws {
        guard record.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              canonicalMutationClock.timeIntervalSinceReferenceDate.isFinite,
              record.modifiedAt.timeIntervalSinceReferenceDate.bitPattern
              == canonicalMutationClock.timeIntervalSinceReferenceDate.bitPattern
        else {
            throw CurrentSyncRecordMergeError.invalidContentClock
        }
    }

    private func reactivationWitnesses(
        in record: SyncRecord,
        for chain: TaskChain
    ) throws -> [ChainReactivationEnvelope] {
        guard record.entityType == .taskChain else { return [] }
        return try record.reactivationWitnesses.map { data in
            let witness: ChainReactivationEnvelope
            do {
                witness = try ChainReactivationEnvelope.decode(data)
            } catch {
                throw CurrentSyncRecordMergeError.invalidReactivationWitnesses
            }
            guard witness.restoredChain.id == chain.id,
                  witness.restoredChain.createdAt == chain.createdAt,
                  chain.updatedAt >= witness.restoredChain.updatedAt
            else {
                throw CurrentSyncRecordMergeError.invalidReactivationWitnesses
            }
            return witness
        }
    }

    private func lwwWinner(
        _ lhs: SyncRecord,
        _ rhs: SyncRecord
    ) -> SyncRecord {
        rhs.currentRecordLWWOrder(comparedTo: lhs) == .after ? rhs : lhs
    }
}

private struct TraceFieldMatchExceptions {
    static let completionUndo = TraceFieldMatchExceptions(
        status: true,
        completedAt: true
    )
    static let cancelledDraftUndo = TraceFieldMatchExceptions(
        status: true,
        settledAt: true,
        draftCancelledOn: true
    )

    var status = false
    var completedAt = false
    var settledAt = false
    var draftCancelledOn = false
}

private extension SyncRecord {
    var isMergeAuthorizationContext: Bool {
        entityType == .day || entityType == .taskChain
    }
}

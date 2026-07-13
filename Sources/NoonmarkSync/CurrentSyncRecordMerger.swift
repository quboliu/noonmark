import Foundation
import NoonmarkCore

enum CurrentSyncRecordMergeError: Error, Equatable {
    case taskChainIdentityCollision
    case taskDefinitionIdentityCollision
    case dayTraceIdentityCollision
    case invalidContentClock
}

enum CurrentSyncRecordBatchError: Error, Equatable {
    case invalidCurrentRecord(recordID: SyncRecordID)
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
        guard record.operation == .upsert else { return }
        switch record.entityType {
        case .day:
            let day = try mapper.decodeDay(record)
            try validateContentClock(
                createdAt: day.createdAt,
                contentUpdatedAt: day.updatedAt,
                terminalDates: [day.lockedAt]
            )
        case .taskChain:
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
            _ = try reactivationWitnesses(in: record, for: chain)
        case .taskDefinition:
            let definition = try mapper.decodeTaskDefinition(record)
            try validateContentClock(
                createdAt: definition.createdAt,
                contentUpdatedAt: definition.contentUpdatedAt,
                terminalDates: [definition.supersededAt]
            )
        case .dayTrace:
            let trace = try mapper.decodeDayTrace(record)
            try validateContentClock(
                createdAt: trace.createdAt,
                contentUpdatedAt: trace.contentUpdatedAt,
                terminalDates: [trace.completedAt, trace.settledAt]
            )
            if let issue = TaskNoteEntryValidator.firstIssue(in: trace.noteEntries) {
                throw TaskNoteEntryMergeError.invalidEntries(issue)
            }
        case .subtask, .appPreferences,
             .classificationCommit, .traceClassificationEvent:
            return
        }
    }

    func prepareTransportBatch(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord]
    ) throws -> CurrentSyncTransportBatch {
        do {
            let records = publishingOrder(incomingRecords)
            let mergeContext = try prepareContext(
                existingRecords: existingRecords,
                incomingRecords: incomingRecords
            )
            try preflightCurrentMerges(
                existingRecords: existingRecords,
                incomingRecords: records,
                context: mergeContext
            )
            return CurrentSyncTransportBatch(
                records: records,
                mergeContext: mergeContext
            )
        } catch let error as CurrentSyncRecordBatchError {
            switch error {
            case let .invalidCurrentRecord(recordID):
                throw SyncRecordTransportError.invalidCurrentRecordMerge(
                    recordID: recordID
                )
            }
        }
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
                    recordID: record.id
                )
            }
        }
    }

    private func prepareContext(
        existingRecords: [SyncRecord],
        incomingRecords: [SyncRecord]
    ) throws -> CurrentSyncRecordMergeContext {
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
            guard allChains.contains(witness.abandonedChain),
                  allTraces.contains(witness.abandonedTrace)
            else {
                continue
            }
            for chain in allChains {
                for trace in allTraces where witness.authorizesRestoredSuccessor(
                    chain: chain,
                    trace: trace
                ) {
                    authorizations.chainIDs.insert(witness.restoredChain.id)
                    let traceAuthorization = TraceReactivationAuthorization(
                        abandoned: witness.abandonedTrace,
                        restoredSuccessor: trace
                    )
                    if authorizations.tracePairs.contains(traceAuthorization) == false {
                        authorizations.tracePairs.append(traceAuthorization)
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
                case .day, .taskDefinition, .subtask, .appPreferences,
                     .classificationCommit, .traceClassificationEvent:
                    break
                }
            } catch {
                continue
            }
        }
        return evidence
    }

    private func validateBatchRecord(_ record: SyncRecord) throws {
        guard record.entityType.requiresImmutableRecordPayload == false else {
            return
        }
        do {
            try validate(record)
        } catch {
            throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                recordID: record.id
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
                recordID: record.id
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
                case .taskDefinition, .dayTrace, .subtask, .appPreferences,
                     .classificationCommit, .traceClassificationEvent:
                    break
                }
            } catch {
                throw CurrentSyncRecordBatchError.invalidCurrentRecord(
                    recordID: record.id
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
        case .subtask, .appPreferences,
             .classificationCommit, .traceClassificationEvent:
            return lwwWinner(existing, incoming)
        }
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
              existingTrace.continuedFromTraceID == incomingTrace.continuedFromTraceID
        else {
            throw CurrentSyncRecordMergeError.dayTraceIdentityCollision
        }
        try validateContentClock(
            createdAt: existingTrace.createdAt,
            contentUpdatedAt: existingTrace.contentUpdatedAt,
            terminalDates: [existingTrace.completedAt, existingTrace.settledAt]
        )
        try validateContentClock(
            createdAt: incomingTrace.createdAt,
            contentUpdatedAt: incomingTrace.contentUpdatedAt,
            terminalDates: [incomingTrace.completedAt, incomingTrace.settledAt]
        )
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
                ignoringStatus: true,
                ignoringCompletedAt: true,
                ignoringSettledAt: false
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
        ignoringStatus: Bool,
        ignoringCompletedAt: Bool,
        ignoringSettledAt: Bool
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.chainID == rhs.chainID
            && lhs.definitionID == rhs.definitionID
            && lhs.date == rhs.date
            && (ignoringStatus || lhs.status == rhs.status)
            && lhs.priority == rhs.priority
            && lhs.continuationSeq == rhs.continuationSeq
            && lhs.descriptionText == rhs.descriptionText
            && lhs.noteEntries == rhs.noteEntries
            && lhs.manualProgressPercent == rhs.manualProgressPercent
            && lhs.continuedFromTraceID == rhs.continuedFromTraceID
            && lhs.changedToTraceID == rhs.changedToTraceID
            && lhs.createdAt == rhs.createdAt
            && (ignoringCompletedAt || lhs.completedAt == rhs.completedAt)
            && (ignoringSettledAt || lhs.settledAt == rhs.settledAt)
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

    private func reactivationWitnesses(
        in record: SyncRecord,
        for chain: TaskChain
    ) throws -> [ChainReactivationEnvelope] {
        guard record.entityType == .taskChain else { return [] }
        return try record.reactivationWitnesses.map { data in
            let witness = try ChainReactivationEnvelope.decode(data)
            guard witness.restoredChain.id == chain.id,
                  witness.restoredChain.createdAt == chain.createdAt,
                  chain.updatedAt >= witness.restoredChain.updatedAt
            else {
                throw SyncRecordMapperError.invalidPayload(record.entityType)
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

private extension SyncRecord {
    var isMergeAuthorizationContext: Bool {
        entityType == .day || entityType == .taskChain
    }
}

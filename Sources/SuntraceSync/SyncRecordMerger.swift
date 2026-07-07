import Foundation
import SuntraceCore

public struct SyncRecordMerger: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func merge(
        records incomingRecords: [SyncRecord],
        into snapshot: SuntraceSnapshot,
        detectedAt: Date = Date()
    ) -> SyncMergeResult {
        var context = MergeContext(working: SnapshotIndex(snapshot), detectedAt: detectedAt)

        for record in ordered(incomingRecords) {
            guard record.operation == .upsert else {
                context.conflicts.append(
                    conflict(.unsupportedDelete, record: record, detectedAt: detectedAt, message: "delete is not supported by the first sync foundation")
                )
                continue
            }

            do {
                switch try mapper.payload(from: record) {
                case let .day(day):
                    apply(day, record: record, context: &context)
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
                }
            } catch {
                context.conflicts.append(conflict(.invalidRecordPayload, record: record, detectedAt: detectedAt, message: "record payload could not be decoded"))
            }
        }

        return SyncMergeResult(
            snapshot: context.working.snapshot(),
            appliedRecordIDs: context.applied,
            conflicts: context.conflicts
        )
    }

    private func ordered(_ records: [SyncRecord]) -> [SyncRecord] {
        records.sorted {
            if order($0.entityType) != order($1.entityType) {
                return order($0.entityType) < order($1.entityType)
            }
            return $0.id.rawValue < $1.id.rawValue
        }
    }

    private func order(_ type: SyncEntityType) -> Int {
        switch type {
        case .taskChain:
            return 0
        case .taskDefinition:
            return 1
        case .day:
            return 2
        case .dayTrace:
            return 3
        case .subtask:
            return 4
        case .appPreferences:
            return 5
        }
    }

    private func apply(_ day: Day, record: SyncRecord, context: inout MergeContext) {
        guard let existing = context.working.days[day.date] else {
            context.working.days[day.date] = day
            context.applied.append(record.id)
            return
        }
        guard existing != day, day.updatedAt >= existing.updatedAt else { return }
        context.working.days[day.date] = day
        context.applied.append(record.id)
    }

    private func apply(_ chain: TaskChain, record: SyncRecord, context: inout MergeContext) {
        guard let existing = context.working.chains[chain.id] else {
            context.working.chains[chain.id] = chain
            context.applied.append(record.id)
            return
        }
        guard existing != chain, chain.updatedAt >= existing.updatedAt else { return }
        context.working.chains[chain.id] = chain
        context.applied.append(record.id)
    }

    private func apply(
        _ definition: TaskDefinition,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        guard context.working.chains[definition.chainID] != nil else {
            context.conflicts.append(conflict(.missingParent, record: record, detectedAt: context.detectedAt, message: "task definition references a missing task chain"))
            return
        }
        guard let existing = context.working.definitions[definition.id] else {
            context.working.definitions[definition.id] = definition
            context.applied.append(record.id)
            return
        }
        guard existing != definition else { return }
        context.conflicts.append(conflict(.taskDefinitionMutation, record: record, detectedAt: context.detectedAt, message: "existing task definitions are not silently overwritten"))
    }

    private func apply(
        _ trace: DayTrace,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        guard context.working.chains[trace.chainID] != nil, context.working.definitions[trace.definitionID] != nil else {
            context.conflicts.append(conflict(.missingParent, record: record, detectedAt: context.detectedAt, message: "day trace references a missing chain or definition"))
            return
        }
        if let continuedFromTraceID = trace.continuedFromTraceID, context.working.traces[continuedFromTraceID] == nil {
            context.conflicts.append(conflict(.invalidReference, record: record, detectedAt: context.detectedAt, message: "day trace references a missing continued-from trace"))
            return
        }
        if let changedToTraceID = trace.changedToTraceID, context.working.traces[changedToTraceID] == nil {
            context.conflicts.append(conflict(.invalidReference, record: record, detectedAt: context.detectedAt, message: "day trace references a missing changed-to trace"))
            return
        }
        let activeTrace = context.working.traces.values.first {
            $0.chainID == trace.chainID && $0.status == .pending && $0.id != trace.id
        }
        if trace.status == .pending, let active = activeTrace {
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
        guard let existing = context.working.traces[trace.id] else {
            context.working.traces[trace.id] = trace
            context.working.days[trace.date] = context.working.days[trace.date] ?? Day(date: trace.date, now: trace.createdAt)
            context.applied.append(record.id)
            return
        }
        guard existing != trace else { return }
        guard existing.status == .pending, existing.settledAt == nil else {
            context.conflicts.append(conflict(.historicalTraceMutation, record: record, detectedAt: context.detectedAt, message: "historical or settled traces cannot be silently overwritten"))
            return
        }
        context.working.traces[trace.id] = trace
        context.applied.append(record.id)
    }

    private func apply(
        _ subtask: Subtask,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        guard let parentTrace = context.working.traces[subtask.traceID] else {
            context.conflicts.append(conflict(.missingParent, record: record, detectedAt: context.detectedAt, message: "subtask references a missing parent trace"))
            return
        }
        if let continuedFromSubtaskID = subtask.continuedFromSubtaskID, context.working.subtasks[continuedFromSubtaskID] == nil {
            context.conflicts.append(conflict(.invalidReference, record: record, detectedAt: context.detectedAt, message: "subtask references a missing continued-from subtask"))
            return
        }
        guard let existing = context.working.subtasks[subtask.id] else {
            context.working.subtasks[subtask.id] = subtask
            context.applied.append(record.id)
            return
        }
        guard existing != subtask else { return }
        guard parentTrace.status == .pending, parentTrace.settledAt == nil else {
            context.conflicts.append(conflict(.historicalSubtaskMutation, record: record, detectedAt: context.detectedAt, message: "subtasks under historical or settled traces cannot be silently overwritten"))
            return
        }
        context.working.subtasks[subtask.id] = subtask
        context.applied.append(record.id)
    }

    private func apply(_ envelope: AppPreferencesEnvelope, record: SyncRecord, context: inout MergeContext) {
        if envelope.updatedAt >= context.working.preferencesUpdatedAt {
            context.working.preferences = envelope.preferences
            context.working.preferencesUpdatedAt = envelope.updatedAt
            context.applied.append(record.id)
        }
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
            remoteRecordID: record.id,
            detectedAt: detectedAt,
            message: message
        )
    }
}

private struct MergeContext {
    var working: SnapshotIndex
    var conflicts: [SyncConflict]
    var applied: [SyncRecordID]
    var detectedAt: Date

    init(working: SnapshotIndex, detectedAt: Date) {
        self.working = working
        self.conflicts = []
        self.applied = []
        self.detectedAt = detectedAt
    }
}

private struct SnapshotIndex {
    var days: [LocalDate: Day]
    var chains: [TaskChainID: TaskChain]
    var definitions: [TaskDefinitionID: TaskDefinition]
    var traces: [DayTraceID: DayTrace]
    var subtasks: [SubtaskID: Subtask]
    var preferences: AppPreferences
    var preferencesUpdatedAt: Date

    init(_ snapshot: SuntraceSnapshot) {
        days = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) })
        chains = Dictionary(uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) })
        definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        traces = Dictionary(uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) })
        subtasks = Dictionary(uniqueKeysWithValues: snapshot.subtasks.map { ($0.id, $0) })
        preferences = snapshot.preferences
        preferencesUpdatedAt = Date(timeIntervalSince1970: 0)
    }

    func snapshot() -> SuntraceSnapshot {
        SuntraceSnapshot(
            days: days.values.sorted { $0.date < $1.date },
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
                return $0.createdAt < $1.createdAt
            },
            subtasks: subtasks.values.sorted {
                if $0.traceID == $1.traceID {
                    return $0.position < $1.position
                }
                return $0.traceID.description < $1.traceID.description
            },
            preferences: preferences
        )
    }
}

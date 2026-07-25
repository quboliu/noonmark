import Foundation
import NoonmarkCore
import NoonmarkSync

public struct SQLiteSyncTaskChanges: Codable, Equatable, Sendable {
    public var newTaskCount: Int
    public var updatedTaskCount: Int

    public init(newTaskCount: Int, updatedTaskCount: Int) {
        self.newTaskCount = newTaskCount
        self.updatedTaskCount = updatedTaskCount
    }
}

struct SQLiteSyncTaskChangeAnalyzer {
    private let mapper = SyncRecordMapper()

    func changes(
        localBefore: NoonmarkSnapshot,
        localAfter: NoonmarkSnapshot,
        remoteBefore: [SyncRecord],
        remoteAfter: [SyncRecord]
    ) -> SQLiteSyncTaskChanges {
        let outbound = remoteChanges(
            before: remoteBefore,
            after: remoteAfter
        )
        let inbound = localChanges(
            before: localBefore,
            after: localAfter
        )
        let newTaskIDs = outbound.newTaskIDs.union(inbound.newTaskIDs)
        let updatedTaskIDs = outbound.updatedTaskIDs
            .union(inbound.updatedTaskIDs)
            .subtracting(newTaskIDs)
        return SQLiteSyncTaskChanges(
            newTaskCount: newTaskIDs.count,
            updatedTaskCount: updatedTaskIDs.count
        )
    }

    private func localChanges(
        before: NoonmarkSnapshot,
        after: NoonmarkSnapshot
    ) -> TaskChangeSet {
        let beforeStates = localTaskStates(in: before)
        let afterStates = localTaskStates(in: after)
        let beforeIDs = Set(beforeStates.keys)
        let afterIDs = Set(afterStates.keys)
        let newTaskIDs = afterIDs.subtracting(beforeIDs)
        let updatedTaskIDs = beforeIDs.intersection(afterIDs).filter {
            beforeStates[$0] != afterStates[$0]
        }
        return TaskChangeSet(
            newTaskIDs: newTaskIDs,
            updatedTaskIDs: Set(updatedTaskIDs)
        )
    }

    private func localTaskStates(
        in snapshot: NoonmarkSnapshot
    ) -> [TaskChainID: LocalTaskState] {
        let tracesByChainID = Dictionary(
            grouping: snapshot.traces,
            by: \.chainID
        )
        let subtasksByTraceID = Dictionary(
            grouping: snapshot.subtasks,
            by: \.traceID
        )
        let definitionsByChainID = Dictionary(
            grouping: snapshot.definitions,
            by: \.chainID
        )
        return Dictionary(
            uniqueKeysWithValues: snapshot.chains.map { chain in
                let traces = (tracesByChainID[chain.id] ?? []).sorted {
                    $0.id.description < $1.id.description
                }
                let traceIDs = Set(traces.map(\.id))
                let subtasks = traceIDs.flatMap {
                    subtasksByTraceID[$0] ?? []
                }.sorted {
                    $0.id.description < $1.id.description
                }
                let classificationEvents = traceIDs.flatMap {
                    snapshot.classifications.snapshotEventsByTraceID[$0] ?? []
                }.sorted {
                    $0.id.uuidString < $1.id.uuidString
                }
                return (
                    chain.id,
                    LocalTaskState(
                        chain: chain,
                        definitions: (definitionsByChainID[chain.id] ?? [])
                            .sorted {
                                $0.id.description < $1.id.description
                            },
                        traces: traces,
                        subtasks: subtasks,
                        classification: snapshot.classifications
                            .currentByChainID[chain.id],
                        classificationRelationHistory: snapshot.classifications
                            .relationHistory
                            .filter { $0.chainID == chain.id }
                            .sorted {
                                $0.id.uuidString < $1.id.uuidString
                            },
                        classificationEvents: classificationEvents
                    )
                )
            }
        )
    }

    private func remoteChanges(
        before: [SyncRecord],
        after: [SyncRecord]
    ) -> TaskChangeSet {
        let beforeByID = recordIndex(before)
        let afterByID = recordIndex(after)
        let beforeTaskIDs = taskChainIDs(in: before)
        let afterTaskIDs = taskChainIDs(in: after)
        let newTaskIDs = afterTaskIDs.subtracting(beforeTaskIDs)
        let traceOwners = traceOwnerIndex(records: before + after)
        let changedRecords = afterByID.values.filter { record in
            guard let previous = beforeByID[record.id] else { return true }
            return previous.exactlyMatches(record) == false
        }
        let affectedTaskIDs = changedRecords.reduce(into: Set<TaskChainID>()) { result, record in
            result.formUnion(
                taskChainIDs(
                    affectedBy: record,
                    traceOwners: traceOwners
                )
            )
        }
        return TaskChangeSet(
            newTaskIDs: newTaskIDs,
            updatedTaskIDs: affectedTaskIDs
                .intersection(beforeTaskIDs)
                .subtracting(newTaskIDs)
        )
    }

    private func recordIndex(
        _ records: [SyncRecord]
    ) -> [SyncRecordID: SyncRecord] {
        records.reduce(into: [:]) { result, record in
            result[record.id] = record
        }
    }

    private func taskChainIDs(
        in records: [SyncRecord]
    ) -> Set<TaskChainID> {
        Set(records.compactMap { record in
            guard record.entityType == .taskChain else { return nil }
            return try? mapper.decodeTaskChain(record).id
        })
    }

    private func traceOwnerIndex(
        records: [SyncRecord]
    ) -> [DayTraceID: TaskChainID] {
        records.reduce(into: [:]) { result, record in
            guard record.entityType == .dayTrace,
                  let trace = try? mapper.decodeDayTrace(record)
            else { return }
            result[trace.id] = trace.chainID
        }
    }

    private func taskChainIDs(
        affectedBy record: SyncRecord,
        traceOwners: [DayTraceID: TaskChainID]
    ) -> Set<TaskChainID> {
        switch record.entityType {
        case .taskChain:
            return (try? mapper.decodeTaskChain(record))
                .map { [$0.id] } ?? []
        case .taskDefinition:
            return (try? mapper.decodeTaskDefinition(record))
                .map { [$0.chainID] } ?? []
        case .dayTrace:
            return (try? mapper.decodeDayTrace(record))
                .map { [$0.chainID] } ?? []
        case .subtask:
            guard let subtask = try? mapper.decodeSubtask(record),
                  let chainID = traceOwners[subtask.traceID]
            else { return [] }
            return [chainID]
        case .classificationCommit:
            guard let envelope = try? mapper.decodeClassificationCommit(record)
            else { return [] }
            return Set(
                envelope.delta.mutation.currentMutations.map(\.id)
                    + envelope.delta.mutation.appendedRelationHistory.map(\.chainID)
            )
        case .traceClassificationEvent:
            guard let envelope = try? mapper.decodeTraceClassificationEvent(record),
                  let chainID = traceOwners[envelope.event.traceID]
            else { return [] }
            return [chainID]
        case .day, .appPreferences:
            return []
        }
    }
}

private struct TaskChangeSet {
    var newTaskIDs: Set<TaskChainID>
    var updatedTaskIDs: Set<TaskChainID>
}

private struct LocalTaskState: Equatable {
    var chain: TaskChain
    var definitions: [TaskDefinition]
    var traces: [DayTrace]
    var subtasks: [Subtask]
    var classification: CurrentTaskClassification?
    var classificationRelationHistory: [ClassificationRelationHistoryEntry]
    var classificationEvents: [TraceClassificationSnapshot]
}

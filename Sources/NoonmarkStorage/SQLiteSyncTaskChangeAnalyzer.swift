import Foundation
import NoonmarkCore
import NoonmarkSync

public struct SQLiteSyncTaskChanges: Codable, Equatable, Sendable {
    public var newTaskCount: Int
    public var updatedTaskCount: Int
    public var newRecurringTaskCount: Int
    public var updatedRecurringTaskCount: Int

    public init(
        newTaskCount: Int,
        updatedTaskCount: Int,
        newRecurringTaskCount: Int = 0,
        updatedRecurringTaskCount: Int = 0
    ) {
        self.newTaskCount = newTaskCount
        self.updatedTaskCount = updatedTaskCount
        self.newRecurringTaskCount = newRecurringTaskCount
        self.updatedRecurringTaskCount = updatedRecurringTaskCount
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
            updatedTaskCount: updatedTaskIDs.count,
            newRecurringTaskCount: newTaskIDs.intersection(
                outbound.recurringTaskIDs.union(
                    inbound.recurringTaskIDs
                )
            ).count,
            updatedRecurringTaskCount: updatedTaskIDs.intersection(
                outbound.recurringTaskIDs.union(
                    inbound.recurringTaskIDs
                )
            ).count
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
            updatedTaskIDs: Set(updatedTaskIDs),
            recurringTaskIDs: Set(
                afterStates.compactMap { taskID, state in
                    state.series == nil ? nil : taskID
                }
            )
        )
    }

    private func localTaskStates(
        in snapshot: NoonmarkSnapshot
    ) -> [TaskChainID: LocalTaskAggregateState] {
        let chainStates = localChainStates(in: snapshot)
        let anchorBySeriesID = recurringAnchorChainIDs(
            in: snapshot.chains
        )
        let seriesByID = Dictionary(
            uniqueKeysWithValues: snapshot.taskCycleSeries.map {
                ($0.id, $0)
            }
        )
        var membersByTaskID: [TaskChainID: [LocalTaskState]] = [:]
        for chainState in chainStates.values {
            let taskID = chainState.chain.cycleMembership.flatMap {
                anchorBySeriesID[$0.seriesID]
            } ?? chainState.chain.id
            membersByTaskID[taskID, default: []].append(chainState)
        }
        return membersByTaskID.mapValues { members in
            let ordered = members.sorted {
                $0.chain.id.description < $1.chain.id.description
            }
            let series = ordered.first?.chain.cycleMembership.flatMap {
                seriesByID[$0.seriesID]
            }
            return LocalTaskAggregateState(
                series: series,
                members: ordered
            )
        }
    }

    private func localChainStates(
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
        let beforeEvidence = recordEvidenceIndex(before)
        let afterEvidence = recordEvidenceIndex(after)
        let beforeIdentity = remoteTaskIdentity(in: before)
        let afterIdentity = remoteTaskIdentity(in: after)
        let combinedIdentity = remoteTaskIdentity(
            in: before + after
        )
        let beforeTaskIDs = beforeIdentity.taskIDs
        let afterTaskIDs = afterIdentity.taskIDs
        let newTaskIDs = afterTaskIDs.subtracting(beforeTaskIDs)
        let traceOwners = traceOwnerIndex(records: before + after)
        let changedRecords = afterEvidence.compactMap { evidenceID, record in
            beforeEvidence[evidenceID] == nil ? record : nil
        }
        let affectedTaskIDs = changedRecords.reduce(into: Set<TaskChainID>()) { result, record in
            result.formUnion(
                taskChainIDs(
                    affectedBy: record,
                    traceOwners: traceOwners,
                    identity: combinedIdentity
                )
            )
        }
        return TaskChangeSet(
            newTaskIDs: newTaskIDs,
            updatedTaskIDs: affectedTaskIDs
                .intersection(beforeTaskIDs)
                .subtracting(newTaskIDs),
            recurringTaskIDs: beforeIdentity.recurringTaskIDs.union(
                afterIdentity.recurringTaskIDs
            )
        )
    }

    private func recordEvidenceIndex(
        _ records: [SyncRecord]
    ) -> [SyncRecordEvidenceID: SyncRecord] {
        records.reduce(into: [:]) { result, record in
            result[SyncRecordEvidenceID(record: record)] = record
        }
    }

    private func remoteTaskIdentity(
        in records: [SyncRecord]
    ) -> RemoteTaskIdentity {
        let chains: [TaskChain] = records.compactMap { record in
            guard record.entityType == .taskChain,
                  let chain = try? mapper.decodeTaskChain(record)
            else {
                return nil
            }
            return chain
        }
        let anchorBySeriesID = recurringAnchorChainIDs(in: chains)
        var taskIDByChainID: [TaskChainID: TaskChainID] = [:]
        for chain in chains {
            let taskID = chain.cycleMembership.flatMap {
                anchorBySeriesID[$0.seriesID]
            } ?? chain.id
            if chain.cycleMembership != nil
                || taskIDByChainID[chain.id] == nil
            {
                taskIDByChainID[chain.id] = taskID
            }
        }
        return RemoteTaskIdentity(
            taskIDByChainID: taskIDByChainID,
            taskIDBySeriesID: anchorBySeriesID,
            taskIDs: Set(taskIDByChainID.values),
            recurringTaskIDs: Set(anchorBySeriesID.values)
        )
    }

    private func recurringAnchorChainIDs(
        in chains: [TaskChain]
    ) -> [TaskCycleSeriesID: TaskChainID] {
        Dictionary(
            grouping: chains.compactMap { chain -> TaskChain? in
                chain.cycleMembership == nil ? nil : chain
            },
            by: { $0.cycleMembership!.seriesID }
        ).mapValues { members in
            members.min { lhs, rhs in
                guard let lhsMembership = lhs.cycleMembership,
                      let rhsMembership = rhs.cycleMembership
                else {
                    return lhs.id.description < rhs.id.description
                }
                if lhsMembership.occurrenceDate
                    != rhsMembership.occurrenceDate
                {
                    return lhsMembership.occurrenceDate
                        < rhsMembership.occurrenceDate
                }
                return lhs.id.description < rhs.id.description
            }!.id
        }
    }

    private func traceOwnerIndex(
        records: [SyncRecord]
    ) -> [DayTraceID: Set<TaskChainID>] {
        records.reduce(into: [:]) { result, record in
            guard record.entityType == .dayTrace,
                  let trace = try? mapper.decodeDayTrace(record)
            else { return }
            result[trace.id, default: []].insert(trace.chainID)
        }
    }

    private func taskChainIDs(
        affectedBy record: SyncRecord,
        traceOwners: [DayTraceID: Set<TaskChainID>],
        identity: RemoteTaskIdentity
    ) -> Set<TaskChainID> {
        func taskIDs(
            for chainIDs: some Sequence<TaskChainID>
        ) -> Set<TaskChainID> {
            Set(chainIDs.compactMap {
                identity.taskIDByChainID[$0]
            })
        }

        switch record.entityType {
        case .taskChain:
            guard let chain = try? mapper.decodeTaskChain(record) else {
                return []
            }
            return taskIDs(for: [chain.id])
        case .taskCycleSeries:
            guard let series = try? mapper.decodeTaskCycleSeries(record),
                  let taskID = identity.taskIDBySeriesID[series.id]
            else {
                return []
            }
            return [taskID]
        case .taskDefinition:
            guard let definition = try? mapper.decodeTaskDefinition(
                record
            ) else {
                return []
            }
            return taskIDs(for: [definition.chainID])
        case .dayTrace:
            guard let trace = try? mapper.decodeDayTrace(record) else {
                return []
            }
            return taskIDs(for: [trace.chainID])
        case .subtask:
            guard let subtask = try? mapper.decodeSubtask(record),
                  let chainIDs = traceOwners[subtask.traceID]
            else { return [] }
            return taskIDs(for: chainIDs)
        case .classificationCommit:
            guard let envelope = try? mapper.decodeClassificationCommit(record)
            else { return [] }
            return taskIDs(for:
                envelope.delta.mutation.currentMutations.map(\.id)
                    + envelope.delta.mutation.appendedRelationHistory.map(\.chainID))
        case .traceClassificationEvent:
            guard let envelope = try? mapper.decodeTraceClassificationEvent(record),
                  let chainIDs = traceOwners[envelope.event.traceID]
            else { return [] }
            return taskIDs(for: chainIDs)
        case .day, .appPreferences:
            return []
        }
    }
}

private struct TaskChangeSet {
    var newTaskIDs: Set<TaskChainID>
    var updatedTaskIDs: Set<TaskChainID>
    var recurringTaskIDs: Set<TaskChainID>
}

private struct RemoteTaskIdentity {
    var taskIDByChainID: [TaskChainID: TaskChainID]
    var taskIDBySeriesID: [TaskCycleSeriesID: TaskChainID]
    var taskIDs: Set<TaskChainID>
    var recurringTaskIDs: Set<TaskChainID>
}

private struct LocalTaskAggregateState: Equatable {
    var series: TaskCycleSeries?
    var members: [LocalTaskState]
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

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
        knownTerminalRejections: [SyncTerminalRejection] = [],
        detectedAt: Date = Date()
    ) -> SyncMergeResult {
        var context = MergeContext(
            working: SnapshotIndex(snapshot),
            knownTerminalRejections: knownTerminalRejections,
            detectedAt: detectedAt
        )
        let plan = orderingPlan(
            incomingRecords,
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

        for record in plan.ordered {
            process(record, context: &context)
        }
        retryWaitingRecords(context: &context)

        return SyncMergeResult(
            snapshot: context.working.snapshot(),
            appliedRecordIDs: context.applied,
            waitingRecords: context.waiting,
            conflicts: context.conflicts
        )
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
            let dependencyIDs = [trace.continuedFromTraceID, trace.changedToTraceID]
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
        let existing = context.working.traces[trace.id]
        let mutatesHistoricalTrace = existing.map {
            $0 != trace
                && ($0.status != .pending || $0.settledAt != nil)
                && isSanctionedHistoricalInverse(
                    from: $0,
                    to: trace,
                    in: context.working
                ) == false
        } ?? false
        if mutatesHistoricalTrace {
            context.conflicts.append(conflict(.historicalTraceMutation, record: record, detectedAt: context.detectedAt, message: "historical or settled traces cannot be silently overwritten"))
            return
        }

        context.working.traces[trace.id] = trace
        context.working.days[trace.date] = context.working.days[trace.date]
            ?? Day(date: trace.date, now: trace.createdAt)
        if existing != trace {
            context.applied.append(record.id)
        }
    }

    private func isSanctionedHistoricalInverse(
        from existing: DayTrace,
        to incoming: DayTrace,
        in snapshot: SnapshotIndex
    ) -> Bool {
        guard snapshot.chains[incoming.chainID]?.state == .active else {
            return false
        }

        if existing.status == .abandoned {
            let hasValidIncomingState =
                (incoming.status == .pending && incoming.settledAt == nil)
                || (incoming.status == .unfinished && incoming.settledAt != nil)
            guard hasValidIncomingState else { return false }

            var permitted = existing
            permitted.status = incoming.status
            permitted.settledAt = incoming.settledAt
            return permitted == incoming
        }

        let isUnlockedCompletionUndo = existing.status == .completed
            && existing.completedAt != nil
            && incoming.status == .pending
            && incoming.completedAt == nil
            && incoming.settledAt == existing.settledAt
            && snapshot.days[existing.date]?.lockedAt == nil
        if isUnlockedCompletionUndo {
            var permitted = existing
            permitted.status = .pending
            permitted.completedAt = nil
            return permitted == incoming
        }

        return false
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

    private func apply(
        _ envelope: TraceClassificationEventEnvelope,
        record: SyncRecord,
        context: inout MergeContext
    ) {
        if let predecessorID = envelope.predecessorEventID {
            if context.terminalRejections[.traceClassificationEvent(predecessorID)] != nil {
                rejectTraceClassificationEvent(
                    record,
                    message: "trace classification event depends on terminal rejected event \(predecessorID.uuidString)",
                    context: &context
                )
                return
            }
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
            context.waiting.append(
                SyncWaitingRecord(
                    record: record,
                    dependencies: missing.sorted(by: dependencyComesBefore)
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
        context.applied.append(record.id)
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
            context.applied.append(record.id)
        case .duplicate:
            return
        case let .waiting(dependencies):
            context.waiting.append(
                SyncWaitingRecord(
                    record: record,
                    dependencies: dependencies
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
            if context.terminalRejections[terminal.identity] == nil {
                context.terminalRejections[terminal.identity] = terminal
            }
        }
    }
}

private struct RecordOrderingPlan {
    var ordered: [SyncRecord]
    var rejected: [RecordOrderingRejection]
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

private struct MergeContext {
    var working: SnapshotIndex
    var conflicts: [SyncConflict]
    var applied: [SyncRecordID]
    var waiting: [SyncWaitingRecord]
    var terminalRejections: [SyncTerminalRecordIdentity: SyncTerminalRejection]
    var detectedAt: Date

    init(
        working: SnapshotIndex,
        knownTerminalRejections: [SyncTerminalRejection],
        detectedAt: Date
    ) {
        self.working = working
        self.conflicts = []
        self.applied = []
        self.waiting = []
        self.terminalRejections = knownTerminalRejections.reduce(into: [:]) {
            if $0[$1.identity] == nil {
                $0[$1.identity] = $1
            }
        }
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
    var classifications: TaskClassificationState
    var preferencesUpdatedAt: Date

    init(_ snapshot: SuntraceSnapshot) {
        days = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.date, $0) })
        chains = Dictionary(uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) })
        definitions = Dictionary(uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) })
        traces = Dictionary(uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) })
        subtasks = Dictionary(uniqueKeysWithValues: snapshot.subtasks.map { ($0.id, $0) })
        preferences = snapshot.preferences
        classifications = snapshot.classifications
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
            preferences: preferences,
            classifications: classifications
        )
    }
}

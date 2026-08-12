import CryptoKit
import Foundation
import NoonmarkCore
import NoonmarkSync

struct ReplicationForkDecisionResolution {
    let baseSnapshot: NoonmarkSnapshot
    let rejectedEvidence: Set<SyncRecordEvidenceID>
    let outcomes: [SQLiteReplicationForkDecisionOutcome]
}

struct ReplicationForkDecisionResolver {
    private let mapper = SyncRecordMapper()

    func resolve(
        snapshot: NoonmarkSnapshot,
        conflictSet: SQLiteReplicationForkConflictSet,
        evidence: ReplicationForkEvidence,
        decisions: [ReplicationForkConflictDecisionSelection],
        decidedAt: Date
    ) throws -> ReplicationForkDecisionResolution {
        guard decidedAt.timeIntervalSinceReferenceDate.isFinite,
              decisions.isEmpty == false,
              Set(decisions.map(\.conflictID)).count == decisions.count,
              Set(decisions.map(\.conflictID))
              == Set(conflictSet.conflicts.map(\.conflict.id)),
              conflictSet.conflicts.allSatisfy({
                  $0.decision == nil
                      && $0.decidedAt == nil
                      && $0.resultReference == nil
              })
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork decisions do not match exact unresolved evidence"
            )
        }
        let conflictsByID = Dictionary(
            uniqueKeysWithValues: conflictSet.conflicts.map {
                ($0.conflict.id, $0.conflict)
            }
        )
        guard decisions.allSatisfy({ selection in
            conflictsByID[selection.conflictID].map {
                ReplicationForkConflictDecision.allowedDecisions(
                    for: $0
                ).contains(selection.decision)
            } ?? false
        }) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "replication fork decision is not executable for its evidence"
            )
        }
        let acceptedRemoteEntityIDs = decisions.compactMap { selection in
            selection.decision == .acceptRemote
                ? conflictsByID[selection.conflictID]?.conflictEntityKey
                : nil
        }
        guard Set(acceptedRemoteEntityIDs).count
            == acceptedRemoteEntityIDs.count
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "one entity cannot accept more than one remote candidate"
            )
        }

        let candidate = try NoonmarkEngine(snapshot: snapshot)
        var outcomes: [SQLiteReplicationForkDecisionOutcome] = []
        for selection in decisions.sorted(by: {
            $0.conflictID.uuidString < $1.conflictID.uuidString
        }) {
            guard let conflict = conflictsByID[selection.conflictID]
            else {
                throw SQLiteRepositoryError.invalidStoredValue(
                    "replication fork decision lost its conflict"
                )
            }
            let resultReference: ReplicationForkDecisionResultReference?
            switch selection.decision {
            case .keepCurrent:
                resultReference = nil
            case .acceptRemote:
                let remoteDefinition = try mapper.decodeTaskDefinition(
                    conflict.remoteRecord
                )
                let forwardID = TaskDefinitionID(
                    deterministicUUID(
                        resolutionID: conflictSet.resolutionID,
                        conflictID: conflict.id,
                        role: "accepted-task-definition"
                    )
                )
                try candidate.acceptRemoteTaskDefinitionAsForwardRevision(
                    remoteDefinition,
                    conflictedDefinitionID: remoteDefinition.id,
                    forwardDefinitionID: forwardID,
                    now: decidedAt
                )
                resultReference = ReplicationForkDecisionResultReference(
                    entityType: .taskDefinition,
                    entityID: forwardID.description
                )
            case .copyAsNew:
                let template = try taskCopyTemplate(
                    for: conflict,
                    evidence: evidence,
                    snapshot: snapshot
                )
                let copiedChainID = TaskChainID(
                    deterministicUUID(
                        resolutionID: conflictSet.resolutionID,
                        conflictID: conflict.id,
                        role: "copied-task-chain"
                    )
                )
                let copiedDefinitionID = TaskDefinitionID(
                    deterministicUUID(
                        resolutionID: conflictSet.resolutionID,
                        conflictID: conflict.id,
                        role: "copied-task-definition"
                    )
                )
                let noteIDs = template.noteBodies.indices.map {
                    TaskNoteEntryID(
                        deterministicUUID(
                            resolutionID: conflictSet.resolutionID,
                            conflictID: conflict.id,
                            role: "copied-note-\($0)"
                        )
                    )
                }
                let plannedIDs = template.plannedSubtasks.indices.map {
                    PlannedSubtaskID(
                        deterministicUUID(
                            resolutionID: conflictSet.resolutionID,
                            conflictID: conflict.id,
                            role: "copied-planned-subtask-\($0)"
                        )
                    )
                }
                let lineageIDs = template.plannedSubtasks.indices.map {
                    SubtaskLineageID(
                        deterministicUUID(
                            resolutionID: conflictSet.resolutionID,
                            conflictID: conflict.id,
                            role: "copied-subtask-lineage-\($0)"
                        )
                    )
                }
                _ = try candidate.copyTaskAsIndependentPoolTask(
                    IndependentPoolTaskCopyRequest(
                        source: IndependentPoolTaskCopyRequest.Source(
                            chainID: template.sourceChainID,
                            title: template.title,
                            descriptionText: template.descriptionText,
                            noteBodies: template.noteBodies,
                            plannedSubtasks: template.plannedSubtasks
                        ),
                        destination:
                        IndependentPoolTaskCopyRequest.DestinationIdentity(
                            chainID: copiedChainID,
                            definitionID: copiedDefinitionID,
                            noteIDs: noteIDs,
                            plannedSubtaskIDs: plannedIDs,
                            lineageIDs: lineageIDs
                        ),
                        classification:
                        IndependentPoolTaskCopyRequest.ClassificationIdentity(
                            changeRecordID: deterministicUUID(
                                resolutionID: conflictSet.resolutionID,
                                conflictID: conflict.id,
                                role: "copied-classification-change"
                            ),
                            planID: deterministicUUID(
                                resolutionID: conflictSet.resolutionID,
                                conflictID: conflict.id,
                                role: "copied-classification-plan"
                            ),
                            interactionID: deterministicUUID(
                                resolutionID: conflictSet.resolutionID,
                                conflictID: conflict.id,
                                role: "copied-classification-interaction"
                            )
                        ),
                        now: decidedAt
                    ),
                )
                resultReference = ReplicationForkDecisionResultReference(
                    entityType: .taskChain,
                    entityID: copiedChainID.description
                )
            }
            outcomes.append(
                SQLiteReplicationForkDecisionOutcome(
                    selection: selection,
                    resultReference: resultReference
                )
            )
        }
        let resolvedSnapshot = candidate.snapshot()
        try resolvedSnapshot.validateIntegrity()
        return ReplicationForkDecisionResolution(
            baseSnapshot: resolvedSnapshot,
            rejectedEvidence: Set(conflictSet.conflicts.map {
                SyncRecordEvidenceID(record: $0.conflict.remoteRecord)
            }),
            outcomes: outcomes
        )
    }

    private func deterministicUUID(
        resolutionID: ReplicationDigest,
        conflictID: UUID,
        role: String
    ) -> UUID {
        var evidence = Data()
        for component in [
            "noonmark.replication-fork-decision.v1",
            resolutionID.rawValue,
            conflictID.uuidString.lowercased(),
            role,
        ] {
            let bytes = Data(component.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) {
                evidence.append(contentsOf: $0)
            }
            evidence.append(bytes)
        }
        var bytes = Array(SHA256.hash(data: evidence).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: value) else {
            preconditionFailure(
                "replication decision digest did not form a UUID"
            )
        }
        return id
    }

    private func taskCopyTemplate(
        for conflict: SyncConflict,
        evidence: ReplicationForkEvidence,
        snapshot: NoonmarkSnapshot
    ) throws -> TaskCopyTemplate {
        guard let branch = evidence.branches.first(where: { branch in
            branch.records.contains {
                $0.exactlyMatches(conflict.remoteRecord)
            }
        }) else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "copy-as-new conflict is not bound to one fork branch"
            )
        }
        let snapshotDefinitions = Dictionary(
            uniqueKeysWithValues: snapshot.definitions.map { ($0.id, $0) }
        )
        let snapshotTraces = Dictionary(
            uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) }
        )
        let snapshotChains = Dictionary(
            uniqueKeysWithValues: snapshot.chains.map { ($0.id, $0) }
        )

        let definition: TaskDefinition
        let sourceTrace: DayTrace?
        switch (conflict.type, conflict.entityType) {
        case (.taskDefinitionMutation, .taskDefinition):
            definition = try mapper.decodeTaskDefinition(
                conflict.remoteRecord
            )
            sourceTrace = nil
        case (.historicalTraceMutation, .dayTrace),
             (.duplicateActiveTrace, .dayTrace):
            let trace = try mapper.decodeDayTrace(conflict.remoteRecord)
            sourceTrace = trace
            definition = try resolvedDefinition(
                id: trace.definitionID,
                branch: branch,
                snapshotDefinitions: snapshotDefinitions
            )
        case (.historicalSubtaskMutation, .subtask):
            let subtask = try mapper.decodeSubtask(conflict.remoteRecord)
            let trace = try resolvedTrace(
                id: subtask.traceID,
                branch: branch,
                snapshotTraces: snapshotTraces
            )
            sourceTrace = trace
            definition = try resolvedDefinition(
                id: trace.definitionID,
                branch: branch,
                snapshotDefinitions: snapshotDefinitions
            )
        default:
            throw SQLiteRepositoryError.invalidStoredValue(
                "copy-as-new is not defined for this conflict"
            )
        }
        guard let sourceChain = try branch.records
            .filter({
                $0.entityType == .taskChain
                    && $0.entityID == definition.chainID.description
            })
            .sorted(by: evidenceComesBefore)
            .first.map(mapper.decodeTaskChain)
            ?? snapshotChains[definition.chainID]
        else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "copy-as-new lacks its source task chain"
            )
        }
        let plannedSubtasks: [PlannedSubtask]
        if let sourceTrace {
            var subtasksByID = Dictionary(
                uniqueKeysWithValues: snapshot.subtasks
                    .filter { $0.traceID == sourceTrace.id }
                    .map { ($0.id, $0) }
            )
            for record in branch.records
            where record.entityType == .subtask {
                let subtask = try mapper.decodeSubtask(record)
                if subtask.traceID == sourceTrace.id {
                    subtasksByID[subtask.id] = subtask
                }
            }
            if conflict.entityType == .subtask {
                let selected = try mapper.decodeSubtask(
                    conflict.remoteRecord
                )
                subtasksByID[selected.id] = selected
            }
            let visible = subtasksByID.values
                .filter(\.isUserPresentable)
                .sorted {
                    if $0.position != $1.position {
                        return $0.position < $1.position
                    }
                    return $0.id.description < $1.id.description
                }
            plannedSubtasks = visible.isEmpty
                ? definition.plannedSubtasks
                : visible.enumerated().map { index, subtask in
                    PlannedSubtask(
                        title: subtask.title,
                        difficulty: subtask.difficulty,
                        position: index + 1,
                        now: subtask.updatedAt
                    )
                }
        } else {
            plannedSubtasks = definition.plannedSubtasks
        }
        let notes = sourceTrace?.activeNoteEntries.isEmpty == false
            ? sourceTrace?.activeNoteEntries ?? []
            : sourceChain.activeNoteEntries
        return TaskCopyTemplate(
            sourceChainID: definition.chainID,
            title: definition.title,
            descriptionText: sourceTrace?.descriptionText
                ?? definition.descriptionText,
            noteBodies: notes.map(\.body),
            plannedSubtasks: plannedSubtasks
        )
    }

    private func resolvedDefinition(
        id: TaskDefinitionID,
        branch: ReceivedReplicationPublication,
        snapshotDefinitions: [TaskDefinitionID: TaskDefinition]
    ) throws -> TaskDefinition {
        if let record = branch.records
            .filter({
                $0.entityType == .taskDefinition
                    && $0.entityID == id.description
            })
            .sorted(by: evidenceComesBefore)
            .first
        {
            return try mapper.decodeTaskDefinition(record)
        }
        guard let definition = snapshotDefinitions[id] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "copy-as-new lacks its task definition"
            )
        }
        return definition
    }

    private func resolvedTrace(
        id: DayTraceID,
        branch: ReceivedReplicationPublication,
        snapshotTraces: [DayTraceID: DayTrace]
    ) throws -> DayTrace {
        if let record = branch.records
            .filter({
                $0.entityType == .dayTrace
                    && $0.entityID == id.description
            })
            .sorted(by: evidenceComesBefore)
            .first
        {
            return try mapper.decodeDayTrace(record)
        }
        guard let trace = snapshotTraces[id] else {
            throw SQLiteRepositoryError.invalidStoredValue(
                "copy-as-new lacks its parent day trace"
            )
        }
        return trace
    }

    private func evidenceComesBefore(
        _ lhs: SyncRecord,
        _ rhs: SyncRecord
    ) -> Bool {
        SyncRecordEvidenceID(record: lhs).rawValue
            < SyncRecordEvidenceID(record: rhs).rawValue
    }
}

private struct TaskCopyTemplate {
    let sourceChainID: TaskChainID
    let title: String
    let descriptionText: String?
    let noteBodies: [String]
    let plannedSubtasks: [PlannedSubtask]
}

private extension SyncConflict {
    var conflictEntityKey: String {
        "\(entityType.rawValue)|\(entityID)"
    }
}

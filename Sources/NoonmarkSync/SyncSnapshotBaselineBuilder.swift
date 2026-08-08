import Foundation
import NoonmarkCore

/// 把一份已经存在、但没有 mutation journal 的完整本地 snapshot
/// 转换成首次同步所需的 pending journal。
///
/// 这里刻意仍以实体级 record 建立基线，避免把整个数据包当成一个覆盖式同步对象。
public struct SyncSnapshotBaselineBuilder: Sendable {
    private let mapper: SyncRecordMapper

    public init(mapper: SyncRecordMapper = SyncRecordMapper()) {
        self.mapper = mapper
    }

    public func journalEntries(
        from snapshot: NoonmarkSnapshot,
        modifiedBy deviceID: SyncDeviceID,
        createdAt: Date = Date()
    ) throws -> [SyncJournalEntry] {
        var entries = snapshot.days.map {
            SyncJournalEntry(
                entityType: .day,
                entityID: $0.date.description,
                changedAt: $0.updatedAt,
                deviceID: deviceID
            )
        }
        entries += snapshot.taskCycleSeries.map {
            SyncJournalEntry(
                entityType: .taskCycleSeries,
                entityID: $0.id.description,
                changedAt: $0.updatedAt,
                deviceID: deviceID
            )
        }
        entries += snapshot.chains.map {
            SyncJournalEntry(
                entityType: .taskChain,
                entityID: $0.id.description,
                changedAt: $0.noteEntries.reduce($0.updatedAt) {
                    max($0, $1.updatedAt)
                },
                deviceID: deviceID
            )
        }
        entries += snapshot.definitions.map {
            SyncJournalEntry(
                entityType: .taskDefinition,
                entityID: $0.id.description,
                changedAt: $0.contentUpdatedAt,
                deviceID: deviceID
            )
        }
        entries += snapshot.traces.map {
            SyncJournalEntry(
                entityType: .dayTrace,
                entityID: $0.id.description,
                changedAt: $0.noteEntries.reduce($0.contentUpdatedAt) {
                    max($0, $1.updatedAt)
                },
                deviceID: deviceID
            )
        }
        entries += snapshot.subtasks.map {
            SyncJournalEntry(
                entityType: .subtask,
                entityID: $0.id.description,
                changedAt: $0.updatedAt,
                deviceID: deviceID
            )
        }
        entries += snapshot.ideas.map {
            SyncJournalEntry(
                entityType: .ideaEntry,
                entityID: $0.id.description,
                changedAt: $0.updatedAt,
                deviceID: deviceID
            )
        }

        let preferencesRecord = try mapper.record(
            for: AppPreferencesEnvelope(preferences: snapshot.preferences),
            modifiedBy: SyncDeviceID(
                snapshot.preferences.themeLanguageWriterID
            )
        )
        entries.append(
            SyncJournalEntry(
                entityType: .appPreferences,
                entityID: preferencesRecord.entityID,
                changedAt: preferencesRecord.modifiedAt,
                deviceID: preferencesRecord.modifiedByDeviceID,
                recordPayload: preferencesRecord.payload
            )
        )
        if snapshot.classifications != TaskClassificationState() {
            let baseline = try ClassificationBaselineEnvelope(
                state: snapshot.classifications,
                createdAt: createdAt
            )
            entries.append(
                SyncJournalEntry(
                    entityType: .classificationBaseline,
                    entityID: baseline.baselineID.uuidString,
                    changedAt: createdAt,
                    deviceID: deviceID,
                    recordPayload: try baseline.canonicalData()
                )
            )
        }
        return entries
    }
}

public struct SyncSnapshotBaselineCoverageAuditor: Sendable {
    private struct EntityKey: Hashable {
        let type: SyncEntityType
        let id: String
    }

    private struct ClassificationEvidence {
        let record: SyncRecord

        var type: SyncEntityType {
            record.entityType
        }
    }

    private let mapper = SyncRecordMapper()
    private let materializer = SyncRecordMaterializer()
    private let merger = SyncRecordMerger()

    public init() {}

    public func isComplete(
        snapshot: NoonmarkSnapshot,
        journalEntries: [SyncJournalEntry],
        remoteRecords: [SyncRecord] = []
    ) -> Bool {
        missingFactCount(
            snapshot: snapshot,
            journalEntries: journalEntries,
            remoteRecords: remoteRecords
        ) == 0
    }

    public func missingFactCount(
        snapshot: NoonmarkSnapshot,
        journalEntries: [SyncJournalEntry],
        remoteRecords: [SyncRecord] = []
    ) -> Int {
        let required = requiredEntityKeys(in: snapshot)
        var represented = localEntityKeysCoveringCurrentFacts(
            snapshot: snapshot,
            entries: journalEntries
        )
        represented.formUnion(
            remoteEntityKeysCoveringCurrentFacts(
                snapshot: snapshot,
                records: remoteRecords
            )
        )
        return required.subtracting(represented).count
            + missingClassificationFactCount(
                snapshot: snapshot,
                journalEntries: journalEntries,
                remoteRecords: remoteRecords
            )
    }

    private func requiredEntityKeys(
        in snapshot: NoonmarkSnapshot
    ) -> Set<EntityKey> {
        var required = Set(
            snapshot.days.map {
                EntityKey(type: .day, id: $0.date.description)
            }
            + snapshot.taskCycleSeries.map {
                EntityKey(type: .taskCycleSeries, id: $0.id.description)
            }
            + snapshot.chains.map {
                EntityKey(type: .taskChain, id: $0.id.description)
            }
            + snapshot.definitions.map {
                EntityKey(type: .taskDefinition, id: $0.id.description)
            }
            + snapshot.traces.map {
                EntityKey(type: .dayTrace, id: $0.id.description)
            }
            + snapshot.subtasks.map {
                EntityKey(type: .subtask, id: $0.id.description)
            }
            + snapshot.ideas.map {
                EntityKey(type: .ideaEntry, id: $0.id.description)
            }
        )
        if containsNondefaultPreferences(snapshot.preferences) {
            required.insert(
                EntityKey(type: .appPreferences, id: "default")
            )
        }
        return required
    }

    private func containsNondefaultPreferences(
        _ preferences: AppPreferences
    ) -> Bool {
        AppPreferencesEnvelope(preferences: preferences)
            != AppPreferencesEnvelope(preferences: AppPreferences())
    }

    private func remoteEntityKeysCoveringCurrentFacts(
        snapshot: NoonmarkSnapshot,
        records: [SyncRecord]
    ) -> Set<EntityKey> {
        Set(
            records
                .filter { record in
                    guard record.operation == .upsert else {
                        return false
                    }
                    return remoteRecordCoversCurrentFact(
                        record,
                        snapshot: snapshot
                    )
                }
                .map {
                    EntityKey(type: $0.entityType, id: $0.entityID)
                }
        )
    }

    private func localEntityKeysCoveringCurrentFacts(
        snapshot: NoonmarkSnapshot,
        entries: [SyncJournalEntry]
    ) -> Set<EntityKey> {
        Set(
            entries.compactMap { entry in
                // A local journal state is not evidence that the remote
                // endpoint still contains the fact. In particular, an
                // uploaded entry can outlive an endpoint replacement. Only
                // pending/failed local work may cover a local baseline; an
                // uploaded fact must be corroborated by remote evidence.
                guard entry.state != .uploaded,
                      let record = try? materializer.record(
                          for: entry,
                          in: snapshot
                      ),
                      remoteRecordCoversCurrentFact(
                          record,
                          snapshot: snapshot
                      )
                else {
                    return nil
                }
                return EntityKey(
                    type: record.entityType,
                    id: record.entityID
                )
            }
        )
    }

    private func remoteRecordCoversCurrentFact(
        _ record: SyncRecord,
        snapshot: NoonmarkSnapshot
    ) -> Bool {
        guard (try? mapper.payload(from: record)) != nil,
              let localRecord = currentRecord(
                  matching: record,
                  snapshot: snapshot
              )
        else {
            return false
        }
        let identityMatches = localRecord.id == record.id
            && localRecord.entityType == record.entityType
        let payloadMatches = localRecord.payload == record.payload
        return identityMatches && payloadMatches
    }

    private func currentRecord(
        matching remoteRecord: SyncRecord,
        snapshot: NoonmarkSnapshot
    ) -> SyncRecord? {
        let deviceID = remoteRecord.modifiedByDeviceID
        return switch remoteRecord.entityType {
        case .day:
            snapshot.days.first {
                $0.date.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .taskCycleSeries:
            snapshot.taskCycleSeries.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .taskChain:
            snapshot.chains.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .taskDefinition:
            snapshot.definitions.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .dayTrace:
            snapshot.traces.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .subtask:
            snapshot.subtasks.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .ideaEntry:
            snapshot.ideas.first {
                $0.id.description == remoteRecord.entityID
            }.flatMap {
                try? mapper.record(for: $0, modifiedBy: deviceID)
            }
        case .appPreferences:
            try? mapper.record(
                for: AppPreferencesEnvelope(
                    preferences: snapshot.preferences
                ),
                modifiedBy: SyncDeviceID(
                    snapshot.preferences.themeLanguageWriterID
                )
            )
        case .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            nil
        }
    }

    private func missingClassificationFactCount(
        snapshot: NoonmarkSnapshot,
        journalEntries: [SyncJournalEntry],
        remoteRecords: [SyncRecord]
    ) -> Int {
        let localEvidence: [ClassificationEvidence] =
            journalEntries.compactMap { entry in
            guard entry.state != .uploaded,
                  entry.entityType.isClassificationEvidence,
                  let record = try? materializer.record(
                      for: entry,
                      in: snapshot
                  ),
                  canonicalClassificationEvidence(record) != nil
            else {
                return nil
            }
            return ClassificationEvidence(record: record)
        }
        let remoteEvidence = remoteRecords.compactMap(
            canonicalRemoteClassificationEvidence
        )
        let evidence = localEvidence + remoteEvidence
        let localState = snapshot.classifications
        let requiredCount = localState.changeRecords.count
            + localState.snapshotEventsByTraceID.values
            .reduce(0) { $0 + $1.count }
        guard requiredCount > 0 else {
            return 0
        }

        let successorRecords: [SyncRecord] = evidence.compactMap {
            item in
            switch item.type {
            case .classificationCommit:
                guard let envelope = try? mapper
                    .decodeClassificationCommit(item.record),
                    localState.changeRecords.contains(
                        envelope.changeRecord
                    )
                else {
                    return nil
                }
                return item.record
            case .traceClassificationEvent:
                guard let envelope = try? mapper
                    .decodeTraceClassificationEvent(item.record),
                    localState.snapshotEventsByTraceID[
                        envelope.event.traceID
                    ]?.contains(envelope.event) == true
                else {
                    return nil
                }
                return item.record
            case .classificationBaseline, .day, .taskCycleSeries,
                 .taskChain, .taskDefinition, .dayTrace, .subtask,
                 .ideaEntry, .appPreferences:
                return nil
            }
        }
        let baselineRecords: [SyncRecord] = evidence.compactMap { item in
            guard item.type == .classificationBaseline,
                  let envelope = try? mapper.decodeClassificationBaseline(
                      item.record
                  ),
                  let baselineState = try? envelope
                  .classificationState(),
                  localState.containsClassificationHistory(
                      from: baselineState
                  ) || baselineState.containsClassificationHistory(
                      from: localState
                  )
            else {
                return nil
            }
            return item.record
        }
        guard let scaffolding = receiverScaffoldingSnapshot(
            for: snapshot
        ) else {
            return requiredCount
        }
        let candidates: [SyncRecord?] = [SyncRecord?.none]
            + baselineRecords.map { Optional($0) }
        let reconstructsCurrentState = candidates.contains { baseline in
            classificationEvidenceReconstructsCurrentState(
                baseline: baseline,
                successors: successorRecords,
                scaffolding: scaffolding,
                expected: localState
            )
        }
        return reconstructsCurrentState ? 0 : requiredCount
    }

    private func canonicalRemoteClassificationEvidence(
        _ record: SyncRecord
    ) -> ClassificationEvidence? {
        guard record.operation == .upsert else {
            return nil
        }
        return canonicalClassificationEvidence(record)
    }

    private func canonicalClassificationEvidence(
        _ record: SyncRecord
    ) -> ClassificationEvidence? {
        switch record.entityType {
        case .classificationBaseline:
            guard (try? mapper.decodeClassificationBaseline(record))
                != nil
            else {
                return nil
            }
        case .classificationCommit:
            guard (try? mapper.decodeClassificationCommit(record))
                != nil
            else {
                return nil
            }
        case .traceClassificationEvent:
            guard (try? mapper.decodeTraceClassificationEvent(record))
                != nil
            else {
                return nil
            }
        case .day, .taskCycleSeries, .taskChain, .taskDefinition,
             .dayTrace, .subtask, .ideaEntry, .appPreferences:
            return nil
        }
        return ClassificationEvidence(record: record)
    }

    private func classificationEvidenceReconstructsCurrentState(
        baseline: SyncRecord?,
        successors: [SyncRecord],
        scaffolding: NoonmarkSnapshot,
        expected: TaskClassificationState
    ) -> Bool {
        var evidence: [SyncRecord] = []
        if let baseline {
            evidence.append(baseline)
        }
        evidence.append(contentsOf: successors)
        guard let result = try? merger.merge(
            records: evidence,
            into: scaffolding,
            detectedAt: Date(timeIntervalSinceReferenceDate: 0)
        ) else {
            return false
        }
        return result.snapshot.classifications == expected
    }

    private func receiverScaffoldingSnapshot(
        for snapshot: NoonmarkSnapshot
    ) -> NoonmarkSnapshot? {
        let state = snapshot.classifications
        var chainIDs = Set(state.currentByChainID.keys)
        chainIDs.formUnion(state.relationHistory.map(\.chainID))
        var traceIDs = Set(state.snapshotsByTraceID.keys)
        traceIDs.formUnion(state.snapshotEventsByTraceID.keys)

        for current in state.currentByChainID.values {
            if let inherited = current.category?.source
                .inheritedTaskChainID
            {
                chainIDs.insert(inherited)
            }
            chainIDs.formUnion(
                current.labels.compactMap {
                    $0.source.inheritedTaskChainID
                }
            )
        }
        for history in state.relationHistory {
            if let inherited = history.originSource
                .inheritedTaskChainID
            {
                chainIDs.insert(inherited)
            }
            if let inherited = history.removedBySource
                .inheritedTaskChainID
            {
                chainIDs.insert(inherited)
            }
        }
        for record in state.changeRecords {
            if let inherited = record.source.inheritedTaskChainID {
                chainIDs.insert(inherited)
            }
            for change in record.changes {
                switch change {
                case let .setCurrent(chainID, _, _):
                    chainIDs.insert(chainID)
                case let .merge(
                    _,
                    _,
                    _,
                    _,
                    _,
                    _,
                    impact
                ):
                    chainIDs.formUnion(impact.currentChainIDs)
                    traceIDs.formUnion(impact.historicalTraceIDs)
                case .create, .hardDelete, .rename, .lifecycle,
                     .categoryPresentationApproval:
                    continue
                }
            }
        }

        let sourceTraces = Dictionary(
            uniqueKeysWithValues: snapshot.traces.map { ($0.id, $0) }
        )
        let requiredSourceTraces = traceIDs.compactMap {
            sourceTraces[$0]
        }
        guard requiredSourceTraces.count == traceIDs.count else {
            return nil
        }
        chainIDs.formUnion(requiredSourceTraces.map(\.chainID))
        let moment = Date(timeIntervalSinceReferenceDate: 0)
        let orderedChainIDs = chainIDs.sorted {
            $0.description < $1.description
        }
        let definitionIDsByChain = Dictionary(
            uniqueKeysWithValues: orderedChainIDs.map {
                ($0, TaskDefinitionID($0.rawValue))
            }
        )
        let chains = orderedChainIDs.map {
            TaskChain(id: $0, now: moment)
        }
        let definitions = orderedChainIDs.compactMap { chainID in
            definitionIDsByChain[chainID].map {
                TaskDefinition(
                    id: $0,
                    chainID: chainID,
                    sequence: 1,
                    title: "classification coverage receiver",
                    now: moment
                )
            }
        }
        let orderedSourceTraces = requiredSourceTraces.sorted {
            $0.id.description < $1.id.description
        }
        var nextPriorityByDate: [LocalDate: Int] = [:]
        let traces: [DayTrace] = orderedSourceTraces.compactMap {
            source in
            guard let definitionID =
                definitionIDsByChain[source.chainID]
            else {
                return nil
            }
            let priority = nextPriorityByDate[source.date, default: 0]
            nextPriorityByDate[source.date] = priority + 1
            var trace = DayTrace(
                id: source.id,
                chainID: source.chainID,
                definitionID: definitionID,
                date: source.date,
                status: .completed,
                priority: priority,
                now: moment
            )
            trace.completedAt = moment
            return trace
        }
        guard traces.count == requiredSourceTraces.count else {
            return nil
        }
        let days = Set(traces.map(\.date))
            .sorted()
            .map { Day(date: $0, now: moment) }
        let scaffolding = NoonmarkSnapshot(
            days: days,
            chains: chains,
            definitions: definitions,
            traces: traces,
            subtasks: [],
            preferences: AppPreferences(),
            classifications: TaskClassificationState()
        )
        guard (try? scaffolding.validateIntegrity()) != nil else {
            return nil
        }
        return scaffolding
    }
}

private extension SyncEntityType {
    var isClassificationEvidence: Bool {
        switch self {
        case .classificationBaseline, .classificationCommit,
             .traceClassificationEvent:
            true
        case .day, .taskCycleSeries, .taskChain, .taskDefinition,
             .dayTrace, .subtask, .ideaEntry, .appPreferences:
            false
        }
    }
}

private extension ClassificationSource {
    var inheritedTaskChainID: TaskChainID? {
        guard case let .inherited(fromChainID) = self else {
            return nil
        }
        return fromChainID
    }
}

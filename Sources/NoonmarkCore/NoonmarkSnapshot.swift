import Foundation

public struct NoonmarkSnapshot: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case days
        case chains
        case definitions
        case traces
        case subtasks
        case preferences
        case classifications
    }

    public var days: [Day]
    public var chains: [TaskChain]
    public var definitions: [TaskDefinition]
    public var traces: [DayTrace]
    public var subtasks: [Subtask]
    public var preferences: AppPreferences
    public var classifications: TaskClassificationState

    public init(
        days: [Day],
        chains: [TaskChain],
        definitions: [TaskDefinition],
        traces: [DayTrace],
        subtasks: [Subtask],
        preferences: AppPreferences,
        classifications: TaskClassificationState
    ) {
        self.days = days
        self.chains = chains
        self.definitions = definitions
        self.traces = traces
        self.subtasks = subtasks
        self.preferences = preferences
        self.classifications = classifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode([Day].self, forKey: .days)
        chains = try container.decode([TaskChain].self, forKey: .chains)
        definitions = try container.decode([TaskDefinition].self, forKey: .definitions)
        traces = try container.decode([DayTrace].self, forKey: .traces)
        subtasks = try container.decode([Subtask].self, forKey: .subtasks)
        preferences = try container.decode(AppPreferences.self, forKey: .preferences)
        classifications = try container.decode(
            TaskClassificationState.self,
            forKey: .classifications
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
        try container.encode(chains, forKey: .chains)
        try container.encode(definitions, forKey: .definitions)
        try container.encode(traces, forKey: .traces)
        try container.encode(subtasks, forKey: .subtasks)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(classifications, forKey: .classifications)
    }
}

public extension NoonmarkSnapshot {
    func validateIntegrity() throws {
        try classifications.validateIntegrity()

        let chainIDs = Set(chains.map(\.id))
        let traceIDs = Set(traces.map(\.id))
        guard chainIDs.count == chains.count else {
            throw NoonmarkError.invalidInput("snapshot contains duplicate task chain identities")
        }
        guard traceIDs.count == traces.count else {
            throw NoonmarkError.invalidInput("snapshot contains duplicate trace identities")
        }
        for definition in definitions {
            try validateTaskNoteEntries(definition.noteEntries, owner: "task definition")
        }
        for trace in traces {
            try validateTaskNoteEntries(trace.noteEntries, owner: "day trace")
        }
        try validateClassificationReferences(
            chainIDs: chainIDs,
            traceIDs: traceIDs
        )
        try validateCurrentAndHistoricalClassificationSources(chainIDs: chainIDs)
    }

    private func validateTaskNoteEntries(
        _ entries: [TaskNoteEntry],
        owner: String
    ) throws {
        guard Set(entries.map(\.id)).count == entries.count else {
            throw NoonmarkError.invalidInput("\(owner) contains duplicate task note identities")
        }
        for entry in entries {
            guard entry.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  entry.updatedAt >= entry.createdAt
            else {
                throw NoonmarkError.invalidInput("\(owner) contains invalid task note timestamps")
            }
            if let deletedAt = entry.deletedAt {
                guard deletedAt.timeIntervalSinceReferenceDate.isFinite,
                      deletedAt == entry.updatedAt,
                      entry.body.isEmpty
                else {
                    throw NoonmarkError.invalidInput("\(owner) contains an invalid task note tombstone")
                }
            } else {
                let normalizedBody = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard normalizedBody.isEmpty == false, normalizedBody == entry.body else {
                    throw NoonmarkError.invalidInput("\(owner) contains an invalid active task note")
                }
            }
        }
    }

    private func validateClassificationReferences(
        chainIDs: Set<TaskChainID>,
        traceIDs: Set<DayTraceID>
    ) throws {
        guard classifications.currentByChainID.keys.allSatisfy(chainIDs.contains) else {
            throw NoonmarkError.invalidInput("classification references a missing task chain")
        }
        guard classifications.relationHistory.allSatisfy({
            chainIDs.contains($0.chainID)
        }) else {
            throw NoonmarkError.invalidInput("classification history references a missing task chain")
        }
        guard classifications.snapshotsByTraceID.keys.allSatisfy(traceIDs.contains),
              classifications.snapshotEventsByTraceID.keys.allSatisfy(traceIDs.contains)
        else {
            throw NoonmarkError.invalidInput("classification history references a missing trace")
        }

        let historicalEventIDs = Set(
            classifications.snapshotEventsByTraceID.values
                .flatMap { $0 }
                .map(\.id)
        )
        for record in classifications.changeRecords {
            try validateClassificationSource(record.source, chainIDs: chainIDs)
            for change in record.changes {
                try validateClassificationChange(
                    change,
                    chainIDs: chainIDs,
                    traceIDs: traceIDs,
                    historicalEventIDs: historicalEventIDs
                )
            }
        }
    }

    private func validateCurrentAndHistoricalClassificationSources(
        chainIDs: Set<TaskChainID>
    ) throws {
        for current in classifications.currentByChainID.values {
            if let category = current.category {
                try validateClassificationSource(category.source, chainIDs: chainIDs)
            }
            for label in current.labels {
                try validateClassificationSource(label.source, chainIDs: chainIDs)
            }
        }
        for history in classifications.relationHistory {
            try validateClassificationSource(history.originSource, chainIDs: chainIDs)
            try validateClassificationSource(history.removedBySource, chainIDs: chainIDs)
        }
    }

    private func validateClassificationSource(
        _ source: ClassificationSource,
        chainIDs: Set<TaskChainID>
    ) throws {
        guard case let .inherited(fromChainID) = source else { return }
        guard chainIDs.contains(fromChainID) else {
            throw NoonmarkError.invalidInput("classification source references a missing task chain")
        }
    }

    private func validateClassificationChange(
        _ change: ClassificationPlanChange,
        chainIDs: Set<TaskChainID>,
        traceIDs: Set<DayTraceID>,
        historicalEventIDs: Set<UUID>
    ) throws {
        switch change {
        case let .setCurrent(chainID, _, _):
            guard chainIDs.contains(chainID) else {
                throw NoonmarkError.invalidInput("classification audit references a missing task chain")
            }
        case let .merge(_, _, _, _, _, _, impact):
            guard impact.currentChainIDs.allSatisfy(chainIDs.contains),
                  impact.historicalTraceIDs.allSatisfy(traceIDs.contains),
                  impact.historicalEventIDs.allSatisfy(historicalEventIDs.contains)
            else {
                throw NoonmarkError.invalidInput("classification merge impact contains a missing reference")
            }
        case .create, .hardDelete, .rename, .lifecycle:
            break
        }
    }
}

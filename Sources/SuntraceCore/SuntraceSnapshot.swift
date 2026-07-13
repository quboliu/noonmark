import Foundation

public struct SuntraceSnapshot: Codable, Equatable, Sendable {
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

public extension SuntraceSnapshot {
    func validateIntegrity() throws {
        try classifications.validateIntegrity()

        let chainIDs = Set(chains.map(\.id))
        let traceIDs = Set(traces.map(\.id))
        guard chainIDs.count == chains.count else {
            throw SuntraceError.invalidInput("snapshot contains duplicate task chain identities")
        }
        guard traceIDs.count == traces.count else {
            throw SuntraceError.invalidInput("snapshot contains duplicate trace identities")
        }
        try validateClassificationReferences(
            chainIDs: chainIDs,
            traceIDs: traceIDs
        )
        try validateCurrentAndHistoricalClassificationSources(chainIDs: chainIDs)
    }

    private func validateClassificationReferences(
        chainIDs: Set<TaskChainID>,
        traceIDs: Set<DayTraceID>
    ) throws {
        guard classifications.currentByChainID.keys.allSatisfy(chainIDs.contains) else {
            throw SuntraceError.invalidInput("classification references a missing task chain")
        }
        guard classifications.relationHistory.allSatisfy({
            chainIDs.contains($0.chainID)
        }) else {
            throw SuntraceError.invalidInput("classification history references a missing task chain")
        }
        guard classifications.snapshotsByTraceID.keys.allSatisfy(traceIDs.contains),
              classifications.snapshotEventsByTraceID.keys.allSatisfy(traceIDs.contains)
        else {
            throw SuntraceError.invalidInput("classification history references a missing trace")
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
            throw SuntraceError.invalidInput("classification source references a missing task chain")
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
                throw SuntraceError.invalidInput("classification audit references a missing task chain")
            }
        case let .merge(_, _, _, _, _, _, impact):
            guard impact.currentChainIDs.allSatisfy(chainIDs.contains),
                  impact.historicalTraceIDs.allSatisfy(traceIDs.contains),
                  impact.historicalEventIDs.allSatisfy(historicalEventIDs.contains)
            else {
                throw SuntraceError.invalidInput("classification merge impact contains a missing reference")
            }
        case .create, .hardDelete, .rename, .lifecycle:
            break
        }
    }
}

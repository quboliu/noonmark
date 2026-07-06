public struct SuntraceSnapshot: Codable, Equatable, Sendable {
    public var days: [Day]
    public var chains: [TaskChain]
    public var definitions: [TaskDefinition]
    public var traces: [DayTrace]
    public var subtasks: [Subtask]
    public var preferences: AppPreferences

    public init(
        days: [Day],
        chains: [TaskChain],
        definitions: [TaskDefinition],
        traces: [DayTrace],
        subtasks: [Subtask],
        preferences: AppPreferences
    ) {
        self.days = days
        self.chains = chains
        self.definitions = definitions
        self.traces = traces
        self.subtasks = subtasks
        self.preferences = preferences
    }
}

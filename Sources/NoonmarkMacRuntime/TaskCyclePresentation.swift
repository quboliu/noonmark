import NoonmarkCore

public struct TaskCycleCollectionProjector: Sendable {
    public init() {}

    public func tracks(
        _ tracks: [TaskCycleTrack],
        for collection: TaskCycleCollection
    ) -> [TaskCycleTrack] {
        tracks.filter { $0.appears(in: collection) }
    }
}

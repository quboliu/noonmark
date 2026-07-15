import NoonmarkCore
import NoonmarkDayContext

@MainActor
public struct DayRolloverCoordinator {
    public init() {}

    public func reconcile(
        engine: NoonmarkEngine,
        moment: NaturalDayMoment,
        persist: (NoonmarkEngine) throws -> Void
    ) throws -> NoonmarkEngine {
        let candidate = try NoonmarkEngine(snapshot: engine.snapshot())
        try candidate.settleDays(
            upTo: moment.today,
            now: moment.instant
        )
        try persist(candidate)
        return candidate
    }
}

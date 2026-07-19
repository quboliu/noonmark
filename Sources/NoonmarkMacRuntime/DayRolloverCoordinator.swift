import Foundation
import NoonmarkCore
import NoonmarkDayContext

@MainActor
public struct DayRolloverCoordinator {
    public init() {}

    public func reconcile(
        engine: NoonmarkEngine,
        moment: NaturalDayMoment,
        persist: (NoonmarkEngine, Date) throws -> Void
    ) throws -> NoonmarkEngine {
        let sourceSnapshot = engine.snapshot()
        let candidate = try NoonmarkEngine(snapshot: sourceSnapshot)
        let mutationInstant = try candidate.nextMutationDate(
            reference: moment.instant
        )
        try candidate.settleDays(
            upTo: moment.today,
            now: mutationInstant
        )
        if candidate.snapshot() != sourceSnapshot {
            try persist(candidate, mutationInstant)
        }
        return candidate
    }
}

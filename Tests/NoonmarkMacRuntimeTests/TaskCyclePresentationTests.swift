import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class TaskCyclePresentationTests: XCTestCase {
    func testCollectionProjectorKeepsFullTrackAndOnlyChangesSemanticAdmission() {
        let mixed = track(
            title: "混合轨迹",
            states: [.completed, .unfinished, .pendingToday, .planned]
        )
        let completedOnly = track(
            title: "完成轨迹",
            states: [.completed, .completed]
        )
        let projector = TaskCycleCollectionProjector()

        XCTAssertEqual(
            projector.tracks([completedOnly, mixed], for: .future),
            [mixed]
        )
        XCTAssertEqual(
            projector.tracks([completedOnly, mixed], for: .unfinished),
            [mixed]
        )
        XCTAssertEqual(
            projector.tracks([completedOnly, mixed], for: .completed),
            [completedOnly, mixed]
        )
        XCTAssertEqual(
            projector.tracks([mixed], for: .future).first?.days.map(\.state),
            [.completed, .unfinished, .pendingToday, .planned]
        )
    }

    private func track(
        title: String,
        states: [TaskCycleTrackDayState]
    ) -> TaskCycleTrack {
        let dates = [
            LocalDate("2026-07-20"),
            LocalDate("2026-07-21"),
            LocalDate("2026-07-22"),
            LocalDate("2026-07-23"),
        ]
        let days = zip(dates, states).map { date, state in
            TaskCycleTrackDay(
                date: date,
                state: state,
                chainID: state == .notScheduled ? nil : TaskChainID(),
                traceID: state == .notScheduled ? nil : DayTraceID()
            )
        }
        return TaskCycleTrack(
            id: TaskCycleSeriesID(),
            title: title,
            startDate: days.first?.date ?? dates[0],
            endDate: days.last?.date ?? dates[0],
            schedule: .daily,
            days: days
        )
    }
}

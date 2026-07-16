import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class WorkspaceCivilCalendarTests: XCTestCase {
    func testWorkspaceCalendarOwnsMonthGridAndDistanceProjection() throws {
        XCTAssertEqual(
            try WorkspaceCivilCalendar.dayDistance(
                from: LocalDate("2028-02-28"),
                to: LocalDate("2028-03-01")
            ),
            2
        )
        XCTAssertEqual(
            try WorkspaceCivilCalendar.daysInMonth(year: 2028, month: 2),
            29
        )
        XCTAssertEqual(
            try WorkspaceCivilCalendar.mondayLeadBlankCount(
                year: 2026,
                month: 7
            ),
            2
        )
        XCTAssertEqual(
            try WorkspaceCivilCalendar.shiftedMonth(
                from: LocalDate("2026-01-31"),
                by: 1
            ),
            LocalDate("2026-02-01")
        )
    }
}

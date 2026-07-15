import NoonmarkCore
@testable import NoonmarkDayContext
import XCTest

final class GregorianCivilCalendarTests: XCTestCase {
    func testDateOnlyArithmeticCrossesLeapDayWithoutUsingElapsedSeconds() throws {
        let leapDay = try GregorianCivilCalendar.offset(
            LocalDate("2028-02-28"),
            byDays: 1
        )
        XCTAssertEqual(leapDay, LocalDate("2028-02-29"))
        XCTAssertEqual(
            try GregorianCivilCalendar.dayDistance(
                from: LocalDate("2028-02-28"),
                to: LocalDate("2028-03-01")
            ),
            2
        )
    }

    func testMonthMetricsUseMondayAsFirstColumn() throws {
        XCTAssertEqual(
            try GregorianCivilCalendar.daysInMonth(year: 2026, month: 2),
            28
        )
        XCTAssertEqual(
            try GregorianCivilCalendar.mondayLeadBlankCount(
                year: 2026,
                month: 7
            ),
            2
        )
        XCTAssertEqual(
            try GregorianCivilCalendar.shiftedMonth(
                from: LocalDate("2026-01-31"),
                by: 1
            ),
            LocalDate("2026-02-01")
        )
    }

    func testInvalidCivilDateFailsClosed() {
        let invalid = LocalDate(year: 2026, month: 2, day: 31)
        XCTAssertThrowsError(
            try GregorianCivilCalendar.offset(invalid, byDays: 1)
        ) { error in
            XCTAssertEqual(
                error as? NaturalDayFailure,
                .invalidLocalDate(invalid)
            )
        }
    }
}

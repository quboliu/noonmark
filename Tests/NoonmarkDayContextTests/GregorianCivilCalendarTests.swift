import NoonmarkCore
@testable import NoonmarkDayContext
import XCTest

final class GregorianLocalDateArithmeticTests: XCTestCase {
    func testDateOnlyArithmeticCrossesLeapDayWithoutUsingElapsedSeconds() throws {
        let leapDay = try GregorianLocalDateArithmetic.offset(
            LocalDate("2028-02-28"),
            byDays: 1
        )
        XCTAssertEqual(leapDay, LocalDate("2028-02-29"))
        XCTAssertEqual(
            try GregorianLocalDateArithmetic.dayDistance(
                from: LocalDate("2028-02-28"),
                to: LocalDate("2028-03-01")
            ),
            2
        )
    }

    func testMonthMetricsUseMondayAsFirstColumn() throws {
        XCTAssertEqual(
            try GregorianLocalDateArithmetic.daysInMonth(year: 2026, month: 2),
            28
        )
        XCTAssertEqual(
            try GregorianLocalDateArithmetic.mondayLeadBlankCount(
                year: 2026,
                month: 7
            ),
            2
        )
        XCTAssertEqual(
            try GregorianLocalDateArithmetic.shiftedMonth(
                from: LocalDate("2026-01-31"),
                by: 1
            ),
            LocalDate("2026-02-01")
        )
    }

    func testInvalidCivilDateFailsClosed() {
        let invalid = LocalDate(year: 2026, month: 2, day: 31)
        XCTAssertThrowsError(
            try GregorianLocalDateArithmetic.offset(invalid, byDays: 1)
        ) { error in
            XCTAssertEqual(
                error as? NaturalDayFailure,
                .invalidLocalDate(invalid)
            )
        }
    }
}

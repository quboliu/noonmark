import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class WorkspaceMonthGridTests: XCTestCase {
    func testAugust2026UsesMondayFirstSixRowBlankTopology() throws {
        let grid = try WorkspaceMonthGrid(
            monthContaining: LocalDate("2026-08-19"),
            rowCount: .minimum(5),
            outsideMonth: .blank
        )

        XCTAssertEqual(grid.month, LocalDate("2026-08-01"))
        XCTAssertEqual(grid.rowCount, 6)
        XCTAssertEqual(grid.slots.count, 42)
        XCTAssertEqual(grid.slots.prefix(5).map(\.content), Array(repeating: .blank, count: 5))
        XCTAssertEqual(grid.slots[5].row, 0)
        XCTAssertEqual(grid.slots[5].column, 5)
        XCTAssertEqual(
            grid.slots[5],
            WorkspaceMonthGrid.Slot(
                index: 5,
                content: .date(
                    LocalDate("2026-08-01"),
                    isInDisplayedMonth: true
                )
            )
        )
        XCTAssertEqual(
            grid.slots[35].content,
            .date(LocalDate("2026-08-31"), isInDisplayedMonth: true)
        )
        XCTAssertEqual(
            grid.slots.suffix(6).map(\.content),
            Array(repeating: .blank, count: 6)
        )
    }

    func testLeapYearFebruaryIncludesTheTwentyNinth() throws {
        let grid = try WorkspaceMonthGrid(
            monthContaining: LocalDate("2028-02-29"),
            rowCount: .minimum(5),
            outsideMonth: .blank
        )

        XCTAssertEqual(grid.rowCount, 5)
        XCTAssertEqual(
            grid.slots[29].content,
            .date(LocalDate("2028-02-29"), isInDisplayedMonth: true)
        )
        XCTAssertEqual(
            grid.slots.suffix(5).map(\.content),
            Array(repeating: .blank, count: 5)
        )
    }

    func testMinimumRowsPadsFourWeekMonthAndExpandsForSixWeekMonth() throws {
        let february = try WorkspaceMonthGrid(
            monthContaining: LocalDate("2027-02-01"),
            rowCount: .minimum(5),
            outsideMonth: .blank
        )
        let august = try WorkspaceMonthGrid(
            monthContaining: LocalDate("2026-08-01"),
            rowCount: .minimum(5),
            outsideMonth: .blank
        )

        XCTAssertEqual(february.rowCount, 5)
        XCTAssertEqual(february.slots.count, 35)
        XCTAssertEqual(
            february.slots.suffix(7).map(\.content),
            Array(repeating: .blank, count: 7)
        )
        XCTAssertEqual(august.rowCount, 6)
        XCTAssertEqual(august.slots.count, 42)
    }

    func testFixedSixRowAdjacentDateGridCrossesYearBoundary() throws {
        let grid = try WorkspaceMonthGrid(
            monthContaining: LocalDate("2026-12-15"),
            rowCount: .fixed(6),
            outsideMonth: .adjacentDates
        )

        XCTAssertEqual(grid.rowCount, 6)
        XCTAssertEqual(grid.slots.count, 42)
        XCTAssertEqual(
            grid.slots[0].content,
            .date(LocalDate("2026-11-30"), isInDisplayedMonth: false)
        )
        XCTAssertEqual(
            grid.slots[1].content,
            .date(LocalDate("2026-12-01"), isInDisplayedMonth: true)
        )
        XCTAssertEqual(
            grid.slots[31].content,
            .date(LocalDate("2026-12-31"), isInDisplayedMonth: true)
        )
        XCTAssertEqual(
            grid.slots[32].content,
            .date(LocalDate("2027-01-01"), isInDisplayedMonth: false)
        )
        XCTAssertEqual(
            grid.slots[41].content,
            .date(LocalDate("2027-01-10"), isInDisplayedMonth: false)
        )
    }

    func testFixedRowsFailClosedWhenTheMonthDoesNotFit() {
        XCTAssertThrowsError(
            try WorkspaceMonthGrid(
                monthContaining: LocalDate("2026-08-01"),
                rowCount: .fixed(5),
                outsideMonth: .blank
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceMonthGridError,
                .fixedRowCountTooSmall(requested: 5, required: 6)
            )
        }
    }
}

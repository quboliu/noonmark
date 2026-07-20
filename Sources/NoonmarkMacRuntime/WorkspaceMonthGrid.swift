import NoonmarkCore

package enum WorkspaceMonthGridError: Error, Equatable {
    case fixedRowCountTooSmall(requested: Int, required: Int)
}

package struct WorkspaceMonthGrid: Equatable {
    package enum RowCount: Equatable {
        case minimum(Int)
        case fixed(Int)
    }

    package enum OutsideMonth: Equatable {
        case blank
        case adjacentDates
    }

    package enum SlotContent: Equatable {
        case blank
        case date(LocalDate, isInDisplayedMonth: Bool)
    }

    package struct Slot: Equatable {
        package let index: Int
        package let content: SlotContent

        package var row: Int {
            index / WorkspaceMonthGrid.columnCount
        }

        package var column: Int {
            index % WorkspaceMonthGrid.columnCount
        }

        package init(index: Int, content: SlotContent) {
            self.index = index
            self.content = content
        }
    }

    package static let columnCount = 7

    package let month: LocalDate
    package let rowCount: Int
    package let slots: [Slot]

    package init(
        monthContaining date: LocalDate,
        rowCount: RowCount = .minimum(5),
        outsideMonth: OutsideMonth = .blank
    ) throws {
        let month = LocalDate(year: date.year, month: date.month, day: 1)
        let leadCount = try WorkspaceCivilCalendar.mondayLeadBlankCount(
            year: month.year,
            month: month.month
        )
        let dayCount = try WorkspaceCivilCalendar.daysInMonth(
            year: month.year,
            month: month.month
        )
        let naturalRowCount = (leadCount + dayCount + Self.columnCount - 1) / Self.columnCount
        let resolvedRowCount: Int
        switch rowCount {
        case let .minimum(minimum):
            resolvedRowCount = max(naturalRowCount, minimum)
        case let .fixed(fixed):
            guard fixed >= naturalRowCount else {
                throw WorkspaceMonthGridError.fixedRowCountTooSmall(
                    requested: fixed,
                    required: naturalRowCount
                )
            }
            resolvedRowCount = fixed
        }

        self.month = month
        self.rowCount = resolvedRowCount
        slots = try (0..<(resolvedRowCount * Self.columnCount)).map { index in
            let day = index - leadCount + 1
            let isInDisplayedMonth = (1...dayCount).contains(day)
            let content: SlotContent = if isInDisplayedMonth {
                .date(
                    LocalDate(year: month.year, month: month.month, day: day),
                    isInDisplayedMonth: true
                )
            } else if outsideMonth == .adjacentDates {
                .date(
                    try WorkspaceCivilCalendar.offset(
                        month,
                        byDays: index - leadCount
                    ),
                    isInDisplayedMonth: false
                )
            } else {
                .blank
            }
            return Slot(index: index, content: content)
        }
    }
}

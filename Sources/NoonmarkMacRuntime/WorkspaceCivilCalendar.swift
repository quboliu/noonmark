import NoonmarkCore
import NoonmarkDayContext

package enum WorkspaceCivilCalendar {
    package static func offset(
        _ date: LocalDate,
        byDays days: Int
    ) throws -> LocalDate {
        try GregorianLocalDateArithmetic.offset(date, byDays: days)
    }

    package static func dayDistance(
        from start: LocalDate,
        to end: LocalDate
    ) throws -> Int {
        try GregorianLocalDateArithmetic.dayDistance(from: start, to: end)
    }

    package static func daysInMonth(year: Int, month: Int) throws -> Int {
        try GregorianLocalDateArithmetic.daysInMonth(year: year, month: month)
    }

    package static func mondayLeadBlankCount(
        year: Int,
        month: Int
    ) throws -> Int {
        try GregorianLocalDateArithmetic.mondayLeadBlankCount(
            year: year,
            month: month
        )
    }

    package static func shiftedMonth(
        from date: LocalDate,
        by months: Int
    ) throws -> LocalDate {
        try GregorianLocalDateArithmetic.shiftedMonth(from: date, by: months)
    }
}

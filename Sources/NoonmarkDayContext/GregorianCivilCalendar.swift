import Foundation
import NoonmarkCore

/// Strict date-only Gregorian arithmetic shared by the natural-day runtime and UI.
///
/// The module always calculates in UTC at noon. It never interprets a civil date
/// through the device's current time zone and never substitutes the current time
/// when an invalid date or arithmetic overflow is encountered.
package enum GregorianLocalDateArithmetic {
    package static func offset(
        _ date: LocalDate,
        byDays days: Int
    ) throws -> LocalDate {
        let calendar = calendar
        let base = try foundationDate(from: date)
        guard let shifted = calendar.date(
            byAdding: .day,
            value: days,
            to: base
        ) else {
            throw NaturalDayFailure.dateArithmeticOverflow
        }
        return try localDate(from: shifted)
    }

    package static func dayDistance(
        from start: LocalDate,
        to end: LocalDate
    ) throws -> Int {
        let startDate = try foundationDate(from: start)
        let endDate = try foundationDate(from: end)
        guard let distance = calendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day else {
            throw NaturalDayFailure.dateArithmeticOverflow
        }
        return distance
    }

    package static func daysInMonth(year: Int, month: Int) throws -> Int {
        let first = try foundationDate(
            from: LocalDate(year: year, month: month, day: 1)
        )
        guard let count = calendar.range(
            of: .day,
            in: .month,
            for: first
        )?.count else {
            throw NaturalDayFailure.dateArithmeticOverflow
        }
        return count
    }

    package static func mondayLeadBlankCount(
        year: Int,
        month: Int
    ) throws -> Int {
        let first = try foundationDate(
            from: LocalDate(year: year, month: month, day: 1)
        )
        return (calendar.component(.weekday, from: first) + 5) % 7
    }

    package static func shiftedMonth(
        from date: LocalDate,
        by months: Int
    ) throws -> LocalDate {
        let first = try foundationDate(
            from: LocalDate(year: date.year, month: date.month, day: 1)
        )
        guard let shifted = calendar.date(
            byAdding: .month,
            value: months,
            to: first
        ) else {
            throw NaturalDayFailure.dateArithmeticOverflow
        }
        let result = try localDate(from: shifted)
        return LocalDate(year: result.year, month: result.month, day: 1)
    }

    package static func foundationDate(from date: LocalDate) throws -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = date.year
        components.month = date.month
        components.day = date.day
        components.hour = 12
        guard let result = calendar.date(from: components) else {
            throw NaturalDayFailure.invalidLocalDate(date)
        }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day],
            from: result
        )
        guard roundTrip.year == date.year,
              roundTrip.month == date.month,
              roundTrip.day == date.day
        else {
            throw NaturalDayFailure.invalidLocalDate(date)
        }
        return result
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func localDate(from date: Date) throws -> LocalDate {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw NaturalDayFailure.dateArithmeticOverflow
        }
        let result = LocalDate(year: year, month: month, day: day)
        _ = try foundationDate(from: result)
        return result
    }
}

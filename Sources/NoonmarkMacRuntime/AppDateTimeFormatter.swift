import Foundation
import NoonmarkCore

public enum AppDateTextStyle: Sendable {
    case monthDay
    case fullDate
    case weekday
    case weekdayNarrow
    case monthYear
    case accessibilityFull
}

public enum AppTimeTextStyle: Sendable {
    case shortTime
    case dateAndTime
}

public enum AppDateTimeFormattingError: Error, Equatable, Sendable {
    case invalidLocalDate(LocalDate)
    case unrepresentableInstant
}

public struct AppDateTimeFormatter {
    public let language: AppLanguage
    public let timeZone: TimeZone

    public init(
        language: AppLanguage,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.language = language
        self.timeZone = timeZone
    }

    public func string(
        from localDate: LocalDate,
        style: AppDateTextStyle
    ) throws -> String {
        let date = try foundationDate(from: localDate)
        let formatter = configuredFormatter()
        formatter.dateFormat = dateFormat(for: style)
        return formatter.string(from: date)
    }

    public func string(
        from instant: Date,
        style: AppTimeTextStyle
    ) -> String {
        let formatter = configuredFormatter()
        switch style {
        case .shortTime:
            if language == .chinese {
                formatter.dateFormat = "HH:mm"
            } else {
                formatter.dateStyle = .none
                formatter.timeStyle = .short
            }
        case .dateAndTime:
            if language == .chinese {
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
            } else {
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
            }
        }
        return formatter.string(from: instant)
    }

    /// Locale-aware weekday labels ordered from Monday through Sunday.
    public func narrowWeekdaySymbolsStartingMonday() -> [String] {
        let symbols = configuredFormatter().veryShortWeekdaySymbols ?? []
        guard symbols.count == 7 else { return symbols }
        return Array(symbols.dropFirst()) + [symbols[0]]
    }

    /// Converts a date-only domain value to a stable local-noon Foundation date.
    /// Local noon avoids time-zone transitions that can make local midnight
    /// ambiguous or nonexistent.
    public func foundationDate(from localDate: LocalDate) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = localDate.year
        components.month = localDate.month
        components.day = localDate.day
        components.hour = 12
        guard let date = calendar.date(from: components) else {
            throw AppDateTimeFormattingError.invalidLocalDate(localDate)
        }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == localDate.year,
              roundTrip.month == localDate.month,
              roundTrip.day == localDate.day
        else {
            throw AppDateTimeFormattingError.invalidLocalDate(localDate)
        }
        return date
    }

    /// Converts a Foundation picker value back to the domain's Gregorian
    /// date-only representation in this formatter's time zone.
    public func localDate(from date: Date) throws -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            throw AppDateTimeFormattingError.unrepresentableInstant
        }
        let localDate = LocalDate(year: year, month: month, day: day)
        _ = try foundationDate(from: localDate)
        return localDate
    }

    private var locale: Locale {
        switch language {
        case .chinese:
            Locale(identifier: "zh_Hans_SG")
        case .english:
            Locale(identifier: "en_SG")
        }
    }

    private func configuredFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        return formatter
    }

    private func dateFormat(for style: AppDateTextStyle) -> String {
        switch language {
        case .chinese:
            chineseDateFormat(for: style)
        case .english:
            englishDateFormat(for: style)
        }
    }

    private func chineseDateFormat(for style: AppDateTextStyle) -> String {
        switch style {
        case .monthDay:
            "M月d日"
        case .fullDate:
            "yyyy年M月d日"
        case .weekday:
            "EEE"
        case .weekdayNarrow:
            "EEEEE"
        case .monthYear:
            "yyyy年M月"
        case .accessibilityFull:
            "yyyy年M月d日，EEE"
        }
    }

    private func englishDateFormat(for style: AppDateTextStyle) -> String {
        switch style {
        case .monthDay:
            "d MMM"
        case .fullDate:
            "d MMMM yyyy"
        case .weekday:
            "EEE"
        case .weekdayNarrow:
            "EEEEE"
        case .monthYear:
            "MMMM yyyy"
        case .accessibilityFull:
            "EEEE, d MMMM yyyy"
        }
    }
}

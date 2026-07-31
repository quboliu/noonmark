import Foundation

enum SQLiteISO8601DateCodec {
    private static let formatterThreadKey =
        "app.noonmark.storage.sqlite-iso8601-date-formatter"

    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter().date(from: string)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let dictionary = Thread.current.threadDictionary
        if let formatter = dictionary[formatterThreadKey]
            as? ISO8601DateFormatter
        {
            return formatter
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        dictionary[formatterThreadKey] = formatter
        return formatter
    }
}

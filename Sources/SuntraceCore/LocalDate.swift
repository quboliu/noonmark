import Foundation

public struct LocalDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        precondition((1...12).contains(month), "month must be 1...12")
        precondition((1...31).contains(day), "day must be 1...31")
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ iso8601Date: String) {
        let parts = iso8601Date.split(separator: "-").map(String.init)
        precondition(parts.count == 3, "date must use yyyy-mm-dd")
        self.init(
            year: Int(parts[0])!,
            month: Int(parts[1])!,
            day: Int(parts[2])!
        )
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

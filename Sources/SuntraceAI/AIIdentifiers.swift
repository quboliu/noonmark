import Foundation

public struct AIProviderID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "provider id cannot be empty")
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

public struct AISuggestionDraftID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

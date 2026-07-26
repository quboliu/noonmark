import Foundation
import NoonmarkCore

public struct TaskLabelInputCandidate: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum TaskLabelInputSubmission: Equatable, Sendable {
    case empty
    case existing(id: String)
    case new(name: String)
}

public struct TaskLabelInputQuery: Equatable, Sendable {
    public let rawValue: String
    public let requestsSuggestions: Bool
    public let normalizedName: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        requestsSuggestions = trimmed.hasPrefix("#")
        let withoutTrigger = requestsSuggestions
            ? String(trimmed.dropFirst())
            : trimmed
        normalizedName = ClassificationNameCanonicalizer.displayName(
            withoutTrigger
        )
    }

    public func matchingCandidates(
        in candidates: [TaskLabelInputCandidate]
    ) -> [TaskLabelInputCandidate] {
        guard requestsSuggestions else { return [] }
        guard normalizedName.isEmpty == false else { return candidates }
        let queryKey = ClassificationNameCanonicalizer.canonicalKey(
            normalizedName
        )
        return candidates.filter {
            ClassificationNameCanonicalizer.canonicalKey($0.name)
                .localizedCaseInsensitiveContains(queryKey)
        }
    }

    public func submission(
        in candidates: [TaskLabelInputCandidate]
    ) -> TaskLabelInputSubmission {
        guard normalizedName.isEmpty == false else { return .empty }
        let queryKey = ClassificationNameCanonicalizer.canonicalKey(
            normalizedName
        )
        if let existing = candidates.first(where: {
            ClassificationNameCanonicalizer.canonicalKey($0.name)
                == queryKey
        }) {
            return .existing(id: existing.id)
        }
        return .new(name: normalizedName)
    }
}

import Foundation
import NoonmarkCore

public enum ZhulongConversationArtifactError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidArtifact
    case unsupportedArtifact
}

public struct ZhulongConversationTurn: Equatable, Sendable {
    public let message: String
    public let artifacts: [ZhulongConversationArtifactProposal]

    public init(
        message: String,
        artifacts: [ZhulongConversationArtifactProposal]
    ) {
        self.message = message
        self.artifacts = artifacts
    }
}

public enum ZhulongConversationArtifactProposal: Codable, Equatable, Sendable {
    case taskPlan(ZhulongConversationTaskPlan)
    case dailyReview(ZhulongConversationDailyReview)
}

public struct ZhulongConversationTaskPlan: Codable, Equatable, Sendable {
    public let tasks: [ZhulongConversationTaskDraft]

    public init(tasks: [ZhulongConversationTaskDraft]) throws {
        guard tasks.isEmpty == false else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        self.tasks = tasks
    }

    public func todoDiffItems(
        planningDate: LocalDate
    ) -> [ZhulongTodoDiffItem] {
        tasks.map { task in
            ZhulongTodoDiffItem(
                operation: .createTask(
                    title: task.title,
                    descriptionText: task.descriptionText,
                    initialNoteBody: task.initialNoteBody,
                    plannedSubtasks: task.subtasks,
                    targetDate: task.destination.targetDate(
                        planningDate: planningDate
                    )
                )
            )
        }
    }
}

public struct ZhulongConversationTaskDraft: Codable, Equatable, Sendable {
    public let title: String
    public let descriptionText: String?
    public let initialNoteBody: String?
    public let destination: ZhulongConversationTaskDestination
    public let subtasks: [ZhulongPlannedSubtaskDraft]

    public init(
        title: String,
        descriptionText: String?,
        initialNoteBody: String?,
        destination: ZhulongConversationTaskDestination,
        subtasks: [ZhulongPlannedSubtaskDraft]
    ) throws {
        self.title = try normalizedRequiredArtifactText(title)
        self.descriptionText = try normalizedOptionalArtifactText(
            descriptionText
        )
        self.initialNoteBody = try normalizedOptionalArtifactText(
            initialNoteBody
        )
        self.destination = destination
        self.subtasks = subtasks
    }
}

public enum ZhulongConversationTaskDestination:
    Codable,
    Equatable,
    Sendable
{
    case taskPool
    case today
    case date(LocalDate)

    public func targetDate(planningDate: LocalDate) -> LocalDate? {
        switch self {
        case .taskPool:
            nil
        case .today:
            planningDate
        case let .date(date):
            date
        }
    }
}

public struct ZhulongConversationDailyReview: Codable, Equatable, Sendable {
    public let summary: String?
    public let tomorrowNote: String?

    public init(summary: String?, tomorrowNote: String?) throws {
        let summary = try normalizedOptionalArtifactText(summary)
        let tomorrowNote = try normalizedOptionalArtifactText(tomorrowNote)
        guard summary != nil || tomorrowNote != nil else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        self.summary = summary
        self.tomorrowNote = tomorrowNote
    }
}

public struct ZhulongConversationTurnParser: Sendable {
    public static let openingTag = "<noonmark-artifacts>"
    public static let closingTag = "</noonmark-artifacts>"

    public init() {}

    public func parse(_ content: String) throws -> ZhulongConversationTurn {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ZhulongConversationArtifactError.invalidEnvelope
        }
        guard let openingRange = trimmed.range(
            of: Self.openingTag
        ) else {
            guard trimmed.contains(Self.closingTag) == false else {
                throw ZhulongConversationArtifactError.invalidEnvelope
            }
            return ZhulongConversationTurn(
                message: trimmed,
                artifacts: []
            )
        }
        guard let closingRange = trimmed.range(
            of: Self.closingTag,
            range: openingRange.upperBound ..< trimmed.endIndex
        ) else {
            throw ZhulongConversationArtifactError.invalidEnvelope
        }
        let trailing = trimmed[closingRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty,
              trimmed[openingRange.upperBound ..< closingRange.lowerBound]
              .contains(Self.openingTag) == false
        else {
            throw ZhulongConversationArtifactError.invalidEnvelope
        }
        let message = trimmed[..<openingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false else {
            throw ZhulongConversationArtifactError.invalidEnvelope
        }
        let artifactJSON = String(
            trimmed[openingRange.upperBound ..< closingRange.lowerBound]
        )
        let artifacts = try parseArtifacts(artifactJSON)
        return ZhulongConversationTurn(
            message: message,
            artifacts: artifacts
        )
    }

    public static func visibleMessage(in content: String) -> String {
        if let openingRange = content.range(of: openingTag) {
            return content[..<openingRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var visible = content
        let maximumPrefixLength = min(
            openingTag.count - 1,
            visible.count
        )
        if maximumPrefixLength > 0 {
            for length in stride(
                from: maximumPrefixLength,
                through: 1,
                by: -1
            ) {
                let suffix = visible.suffix(length)
                if openingTag.hasPrefix(suffix) {
                    visible.removeLast(length)
                    break
                }
            }
        }
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseArtifacts(
        _ content: String
    ) throws -> [ZhulongConversationArtifactProposal] {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["artifacts"],
              let artifacts = dictionary["artifacts"] as? [[String: Any]],
              artifacts.isEmpty == false
        else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        return try artifacts.map(parseArtifact)
    }

    private func parseArtifact(
        _ object: [String: Any]
    ) throws -> ZhulongConversationArtifactProposal {
        guard let kind = object["kind"] as? String else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        switch kind {
        case "taskPlan":
            return .taskPlan(
                try parseTaskPlan(object)
            )
        case "dailyReview":
            return .dailyReview(
                try parseDailyReview(object)
            )
        default:
            throw ZhulongConversationArtifactError.unsupportedArtifact
        }
    }

    private func parseTaskPlan(
        _ object: [String: Any]
    ) throws -> ZhulongConversationTaskPlan {
        guard Set(object.keys) == ["kind", "tasks"],
              let tasks = object["tasks"] as? [[String: Any]]
        else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        return try ZhulongConversationTaskPlan(
            tasks: tasks.map(parseTask)
        )
    }

    private func parseTask(
        _ object: [String: Any]
    ) throws -> ZhulongConversationTaskDraft {
        let required = Set([
            "title",
            "description",
            "note",
            "destination",
            "subtasks"
        ])
        guard Set(object.keys) == required,
              let title = object["title"] as? String,
              let destination = object["destination"] as? [String: Any],
              let subtasks = object["subtasks"] as? [[String: Any]]
        else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        return try ZhulongConversationTaskDraft(
            title: title,
            descriptionText: try optionalString(
                in: object,
                key: "description"
            ),
            initialNoteBody: try optionalString(
                in: object,
                key: "note"
            ),
            destination: try parseDestination(destination),
            subtasks: subtasks.map(parseSubtask)
        )
    }

    private func parseDestination(
        _ object: [String: Any]
    ) throws -> ZhulongConversationTaskDestination {
        guard let kind = object["kind"] as? String else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        switch kind {
        case "pool":
            guard Set(object.keys) == ["kind"] else {
                throw ZhulongConversationArtifactError.invalidArtifact
            }
            return .taskPool
        case "today":
            guard Set(object.keys) == ["kind"] else {
                throw ZhulongConversationArtifactError.invalidArtifact
            }
            return .today
        case "date":
            guard Set(object.keys) == ["kind", "date"],
                  let value = object["date"] as? String,
                  let date = LocalDate(
                      validatingISO8601Date: value
                  )
            else {
                throw ZhulongConversationArtifactError.invalidArtifact
            }
            return .date(date)
        default:
            throw ZhulongConversationArtifactError.invalidArtifact
        }
    }

    private func parseSubtask(
        _ object: [String: Any]
    ) throws -> ZhulongPlannedSubtaskDraft {
        guard Set(object.keys) == ["title", "difficulty"],
              let title = object["title"] as? String,
              let rawDifficulty = object["difficulty"] as? String,
              let difficulty = difficulty(rawDifficulty)
        else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        return try ZhulongPlannedSubtaskDraft(
            title: title,
            difficulty: difficulty
        )
    }

    private func parseDailyReview(
        _ object: [String: Any]
    ) throws -> ZhulongConversationDailyReview {
        guard Set(object.keys) == [
            "kind",
            "summary",
            "tomorrowNote"
        ] else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        return try ZhulongConversationDailyReview(
            summary: try optionalString(
                in: object,
                key: "summary"
            ),
            tomorrowNote: try optionalString(
                in: object,
                key: "tomorrowNote"
            )
        )
    }

    private func optionalString(
        in object: [String: Any],
        key: String
    ) throws -> String? {
        guard let value = object[key] else {
            throw ZhulongConversationArtifactError.invalidArtifact
        }
        switch value {
        case is NSNull:
            return nil
        case let value as String:
            return value
        default:
            throw ZhulongConversationArtifactError.invalidArtifact
        }
    }

    private func difficulty(_ value: String) -> SubtaskDifficulty? {
        switch value {
        case "simple":
            .simple
        case "medium":
            .medium
        case "hard":
            .hard
        default:
            nil
        }
    }
}

private func normalizedRequiredArtifactText(
    _ value: String
) throws -> String {
    let normalized = value.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    guard normalized.isEmpty == false else {
        throw ZhulongConversationArtifactError.invalidArtifact
    }
    return normalized
}

private func normalizedOptionalArtifactText(
    _ value: String?
) throws -> String? {
    guard let value else {
        return nil
    }
    let normalized = value.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    return normalized.isEmpty ? nil : normalized
}

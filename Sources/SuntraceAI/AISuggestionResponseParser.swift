import Foundation
import SuntraceCore

public enum AISuggestionResponseParseError: Error, Equatable, Sendable {
    case invalidJSON
    case missingSummary
    case unsupportedOperation(String)
    case invalidOperation(String)
}

public struct AISuggestionResponseParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> AIProviderResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else {
            return AIProviderResponse(text: trimmed)
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw AISuggestionResponseParseError.invalidJSON
        }

        let payload: StructuredSuggestionPayload
        do {
            payload = try JSONDecoder().decode(StructuredSuggestionPayload.self, from: data)
        } catch {
            throw AISuggestionResponseParseError.invalidJSON
        }

        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.isEmpty == false else {
            throw AISuggestionResponseParseError.missingSummary
        }

        return AIProviderResponse(
            text: summary,
            proposedOperations: try payload.proposedOperations.map(decodeOperation),
            confidence: payload.confidence
        )
    }

    private func decodeOperation(_ operation: StructuredSuggestionOperation) throws -> AIProposedOperation {
        switch operation.type {
        case "createPoolTask":
            guard let title = operation.title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false else {
                throw AISuggestionResponseParseError.invalidOperation("createPoolTask.title")
            }
            return .createPoolTask(
                title: title,
                descriptionText: operation.descriptionText,
                note: operation.note
            )

        case "updateDailyReview":
            guard let dateText = operation.date, let date = localDate(from: dateText) else {
                throw AISuggestionResponseParseError.invalidOperation("updateDailyReview.date")
            }
            return .updateDailyReview(
                date: date,
                summary: operation.summary,
                unfinishedReason: operation.unfinishedReason,
                tomorrowNote: operation.tomorrowNote
            )

        default:
            throw AISuggestionResponseParseError.unsupportedOperation(operation.type)
        }
    }

    private func localDate(from text: String) -> LocalDate? {
        let parts = text.split(separator: "-").map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else {
            return nil
        }
        return LocalDate(year: year, month: month, day: day)
    }
}

private struct StructuredSuggestionPayload: Decodable {
    var summary: String
    var confidence: Double?
    var proposedOperations: [StructuredSuggestionOperation]

    enum CodingKeys: String, CodingKey {
        case summary
        case confidence
        case proposedOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        proposedOperations = try container.decodeIfPresent([StructuredSuggestionOperation].self, forKey: .proposedOperations) ?? []
    }
}

private struct StructuredSuggestionOperation: Decodable {
    var type: String
    var title: String?
    var descriptionText: String?
    var note: String?
    var date: String?
    var summary: String?
    var unfinishedReason: String?
    var tomorrowNote: String?
}

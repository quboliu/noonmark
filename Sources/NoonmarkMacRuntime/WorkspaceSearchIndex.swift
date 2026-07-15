import Foundation
import NoonmarkCore

public enum WorkspaceSearchDestination: Hashable, Sendable {
    case trace(id: DayTraceID, date: LocalDate, status: TraceStatus)
    case pool(chainID: TaskChainID)
    case subtask(
        id: SubtaskID,
        parentTraceID: DayTraceID,
        date: LocalDate,
        parentStatus: TraceStatus
    )
}

public enum WorkspaceSearchResultKind: Hashable, Sendable {
    case task
    case poolTask
    case subtask
}

public struct WorkspaceSearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: WorkspaceSearchResultKind
    public let title: String
    public let context: String?
    public let destination: WorkspaceSearchDestination

    public init(
        id: String,
        kind: WorkspaceSearchResultKind,
        title: String,
        context: String?,
        destination: WorkspaceSearchDestination
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.context = context
        self.destination = destination
    }
}

/// A read-only, session-local index over the user's current engine state.
/// The public interface deliberately exposes destinations rather than page
/// decisions; the Mac command layer owns how a result is revealed.
public struct WorkspaceSearchIndex: Sendable {
    private struct IndexedEntry {
        let result: WorkspaceSearchResult
        let normalizedTitle: String
        let normalizedContext: String
        let recency: Date
    }

    private let entries: [IndexedEntry]

    public init(engine: NoonmarkEngine) {
        var entries: [IndexedEntry] = []

        for task in engine.taskPool() {
            let contextParts: [String?] = [
                task.definition.descriptionText,
                task.chain.activeNoteEntries.map(\.body).joined(separator: " "),
                task.definition.plannedSubtasks.map(\.title).joined(separator: " ")
            ]
            let context = Self.joinedContext(contextParts)
            let result = WorkspaceSearchResult(
                id: "pool-\(task.chain.id.description)",
                kind: .poolTask,
                title: task.definition.title,
                context: context,
                destination: .pool(chainID: task.chain.id)
            )
            entries.append(Self.indexed(result, recency: task.definition.contentUpdatedAt))
        }

        for trace in engine.traces.values {
            guard let definition = engine.definitions[trace.definitionID] else { continue }
            let actualSubtasks = engine.subtasks.values
                .filter { $0.traceID == trace.id }
                .sorted { $0.position < $1.position }
            let chainNotes = engine.chains[trace.chainID]?.activeNoteEntries ?? []
            let contextParts: [String?] = [
                definition.descriptionText,
                trace.descriptionText,
                trace.activeNoteEntries.map(\.body).joined(separator: " "),
                chainNotes.map(\.body).joined(separator: " "),
                actualSubtasks.map(\.title).joined(separator: " ")
            ]
            let context = Self.joinedContext(contextParts)
            let result = WorkspaceSearchResult(
                id: "trace-\(trace.id.description)",
                kind: .task,
                title: definition.title,
                context: context,
                destination: .trace(
                    id: trace.id,
                    date: trace.date,
                    status: trace.status
                )
            )
            entries.append(Self.indexed(result, recency: trace.contentUpdatedAt))

            for subtask in actualSubtasks {
                let subtaskResult = WorkspaceSearchResult(
                    id: "subtask-\(subtask.id.description)",
                    kind: .subtask,
                    title: subtask.title,
                    context: definition.title,
                    destination: .subtask(
                        id: subtask.id,
                        parentTraceID: trace.id,
                        date: trace.date,
                        parentStatus: trace.status
                    )
                )
                entries.append(Self.indexed(subtaskResult, recency: subtask.createdAt))
            }
        }

        self.entries = entries
    }

    public func search(_ query: String, limit: Int = 50) -> [WorkspaceSearchResult] {
        let tokens = Self.normalized(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0.isEmpty == false }
        guard tokens.isEmpty == false, limit > 0 else { return [] }

        return entries.compactMap { entry -> (IndexedEntry, Int)? in
            guard tokens.allSatisfy({ token in
                entry.normalizedTitle.contains(token)
                    || entry.normalizedContext.contains(token)
            }) else { return nil }

            let score = tokens.reduce(into: 0) { score, token in
                if entry.normalizedTitle == token {
                    score += 120
                } else if entry.normalizedTitle.hasPrefix(token) {
                    score += 90
                } else if entry.normalizedTitle.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(token) }) {
                    score += 70
                } else if entry.normalizedTitle.contains(token) {
                    score += 50
                } else {
                    score += 20
                }
            }
            return (entry, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.recency != rhs.0.recency {
                return lhs.0.recency > rhs.0.recency
            }
            return lhs.0.result.title.localizedStandardCompare(
                rhs.0.result.title
            ) == .orderedAscending
        }
        .prefix(limit)
        .map(\.0.result)
    }

    private static func indexed(
        _ result: WorkspaceSearchResult,
        recency: Date
    ) -> IndexedEntry {
        IndexedEntry(
            result: result,
            normalizedTitle: normalized(result.title),
            normalizedContext: normalized(result.context ?? ""),
            recency: recency
        )
    }

    private static func joinedContext(_ parts: [String?]) -> String? {
        let values = parts.compactMap { part -> String? in
            let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

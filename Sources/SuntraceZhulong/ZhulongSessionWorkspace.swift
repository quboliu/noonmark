import Foundation

public struct ZhulongSessionEntryID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ZhulongSessionEntryAuthor: String, Codable, Equatable, Sendable {
    case user
    case zhulong
}

public enum ZhulongSessionEntryKind: String, Codable, Equatable, Sendable {
    case statement
    case question
    case answer
    case decision
    case correction
}

public struct ZhulongSessionEntry: Codable, Equatable, Sendable {
    public let id: ZhulongSessionEntryID
    public let author: ZhulongSessionEntryAuthor
    public let kind: ZhulongSessionEntryKind
    public let content: String
    public let createdAt: Date
    public let correctsEntryID: ZhulongSessionEntryID?
}

public enum ZhulongWorkspaceStatus: String, Codable, Equatable, Sendable {
    case active
    case paused
    case archived
}

public enum ZhulongSessionEventReference: Codable, Equatable, Sendable {
    case providerRun(ZhulongProviderRunID)
    case sessionEntry(ZhulongSessionEntryID)
}

public extension ZhulongSession {
    @discardableResult
    mutating func appendEntry(
        author: ZhulongSessionEntryAuthor,
        kind: ZhulongSessionEntryKind,
        content: String,
        now: Date = Date()
    ) throws -> ZhulongSessionEntry {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard kind != .correction else {
            throw ZhulongSessionError.correctionRequiresTarget
        }
        let normalized = try normalizedEntryContent(content)
        try validateActivityTime(now)
        let entry = ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: author,
            kind: kind,
            content: normalized,
            createdAt: now,
            correctsEntryID: nil
        )
        entries.append(entry)
        return entry
    }

    @discardableResult
    mutating func correctEntry(
        _ targetID: ZhulongSessionEntryID,
        author: ZhulongSessionEntryAuthor,
        replacementContent: String,
        now: Date = Date()
    ) throws -> ZhulongSessionEntry {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.workspaceInactive
        }
        guard let target = entries.first(where: { $0.id == targetID }) else {
            throw ZhulongSessionError.missingCorrectionTarget
        }
        guard target.correctsEntryID == nil else {
            throw ZhulongSessionError.correctionTargetIsCorrection
        }
        let normalized = try normalizedEntryContent(replacementContent)
        try validateActivityTime(now)
        let correction = ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: author,
            kind: .correction,
            content: normalized,
            createdAt: now,
            correctsEntryID: targetID
        )
        entries.append(correction)
        appendEvent(
            .sessionCorrected,
            summary: "已追加会话更正",
            reference: .sessionEntry(correction.id),
            now: now
        )
        return correction
    }

    func effectiveContent(for entryID: ZhulongSessionEntryID) -> String? {
        guard let original = entries.first(where: { $0.id == entryID }) else { return nil }
        return entries.last(where: { $0.correctsEntryID == entryID })?.content ?? original.content
    }

    mutating func pause(now: Date = Date()) throws {
        guard workspaceStatus == .active else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateActivityTime(now)
        workspaceStatus = .paused
        appendEvent(.sessionPaused, summary: "会话已暂停", now: now)
    }

    mutating func resume(now: Date = Date()) throws {
        guard workspaceStatus == .paused else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        try validateActivityTime(now)
        workspaceStatus = .active
        appendEvent(.sessionResumed, summary: "会话已恢复", now: now)
    }

    mutating func archive(now: Date = Date()) throws {
        guard workspaceStatus != .archived else {
            throw ZhulongSessionError.invalidWorkspaceTransition
        }
        guard phase != .providerRunning else {
            throw ZhulongSessionError.providerRunStillActive
        }
        try validateActivityTime(now)
        workspaceStatus = .archived
        appendEvent(.sessionArchived, summary: "会话已归档", now: now)
    }

    private func normalizedEntryContent(_ content: String) throws -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            throw ZhulongSessionError.emptySessionEntry
        }
        return normalized
    }
}

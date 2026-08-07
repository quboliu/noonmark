import Foundation

/// Serializes durable edits to user-editable Zhulong drafts away from the UI
/// actor.
///
/// Every commit reloads the authoritative encrypted session before applying
/// the edit. A stale UI draft may advance across user-authored revisions, but
/// never across a Provider revision or a completed application boundary.
public actor ZhulongDraftPersistenceLane {
    public struct TodoDiffCommit: Sendable {
        public let session: ZhulongSession
        public let draftID: ZhulongTodoDiffID
        public let wroteRevision: Bool
    }

    public struct DailyReviewCommit: Sendable {
        public let session: ZhulongSession
        public let draftID: ZhulongDailyReviewDraftID
        public let wroteRevision: Bool
    }

    private let repository: any ZhulongSessionRepository

    public init(repository: any ZhulongSessionRepository) {
        self.repository = repository
    }

    public func reviseTodoDiff(
        sessionID: ZhulongSessionID,
        sourceDraftID: ZhulongTodoDiffID,
        items: [ZhulongTodoDiffItem],
        now: Date = Date()
    ) throws -> TodoDiffCommit {
        let commit = try commit(
            sessionID: sessionID
        ) { session in
            guard let source = session.todoDiffDrafts.first(
                where: { $0.id == sourceDraftID }
            ), let current = session.currentTodoDiff,
            currentDescendsThroughUserRevisions(
                current,
                from: source,
                drafts: session.todoDiffDrafts
            )
            else {
                throw ZhulongTodoDiffError
                    .sessionBindingMismatch
            }
            guard current.items != items else {
                return (current.id, false)
            }
            let revisionDate = strictlyAfter(
                max(now, session.latestActivityAt)
            )
            let revision = try ZhulongTodoDiffDraft(
                revising: current,
                createdAt: revisionDate,
                items: items
            )
            try session.reviseTodoDiff(
                revision,
                now: revisionDate
            )
            return (revision.id, true)
        }
        return TodoDiffCommit(
            session: commit.session,
            draftID: commit.result,
            wroteRevision: commit.changed
        )
    }

    public func reviseDailyReview(
        sessionID: ZhulongSessionID,
        sourceDraftID: ZhulongDailyReviewDraftID,
        summary: String?,
        tomorrowNote: String?,
        now: Date = Date()
    ) throws -> DailyReviewCommit {
        let commit = try commit(
            sessionID: sessionID
        ) { session in
            guard let source = session.dailyReviewDrafts.first(
                where: { $0.id == sourceDraftID }
            ), let current = session.dailyReviewDrafts.last,
            current.dailyCloseID == source.dailyCloseID,
            session.dailyReviewReceipts.contains(
                where: { $0.draftID == current.id }
            ) == false
            else {
                throw ZhulongDailyCloseError.invalidReviewDraft
            }
            let normalizedSummary = normalized(summary)
            let normalizedTomorrowNote = normalized(
                tomorrowNote
            )
            guard current.summary != normalizedSummary
                || current.tomorrowNote
                != normalizedTomorrowNote
            else {
                return (current.id, false)
            }
            let revisionDate = strictlyAfter(
                max(now, session.latestActivityAt)
            )
            let revision = try session.publishDailyReviewDraft(
                dailyCloseID: current.dailyCloseID,
                summary: normalizedSummary,
                tomorrowNote: normalizedTomorrowNote,
                causeResolutionIDs:
                current.confirmedCauseResolutionIDs,
                now: revisionDate
            )
            return (revision.id, true)
        }
        return DailyReviewCommit(
            session: commit.session,
            draftID: commit.result,
            wroteRevision: commit.changed
        )
    }

    /// Waits for every draft commit enqueued before this call.
    public func drain() {}

    public func load(
        sessionID: ZhulongSessionID
    ) throws -> ZhulongSession {
        try repository.load(sessionID)
    }

    private func commit<Result: Sendable>(
        sessionID: ZhulongSessionID,
        operation: (inout ZhulongSession) throws
            -> (Result, Bool)
    ) throws -> (
        session: ZhulongSession,
        result: Result,
        changed: Bool
    ) {
        var conflictCount = 0
        while true {
            let expected = try repository.load(sessionID)
            var candidate = expected
            let (result, changed) = try operation(&candidate)
            guard changed else {
                return (expected, result, false)
            }
            do {
                try repository.save(
                    candidate,
                    replacing: expected
                )
                return (candidate, result, true)
            } catch let conflict
                as ZhulongSidecarRepositoryError
                where conflict == .sessionConflict
            {
                conflictCount += 1
                guard conflictCount < 3 else {
                    throw conflict
                }
            }
        }
    }

    private func currentDescendsThroughUserRevisions(
        _ current: ZhulongTodoDiffDraft,
        from source: ZhulongTodoDiffDraft,
        drafts: [ZhulongTodoDiffDraft]
    ) -> Bool {
        if current.id == source.id {
            return true
        }
        let byID = Dictionary(
            uniqueKeysWithValues: drafts.map { ($0.id, $0) }
        )
        var cursor = current
        while cursor.id != source.id {
            guard case let .userRevision(parentID, _) =
                cursor.source,
                let parent = byID[parentID]
            else {
                return false
            }
            cursor = parent
        }
        return true
    }

    private func strictlyAfter(_ date: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate:
            date.timeIntervalSinceReferenceDate.nextUp
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }
}

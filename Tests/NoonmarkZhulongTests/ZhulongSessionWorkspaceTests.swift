@testable import NoonmarkZhulong
import XCTest

final class ZhulongSessionWorkspaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSessionStartsWithImmutablePrimaryIntentEntryAndAppendsConversation() throws {
        var session = try makeSession()

        let question = try session.appendEntry(
            author: .zhulong,
            kind: .question,
            content: "你认为什么结果才算完成？",
            now: now.addingTimeInterval(1)
        )
        let answer = try session.appendEntry(
            author: .user,
            kind: .answer,
            content: "完成可交付版本并通过验收。",
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(session.entries.map(\.content), [
            "规划发布新版",
            "你认为什么结果才算完成？",
            "完成可交付版本并通过验收。"
        ])
        XCTAssertEqual(question.author, .zhulong)
        XCTAssertEqual(answer.kind, .answer)
    }

    func testDecisionAddsContentFreeLinkedAuditEvent() throws {
        var session = try makeSession()

        let decision = try session.appendEntry(
            author: .user,
            kind: .decision,
            content: "先保证离线能力，再接远程同步。",
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(session.events.last?.kind, .sessionDecisionRecorded)
        XCTAssertEqual(session.events.last?.sessionEntryID, decision.id)
        XCTAssertEqual(session.events.last?.summary, "已记录用户决定")
        XCTAssertFalse(session.events.last?.summary.contains("离线") == true)
    }

    func testCorrectionAppendsWithoutRewritingOriginalAndEffectiveViewUsesLatest() throws {
        var session = try makeSession()
        let answer = try session.appendEntry(
            author: .user,
            kind: .answer,
            content: "周五完成。",
            now: now.addingTimeInterval(1)
        )

        let correction = try session.correctEntry(
            answer.id,
            author: .user,
            replacementContent: "下周一完成。",
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(session.entries[1].content, "周五完成。")
        XCTAssertEqual(correction.correctsEntryID, answer.id)
        XCTAssertEqual(session.effectiveContent(for: answer.id), "下周一完成。")
        XCTAssertEqual(session.events.last?.kind, .sessionCorrected)
        XCTAssertEqual(session.events.last?.sessionEntryID, correction.id)
        XCTAssertFalse(session.events.last?.summary.contains("下周一") == true)
    }

    func testCorrectingInitialIntentChangesTheEffectivePrimaryIntent() throws {
        var session = try makeSession()

        _ = try session.correctEntry(
            session.entries[0].id,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(session.initialPrimaryIntent, "规划发布新版")
        XCTAssertEqual(session.primaryIntent, "规划发布稳定版")
    }

    func testCorrectionRejectsMissingOrCorrectionTargetsWithoutMutation() throws {
        var session = try makeSession()
        let originalEntries = session.entries

        XCTAssertThrowsError(
            try session.correctEntry(
                ZhulongSessionEntryID(),
                author: .user,
                replacementContent: "不存在",
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .missingCorrectionTarget)
        }
        XCTAssertEqual(session.entries, originalEntries)

        let correction = try session.correctEntry(
            session.entries[0].id,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(2)
        )
        XCTAssertThrowsError(
            try session.correctEntry(
                correction.id,
                author: .user,
                replacementContent: "再次修正",
                now: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .correctionTargetIsCorrection)
        }
    }

    func testPauseResumeAndArchiveAreExplicitAndArchivedSessionIsTerminal() throws {
        var session = try makeSession()

        try session.pause(now: now.addingTimeInterval(1))
        XCTAssertEqual(session.workspaceStatus, .paused)
        XCTAssertThrowsError(
            try session.appendEntry(
                author: .user,
                kind: .statement,
                content: "暂停期间不应写入",
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .workspaceInactive)
        }

        try session.resume(now: now.addingTimeInterval(3))
        XCTAssertEqual(session.workspaceStatus, .active)
        try session.archive(now: now.addingTimeInterval(4))
        XCTAssertEqual(session.workspaceStatus, .archived)
        XCTAssertThrowsError(try session.resume(now: now.addingTimeInterval(5)))
        XCTAssertEqual(
            session.events.suffix(3).map(\.kind),
            [.sessionPaused, .sessionResumed, .sessionArchived]
        )
    }

    func testProviderCannotStartWhileWorkspacePaused() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(1)
        )
        try session.pause(now: now.addingTimeInterval(2))

        XCTAssertThrowsError(
            try session.beginProviderRun(
                payload: ZhulongProviderPayload(
                    systemPrompt: "只输出结构化规划草稿。",
                    userPrompt: session.primaryIntent,
                    contextVersion: "context-v1",
                    scopeContent: [.currentDayTodo: "今日任务摘要"]
                ),
                providerIdentity: identity,
                now: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .workspaceInactive)
        }
    }

    private func makeSession() throws -> ZhulongSession {
        try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
    }
}

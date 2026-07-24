@testable import NoonmarkZhulong
import XCTest

final class ZhulongSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSessionRequiresOneNonemptyPrimaryIntent() {
        XCTAssertThrowsError(
            try ZhulongSession(
                primaryIntent: "  ",
                proposedScopes: [.currentDayTodo],
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .emptyPrimaryIntent)
        }
    }

    func testSessionRetainsTypedWorkflowPurposeIndependentOfDisplayIntent() throws {
        let session = try ZhulongSession(
            primaryIntent: "Close today and form the next credible commitment",
            purpose: .dailyClose,
            proposedScopes: [.currentDayTodo],
            now: now
        )

        XCTAssertEqual(session.purpose, .dailyClose)
        XCTAssertEqual(session.primaryIntent, "Close today and form the next credible commitment")
    }

    func testProviderRunFailsClosedBeforeExactScopeAuthorization() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()

        XCTAssertEqual(
            session.scopeAuthorizationRequirement(
                for: identity
            ),
            .initialSession
        )
        XCTAssertThrowsError(
            try session.beginProviderRun(
                payload: makePayload(),
                providerIdentity: identity,
                now: now
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .scopeNotAuthorized)
        }
        XCTAssertEqual(session.phase, .scopeReview)
        XCTAssertEqual(session.events.map(\.kind), [.sessionCreated])
    }

    func testScopeAuthorizationBindsProviderIdentityAndProducesRequest() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()

        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(1)
        )
        let payload = try makePayload()
        let request = try session.beginProviderRun(
            payload: payload,
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(request.sessionID, session.id)
        XCTAssertEqual(request.payload, payload)
        XCTAssertEqual(request.providerIdentity, identity)
        XCTAssertEqual(session.phase, .providerRunning)
        XCTAssertEqual(
            session.events.map(\.kind),
            [.sessionCreated, .scopeAuthorized, .providerRunStarted]
        )
        XCTAssertEqual(session.events.map(\.sequence), [1, 2, 3])
    }

    func testAuthorizationCannotSilentlyExpandProposedScope() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()

        XCTAssertThrowsError(
            try session.authorizeScope(
                [.currentDayTodo, .taskPool],
                providerIdentity: identity,
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .scopeDoesNotMatchProposal)
        }
        XCTAssertNil(session.authorization)
        XCTAssertEqual(session.events.map(\.kind), [.sessionCreated])
    }

    func testBackdatedEventFailsWithoutPartiallyAuthorizingSession() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()

        XCTAssertThrowsError(
            try session.authorizeScope(
                [.currentDayTodo],
                providerIdentity: identity,
                now: now.addingTimeInterval(-1)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .nonMonotonicEventTime)
        }
        XCTAssertEqual(session.phase, .scopeReview)
        XCTAssertNil(session.authorization)
        XCTAssertEqual(session.events.map(\.kind), [.sessionCreated])
    }

    func testDraftReviewCanOnlyFollowProviderRunAndEventsRemainAppendOnly() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()

        XCTAssertThrowsError(
            try session.recordProviderResponse(
                ZhulongProviderResponse(content: "{}", draftVersion: 1),
                runID: ZhulongProviderRunID(),
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSessionError,
                .invalidTransition(from: .scopeReview, to: .draftReview)
            )
        }

        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )
        let request = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(3)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "{}", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(4)
        )

        XCTAssertEqual(session.phase, .draftReview)
        XCTAssertEqual(session.draftVersion, 1)
        XCTAssertEqual(session.entries.last?.author, .zhulong)
        XCTAssertEqual(session.entries.last?.kind, .statement)
        XCTAssertEqual(session.entries.last?.content, "{}")
        XCTAssertEqual(session.events.count, 4)
        XCTAssertEqual(session.events.last?.kind, .draftReady)
        XCTAssertEqual(session.events.map(\.sequence), [1, 2, 3, 4])
    }

    func testConversationCanContinueAfterAReplyAndPersistsEveryTurn() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(1)
        )

        let firstRequest = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "先从今天最重要的一件事开始。", draftVersion: 1),
            runID: firstRequest.runID,
            now: now.addingTimeInterval(3)
        )
        _ = try session.appendEntry(
            author: .user,
            kind: .statement,
            content: "那件事是整理发布计划。",
            now: now.addingTimeInterval(4)
        )
        let secondRequest = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "好，我们先把发布计划拆成今天能完成的切片。", draftVersion: 1),
            runID: secondRequest.runID,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(session.phase, .draftReview)
        XCTAssertEqual(session.entries.map(\.author), [.user, .zhulong, .user, .zhulong])
        XCTAssertEqual(session.entries.map(\.content), [
            "结束今天并安排明天",
            "先从今天最重要的一件事开始。",
            "那件事是整理发布计划。",
            "好，我们先把发布计划拆成今天能完成的切片。"
        ])
        XCTAssertEqual(session.providerSends.map(\.status), [.succeeded, .succeeded])
    }

    func testConversationCanBeReauthorizedAfterProviderChangesInDraftReview() throws {
        var session = try makeSession()
        let firstIdentity = try makeProviderIdentity()
        let replacementIdentity = try makeProviderIdentity(version: "v5")
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: firstIdentity,
            now: now.addingTimeInterval(1)
        )
        let firstRequest = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: firstIdentity,
            now: now.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "我们继续聊。", draftVersion: 1),
            runID: firstRequest.runID,
            now: now.addingTimeInterval(3)
        )

        XCTAssertFalse(
            session.requiresScopeAuthorization(
                for: firstIdentity
            )
        )
        XCTAssertTrue(
            session.requiresScopeAuthorization(
                for: replacementIdentity
            )
        )

        XCTAssertThrowsError(
            try session.beginProviderRun(
                payload: makePayload(),
                providerIdentity: replacementIdentity,
                now: now.addingTimeInterval(4)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .providerIdentityMismatch)
        }

        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: replacementIdentity,
            now: now.addingTimeInterval(5)
        )
        XCTAssertNil(session.draftVersion)
        let continuedRequest = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: replacementIdentity,
            now: now.addingTimeInterval(6)
        )

        XCTAssertEqual(session.authorization?.providerIdentity, replacementIdentity)
        XCTAssertEqual(session.authorizations.count, 2)
        XCTAssertEqual(continuedRequest.providerIdentity, replacementIdentity)
        XCTAssertFalse(
            session.requiresScopeAuthorization(
                for: replacementIdentity
            )
        )
    }

    func testScopeAuthorizationDoesNotExpireWhileRecipientAndScopeStayUnchanged() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(1)
        )

        let request = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(60 * 60 * 24 * 30)
        )

        XCTAssertEqual(session.authorizations.count, 1)
        XCTAssertEqual(request.providerIdentity, identity)
    }

    func testProviderIdentityIncludesEveryTrustRelevantConfigurationField() throws {
        let baseline = try makeProviderIdentity()

        XCTAssertNotEqual(baseline, try makeProviderIdentity(version: "v5"))
        XCTAssertNotEqual(baseline, try makeProviderIdentity(model: "another-model"))
        XCTAssertNotEqual(
            baseline,
            try makeProviderIdentity(capabilities: [.structuredOutput])
        )
    }

    func testProviderIdentityRejectsEndpointQueryThatCannotBeSafelyDisclosed() {
        XCTAssertThrowsError(
            try ZhulongProviderConfigurationIdentity(
                providerID: "带查询参数的 Provider",
                kind: .openAICompatible,
                baseURL: URL(
                    string: "https://provider.example/v1?tenant=secret"
                )!,
                location: .remote,
                model: "model-v1",
                dataCapabilities: [.structuredOutput]
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSessionError,
                .invalidProviderIdentity
            )
        }
    }

    func testScopeAuthorizationFollowsDataRecipientInsteadOfProviderPresentation() throws {
        var session = try makeSession()
        let authorizedIdentity = try ZhulongProviderConfigurationIdentity(
            providerID: "原 Provider 名称",
            kind: .openAICompatible,
            baseURL: URL(string: "https://provider.example/v1")!,
            location: .remote,
            model: "model-v1",
            dataCapabilities: [.structuredOutput, .taskContext]
        )
        let sameRecipient = try ZhulongProviderConfigurationIdentity(
            providerID: "重命名后的 Provider",
            kind: .openAICompatible,
            baseURL: URL(string: "https://provider.example/v1")!,
            location: .remote,
            model: "model-v2",
            dataCapabilities: [.structuredOutput]
        )
        let differentRecipient = try ZhulongProviderConfigurationIdentity(
            providerID: "另一个接收方",
            kind: .openAICompatible,
            baseURL: URL(string: "https://other.example/v1")!,
            location: .remote,
            model: "model-v2",
            dataCapabilities: [.structuredOutput]
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: authorizedIdentity,
            now: now.addingTimeInterval(1)
        )

        XCTAssertFalse(
            session.requiresScopeAuthorization(
                for: sameRecipient
            )
        )
        XCTAssertTrue(
            session.requiresScopeAuthorization(
                for: differentRecipient
            )
        )
        XCTAssertEqual(
            session.scopeAuthorizationRequirement(
                for: differentRecipient
            ),
            .dataRecipientChanged
        )
        XCTAssertNoThrow(
            try session.beginProviderRun(
                payload: makePayload(),
                providerIdentity: sameRecipient,
                now: now.addingTimeInterval(2)
            )
        )
    }

    func testChangingProviderRequiresAndAcceptsExplicitReauthorization() throws {
        var session = try makeSession()
        let firstIdentity = try makeProviderIdentity()
        let replacementIdentity = try makeProviderIdentity(version: "v5")
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: firstIdentity,
            now: now.addingTimeInterval(1)
        )

        XCTAssertThrowsError(
            try session.beginProviderRun(
                payload: makePayload(),
                providerIdentity: replacementIdentity,
                now: now.addingTimeInterval(2)
            )
        ) { error in
            XCTAssertEqual(error as? ZhulongSessionError, .providerIdentityMismatch)
        }

        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: replacementIdentity,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(session.authorization?.providerIdentity, replacementIdentity)
        XCTAssertEqual(session.authorizations.count, 2)
    }

    func testProviderEventsLinkToSendRecordWithoutCopyingPayload() throws {
        var session = try makeSession()
        let identity = try makeProviderIdentity()
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: identity,
            now: now.addingTimeInterval(1)
        )
        let request = try session.beginProviderRun(
            payload: makePayload(),
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )

        let event = try XCTUnwrap(session.events.last)
        XCTAssertEqual(event.providerRunID, request.runID)
        XCTAssertFalse(event.summary.contains("完成 2 项"))
        XCTAssertFalse(event.summary.isEmpty)
    }

    private func makeSession() throws -> ZhulongSession {
        try ZhulongSession(
            primaryIntent: "结束今天并安排明天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
    }

    private func makePayload() throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "只输出结构化规划草稿。",
            userPrompt: "结束今天并安排明天",
            contextVersion: "context-v1",
            scopeContent: [.currentDayTodo: "完成 2 项，未完成 1 项"]
        )
    }
}

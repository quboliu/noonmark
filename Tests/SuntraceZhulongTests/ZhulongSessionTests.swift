@testable import SuntraceZhulong
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

    func testProviderRunFailsClosedBeforeExactScopeAuthorization() throws {
        var session = try makeSession()
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")

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
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")

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
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")

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
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")

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
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")

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
        XCTAssertEqual(session.events.count, 4)
        XCTAssertEqual(session.events.last?.kind, .draftReady)
        XCTAssertEqual(session.events.map(\.sequence), [1, 2, 3, 4])
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

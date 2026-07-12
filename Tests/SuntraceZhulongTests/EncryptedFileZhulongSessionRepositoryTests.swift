import Foundation
@testable import SuntraceZhulong
import XCTest

final class EncryptedZhulongRepositoryTests: XCTestCase {
    private var directoryURL: URL!
    private let key = Data(repeating: 0x2A, count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-zhulong-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testEncryptedRepositoryRoundTripsValidatedSessionWithoutPlaintextLeakage() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()

        try repository.save(session)
        let restored = try repository.load(session.id)

        XCTAssertEqual(restored, session)
        let fileURL = repository.fileURL(for: session.id)
        let storedBytes = try Data(contentsOf: fileURL)
        XCTAssertNil(storedBytes.range(of: Data(session.primaryIntent.utf8)))
        XCTAssertNil(storedBytes.range(of: Data("provider-v4".utf8)))
        XCTAssertNil(storedBytes.range(of: Data("https://provider.example/v4".utf8)))
        XCTAssertNil(storedBytes.range(of: Data("只输出结构化规划草稿。".utf8)))
        XCTAssertNil(storedBytes.range(of: Data("完成 2 项，未完成 1 项".utf8)))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testWrongKeyAndCiphertextTamperingFailClosed() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()
        try repository.save(session)

        let wrongKeyRepository = makeRepository(key: Data(repeating: 0x19, count: 32))
        XCTAssertThrowsError(try wrongKeyRepository.load(session.id))

        let fileURL = repository.fileURL(for: session.id)
        var ciphertext = try Data(contentsOf: fileURL)
        ciphertext[ciphertext.index(before: ciphertext.endIndex)] ^= 0x01
        try ciphertext.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try repository.load(session.id))
    }

    func testEnvelopeVersionTamperingFailsClosedForCurrentAndLegacyFiles() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()

        try repository.save(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2]
        )

        try repository.saveVersionTwoSessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 3]
        )

        try repository.saveLegacySessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [2, 3]
        )
    }

    func testUnavailableKeyFailsBeforeWritingAnything() throws {
        let repository = EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: FailingKeySource()
        )
        let session = try makeDraftReviewSession()

        XCTAssertThrowsError(try repository.save(session)) { error in
            XCTAssertEqual(error as? TestKeyError, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.fileURL(for: session.id).path))
    }

    func testRepositoryTightensExistingSidecarDirectoryPermissions() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let repository = makeRepository(key: key)

        try repository.save(makeDraftReviewSession())

        let attributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o700)
    }

    func testRepositoryRejectsNoncanonicalPersistedEventSequenceAfterDecryption() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()
        var record = ZhulongSessionRecord(session)
        record.events[1].sequence = 9
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(
                error as? ZhulongSessionRestorationError,
                .noncanonicalEventSequence
            )
        }
    }

    func testRepositoryRejectsProviderSendOutsideAuthorizedProviderIdentity() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()
        var record = ZhulongSessionRecord(session)
        let send = try XCTUnwrap(record.providerSends.first)
        record.providerSends[0] = try ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: makeProviderIdentity(version: "forged"),
            payload: send.payload,
            startedAt: send.startedAt,
            result: send.result
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(
                error as? ZhulongSessionRestorationError,
                .invalidEventsForPhase
            )
        }
    }

    func testRepositoryRoundTripsExplicitProviderReauthorizationInEventOrder() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "重新规划明天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        let replacement = try makeProviderIdentity(version: "v5")
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: replacement,
            expiresAt: now.addingTimeInterval(400),
            now: now.addingTimeInterval(2)
        )
        let request = try session.beginProviderRun(
            payload: ZhulongProviderPayload(
                systemPrompt: "只输出结构化规划草稿。",
                userPrompt: session.primaryIntent,
                contextVersion: "context-v2",
                scopeContent: [.currentDayTodo: "明日有三项候选任务"]
            ),
            providerIdentity: replacement,
            now: now.addingTimeInterval(3)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "{}", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(4)
        )

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testRepositoryRoundTripsCorrectionsAndPausedWorkspace() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        let answer = try session.appendEntry(
            author: .user,
            kind: .answer,
            content: "周五完成。",
            now: now.addingTimeInterval(1)
        )
        _ = try session.correctEntry(
            answer.id,
            author: .user,
            replacementContent: "下周一完成。",
            now: now.addingTimeInterval(2)
        )
        try session.pause(now: now.addingTimeInterval(3))

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testRepositoryMigratesVersionOneEncryptedSessionWithoutLosingProviderHistory() throws {
        let repository = makeRepository(key: key)
        let legacySession = try makeDraftReviewSession()
        try repository.saveLegacySessionForTesting(legacySession)

        let migrated = try repository.load(legacySession.id)

        XCTAssertEqual(migrated.id, legacySession.id)
        XCTAssertEqual(migrated.primaryIntent, legacySession.primaryIntent)
        XCTAssertEqual(migrated.phase, legacySession.phase)
        XCTAssertEqual(migrated.authorizations, legacySession.authorizations)
        XCTAssertEqual(migrated.providerSends, legacySession.providerSends)
        XCTAssertEqual(migrated.workspaceStatus, .active)
        XCTAssertEqual(migrated.entries.map(\.content), [legacySession.primaryIntent])
        XCTAssertEqual(try repository.load(legacySession.id), migrated)
    }

    func testRepositoryMigratesVersionTwoWorkspaceSessionWithoutLosingEntries() throws {
        let repository = makeRepository(key: key)
        var versionTwoSession = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        _ = try versionTwoSession.appendEntry(
            author: .user,
            kind: .decision,
            content: "先交付离线版本。",
            now: now.addingTimeInterval(1)
        )
        try repository.saveVersionTwoSessionForTesting(versionTwoSession)

        let migrated = try repository.load(versionTwoSession.id)

        XCTAssertEqual(migrated, versionTwoSession)
        XCTAssertTrue(migrated.planningBriefs.isEmpty)
        XCTAssertEqual(try repository.load(versionTwoSession.id), migrated)
    }

    func testRepositoryRoundTripsPlanningBriefReviewDelegationAndInvalidation() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        _ = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: try makeProviderIdentity(version: "v5"),
            expiresAt: now.addingTimeInterval(400),
            now: now.addingTimeInterval(5)
        )
        let replacement = try session.delegatePlanning(
            for: brief.id,
            now: now.addingTimeInterval(6)
        )
        _ = try session.beginPlanningProviderRun(
            delegationID: replacement.id,
            payload: ZhulongProviderPayload(
                systemPrompt: "只执行委托 contract 中允许的规划活动。",
                userPrompt: session.primaryIntent,
                contextVersion: "context-v3",
                scopeContent: [.currentDayTodo: "今日任务摘要"]
            ),
            providerIdentity: makeProviderIdentity(version: "v5"),
            now: now.addingTimeInterval(7)
        )

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
        let storedBytes = try Data(contentsOf: repository.fileURL(for: session.id))
        XCTAssertNil(storedBytes.range(of: Data("发布稳定版".utf8)))
        XCTAssertNil(storedBytes.range(of: Data("真实 App E2E 通过".utf8)))
    }

    func testRepositoryRejectsPlanningReviewRemovedWithoutRemovingAuditEvent() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        var record = ZhulongSessionRecord(session)
        record.planningBriefReviews.removeAll()
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(
                error as? ZhulongSessionRestorationError,
                .invalidEventsForPhase
            )
        }
    }

    func testRepositoryRejectsAuthorizationForgedAfterDraftReady() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()
        var record = ZhulongSessionRecord(session)
        let forgedAt = now.addingTimeInterval(4)
        record.authorizations.append(ZhulongScopeAuthorizationRecord(
            scopes: [.currentDayTodo],
            providerIdentity: try makeProviderIdentity(version: "v5"),
            grantedAt: forgedAt,
            expiresAt: now.addingTimeInterval(400)
        ))
        record.events.append(ZhulongSessionEventRecord(
            sequence: UInt64(record.events.count + 1),
            kind: .scopeAuthorized,
            occurredAt: forgedAt,
            summary: "已授权 1 项数据范围",
            reference: nil
        ))
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testRepositoryRoundTripsBriefAndDelegationInvalidatedBySourceCorrection() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let sourceID = session.entries[0].id
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        _ = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        _ = try session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(5)
        )

        try repository.save(session)

        let restored = try repository.load(session.id)
        XCTAssertEqual(restored, session)
        XCTAssertNil(restored.currentPlanningBrief)
        XCTAssertNil(restored.activePlanningDelegation)
    }

    func testRepositoryRejectsPlanningSendRelabeledAsConversation() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        _ = try session.beginPlanningProviderRun(
            delegationID: delegation.id,
            payload: ZhulongProviderPayload(
                systemPrompt: "只执行委托 contract 中允许的规划活动。",
                userPrompt: session.primaryIntent,
                contextVersion: "context-v3",
                scopeContent: [.currentDayTodo: "今日任务摘要"]
            ),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        var record = ZhulongSessionRecord(session)
        let send = try XCTUnwrap(record.providerSends.last)
        record.providerSends[record.providerSends.count - 1] = ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: send.providerIdentity,
            payload: send.payload,
            purpose: .conversation,
            startedAt: send.startedAt,
            result: send.result
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testRepositoryRoundTripsInvalidatedCompletedPlanningDraft() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let sourceID = session.entries[0].id
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let request = try session.beginPlanningProviderRun(
            delegationID: delegation.id,
            payload: ZhulongProviderPayload(
                systemPrompt: "只执行委托 contract 中允许的规划活动。",
                userPrompt: session.primaryIntent,
                contextVersion: "context-v3",
                scopeContent: [.currentDayTodo: "今日任务摘要"]
            ),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "规划草稿 v1", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        _ = try session.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版",
            now: now.addingTimeInterval(7)
        )

        try repository.save(session)

        let restored = try repository.load(session.id)
        XCTAssertEqual(restored, session)
        XCTAssertNil(restored.effectiveDraftVersion)
        XCTAssertEqual(restored.planningRunInvalidations.map(\.runID), [request.runID])
    }

    func testRepositoryRoundTripsSubsetScopeAndSecondPlanningRunFromDraftReview() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo, .taskPool],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo, .taskPool],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let first = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let firstRequest = try session.beginPlanningProviderRun(
            delegationID: first.id,
            payload: planningPayload(for: session, contextVersion: "context-v1"),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "规划草稿 v1", draftVersion: 1),
            runID: firstRequest.runID,
            now: now.addingTimeInterval(6)
        )
        let second = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(7))
        _ = try session.beginPlanningProviderRun(
            delegationID: second.id,
            payload: planningPayload(for: session, contextVersion: "context-v2"),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(8)
        )

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testRepositoryRejectsCorrectionWhoseTargetWasForged() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        let answer = try session.appendEntry(
            author: .user,
            kind: .answer,
            content: "周五完成。",
            now: now.addingTimeInterval(1)
        )
        _ = try session.correctEntry(
            answer.id,
            author: .user,
            replacementContent: "下周一完成。",
            now: now.addingTimeInterval(2)
        )
        var record = ZhulongSessionRecord(session)
        let correction = record.entries[2]
        record.entries[2] = ZhulongSessionEntry(
            id: correction.id,
            author: correction.author,
            kind: correction.kind,
            content: correction.content,
            createdAt: correction.createdAt,
            correctsEntryID: ZhulongSessionEntryID()
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(
                error as? ZhulongSessionRestorationError,
                .invalidEventsForPhase
            )
        }
    }

    func testRepositoryRejectsEntryForgedAtTheSameTimeAsPause() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        let pausedAt = now.addingTimeInterval(1)
        try session.pause(now: pausedAt)
        var record = ZhulongSessionRecord(session)
        record.entries.append(ZhulongSessionEntry(
            id: ZhulongSessionEntryID(),
            author: .user,
            kind: .statement,
            content: "伪造的暂停后内容",
            createdAt: pausedAt,
            correctsEntryID: nil
        ))
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(
                error as? ZhulongSessionRestorationError,
                .invalidEventsForPhase
            )
        }
    }

    private func makeRepository(key: Data) -> EncryptedFileZhulongSessionRepository {
        EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: FixedKeySource(key: key)
        )
    }

    private func assertVersionTamperingFails(
        repository: EncryptedFileZhulongSessionRepository,
        sessionID: ZhulongSessionID,
        replacementVersions: [UInt8]
    ) throws {
        let fileURL = repository.fileURL(for: sessionID)
        let original = try Data(contentsOf: fileURL)
        let versionIndex = Data("NOONMARK-ZHULONG-SIDECAR".utf8).count
        for replacementVersion in replacementVersions {
            var tampered = original
            tampered[versionIndex] = replacementVersion
            try tampered.write(to: fileURL, options: .atomic)
            XCTAssertThrowsError(try repository.load(sessionID)) { error in
                XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
            }
        }
        try original.write(to: fileURL, options: .atomic)
    }

    private func makeDraftReviewSession() throws -> ZhulongSession {
        var session = try ZhulongSession(
            primaryIntent: "结束今天并安排明天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(301),
            now: now.addingTimeInterval(1)
        )
        let identity = try makeProviderIdentity()
        let payload = try ZhulongProviderPayload(
            systemPrompt: "只输出结构化规划草稿。",
            userPrompt: session.primaryIntent,
            contextVersion: "context-v1",
            scopeContent: [.currentDayTodo: "完成 2 项，未完成 1 项"]
        )
        let request = try session.beginProviderRun(
            payload: payload,
            providerIdentity: identity,
            now: now.addingTimeInterval(2)
        )
        try session.recordProviderResponse(
            ZhulongProviderResponse(content: "{}", draftVersion: 1),
            runID: request.runID,
            now: now.addingTimeInterval(3)
        )
        return session
    }

    private func makePlanningSession() throws -> ZhulongSession {
        var session = try ZhulongSession(
            primaryIntent: "规划发布新版",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: makeProviderIdentity(),
            expiresAt: now.addingTimeInterval(300),
            now: now.addingTimeInterval(1)
        )
        return session
    }

    private func makePlanningBriefDraft(for session: ZhulongSession) throws -> ZhulongPlanningBriefDraft {
        try ZhulongPlanningBriefDraft(
            goal: "发布稳定版",
            successCriteria: ["真实 App E2E 通过"],
            hardConstraints: ["普通 Todo 必须离线可用"],
            userDecisions: ["先完成 Mac 版"],
            delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
            assumptions: ["Provider 配置保持可用"],
            openQuestions: [],
            dataScopes: [.currentDayTodo],
            sourceEntryIDs: [session.entries[0].id]
        )
    }

    private func planningPayload(
        for session: ZhulongSession,
        contextVersion: String
    ) throws -> ZhulongProviderPayload {
        try ZhulongProviderPayload(
            systemPrompt: "只执行委托 contract 中允许的规划活动。",
            userPrompt: session.primaryIntent,
            contextVersion: contextVersion,
            scopeContent: [.currentDayTodo: "今日任务摘要"]
        )
    }
}

private struct FixedKeySource: ZhulongSidecarKeySource {
    let key: Data

    func loadOrCreateKey() throws -> Data {
        key
    }
}

private enum TestKeyError: Error, Equatable {
    case unavailable
}

private struct FailingKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        throw TestKeyError.unavailable
    }
}

import Foundation
@testable import SuntraceCore
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

    func testRepositoryRoundTripsTodoLedgerAndRejectsMissingAuthorization() throws {
        let repository = makeRepository(key: key)
        var session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())
        var engine = SuntraceEngine()
        let artifact = try XCTUnwrap(session.effectivePlanArtifact)
        let draft = try ZhulongTodoDiffDraft(
            sessionID: session.id,
            planArtifactID: artifact.id,
            planArtifactVersion: artifact.version,
            planningDate: LocalDate("2026-07-12"),
            sourceSnapshot: engine.snapshot(),
            createdAt: now.addingTimeInterval(7),
            items: [
                ZhulongTodoDiffItem(
                    operation: .createTask(
                        title: "持久化原子批次",
                        descriptionText: nil,
                        note: nil,
                        plannedSubtasks: [],
                        targetDate: nil
                    )
                )
            ]
        )
        try session.publishTodoDiff(draft, now: now.addingTimeInterval(7))
        _ = try session.authorizeTodoWrite(
            against: engine,
            today: LocalDate("2026-07-12"),
            now: now.addingTimeInterval(8)
        )
        _ = try session.applyAuthorizedTodoDiff(
            to: &engine,
            today: LocalDate("2026-07-12"),
            now: now.addingTimeInterval(9)
        )

        try repository.save(session)
        XCTAssertEqual(try repository.load(session.id), session)

        var record = ZhulongSessionRecord(session)
        record.todoWriteAuthorizations.removeAll()
        try repository.saveRecordForTesting(record)
        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testRepositoryRoundTripsDailyCloseLedgerAndRejectsMissingSnapshot() throws {
        let repository = makeRepository(key: key)
        var session = try ZhulongSession(
            primaryIntent: "完成每日收尾",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        var engine = SuntraceEngine()
        let date = LocalDate("2026-07-12")
        let chainID = try engine.createPoolTask(title: "仍在进行", now: now)
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: date,
            today: date,
            now: now
        )
        let snapshot = try session.captureDailyClose(
            date: date,
            from: engine,
            now: now.addingTimeInterval(1)
        )
        let hypothesis = try ZhulongUnfinishedCauseHypothesis(
            dailyCloseID: snapshot.id,
            content: "任务范围可能大于预期",
            evidenceTraceIDs: [traceID],
            confidence: 0.65,
            counterexamples: ["也可能是外部依赖延迟"],
            createdAt: now.addingTimeInterval(2)
        )
        try session.proposeUnfinishedCause(hypothesis)
        let resolution = try session.resolveUnfinishedCause(
            hypothesis.id,
            decision: .confirmed(content: "任务范围比预期大"),
            now: now.addingTimeInterval(3)
        )
        let draft = try session.publishDailyReviewDraft(
            dailyCloseID: snapshot.id,
            summary: "完成了证据整理",
            tomorrowNote: nil,
            causeResolutionIDs: [resolution.id],
            now: now.addingTimeInterval(4)
        )
        _ = try session.authorizeDailyReview(
            draft.id,
            against: engine,
            now: now.addingTimeInterval(5)
        )
        _ = try session.applyAuthorizedDailyReview(
            draft.id,
            to: &engine,
            now: now.addingTimeInterval(6)
        )

        try repository.save(session)
        XCTAssertEqual(try repository.load(session.id), session)

        var forged = ZhulongSessionRecord(session)
        forged.dailyCloseSnapshots.removeAll()
        try repository.saveRecordForTesting(forged)
        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testRepositoryMigratesVersionSixTodoLedgerToEmptyDailyCloseLedger() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()

        try repository.saveVersionSixSessionForTesting(session)
        let restored = try repository.load(session.id)

        XCTAssertEqual(restored, session)
        XCTAssertTrue(restored.dailyCloseSnapshots.isEmpty)
        XCTAssertTrue(restored.dailyReviewReceipts.isEmpty)

        try repository.saveCurrentSessionWithoutDailyLedgerForTesting(session)
        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }
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

    func testCurrentSchemaRejectsLegacySessionOnlyAuthentication() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()

        try repository.saveCurrentSessionWithLegacyAuthenticationForTesting(session)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }
    }

    func testEnvelopeVersionTamperingFailsClosedForCurrentAndLegacyFiles() throws {
        let repository = makeRepository(key: key)
        let session = try makeDraftReviewSession()

        try repository.save(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2, 3, 4, 5, 6, 7, 9]
        )

        try repository.saveVersionThreeSessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2, 4, 5, 6, 7, 8, 9]
        )

        try repository.saveVersionTwoSessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 3, 4, 5, 6, 7, 8, 9]
        )

        try repository.saveLegacySessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [2, 3, 4, 5, 6, 7, 8, 9]
        )
    }

    func testRepositoryMigratesVersionFourPlanningOutputToEmptyTodoLedger() throws {
        let repository = makeRepository(key: key)
        let session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())

        try repository.saveVersionFourSessionForTesting(session)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2, 3, 5, 6, 7, 8, 9]
        )
        try repository.saveVersionFourSessionForTesting(session)
        let restored = try repository.load(session.id)

        XCTAssertEqual(restored, session)
        XCTAssertTrue(restored.todoDiffDrafts.isEmpty)
        try repository.save(restored)
        let bytes = try Data(contentsOf: repository.fileURL(for: session.id))
        XCTAssertEqual(bytes[Data("NOONMARK-ZHULONG-SIDECAR".utf8).count], 8)
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

    func testRepositoryMigratesVersionThreePlanningBriefSession() throws {
        let repository = makeRepository(key: key)
        var session = try makePlanningSession()
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        _ = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        try repository.saveVersionThreeSessionForTesting(session)

        let migrated = try repository.load(session.id)

        XCTAssertEqual(migrated, session)
        XCTAssertTrue(migrated.decisionGates.isEmpty)
        XCTAssertTrue(migrated.planArtifacts.isEmpty)
    }

    func testVersionThreeRawPlanArtifactMigratesToReadOnlyLegacyPurpose() throws {
        let repository = makeRepository(key: key)
        let session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())
        var record = ZhulongSessionRecordV3(session)
        let send = try XCTUnwrap(record.providerSends.last)
        let completedAt = try XCTUnwrap(send.completedAt)
        record.providerSends[record.providerSends.count - 1] = ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: send.providerIdentity,
            payload: send.payload,
            purpose: send.purpose,
            startedAt: send.startedAt,
            result: .succeeded(
                completedAt: completedAt,
                response: ZhulongProviderResponse(content: "旧版规划草稿", draftVersion: 1)
            )
        )
        let finalSequence = try XCTUnwrap(record.events.last?.sequence)
        record.events[record.events.count - 1] = ZhulongSessionEventRecord(
            sequence: finalSequence,
            kind: .draftReady,
            occurredAt: completedAt,
            summary: "Provider 已返回可审查草稿",
            reference: .providerRun(send.runID)
        )
        try repository.saveVersionThreeRecordForTesting(record)

        let migrated = try repository.load(session.id)

        guard case .migratedLegacyPlanning = migrated.providerSends.last?.purpose else {
            return XCTFail("Expected explicit legacy planning purpose")
        }
        XCTAssertEqual(migrated.effectiveDraftVersion, 1)
        XCTAssertNil(migrated.effectivePlanArtifact)
        XCTAssertTrue(migrated.planArtifacts.isEmpty)
        try repository.save(migrated)
        let migratedBytes = try Data(contentsOf: repository.fileURL(for: session.id))
        XCTAssertEqual(migratedBytes[Data("NOONMARK-ZHULONG-SIDECAR".utf8).count], 9)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2, 3, 4, 5, 6, 7, 8]
        )
        try repository.save(migrated)
        XCTAssertEqual(try repository.load(session.id), migrated)
        try assertVersionTamperingFails(
            repository: repository,
            sessionID: session.id,
            replacementVersions: [1, 2, 3, 4, 5, 6, 7, 8]
        )
    }

    func testRepositoryRoundTripsStructuredPlanArtifactAndRejectsMissingArtifact() throws {
        let repository = makeRepository(key: key)
        let session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
        var forged = ZhulongSessionRecord(session)
        forged.planArtifacts.removeAll()
        try repository.saveRecordForTesting(forged)
        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidDraftVersion)
        }
    }

    func testCurrentEnvelopeRejectsDelegatedPlanningRelabeledAsMigratedLegacy() throws {
        let repository = makeRepository(key: key)
        let session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())
        var record = ZhulongSessionRecord(session)
        let send = try XCTUnwrap(record.providerSends.last)
        let contract = try XCTUnwrap(send.planningContract)
        record.providerSends[record.providerSends.count - 1] = ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: send.providerIdentity,
            payload: send.payload,
            purpose: .migratedLegacyPlanning(contract),
            startedAt: send.startedAt,
            result: send.result
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testCurrentEnvelopeRejectsUnstructuredDelegatedSuccessWithoutArtifact() throws {
        let repository = makeRepository(key: key)
        let session = try makeStructuredPlanningSession(output: structuredPlanArtifactJSON())
        var record = ZhulongSessionRecord(session)
        let send = try XCTUnwrap(record.providerSends.last)
        let completedAt = try XCTUnwrap(send.completedAt)
        record.providerSends[record.providerSends.count - 1] = ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: send.providerIdentity,
            payload: send.payload,
            purpose: send.purpose,
            startedAt: send.startedAt,
            result: .succeeded(
                completedAt: completedAt,
                response: ZhulongProviderResponse(content: "未结构化旧草稿", draftVersion: 1)
            )
        )
        record.planArtifacts.removeAll()
        let sequence = try XCTUnwrap(record.events.last?.sequence)
        record.events[record.events.count - 1] = ZhulongSessionEventRecord(
            sequence: sequence,
            kind: .draftReady,
            occurredAt: completedAt,
            summary: "Provider 已返回可审查草稿",
            reference: .providerRun(send.runID)
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidDraftVersion)
        }
    }

    func testCurrentEnvelopeRejectsPrecisionClaimWhoseBasisWasRewritten() throws {
        let repository = makeRepository(key: key)
        let validOutput = structuredPlanArtifactJSON()
            .replacingOccurrences(
                of: "普通 Todo 必须离线可用",
                with: "必须在 2026-08-01 前完成"
            )
            .replacingOccurrences(
                of: "\"precisionClaims\":[]",
                with: precisionClaimJSON(basis: "必须在 2026-08-01 前完成")
            )
        let session = try makeStructuredPlanningSession(output: validOutput)
        var record = ZhulongSessionRecord(session)
        let send = try XCTUnwrap(record.providerSends.last)
        let completedAt = try XCTUnwrap(send.completedAt)
        let forgedOutput = structuredPlanArtifactJSON()
            .replacingOccurrences(
                of: "普通 Todo 必须离线可用",
                with: "模型自称 2026-08-01 前完成"
            )
            .replacingOccurrences(
                of: "\"precisionClaims\":[]",
                with: precisionClaimJSON(basis: "模型自称 2026-08-01 前完成")
            )
        record.providerSends[record.providerSends.count - 1] = ZhulongProviderSendRecord(
            runID: send.runID,
            providerIdentity: send.providerIdentity,
            payload: send.payload,
            purpose: send.purpose,
            startedAt: send.startedAt,
            result: .succeeded(
                completedAt: completedAt,
                response: ZhulongProviderResponse(content: forgedOutput, draftVersion: 1)
            )
        )
        let parsed = try ZhulongPlanningOutputParser().parse(forgedOutput)
        guard case let .planArtifact(forgedProposal) = parsed else {
            return XCTFail("Expected forged plan artifact")
        }
        let artifact = try XCTUnwrap(record.planArtifacts.last)
        record.planArtifacts[record.planArtifacts.count - 1] = ZhulongPlanArtifact(
            id: artifact.id,
            sessionID: artifact.sessionID,
            runID: artifact.runID,
            briefID: artifact.briefID,
            briefVersion: artifact.briefVersion,
            providerIdentity: artifact.providerIdentity,
            contextVersion: artifact.contextVersion,
            version: artifact.version,
            createdAt: artifact.createdAt,
            proposal: forgedProposal
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
    }

    func testRepositoryRoundTripsResolvedDecisionGate() throws {
        let repository = makeRepository(key: key)
        var session = try makeStructuredPlanningSession(output: decisionGateJSON(), draftVersion: nil)
        let gate = try XCTUnwrap(session.currentDecisionGate)
        _ = try session.resolveDecisionGate(
            gate.id,
            selectedOptionID: "investigate",
            supplementalDecision: "只形成真实测量任务。",
            now: now.addingTimeInterval(7)
        )

        try repository.save(session)

        XCTAssertEqual(try repository.load(session.id), session)
    }

    func testRepositoryRoundTripsGateSourceCorrectionBeforeAndAfterResolution() throws {
        let repository = makeRepository(key: key)
        var unresolved = try makeStructuredPlanningSession(
            output: decisionGateJSON(),
            draftVersion: nil
        )
        _ = try unresolved.correctEntry(
            unresolved.entries[0].id,
            author: .user,
            replacementContent: "规划发布稳定版并先测量",
            now: now.addingTimeInterval(7)
        )
        try repository.save(unresolved)
        XCTAssertEqual(try repository.load(unresolved.id), unresolved)

        var resolved = try makeStructuredPlanningSession(
            output: decisionGateJSON(),
            draftVersion: nil
        )
        let gate = try XCTUnwrap(resolved.currentDecisionGate)
        let resolution = try resolved.resolveDecisionGate(
            gate.id,
            selectedOptionID: "investigate",
            supplementalDecision: "只形成真实测量任务。",
            now: now.addingTimeInterval(7)
        )
        let sourceID = resolved.entries[0].id
        _ = try resolved.correctEntry(
            sourceID,
            author: .user,
            replacementContent: "规划发布稳定版并先测量",
            now: now.addingTimeInterval(8)
        )
        _ = try resolved.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版并先测量",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用"],
                userDecisions: ["先完成 Mac 版", "先调查：只形成真实测量任务。"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: ["Provider 配置保持可用"],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [sourceID, resolution.decisionEntryID]
            ),
            now: now.addingTimeInterval(9)
        )
        try repository.save(resolved)
        XCTAssertEqual(try repository.load(resolved.id), resolved)
    }

    func testRepositoryRejectsBriefRevisionThatNoLongerIncludesGateDecision() throws {
        let repository = makeRepository(key: key)
        var session = try makeStructuredPlanningSession(output: decisionGateJSON(), draftVersion: nil)
        let gate = try XCTUnwrap(session.currentDecisionGate)
        let resolution = try session.resolveDecisionGate(
            gate.id,
            selectedOptionID: "investigate",
            supplementalDecision: "只形成真实测量任务。",
            now: now.addingTimeInterval(7)
        )
        _ = try session.publishPlanningBrief(
            ZhulongPlanningBriefDraft(
                goal: "发布稳定版",
                successCriteria: ["真实 App E2E 通过"],
                hardConstraints: ["普通 Todo 必须离线可用"],
                userDecisions: ["先完成 Mac 版", "先调查：只形成真实测量任务。"],
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview],
                assumptions: ["Provider 配置保持可用"],
                openQuestions: [],
                dataScopes: [.currentDayTodo],
                sourceEntryIDs: [session.entries[0].id, resolution.decisionEntryID]
            ),
            now: now.addingTimeInterval(8)
        )
        var record = ZhulongSessionRecord(session)
        let entryIndex = try XCTUnwrap(record.entries.firstIndex(where: {
            $0.id == resolution.decisionEntryID
        }))
        let entry = record.entries[entryIndex]
        record.entries[entryIndex] = ZhulongSessionEntry(
            id: entry.id,
            author: entry.author,
            kind: entry.kind,
            content: "先调查：改成另一项。",
            createdAt: entry.createdAt,
            correctsEntryID: entry.correctsEntryID
        )
        try repository.saveRecordForTesting(record)

        XCTAssertThrowsError(try repository.load(session.id)) { error in
            XCTAssertEqual(error as? ZhulongSessionRestorationError, .invalidEventsForPhase)
        }
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

    func testRepositoryRoundTripsInvalidatedCompletedPlanArtifact() throws {
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
        try session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: structuredPlanArtifactJSON(), draftVersion: 1),
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
        try session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: structuredPlanArtifactJSON(), draftVersion: 1),
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
            hardConstraints: ["普通 Todo 必须离线可用", "必须在 2026-08-01 前完成"],
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

    private func makeStructuredPlanningSession(
        output: String,
        draftVersion: Int? = 1
    ) throws -> ZhulongSession {
        var session = try makePlanningSession()
        let brief = try session.publishPlanningBrief(
            makePlanningBriefDraft(for: session),
            now: now.addingTimeInterval(2)
        )
        try session.reviewPlanningBrief(brief.id, now: now.addingTimeInterval(3))
        let delegation = try session.delegatePlanning(for: brief.id, now: now.addingTimeInterval(4))
        let request = try session.beginPlanningProviderRun(
            delegationID: delegation.id,
            payload: planningPayload(for: session, contextVersion: "context-v1"),
            providerIdentity: makeProviderIdentity(),
            now: now.addingTimeInterval(5)
        )
        try session.recordPlanningProviderResponse(
            ZhulongProviderResponse(content: output, draftVersion: draftVersion),
            runID: request.runID,
            now: now.addingTimeInterval(6)
        )
        return session
    }

    private func decisionGateJSON() -> String {
        """
        {"kind":"decisionGate","summary":"证据不足。","prompt":"怎样继续？","reason":"缺少测量。","evidenceGaps":["没有同度量历史"],"options":[{"id":"investigate","title":"先调查","impact":"形成测量任务"},{"id":"stop","title":"保留未决","impact":"停止规划"}]}
        """
    }

    private func structuredPlanArtifactJSON() -> String {
        """
        {
          "kind":"planArtifact",
          "summary":"先取得测量，再交付近期切片。",
          "stages":[
            {"id":"measure","title":"工程测量","objective":"取得真实数据","horizon":"nearTerm","dependencyIDs":[],"deliverables":["测量记录"],"triggerCondition":null},
            {"id":"delivery","title":"交付切片","objective":"完成任务成形闭环","horizon":"later","dependencyIDs":["measure"],"deliverables":[],"triggerCondition":"测量记录已审查"}
          ],
          "decisionExplanations":[{
            "subject":"为何先测量","userDecisions":["先完成 Mac 版"],"assumptions":["Provider 配置保持可用"],"dataScopes":["currentDayTodo"],"evidence":["当前没有同度量工程数据"],"constraints":["普通 Todo 必须离线可用"],
            "alternatives":[{"title":"直接排期","tradeoffs":["快但无证据"]},{"title":"先测量","tradeoffs":["较慢但可校准"]}],
            "counterexamples":["直接排期会隐藏证据缺口"],"rationale":"测量后才能形成可信承诺。","uncertainties":["测量结果未知"],"expectedImpacts":["近期只生成调查任务"],"requiredAuthorizations":["todoWrite"]
          }],
          "precisionClaims":[]
        }
        """
    }

    private func precisionClaimJSON(basis: String) -> String {
        """
        "precisionClaims":[{
          "kind":"targetDate","dateValue":"2026-08-01","numericValue":null,
          "basisSource":"hardConstraint","basis":"\(basis)","basisValue":"2026-08-01","dataScope":null
        }]
        """
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

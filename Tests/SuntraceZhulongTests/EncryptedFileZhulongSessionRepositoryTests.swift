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
        XCTAssertNil(storedBytes.range(of: Data("provider-config-v4".utf8)))
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
            providerIdentity: ZhulongProviderConfigurationIdentity("provider-config-forged"),
            payload: send.payload,
            startedAt: send.startedAt,
            status: send.status,
            completedAt: send.completedAt,
            response: send.response,
            failure: send.failure
        )
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

    private func makeDraftReviewSession() throws -> ZhulongSession {
        var session = try ZhulongSession(
            primaryIntent: "结束今天并安排明天",
            proposedScopes: [.currentDayTodo],
            now: now
        )
        try session.authorizeScope(
            [.currentDayTodo],
            providerIdentity: ZhulongProviderConfigurationIdentity("provider-config-v4"),
            now: now.addingTimeInterval(1)
        )
        let identity = try ZhulongProviderConfigurationIdentity("provider-config-v4")
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

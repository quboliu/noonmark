import Foundation
@testable import NoonmarkZhulong
import XCTest

final class EncryptedZhulongMemoryRepositoryTests: XCTestCase {
    private var directoryURL: URL!
    private let key = Data(repeating: 0x4D, count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noonmark-zhulong-memory-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testRepositoryRoundTripsLedgerWithoutPlaintextLeakage() throws {
        let repository = makeRepository(key: key)
        let ledger = try makeConfirmedLedger()

        try repository.save(ledger)
        XCTAssertEqual(try repository.load(), ledger)

        let bytes = try Data(contentsOf: repository.fileURL)
        XCTAssertNil(bytes.range(of: Data("偏好上午深度工作".utf8)))
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        let filePermissions = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(filePermissions & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
        let directoryPermissions = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryPermissions & 0o777, 0o700)
    }

    func testMissingWrongKeyAndCiphertextTamperingFailClosed() throws {
        let repository = makeRepository(key: key)
        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .missingMemoryLedger)
        }

        try repository.save(try makeConfirmedLedger())
        XCTAssertThrowsError(try makeRepository(key: Data(repeating: 0x2A, count: 32)).load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }

        var bytes = try Data(contentsOf: repository.fileURL)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0x01
        try bytes.write(to: repository.fileURL, options: .atomic)
        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }
    }

    func testRepositoryRejectsSemanticallyInvalidLedgerBeforeEncryption() throws {
        let repository = makeRepository(key: key)
        let valid = try makeConfirmedLedger()
        let data = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var memories = try XCTUnwrap(object["memories"] as? [[String: Any]])
        memories[0]["content"] = ""
        object["memories"] = memories
        let forgedData = try JSONSerialization.data(withJSONObject: object)
        let forged = try JSONDecoder().decode(ZhulongMemoryLedger.self, from: forgedData)

        XCTAssertThrowsError(try repository.save(forged)) { error in
            XCTAssertEqual(error as? ZhulongMemoryError, .invalidLedger)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.fileURL.path))
    }

    private func makeConfirmedLedger() throws -> ZhulongMemoryLedger {
        var ledger = ZhulongMemoryLedger(isEnabled: true)
        let candidate = try ZhulongMemoryCandidate(
            topicKey: "deep-work-time",
            content: "偏好上午深度工作",
            source: .zhulongInference,
            evidenceWindowStart: now,
            evidenceWindowEnd: now.addingTimeInterval(1),
            evidenceReferences: [.sessionEntry(ZhulongSessionEntryID())],
            confidence: 0.75,
            counterexamples: ["上周有一次夜间专注记录"],
            createdAt: now.addingTimeInterval(2)
        )
        try ledger.propose(candidate)
        _ = try ledger.confirmCandidate(candidate.id, now: now.addingTimeInterval(3))
        return ledger
    }

    private func makeRepository(key: Data) -> EncryptedFileZhulongMemoryRepository {
        EncryptedFileZhulongMemoryRepository(
            directoryURL: directoryURL,
            keySource: FixedMemoryTestKeySource(key: key)
        )
    }
}

private struct FixedMemoryTestKeySource: ZhulongSidecarKeySource {
    let key: Data

    func loadOrCreateKey() throws -> Data {
        key
    }
}

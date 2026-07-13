import CryptoKit
import Foundation
import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongApplicationJournalTests: XCTestCase {
    func testRoundTripEncryptsSnapshotsAndAfterSession() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x31)
        )
        let application = try makeApplication()

        try repository.save(application)

        XCTAssertEqual(try repository.load(), application)
        let ciphertext = try Data(contentsOf: repository.fileURL)
        XCTAssertNil(ciphertext.range(of: Data("敏感恢复任务".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testWrongKeyFailsClosedAndClearRemovesJournal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x41)
        )
        try writer.save(makeApplication())
        let reader = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x42)
        )

        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }

        try writer.clear()
        XCTAssertNil(try writer.load())
    }

    func testRepositoryRejectsCurrentEnvelopeWithUnknownTopLevelField() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyByte: UInt8 = 0x51
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: keyByte)
        )
        try repository.save(makeApplication())
        try rewriteStoredPlaintext(repository: repository, keyByte: keyByte) { object in
            object["unexpectedPayload"] = ["enabled": true]
        }

        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }
    }

    func testRepositoryRejectsNoncurrentEnvelopeVersion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x61)
        )
        try repository.save(makeApplication())
        let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
        var envelope = try Data(contentsOf: repository.fileURL)
        envelope[magic.count] = 2
        try envelope.write(to: repository.fileURL, options: .atomic)

        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .unsupportedEnvelope)
        }
    }

    private func makeApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSince1970: 1000)
        let session = try ZhulongSession(
            primaryIntent: "敏感恢复任务",
            proposedScopes: [.taskPool],
            now: now
        )
        let before = NoonmarkEngine().snapshot()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "敏感恢复任务",
            now: now.addingTimeInterval(1)
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: before,
            afterSnapshot: afterEngine.snapshot(),
            afterSession: session,
            createdAt: now.addingTimeInterval(2)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zhulong-application-journal-\(UUID().uuidString)")
    }

    private func rewriteStoredPlaintext(
        repository: EncryptedFileZhulongApplicationJournal,
        keyByte: UInt8,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
        let formatVersion: UInt8 = 1
        let envelope = try Data(contentsOf: repository.fileURL)
        let ciphertext = Data(envelope.dropFirst(magic.count + 1))
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        var authenticatedData = magic
        authenticatedData.append(formatVersion)
        let key = SymmetricKey(data: Data(repeating: keyByte, count: 32))
        let plaintext = try AES.GCM.open(
            sealedBox,
            using: key,
            authenticating: authenticatedData
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        )
        mutation(&object)
        let forgedPlaintext = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let forgedBox = try AES.GCM.seal(
            forgedPlaintext,
            using: key,
            authenticating: authenticatedData
        )
        var forgedEnvelope = magic
        forgedEnvelope.append(formatVersion)
        forgedEnvelope.append(try XCTUnwrap(forgedBox.combined))
        try forgedEnvelope.write(to: repository.fileURL, options: .atomic)
    }
}

private struct FixedJournalKeySource: ZhulongSidecarKeySource {
    let byte: UInt8

    func loadOrCreateKey() throws -> Data {
        Data(repeating: byte, count: 32)
    }
}

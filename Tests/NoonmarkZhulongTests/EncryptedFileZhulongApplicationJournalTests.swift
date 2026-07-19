import CryptoKit
import Foundation
import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongApplicationJournalTests: XCTestCase {
    func testPrepareDoesNotReportFailureWhenExactJournalWasInstalledBeforeChmodError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keySource = FixedJournalKeySource(byte: 0x21)
        let application = try makeApplication()
        let sessionRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: directory,
            keySource: keySource
        )
        try sessionRepository.save(application.beforeSession)
        var fileOperations = ZhulongJournalDarwinOperations.live
        let liveRename = fileOperations.renameExclusive
        let liveDirectorySync = fileOperations.syncDirectory
        var directorySyncCount = 0
        fileOperations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            throw JournalPostReplaceFault.chmodReportedAfterSuccess
        }
        fileOperations.syncDirectory = { descriptor in
            directorySyncCount += 1
            try liveDirectorySync(descriptor)
        }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: keySource,
            fileOperations: fileOperations
        )

        let outcome = try repository.save(application)

        XCTAssertEqual(
            outcome,
            .recoveredCommitted(after: .replacement),
            "exact authenticated pending 已安装后必须返回 committed outcome"
        )
        XCTAssertEqual(
            try repository.load(),
            application,
            "现有实现虽回报失败，重启仍会看到并应用同一 pending"
        )
        XCTAssertEqual(
            directorySyncCount,
            1,
            "rename 已生效但回报错误时，必须补做目录同步才可确认 recovered"
        )
    }

    func testRoundTripEncryptsSnapshotsAndAfterSession() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x31)
        )
        let application = try makeApplication()

        try save(
            application,
            to: repository,
            keyByte: 0x31
        )

        XCTAssertEqual(try repository.load(), application)
        let ciphertext = try Data(contentsOf: repository.fileURL)
        XCTAssertNil(ciphertext.range(of: Data("敏感恢复任务".utf8)))
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRoundTripPreservesLogicalClockBitPatternsExactly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x32)
        )
        let applySeconds = Double(bitPattern: 4_740_043_791_979_369_303)
        let sessionAt = Date(
            timeIntervalSinceReferenceDate: applySeconds.nextDown
        )
        let applyAt = Date(
            timeIntervalSinceReferenceDate: applySeconds
        )
        var session = try ZhulongSession(
            primaryIntent: "精确逻辑时钟",
            proposedScopes: [.taskPool],
            now: sessionAt
        )
        let beforeSession = session
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "应用完成",
            now: applyAt
        )
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "精确逻辑时钟任务",
            now: applyAt
        )
        let application = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: NoonmarkEngine().snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: applyAt
        )

        try save(
            application,
            to: repository,
            keyByte: 0x32
        )

        XCTAssertEqual(try repository.load(), application)
    }

    func testWrongKeyFailsClosedAndClearRemovesJournal() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x41)
        )
        let application = try makeApplication()
        try save(
            application,
            to: writer,
            keyByte: 0x41
        )
        let reader = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x42)
        )

        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }

        try writer.clear(
            application,
            requiring: .beforeSession
        )
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
        try save(
            makeApplication(),
            to: repository,
            keyByte: keyByte
        )
        try rewriteStoredPlaintext(repository: repository, keyByte: keyByte) { object in
            object["unexpectedPayload"] = ["enabled": true]
        }

        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .invalidCiphertext)
        }
    }

    func testRepositoryRejectsLegacyEnvelopeVersion() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: 0x61)
        )
        try save(
            makeApplication(),
            to: repository,
            keyByte: 0x61
        )
        let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
        var envelope = try Data(contentsOf: repository.fileURL)
        envelope[magic.count] = 1
        try envelope.write(to: repository.fileURL, options: .atomic)

        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? ZhulongSidecarRepositoryError, .unsupportedEnvelope)
        }
    }

    func testRepositoryRejectsNonfiniteExactDateBits() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyByte: UInt8 = 0x62
        let repository = EncryptedFileZhulongApplicationJournal(
            directoryURL: directory,
            keySource: FixedJournalKeySource(byte: keyByte)
        )
        try save(
            makeApplication(),
            to: repository,
            keyByte: keyByte
        )
        try rewriteStoredPlaintext(
            repository: repository,
            keyByte: keyByte
        ) { object in
            object["createdAt"] = Double.infinity.bitPattern
        }

        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .invalidCiphertext
            )
        }
    }

    private func makeApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSince1970: 1000)
        var session = try ZhulongSession(
            primaryIntent: "敏感恢复任务",
            proposedScopes: [.taskPool],
            now: now
        )
        let beforeSession = session
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "应用完成",
            now: now.addingTimeInterval(2)
        )
        let before = NoonmarkEngine().snapshot()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "敏感恢复任务",
            now: now.addingTimeInterval(2)
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: before,
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: now.addingTimeInterval(2)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zhulong-application-journal-\(UUID().uuidString)")
    }

    private func save(
        _ application: ZhulongPendingApplication,
        to repository: EncryptedFileZhulongApplicationJournal,
        keyByte: UInt8
    ) throws {
        let sessionRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: repository.directoryURL,
            keySource: FixedJournalKeySource(byte: keyByte)
        )
        try sessionRepository.save(application.beforeSession)
        try repository.save(application)
    }

    private func rewriteStoredPlaintext(
        repository: EncryptedFileZhulongApplicationJournal,
        keyByte: UInt8,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        let magic = Data("NOONMARK-ZHULONG-APPLICATION".utf8)
        let formatVersion: UInt8 = 3
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

private enum JournalPostReplaceFault: Error {
    case chmodReportedAfterSuccess
}

import Foundation
import SuntraceCore
@testable import SuntraceZhulong
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

    private func makeApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSince1970: 1000)
        let session = try ZhulongSession(
            primaryIntent: "敏感恢复任务",
            proposedScopes: [.taskPool],
            now: now
        )
        let before = SuntraceEngine().snapshot()
        let afterEngine = SuntraceEngine()
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
}

private struct FixedJournalKeySource: ZhulongSidecarKeySource {
    let byte: UInt8

    func loadOrCreateKey() throws -> Data {
        Data(repeating: byte, count: 32)
    }
}

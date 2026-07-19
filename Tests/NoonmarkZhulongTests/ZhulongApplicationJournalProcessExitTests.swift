import Darwin
import Foundation
@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongJournalProcessExitTests: XCTestCase {
    private static let phaseEnvironment =
        "NOONMARK_TEST_ZHULONG_JOURNAL_EXIT_PHASE"
    private static let directoryEnvironment =
        "NOONMARK_TEST_ZHULONG_JOURNAL_EXIT_DIRECTORY"
    private static let testSelector =
        "NoonmarkZhulongTests.ZhulongJournalProcessExitTests/" +
        "testRenameBoundaryLeavesOnlyAbsentOrAuthenticatedExact"

    func testRenameBoundaryLeavesOnlyAbsentOrAuthenticatedExact() throws {
        if let phase = ProcessInfo.processInfo.environment[
            Self.phaseEnvironment
        ] {
            try runChild(phase: phase)
            XCTFail("child phase did not terminate at its boundary")
            return
        }

        try assertChildExit(
            phase: ExitPhase.beforeRename.rawValue,
            expectedStatus: ExitPhase.beforeRename.status
        ) { journal in
            XCTAssertEqual(
                try orphanedTemporaryJournalURLs(in: journal.directoryURL)
                    .count,
                1
            )
            XCTAssertNil(try journal.load())
            XCTAssertTrue(
                try orphanedTemporaryJournalURLs(in: journal.directoryURL)
                    .isEmpty
            )
        }
        try assertChildExit(
            phase: ExitPhase.afterRename.rawValue,
            expectedStatus: ExitPhase.afterRename.status
        ) { journal in
            let pending = try XCTUnwrap(journal.load())
            XCTAssertEqual(pending.id, Self.pendingID)
            XCTAssertEqual(pending.sessionID, Self.sessionID)
        }
    }

    private func assertChildExit(
        phase: String,
        expectedStatus: Int32,
        assertion: (EncryptedFileZhulongApplicationJournal) throws -> Void
    ) throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-journal-process-exit-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            Self.testSelector,
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.phaseEnvironment] = phase
        environment[Self.directoryEnvironment] = directoryURL.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationReason,
            .exit,
            childOutput
        )
        XCTAssertEqual(
            process.terminationStatus,
            expectedStatus,
            childOutput
        )
        let journal = EncryptedFileZhulongApplicationJournal(
            directoryURL: directoryURL,
            keySource: ProcessExitKeySource()
        )
        try assertion(journal)
    }

    private func runChild(phase: String) throws {
        guard let directory = ProcessInfo.processInfo.environment[
            Self.directoryEnvironment
        ] else {
            throw ProcessExitTestError.missingDirectory
        }
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let keySource = ProcessExitKeySource()
        let pending = try makePendingApplication()
        try EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: keySource
        ).save(pending.beforeSession)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        switch phase {
        case ExitPhase.beforeRename.rawValue:
            operations.renameExclusive = { _, _ in
                _exit(ExitPhase.beforeRename.status)
            }
        case ExitPhase.afterRename.rawValue:
            operations.renameExclusive = { source, destination in
                try liveRename(source, destination)
                _exit(ExitPhase.afterRename.status)
            }
        default:
            throw ProcessExitTestError.unknownPhase
        }
        let journal = EncryptedFileZhulongApplicationJournal(
            directoryURL: directoryURL,
            keySource: keySource,
            fileOperations: operations
        )
        _ = try journal.save(pending)
    }

    private func orphanedTemporaryJournalURLs(
        in directoryURL: URL
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".pending-application.zhj.")
                && $0.pathExtension == "tmp"
        }
    }

    private func makePendingApplication() throws -> ZhulongPendingApplication {
        let now = Date(timeIntervalSinceReferenceDate: 2_345_678)
        var session = try ZhulongSession(
            id: Self.sessionID,
            primaryIntent: "process exit journal boundary",
            proposedScopes: [.taskPool],
            now: now
        )
        let beforeSession = session
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "process exit applied",
            now: now.addingTimeInterval(2)
        )
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "process exit exact journal",
            now: now.addingTimeInterval(2)
        )
        return try ZhulongPendingApplication(
            id: Self.pendingID,
            kind: .todoDiff(Self.diffID),
            sessionID: Self.sessionID,
            beforeSnapshot: NoonmarkEngine().snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: now.addingTimeInterval(2)
        )
    }

    private static let pendingID = UUID(
        uuidString: "96B8869D-47F0-4E95-AD49-8FD9909C7550"
    )!
    private static let sessionID = ZhulongSessionID(
        UUID(uuidString: "094FFB7F-5C57-43F7-B147-A99E94984B16")!
    )
    private static let diffID = ZhulongTodoDiffID(
        UUID(uuidString: "718455EA-EEAB-489D-A6C5-8DB2F3F5B881")!
    )
}

private enum ExitPhase: String {
    case beforeRename
    case afterRename

    var status: Int32 {
        switch self {
        case .beforeRename: 70
        case .afterRename: 71
        }
    }
}

private struct ProcessExitKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        Data(repeating: 0x45, count: 32)
    }
}

private enum ProcessExitTestError: Error {
    case missingDirectory
    case unknownPhase
}

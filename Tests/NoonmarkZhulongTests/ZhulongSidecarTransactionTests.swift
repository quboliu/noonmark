import Foundation
@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongSidecarTransactionTests: XCTestCase {
    private var directoryURL: URL!
    private let key = Data(repeating: 0x6C, count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-zhulong-sidecar-transaction-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    func testJournalCreationRejectsStaleBeforeSessionWithoutWriting() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "建立精确 before")
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        var third = before
        try third.pause(now: now.addingTimeInterval(1))
        try repositories.sessions.save(third)

        XCTAssertThrowsError(
            try repositories.journal.save(pending)
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .sessionConflict
            )
        }
        XCTAssertNil(try repositories.journal.load())
        XCTAssertEqual(try repositories.sessions.load(before.id), third)
    }

    func testJournalCreationRejectsAnyExistingPendingApplication() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "拒绝第二份 journal")
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        try repositories.sessions.save(before)
        try repositories.journal.save(pending)
        let competing = try ZhulongPendingApplication(
            id: UUID(),
            kind: pending.kind,
            sessionID: pending.sessionID,
            beforeSnapshot: pending.beforeSnapshot,
            afterSnapshot: pending.afterSnapshot,
            beforeSession: pending.beforeSession,
            afterSession: pending.afterSession,
            createdAt: pending.createdAt
        )

        XCTAssertThrowsError(
            try repositories.journal.save(competing)
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
        XCTAssertEqual(try repositories.journal.load(), pending)
    }

    func testPendingApplicationBlocksNewAndExistingSessionWritesGlobally() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "待恢复会话")
        let unrelated = try makeSession(
            intent: "另一会话",
            at: now.addingTimeInterval(10)
        )
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        try repositories.sessions.save(before)
        try repositories.sessions.save(unrelated)
        try repositories.journal.save(pending)
        let newSession = try makeSession(
            intent: "新会话",
            at: now.addingTimeInterval(20)
        )
        var unrelatedReplacement = unrelated
        try unrelatedReplacement.pause(now: now.addingTimeInterval(11))

        XCTAssertThrowsError(
            try repositories.sessions.save(newSession)
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
        XCTAssertThrowsError(
            try repositories.sessions.save(unrelatedReplacement)
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
        XCTAssertThrowsError(
            try repositories.sessions.save(
                unrelatedReplacement,
                replacing: unrelated
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
        XCTAssertThrowsError(
            try repositories.sessions.save(
                pending.afterSession,
                replacing: pending.beforeSession
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
        XCTAssertEqual(
            try repositories.sessions.load(unrelated.id),
            unrelated
        )
        XCTAssertThrowsError(try repositories.sessions.load(newSession.id)) {
            XCTAssertEqual(
                $0 as? ZhulongSidecarRepositoryError,
                .missingSession
            )
        }
    }

    func testDistinctLockInstancesSerializeSameProcessThreads() async throws {
        let firstLock = ZhulongSidecarTransactionLock(
            directoryURL: directoryURL,
            fileManager: .default
        )
        let secondLock = ZhulongSidecarTransactionLock(
            directoryURL: directoryURL,
            fileManager: .default
        )
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondReadyToAcquire = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        let first = Task.detached {
            try firstLock.withExclusiveLock {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(
            firstEntered.wait(timeout: .now() + 2),
            .success
        )
        let second = Task.detached {
            try secondLock.withExclusiveLock(
                beforeAcquire: {
                    _ = secondReadyToAcquire.signal()
                },
                {
                    _ = secondEntered.signal()
                }
            )
        }
        XCTAssertEqual(
            secondReadyToAcquire.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 1),
            .timedOut,
            "macOS flock 必须让同进程不同 fd 的临界区互斥"
        )

        releaseFirst.signal()
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 2),
            .success
        )
        try await first.value
        try await second.value
    }

    func testRecoveryCASRejectsWrongApplicationIdentityAndWrongPair() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "核对恢复授权")
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        try repositories.sessions.save(before)
        try repositories.journal.save(pending)
        let wrongIdentity = try ZhulongPendingApplication(
            id: UUID(),
            kind: pending.kind,
            sessionID: pending.sessionID,
            beforeSnapshot: pending.beforeSnapshot,
            afterSnapshot: pending.afterSnapshot,
            beforeSession: pending.beforeSession,
            afterSession: pending.afterSession,
            createdAt: pending.createdAt
        )
        var wrongReplacement = before
        try wrongReplacement.pause(now: now.addingTimeInterval(3))

        XCTAssertThrowsError(
            try repositories.sessions.save(
                pending.afterSession,
                replacing: pending.beforeSession,
                authorizedBy: wrongIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .pendingApplicationConflict
            )
        }
        XCTAssertThrowsError(
            try repositories.sessions.save(
                wrongReplacement,
                replacing: pending.beforeSession,
                authorizedBy: pending
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .pendingApplicationConflict
            )
        }
        XCTAssertEqual(try repositories.sessions.load(before.id), before)
        XCTAssertEqual(try repositories.journal.load(), pending)
    }

    func testExactRecoveryCASAndAfterSessionClearCompletePendingProtocol() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "完成精确恢复")
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        try repositories.sessions.save(before)
        try repositories.journal.save(pending)

        try repositories.sessions.save(
            pending.afterSession,
            replacing: pending.beforeSession,
            authorizedBy: pending
        )
        try repositories.journal.clear(
            pending,
            requiring: .afterSession
        )

        XCTAssertEqual(
            try repositories.sessions.load(before.id),
            pending.afterSession
        )
        XCTAssertNil(try repositories.journal.load())
    }

    func testJournalClearRequiresExactPendingAndRequiredSessionState() throws {
        let repositories = makeRepositories()
        let before = try makeSession(intent: "核对 journal clear")
        let pending = try makePending(
            beforeSession: before,
            createdAt: now.addingTimeInterval(2)
        )
        try repositories.sessions.save(before)
        try repositories.journal.save(pending)
        let wrongIdentity = try ZhulongPendingApplication(
            id: UUID(),
            kind: pending.kind,
            sessionID: pending.sessionID,
            beforeSnapshot: pending.beforeSnapshot,
            afterSnapshot: pending.afterSnapshot,
            beforeSession: pending.beforeSession,
            afterSession: pending.afterSession,
            createdAt: pending.createdAt
        )

        XCTAssertThrowsError(
            try repositories.journal.clear(
                wrongIdentity,
                requiring: .beforeSession
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .pendingApplicationConflict
            )
        }
        XCTAssertThrowsError(
            try repositories.journal.clear(
                pending,
                requiring: .afterSession
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongSidecarRepositoryError,
                .sessionConflict
            )
        }
        XCTAssertEqual(try repositories.journal.load(), pending)

        try repositories.journal.clear(
            pending,
            requiring: .beforeSession
        )
        XCTAssertNil(try repositories.journal.load())
    }

    private func makeRepositories() -> (
        sessions: EncryptedFileZhulongSessionRepository,
        journal: EncryptedFileZhulongApplicationJournal
    ) {
        let keySource = SidecarTransactionKeySource(key: key)
        return (
            EncryptedFileZhulongSessionRepository(
                directoryURL: directoryURL,
                keySource: keySource
            ),
            EncryptedFileZhulongApplicationJournal(
                directoryURL: directoryURL,
                keySource: keySource
            )
        )
    }

    private func makeSession(
        intent: String,
        at createdAt: Date? = nil
    ) throws -> ZhulongSession {
        try ZhulongSession(
            primaryIntent: intent,
            proposedScopes: [.taskPool],
            now: createdAt ?? now
        )
    }

    private func makePending(
        beforeSession: ZhulongSession,
        createdAt: Date
    ) throws -> ZhulongPendingApplication {
        var afterSession = beforeSession
        try afterSession.pause(now: createdAt)
        let beforeEngine = NoonmarkEngine()
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "恢复围栏任务",
            now: createdAt
        )
        return try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: beforeSession.id,
            beforeSnapshot: beforeEngine.snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: afterSession,
            createdAt: createdAt
        )
    }
}

private struct SidecarTransactionKeySource: ZhulongSidecarKeySource {
    let key: Data

    func loadOrCreateKey() throws -> Data {
        key
    }
}

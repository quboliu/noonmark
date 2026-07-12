@testable import SuntraceZhulong
import XCTest

final class ZhulongMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let entryID = ZhulongSessionEntryID(
        UUID(uuidString: "AAAAAAAA-2000-0000-0000-000000000001")!
    )

    func testMemoryIsOptInAndCandidateDoesNotBecomeUsableBeforeConfirmation() throws {
        var ledger = ZhulongMemoryLedger()
        let candidate = try makeCandidate(content: "偏好在上午处理复杂任务")

        XCTAssertThrowsError(try ledger.propose(candidate)) { error in
            XCTAssertEqual(error as? ZhulongMemoryError, .disabled)
        }
        ledger.setEnabled(true)
        try ledger.propose(candidate)
        XCTAssertTrue(ledger.usableMemories.isEmpty)

        let confirmed = try ledger.confirmCandidate(
            candidate.id,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(ledger.usableMemories, [confirmed])
        XCTAssertEqual(confirmed.source, .zhulongInference)

        ledger.setEnabled(false)
        XCTAssertTrue(ledger.usableMemories.isEmpty)
    }

    func testConflictSuspendsExistingMemoryUntilUserAcceptsNewVersion() throws {
        var ledger = ZhulongMemoryLedger(isEnabled: true)
        let originalCandidate = try makeCandidate(content: "偏好上午深度工作")
        try ledger.propose(originalCandidate)
        let original = try ledger.confirmCandidate(
            originalCandidate.id,
            now: now.addingTimeInterval(2)
        )
        let replacement = try makeCandidate(
            content: "现在偏好晚上深度工作",
            conflictsWith: [original.reference],
            createdAt: now.addingTimeInterval(3)
        )
        try ledger.propose(replacement)

        XCTAssertTrue(ledger.usableMemories.isEmpty)
        XCTAssertThrowsError(
            try ledger.confirmCandidate(replacement.id, now: now.addingTimeInterval(4))
        ) { error in
            XCTAssertEqual(error as? ZhulongMemoryError, .conflictRequired)
        }
        let next = try XCTUnwrap(ledger.resolveConflicts(
            for: replacement.id,
            choice: .acceptCandidate,
            now: now.addingTimeInterval(4)
        ))

        XCTAssertEqual(next.memoryID, original.memoryID)
        XCTAssertEqual(next.version, 2)
        XCTAssertEqual(ledger.usableMemories, [next])
        XCTAssertEqual(ledger.memories.first?.status, .superseded)
    }

    func testForgetRemovesMemoryTextAndSuppressionBlocksSameTopic() throws {
        var ledger = ZhulongMemoryLedger(isEnabled: true)
        let candidate = try makeCandidate(content: "偏好较小的每日承诺")
        try ledger.propose(candidate)
        let memory = try ledger.confirmCandidate(
            candidate.id,
            now: now.addingTimeInterval(2)
        )

        try ledger.forget(
            memoryID: memory.memoryID,
            suppressFutureInference: true,
            now: now.addingTimeInterval(3)
        )

        XCTAssertFalse(ledger.memories.contains(where: { $0.memoryID == memory.memoryID }))
        XCTAssertFalse(String(describing: ledger).contains(memory.content))
        let repeated = try makeCandidate(
            content: "再次推断较小承诺偏好",
            createdAt: now.addingTimeInterval(4)
        )
        XCTAssertThrowsError(try ledger.propose(repeated)) { error in
            XCTAssertEqual(error as? ZhulongMemoryError, .suppressedTopic)
        }

        let userStatement = try makeCandidate(
            content: "我现在明确偏好较小的每日承诺",
            source: .userStatement,
            createdAt: now.addingTimeInterval(4)
        )
        XCTAssertNoThrow(try ledger.propose(userStatement))
    }

    private func makeCandidate(
        content: String,
        source: ZhulongMemoryCandidateSource = .zhulongInference,
        conflictsWith: [ZhulongMemoryVersionReference] = [],
        createdAt: Date? = nil
    ) throws -> ZhulongMemoryCandidate {
        let createdAt = createdAt ?? now.addingTimeInterval(1)
        return try ZhulongMemoryCandidate(
            topicKey: "commitment-size",
            content: content,
            source: source,
            evidenceWindowStart: now,
            evidenceWindowEnd: createdAt.addingTimeInterval(-0.5),
            evidenceReferences: [.sessionEntry(entryID)],
            confidence: 0.7,
            counterexamples: ["近期也有一次大型承诺按时完成"],
            conflictsWith: conflictsWith,
            createdAt: createdAt
        )
    }
}

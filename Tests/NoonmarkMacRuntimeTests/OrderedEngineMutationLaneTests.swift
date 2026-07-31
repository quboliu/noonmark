import Foundation
import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class OrderedEngineMutationLaneTests: XCTestCase {
    func testAsyncCommitsAreFIFOAndSecondStartsFromFirstCommit() async throws {
        let initial = NoonmarkEngine()
        let lane = OrderedEngineMutationLane(engine: initial)
        let firstStarted = expectation(description: "first started")
        let releaseFirst = DispatchSemaphore(value: 0)

        let first = Task {
            try await lane.commit { candidate, _ in
                firstStarted.fulfill()
                releaseFirst.wait()
                try candidate.updateLanguage(
                    .english,
                    now: Date(timeIntervalSince1970: 1)
                )
                return "first"
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let second = Task {
            try await lane.commit { candidate, source in
                XCTAssertEqual(source.preferences.language, .english)
                try candidate.updateTheme(
                    .warmPaper,
                    now: Date(timeIntervalSince1970: 2)
                )
                return "second"
            }
        }
        releaseFirst.signal()

        let firstCommit = try await first.value
        let secondCommit = try await second.value
        XCTAssertEqual(firstCommit.sequence, 1)
        XCTAssertEqual(secondCommit.sequence, 2)
        XCTAssertEqual(secondCommit.engine.preferences.language, .english)
        XCTAssertEqual(secondCommit.engine.preferences.theme, .warmPaper)
    }

    func testFailedCommitDoesNotAdvanceHead() async throws {
        enum ExpectedFailure: Error {
            case rejected
        }

        let lane = OrderedEngineMutationLane(engine: NoonmarkEngine())
        do {
            _ = try await lane.commit { candidate, _ in
                try candidate.updateLanguage(
                    .english,
                    now: Date(timeIntervalSince1970: 1)
                )
                throw ExpectedFailure.rejected
            } as OrderedEngineMutationLane.Commit<Void>
            XCTFail("expected rejection")
        } catch ExpectedFailure.rejected {
            // Expected.
        }

        let commit = try await lane.commit { candidate, source in
            XCTAssertEqual(source.preferences.language, .chinese)
            try candidate.updateTheme(
                .warmPaper,
                now: Date(timeIntervalSince1970: 1)
            )
            return true
        }
        XCTAssertEqual(commit.sequence, 1)
        XCTAssertEqual(commit.engine.preferences.language, .chinese)
    }

    func testSynchronousCommitQueuesBehindAsyncCommit() async throws {
        let lane = OrderedEngineMutationLane(engine: NoonmarkEngine())
        let firstStarted = expectation(description: "first started")
        let releaseFirst = DispatchSemaphore(value: 0)

        let first = Task {
            try await lane.commit { candidate, _ in
                firstStarted.fulfill()
                releaseFirst.wait()
                try candidate.updateLanguage(
                    .english,
                    now: Date(timeIntervalSince1970: 1)
                )
                return ()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        DispatchQueue.global().asyncAfter(
            deadline: .now() + 0.05
        ) {
            releaseFirst.signal()
        }
        let second = try lane.commitAndWait { candidate, source in
            XCTAssertEqual(source.preferences.language, .english)
            try candidate.updateTheme(
                .warmPaper,
                now: Date(timeIntervalSince1970: 2)
            )
            return ()
        }
        _ = try await first.value

        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(second.engine.preferences.language, .english)
        XCTAssertEqual(second.engine.preferences.theme, .warmPaper)
    }

    func testReplacementIsOrderedAndInvalidatesOlderPublicationSequence()
        async throws
    {
        let lane = OrderedEngineMutationLane(engine: NoonmarkEngine())
        let first = try await lane.commit { candidate, _ in
            try candidate.updateLanguage(
                .english,
                now: Date(timeIntervalSince1970: 1)
            )
            return ()
        }
        let replacement = NoonmarkEngine()
        try replacement.updateTheme(
            .warmPaper,
            now: Date(timeIntervalSince1970: 1)
        )
        let replacementSequence = lane.replaceAndWait(
            with: replacement
        )
        let next = try await lane.commit { _, source in
            XCTAssertEqual(source.preferences.language, .chinese)
            XCTAssertEqual(source.preferences.theme, .warmPaper)
            return ()
        }

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(replacementSequence, 2)
        XCTAssertEqual(next.sequence, 3)
    }
}

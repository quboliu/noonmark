import NoonmarkMacRuntime
import XCTest

final class TaskLabelInputQueryTests: XCTestCase {
    private let candidates = [
        TaskLabelInputCandidate(id: "client", name: "客户"),
        TaskLabelInputCandidate(id: "review", name: "复盘"),
        TaskLabelInputCandidate(id: "deep-work", name: "深度工作")
    ]

    func testHashTriggerOpensAllAvailableSuggestions() {
        let query = TaskLabelInputQuery("#")

        XCTAssertTrue(query.requestsSuggestions)
        XCTAssertEqual(query.normalizedName, "")
        XCTAssertEqual(
            query.matchingCandidates(in: candidates),
            candidates
        )
        XCTAssertEqual(query.submission(in: candidates), .empty)
    }

    func testHashQueryFiltersSuggestionsAndSelectsExactExistingLabel() {
        let partial = TaskLabelInputQuery("#客")
        XCTAssertEqual(
            partial.matchingCandidates(in: candidates),
            [TaskLabelInputCandidate(id: "client", name: "客户")]
        )

        let exact = TaskLabelInputQuery("# 客户 ")
        XCTAssertEqual(
            exact.submission(in: candidates),
            .existing(id: "client")
        )
    }

    func testDirectInputCreatesNormalizedLabelWhenNoExistingNameMatches() {
        let query = TaskLabelInputQuery("  新标签  ")

        XCTAssertFalse(query.requestsSuggestions)
        XCTAssertEqual(query.normalizedName, "新标签")
        XCTAssertTrue(query.matchingCandidates(in: candidates).isEmpty)
        XCTAssertEqual(
            query.submission(in: candidates),
            .new(name: "新标签")
        )
    }

    func testCanonicalExistingNameWinsOverCreatingDuplicate() {
        let query = TaskLabelInputQuery("  深度工作 ")

        XCTAssertEqual(
            query.submission(in: candidates),
            .existing(id: "deep-work")
        )
    }
}

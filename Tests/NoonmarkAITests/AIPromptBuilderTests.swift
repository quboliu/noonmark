@testable import NoonmarkAI
@testable import NoonmarkCore
import XCTest

final class AIPromptBuilderTests: XCTestCase {
    func testClassificationScopePreservesCategoryAndLabelTypesInPrompt() {
        let scope = AIScopeSnapshot(
            ranges: [],
            classifications: AIClassificationCatalogSnapshot(
                categories: ["工程", "生活"],
                labels: ["SwiftUI", "健康"]
            )
        )

        let request = AIPromptBuilder().buildRequest(
            task: .classification,
            scope: scope,
            report: LocalInsightReport(evidence: [], facts: [])
        )

        XCTAssertTrue(request.userPrompt.contains("主分类候选：工程，生活"))
        XCTAssertTrue(request.userPrompt.contains("标签候选：SwiftUI，健康"))
        XCTAssertEqual(request.metadata["task"], "classification")
    }

    func testCombiningClassificationScopesDeduplicatesEachTypeIndependently() {
        let combined = AIScopeSnapshot.combined([
            AIScopeSnapshot(
                ranges: [],
                classifications: AIClassificationCatalogSnapshot(
                    categories: ["工程"],
                    labels: ["健康"]
                )
            ),
            AIScopeSnapshot(
                ranges: [],
                classifications: AIClassificationCatalogSnapshot(
                    categories: ["生活", "工程"],
                    labels: ["SwiftUI", "健康"]
                )
            )
        ])

        XCTAssertEqual(combined.classifications.categories, ["工程", "生活"])
        XCTAssertEqual(combined.classifications.labels, ["SwiftUI", "健康"])
    }

    func testClearedTraceDescriptionDoesNotFallBackToDefinitionInPrompt() throws {
        let today = LocalDate("2026-07-23")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inheritedDescription = "快速记录自 Day Todo。"
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "清空描述",
            descriptionText: inheritedDescription,
            now: now
        )
        let traceID = try engine.scheduleFromPool(
            chainID: chainID,
            date: today,
            today: today,
            now: now.addingTimeInterval(1)
        )
        try engine.updateTraceText(
            traceID: traceID,
            descriptionText: "",
            today: today,
            now: now.addingTimeInterval(2)
        )
        let scope = AIScopeSnapshot.day(
            date: today,
            from: engine,
            requestedAt: now.addingTimeInterval(3)
        )

        let request = AIPromptBuilder().buildRequest(
            task: .dailyReview,
            scope: scope,
            report: LocalInsightAnalyzer().analyze(scope)
        )

        XCTAssertNil(engine.traces[traceID]?.descriptionText)
        XCTAssertFalse(request.userPrompt.contains(inheritedDescription))
    }
}

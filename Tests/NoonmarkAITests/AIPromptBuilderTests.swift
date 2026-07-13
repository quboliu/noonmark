@testable import NoonmarkAI
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
}

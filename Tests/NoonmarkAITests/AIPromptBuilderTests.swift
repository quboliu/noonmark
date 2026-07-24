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

    func testTaskPoolAnalysisScopeCarriesStableEvidenceIdentityAndContext() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = NoonmarkEngine()
        let chainID = try engine.createPoolTask(
            title: "准备发布",
            descriptionText: "确认版本范围与完成标准。",
            initialNoteBody: "等待法务确认。",
            now: now
        )
        _ = try engine.addPlannedSubtask(
            chainID: chainID,
            title: "整理发布核对表",
            difficulty: .medium,
            now: now.addingTimeInterval(1)
        )
        let emptyTitleChainID = try engine.createPoolTask(
            title: "临时标题",
            now: now.addingTimeInterval(2)
        )
        try engine.updatePoolTask(
            chainID: emptyTitleChainID,
            title: "",
            descriptionText: "保留空标题任务。",
            now: now.addingTimeInterval(3)
        )
        let scope = AIScopeSnapshot(
            ranges: [.taskPool],
            taskPool: engine.taskPool()
        )

        let request = AIPromptBuilder().buildRequest(
            task: .taskPoolAnalysis,
            scope: scope,
            report: LocalInsightAnalyzer().analyze(scope)
        )

        XCTAssertTrue(
            request.userPrompt.contains(
                "- taskID \(chainID)；标题：准备发布"
            )
        )
        XCTAssertTrue(
            request.userPrompt.contains(
                "描述：确认版本范围与完成标准。"
            )
        )
        XCTAssertTrue(
            request.userPrompt.contains(
                "附言：等待法务确认。"
            )
        )
        XCTAssertTrue(
            request.userPrompt.contains(
                "计划子任务：整理发布核对表[中]"
            )
        )
        XCTAssertTrue(
            request.userPrompt.contains(
                "- taskID \(emptyTitleChainID)；标题：null"
            )
        )
        XCTAssertEqual(request.metadata["task"], "taskPoolAnalysis")

        let schedulingRequest = AIPromptBuilder().buildRequest(
            task: .scheduling,
            scope: scope,
            report: LocalInsightAnalyzer().analyze(scope)
        )
        XCTAssertFalse(schedulingRequest.userPrompt.contains("taskID"))
        XCTAssertFalse(schedulingRequest.userPrompt.contains("计划子任务"))
    }
}

import NoonmarkMacRuntime
import XCTest

final class TaskPoolHomePresentationTests: XCTestCase {
    func testStatisticsUseOnlyPoolFactsAndKeepGroupingSeparateFromLabels() {
        let snapshot = TaskPoolStatisticsSnapshot(
            items: [
                TaskPoolStatisticsItem(
                    categoryID: "engineering",
                    labelIDs: ["urgent", "release"],
                    hasContext: true,
                    hasPlannedSubtasks: true,
                    hasReturnedToPool: false
                ),
                TaskPoolStatisticsItem(
                    categoryID: nil,
                    labelIDs: ["urgent"],
                    hasContext: false,
                    hasPlannedSubtasks: false,
                    hasReturnedToPool: true
                ),
                TaskPoolStatisticsItem(
                    categoryID: "product",
                    labelIDs: [],
                    hasContext: true,
                    hasPlannedSubtasks: false,
                    hasReturnedToPool: true
                )
            ]
        )

        XCTAssertEqual(snapshot.taskCount, 3)
        XCTAssertEqual(snapshot.categoryCount, 2)
        XCTAssertEqual(snapshot.labelCount, 2)
        XCTAssertEqual(snapshot.ungroupedTaskCount, 1)
        XCTAssertEqual(snapshot.contextualTaskCount, 2)
        XCTAssertEqual(snapshot.plannedTaskCount, 1)
        XCTAssertEqual(snapshot.returnedTaskCount, 2)
    }

    func testAnalysisIsAbsentUntilProviderConfigurationIsReady() {
        XCTAssertFalse(
            TaskPoolAnalysisAvailability(
                providerConfigurationIsReady: false
            ).isVisible
        )
        XCTAssertTrue(
            TaskPoolAnalysisAvailability(
                providerConfigurationIsReady: true
            ).isVisible
        )
    }

    func testAnalysisStateSeparatesGenerationFreshnessAndFailure() {
        let report = TaskPoolAnalysisReportPresentation(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            findings: [
                TaskPoolAnalysisFindingPresentation(
                    conclusion: "任务范围可能重叠",
                    evidenceTitles: ["准备发布", "上线新版"],
                    confidence: .medium,
                    uncertainty: "版本范围尚不明确",
                    recommendation: "先确认版本边界"
                )
            ]
        )

        XCTAssertNil(
            TaskPoolAnalysisProjection.state(
                availability: .unavailable,
                run: nil,
                currentContextVersion: "pool-v2"
            )
        )
        XCTAssertEqual(
            TaskPoolAnalysisProjection.state(
                availability: .ready,
                run: .running,
                currentContextVersion: "pool-v2"
            ),
            .generating
        )
        XCTAssertEqual(
            TaskPoolAnalysisProjection.state(
                availability: .ready,
                run: .succeeded(
                    contextVersion: "pool-v1",
                    report: report
                ),
                currentContextVersion: "pool-v2"
            ),
            .report(report, freshness: .outdated)
        )
        XCTAssertEqual(
            TaskPoolAnalysisProjection.state(
                availability: .ready,
                run: .failed,
                currentContextVersion: "pool-v2"
            ),
            .failed
        )
    }
}

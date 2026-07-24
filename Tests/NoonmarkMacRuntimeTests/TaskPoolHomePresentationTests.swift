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
}

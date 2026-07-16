import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class CalendarInsightPresentationTests: XCTestCase {
    func testTodayRiskUsesContinuationCopyWithoutSuggestingSilentRescheduling() {
        let chinese = AppPresentation(language: .chinese).calendarInsight.riskSummary(
            position: .today,
            unresolved: 0,
            pending: 4,
            total: 4
        )
        let english = AppPresentation(language: .english).calendarInsight.riskSummary(
            position: .today,
            unresolved: 0,
            pending: 4,
            total: 4
        )

        XCTAssertTrue(chinese.contains("当日优先级"))
        XCTAssertTrue(chinese.contains("延续复制"))
        XCTAssertFalse(chinese.contains("改期"))
        XCTAssertTrue(english.contains("continuation copying"))
        XCTAssertFalse(english.contains("reschedule"))
    }

    func testFutureRiskUsesPlanDraftReschedulingLanguage() {
        let chinese = AppPresentation(language: .chinese).calendarInsight.riskSummary(
            position: .future,
            unresolved: 0,
            pending: 5,
            total: 5
        )
        let english = AppPresentation(language: .english).calendarInsight.riskSummary(
            position: .future,
            unresolved: 0,
            pending: 5,
            total: 5
        )

        XCTAssertTrue(chinese.contains("计划草稿"))
        XCTAssertTrue(chinese.contains("改期"))
        XCTAssertFalse(chinese.contains("延续复制"))
        XCTAssertTrue(english.contains("reschedule"))
    }

    func testHistoryAndEmptyDayRiskRemainPositionSpecific() {
        let presentation = AppPresentation(language: .english).calendarInsight

        XCTAssertEqual(
            presentation.riskSummary(
                position: .history,
                unresolved: 2,
                pending: 0,
                total: 2
            ),
            "This past day has 2 unresolved or dropped items; add the reason to the review."
        )
        XCTAssertEqual(
            presentation.riskSummary(
                position: .future,
                unresolved: 0,
                pending: 0,
                total: 0
            ),
            "This future day has no plans; leave it open or schedule from the Task Pool."
        )
        XCTAssertEqual(
            presentation.riskSummary(
                position: .today,
                unresolved: 0,
                pending: 0,
                total: 0
            ),
            "No tasks were recorded that day."
        )
    }
}

@testable import SuntraceAI
@testable import SuntraceCore
import XCTest

final class AISuggestionResponseParserTests: XCTestCase {
    func testPlainTextResponseRemainsSummaryOnly() throws {
        let response = try AISuggestionResponseParser().parse("事实：今天有两个未完成。")

        XCTAssertEqual(response.text, "事实：今天有两个未完成。")
        XCTAssertEqual(response.proposedOperations, [])
        XCTAssertNil(response.confidence)
    }

    func testStructuredResponseParsesSafeOperations() throws {
        let raw = """
        {
          "summary": "事实：任务池仍有任务。建议：先创建一个收敛任务并补复盘。",
          "confidence": 0.71,
          "proposedOperations": [
            {
              "type": "createPoolTask",
              "title": "收敛远程建议解析",
              "descriptionText": "只允许安全草稿操作",
              "note": "确认后才落库"
            },
            {
              "type": "updateDailyReview",
              "date": "2026-07-05",
              "summary": "今日完成结构化解析。",
              "unfinishedReason": "剩余远程 ID 映射暂不做。",
              "tomorrowNote": "补真实 UI 自动化。"
            }
          ]
        }
        """

        let response = try AISuggestionResponseParser().parse(raw)

        XCTAssertEqual(response.text, "事实：任务池仍有任务。建议：先创建一个收敛任务并补复盘。")
        XCTAssertEqual(response.confidence, 0.71)
        XCTAssertEqual(
            response.proposedOperations,
            [
                .createPoolTask(
                    title: "收敛远程建议解析",
                    descriptionText: "只允许安全草稿操作",
                    note: "确认后才落库"
                ),
                .updateDailyReview(
                    date: LocalDate("2026-07-05"),
                    summary: "今日完成结构化解析。",
                    unfinishedReason: "剩余远程 ID 映射暂不做。",
                    tomorrowNote: "补真实 UI 自动化。"
                )
            ]
        )
    }

    func testUnsupportedOperationFailsClosed() throws {
        let raw = """
        {
          "summary": "建议排期。",
          "proposedOperations": [
            { "type": "scheduleFromPool", "targetDate": "2026-07-06" }
          ]
        }
        """

        XCTAssertThrowsError(try AISuggestionResponseParser().parse(raw)) { error in
            XCTAssertEqual(error as? AISuggestionResponseParseError, .unsupportedOperation("scheduleFromPool"))
        }
    }
}

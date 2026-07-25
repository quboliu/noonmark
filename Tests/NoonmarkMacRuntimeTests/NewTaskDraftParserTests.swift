@testable import NoonmarkMacRuntime
import XCTest

final class NewTaskDraftParserTests: XCTestCase {
    func testParsesLabelsAndOneCategoryWithoutLeakingTokensIntoTitle() {
        let draft = NewTaskDraftParser.parse(
            "准备发布 @工作 #紧急 #本周"
        )

        XCTAssertEqual(draft.title, "准备发布")
        XCTAssertEqual(draft.categoryName, "工作")
        XCTAssertEqual(draft.labelNames, ["紧急", "本周"])
        XCTAssertNil(draft.issue)
    }

    func testQuotedTokensSupportClassificationNamesContainingSpaces() {
        let draft = NewTaskDraftParser.parse(
            #"Prepare release @"Client Work" #"Deep Focus""#
        )

        XCTAssertEqual(draft.title, "Prepare release")
        XCTAssertEqual(draft.categoryName, "Client Work")
        XCTAssertEqual(draft.labelNames, ["Deep Focus"])
        XCTAssertNil(draft.issue)
    }

    func testClassificationMarkersInsideWordsRemainTaskContent() {
        let draft = NewTaskDraftParser.parse(
            "邮件发到 dev@example.com 并更新 C# 文档"
        )

        XCTAssertEqual(draft.title, "邮件发到 dev@example.com 并更新 C# 文档")
        XCTAssertNil(draft.categoryName)
        XCTAssertEqual(draft.labelNames, [])
        XCTAssertNil(draft.issue)
    }

    func testChineseTitleCanBeFollowedImmediatelyByClassificationToken() {
        let draft = NewTaskDraftParser.parse("买菜#生活")

        XCTAssertEqual(draft.title, "买菜")
        XCTAssertEqual(draft.labelNames, ["生活"])
    }

    func testMultipleCategoriesFailClosed() {
        let draft = NewTaskDraftParser.parse(
            "准备发布 @工作 @个人 #紧急"
        )

        XCTAssertEqual(
            draft.issue,
            .multipleCategories(["工作", "个人"])
        )
    }

    func testActiveTokenAndCompletionUseTheMatchingMarker() {
        XCTAssertEqual(
            NewTaskDraftParser.activeToken(in: "准备 #紧"),
            NewTaskClassificationToken(kind: .label, query: "紧")
        )
        XCTAssertEqual(
            NewTaskDraftParser.activeToken(in: "准备 @工"),
            NewTaskClassificationToken(kind: .category, query: "工")
        )
        XCTAssertEqual(
            NewTaskDraftParser.completingActiveToken(
                in: "Prepare @cli",
                with: "Client Work"
            ),
            #"Prepare @"Client Work" "#
        )
    }
}

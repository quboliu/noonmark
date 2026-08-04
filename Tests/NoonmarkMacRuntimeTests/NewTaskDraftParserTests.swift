@testable import NoonmarkMacRuntime
import XCTest

final class NewTaskDraftParserTests: XCTestCase {
    func testIdeaDraftPreservesLineBreaksWhileRemovingClassificationTokens() {
        let draft = IdeaDraftParser.parse(
            "第一行原样保留\n第二行继续说明 #灵感 @工作"
        )

        XCTAssertEqual(draft.body, "第一行原样保留\n第二行继续说明")
        XCTAssertEqual(draft.categoryName, "工作")
        XCTAssertEqual(draft.labelNames, ["灵感"])
        XCTAssertNil(draft.issue)
    }

    func testIdeaDraftPreservesMarkdownCodeAndLinkDestinations() {
        let draft = IdeaDraftParser.parse(
            """
            ## API note
            Use `#define @value` and [profile](https://example.com/@user).
            ```c
            #include <stdio.h>
            @main
            ```
            #reference @Engineering
            """
        )

        XCTAssertEqual(
            draft.body,
            """
            ## API note
            Use `#define @value` and [profile](https://example.com/@user).
            ```c
            #include <stdio.h>
            @main
            ```
            """
        )
        XCTAssertEqual(draft.categoryName, "Engineering")
        XCTAssertEqual(draft.labelNames, ["reference"])
    }

    func testIdeaDraftPreservesEscapedMarkersAndBareURLFragments() {
        let draft = IdeaDraftParser.parse(
            "Keep \\#literal and https://example.com/@user plus #reference @Engineering"
        )

        XCTAssertEqual(
            draft.body,
            "Keep \\#literal and https://example.com/@user plus"
        )
        XCTAssertEqual(draft.categoryName, "Engineering")
        XCTAssertEqual(draft.labelNames, ["reference"])
    }

    func testIdeaActiveTokenIgnoresMarkdownCode() {
        XCTAssertNil(IdeaDraftParser.activeToken(in: "Use `#define"))
        XCTAssertEqual(
            IdeaDraftParser.activeToken(in: "Use `#define` #ref"),
            NewTaskClassificationToken(kind: .label, query: "ref")
        )
    }

    func testIdeaActiveTokenIgnoresEscapedMarkerAndBareURLFragment() {
        XCTAssertNil(IdeaDraftParser.activeToken(in: "Keep \\#literal"))
        XCTAssertNil(
            IdeaDraftParser.activeToken(in: "https://example.com/@user")
        )
    }

    func testIdeaEditableTextRoundTripsClassificationNamesContainingSpaces() {
        let editable = IdeaDraftParser.editableText(
            body: "Keep the authored body",
            categoryName: "Client Work",
            labelNames: ["Deep Focus", "reference"]
        )
        let roundTrip = IdeaDraftParser.parse(editable)

        XCTAssertEqual(
            editable,
            "Keep the authored body\n@\"Client Work\" #\"Deep Focus\" #reference"
        )
        XCTAssertEqual(roundTrip.body, "Keep the authored body")
        XCTAssertEqual(roundTrip.categoryName, "Client Work")
        XCTAssertEqual(roundTrip.labelNames, ["Deep Focus", "reference"])
        XCTAssertNil(roundTrip.issue)
    }

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

    func testRecurringSlashCommandIsRemovedFromTaskTitle() {
        let chinese = NewTaskDraftParser.parse(
            "/重复 晨跑五公里 @生活 #健康"
        )
        let english = NewTaskDraftParser.parse(
            "/repeat Write weekly report #review"
        )

        XCTAssertEqual(chinese.command, .recurring)
        XCTAssertEqual(chinese.title, "晨跑五公里")
        XCTAssertEqual(chinese.categoryName, "生活")
        XCTAssertEqual(chinese.labelNames, ["健康"])
        XCTAssertEqual(english.command, .recurring)
        XCTAssertEqual(english.title, "Write weekly report")
        XCTAssertEqual(english.labelNames, ["review"])
    }

    func testSlashCommandQueryOnlyActivatesAtDraftStart() {
        XCTAssertEqual(
            NewTaskDraftParser.activeCommandQuery(in: "/重"),
            "重"
        )
        XCTAssertEqual(
            NewTaskDraftParser.activeCommandQuery(in: "/rep"),
            "rep"
        )
        XCTAssertNil(
            NewTaskDraftParser.activeCommandQuery(
                in: "整理 /repeat 文档"
            )
        )
        XCTAssertNil(
            NewTaskDraftParser.activeCommandQuery(
                in: "/repeat 晨跑"
            )
        )
    }
}

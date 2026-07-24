@testable import NoonmarkMacRuntime
import XCTest

final class ZhulongConversationCommandTests: XCTestCase {
    func testExplicitCommitPhrasesAreRecognized() {
        for command in [
            "提交",
            "提交吧！",
            "确认提交",
            "按这个提交",
            "确认并提交",
            "Commit it!"
        ] {
            XCTAssertTrue(
                ZhulongConversationCommand.isCommit(command),
                command
            )
        }
    }

    func testDiscussionAndNegationDoNotBecomeCommitAuthority() {
        for content in [
            "怎么提交？",
            "不要提交",
            "先改一下再提交",
            "我想讨论提交后的行为",
            "就这样安排",
            "可以提交",
            "保存",
            "执行吧",
            "looks good"
        ] {
            XCTAssertFalse(
                ZhulongConversationCommand.isCommit(content),
                content
            )
        }
    }
}

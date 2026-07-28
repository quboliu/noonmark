import NoonmarkCore
import NoonmarkMacRuntime
import XCTest

final class OperationFailurePresentationTests: XCTestCase {
    func testEveryOperationFailureHasDistinctChineseAndEnglishCopy() {
        let chinese = AppPresentation(language: .chinese)
        let english = AppPresentation(language: .english)

        for context in AppOperationFailureContext.allCases {
            let chineseMessage = chinese.failureMessage(for: context)
            let englishMessage = english.failureMessage(for: context)
            XCTAssertFalse(chineseMessage.isEmpty)
            XCTAssertFalse(englishMessage.isEmpty)
            XCTAssertNotEqual(chineseMessage, englishMessage)
        }
    }

    func testFailureCopyNeverIncludesUnderlyingErrorDetail() {
        let secret = "SECRET_DATABASE_PATH"
        let presentation = AppPresentation(language: .english)

        for context in [
            AppOperationFailureContext.persistence,
            .sync,
            .dataTransfer,
            .databaseLoad
        ] {
            XCTAssertFalse(
                presentation.failureMessage(for: context).contains(secret)
            )
        }
    }

    func testSyncBaselineFailuresExplicitlyRejectFalseSuccess() {
        let chinese = AppPresentation(language: .chinese)
        let english = AppPresentation(language: .english)

        for reason in AppSyncFailureReason.allCases {
            let chineseMessage = chinese.syncFailureMessage(for: reason)
            let englishMessage = english.syncFailureMessage(for: reason)
            XCTAssertTrue(chineseMessage.contains("同步未完成"))
            XCTAssertTrue(chineseMessage.contains("没有将本次操作标记为成功"))
            XCTAssertTrue(englishMessage.contains("Sync did not complete"))
            XCTAssertTrue(englishMessage.contains("was not marked as successful"))
        }
    }
}

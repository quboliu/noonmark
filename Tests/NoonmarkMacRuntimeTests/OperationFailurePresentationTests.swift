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
}

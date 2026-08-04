import Foundation
@testable import NoonmarkMacRuntime
import NoonmarkCore
import XCTest

@MainActor
final class IdeaCaptureSessionTests: XCTestCase {
    func testComposerRestoresDraftAndClearsItOnlyAfterSuccessfulCapture() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = IdeaComposerDraftRepository(defaults: defaults)
        repository.save("第一行\n第二行 #记录")
        let session = IdeaComposerSession(repository: repository)
        var capturedBody: String?

        XCTAssertEqual(session.text, "第一行\n第二行 #记录")

        let saved = session.submit { body in
            capturedBody = body
            return true
        }

        XCTAssertTrue(saved)
        XCTAssertEqual(capturedBody, "第一行\n第二行 #记录")
        XCTAssertEqual(session.text, "")
        XCTAssertEqual(repository.load(), "")
        XCTAssertEqual(session.submissionState, .idle)
    }

    func testComposerPersistsEveryRevisionAndRetainsFailedSubmission() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = IdeaComposerDraftRepository(defaults: defaults)
        let session = IdeaComposerSession(repository: repository)

        session.updateText("  尚未保存的想法\n")
        let saved = session.submit { _ in false }

        XCTAssertFalse(saved)
        XCTAssertEqual(session.text, "  尚未保存的想法\n")
        XCTAssertEqual(repository.load(), "  尚未保存的想法\n")
        XCTAssertEqual(session.submissionState, .failed)
    }

    func testComposerRejectsWhitespaceWithoutCallingCapture() {
        let session = IdeaComposerSession(
            repository: InMemoryIdeaComposerDraftRepository(" \n ")
        )
        var captureWasCalled = false

        let saved = session.submit { _ in
            captureWasCalled = true
            return true
        }

        XCTAssertFalse(saved)
        XCTAssertFalse(captureWasCalled)
        XCTAssertEqual(session.submissionState, .empty)
    }

    func testInlineEditorCommitsNormalizedTextAndEndsSession() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        var observed: (IdeaID, String)?
        session.begin(id: id, body: "原来的想法")
        session.updateText("  修改后的想法\n")

        let saved = session.save { savedID, body in
            observed = (savedID, body)
            return true
        }

        XCTAssertTrue(saved)
        XCTAssertEqual(observed?.0, id)
        XCTAssertEqual(observed?.1, "修改后的想法")
        XCTAssertNil(session.ideaID)
        XCTAssertEqual(session.draftText, "")
        XCTAssertEqual(session.saveState, .idle)
    }

    func testInlineEditorKeepsRecoverableDraftWhenSaveFails() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        session.begin(id: id, body: "原文")
        session.updateText("不能丢的修改")

        let saved = session.save { _, _ in false }

        XCTAssertFalse(saved)
        XCTAssertEqual(session.ideaID, id)
        XCTAssertEqual(session.draftText, "不能丢的修改")
        XCTAssertEqual(session.originalText, "原文")
        XCTAssertEqual(session.saveState, .failed)
    }

    func testInlineEditorEscapeCancelsWithoutSaving() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        session.begin(id: id, body: "原文")
        session.updateText("应该放弃")

        session.cancel()

        XCTAssertNil(session.ideaID)
        XCTAssertEqual(session.draftText, "")
        XCTAssertEqual(session.saveState, .idle)
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "IdeaCaptureSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}

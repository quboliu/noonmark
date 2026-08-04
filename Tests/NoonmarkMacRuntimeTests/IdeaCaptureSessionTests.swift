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
        XCTAssertEqual(session.submissionState, .succeeded)
    }

    func testComposerPersistsEveryRevisionAndRetainsFailedSubmission() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = IdeaComposerDraftRepository(defaults: defaults)
        let session = IdeaComposerSession(repository: repository)

        session.updateText("  尚未保存的想法\n")
        let saved = session.submit { _ in
            session.setFailureMessage("分类不存在")
            return false
        }

        XCTAssertFalse(saved)
        XCTAssertEqual(session.text, "  尚未保存的想法\n")
        XCTAssertEqual(repository.load(), "  尚未保存的想法\n")
        XCTAssertEqual(session.submissionState, .failed)
        XCTAssertEqual(session.failureMessage, "分类不存在")
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
        XCTAssertEqual(session.saveState, .succeeded)
        XCTAssertEqual(session.lastSavedIdeaID, id)
    }

    func testInlineEditorKeepsRecoverableDraftWhenSaveFails() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        session.begin(id: id, body: "原文")
        session.updateText("不能丢的修改")

        let saved = session.save { _, _ in
            session.setFailureMessage("写入失败")
            return false
        }

        XCTAssertFalse(saved)
        XCTAssertEqual(session.ideaID, id)
        XCTAssertEqual(session.draftText, "不能丢的修改")
        XCTAssertEqual(session.originalText, "原文")
        XCTAssertEqual(session.saveState, .failed)
        XCTAssertEqual(session.failureMessage, "写入失败")
    }

    func testInlineEditorBeginningTheSameIdeaDoesNotOverwriteDirtyDraft() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        session.begin(id: id, body: "原文")
        session.updateText("不能被重复双击覆盖的修改")

        session.begin(id: id, body: "原文")

        XCTAssertEqual(session.ideaID, id)
        XCTAssertEqual(session.originalText, "原文")
        XCTAssertEqual(session.draftText, "不能被重复双击覆盖的修改")
    }

    func testInlineEditorRefusesToReplaceAnActiveIdeaWithoutEndingIt() {
        let firstID = IdeaID()
        let secondID = IdeaID()
        let session = IdeaInlineEditorSession()
        session.begin(id: firstID, body: "第一条原文")
        session.updateText("第一条不能丢的修改")

        session.begin(id: secondID, body: "第二条原文")

        XCTAssertEqual(session.ideaID, firstID)
        XCTAssertEqual(session.originalText, "第一条原文")
        XCTAssertEqual(session.draftText, "第一条不能丢的修改")
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

    func testInlineEditorExplicitCancelSuppressesFollowingBlurPersistence() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        var persistedBodies: [String] = []
        session.begin(id: id, body: "原文")
        session.updateText("必须放弃的修改")

        XCTAssertTrue(
            session.end(reason: .explicitCancel) { _, body in
                persistedBodies.append(body)
                return true
            }
        )
        XCTAssertFalse(
            session.end(reason: .blur) { _, body in
                persistedBodies.append(body)
                return true
            }
        )

        XCTAssertTrue(persistedBodies.isEmpty)
        XCTAssertNil(session.ideaID)
    }

    func testInlineEditorBlurPersistsDirtyDraftThroughTheSameEndPath() {
        let id = IdeaID()
        let session = IdeaInlineEditorSession()
        var persistedBody: String?
        session.begin(id: id, body: "原文")
        session.updateText("失焦时保存")

        let saved = session.end(reason: .blur) { _, body in
            persistedBody = body
            return true
        }

        XCTAssertTrue(saved)
        XCTAssertEqual(persistedBody, "失焦时保存")
        XCTAssertNil(session.ideaID)
    }

    private func makeIsolatedDefaults() -> (String, UserDefaults) {
        let suiteName = "IdeaCaptureSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}

import AppKit
import Foundation
import NoonmarkCore

/// Drives the visible task-note controls with real window mouse events.
/// It deliberately has no reference to `NoonmarkStore`, so an E2E run cannot bypass the UI
/// by calling the note mutation methods directly.
@MainActor
enum TaskNoteE2EUIInteractionDriver {
    static func start(
        state: TaskNoteE2EState,
        editedBody: String,
        resultURL: URL
    ) {
        InteractionSession(
            state: state,
            editedBody: editedBody,
            resultURL: resultURL
        ).start()
    }

    @MainActor
    private final class InteractionSession {
        private let state: TaskNoteE2EState
        private let editedBody: String
        private let resultURL: URL
        private var actionMenuIdentity: AppViewTreeE2E.PresentationWindowIdentity?

        init(state: TaskNoteE2EState, editedBody: String, resultURL: URL) {
            self.state = state
            self.editedBody = editedBody
            self.resultURL = resultURL
        }

        func start() {
            waitFor("编辑目标的附言操作按钮") { [self] in
                guard let button = element(identifier: editedActionsIdentifier) else { return false }
                return click(button)
            } onSuccess: { [self] in
                selectEditMenuItem()
            }
        }

        private func selectEditMenuItem() {
            waitFor("编辑附言菜单项") { [self] in
                guard let item = element(identifier: editedMenuIdentifier),
                      let identity = AppViewTreeE2E.mappedPresentationWindow(
                          identifier: editedMenuIdentifier
                      )
                else { return false }
                actionMenuIdentity = identity
                return click(item)
            } onSuccess: { [self] in
                enterEditedBody()
            }
        }

        private func enterEditedBody() {
            waitFor("附言编辑器") { [self] in
                guard let actionMenuIdentity,
                      AppViewTreeE2E.isPresentationWindowOpen(actionMenuIdentity) == false
                else { return false }
                guard let textView = element(
                    identifier: "\(editedEditorIdentifier).input"
                ) as? NSTextView else {
                    return false
                }
                textView.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
                textView.insertText(editedBody, replacementRange: textView.selectedRange())
                return textView.string == editedBody
                    && AppViewTreeE2E.hasNoVisibleView(
                        identifier: deletedActionsIdentifier
                    )
            } onSuccess: { [self] in
                saveEdit()
            }
        }

        private func saveEdit() {
            waitFor("保存附言按钮") { [self] in
                guard let button = element(identifier: editedSaveIdentifier) else { return false }
                return click(button)
            } onSuccess: { [self] in
                waitFor("保存后编辑器消失") { [self] in
                    AppViewTreeE2E.hasNoVisibleView(identifier: editedEditorStateIdentifier)
                } onSuccess: { [self] in
                    openDeleteMenu()
                }
            }
        }

        private func openDeleteMenu() {
            waitFor("删除目标的附言操作按钮") { [self] in
                guard let button = element(identifier: deletedActionsIdentifier) else { return false }
                return click(button)
            } onSuccess: { [self] in
                selectDeleteMenuItem()
            }
        }

        private func selectDeleteMenuItem() {
            waitFor("删除附言菜单项") { [self] in
                guard let item = element(identifier: deletedMenuIdentifier),
                      let identity = AppViewTreeE2E.mappedPresentationWindow(
                          identifier: deletedMenuIdentifier
                      )
                else { return false }
                actionMenuIdentity = identity
                return click(item)
            } onSuccess: { [self] in
                waitFor("删除后的附言行消失") { [self] in
                    guard let actionMenuIdentity else { return false }
                    return AppViewTreeE2E.hasNoVisibleView(
                        identifier: deletedEntryStateIdentifier
                    )
                        && AppViewTreeE2E.isPresentationWindowOpen(actionMenuIdentity) == false
                } onSuccess: { [self] in
                    finish(with: "ok")
                }
            }
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 60,
            action: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            if action() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onSuccess)
                return
            }
            guard attemptsRemaining > 1 else {
                fail("等待真实 UI 超时：\(step)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                waitFor(
                    step,
                    attemptsRemaining: attemptsRemaining - 1,
                    action: action,
                    onSuccess: onSuccess
                )
            }
        }

        private func element(identifier: String) -> NSView? {
            AppViewTreeE2E.view(identifier: identifier)
        }

        private func click(_ view: NSView) -> Bool {
            AppViewTreeE2E.click(view)
        }

        private func fail(_ message: String) {
            writeViewTreeDump()
            finish(with: "failed: \(message)")
        }

        private func finish(with result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Noonmark task-note UI E2E result write failed: %@", String(describing: error))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }

        private func writeViewTreeDump() {
            AppViewTreeE2E.writeDump(beside: resultURL)
        }

        private var editedActionsIdentifier: String {
            "detail.note.actions.\(state.editedNoteID.description)"
        }

        private var deletedActionsIdentifier: String {
            "detail.note.actions.\(state.deletedNoteID.description)"
        }

        private var editedEditorIdentifier: String {
            "detail.note.editor.\(state.editedNoteID.description)"
        }

        private var editedEditorStateIdentifier: String {
            "detail.note.editor.state.\(state.editedNoteID.description)"
        }

        private var deletedEntryStateIdentifier: String {
            "detail.note.entry.state.\(state.deletedNoteID.description)"
        }

        private var editedMenuIdentifier: String {
            "detail.note.edit.\(state.editedNoteID.description)"
        }

        private var deletedMenuIdentifier: String {
            "detail.note.delete.\(state.deletedNoteID.description)"
        }

        private var editedSaveIdentifier: String {
            "detail.note.save.\(state.editedNoteID.description)"
        }
    }
}

/// Verifies that a real failed note edit preserves the visible editor and draft.
@MainActor
enum TaskNotePersistenceFailureUIE2EDriver {
    static func start(
        noteID: TaskNoteEntryID,
        otherNoteID: TaskNoteEntryID,
        editedBody: String,
        expectedFailureMessage: String,
        resultURL: URL
    ) {
        Session(
            noteID: noteID,
            otherNoteID: otherNoteID,
            editedBody: editedBody,
            expectedFailureMessage: expectedFailureMessage,
            resultURL: resultURL
        ).start()
    }

    @MainActor
    private final class Session {
        private let noteID: TaskNoteEntryID
        private let otherNoteID: TaskNoteEntryID
        private let editedBody: String
        private let expectedFailureMessage: String
        private let resultURL: URL

        init(
            noteID: TaskNoteEntryID,
            otherNoteID: TaskNoteEntryID,
            editedBody: String,
            expectedFailureMessage: String,
            resultURL: URL
        ) {
            self.noteID = noteID
            self.otherNoteID = otherNoteID
            self.editedBody = editedBody
            self.expectedFailureMessage = expectedFailureMessage
            self.resultURL = resultURL
        }

        func start() {
            waitFor("保存失败目标的附言操作按钮") { [self] in
                guard let button = AppViewTreeE2E.view(identifier: actionsIdentifier) else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                openEditor()
            }
        }

        private func openEditor() {
            waitFor("保存失败目标的编辑菜单项") { [self] in
                guard let button = AppViewTreeE2E.view(identifier: editMenuIdentifier) else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                enterDraft()
            }
        }

        private func enterDraft() {
            waitFor("保存失败目标的附言编辑器") { [self] in
                guard let textView = AppViewTreeE2E.view(
                    identifier: editorIdentifier
                ) as? NSTextView else {
                    return false
                }
                textView.window?.makeFirstResponder(textView)
                textView.selectAll(nil)
                textView.insertText(
                    editedBody,
                    replacementRange: textView.selectedRange()
                )
                return textView.string == editedBody
                    && AppViewTreeE2E.hasNoVisibleView(
                        identifier: otherActionsIdentifier
                    )
            } onSuccess: { [self] in
                saveDraft()
            }
        }

        private func saveDraft() {
            waitFor("保存失败目标的保存按钮") { [self] in
                guard let button = AppViewTreeE2E.view(identifier: saveIdentifier) else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                waitFor("保存失败后编辑器、草稿与失败反馈仍可见") { [self] in
                    guard AppViewTreeE2E.view(identifier: editorStateIdentifier) != nil,
                          let textView = AppViewTreeE2E.view(
                              identifier: editorIdentifier
                          ) as? NSTextView,
                          textView.string == editedBody,
                          let failure = AppViewTreeE2E.view(
                              identifier: "app.operation-failure"
                          ),
                          AppViewTreeE2E.verificationText(for: failure)
                              == expectedFailureMessage
                    else {
                        return false
                    }
                    return true
                } onSuccess: { [self] in
                    retrySave()
                }
            }
        }

        private func retrySave() {
            waitFor("保存失败后的重试按钮") { [self] in
                guard let button = AppViewTreeE2E.view(identifier: saveIdentifier) else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                waitFor("重试成功后编辑器与对应失败反馈消失") { [self] in
                    guard AppViewTreeE2E.hasNoVisibleView(
                        identifier: editorStateIdentifier
                    ),
                    AppViewTreeE2E.hasNoVisibleView(
                        identifier: "app.operation-failure"
                    ),
                    let entry = AppViewTreeE2E.view(identifier: entryStateIdentifier),
                    AppViewTreeE2E.verificationText(for: entry) == editedBody,
                    AppViewTreeE2E.hasNoAttachedPresentationWindows()
                    else {
                        return false
                    }
                    return true
                } onSuccess: { [self] in
                    finish(with: "ok")
                }
            }
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 60,
            action: @escaping @MainActor () -> Bool,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            if action() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: onSuccess)
                return
            }
            guard attemptsRemaining > 1 else {
                AppViewTreeE2E.writeDump(beside: resultURL)
                finish(with: "failed: 等待真实 UI 超时：\(step)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                waitFor(
                    step,
                    attemptsRemaining: attemptsRemaining - 1,
                    action: action,
                    onSuccess: onSuccess
                )
            }
        }

        private func finish(with result: String) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark task-note save-failure UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }

        private var actionsIdentifier: String {
            "detail.note.actions.\(noteID.description)"
        }

        private var otherActionsIdentifier: String {
            "detail.note.actions.\(otherNoteID.description)"
        }

        private var editMenuIdentifier: String {
            "detail.note.edit.\(noteID.description)"
        }

        private var editorIdentifier: String {
            "detail.note.editor.\(noteID.description).input"
        }

        private var editorStateIdentifier: String {
            "detail.note.editor.state.\(noteID.description)"
        }

        private var entryStateIdentifier: String {
            "detail.note.entry.state.\(noteID.description)"
        }

        private var saveIdentifier: String {
            "detail.note.save.\(noteID.description)"
        }
    }
}

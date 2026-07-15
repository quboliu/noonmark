import AppKit
import Foundation

/// Verifies the English task-note copy through the live AppKit view tree.
/// Stable identifiers drive actions; localized labels are assertions, never selectors.
@MainActor
enum TaskNoteCopyE2EUIInteractionDriver {
    static func start(state: TaskNoteE2EState, resultURL: URL) {
        Session(state: state, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let state: TaskNoteE2EState
        private let resultURL: URL

        init(state: TaskNoteE2EState, resultURL: URL) {
            self.state = state
            self.resultURL = resultURL
        }

        func start() {
            waitFor("English 附言区与输入框") { [self] in
                elementHasText(identifier: "detail.note.section", expected: "Notes")
                    && elementHasText(
                        identifier: "detail.note.composer.copy",
                        expected: "Add a note, press Return"
                    )
            } onSuccess: { [self] in
                openActionMenu()
            }
        }

        private func openActionMenu() {
            waitFor("English 附言操作入口") { [self] in
                guard let button = AppViewTreeE2E.view(
                    identifier: actionsIdentifier
                ), elementHasText(button, expected: "Note actions") else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                verifyMenu()
            }
        }

        private func verifyMenu() {
            waitFor("English 编辑与删除菜单") { [self] in
                elementHasText(identifier: editMenuIdentifier, expected: "Edit note")
                    && elementHasText(identifier: deleteMenuIdentifier, expected: "Delete note")
            } onSuccess: { [self] in
                guard let editButton = AppViewTreeE2E.view(
                    identifier: editMenuIdentifier
                ), AppViewTreeE2E.click(editButton) else {
                    fail("无法通过真实 UI 打开 English 附言编辑器")
                    return
                }
                verifyEditor()
            }
        }

        private func verifyEditor() {
            waitFor("English 附言编辑器") { [self] in
                elementHasText(
                    identifier: editorStateIdentifier,
                    expected: "Edit note…"
                )
                    && elementHasText(identifier: cancelIdentifier, expected: "Cancel")
                    && elementHasText(identifier: saveIdentifier, expected: "Save")
            } onSuccess: { [self] in
                guard let cancelButton = AppViewTreeE2E.view(
                    identifier: cancelIdentifier
                ), AppViewTreeE2E.click(cancelButton) else {
                    fail("无法通过真实 UI 取消 English 附言编辑")
                    return
                }
                openDeleteMenu()
            }
        }

        private func openDeleteMenu() {
            waitFor("取消编辑后的 English 附言操作入口") { [self] in
                guard let button = AppViewTreeE2E.view(
                    identifier: actionsIdentifier
                ) else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: { [self] in
                waitFor("English 删除附言菜单") { [self] in
                    elementHasText(identifier: deleteMenuIdentifier, expected: "Delete note")
                } onSuccess: { [self] in
                    guard let deleteButton = AppViewTreeE2E.view(
                        identifier: deleteMenuIdentifier
                    ), AppViewTreeE2E.click(deleteButton) else {
                        fail("无法通过真实 UI 删除 English 附言")
                        return
                    }
                    verifyDeleteToast()
                }
            }
        }

        private func verifyDeleteToast() {
            waitFor("English 删除附言反馈") { [self] in
                elementHasText(identifier: "app.toast", expected: "Note deleted")
                    && AppViewTreeE2E.hasNoAttachedPresentationWindows()
            } onSuccess: { [self] in
                finish(with: "ok")
            }
        }

        private func elementHasText(identifier: String, expected: String) -> Bool {
            guard let element = AppViewTreeE2E.view(identifier: identifier) else {
                return false
            }
            return elementHasText(element, expected: expected)
        }

        private func elementHasText(_ view: NSView, expected: String) -> Bool {
            AppViewTreeE2E.verificationText(for: view) == expected
        }

        private func waitFor(
            _ step: String,
            attemptsRemaining: Int = 80,
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

        private func fail(_ message: String) {
            AppViewTreeE2E.writeDump(beside: resultURL)
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
                NSLog(
                    "Noonmark task-note English copy E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }

        private var actionsIdentifier: String {
            "detail.note.actions.\(state.editedNoteID.description)"
        }

        private var editMenuIdentifier: String {
            "detail.note.edit.\(state.editedNoteID.description)"
        }

        private var deleteMenuIdentifier: String {
            "detail.note.delete.\(state.editedNoteID.description)"
        }

        private var editorStateIdentifier: String {
            "detail.note.editor.state.\(state.editedNoteID.description)"
        }

        private var cancelIdentifier: String {
            "detail.note.cancel.\(state.editedNoteID.description)"
        }

        private var saveIdentifier: String {
            "detail.note.save.\(state.editedNoteID.description)"
        }
    }
}

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
        private var actionMenuIdentity: AppViewTreeE2E.PresentationWindowIdentity?

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
            synchronizeMainWindow(
                before: "English 附言主窗口激活"
            ) { [self] in
                clickActionMenuButton(after: "English 附言操作入口") { [self] in
                    verifyMenu()
                }
            }
        }

        private func clickActionMenuButton(
            after step: String,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            waitFor(step) { [self] in
                guard let button = AppViewTreeE2E.view(
                    identifier: actionsIdentifier
                ), elementHasText(button, expected: "Note actions") else {
                    return false
                }
                return AppViewTreeE2E.click(button)
            } onSuccess: {
                onSuccess()
            }
        }

        private func verifyMenu() {
            waitFor("English 编辑与删除菜单") { [self] in
                elementHasText(identifier: editMenuIdentifier, expected: "Edit note")
                    && elementHasText(identifier: deleteMenuIdentifier, expected: "Delete note")
            } onSuccess: { [self] in
                guard let editButton = AppViewTreeE2E.view(
                    identifier: editMenuIdentifier
                ), let identity = AppViewTreeE2E.mappedPresentationWindow(
                    identifier: editMenuIdentifier
                ), AppViewTreeE2E.click(editButton) else {
                    fail("无法通过真实 UI 打开 English 附言编辑器")
                    return
                }
                actionMenuIdentity = identity
                verifyEditor()
            }
        }

        private func verifyEditor() {
            waitFor("English 附言编辑器") { [self] in
                guard let actionMenuIdentity,
                      AppViewTreeE2E.isPresentationWindowOpen(actionMenuIdentity) == false
                else { return false }
                return elementHasText(
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
            synchronizeMainWindow(
                before: "取消编辑后的 English 主窗口激活"
            ) { [self] in
                clickActionMenuButton(
                    after: "取消编辑后的 English 附言操作入口"
                ) { [self] in
                    verifyDeleteMenu()
                }
            }
        }

        private func synchronizeMainWindow(
            before step: String,
            onSuccess: @escaping @MainActor () -> Void
        ) {
            guard AppViewTreeE2E.requestMainWindowActivation() else {
                fail("无法请求主窗口激活：\(step)")
                return
            }
            waitFor(step) {
                AppViewTreeE2E.mainWindowHasInteractionIdentity()
            } onSuccess: {
                onSuccess()
            }
        }

        private func verifyDeleteMenu() {
            waitFor("English 删除附言菜单") { [self] in
                elementHasText(identifier: deleteMenuIdentifier, expected: "Delete note")
                    && AppViewTreeE2E.mappedPresentationWindow(
                        identifier: deleteMenuIdentifier
                    ) != nil
            } onSuccess: { [self] in
                guard let deleteButton = AppViewTreeE2E.view(
                    identifier: deleteMenuIdentifier
                ), let identity = AppViewTreeE2E.mappedPresentationWindow(
                    identifier: deleteMenuIdentifier
                ), AppViewTreeE2E.click(deleteButton) else {
                    fail("无法通过真实 UI 删除 English 附言")
                    return
                }
                actionMenuIdentity = identity
                verifyDeleteToast()
            }
        }

        private func verifyDeleteToast() {
            waitFor("English 删除附言反馈") { [self] in
                guard let actionMenuIdentity else { return false }
                return elementHasText(identifier: "app.toast", expected: "Note deleted")
                    && AppViewTreeE2E.isPresentationWindowOpen(actionMenuIdentity) == false
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

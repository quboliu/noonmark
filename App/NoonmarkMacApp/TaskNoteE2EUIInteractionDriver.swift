import AppKit
import Foundation
import NoonmarkCore

/// Drives the visible task-note controls with real window mouse events.
/// It deliberately has no reference to `NoonmarkStore`, so an E2E run cannot bypass the UI
/// by calling note mutation methods directly. The supplied probe is read-only
/// evidence that the UI-driven write reached SQLite before the edit is closed.
@MainActor
enum TaskNoteE2EUIInteractionDriver {
    static func start(
        editedNoteID: TaskNoteEntryID,
        deletedNoteID: TaskNoteEntryID,
        editedBody: String,
        hasDurablyPersistedEditedBody: @escaping @MainActor () -> Bool,
        resultURL: URL
    ) {
        InteractionSession(
            editedNoteID: editedNoteID,
            deletedNoteID: deletedNoteID,
            editedBody: editedBody,
            hasDurablyPersistedEditedBody: hasDurablyPersistedEditedBody,
            resultURL: resultURL
        ).start()
    }

    @MainActor
    private final class InteractionSession {
        private let editedNoteID: TaskNoteEntryID
        private let deletedNoteID: TaskNoteEntryID
        private let editedBody: String
        private let hasDurablyPersistedEditedBody: @MainActor () -> Bool
        private let resultURL: URL

        init(
            editedNoteID: TaskNoteEntryID,
            deletedNoteID: TaskNoteEntryID,
            editedBody: String,
            hasDurablyPersistedEditedBody: @escaping @MainActor () -> Bool,
            resultURL: URL
        ) {
            self.editedNoteID = editedNoteID
            self.deletedNoteID = deletedNoteID
            self.editedBody = editedBody
            self.hasDurablyPersistedEditedBody = hasDurablyPersistedEditedBody
            self.resultURL = resultURL
        }

        func start() {
            Task { @MainActor [self] in
                do {
                    try await enterEditedBodyThroughWindowServer()
                    saveEdit()
                } catch {
                    fail(error.localizedDescription)
                }
            }
        }

        private func enterEditedBodyThroughWindowServer() async throws {
            var body: NSView?
            try await waitUntil("可双击的附言正文") {
                body = self.element(identifier: self.editedBodyIdentifier)
                return body != nil
            }
            guard let body, let window = body.window else {
                throw InteractionFailure.failed("附言正文没有窗口坐标")
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            try await waitUntil("附言所在窗口没有成为 key window") {
                NSApp.isActive && window.isKeyWindow
            }

            let input = try WindowServerInputDriver()
            let resolveTarget: @MainActor () throws
                -> WindowServerInputDriver.PointerCoordinate = {
                guard let currentBody = self.element(identifier: self.editedBodyIdentifier),
                      currentBody === body,
                      currentBody.window === window,
                      window.isKeyWindow
                else {
                    throw InteractionFailure.failed("附言正文在 mouseDown 前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: currentBody)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            let initialTarget = try resolveTarget()
            try await input.postDoubleClick(
                at: initialTarget,
                modifiers: [],
                resolveTarget: resolveTarget
            )

            var textView: NSTextView?
            try await waitUntil("双击后附言编辑器没有出现并聚焦") {
                textView = self.element(
                    identifier: "\(self.editedEditorIdentifier).input"
                ) as? NSTextView
                return textView.map { window.firstResponder === $0 } == true
            }
            guard let textView else {
                throw InteractionFailure.failed("附言编辑器缺少原生 NSTextView")
            }
            try input.postKey(keyCode: 0, modifiers: .command)
            try input.typeUnicode(editedBody)
            try await waitUntil("WindowServer 输入没有写入附言编辑器") {
                textView.string == self.editedBody
                    && AppViewTreeE2E.hasNoVisibleView(
                        identifier: self.deletedActionsIdentifier
                    )
            }
            try await clickAwayFromEditedNoteEditor(
                textView,
                in: window,
                input: input
            )
        }

        private func clickAwayFromEditedNoteEditor(
            _ textView: NSTextView,
            in window: NSWindow,
            input: WindowServerInputDriver
        ) async throws {
            try await waitUntil("附言编辑后没有可点击的任务标题") {
                self.element(identifier: "detail.title.input")?.window === window
            }
            let resolveTarget: @MainActor () throws
                -> WindowServerInputDriver.PointerCoordinate = {
                guard let title = self.element(identifier: "detail.title.input"),
                      title.window === window,
                      window.isKeyWindow,
                      title.isHiddenOrHasHiddenAncestor == false
                else {
                    throw InteractionFailure.failed("点击离焦时任务标题不可用")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: title)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            let initialTarget = try resolveTarget()
            try await input.postClick(
                at: initialTarget,
                modifiers: [],
                resolveTarget: resolveTarget
            )
            try await waitUntil("点击离焦后附言尚未写入 SQLite") {
                window.firstResponder !== textView
                    && textView.string == self.editedBody
                    && self.hasDurablyPersistedEditedBody()
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
            Task { @MainActor [self] in
                do {
                    try await clearDeletedNoteThroughWindowServer()
                    finish(with: "ok")
                } catch {
                    fail(error.localizedDescription)
                }
            }
        }

        private func clearDeletedNoteThroughWindowServer() async throws {
            var body: NSView?
            try await waitUntil("待清空的附言正文") {
                body = self.element(identifier: self.deletedBodyIdentifier)
                return body != nil
            }
            guard let body, let window = body.window else {
                throw InteractionFailure.failed("待清空附言正文没有窗口坐标")
            }
            let input = try WindowServerInputDriver()
            let resolveTarget: @MainActor () throws
                -> WindowServerInputDriver.PointerCoordinate = {
                guard let currentBody = self.element(
                    identifier: self.deletedBodyIdentifier
                ), currentBody === body,
                currentBody.window === window,
                window.isKeyWindow
                else {
                    throw InteractionFailure.failed("待清空附言在 mouseDown 前变化")
                }
                let frame = AppViewTreeE2E.frameInWindow(for: currentBody)
                return try input.pointerCoordinate(
                    windowPoint: NSPoint(x: frame.midX, y: frame.midY),
                    in: window
                )
            }
            try await input.postDoubleClick(
                at: try resolveTarget(),
                modifiers: [],
                resolveTarget: resolveTarget
            )

            var textView: NSTextView?
            try await waitUntil("待清空附言编辑器没有出现并聚焦") {
                textView = self.element(
                    identifier: self.deletedEditorIdentifier
                ) as? NSTextView
                return textView.map { window.firstResponder === $0 } == true
            }
            guard let textView else {
                throw InteractionFailure.failed("待清空附言缺少原生 NSTextView")
            }
            try input.postKey(keyCode: 0, modifiers: .command)
            try input.postKey(keyCode: 51)
            try await waitUntil("Cmd+A Delete 没有清空附言编辑器") {
                textView.string.isEmpty
            }
            guard let save = element(identifier: deletedSaveIdentifier),
                  click(save)
            else {
                throw InteractionFailure.failed("空附言无法通过保存动作删除")
            }
            try await waitUntil("清空保存后的附言行没有消失") {
                AppViewTreeE2E.hasNoVisibleView(
                    identifier: self.deletedEntryStateIdentifier
                )
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

        private func waitUntil(
            _ step: String,
            attempts: Int = 120,
            condition: @MainActor () -> Bool
        ) async throws {
            for _ in 0 ..< attempts {
                if condition() {
                    return
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw InteractionFailure.failed("等待真实 UI 超时：\(step)")
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

        private var deletedActionsIdentifier: String {
            "detail.note.actions.\(deletedNoteID.description)"
        }

        private var editedEditorIdentifier: String {
            "detail.note.editor.\(editedNoteID.description)"
        }

        private var editedEditorStateIdentifier: String {
            "detail.note.editor.state.\(editedNoteID.description)"
        }

        private var editedBodyIdentifier: String {
            "detail.note.body.\(editedNoteID.description)"
        }

        private var deletedEntryStateIdentifier: String {
            "detail.note.entry.state.\(deletedNoteID.description)"
        }

        private var deletedBodyIdentifier: String {
            "detail.note.body.\(deletedNoteID.description)"
        }

        private var deletedEditorIdentifier: String {
            "detail.note.editor.\(deletedNoteID.description).input"
        }

        private var deletedSaveIdentifier: String {
            "detail.note.save.\(deletedNoteID.description)"
        }

        private var editedSaveIdentifier: String {
            "detail.note.save.\(editedNoteID.description)"
        }
    }

    private enum InteractionFailure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }
}

/// Verifies that a real failed immediate note save preserves the visible editor
/// and draft, then allows the explicit retry control to complete the write.
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
                waitForImmediateSaveFailure()
            }
        }

        private func waitForImmediateSaveFailure() {
            waitFor("输入后保存失败的编辑器、草稿与失败反馈") { [self] in
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

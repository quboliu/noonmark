import AppKit
import Foundation

/// Exercises quick-add through the real main-window NSTextView and responder chain.
@MainActor
enum QuickAddUIE2EDriver {
    static func start(
        resultURL: URL,
        title: String,
        editorIdentifier: String,
        inputReadback: @escaping @MainActor () -> String,
        taskExists: @escaping @MainActor (String) -> Bool
    ) {
        Session(
            resultURL: resultURL,
            title: title,
            editorIdentifier: editorIdentifier,
            inputReadback: inputReadback,
            taskExists: taskExists
        ).waitForEditor()
    }

    @MainActor
    private final class Session {
        private let resultURL: URL
        private let title: String
        private let inputIdentifier: String
        private let inputReadback: @MainActor () -> String
        private let taskExists: @MainActor (String) -> Bool

        init(
            resultURL: URL,
            title: String,
            editorIdentifier: String,
            inputReadback: @escaping @MainActor () -> String,
            taskExists: @escaping @MainActor (String) -> Bool
        ) {
            self.resultURL = resultURL
            self.title = title
            inputIdentifier = editorIdentifier.hasSuffix(".input")
                ? editorIdentifier
                : "\(editorIdentifier).input"
            self.inputReadback = inputReadback
            self.taskExists = taskExists
        }

        func waitForEditor(attemptsRemaining: Int = 80) {
            guard isPrintableASCII(title), title.isEmpty == false else {
                finish(
                    failure(
                        phase: "fixture",
                        message: "title 必须是非空 printable ASCII",
                        geometry: nil
                    )
                )
                return
            }
            guard let textView = currentTextView else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "locate",
                    message: "真实 quick-add NSTextView 未唯一出现",
                    geometry: nil
                ) { [self] nextAttempts in
                    waitForEditor(attemptsRemaining: nextAttempts)
                }
                return
            }
            let expectedPointSize = NoonmarkVisualMetrics.compactEditorPointSize
            guard let pointSize = textView.font?.pointSize,
                  abs(pointSize - expectedPointSize) <= 0.01
            else {
                finish(
                    failure(
                        phase: "typography",
                        message: "quick-add 字号不符合 token expected=\(expectedPointSize) actual=\(textView.font?.pointSize.description ?? "nil")",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            guard textView.string.isEmpty, inputReadback().isEmpty else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "initial-state",
                    message: "quick-add 初始输入未清空 actual=\(quoted(textView.string)) readback=\(quoted(inputReadback()))",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForEditor(attemptsRemaining: nextAttempts)
                }
                return
            }
            guard let window = textView.window else {
                finish(
                    failure(
                        phase: "focus",
                        message: "真实 quick-add NSTextView 不属于窗口",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }

            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            waitForInteractiveWindow(textView: textView)
        }

        private func waitForInteractiveWindow(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard let window = textView.window,
                  NSApp.isActive,
                  NSApp.keyWindow === window,
                  NSApp.mainWindow === window,
                  window.isKeyWindow,
                  window.isMainWindow
            else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "activation",
                    message: "quick-add 所在 App 与窗口尚未进入可交互状态",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForInteractiveWindow(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            guard clickTextInput(textView) else {
                finish(
                    failure(
                        phase: "focus",
                        message: "无法点击真实 quick-add NSTextView",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForFirstResponder(textView: textView)
            }
        }

        private func waitForFirstResponder(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard textView.window?.firstResponder === textView else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "focus",
                    message: "quick-add 没有成为真实窗口 first responder actual=\(firstResponderDescription(for: textView))",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForFirstResponder(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.setMarkedText(
                Self.markedTextFixture,
                selectedRange: NSRange(
                    location: Self.markedTextFixture.utf16.count,
                    length: 0
                ),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            waitForMarkedText(textView: textView)
        }

        /// NSTextView enters editing while handling mouseDown.  Posting both
        /// halves of a click can leave a launch automation checking focus
        /// before AppKit drains its event queue.  Queue mouseUp first, then
        /// synchronously deliver the genuine mouseDown, matching AppKit's
        /// native tracking contract without bypassing hit testing or focus.
        private func clickTextInput(_ textView: NSTextView) -> Bool {
            guard let window = textView.window else { return false }
            let point = textView.convert(
                NSPoint(x: textView.bounds.midX, y: textView.bounds.midY),
                to: nil
            )
            let root = window.contentView?.superview ?? window.contentView
            guard let hitView = root?.hitTest(point),
                  hitView === textView || hitView.isDescendant(of: textView)
            else {
                return false
            }
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ), let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: timestamp + 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            ) else {
                return false
            }
            NSApp.postEvent(mouseUp, atStart: false)
            window.sendEvent(mouseDown)
            return true
        }

        private func waitForMarkedText(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard textView.hasMarkedText(),
                  textView.string == Self.markedTextFixture
            else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "marked-text-setup",
                    message: "真实编辑器未建立 IME marked text actual=\(quoted(textView.string)) readback=\(quoted(inputReadback())) marked=\(textView.hasMarkedText())",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForMarkedText(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            guard sendReturnThroughWindow(textView: textView) else {
                finish(
                    failure(
                        phase: "marked-text-return",
                        message: "无法通过真实窗口发送 IME 确认 Return",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            waitForMarkedTextReturn(textView: textView)
        }

        private func waitForMarkedTextReturn(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard taskExists(Self.markedTextFixture) == false else {
                finish(
                    failure(
                        phase: "marked-text-return",
                        message: "IME 组合态的首个 Return 错误地创建了任务",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            guard textView.hasMarkedText() == false else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "marked-text-return",
                    message: "IME 组合态的首个 Return 未交还 AppKit 确认 marked text",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForMarkedTextReturn(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            guard sendSelectAllAndDeleteThroughWindow(textView: textView) else {
                finish(
                    failure(
                        phase: "marked-text-cleanup",
                        message: "无法通过真实窗口清理已确认的 IME fixture",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            waitForMarkedTextCleanup(textView: textView)
        }

        private func waitForMarkedTextCleanup(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard textView.string.isEmpty, inputReadback().isEmpty else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "marked-text-cleanup",
                    message: "IME fixture 未从真实编辑器与 binding 清空 actual=\(quoted(textView.string)) readback=\(quoted(inputReadback()))",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForMarkedTextCleanup(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            guard sendTitleThroughWindow(textView: textView) else {
                finish(
                    failure(
                        phase: "input",
                        message: "无法构造或发送 ASCII title 的窗口键盘事件",
                        geometry: geometrySnapshot(for: textView)
                    )
                )
                return
            }
            waitForTypedTitle(textView: textView)
        }

        private func waitForTypedTitle(
            textView: NSTextView,
            attemptsRemaining: Int = 40
        ) {
            guard textView.string == title, inputReadback() == title else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "input",
                    message: "窗口键盘输入未完整进入真实编辑器与 binding actual=\(quoted(textView.string)) readback=\(quoted(inputReadback())) expected=\(quoted(title))",
                    geometry: geometrySnapshot(for: textView)
                ) { [self] nextAttempts in
                    waitForTypedTitle(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }

            textView.setSelectedRange(
                NSRange(location: title.utf16.count, length: 0)
            )
            let geometry = geometrySnapshot(for: textView)
            guard sendReturnThroughWindow(textView: textView) else {
                finish(
                    failure(
                        phase: "return-event",
                        message: "无法通过真实窗口发送 Return keyCode=36",
                        geometry: geometry
                    )
                )
                return
            }
            waitForSubmission(geometry: geometry)
        }

        private func waitForSubmission(
            geometry: GeometrySnapshot?,
            attemptsRemaining: Int = 60
        ) {
            let actualText = currentTextView?.string
            let readback = inputReadback()
            let exists = taskExists(title)
            guard actualText == "", readback.isEmpty, exists else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    phase: "submission",
                    message: "Return 后未同时清空真实输入与 binding 并创建任务 actual=\(quoted(actualText)) readback=\(quoted(readback)) taskExists=\(exists)",
                    geometry: geometry
                ) { [self] nextAttempts in
                    waitForSubmission(
                        geometry: geometry,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }

            guard let geometry else {
                finish(
                    failure(
                        phase: "geometry",
                        message: "Return 已成功，但无法取得真实 caret/field 几何",
                        geometry: nil
                    )
                )
                return
            }
            guard geometry.centerError <= 0.5,
                  geometry.whitespaceImbalance <= 1
            else {
                finish(
                    failure(
                        phase: "geometry",
                        message: "Return 已成功，但 caret 未在输入框垂直正中",
                        geometry: geometry
                    )
                )
                return
            }
            finish("ok")
        }

        private var currentTextView: NSTextView? {
            AppViewTreeE2E.view(identifier: inputIdentifier) as? NSTextView
        }

        private func sendTitleThroughWindow(textView: NSTextView) -> Bool {
            guard let window = textView.window else { return false }
            for character in title {
                guard let stroke = keystroke(for: character),
                      let keyDown = keyEvent(
                          type: .keyDown,
                          stroke: stroke,
                          window: window
                      ),
                      let keyUp = keyEvent(
                          type: .keyUp,
                          stroke: stroke,
                          window: window
                      )
                else {
                    return false
                }
                window.sendEvent(keyDown)
                window.sendEvent(keyUp)
            }
            return true
        }

        private func sendReturnThroughWindow(textView: NSTextView) -> Bool {
            sendKeyDownThroughWindow(
                textView: textView,
                stroke: Keystroke(
                    characters: "\r",
                    charactersIgnoringModifiers: "\r",
                    keyCode: 36,
                    modifiers: []
                )
            )
        }

        private func sendSelectAllAndDeleteThroughWindow(textView: NSTextView) -> Bool {
            let selectAll = Keystroke(
                characters: "a",
                charactersIgnoringModifiers: "a",
                keyCode: 0,
                modifiers: .control
            )
            let delete = Keystroke(
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                keyCode: 51,
                modifiers: []
            )
            return sendKeyDownThroughWindow(
                textView: textView,
                stroke: selectAll
            ) && sendKeyDownThroughWindow(
                textView: textView,
                stroke: delete
            )
        }

        private func sendKeyDownThroughWindow(
            textView: NSTextView,
            stroke: Keystroke
        ) -> Bool {
            guard let window = textView.window,
                  window.firstResponder === textView,
                  let event = keyEvent(
                      type: .keyDown,
                      stroke: stroke,
                      window: window
                  )
            else {
                return false
            }
            window.sendEvent(event)
            return true
        }

        private func keyEvent(
            type: NSEvent.EventType,
            stroke: Keystroke,
            window: NSWindow
        ) -> NSEvent? {
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: stroke.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: stroke.characters,
                charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: stroke.keyCode
            )
        }

        private func geometrySnapshot(for textView: NSTextView) -> GeometrySnapshot? {
            guard let scrollView = textView.enclosingScrollView,
                  let window = scrollView.window
            else {
                return nil
            }
            let location = min(
                textView.selectedRange().location,
                textView.string.utf16.count
            )
            var actualRange = NSRange(location: NSNotFound, length: 0)
            let caretRect = textView.firstRect(
                forCharacterRange: NSRange(location: location, length: 0),
                actualRange: &actualRange
            )
            let fieldRect = window.convertToScreen(
                scrollView.convert(scrollView.bounds, to: nil)
            )
            // NSTextInputClient exposes an insertion caret as a zero-width
            // rectangle; NSRect.isEmpty therefore cannot validate it.
            guard caretRect.height > 0,
                  fieldRect.height > 0
            else {
                return nil
            }

            let topWhitespace = fieldRect.maxY - caretRect.maxY
            let bottomWhitespace = caretRect.minY - fieldRect.minY
            return GeometrySnapshot(
                fieldRect: fieldRect,
                caretRect: caretRect,
                actualRange: actualRange,
                topWhitespace: topWhitespace,
                bottomWhitespace: bottomWhitespace,
                centerError: abs(caretRect.midY - fieldRect.midY),
                whitespaceImbalance: abs(topWhitespace - bottomWhitespace)
            )
        }

        private func firstResponderDescription(for textView: NSTextView) -> String {
            guard let responder = textView.window?.firstResponder else { return "nil" }
            if let view = responder as? NSView {
                return "\(String(describing: type(of: view))):\(view.identifier?.rawValue ?? "unidentified")"
            }
            return String(describing: type(of: responder))
        }

        private func keystroke(for character: Character) -> Keystroke? {
            guard let scalar = character.unicodeScalars.only else { return nil }
            let value = scalar.value
            guard value >= 32, value <= 126 else { return nil }

            let rendered = String(character)
            if character.isLetter {
                let lowercased = rendered.lowercased()
                guard let keyCode = Self.keyCodes[Character(lowercased)] else {
                    return nil
                }
                return Keystroke(
                    characters: rendered,
                    charactersIgnoringModifiers: lowercased,
                    keyCode: keyCode,
                    modifiers: rendered == lowercased ? [] : .shift
                )
            }
            if let keyCode = Self.keyCodes[character] {
                return Keystroke(
                    characters: rendered,
                    charactersIgnoringModifiers: rendered,
                    keyCode: keyCode,
                    modifiers: []
                )
            }
            guard let base = Self.shiftedCharacters[character],
                  let keyCode = Self.keyCodes[base]
            else {
                return nil
            }
            return Keystroke(
                characters: rendered,
                charactersIgnoringModifiers: String(base),
                keyCode: keyCode,
                modifiers: .shift
            )
        }

        private func isPrintableASCII(_ value: String) -> Bool {
            value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 32 && scalar.value <= 126
            }
        }

        private func retryOrFail(
            attemptsRemaining: Int,
            phase: String,
            message: String,
            geometry: GeometrySnapshot?,
            retry: @escaping @MainActor (Int) -> Void
        ) {
            guard attemptsRemaining > 1 else {
                finish(
                    failure(
                        phase: phase,
                        message: message,
                        geometry: geometry
                    )
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                retry(attemptsRemaining - 1)
            }
        }

        private func failure(
            phase: String,
            message: String,
            geometry: GeometrySnapshot?
        ) -> String {
            "failed: phase=\(phase) \(message) \(geometryDescription(geometry))"
        }

        private func geometryDescription(_ geometry: GeometrySnapshot?) -> String {
            guard let geometry else { return "geometry=unavailable" }
            return "geometry={field=\(rectDescription(geometry.fieldRect)),caret=\(rectDescription(geometry.caretRect)),actualRange=\(geometry.actualRange),top=\(rounded(geometry.topWhitespace)),bottom=\(rounded(geometry.bottomWhitespace)),centerError=\(rounded(geometry.centerError)),whitespaceImbalance=\(rounded(geometry.whitespaceImbalance))}"
        }

        private func rectDescription(_ rect: NSRect) -> String {
            "x:\(rounded(rect.minX)),y:\(rounded(rect.minY)),w:\(rounded(rect.width)),h:\(rounded(rect.height))"
        }

        private func rounded(_ value: CGFloat) -> String {
            String(format: "%.2f", value)
        }

        private func quoted(_ value: String?) -> String {
            guard let value else { return "nil" }
            return "\"\(value)\""
        }

        private func finish(_ result: String) {
            if result != "ok" {
                AppViewTreeE2E.writeDump(beside: resultURL)
            }
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try result.write(to: resultURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog(
                    "Noonmark quick-add UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }

        private static let keyCodes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
            "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18,
            "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
            "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
            "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
            "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50
        ]

        private static let shiftedCharacters: [Character: Character] = [
            "~": "`", "!": "1", "@": "2", "#": "3", "$": "4",
            "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
            ")": "0", "_": "-", "+": "=", "{": "[", "}": "]",
            "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".",
            "?": "/"
        ]

        private static let markedTextFixture = "imefixture"
    }

    private struct Keystroke {
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    private struct GeometrySnapshot {
        let fieldRect: NSRect
        let caretRect: NSRect
        let actualRange: NSRange
        let topWhitespace: CGFloat
        let bottomWhitespace: CGFloat
        let centerError: CGFloat
        let whitespaceImbalance: CGFloat
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

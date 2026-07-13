import AppKit
import Foundation

/// Drives the real detail-description NSTextView through the application's
/// main menu definition and NSApplication window-event path.
@MainActor
enum MarkdownEditorUIE2EDriver {
    static func start(
        resultURL: URL,
        initialText: String,
        classificationMenuIdentifier: String,
        readback: @escaping @MainActor () -> String
    ) {
        Session(
            resultURL: resultURL,
            initialText: initialText,
            classificationMenuIdentifier: classificationMenuIdentifier,
            readback: readback
        ).waitForEditor()
    }

    @MainActor
    private final class Session {
        private let resultURL: URL
        private let initialText: String
        private let classificationMenuIdentifier: String
        private let readback: @MainActor () -> String

        init(
            resultURL: URL,
            initialText: String,
            classificationMenuIdentifier: String,
            readback: @escaping @MainActor () -> String
        ) {
            self.resultURL = resultURL
            self.initialText = initialText
            self.classificationMenuIdentifier = classificationMenuIdentifier
            self.readback = readback
        }

        func waitForEditor(attemptsRemaining: Int = 80) {
            guard let textView = AppViewTreeE2E.view(
                identifier: "detail.description.input"
            ) as? NSTextView else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    message: "真实描述 NSTextView 未出现"
                ) { [self] nextAttempts in
                    waitForEditor(attemptsRemaining: nextAttempts)
                }
                return
            }
            guard textView.string == initialText else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    message: "描述 fixture 未进入真实编辑器：\(textView.string)"
                ) { [self] nextAttempts in
                    waitForEditor(attemptsRemaining: nextAttempts)
                }
                return
            }
            guard let scrollView = textView.enclosingScrollView,
                  scrollView.borderType == .noBorder,
                  scrollView.drawsBackground == false,
                  textView.drawsBackground == false,
                  textView.textContainerInset == NSSize(
                      width: NoonmarkVisualMetrics.detailTextInset,
                      height: NoonmarkVisualMetrics.detailTextInset
                  )
            else {
                finish("failed: 真实描述编辑器仍有 surface 或 inset 不符合当前契约")
                return
            }
            guard let classificationAnchor = AppViewTreeE2E.view(
                identifier: classificationMenuIdentifier
            ), AppViewTreeE2E.verificationText(for: classificationAnchor)?.isEmpty == false,
                  AppViewTreeE2E.button(overlapping: classificationAnchor) != nil,
                  AppViewTreeE2E.visibleButtonLabels().isDisjoint(with: ["更换", "Change"])
            else {
                finish("failed: 当前分组值不是唯一可见的 Menu 入口")
                return
            }
            guard AppViewTreeE2E.click(textView) else {
                finish("failed: 无法点击真实描述编辑器")
                return
            }
            textView.window?.makeKeyAndOrderFront(nil)
            textView.window?.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            guard textView.window?.makeFirstResponder(textView) == true else {
                finish("failed: 真实窗口拒绝描述编辑器成为 first responder")
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
                    message: "描述编辑器没有成为真实窗口的 first responder"
                ) { [self] nextAttempts in
                    waitForFirstResponder(
                        textView: textView,
                        attemptsRemaining: nextAttempts
                    )
                }
                return
            }
            exerciseNativeEditing(in: textView)
        }

        private func exerciseNativeEditing(in textView: NSTextView) {
            let fullRange = NSRange(location: 0, length: initialText.utf16.count)
            textView.setSelectedRange(
                NSRange(location: initialText.utf16.count, length: 0)
            )

            let selectAllHandled = performMenuKey(
                "a",
                modifiers: .command
            )
            guard selectAllHandled, textView.selectedRange() == fullRange else {
                finish(
                    "failed: ⌘A 没有通过 App 编辑菜单全选 "
                        + "handled=\(selectAllHandled) selection=\(textView.selectedRange()) "
                        + "expected=\(fullRange) firstResponder="
                        + "\(String(describing: textView.window?.firstResponder)) "
                        + "responds=\(textView.responds(to: #selector(NSResponder.selectAll(_:)))) "
                        + "appActive=\(NSApp.isActive) key=\(String(describing: NSApp.keyWindow?.windowNumber)) "
                        + "main=\(String(describing: NSApp.mainWindow?.windowNumber)) "
                        + "editorWindow=\(String(describing: textView.window?.windowNumber)) "
                        + "isKey=\(textView.window?.isKeyWindow == true) "
                        + "isMain=\(textView.window?.isMainWindow == true) "
                        + "menu=\(menuSnapshot())"
                )
                return
            }

            replacePasteboard(with: "SENTINEL")
            guard performMenuKey(
                "c",
                modifiers: .command
            ),
                  NSPasteboard.general.string(forType: .string) == initialText
            else {
                finish("failed: ⌘C 没有通过 responder chain 复制")
                return
            }

            guard performMenuKey(
                "x",
                modifiers: .command
            ), textView.string.isEmpty else {
                finish("failed: ⌘X 没有通过 responder chain 剪切")
                return
            }
            guard performMenuKey(
                "v",
                modifiers: .command
            ), textView.string == initialText else {
                finish("failed: ⌘V 没有通过 responder chain 粘贴")
                return
            }

            textView.setSelectedRange(
                NSRange(location: textView.string.utf16.count, length: 0)
            )
            guard sendWindowKey("!", keyCode: 18, modifiers: []),
                  textView.string == initialText + "!"
            else {
                finish("failed: 普通文本输入没有进入描述编辑器")
                return
            }
            guard performMenuKey(
                "z",
                modifiers: .command
            ), textView.string == initialText else {
                finish("failed: ⌘Z 没有优先撤销文本编辑")
                return
            }
            guard performMenuKey(
                "z",
                modifiers: [.command, .shift]
            ),
                  textView.string == initialText + "!"
            else {
                finish(
                    "failed: ⇧⌘Z 没有重做文本编辑 text=\(textView.string) "
                        + "canUndo=\(textView.undoManager?.canUndo == true) "
                        + "canRedo=\(textView.undoManager?.canRedo == true) "
                        + "menu=\(menuSnapshot())"
                )
                return
            }

            textView.setSelectedRange(
                NSRange(location: textView.string.utf16.count, length: 0)
            )
            guard sendWindowKey("a", keyCode: 0, modifiers: .control),
                  textView.selectedRange()
                  == NSRange(location: 0, length: textView.string.utf16.count)
            else {
                finish("failed: Control-A 没有全选")
                return
            }
            guard sendWindowKey("b", keyCode: 11, modifiers: .command),
                  textView.string == "**\(initialText)!**"
            else {
                finish("failed: ⌘B 没有应用 Markdown 粗体")
                return
            }

            waitForReadback(expected: textView.string)
        }

        private func waitForReadback(
            expected: String,
            attemptsRemaining: Int = 40
        ) {
            guard readback() == expected else {
                retryOrFail(
                    attemptsRemaining: attemptsRemaining,
                    message: "Markdown 编辑结果没有进入任务 binding"
                ) { [self] nextAttempts in
                    waitForReadback(expected: expected, attemptsRemaining: nextAttempts)
                }
                return
            }
            finish("ok")
        }

        private func performMenuKey(
            _ characters: String,
            modifiers: NSEvent.ModifierFlags
        ) -> Bool {
            guard let event = keyEvent(
                characters,
                keyCode: keyCode(for: characters),
                modifiers: modifiers
            ) else {
                return false
            }
            let normalizedModifiers = modifiers.intersection(
                .deviceIndependentFlagsMask
            )
            guard let mainMenu = NSApp.mainMenu,
                  let menuItem = mainMenu.items
                  .compactMap(\.submenu)
                  .flatMap(\.items)
                  .first(where: {
                      let itemModifiers = $0.keyEquivalentModifierMask
                          .intersection(.deviceIndependentFlagsMask)
                          .union(
                              $0.keyEquivalent == $0.keyEquivalent.uppercased()
                                  && $0.keyEquivalent != $0.keyEquivalent.lowercased()
                                  ? .shift
                                  : []
                          )
                      return $0.action != nil
                          && $0.keyEquivalent.lowercased() == characters.lowercased()
                          && itemModifiers == normalizedModifiers
                  }), menuItem.action != nil,
                  let window = e2eWindow,
                  window.firstResponder is NSTextView
            else {
                return false
            }
            return mainMenu.performKeyEquivalent(with: event)
        }

        private func sendWindowKey(
            _ characters: String,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags
        ) -> Bool {
            guard let event = keyEvent(
                characters,
                keyCode: keyCode,
                modifiers: modifiers
            ), let window = e2eWindow else {
                return false
            }
            window.sendEvent(event)
            return true
        }

        private func keyEvent(
            _ characters: String,
            keyCode: UInt16,
            modifiers: NSEvent.ModifierFlags
        ) -> NSEvent? {
            guard let window = e2eWindow else { return nil }
            let eventCharacters = modifiers.contains(.shift)
                ? characters.uppercased()
                : characters
            return NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: eventCharacters,
                charactersIgnoringModifiers: eventCharacters,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        private var e2eWindow: NSWindow? {
            NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0 is NoonmarkWindow })
        }

        private func keyCode(for characters: String) -> UInt16 {
            switch characters.lowercased() {
            case "a": 0
            case "b": 11
            case "c": 8
            case "v": 9
            case "x": 7
            case "z": 6
            default: 0
            }
        }

        private func replacePasteboard(with value: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        private func menuSnapshot() -> String {
            guard let mainMenu = NSApp.mainMenu else { return "missing" }
            return mainMenu.items.flatMap { topItem -> [String] in
                guard let submenu = topItem.submenu else { return [] }
                return submenu.items.map { item in
                    "\(item.title){key=\(item.keyEquivalent),mask=\(item.keyEquivalentModifierMask.rawValue),action=\(String(describing: item.action)),enabled=\(item.isEnabled)}"
                }
            }.joined(separator: ",")
        }

        private func retryOrFail(
            attemptsRemaining: Int,
            message: String,
            retry: @escaping @MainActor (Int) -> Void
        ) {
            guard attemptsRemaining > 1 else {
                finish("failed: \(message)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                retry(attemptsRemaining - 1)
            }
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
                    "Noonmark Markdown editor UI E2E result write failed: %@",
                    String(describing: error)
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }
}

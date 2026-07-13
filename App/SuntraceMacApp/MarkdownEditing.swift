import AppKit
import Foundation
import SwiftUI

enum MarkdownEditorStyle {
    case title
    case body
    case compact

    var font: NSFont {
        switch self {
        case .title: .systemFont(ofSize: 14, weight: .semibold)
        case .body: .systemFont(ofSize: 12)
        case .compact: .systemFont(ofSize: 12.5, weight: .medium)
        }
    }

    var minimumHeight: CGFloat {
        switch self {
        case .title: 58
        case .body: 86
        case .compact: 42
        }
    }
}

struct MarkdownEditor: View {
    @Binding var text: String
    let placeholder: String
    var style: MarkdownEditorStyle = .body
    var warm = false
    var showsSurface = true
    var height: CGFloat?
    var onCommit: (() -> Void)?
    var onEndEditing: (() -> Void)?

    var body: some View {
        MarkdownTextViewRepresentable(
            text: $text,
            style: style,
            onCommit: onCommit,
            onEndEditing: onEndEditing
        )
            .frame(height: height ?? style.minimumHeight)
            .background(showsSurface ? (warm ? Theme.noteBackground : Theme.panel2) : Color.clear)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: style == .title ? 14 : 12))
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(placeholder)
    }
}

private struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let style: MarkdownEditorStyle
    let onCommit: (() -> Void)?
    let onEndEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEndEditing: onEndEditing)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = MarkdownNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = style.font
        textView.textColor = NSColor.labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.commitAction = onCommit
        context.coordinator.onEndEditing = onEndEditing
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(location: min(selection.location, text.utf16.count), length: 0)
            )
        }
        textView.font = style.font
        textView.commitAction = onCommit
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEndEditing: (() -> Void)?

        init(text: Binding<String>, onEndEditing: (() -> Void)?) {
            self.text = text
            self.onEndEditing = onEndEditing
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            onEndEditing?()
        }
    }
}

private final class MarkdownNSTextView: NSTextView {
    var commitAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if modifiers.contains(.control), key == "a" {
            selectAll(nil)
            return
        }
        if modifiers.contains(.command), event.keyCode == 36 {
            commitAction?()
            return
        }
        if modifiers.contains(.shift), event.keyCode == 36 {
            insertText("  \n", replacementRange: selectedRange())
            return
        }
        if modifiers.contains(.command), let key {
            switch key {
            case "b":
                wrapSelection(prefix: "**", suffix: "**")
                return
            case "i":
                wrapSelection(prefix: "*", suffix: "*")
                return
            case "e":
                wrapSelection(prefix: "`", suffix: "`")
                return
            case "k":
                wrapSelection(prefix: "[", suffix: "](https://)")
                return
            default:
                break
            }
        }
        if event.keyCode == 48, modifiers.contains(.command) == false {
            insertText("    ", replacementRange: selectedRange())
            return
        }
        super.keyDown(with: event)
    }

    private func wrapSelection(prefix: String, suffix: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(prefix + selected + suffix, replacementRange: range)
        setSelectedRange(
            NSRange(location: range.location + prefix.utf16.count, length: selected.utf16.count)
        )
    }
}

enum MarkdownEditorKeyboardProbe {
    @MainActor
    static func failures() -> [String] {
        let textView = MarkdownNSTextView()
        textView.string = "alpha beta"
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        var failures: [String] = []
        if let selectAll = keyEvent(keyCode: 0, characters: "a", modifiers: .control) {
            textView.keyDown(with: selectAll)
            if textView.selectedRange() != NSRange(location: 0, length: textView.string.utf16.count) {
                failures.append("Ctrl+A did not select all")
            }
        } else {
            failures.append("Ctrl+A event could not be created")
        }

        textView.string = "soft"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        if let hardBreak = keyEvent(keyCode: 36, characters: "\r", modifiers: .shift) {
            textView.keyDown(with: hardBreak)
            if textView.string != "soft  \n" {
                failures.append("Shift+Return did not insert a Markdown hard break")
            }
        } else {
            failures.append("Shift+Return event could not be created")
        }

        textView.string = "bold"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        if let bold = keyEvent(keyCode: 11, characters: "b", modifiers: .command) {
            textView.keyDown(with: bold)
            if textView.string != "**bold**" {
                failures.append("Command+B did not wrap the selection")
            }
        } else {
            failures.append("Command+B event could not be created")
        }

        let rendered = MarkdownInlineText.attributed("**bold** and [link](https://example.com)")
        if String(rendered.characters) != "bold and link" {
            failures.append("inline Markdown did not render")
        }
        let blocks = MarkdownBlock.parse("# Heading\n- [x] item\n> quote\n```\ncode\n```")
        if blocks.count != 4 {
            failures.append("block Markdown did not render")
        }
        return failures
    }

    private static func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

struct MarkdownInlineText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        Text(Self.attributed(source))
    }

    static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        )) ?? AttributedString(source)
    }
}

struct MarkdownText: View {
    let source: String
    var fallback: String

    init(_ source: String, fallback: String = "") {
        self.source = source
        self.fallback = fallback
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        if blocks.isEmpty {
            Text(fallback)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            MarkdownInlineText(block.text)
                .font(.system(size: max(13, 20 - CGFloat(level * 2)), weight: .bold))
        case .paragraph:
            MarkdownInlineText(block.text)
                .lineSpacing(3)
        case let .list(marker, checked):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(checked ? Theme.ok : Theme.text3)
                        .frame(width: 13)
                } else {
                    Text(marker)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(minWidth: 13)
                }
                MarkdownInlineText(block.text)
            }
        case .quote:
            HStack(alignment: .top, spacing: 9) {
                Rectangle().fill(Theme.accent.opacity(0.55)).frame(width: 3)
                MarkdownInlineText(block.text).foregroundStyle(Theme.text2)
            }
        case .code:
            Text(block.text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.controlFill))
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case paragraph
        case list(marker: String, checked: Bool?)
        case quote
        case code
    }

    let id = UUID()
    let kind: Kind
    let text: String

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard source.isEmpty == false else { return [] }
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var isCode = false

        func flushParagraph() {
            guard paragraph.isEmpty == false else { return }
            blocks.append(MarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if isCode {
                    blocks.append(MarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
                    code.removeAll()
                } else {
                    flushParagraph()
                }
                isCode.toggle()
                continue
            }
            if isCode {
                code.append(line)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = heading(line) {
                flushParagraph()
                blocks.append(heading)
            } else if let list = list(line) {
                flushParagraph()
                blocks.append(list)
            } else if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote, text: String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if code.isEmpty == false {
            blocks.append(MarkdownBlock(kind: .code, text: code.joined(separator: "\n")))
        }
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return MarkdownBlock(kind: .heading(count), text: String(line.dropFirst(count + 1)))
    }

    private static func list(_ line: String) -> MarkdownBlock? {
        if line.hasPrefix("- [ ] ") {
            return MarkdownBlock(kind: .list(marker: "", checked: false), text: String(line.dropFirst(6)))
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return MarkdownBlock(kind: .list(marker: "", checked: true), text: String(line.dropFirst(6)))
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return MarkdownBlock(kind: .list(marker: "•", checked: nil), text: String(line.dropFirst(2)))
        }
        guard let period = line.firstIndex(of: "."), period < line.endIndex else { return nil }
        let prefix = line[..<period]
        let after = line.index(after: period)
        guard prefix.allSatisfy(\.isNumber), line.indices.contains(after), line[after] == " " else { return nil }
        return MarkdownBlock(
            kind: .list(marker: "\(prefix).", checked: nil),
            text: String(line[line.index(after: after)...])
        )
    }
}

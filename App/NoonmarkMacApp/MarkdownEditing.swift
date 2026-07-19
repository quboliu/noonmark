import AppKit
import Foundation
import SwiftUI

enum MarkdownEditorStyle {
    case title
    case body
    case detailBody
    case compact

    var font: NSFont {
        switch self {
        case .title: .noonmarkSystemFont(ofSize: 14, weight: .semibold)
        case .body, .detailBody: .noonmarkSystemFont(ofSize: 12)
        case .compact:
            .systemFont(ofSize: NoonmarkVisualMetrics.compactEditorPointSize, weight: .medium)
        }
    }

    var swiftUIFont: Font {
        switch self {
        case .title: .noonmarkSystem(size: 14, weight: .semibold)
        case .body, .detailBody: .noonmarkSystem(size: 12)
        case .compact:
            .noonmarkRenderedSystem(
                size: NoonmarkVisualMetrics.compactEditorPointSize,
                weight: .medium
            )
        }
    }

    var minimumHeight: CGFloat {
        switch self {
        case .title: NoonmarkVisualMetrics.detailTitleMinimumHeight
        case .body: 54
        case .detailBody: NoonmarkVisualMetrics.detailDescriptionMinimumHeight
        case .compact: 32
        }
    }

    var maximumHeight: CGFloat {
        switch self {
        case .title: NoonmarkVisualMetrics.detailTitleMaximumHeight
        case .detailBody: NoonmarkVisualMetrics.detailDescriptionMaximumHeight
        case .body: 132
        case .compact: 32
        }
    }

    var textContainerInset: NSSize {
        switch self {
        case .title, .detailBody:
            NSSize(
                width: NoonmarkVisualMetrics.detailTextInset,
                height: NoonmarkVisualMetrics.detailTextInset
            )
        case .body:
            NSSize(width: 5, height: 6)
        case .compact:
            // A 15 pt insertion caret inside the fixed 32 pt compact field
            // leaves 17 pt of vertical whitespace. Split that evenly so the
            // text system does not scroll a 35 pt document inside the viewport.
            NSSize(width: 5, height: NoonmarkVisualMetrics.compactEditorVerticalInset)
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
    var commitsOnReturn = false
    var onCommit: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var nativeAccessibilityIdentifier: String?
    var focusesOnAppear = false
    var focusRequest = 0

    var body: some View {
        let editor = MarkdownTextViewRepresentable(
            text: $text,
            style: style,
            commitsOnReturn: commitsOnReturn,
            onCommit: onCommit,
            onEndEditing: onEndEditing,
            accessibilityLabel: placeholder,
            nativeAccessibilityIdentifier: nativeAccessibilityIdentifier,
            explicitHeight: height,
            focusesOnAppear: focusesOnAppear,
            focusRequest: focusRequest
        )
        Group {
            if let height {
                editor.frame(height: height)
            } else {
                editor.frame(
                    minHeight: style.minimumHeight,
                    maxHeight: style.maximumHeight
                )
            }
        }
            .background(showsSurface ? (warm ? Theme.noteBackground : Theme.panel2) : Color.clear)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(style.swiftUIFont)
                        .foregroundStyle(Theme.text3)
                        .padding(.horizontal, style.textContainerInset.width)
                        .padding(.vertical, style.textContainerInset.height)
                        .allowsHitTesting(false)
                        .background {
                            if let nativeAccessibilityIdentifier {
                                AppE2EViewAnchor(
                                    identifier: "\(nativeAccessibilityIdentifier).placeholder",
                                    verificationText: placeholder
                                )
                            }
                        }
                }
            }
            .accessibilityLabel(placeholder)
    }
}

private struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let style: MarkdownEditorStyle
    let commitsOnReturn: Bool
    let onCommit: (() -> Void)?
    let onEndEditing: (() -> Void)?
    let accessibilityLabel: String
    let nativeAccessibilityIdentifier: String?
    let explicitHeight: CGFloat?
    let focusesOnAppear: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onEndEditing: onEndEditing,
            focusRequest: focusRequest
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = style != .compact
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
        textView.textContainerInset = style.textContainerInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.commitsOnReturn = commitsOnReturn
        textView.commitAction = onCommit
        scrollView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityLabel(accessibilityLabel)
        if let nativeAccessibilityIdentifier {
            scrollView.setAccessibilityIdentifier(nativeAccessibilityIdentifier)
            textView.setAccessibilityIdentifier("\(nativeAccessibilityIdentifier).input")
            scrollView.identifier = NSUserInterfaceItemIdentifier(nativeAccessibilityIdentifier)
            textView.identifier = NSUserInterfaceItemIdentifier(
                "\(nativeAccessibilityIdentifier).input"
            )
        }
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
        textView.textContainerInset = style.textContainerInset
        textView.commitsOnReturn = commitsOnReturn
        textView.commitAction = onCommit
        scrollView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityLabel(accessibilityLabel)
        if let nativeAccessibilityIdentifier {
            scrollView.setAccessibilityIdentifier(nativeAccessibilityIdentifier)
            textView.setAccessibilityIdentifier("\(nativeAccessibilityIdentifier).input")
            scrollView.identifier = NSUserInterfaceItemIdentifier(nativeAccessibilityIdentifier)
            textView.identifier = NSUserInterfaceItemIdentifier(
                "\(nativeAccessibilityIdentifier).input"
            )
        }
        context.coordinator.text = $text
        context.coordinator.onEndEditing = onEndEditing
        if focusesOnAppear, context.coordinator.didRequestInitialFocus == false {
            context.coordinator.didRequestInitialFocus = true
            DispatchQueue.main.async { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                scrollView.window?.makeFirstResponder(textView)
            }
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0,
              let textView = scrollView.documentView as? MarkdownNSTextView
        else {
            return nil
        }
        let horizontalInsets = textView.textContainerInset.width * 2
        let verticalInsets = textView.textContainerInset.height * 2
        let availableWidth = max(1, width - horizontalInsets)
        let source = textView.string.isEmpty ? " " : textView.string
        let measured = (source as NSString).boundingRect(
            with: NSSize(
                width: availableWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: style.font]
        )
        let contentHeight = ceil(measured.height + verticalInsets)
        let preferredHeight = min(
            max(contentHeight, style.minimumHeight),
            style.maximumHeight
        )
        let fixedHeight = explicitHeight.flatMap { height in
            height.isFinite && height > 0 ? height : nil
        }
        return CGSize(
            width: width,
            height: fixedHeight.map {
                min(max($0, style.minimumHeight), style.maximumHeight)
            } ?? preferredHeight
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEndEditing: (() -> Void)?
        var focusRequest: Int
        var didRequestInitialFocus = false

        init(
            text: Binding<String>,
            onEndEditing: (() -> Void)?,
            focusRequest: Int
        ) {
            self.text = text
            self.onEndEditing = onEndEditing
            self.focusRequest = focusRequest
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
    var commitsOnReturn = false
    var commitAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if handleSelectAll(key: key, modifiers: modifiers) { return }
        if handleReturn(event, modifiers: modifiers) { return }
        if handleFormattingShortcut(key: key, modifiers: modifiers) { return }
        if handleTab(event, modifiers: modifiers) { return }
        super.keyDown(with: event)
    }

    private func handleSelectAll(
        key: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.contains(.control), key == "a" else { return false }
        selectAll(nil)
        return true
    }

    private func handleReturn(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 36 else { return false }
        guard hasMarkedText() == false else { return false }
        if modifiers.contains(.command) {
            commitAction?()
            return true
        }
        let returnModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        if commitsOnReturn, returnModifiers.isDisjoint(with: modifiers) {
            commitAction?()
            return true
        }
        if modifiers.contains(.shift) {
            insertText("  \n", replacementRange: selectedRange())
            return true
        }
        return false
    }

    private func handleFormattingShortcut(
        key: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.contains(.command), let key else { return false }
        switch key {
        case "b":
            wrapSelection(prefix: "**", suffix: "**")
        case "i":
            wrapSelection(prefix: "*", suffix: "*")
        case "e":
            wrapSelection(prefix: "`", suffix: "`")
        case "k":
            wrapSelection(prefix: "[", suffix: "](https://)")
        default:
            return false
        }
        return true
    }

    private func handleTab(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 48 else { return false }
        let semanticModifiers = modifiers.intersection([
            .command,
            .control,
            .option,
            .shift
        ])
        if semanticModifiers.isEmpty {
            window?.selectNextKeyView(self)
        } else if semanticModifiers == [.shift] {
            window?.selectPreviousKeyView(self)
        } else if semanticModifiers == [.option] {
            insertText("    ", replacementRange: selectedRange())
        } else {
            return false
        }
        return true
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
    static func submitWithReturn(_ action: @escaping () -> Void) -> Bool {
        let textView = MarkdownNSTextView()
        textView.string = "new task"
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.commitsOnReturn = true
        textView.commitAction = action
        guard let submit = keyEvent(keyCode: 36, characters: "\r", modifiers: []) else {
            return false
        }
        textView.keyDown(with: submit)
        return textView.string == "new task"
    }

    @MainActor
    static func failures() -> [String] {
        let textView = MarkdownNSTextView()
        textView.string = "alpha beta"
        textView.setSelectedRange(NSRange(location: 3, length: 0))

        var failures = compactSubmissionFailures()

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

        failures.append(contentsOf: tabFailures(using: textView))

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

    @MainActor
    private static func tabFailures(
        using textView: MarkdownNSTextView
    ) -> [String] {
        var failures: [String] = []
        textView.string = "indent"
        textView.setSelectedRange(
            NSRange(location: textView.string.utf16.count, length: 0)
        )
        if let optionTab = keyEvent(
            keyCode: 48,
            characters: "\t",
            modifiers: .option
        ) {
            textView.keyDown(with: optionTab)
            if textView.string != "indent    " {
                failures.append("Option+Tab did not insert four spaces")
            }
        } else {
            failures.append("Option+Tab event could not be created")
        }

        textView.string = "guard"
        textView.setSelectedRange(
            NSRange(location: textView.string.utf16.count, length: 0)
        )
        if let modifiedBacktab = keyEvent(
            keyCode: 48,
            characters: "\u{19}",
            modifiers: [.option, .shift]
        ) {
            textView.keyDown(with: modifiedBacktab)
            if textView.string == "guard    " {
                failures.append("Option+Shift+Tab incorrectly inserted four spaces")
            }
        } else {
            failures.append("Option+Shift+Tab event could not be created")
        }
        return failures
    }

    @MainActor
    private static func compactSubmissionFailures() -> [String] {
        var failures: [String] = []
        if MarkdownEditorStyle.compact.minimumHeight > 32 {
            failures.append("compact editor is taller than a single-line control")
        }

        var returnCommitCount = 0
        if submitWithReturn({ returnCommitCount += 1 }) == false {
            failures.append("Return event could not be created")
        }
        if returnCommitCount != 1 {
            failures.append("Return did not submit the single-line editor")
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
                .font(.noonmarkSystem(size: max(13, 20 - CGFloat(level * 2)), weight: .bold))
        case .paragraph:
            MarkdownInlineText(block.text)
                .lineSpacing(3)
        case let .list(marker, checked):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.noonmarkSystem(size: 11, weight: .semibold))
                        .foregroundStyle(checked ? Theme.ok : Theme.text3)
                        .frame(width: 13)
                } else {
                    Text(marker)
                        .font(.noonmarkSystem(size: 10.5, weight: .bold))
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
                .font(.noonmarkSystem(size: 11.5, design: .monospaced))
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

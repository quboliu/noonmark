import AppKit
import Foundation
import NoonmarkMacRuntime
import SwiftUI

enum MarkdownEditorStyle {
    case title
    case body
    case detailBody
    case compact
    case subtask
    case conversation

    var font: NSFont {
        switch self {
        case .title: .noonmarkSystemFont(ofSize: 14, weight: .semibold)
        case .body, .detailBody: .noonmarkSystemFont(ofSize: 12)
        case .compact, .subtask:
            .systemFont(ofSize: NoonmarkVisualMetrics.compactEditorPointSize, weight: .medium)
        case .conversation:
            .noonmarkSystemFont(ofSize: NoonmarkVisualMetrics.zhulongConversationComposerBodyPointSize)
        }
    }

    var swiftUIFont: Font {
        switch self {
        case .title: .noonmarkSystem(size: 14, weight: .semibold)
        case .body, .detailBody: .noonmarkSystem(size: 12)
        case .compact, .subtask:
            .noonmarkRenderedSystem(
                size: NoonmarkVisualMetrics.compactEditorPointSize,
                weight: .medium
            )
        case .conversation:
            .noonmarkSystem(size: NoonmarkVisualMetrics.zhulongConversationComposerBodyPointSize)
        }
    }

    var minimumHeight: CGFloat {
        switch self {
        case .title: NoonmarkVisualMetrics.detailTitleMinimumHeight
        case .body: 54
        case .detailBody: NoonmarkVisualMetrics.detailDescriptionMinimumHeight
        case .compact, .subtask: 32
        case .conversation: NoonmarkVisualMetrics.zhulongConversationComposerEditorHeight
        }
    }

    var maximumHeight: CGFloat {
        switch self {
        case .title: NoonmarkVisualMetrics.detailTitleMaximumHeight
        case .detailBody: NoonmarkVisualMetrics.detailDescriptionMaximumHeight
        case .body: 132
        case .compact: 32
        case .subtask: 120
        case .conversation: 168
        }
    }

    var textContainerInset: NSSize {
        switch self {
        case .title, .detailBody:
            NSSize(
                width: NoonmarkVisualMetrics.detailHorizontalTextInset,
                height: NoonmarkVisualMetrics.detailVerticalTextInset
            )
        case .body:
            NSSize(width: 5, height: 6)
        case .compact, .subtask:
            // Keep the first 15 pt insertion caret centred in a 32 pt line.
            // Subtask editors reuse this first-line rhythm as they grow.
            NSSize(width: 5, height: NoonmarkVisualMetrics.compactEditorVerticalInset)
        case .conversation:
            NSSize(
                width: NoonmarkVisualMetrics.zhulongConversationComposerHorizontalInset - 5,
                height: NoonmarkVisualMetrics.zhulongConversationComposerVerticalInset
            )
        }
    }

    var lineFragmentPadding: CGFloat {
        switch self {
        case .title, .detailBody:
            NoonmarkVisualMetrics.detailLineFragmentPadding
        case .body, .compact, .subtask, .conversation:
            5
        }
    }
}

struct NativeMarkdownEditorSnapshot: Equatable {
    let text: String
    let isComposing: Bool
}

struct MarkdownEditor: View {
    @Binding var text: String
    let placeholder: String
    var style: MarkdownEditorStyle = .body
    var warm = false
    var showsSurface = true
    var height: CGFloat?
    var commitsOnReturn = false
    var defersMarkedTextBindingUpdates = false
    var onCommit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onNativeSnapshot:
        ((NativeMarkdownEditorSnapshot) -> Void)?
    var nativeAccessibilityIdentifier: String?
    var focusesOnAppear = false
    var focusRequest = 0

    var body: some View {
        let editor = MarkdownTextViewRepresentable(
            text: $text,
            placeholder: placeholder,
            style: style,
            commitsOnReturn: commitsOnReturn,
            defersMarkedTextBindingUpdates:
            defersMarkedTextBindingUpdates,
            onCommit: onCommit,
            onEscape: onEscape,
            onEndEditing: onEndEditing,
            onNativeSnapshot: onNativeSnapshot,
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
            .fixedSize(horizontal: false, vertical: true)
            .background(showsSurface ? (warm ? Theme.noteBackground : Theme.panel2) : Color.clear)
            .accessibilityLabel(placeholder)
    }
}

private struct MarkdownTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let style: MarkdownEditorStyle
    let commitsOnReturn: Bool
    let defersMarkedTextBindingUpdates: Bool
    let onCommit: (() -> Void)?
    let onEscape: (() -> Void)?
    let onEndEditing: (() -> Void)?
    let onNativeSnapshot:
        ((NativeMarkdownEditorSnapshot) -> Void)?
    let accessibilityLabel: String
    let nativeAccessibilityIdentifier: String?
    let explicitHeight: CGFloat?
    let focusesOnAppear: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            defersMarkedTextBindingUpdates:
            defersMarkedTextBindingUpdates,
            onEndEditing: onEndEditing,
            onNativeSnapshot: onNativeSnapshot,
            focusRequest: focusRequest
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownEditorScrollView()
        scrollView.requestsInitialFocus = focusesOnAppear
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = style != .compact
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = MarkdownNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.recordExternalText(text)
        textView.compositionStateDidChange = {
            [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.captureNativeSnapshot(from: textView)
        }
        textView.font = style.font
        textView.textColor = NSColor.labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = style.textContainerInset
        textView.textContainer?.lineFragmentPadding = style.lineFragmentPadding
        textView.configurePlaceholder(
            placeholder,
            font: style.font,
            accessibilityIdentifier: nativeAccessibilityIdentifier.map {
                "\($0).placeholder"
            }
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.commitsOnReturn = commitsOnReturn
        textView.commitAction = onCommit
        textView.escapeAction = onEscape
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
        context.coordinator.onNativeSnapshot =
            onNativeSnapshot
        scrollView.documentView = textView
        scrollView.requestInitialFocusIfPossible()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        // An IME owns the editor contents while marked text is active.
        // Replacing the string from SwiftUI during composition cancels the
        // candidate session before AppKit can commit the selected text.
        if textView.hasMarkedText() == false, textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(location: min(selection.location, text.utf16.count), length: 0)
            )
            context.coordinator.recordExternalText(text)
        }
        textView.font = style.font
        textView.textContainerInset = style.textContainerInset
        textView.textContainer?.lineFragmentPadding = style.lineFragmentPadding
        textView.configurePlaceholder(
            placeholder,
            font: style.font,
            accessibilityIdentifier: nativeAccessibilityIdentifier.map {
                "\($0).placeholder"
            }
        )
        textView.commitsOnReturn = commitsOnReturn
        textView.commitAction = onCommit
        textView.escapeAction = onEscape
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
        context.coordinator.defersMarkedTextBindingUpdates =
            defersMarkedTextBindingUpdates
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.onNativeSnapshot =
            onNativeSnapshot
        textView.compositionStateDidChange = {
            [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.captureNativeSnapshot(from: textView)
        }
        if let editorScrollView = scrollView as? MarkdownEditorScrollView {
            editorScrollView.requestsInitialFocus = focusesOnAppear
            editorScrollView.requestInitialFocusIfPossible()
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak scrollView, weak textView] in
                guard let scrollView, let textView else { return }
                scrollView.window?.makeFirstResponder(textView)
            }
        }
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView =
            scrollView.documentView as? MarkdownNSTextView
        else {
            coordinator.onEndEditing?()
            return
        }
        if textView.hasMarkedText() {
            textView.unmarkText()
        }
        coordinator.captureNativeSnapshot(from: textView)
        coordinator.onEndEditing?()
        textView.delegate = nil
        textView.compositionStateDidChange = nil
        textView.commitAction = nil
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
        let horizontalInsets = (
            textView.textContainerInset.width
                + (textView.textContainer?.lineFragmentPadding ?? 0)
        ) * 2
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var defersMarkedTextBindingUpdates: Bool
        var onEndEditing: (() -> Void)?
        var onNativeSnapshot:
            ((NativeMarkdownEditorSnapshot) -> Void)?
        var focusRequest: Int
        private var lastNativeSnapshot:
            NativeMarkdownEditorSnapshot

        init(
            text: Binding<String>,
            defersMarkedTextBindingUpdates: Bool,
            onEndEditing: (() -> Void)?,
            onNativeSnapshot:
            ((NativeMarkdownEditorSnapshot) -> Void)?,
            focusRequest: Int
        ) {
            self.text = text
            self.defersMarkedTextBindingUpdates =
                defersMarkedTextBindingUpdates
            self.onEndEditing = onEndEditing
            self.onNativeSnapshot = onNativeSnapshot
            self.focusRequest = focusRequest
            lastNativeSnapshot = NativeMarkdownEditorSnapshot(
                text: text.wrappedValue,
                isComposing: false
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            captureNativeSnapshot(from: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onEndEditing?()
        }

        func recordExternalText(_ nextText: String) {
            lastNativeSnapshot = NativeMarkdownEditorSnapshot(
                text: nextText,
                isComposing: false
            )
        }

        func captureNativeSnapshot(
            from textView: NSTextView
        ) {
            let startedAt =
                ProcessInfo.processInfo.systemUptime
            defer {
                (textView as? MarkdownNSTextView)?
                    .recordNativeSnapshotCallback(
                        milliseconds:
                        (
                            ProcessInfo.processInfo
                                .systemUptime
                                - startedAt
                        ) * 1000
                    )
            }
            let snapshot = NativeMarkdownEditorSnapshot(
                text: textView.string,
                isComposing: textView.hasMarkedText()
            )
            guard snapshot != lastNativeSnapshot else {
                return
            }
            lastNativeSnapshot = snapshot
            if IMETextBindingPublicationPolicy
                .shouldPublishToSwiftUI(
                    isComposing: snapshot.isComposing,
                    defersMarkedTextUpdates:
                    defersMarkedTextBindingUpdates
                ),
                text.wrappedValue != snapshot.text
            {
                text.wrappedValue = snapshot.text
            }
            onNativeSnapshot?(snapshot)
        }
    }
}

private final class MarkdownEditorScrollView: NSScrollView {
    var requestsInitialFocus = false
    private var didRequestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocusIfPossible()
    }

    func requestInitialFocusIfPossible() {
        guard requestsInitialFocus,
              didRequestInitialFocus == false,
              let window,
              let textView = documentView as? NSTextView
        else {
            return
        }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window, weak textView] in
            guard let self,
                  let window,
                  let textView,
                  self.window === window
            else {
                return
            }
            window.makeFirstResponder(textView)
        }
    }
}

struct MarkdownEditorKeyDownTiming {
    let enteredAt: TimeInterval
    let markedTextQueryMilliseconds: Double
    let preSuperMilliseconds: Double
    let superKeyDownMilliseconds: Double
    let setMarkedTextMilliseconds: Double
    let insertTextMilliseconds: Double
    let didChangeTextMilliseconds: Double
    let compositionCallbackMilliseconds: Double
    let nativeSnapshotCallbackMilliseconds: Double
}

@MainActor
enum MarkdownEditorKeyDownTimingProbe {
    static var observer:
        ((MarkdownEditorKeyDownTiming) -> Void)?

    static func record(
        _ timing: MarkdownEditorKeyDownTiming
    ) {
        observer?(timing)
    }
}

private final class MarkdownNSTextView: NSTextView {
    var commitsOnReturn = false
    var commitAction: (() -> Void)?
    var escapeAction: (() -> Void)?
    var compositionStateDidChange: (() -> Void)?

    private var reportedCompositionIsActive = false
    private var recordsKeyDownTiming = false
    private var setMarkedTextMilliseconds = 0.0
    private var insertTextMilliseconds = 0.0
    private var didChangeTextMilliseconds = 0.0
    private var compositionCallbackMilliseconds = 0.0
    private var nativeSnapshotCallbackMilliseconds =
        0.0
    private lazy var placeholderField: MarkdownPlaceholderTextField = {
        let field = MarkdownPlaceholderTextField(labelWithString: "")
        field.textColor = .placeholderTextColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        addSubview(field)
        return field
    }()

    func configurePlaceholder(
        _ text: String,
        font: NSFont,
        accessibilityIdentifier: String?
    ) {
        placeholderField.stringValue = text
        placeholderField.font = font
        placeholderField.identifier = accessibilityIdentifier.map {
            NSUserInterfaceItemIdentifier($0)
        }
        updatePlaceholderVisibility()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard placeholderField.superview != nil else { return }
        let linePadding = textContainer?.lineFragmentPadding ?? 0
        let x = textContainerInset.width + linePadding
        let height = ceil(
            placeholderField.font?.boundingRectForFont.height ?? 0
        )
        placeholderField.frame = NSRect(
            x: x,
            y: textContainerInset.height,
            width: max(0, bounds.width - x * 2),
            height: height
        )
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let startedAt =
            ProcessInfo.processInfo.systemUptime
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        if recordsKeyDownTiming {
            setMarkedTextMilliseconds +=
                (
                    ProcessInfo.processInfo.systemUptime
                        - startedAt
                ) * 1000
        }
        let callbackStartedAt =
            ProcessInfo.processInfo.systemUptime
        reportCompositionStateIfNeeded()
        if recordsKeyDownTiming {
            compositionCallbackMilliseconds +=
                (
                    ProcessInfo.processInfo.systemUptime
                        - callbackStartedAt
                ) * 1000
        }
    }

    override func insertText(
        _ insertString: Any,
        replacementRange: NSRange
    ) {
        let startedAt =
            ProcessInfo.processInfo.systemUptime
        super.insertText(
            insertString,
            replacementRange: replacementRange
        )
        if recordsKeyDownTiming {
            insertTextMilliseconds +=
                (
                    ProcessInfo.processInfo.systemUptime
                        - startedAt
                ) * 1000
        }
        let callbackStartedAt =
            ProcessInfo.processInfo.systemUptime
        reportCompositionStateIfNeeded()
        if recordsKeyDownTiming {
            compositionCallbackMilliseconds +=
                (
                    ProcessInfo.processInfo.systemUptime
                        - callbackStartedAt
                ) * 1000
        }
    }

    override func unmarkText() {
        super.unmarkText()
        reportCompositionStateIfNeeded()
    }

    override func didChangeText() {
        let startedAt =
            ProcessInfo.processInfo.systemUptime
        super.didChangeText()
        updatePlaceholderVisibility()
        if recordsKeyDownTiming {
            didChangeTextMilliseconds +=
                (
                    ProcessInfo.processInfo.systemUptime
                        - startedAt
                ) * 1000
        }
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = string.isEmpty == false
    }

    override func keyDown(with event: NSEvent) {
        recordsKeyDownTiming = true
        setMarkedTextMilliseconds = 0
        insertTextMilliseconds = 0
        didChangeTextMilliseconds = 0
        compositionCallbackMilliseconds = 0
        nativeSnapshotCallbackMilliseconds = 0
        let enteredAt =
            ProcessInfo.processInfo.systemUptime
        let markedTextQueryStartedAt =
            ProcessInfo.processInfo.systemUptime
        let isComposing = hasMarkedText()
        let markedTextQueryFinishedAt =
            ProcessInfo.processInfo.systemUptime
        var superStartedAt: TimeInterval?
        var superFinishedAt: TimeInterval?
        defer {
            let finishedAt =
                ProcessInfo.processInfo.systemUptime
            MarkdownEditorKeyDownTimingProbe.record(
                MarkdownEditorKeyDownTiming(
                    enteredAt: enteredAt,
                    markedTextQueryMilliseconds:
                    (
                        markedTextQueryFinishedAt
                            - markedTextQueryStartedAt
                    ) * 1000,
                    preSuperMilliseconds:
                    (
                        (
                            superStartedAt
                                ?? finishedAt
                        )
                            - markedTextQueryFinishedAt
                    ) * 1000,
                    superKeyDownMilliseconds:
                    superStartedAt.map {
                        (
                            (
                                superFinishedAt
                                    ?? finishedAt
                            ) - $0
                        ) * 1000
                    } ?? 0,
                    setMarkedTextMilliseconds:
                    setMarkedTextMilliseconds,
                    insertTextMilliseconds:
                    insertTextMilliseconds,
                    didChangeTextMilliseconds:
                    didChangeTextMilliseconds,
                    compositionCallbackMilliseconds:
                    compositionCallbackMilliseconds,
                    nativeSnapshotCallbackMilliseconds:
                    nativeSnapshotCallbackMilliseconds
                )
            )
            recordsKeyDownTiming = false
        }
        // Give the active input method the untouched event stream. Reading
        // command characters before AppKit interprets a marked-text event can
        // prevent third-party IMEs from committing their selected candidate.
        if isComposing {
            superStartedAt =
                ProcessInfo.processInfo.systemUptime
            super.keyDown(with: event)
            superFinishedAt =
                ProcessInfo.processInfo.systemUptime
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if handleEscape(event, modifiers: modifiers) { return }
        if handleSelectAll(key: key, modifiers: modifiers) { return }
        if handleReturn(event, modifiers: modifiers) { return }
        if handleFormattingShortcut(key: key, modifiers: modifiers) { return }
        if handleTab(event, modifiers: modifiers) { return }
        superStartedAt =
            ProcessInfo.processInfo.systemUptime
        super.keyDown(with: event)
        superFinishedAt =
            ProcessInfo.processInfo.systemUptime
    }

    func recordNativeSnapshotCallback(
        milliseconds: Double
    ) {
        guard recordsKeyDownTiming else {
            return
        }
        nativeSnapshotCallbackMilliseconds +=
            milliseconds
    }

    private func reportCompositionStateIfNeeded() {
        let isActive = hasMarkedText()
        guard isActive != reportedCompositionIsActive else {
            return
        }
        reportedCompositionIsActive = isActive
        compositionStateDidChange?()
    }

    private func handleEscape(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 53,
              modifiers.isDisjoint(with: [.command, .shift, .control, .option]),
              let escapeAction
        else {
            return false
        }
        escapeAction()
        return true
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

private final class MarkdownPlaceholderTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
    var e2eIdentifier: String?

    init(
        _ source: String,
        fallback: String = "",
        e2eIdentifier: String? = nil
    ) {
        self.source = source
        self.fallback = fallback
        self.e2eIdentifier = e2eIdentifier
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(source.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        if blocks.isEmpty {
            Text(fallback)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block)
                        .background {
                            if let e2eIdentifier {
                                AppE2EViewAnchor(
                                    identifier: "\(e2eIdentifier).\(index)",
                                    verificationText: block.kind.verificationValue
                                )
                            }
                        }
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
            HStack(alignment: .top, spacing: 8) {
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

        var verificationValue: String {
            switch self {
            case let .heading(level):
                "heading-\(level)"
            case .paragraph:
                "paragraph"
            case .list:
                "list"
            case .quote:
                "quote"
            case .code:
                "code"
            }
        }
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

import AppKit
import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

enum FlylightComposerMode: Equatable {
    case pageCreate
    case globalCapture
    case inlineEdit
}

enum FlylightComposerState: Equatable {
    case pristine
    case dirty
    case invalid
    case saving
    case success
    case failed

    init(
        _ state: IdeaComposerSubmissionState,
        isDirty: Bool,
        isInvalid: Bool
    ) {
        switch state {
        case .idle:
            self = isInvalid ? .invalid : (isDirty ? .dirty : .pristine)
        case .saving: self = .saving
        case .succeeded: self = .success
        case .empty: self = .invalid
        case .failed: self = .failed
        }
    }

    init(
        _ state: IdeaInlineEditorSaveState,
        isDirty: Bool,
        isInvalid: Bool
    ) {
        switch state {
        case .idle:
            self = isInvalid ? .invalid : (isDirty ? .dirty : .pristine)
        case .saving: self = .saving
        case .succeeded: self = .success
        case .empty: self = .invalid
        case .failed: self = .failed
        }
    }
}

enum FlylightActionEmphasis {
    case primary
    case secondary
}

struct FlylightActionButton: View {
    let title: String
    let identifier: String
    let emphasis: FlylightActionEmphasis
    var isBusy = false
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 12, height: 12)
                }
                Text(title)
                    .lineLimit(1)
                if isBusy == false, let systemImage {
                    Image(systemName: systemImage)
                        .font(.noonmarkSystem(size: 10.5, weight: .bold))
                }
            }
            .frame(minWidth: emphasis == .primary ? 76 : 52)
        }
        .buttonStyle(FlylightActionButtonStyle(emphasis: emphasis))
        .accessibilityIdentifier(identifier)
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: title
            )
        }
    }
}

private struct FlylightActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let emphasis: FlylightActionEmphasis

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.noonmarkSystem(size: 12.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 13)
            .frame(height: NoonmarkVisualMetrics.ideasComposerActionButtonHeight)
            .background(background(configuration: configuration))
            .overlay {
                if emphasis == .secondary {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.lineSubtle)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.text3 }
        return emphasis == .primary ? .white : Theme.text2
    }

    private func background(configuration: Configuration) -> Color {
        guard isEnabled else { return Theme.chip }
        return switch emphasis {
        case .primary:
            configuration.isPressed
                ? Theme.accent.opacity(0.88)
                : Theme.accent
        case .secondary:
            configuration.isPressed
                ? Theme.chip
                : Theme.controlFill
        }
    }
}

/// The product boundary for all Flylight writing. Callers provide state and
/// intents; editor focus, Markdown tools, action hierarchy, validation and
/// deferred blur ordering stay inside this surface.
struct FlylightComposerSurface: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var text: String

    let mode: FlylightComposerMode
    let state: FlylightComposerState
    let issueMessage: String?
    let identifier: String
    let placeholder: String
    var primaryIdentifier: String?
    var secondaryIdentifier: String?
    var focusesOnAppear = false
    var focusRequest = 0
    let onSubmit: () -> Void
    var onSecondary: (() -> Void)?
    var onBlur: (() -> Bool)?

    @State private var isFocused = false
    @State private var commandGeneration: UInt64 = 0
    @State private var commandRequest: MarkdownEditorCommandRequest?
    @State private var recoveryFocusRequest = 0

    private var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard normalizedText.isEmpty == false else { return false }
        if state == .failed {
            return true
        }
        return issueMessage == nil && state == .dirty
    }

    private var primaryTitle: String {
        if state == .failed {
            return store.copy.ideaRetryAction
        }
        return switch mode {
        case .pageCreate, .globalCapture:
            state == .saving
                ? store.copy.ideaPublishingStatus
                : store.copy.ideaPublishAction
        case .inlineEdit:
            state == .saving
                ? store.copy.ideaSavingEditStatus
                : store.copy.ideaSaveEditAction
        }
    }

    private var secondaryTitle: String? {
        switch mode {
        case .pageCreate: nil
        case .globalCapture: store.copy.ideaContinueLaterAction
        case .inlineEdit: store.copy.ideaCancelEditAction
        }
    }

    private var message: String? {
        if let issueMessage {
            return issueMessage
        }
        switch state {
        case .invalid:
            return store.copy.ideaContentRequired
        case .failed:
            return mode == .inlineEdit
                ? store.copy.ideaEditSaveFailed
                : store.copy.ideaPublishFailed
        case .pristine, .dirty, .saving, .success:
            return nil
        }
    }

    private var statusText: String? {
        switch state {
        case .dirty:
            return mode == .inlineEdit
                ? store.copy.ideaDirtyEditStatus
                : store.copy.ideaDirtyPublishStatus
        case .saving:
            return store.copy.ideaSavingLocallyStatus
        case .success:
            return mode == .inlineEdit
                ? store.copy.ideaEditSucceededStatus
                : store.copy.ideaPublishSucceededStatus
        case .pristine, .invalid, .failed:
            return nil
        }
    }

    private var activeClassificationToken: NewTaskClassificationToken? {
        store.ideaClassificationToken(for: text)
    }

    private var classificationSuggestions: [ClassificationCatalogItemProjection] {
        Array(store.ideaClassificationSuggestions(for: text).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            composerSurface
            if let activeClassificationToken, classificationSuggestions.isEmpty == false {
                NewTaskClassificationSuggestionList(
                    tokenKind: activeClassificationToken.kind,
                    suggestions: classificationSuggestions,
                    accessibilityIdentifier: "\(identifier).suggestions"
                ) { suggestion in
                    text = store.completeIdeaClassificationToken(
                        in: text,
                        with: suggestion.name
                    )
                    recoveryFocusRequest &+= 1
                }
            }
        }
        .onChange(of: state) { _, nextState in
            if mode == .pageCreate, nextState == .success {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var composerSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownEditor(
                text: $text,
                placeholder: placeholder,
                style: .flylight,
                showsSurface: false,
                onCommit: submit,
                onEscape: escape,
                onEndEditing: scheduleBlur,
                onFocusChange: { focused in
                    isFocused = focused
                },
                commandRequest: commandRequest,
                accessibilityLabel: store.copy.ideaBodyAccessibilityLabel,
                nativeAccessibilityIdentifier: identifier,
                focusesOnAppear: focusesOnAppear,
                focusRequest: focusRequest &+ recoveryFocusRequest
            )

            if let message {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warnSoft.opacity(0.55))
                .accessibilityIdentifier("\(identifier).message")
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(identifier).message",
                        verificationText: message
                    )
                }
            }

            Divider().overlay(Theme.lineSubtle)

            HStack(spacing: 4) {
                toolButton(
                    title: "#",
                    label: store.copy.ideaLabelTool,
                    suffix: "label",
                    command: .insertLabelToken
                )
                toolButton(
                    title: "@",
                    label: store.copy.ideaCategoryTool,
                    suffix: "category",
                    command: .insertCategoryToken
                )
                formatMenu

                Spacer(minLength: 8)

                if let statusText {
                    Text(statusText)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(
                            state == .success ? Theme.ok : Theme.text3
                        )
                        .lineLimit(1)
                        .transition(.opacity)
                        .accessibilityIdentifier("\(identifier).status")
                }

                HStack(spacing: NoonmarkVisualMetrics.ideasComposerActionSpacing) {
                    if let secondaryTitle {
                        FlylightActionButton(
                            title: secondaryTitle,
                            identifier: secondaryIdentifier
                                ?? "\(identifier).secondary",
                            emphasis: .secondary,
                            action: secondary
                        )
                    }
                    FlylightActionButton(
                        title: primaryTitle,
                        identifier: primaryIdentifier
                            ?? "\(identifier).primary",
                        emphasis: .primary,
                        isBusy: state == .saving,
                        systemImage: state == .success ? nil : "arrow.up",
                        action: submit
                    )
                    .disabled(canSubmit == false)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: NoonmarkVisualMetrics.ideasComposerActionBarHeight)
        }
        .background(Theme.panel2)
        .clipShape(
            RoundedRectangle(
                cornerRadius: NoonmarkVisualMetrics.ideasComposerCornerRadius
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: NoonmarkVisualMetrics.ideasComposerCornerRadius
            )
            .stroke(
                isFocused ? Theme.accent : Theme.lineSubtle,
                lineWidth: isFocused ? 1.5 : 1
            )
        }
        .background {
            AppE2EViewAnchor(
                identifier: "\(identifier).surface",
                verificationText: stateVerificationText
            )
        }
    }

    private var formatMenu: some View {
        Menu {
            Button(store.copy.ideaFormatBold) { request(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button(store.copy.ideaFormatItalic) { request(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button(store.copy.ideaFormatLink) { request(.link) }
                .keyboardShortcut("k", modifiers: .command)
            Button(store.copy.ideaFormatInlineCode) { request(.inlineCode) }
            Divider()
            ForEach(1 ... 3, id: \.self) { level in
                Button(store.copy.ideaFormatHeading(level)) {
                    request(.heading(level))
                }
            }
            Divider()
            Button(store.copy.ideaFormatUnorderedList) {
                request(.unorderedList)
            }
            Button(store.copy.ideaFormatOrderedList) {
                request(.orderedList)
            }
            Button(store.copy.ideaFormatTaskList) {
                request(.taskList)
            }
            Button(store.copy.ideaFormatQuote) { request(.quote) }
            Button(store.copy.ideaFormatCodeBlock) { request(.codeBlock) }
        } label: {
            Text("Aa")
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(
                    width: NoonmarkVisualMetrics.ideasComposerToolHitTarget,
                    height: NoonmarkVisualMetrics.ideasComposerToolHitTarget
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(identifier).tool.format"
                    )
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            AppE2EViewAnchor(
                identifier: "\(identifier).tool.format"
            )
        }
        .help(store.copy.ideaFormattingTool)
        .accessibilityLabel(store.copy.ideaFormattingTool)
        .accessibilityIdentifier("\(identifier).tool.format")
    }

    private func toolButton(
        title: String,
        label: String,
        suffix: String,
        command: MarkdownEditorCommand
    ) -> some View {
        Button {
            request(command)
        } label: {
            Text(title)
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .frame(
                    width: NoonmarkVisualMetrics.ideasComposerToolHitTarget,
                    height: NoonmarkVisualMetrics.ideasComposerToolHitTarget
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(identifier).tool.\(suffix)"
                    )
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(identifier).tool.\(suffix)")
    }

    private var stateVerificationText: String {
        switch state {
        case .pristine: "pristine"
        case .dirty: "dirty"
        case .invalid: "invalid"
        case .saving: "saving"
        case .success: "success"
        case .failed: "failed"
        }
    }

    private func request(_ command: MarkdownEditorCommand) {
        commandGeneration &+= 1
        commandRequest = MarkdownEditorCommandRequest(
            generation: commandGeneration,
            command: command
        )
    }

    private func submit() {
        guard canSubmit else {
            NSSound.beep()
            return
        }
        onSubmit()
    }

    private func secondary() {
        onSecondary?()
    }

    private func escape() {
        switch mode {
        case .pageCreate:
            NSApp.keyWindow?.makeFirstResponder(nil)
        case .globalCapture, .inlineEdit:
            secondary()
        }
    }

    private func scheduleBlur() {
        guard onBlur != nil else { return }
        DispatchQueue.main.async {
            guard isFocused == false else { return }
            if onBlur?() == false {
                recoveryFocusRequest &+= 1
            }
        }
    }
}

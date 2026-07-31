import NoonmarkMacRuntime
import NoonmarkZhulong
import SwiftUI

/// View-layer polish metrics for the Zhulong session surface. These refine the
/// contract-level conversation layout (message rhythm, readable measure and
/// composer surface) without touching the design contract module itself.
enum ZhulongSessionPolishMetrics {
    static let contentMaxWidth = 680.0
    static let messageSpacing = 20.0
    static let turnSpacing = 24.0
    static let bodyPointSize = 13.0
    static let bodyLineSpacing = 4.0
    static let metaPointSize = 10.5
    static let userBubbleMaxWidth = 480.0
    static let userBubbleMinimumLeading = 96.0
    static let userBubbleCornerRadius = 12.0
    static let userBubbleHorizontalPadding = 12.0
    static let userBubbleVerticalPadding = 8.0
    static let composerCornerRadius = 12.0
    static let composerActionSize = 28.0
    static let composerActionRowInset = 12.0
    static let composerActionRowBottomPadding = 8.0
    static let composerOuterBottomPadding = 16.0
    static let streamContentBottomPadding = 36.0
}

/// All four stream views deliberately reuse this one transcript grammar. The
/// projection changes how records are grouped for reading; it never replaces
/// the message primitive with a second dashboard renderer.
struct ZhulongChatTranscript<ArtifactContent: View>: View {
    let records: [ZhulongStreamRecord]
    let variant: ZhulongStreamView
    let sectionTitle: (ZhulongStreamSection) -> String
    let dossierSectionTitle: (String) -> String
    let chapterSectionTitle: (Int, String) -> String
    @ViewBuilder let artifactContent:
        (ZhulongTodoDiffID) -> ArtifactContent

    var body: some View {
        transcript
            .frame(
                maxWidth: ZhulongSessionPolishMetrics.contentMaxWidth,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityIdentifier("zhulong-stream-\(variant.rawValue)")
    }

    @ViewBuilder
    private var transcript: some View {
        switch variant {
        case .conversation:
            conversationTranscript
        case .dossier:
            dossierTranscript
        case .chapters:
            chaptersTranscript
        case .weave:
            weaveTranscript
        }
    }

    private var conversationTranscript: some View {
        VStack(alignment: .leading, spacing: ZhulongSessionPolishMetrics.messageSpacing) {
            ForEach(visibleRecords) { record in
                transcriptRecord(record)
            }
        }
    }

    private var dossierTranscript: some View {
        VStack(alignment: .leading, spacing: ZhulongSessionPolishMetrics.messageSpacing) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                if beginsSection(for: record, at: index) {
                    dossierHeader(for: record.section)
                }
                transcriptRecord(record)
            }
        }
    }

    private var chaptersTranscript: some View {
        VStack(alignment: .leading, spacing: ZhulongSessionPolishMetrics.messageSpacing) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                if beginsSection(for: record, at: index) {
                    chapterHeader(for: record.section, number: chapterNumber(at: index))
                }
                transcriptRecord(record)
            }
        }
    }

    private var weaveTranscript: some View {
        VStack(alignment: .leading, spacing: ZhulongSessionPolishMetrics.turnSpacing) {
            ForEach(Array(weaveTurns.enumerated()), id: \.offset) { index, turn in
                VStack(alignment: .leading, spacing: ZhulongSessionPolishMetrics.messageSpacing) {
                    ForEach(turn) { record in
                        transcriptRecord(record)
                    }
                }
                .accessibilityIdentifier("zhulong-stream-weave-turn-\(index)")

                if index < weaveTurns.count - 1 {
                    RailDivider()
                        .padding(.leading, 48)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRecord(
        _ record: ZhulongStreamRecord
    ) -> some View {
        switch record.content {
        case .message:
            ZhulongChatMessage(record: record)
                .id(record.id)
        case let .conversationTodoArtifact(draftID):
            artifactContent(draftID)
                .id(record.id)
        }
    }

    private func beginsSection(
        for record: ZhulongStreamRecord,
        at index: Int
    ) -> Bool {
        guard index > 0 else { return true }
        return visibleRecords[index - 1].section != record.section
    }

    private func chapterNumber(at index: Int) -> Int {
        guard index > 0 else { return 1 }
        var number = 1
        for currentIndex in 1 ... index where
            visibleRecords[currentIndex - 1].section != visibleRecords[currentIndex].section
        {
            number += 1
        }
        return number
    }

    private var visibleRecords: [ZhulongStreamRecord] {
        records.filter { record in
            record.actor != .system || record.isCriticalSystemNotice || record.isInvalidation
        }
    }

    private var weaveTurns: [[ZhulongStreamRecord]] {
        visibleRecords.reduce(into: []) { turns, record in
            if record.actor == .user, turns.last?.isEmpty == false {
                turns.append([record])
            } else if turns.isEmpty {
                turns.append([record])
            } else {
                turns[turns.count - 1].append(record)
            }
        }
    }

    private func dossierHeader(for section: ZhulongStreamSection) -> some View {
        HStack(spacing: 10) {
            Text(dossierSectionTitle(sectionTitle(section)))
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            RailDivider()
        }
        .padding(.top, 8)
        .padding(.bottom, -12)
    }

    private func chapterHeader(for section: ZhulongStreamSection, number: Int) -> some View {
        Text(chapterSectionTitle(number, sectionTitle(section)))
            .font(.noonmarkSystem(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .tracking(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, -8)
    }
}

private struct ZhulongChatMessage: View {
    let record: ZhulongStreamRecord

    private var message: String {
        guard let body = record.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              body.isEmpty == false
        else { return record.title }
        return body
    }

    var body: some View {
        switch record.actor {
        case .user:
            userMessage
        case .zhulong:
            zhulongMessage
        case .system:
            systemMessage
        }
    }

    private var userMessage: some View {
        HStack(alignment: .top) {
            Spacer(minLength: ZhulongSessionPolishMetrics.userBubbleMinimumLeading)
            userBubble
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userBubble: some View {
        ZhulongUserBubbleLayout(
            maximumWidth:
            ZhulongSessionPolishMetrics.userBubbleMaxWidth
        ) {
            MarkdownText(message)
                .font(
                    .noonmarkSystem(
                        size:
                        ZhulongSessionPolishMetrics.bodyPointSize
                    )
                )
                .foregroundStyle(Theme.text1)
                .lineSpacing(ZhulongSessionPolishMetrics.bodyLineSpacing)
                .padding(.horizontal, ZhulongSessionPolishMetrics.userBubbleHorizontalPadding)
                .padding(.vertical, ZhulongSessionPolishMetrics.userBubbleVerticalPadding)
                .background(
                    RoundedRectangle(
                        cornerRadius:
                        ZhulongSessionPolishMetrics.userBubbleCornerRadius,
                        style: .continuous
                    )
                    .fill(Theme.accentSoft)
                )
        }
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-message-\(record.id)",
                verificationText: message
            )
        }
    }

    private var zhulongMessage: some View {
        MarkdownText(message)
            .font(.noonmarkSystem(size: ZhulongSessionPolishMetrics.bodyPointSize))
            .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
            .lineSpacing(ZhulongSessionPolishMetrics.bodyLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(record.isInvalidation ? 0.70 : 1)
    }

    private var systemMessage: some View {
        Text(systemText)
            .font(.noonmarkSystem(size: ZhulongSessionPolishMetrics.metaPointSize, weight: .medium))
            .foregroundStyle(record.isInvalidation ? Theme.warn : Theme.text3)
            .monospacedDigit()
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(record.isInvalidation ? 0.82 : 1)
    }

    private var systemText: String {
        guard let detail = record.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              detail.isEmpty == false
        else { return record.title }
        return "\(record.title) · \(detail)"
    }
}

struct ZhulongLiveAssistantMessage: View {
    let content: String

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            MarkdownText(content)
                .font(.noonmarkSystem(
                    size: ZhulongSessionPolishMetrics.bodyPointSize
                ))
                .foregroundStyle(Theme.text1)
                .lineSpacing(ZhulongSessionPolishMetrics.bodyLineSpacing)
                .textSelection(.enabled)
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.text2)
                .frame(width: 1.5, height: 15)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("zhulong-live-assistant-message")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-live-assistant-message",
                verificationText: content
            )
        }
    }
}

/// Placeholder shown on the assistant axis while a provider run has started
/// but no visible token has arrived yet. It reuses the live-message anchor so
/// the streaming message replaces it in place at the same identifier.
struct ZhulongProviderWaitingIndicator: View {
    let waitingText: String

    var body: some View {
        HStack(spacing: 8) {
            if Theme.shouldReduceMotion == false {
                ZhulongBreathingDots()
            }
            Text(waitingText)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("zhulong-live-assistant-message")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-live-assistant-message",
                verificationText: waitingText
            )
        }
    }
}

/// Three accent dots pulsing in sequence on a 1.2 s cycle.
private struct ZhulongBreathingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .phaseAnimator([0.25, 1.0]) { dot, opacity in
                        dot.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 0.6).delay(Double(index) * 0.2)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Keeps a short user message close to its readable content width while giving
/// long Markdown an explicit wrapping measure. A flexible `frame(maxWidth:)`
/// would otherwise make every short message occupy the full bubble limit.
private struct ZhulongUserBubbleLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let availableWidth = min(proposal.width ?? maximumWidth, maximumWidth)
        let intrinsicSize = subview.sizeThatFits(.unspecified)
        let width = min(max(1, intrinsicSize.width), availableWidth)
        let fittingSize = subview.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
        return CGSize(width: width, height: fittingSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height)
        )
    }
}

struct ZhulongChatComposer: View {
    @Binding var text: String
    let placeholder: String
    let sendAccessibilityLabel: String
    let stopAccessibilityLabel: String
    let primaryAction: ZhulongComposerPrimaryAction
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var editorIsFocused: Bool

    private var isSendEnabled: Bool {
        guard case let .send(isEnabled) = primaryAction else {
            return false
        }
        return isEnabled
    }

    private var actionIsProminent: Bool {
        isSendEnabled || primaryAction == .stop
    }

    private var actionIdentifier: String {
        switch primaryAction {
        case .send:
            "zhulong-session-send"
        case .stop:
            "zhulong-session-stop"
        }
    }

    private var actionAccessibilityLabel: String {
        switch primaryAction {
        case .send:
            sendAccessibilityLabel
        case .stop:
            stopAccessibilityLabel
        }
    }

    private var actionSystemImage: String {
        switch primaryAction {
        case .send:
            "arrow.up"
        case .stop:
            "stop.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownEditor(
                text: $text,
                placeholder: placeholder,
                style: .conversation,
                showsSurface: false,
                height: NoonmarkVisualMetrics.zhulongConversationComposerEditorHeight,
                commitsOnReturn: true,
                onCommit: submitIfAvailable,
                nativeAccessibilityIdentifier: "zhulong-session-entry"
            )
            .focused($editorIsFocused)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: performPrimaryAction) {
                    Image(systemName: actionSystemImage)
                        .font(.noonmarkSystem(
                            size: primaryAction == .stop ? 10 : 12,
                            weight: .bold
                        ))
                        .foregroundStyle(
                            actionIsProminent
                                ? Color.white
                                : Theme.text3
                        )
                        .frame(
                            width: ZhulongSessionPolishMetrics.composerActionSize,
                            height: ZhulongSessionPolishMetrics.composerActionSize
                        )
                        .background(
                            Circle().fill(
                                actionIsProminent
                                    ? Theme.accent
                                    : Theme.controlFill
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(primaryAction == .send(isEnabled: false))
                .accessibilityLabel(actionAccessibilityLabel)
                .accessibilityIdentifier(actionIdentifier)
                .background {
                    AppE2EViewAnchor(
                        identifier: actionIdentifier,
                        verificationText: actionAccessibilityLabel
                    )
                }
            }
            .padding(.horizontal, ZhulongSessionPolishMetrics.composerActionRowInset)
            .padding(.bottom, ZhulongSessionPolishMetrics.composerActionRowBottomPadding)
        }
        .frame(minHeight: NoonmarkVisualMetrics.zhulongConversationComposerMinimumHeight)
        .background(
            RoundedRectangle(
                cornerRadius: ZhulongSessionPolishMetrics.composerCornerRadius,
                style: .continuous
            )
            .fill(Theme.panel2)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: ZhulongSessionPolishMetrics.composerCornerRadius,
                style: .continuous
            )
            .stroke(editorIsFocused ? Theme.accentStroke : Color.clear)
        )
        .shadow(color: Theme.shadowSubtle, radius: 16, y: 4)
        .accessibilityIdentifier("zhulong-session-composer")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-session-composer",
                verificationText: placeholder
            )
        }
    }

    private func submitIfAvailable() {
        guard isSendEnabled else { return }
        onSend()
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .send:
            submitIfAvailable()
        case .stop:
            onStop()
        }
    }
}

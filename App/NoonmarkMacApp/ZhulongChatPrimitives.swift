import NoonmarkMacRuntime
import NoonmarkZhulong
import SwiftUI

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
                maxWidth: NoonmarkVisualMetrics.zhulongConversationContentMaxWidth,
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
        VStack(alignment: .leading, spacing: NoonmarkVisualMetrics.zhulongConversationMessageSpacing) {
            ForEach(visibleRecords) { record in
                transcriptRecord(record)
            }
        }
    }

    private var dossierTranscript: some View {
        VStack(alignment: .leading, spacing: NoonmarkVisualMetrics.zhulongConversationMessageSpacing) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                if beginsSection(for: record, at: index) {
                    dossierHeader(for: record.section)
                }
                transcriptRecord(record)
            }
        }
    }

    private var chaptersTranscript: some View {
        VStack(alignment: .leading, spacing: NoonmarkVisualMetrics.zhulongConversationMessageSpacing) {
            ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                if beginsSection(for: record, at: index) {
                    chapterHeader(for: record.section, number: chapterNumber(at: index))
                }
                transcriptRecord(record)
            }
        }
    }

    private var weaveTranscript: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(weaveTurns.enumerated()), id: \.offset) { index, turn in
                VStack(alignment: .leading, spacing: NoonmarkVisualMetrics.zhulongConversationMessageSpacing) {
                    ForEach(turn) { record in
                        transcriptRecord(record)
                    }
                }
                .accessibilityIdentifier("zhulong-stream-weave-turn-\(index)")

                if index < weaveTurns.count - 1 {
                    Divider()
                        .overlay(Theme.line.opacity(0.64))
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
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.28)
            Divider()
                .overlay(Theme.line.opacity(0.6))
        }
        .padding(.top, 8)
        .padding(.bottom, -12)
    }

    private func chapterHeader(for section: ZhulongStreamSection, number: Int) -> some View {
        Text(chapterSectionTitle(number, sectionTitle(section)))
            .font(.noonmarkSystem(size: 12, weight: .semibold))
            .foregroundStyle(Theme.text2)
            .tracking(0.16)
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
            Spacer(minLength: 96)
            userBubble
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userBubble: some View {
        ZhulongUserBubbleLayout(
            maximumWidth:
            NoonmarkVisualMetrics.zhulongConversationUserBubbleMaxWidth
        ) {
            MarkdownText(message)
                .font(
                    .noonmarkSystem(
                        size:
                        NoonmarkVisualMetrics
                            .zhulongConversationUserBodyPointSize
                    )
                )
                .foregroundStyle(Theme.text1)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(
                        cornerRadius:
                        NoonmarkVisualMetrics
                            .zhulongConversationUserBubbleCornerRadius
                    )
                    .fill(Theme.chip)
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
            .font(.noonmarkSystem(size: NoonmarkVisualMetrics.zhulongConversationAssistantBodyPointSize))
            .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(record.isInvalidation ? 0.70 : 1)
    }

    private var systemMessage: some View {
        Text(systemText)
            .font(.noonmarkSystem(size: 11.5, weight: .medium))
            .foregroundStyle(record.isInvalidation ? Theme.warn : Theme.text3)
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
    let waitingText: String

    var body: some View {
        Group {
            if content.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(waitingText)
                        .font(.noonmarkSystem(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text3)
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    MarkdownText(content)
                        .font(.noonmarkSystem(
                            size: NoonmarkVisualMetrics.zhulongConversationAssistantBodyPointSize
                        ))
                        .foregroundStyle(Theme.text1)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.text2)
                        .frame(width: 1.5, height: 15)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("zhulong-live-assistant-message")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-live-assistant-message",
                verificationText: content.isEmpty ? waitingText : content
            )
        }
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
    let keyboardHint: String
    let sendAccessibilityLabel: String
    let canSubmit: Bool
    let sessionControlTitle: String?
    let sessionControlSystemImage: String
    let sessionControlAccessibilityIdentifier: String?
    let onSessionControl: (() -> Void)?
    let onSend: () -> Void

    private var canSend: Bool {
        canSubmit && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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

            HStack(spacing: 10) {
                Text(keyboardHint)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer(minLength: 12)
                if let sessionControlTitle,
                   let sessionControlAccessibilityIdentifier,
                   let onSessionControl
                {
                    Button(action: onSessionControl) {
                        Label(
                            sessionControlTitle,
                            systemImage: sessionControlSystemImage
                        )
                        .font(.noonmarkSystem(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(
                            Capsule().fill(Theme.chip.opacity(0.72))
                        )
                        .overlay(Capsule().stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        sessionControlAccessibilityIdentifier
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            sessionControlAccessibilityIdentifier,
                            verificationText: sessionControlTitle
                        )
                    }
                }
                Button(action: submitIfAvailable) {
                    Image(systemName: "arrow.up")
                        .font(.noonmarkSystem(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Theme.panel : Theme.text3)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? Theme.text1 : Theme.chip))
                        .overlay(Circle().stroke(canSend ? Color.clear : Theme.line))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(canSend == false)
                .accessibilityLabel(sendAccessibilityLabel)
                .accessibilityIdentifier("zhulong-session-send")
            }
            .padding(.horizontal, NoonmarkVisualMetrics.zhulongConversationComposerHorizontalInset)
            .padding(.bottom, 10)
        }
        .frame(minHeight: NoonmarkVisualMetrics.zhulongConversationComposerMinimumHeight)
        .background(
            RoundedRectangle(cornerRadius: NoonmarkVisualMetrics.zhulongConversationComposerCornerRadius)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NoonmarkVisualMetrics.zhulongConversationComposerCornerRadius)
                .stroke(Theme.line)
        )
        .shadow(color: Theme.text1.opacity(0.07), radius: 16, y: 5)
        .accessibilityIdentifier("zhulong-session-composer")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-session-composer",
                verificationText: placeholder
            )
        }
    }

    private func submitIfAvailable() {
        guard canSend else { return }
        onSend()
    }
}

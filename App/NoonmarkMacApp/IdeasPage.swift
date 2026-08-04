import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct IdeasPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var searchIsPresented = false

    private var visibleIdeaIDs: [IdeaID] {
        store.displayedIdeaGroups.flatMap {
            $0.ideas.map(\.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePageHeader(
                title: store.copy.navIdeas,
                subtitle: store.copy.ideasSubtitle
            ) {
                IdeaPageToolbar(searchIsPresented: $searchIsPresented)
            }
            IdeaTimelinePane(searchIsPresented: $searchIsPresented)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.page",
                verificationText: store.copy.navIdeas
            )
        }
        .onChange(of: visibleIdeaIDs) { _, ids in
            guard let editingID = store.editingIdeaID,
                  ids.contains(editingID) == false
            else { return }
            store.cancelIdeaEdit()
        }
    }
}

private struct IdeaPageToolbar: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var searchIsPresented: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if searchIsPresented {
                    store.dismissIdeaSearch()
                    searchIsPresented = false
                } else {
                    store.showRecentIdeas()
                    searchIsPresented = true
                }
            } label: {
                Label(
                    store.copy.ideaSearchAction,
                    systemImage: "magnifyingglass"
                )
            }
            .buttonStyle(.borderless)
            .foregroundStyle(
                searchIsPresented ? Theme.accent : Theme.text2
            )
            .accessibilityIdentifier("ideas.search.toggle")
            .background {
                AppE2EViewAnchor(identifier: "ideas.search.toggle")
            }

            Button {
                searchIsPresented = false
                if store.ideaBrowseMode == .review {
                    store.showRecentIdeas()
                } else {
                    store.showIdeaReview()
                }
            } label: {
                Label(
                    store.copy.ideaReviewAction,
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderless)
            .foregroundStyle(
                store.ideaBrowseMode == .review
                    ? Theme.accent
                    : Theme.text2
            )
            .accessibilityIdentifier("ideas.review.toggle")
            .background {
                AppE2EViewAnchor(identifier: "ideas.review.toggle")
            }
        }
        .font(.noonmarkSystem(size: 11.5, weight: .medium))
    }
}

private struct IdeaTimelinePane: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var searchIsPresented: Bool

    private var groups: [IdeaDayGroup] {
        store.displayedIdeaGroups
    }

    private var visibleIdeaIDs: [IdeaID] {
        groups.flatMap { $0.ideas.map(\.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                IdeaComposer(session: store.ideaComposerSession)
                if searchIsPresented {
                    IdeaFilterField()
                }
                IdeaCollectionContext(count: visibleIdeaIDs.count)
            }
            .frame(
                maxWidth: NoonmarkVisualMetrics
                    .ideasReadableTimelineMaximumWidth
            )
            .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)

            ScrollViewReader { proxy in
                TaskSelectionClearingScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let filterName = store.activeIdeaClassificationFilterName {
                            IdeaClassificationFilterIndicator(name: filterName)
                                .padding(
                                    .bottom,
                                    NoonmarkVisualMetrics.ideasComposerFilterSpacing
                                )
                        }
                        ForEach(Array(groups.enumerated()), id: \.element.date) { index, group in
                            IdeaDaySectionHeader(group: group)
                                .padding(
                                    .top,
                                    index == 0
                                        ? 0
                                        : NoonmarkVisualMetrics.ideasTimelineSectionSpacing
                                )
                            IdeaCardList(ideas: group.ideas)
                        }
                        if visibleIdeaIDs.isEmpty {
                            IdeaEmptyState()
                        }
                    }
                    .frame(
                        maxWidth: NoonmarkVisualMetrics
                            .ideasReadableTimelineMaximumWidth
                    )
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.timeline",
                            verificationText: "\(visibleIdeaIDs.count)"
                        )
                    }
                }
                .onAppear {
                    revealSelectedIdea(using: proxy)
                }
                .onChange(of: store.selectedIdeaID) {
                    revealSelectedIdea(using: proxy)
                }
            }
        }
    }

    private func revealSelectedIdea(using proxy: ScrollViewProxy) {
        guard let targetID = store.selectedIdeaID,
              visibleIdeaIDs.contains(targetID)
        else {
            return
        }
        DispatchQueue.main.async {
            withAnimation(
                Theme.shouldReduceMotion ? nil : .easeInOut(duration: 0.22)
            ) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }
}

private struct IdeaCollectionContext: View {
    @EnvironmentObject private var store: NoonmarkStore
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(
                store.ideaBrowseMode == .review
                    ? store.copy.ideaReviewContext(count)
                    : store.copy.ideaRecentContext(count)
            )
            .font(.noonmarkSystem(size: 11))
            .foregroundStyle(Theme.text3)
            Spacer()
            if store.ideaBrowseMode == .review {
                Button(store.copy.ideaReviewRefreshAction) {
                    store.refreshIdeaReview()
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("ideas.review.refresh")
            }
        }
        .frame(minHeight: 24)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.collection",
                verificationText: store.ideaBrowseMode == .review
                    ? "review"
                    : "recent"
            )
        }
    }
}

private struct IdeaEmptyState: View {
    @EnvironmentObject private var store: NoonmarkStore

    private var message: String {
        if store.ideaBrowseMode == .review {
            return store.copy.ideaReviewEmptyState
        }
        return store.visibleIdeaCount == 0
            ? store.copy.ideaEmptyState
            : store.copy.ideaFilterEmptyState
    }

    private var verificationText: String {
        if store.ideaBrowseMode == .review {
            return "review-empty"
        }
        return store.visibleIdeaCount == 0 ? "empty" : "no-filter-match"
    }

    var body: some View {
        Text(message)
        .font(.noonmarkSystem(size: 12.5))
        .foregroundStyle(Theme.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.empty",
                verificationText: verificationText
            )
        }
    }
}

private struct IdeaComposer: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var session: IdeaComposerSession

    private var text: Binding<String> {
        Binding(
            get: { session.text },
            set: { session.updateText($0) }
        )
    }

    private var activeToken: NewTaskClassificationToken? {
        store.ideaClassificationToken(for: session.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownEditor(
                text: text,
                placeholder: store.copy.ideaComposerPlaceholder,
                style: .body,
                onCommit: {
                    _ = store.appendIdeaFromComposer()
                },
                nativeAccessibilityIdentifier: "ideas.composer"
            )
            .background(
                RoundedRectangle(
                    cornerRadius: NoonmarkVisualMetrics.ideasComposerCornerRadius
                ).fill(Theme.controlFill)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: NoonmarkVisualMetrics.ideasComposerCornerRadius
                ).stroke(Theme.lineSubtle)
            )
            .background {
                AppE2EViewAnchor(identifier: "ideas.composer.surface")
            }

            if store.shouldShowIdeaClassificationSuggestions(
                for: session.text
            ), let activeToken {
                NewTaskClassificationSuggestionList(
                    tokenKind: activeToken.kind,
                    suggestions: Array(
                        store.ideaClassificationSuggestions(
                            for: session.text
                        ).prefix(6)
                    ),
                    accessibilityIdentifier: "ideas.composer.suggestions"
                ) { suggestion in
                    session.updateText(
                        store.completeIdeaClassificationToken(
                            in: session.text,
                            with: suggestion.name
                        )
                    )
                }
            }

            if let issue = store.ideaDraftIssueMessage(for: session.text) {
                Text(issue)
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warn)
            }
        }
    }
}

private struct IdeaFilterField: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        TextField(
            store.copy.ideaFilterPlaceholder,
            text: $store.ideaFilterText
        )
        .textFieldStyle(.plain)
        .font(.noonmarkSystem(size: 12.5))
        .foregroundStyle(Theme.text1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(Theme.lineSubtle)
        )
        .accessibilityIdentifier("ideas.filter")
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.filter",
                verificationText: store.ideaFilterText
            )
        }
        .onChange(of: store.ideaFilterText) { _, text in
            if text.isEmpty == false {
                store.showRecentIdeas()
            }
        }
    }
}

/// Single quiet indicator for the active classification filter: filter name
/// plus a clear control, one visual unit, no chip or badge.
private struct IdeaClassificationFilterIndicator: View {
    @EnvironmentObject private var store: NoonmarkStore
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Text(store.copy.ideaClassificationFilterIndicator(name))
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
            Button {
                store.clearIdeaClassificationFilter()
            } label: {
                MicroLabel(systemImage: "xmark", color: Theme.text2)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.filter.classification.clear"
                        )
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.copy.clearIdeaClassificationFilterAction)
            .accessibilityIdentifier("ideas.filter.classification.clear")
            Spacer()
        }
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.filter.classification",
                verificationText: name
            )
        }
    }
}

private struct IdeaCardList: View {
    @EnvironmentObject private var store: NoonmarkStore
    let ideas: [IdeaEntry]

    var body: some View {
        ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
            VStack(alignment: .leading, spacing: 0) {
                // SwiftUI caches a Menu's items at first presentation; folding
                // Sticky Note membership into identity refreshes that intent.
                IdeaCardView(
                    idea: idea,
                    editorSession: store.ideaInlineEditorSession
                )
                .id("\(idea.id.description)-sticky:\(idea.pinnedAt != nil)")
                if index < ideas.count - 1 {
                    Divider()
                        .overlay(Theme.lineSubtle)
                        .padding(
                            .leading,
                            NoonmarkVisualMetrics.ideasCardHorizontalPadding
                        )
                }
            }
            .id(idea.id)
        }
    }
}

private struct IdeaDaySectionHeader: View {
    @EnvironmentObject private var store: NoonmarkStore
    let group: IdeaDayGroup

    var body: some View {
        HStack(spacing: 8) {
            Text(store.displayFullDate(group.date))
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("\(group.ideas.count)")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
            Spacer()
        }
        .padding(.bottom, NoonmarkVisualMetrics.ideasSectionHeaderBottomPadding)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.day.\(group.date)",
                verificationText: store.displayFullDate(group.date)
            )
        }
    }
}

private struct IdeaCardView: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry
    @ObservedObject var editorSession: IdeaInlineEditorSession

    private var isEditing: Bool {
        editorSession.ideaID == idea.id
    }

    private var isSelected: Bool {
        store.selectedIdeaID == idea.id
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: NoonmarkVisualMetrics.ideasCardMetadataSpacing
        ) {
            if isEditing {
                editingBody
            } else {
                displayBody
            }
        }
        .padding(.horizontal, NoonmarkVisualMetrics.ideasCardHorizontalPadding)
        .padding(.vertical, NoonmarkVisualMetrics.ideasCardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.controlFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectIdea(idea.id)
        }
        .overlay {
            AppE2EViewAnchor(
                identifier: "ideas.card.\(idea.id)",
                verificationText: idea.body
            )
            .allowsHitTesting(false)
        }
    }

    private var displayBody: some View {
        Group {
            MarkdownText(
                idea.body,
                e2eIdentifier: "ideas.card.markdown.\(idea.id)"
            )
                .font(.noonmarkSystem(size: 13.5, weight: .regular))
                .foregroundStyle(Theme.text1)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    store.selectIdea(idea.id)
                    store.beginIdeaEdit(idea)
                }
                .background {
                    AppE2EViewAnchor(
                        identifier: "ideas.card.body.\(idea.id)",
                        verificationText: idea.body
                    )
                }
            HStack(alignment: .center, spacing: 8) {
                Text(store.displayTime(idea.createdAt) ?? "")
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                IdeaCardClassificationLine(idea: idea)
                Spacer(minLength: 8)
                IdeaCardOverflowMenu(idea: idea)
            }
        }
    }

    private var editingBody: some View {
        Group {
            IdeaEditComposer(
                session: editorSession,
                idea: idea
            )
            if editorSession.saveState == .failed {
                Text(store.copy.ideaEditSaveFailed)
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warn)
            }
            HStack(spacing: 12) {
                TaskNoteTextActionControl(
                    title: store.copy.ideaSaveEditAction,
                    identifier: "ideas.card.edit.save.\(idea.id)",
                    emphasis: .accent
                ) {
                    _ = store.commitIdeaEdit()
                }
                TaskNoteTextActionControl(
                    title: store.copy.ideaCancelEditAction,
                    identifier: "ideas.card.edit.cancel.\(idea.id)",
                    emphasis: .secondary
                ) {
                    store.cancelIdeaEdit()
                }
                Spacer()
            }
        }
    }
}

/// Clickable classification line: each group/label component sets the page
/// classification filter; the active component is shown in accent.
private struct IdeaCardClassificationLine: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry

    private var components: [IdeaClassificationComponent] {
        store.ideaClassificationComponents(for: idea)
    }

    var body: some View {
        if components.isEmpty == false {
            HStack(spacing: 8) {
                ForEach(components, id: \.anchorSuffix) { component in
                    Button {
                        store.selectIdeaClassificationFilter(component)
                    } label: {
                        Text(component.displayName)
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(
                                store.isIdeaClassificationFilterActive(component)
                                    ? Theme.accent
                                    : Theme.text3
                            )
                            .lineLimit(1)
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "ideas.card.filter.\(idea.id).\(component.anchorSuffix)"
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "ideas.card.filter.\(idea.id).\(component.anchorSuffix)"
                    )
                }
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "ideas.card.filter.\(idea.id)",
                    verificationText: store.ideaClassificationLine(for: idea) ?? ""
                )
            }
        }
    }
}

private struct IdeaEditComposer: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var session: IdeaInlineEditorSession
    let idea: IdeaEntry

    private var text: Binding<String> {
        Binding(
            get: { session.draftText },
            set: { session.updateText($0) }
        )
    }

    var body: some View {
        MarkdownEditor(
            text: text,
            placeholder: store.copy.ideaEditPlaceholder,
            style: .body,
            onCommit: {
                _ = store.commitIdeaEdit()
            },
            onEscape: {
                store.cancelIdeaEdit()
            },
            onEndEditing: {
                guard session.ideaID == idea.id else { return }
                _ = store.commitIdeaEdit()
            },
            nativeAccessibilityIdentifier: "ideas.card.edit-field.\(idea.id)",
            focusesOnAppear: true
        )
    }
}

private struct IdeaCardOverflowMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry

    var body: some View {
        Menu {
            Button(
                idea.pinnedAt == nil
                    ? store.copy.addToStickyNotesAction
                    : store.copy.removeFromStickyNotesAction
            ) {
                if idea.pinnedAt == nil {
                    _ = store.addIdeaToStickyNotes(idea.id)
                } else {
                    _ = store.removeIdeaFromStickyNotes(idea.id)
                }
            }
            .accessibilityIdentifier(
                idea.pinnedAt == nil
                    ? "ideas.card.sticky.add.\(idea.id)"
                    : "ideas.card.sticky.remove.\(idea.id)"
            )
            Button(store.copy.editIdeaAction) {
                store.beginIdeaEdit(idea)
            }
            .accessibilityIdentifier("ideas.card.edit.\(idea.id)")
            Button(store.copy.deleteIdeaAction) {
                _ = store.deleteIdea(idea.id)
            }
            .accessibilityIdentifier("ideas.card.delete.\(idea.id)")
        } label: {
            Image(systemName: "ellipsis")
                .font(.noonmarkSystem(size: 12, weight: .medium))
                .foregroundStyle(Theme.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.editingIdeaID != nil)
        .accessibilityLabel(store.copy.ideaActionsAccessibilityLabel)
        .accessibilityIdentifier("ideas.card.menu.\(idea.id)")
        .background {
            AppE2EViewAnchor(identifier: "ideas.card.menu.\(idea.id)")
        }
    }
}

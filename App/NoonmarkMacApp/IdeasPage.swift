import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct IdeasPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var searchIsPresented = false

    private var visibleIdeaIDs: [IdeaID] {
        let pinned = store.ideaBrowseMode == .recent
            ? store.pinnedIdeas.map(\.id)
            : []
        return pinned + store.displayedIdeaGroups.flatMap {
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
            GeometryReader { proxy in
                if proxy.size.width >= NoonmarkVisualMetrics.ideasWideLayoutMinimumWidth {
                    HStack(spacing: 0) {
                        IdeaTimelinePane(
                            searchIsPresented: $searchIsPresented
                        )
                        Divider().overlay(Theme.lineSubtle)
                        IdeaInspector()
                            .frame(
                                width: NoonmarkVisualMetrics
                                    .ideasWideInspectorWidth
                            )
                    }
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.layout",
                            verificationText: "wide"
                        )
                    }
                } else {
                    IdeaTimelinePane(
                        searchIsPresented: $searchIsPresented
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.layout",
                            verificationText: "compact"
                        )
                    }
                }
            }
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
        .onChange(of: store.ideaTrashItems.map(\.id)) { _, ids in
            guard let restoringID = store.restoringIdeaID,
                  ids.contains(restoringID) == false
            else { return }
            store.cancelIdeaRestore()
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

    private var pinnedIdeas: [IdeaEntry] {
        store.ideaBrowseMode == .recent ? store.pinnedIdeas : []
    }

    private var visibleIdeaIDs: [IdeaID] {
        pinnedIdeas.map(\.id) + groups.flatMap { $0.ideas.map(\.id) }
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

            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let filterName = store.activeIdeaClassificationFilterName {
                        IdeaClassificationFilterIndicator(name: filterName)
                            .padding(
                                .bottom,
                                NoonmarkVisualMetrics.ideasComposerFilterSpacing
                            )
                    }
                    if pinnedIdeas.isEmpty == false {
                        IdeaPinnedSectionHeader(count: pinnedIdeas.count)
                        IdeaCardList(ideas: pinnedIdeas)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.date) { index, group in
                        IdeaDaySectionHeader(group: group)
                            .padding(
                                .top,
                                index == 0 && pinnedIdeas.isEmpty
                                    ? 0
                                    : NoonmarkVisualMetrics.ideasTimelineSectionSpacing
                            )
                        IdeaCardList(ideas: group.ideas)
                    }
                    if visibleIdeaIDs.isEmpty {
                        IdeaEmptyState()
                    }
                    if store.ideaBrowseMode == .recent {
                        IdeaTrashSection()
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
        store.newTaskClassificationToken(for: session.text)
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

            if store.shouldShowNewTaskClassificationSuggestions(
                for: session.text
            ), let activeToken {
                NewTaskClassificationSuggestionList(
                    tokenKind: activeToken.kind,
                    suggestions: Array(
                        store.newTaskClassificationSuggestions(
                            for: session.text
                        ).prefix(6)
                    ),
                    accessibilityIdentifier: "ideas.composer.suggestions"
                ) { suggestion in
                    session.updateText(
                        store.completeNewTaskClassificationToken(
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

private struct IdeaInspector: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ScrollView {
            if let idea = store.selectedIdea {
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.copy.ideaInspectorTitle)
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .tracking(0.6)
                    MarkdownInlineText(idea.body)
                        .font(.noonmarkSystem(size: 14.5, weight: .regular))
                        .foregroundStyle(Theme.text1)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)

                    IdeaInspectorSection(
                        title: store.copy.ideaInspectorRecordedAt
                    ) {
                        Text(store.displayDateTime(idea.createdAt))
                    }

                    if let classification = store.ideaClassificationLine(
                        for: idea
                    ) {
                        IdeaInspectorSection(
                            title: store.copy.ideaInspectorClassification
                        ) {
                            Text(classification)
                        }
                    }

                    IdeaInspectorSection(
                        title: store.copy.ideaInspectorActions
                    ) {
                        HStack(spacing: 12) {
                            Button(store.copy.editIdeaAction) {
                                store.beginIdeaEdit(idea)
                            }
                            Button(
                                idea.pinnedAt == nil
                                    ? store.copy.pinIdeaAction
                                    : store.copy.unpinIdeaAction
                            ) {
                                if idea.pinnedAt == nil {
                                    _ = store.pinIdea(idea.id)
                                } else {
                                    _ = store.unpinIdea(idea.id)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
                .padding(24)
                .background {
                    AppE2EViewAnchor(
                        identifier: "ideas.inspector.idea.\(idea.id)",
                        verificationText: idea.body
                    )
                }
            } else {
                Text(store.copy.ideaInspectorEmptyState)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel2)
        .background {
            AppE2EViewAnchor(identifier: "ideas.inspector")
        }
    }
}

private struct IdeaInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
            content
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Divider().overlay(Theme.lineSubtle)
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

/// Pinned ideas float above the day-grouped timeline; the header reuses the
/// day-section typography so position and weight, not badges, distinguish it.
private struct IdeaPinnedSectionHeader: View {
    @EnvironmentObject private var store: NoonmarkStore
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(store.copy.ideasPinnedSectionTitle)
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text2)
            Text("\(count)")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
            Spacer()
        }
        .padding(.bottom, NoonmarkVisualMetrics.ideasSectionHeaderBottomPadding)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.pinned",
                verificationText: "\(count)"
            )
        }
    }
}

private struct IdeaCardList: View {
    @EnvironmentObject private var store: NoonmarkStore
    let ideas: [IdeaEntry]

    var body: some View {
        ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
            // SwiftUI caches a Menu's items at first presentation; folding
            // the pin state into the card identity recreates the card (and
            // its overflow menu) so the reopened menu offers unpin.
            IdeaCardView(
                idea: idea,
                editorSession: store.ideaInlineEditorSession
            )
                .id("\(idea.id.description)-pinned:\(idea.pinnedAt != nil)")
            if index < ideas.count - 1 {
                Divider()
                    .overlay(Theme.lineSubtle)
                    .padding(.leading, NoonmarkVisualMetrics.ideasCardHorizontalPadding)
            }
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
            MarkdownInlineText(idea.body)
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
                    ? store.copy.pinIdeaAction
                    : store.copy.unpinIdeaAction
            ) {
                if idea.pinnedAt == nil {
                    _ = store.pinIdea(idea.id)
                } else {
                    _ = store.unpinIdea(idea.id)
                }
            }
            .accessibilityIdentifier(
                idea.pinnedAt == nil
                    ? "ideas.card.pin.\(idea.id)"
                    : "ideas.card.unpin.\(idea.id)"
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

/// Collapsed-by-default trash section at the bottom of the page. Tombstones
/// retain no body, so rows show the deletion timestamp and restore asks the
/// user to retype the content before committing.
private struct IdeaTrashSection: View {
    @EnvironmentObject private var store: NoonmarkStore

    private var items: [IdeaEntry] {
        store.ideaTrashItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(store.copy.ideasTrashSectionTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Text("\(items.count)")
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                Spacer()
                Button {
                    store.isIdeaTrashExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            store.isIdeaTrashExpanded
                                ? store.copy.collapseIdeasTrash
                                : store.copy.expandIdeasTrash
                        )
                        Image(
                            systemName: store.isIdeaTrashExpanded
                                ? "chevron.up"
                                : "chevron.down"
                        )
                        .font(.noonmarkSystem(size: 8, weight: .semibold))
                    }
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .contentShape(Rectangle())
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.trash.toggle",
                            verificationText: store.isIdeaTrashExpanded
                                ? "expanded"
                                : "collapsed"
                        )
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    store.isIdeaTrashExpanded
                        ? store.copy.collapseIdeasTrash
                        : store.copy.expandIdeasTrash
                )
                .accessibilityIdentifier("ideas.trash.toggle.ax")
            }
            .padding(.bottom, NoonmarkVisualMetrics.ideasSectionHeaderBottomPadding)

            if store.isIdeaTrashExpanded {
                if items.isEmpty {
                    Text(store.copy.ideasTrashEmptyState)
                        .font(.noonmarkSystem(size: 12.5))
                        .foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, idea in
                        IdeaTrashRow(idea: idea)
                        if index < items.count - 1 {
                            Divider()
                                .overlay(Theme.lineSubtle)
                                .padding(.leading, NoonmarkVisualMetrics.ideasCardHorizontalPadding)
                        }
                    }
                }
            }
        }
        .padding(.top, NoonmarkVisualMetrics.ideasTimelineSectionSpacing)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.trash",
                verificationText: "\(items.count)"
            )
        }
    }
}

private struct IdeaTrashRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry

    private var isRestoring: Bool {
        store.restoringIdeaID == idea.id
    }

    private var restoreBodyIsEmpty: Bool {
        store.ideaRestoreText.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        Group {
            if isRestoring {
                VStack(
                    alignment: .leading,
                    spacing: NoonmarkVisualMetrics.ideasCardMetadataSpacing
                ) {
                    IdeaRestoreComposer(
                        draft: store.ideaRestoreTextDraft,
                        idea: idea
                    )
                    HStack(spacing: 12) {
                        TaskNoteTextActionControl(
                            title: store.copy.restoreIdeaAction,
                            identifier: "ideas.trash.restore.save.\(idea.id)",
                            emphasis: .accent,
                            isEnabled: restoreBodyIsEmpty == false
                        ) {
                            _ = store.commitIdeaRestore()
                        }
                        TaskNoteTextActionControl(
                            title: store.copy.ideaCancelEditAction,
                            identifier: "ideas.trash.restore.cancel.\(idea.id)",
                            emphasis: .secondary
                        ) {
                            store.cancelIdeaRestore()
                        }
                        Spacer()
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(
                        store.copy.ideaTrashDeletionLabel(
                            store.displayDateTime(idea.deletedAt ?? idea.updatedAt)
                        )
                    )
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(store.copy.restoreIdeaAction) {
                        store.beginIdeaRestore(idea)
                    }
                    .buttonStyle(.plain)
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("ideas.trash.restore.\(idea.id)")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "ideas.trash.restore.\(idea.id)"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, NoonmarkVisualMetrics.ideasCardHorizontalPadding)
        .padding(.vertical, NoonmarkVisualMetrics.ideasCardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            AppE2EViewAnchor(
                identifier: "ideas.trash.item.\(idea.id)",
                verificationText: isRestoring ? "restoring" : "deleted"
            )
        }
    }
}

private struct IdeaRestoreComposer: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var draft: NoonmarkTextInputDraft
    let idea: IdeaEntry

    var body: some View {
        MarkdownEditor(
            text: $draft.text,
            placeholder: store.copy.ideaRestorePlaceholder,
            style: .body,
            onCommit: {
                _ = store.commitIdeaRestore()
            },
            onEscape: {
                store.cancelIdeaRestore()
            },
            nativeAccessibilityIdentifier: "ideas.trash.restore.field.\(idea.id)",
            focusesOnAppear: true
        )
    }
}

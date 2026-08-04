import NoonmarkCore
import SwiftUI

/// Local presentation preference only. Sticky Note membership lives on the
/// Flylight source entry and is deliberately independent of these layouts.
enum StickyNotePresentationMode: String, CaseIterable, Identifiable {
    case stream
    case wall

    var id: String { rawValue }
}

struct StickyNotesPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @AppStorage("noonmark.sticky-note.presentation-mode")
    private var presentationMode = StickyNotePresentationMode.stream

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePageHeader(
                title: store.copy.navStickyNotes,
                subtitle: store.copy.stickyNotesSubtitle
            ) {
                StickyNotePresentationControl(selection: $presentationMode)
                .background {
                    AppE2EViewAnchor(
                        identifier: "sticky-notes.mode",
                        verificationText: presentationMode.rawValue
                    )
                }
            }

            if store.stickyNoteIdeas.isEmpty {
                StickyNotesEmptyState()
            } else {
                ScrollView {
                    presentation
                        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                        .padding(.top, 6)
                        .padding(.bottom, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .background {
            AppE2EViewAnchor(
                identifier: "sticky-notes.page",
                verificationText: "\(store.stickyNoteIdeas.count)"
            )
        }
    }

    @ViewBuilder
    private var presentation: some View {
        switch presentationMode {
        case .stream:
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.stickyNoteIdeas.enumerated()), id: \.element.id) { index, idea in
                    StickyNoteItemView(idea: idea, mode: .stream)
                    if index < store.stickyNoteIdeas.count - 1 {
                        Divider().overlay(Theme.lineSubtle)
                    }
                }
            }
            .frame(maxWidth: NoonmarkVisualMetrics.ideasReadableTimelineMaximumWidth)
            .frame(maxWidth: .infinity)
            .background {
                AppE2EViewAnchor(
                    identifier: "sticky-notes.presentation",
                    verificationText: StickyNotePresentationMode.stream.rawValue
                )
            }
        case .wall:
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 230, maximum: 340),
                        spacing: 16,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(store.stickyNoteIdeas) { idea in
                    StickyNoteItemView(idea: idea, mode: .wall)
                }
            }
            .background {
                AppE2EViewAnchor(
                    identifier: "sticky-notes.presentation",
                    verificationText: StickyNotePresentationMode.wall.rawValue
                )
            }
        }
    }
}

/// Stable, app-owned hit targets avoid relying on AppKit's transient Picker
/// label hierarchy. This also leaves the visual treatment replaceable without
/// changing the presentation preference or automation contract.
private struct StickyNotePresentationControl: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var selection: StickyNotePresentationMode

    var body: some View {
        HStack(spacing: 2) {
            modeButton(
                .stream,
                title: store.copy.stickyNoteStreamMode,
                systemImage: "list.bullet"
            )
            modeButton(
                .wall,
                title: store.copy.stickyNoteWallMode,
                systemImage: "rectangle.grid.2x2"
            )
        }
        .padding(2)
        .frame(width: 188, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Theme.chip)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.copy.stickyNotePresentationMode)
        .accessibilityIdentifier("sticky-notes.mode")
    }

    private func modeButton(
        _ mode: StickyNotePresentationMode,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            selection = mode
        } label: {
            Label(title, systemImage: systemImage)
                .font(.noonmarkSystem(size: 10.5, weight: .medium))
                .foregroundStyle(selection == mode ? Theme.text1 : Theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selection == mode ? Theme.panel : Color.clear)
                .shadow(
                    color: selection == mode ? Theme.shadowSubtle : .clear,
                    radius: 2,
                    y: 1
                )
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
        .accessibilityIdentifier("sticky-notes.mode.\(mode.rawValue)")
        .background {
            AppE2EViewAnchor(
                identifier: "sticky-notes.mode.\(mode.rawValue)"
            )
        }
    }
}

private struct StickyNotesEmptyState: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.copy.stickyNotesEmptyState)
                .font(.noonmarkSystem(size: 13))
                .foregroundStyle(Theme.text3)
            Button(store.copy.openInFlylightAction) {
                store.selectPage(.ideas)
            }
            .buttonStyle(.plain)
            .font(.noonmarkSystem(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.top, 42)
        .background {
            AppE2EViewAnchor(identifier: "sticky-notes.empty")
        }
    }
}

/// Shared content and intent layer for every Sticky Note presentation. A
/// future paper, stack, board, or spatial view can supply another surface
/// without forking content rendering or Flylight mutations.
private struct StickyNoteItemView: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry
    let mode: StickyNotePresentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MarkdownText(
                idea.body,
                e2eIdentifier: "sticky-notes.markdown.\(idea.id)"
            )
            .font(.noonmarkSystem(size: mode == .wall ? 14 : 13.5))
            .foregroundStyle(Theme.text1)
            .lineSpacing(mode == .wall ? 4 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 8) {
                Text(store.displayDateTime(idea.createdAt))
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                    .lineLimit(1)
                if let classification = store.ideaClassificationLine(for: idea) {
                    Text(classification)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                StickyNoteItemMenu(idea: idea)
            }
        }
        .padding(mode == .wall ? 18 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if mode == .wall {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.noteBackground)
                    .shadow(color: Theme.shadowSubtle, radius: 6, y: 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.lineSubtle)
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.openIdeaInFlylight(idea.id)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "sticky-notes.item.\(idea.id)",
                verificationText: idea.body
            )
        }
    }
}

private struct StickyNoteItemMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let idea: IdeaEntry

    var body: some View {
        Menu {
            Button(store.copy.openInFlylightAction) {
                store.openIdeaInFlylight(idea.id)
            }
            .accessibilityIdentifier("sticky-notes.open.\(idea.id)")
            Button(store.copy.removeFromStickyNotesAction) {
                _ = store.removeIdeaFromStickyNotes(idea.id)
            }
            .accessibilityIdentifier("sticky-notes.remove.\(idea.id)")
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
        .accessibilityLabel(store.copy.ideaActionsAccessibilityLabel)
        .accessibilityIdentifier("sticky-notes.menu.\(idea.id)")
        .background {
            AppE2EViewAnchor(identifier: "sticky-notes.menu.\(idea.id)")
        }
    }
}

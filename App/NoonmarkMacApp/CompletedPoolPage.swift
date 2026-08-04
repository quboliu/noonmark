import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct CompletedPoolPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .completed)
        )
    }

    var hierarchies: [CompletedTaskHierarchy] {
        store.engine.completedTaskHierarchies()
    }

    private var hierarchiesByID: [String: CompletedTaskHierarchy] {
        Dictionary(
            uniqueKeysWithValues: hierarchies.map {
                ($0.chain.id.description, $0)
            }
        )
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let rows = hierarchies.map { hierarchy in
            return TaskCollectionPresentationItem(
                id: hierarchy.chain.id.description,
                title: store.copy.displayTaskTitle(
                    hierarchy.definition.title
                ),
                time: hierarchy.latestCompletionAt,
                category: store.currentClassification(
                    for: hierarchy.chain.id
                )?.category?.taskCollectionCategoryPresentation
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: rows,
            preference: presentationPreference,
            ungroupedTitle: store.copy.ungrouped
        )
    }

    private var hierarchyProjectionVerificationText: String {
        hierarchies.filter {
            $0.chain.cycleMembership == nil
        }.map { hierarchy in
            let parentState =
                hierarchy.parentCompletion == nil
                    ? "open"
                    : "completed"
            let expansionState =
                store.collapsedCompletedHierarchyIDs.contains(
                    hierarchy.chain.id
                )
                    ? "collapsed"
                    : "expanded"
            let childState =
                hierarchy.parentCompletion == nil
                    ? "checked"
                    : "quiet"
            let children = hierarchy.completedChildren.map {
                "\($0.subtask.id.description):\(childState)"
            }.sorted().joined(separator: ",")
            return [
                hierarchy.chain.id.description,
                parentState,
                expansionState,
                children
            ].joined(separator: "|")
        }.sorted().joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePageHeader(title: store.copy.navCompleted, subtitle: store.copy.completedSubtitle) {
                TaskCollectionPresentationMenu(
                    copy: store.copy,
                    accessibilityIdentifier: "task-collection-view.completed",
                    preference: $presentationPreference
                )
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentationSections, id: \.id) { section in
                        if presentationPreference.organization == .grouped {
                            TaskCollectionSectionHeader(section: section, count: section.items.count)
                        }
                        ForEach(section.items, id: \.id) { row in
                            if let hierarchy = hierarchiesByID[row.id] {
                                CompletedTaskHierarchyRows(
                                    hierarchy: hierarchy
                                )
                            }
                        }
                    }
                    if hierarchies.isEmpty {
                        EmptyState(kind: .completedPool, text: store.copy.emptyCompleted)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .taskCollectionCategoryVisibility(presentationPreference)
        .onChange(of: presentationPreference) { _, preference in
            presentationRepository.save(preference, for: .completed)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "completed.hierarchy-projection",
                verificationText: hierarchyProjectionVerificationText
            )
        }
    }
}

struct CompletedTaskHierarchyRows: View {
    @EnvironmentObject private var store: NoonmarkStore
    let hierarchy: CompletedTaskHierarchy

    private var childrenExpanded: Bool {
        store.collapsedCompletedHierarchyIDs.contains(
            hierarchy.chain.id
        ) == false
    }

    var body: some View {
        VStack(spacing: 0) {
            CompletedTaskHierarchyParentRow(
                hierarchy: hierarchy,
                childrenExpanded: childrenExpanded
            )
            if childrenExpanded {
                ForEach(hierarchy.completedChildren, id: \.subtask.id) {
                    record in
                    CompletedTaskHierarchyChildRow(
                        record: record,
                        parentIsCompleted:
                        hierarchy.parentCompletion != nil
                    )
                }
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier:
                "completed.hierarchy.\(hierarchy.chain.id.description)",
                verificationText:
                [
                    hierarchy.parentCompletion == nil
                        ? "open"
                        : "completed",
                    "\(hierarchy.completedChildren.count)",
                    childrenExpanded ? "expanded" : "collapsed"
                ].joined(separator: ",")
            )
        }
    }
}

struct CompletedTaskHierarchyParentRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let hierarchy: CompletedTaskHierarchy
    let childrenExpanded: Bool

    private var selection: NoonmarkStore.WorkspaceSelectionItem? {
        store.completedHierarchyParentSelection(hierarchy)
    }

    var body: some View {
        if let item = hierarchy.parentCompletion {
            parentContent
                .listRowSurface(
                    selected: store.isWorkspaceItemSelected(
                        .completedTrace(item.trace.id)
                    ),
                    tint: Theme.accent,
                    separatorLeadingInset: 40
                )
                .workspaceSelectable(.completedTrace(item.trace.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    store.userSelectCompleted(item.trace.id)
                }
                .contextMenu {
                    CompletedTaskContextMenu(item: item)
                }
        } else if let selection {
            parentContent
                .listRowSurface(
                    selected: store.isWorkspaceItemSelected(selection),
                    tint: Theme.accent,
                    separatorLeadingInset: 40
                )
                .workspaceSelectable(selection)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.userSelectWorkspaceItem(selection)
                }
        } else {
            parentContent
                .listRowSurface(
                    selected: false,
                    tint: Theme.accent,
                    separatorLeadingInset: 40
                )
        }
    }

    private var parentContent: some View {
        let completedItem = hierarchy.parentCompletion
        let accessibilityInstanceID =
            completedItem?.trace.id.description
                ?? hierarchy.chain.id.description
        let trajectoryNodes = completedItem?.trajectory.traces.map(
            CompletedTrajectoryNode.init(trace:)
        ) ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(
                    status: completedItem == nil
                        ? .pending
                        : .completed
                )
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(
                        store.copy.displayTaskTitle(
                            hierarchy.definition.title
                        )
                    )
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .foregroundStyle(
                            completedItem == nil
                                ? Theme.text1
                                : Theme.text3
                        )
                        .strikethrough(completedItem != nil)
                        .lineLimit(1)
                    if let classification =
                        store.displayableClassification(
                            for: hierarchy.chain.id
                        )
                    {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: hierarchy.definition.title,
                            accessibilityNamespace:
                            TaskClassificationAccessibilityNamespace(
                                surface: "completed-row",
                                instanceID: accessibilityInstanceID
                            )
                        )
                        .padding(.top, 4)
                    }
                    AutomaticTaskClassificationStatusView(
                        chainID: hierarchy.chain.id,
                        taskTitle: hierarchy.definition.title,
                        accessibilitySurface: .completedRow,
                        accessibilityInstanceID:
                        accessibilityInstanceID
                    )
                    .padding(.top, 3)
                }
                .background {
                    AppE2EViewAnchor(
                        identifier: "completed.hierarchy.parent-select.\(hierarchy.chain.id.description)",
                        verificationText: hierarchy.parentCompletion == nil ? "open" : "completed"
                    )
                }
                if hierarchy.completedChildren.isEmpty == false {
                    Button {
                        store.toggleCompletedHierarchyChildren(
                            hierarchy
                        )
                    } label: {
                        SubtaskDisclosureLabel(
                            count: hierarchy.completedChildren.count,
                            expanded: childrenExpanded
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        store.copy.subtaskDisclosureAccessibilityLabel(
                            count: hierarchy.completedChildren.count,
                            expanded: childrenExpanded
                        )
                    )
                    .accessibilityIdentifier(
                        "completed.hierarchy.disclosure.\(hierarchy.chain.id.description)"
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "completed.hierarchy.disclosure.\(hierarchy.chain.id.description)",
                            verificationText:
                            childrenExpanded
                                ? "expanded"
                                : "collapsed"
                        )
                    }
                }
                Spacer()
                if let completedItem {
                    CompletionMomentText(
                        date: store.displayDate(
                            completedItem.trace.date
                        ),
                        time: store.displayTime(
                            completedItem.trace.completedAt
                        )
                    )
                }
            }
            if trajectoryNodes.count
                >= MacUICompletedPoolRowLayout
                .minimumVisibleTrajectoryNodeCount
            {
                CompletedTrajectoryNodes(nodes: trajectoryNodes)
                    .padding(.leading, 28)
            }
        }
        .frame(minHeight: 52, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .background {
            AppE2EViewAnchor(
                identifier:
                "completed.hierarchy.parent.\(hierarchy.chain.id.description)",
                verificationText:
                hierarchy.parentCompletion == nil
                    ? "open"
                    : "completed"
            )
        }
    }
}

struct CompletedTaskHierarchyChildRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord
    let parentIsCompleted: Bool

    var body: some View {
        let selection = NoonmarkStore.WorkspaceSelectionItem
            .completedSubtask(record.subtask.id)
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 28, height: 1)
                .accessibilityHidden(true)
            if parentIsCompleted {
                Text("–")
                    .font(
                        .noonmarkSystem(
                            size: 12,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(Theme.text3)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                StatusGlyph(status: .completed)
            }
            MarkdownInlineText(record.subtask.title)
                .font(.noonmarkSystem(size: 12.5, weight: .medium))
                .foregroundStyle(
                    parentIsCompleted
                        ? Theme.text2
                        : Theme.text1
                )
                .lineLimit(1)
            Spacer(minLength: 8)
            CompletionMomentText(
                date: store.displayDate(record.date),
                time: store.displayTime(record.subtask.completedAt)
            )
        }
        .frame(minHeight: 40, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .listRowSurface(
            selected: store.isWorkspaceItemSelected(selection),
            tint: Theme.accent,
            separatorLeadingInset: 70
        )
        .workspaceSelectable(selection)
        .contentShape(Rectangle())
        .onTapGesture {
            store.userSelectCompletedSubtask(record.subtask.id)
        }
        .contextMenu {
            CompletedSubtaskContextMenu(record: record)
        }
        .background {
            AppE2EViewAnchor(
                identifier:
                "completed.hierarchy.child.\(record.subtask.id.description)",
                verificationText:
                parentIsCompleted
                    ? "quiet"
                    : "checked"
            )
        }
    }
}

struct CompletedTaskContextMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

    var body: some View {
        Button(store.copy.openDay) {
            store.selectedDate = item.trace.date
            store.page = .day
            store.selectTrace(item.trace.id)
        }
        Button(store.copy.copyAsNewTask) {
            store.copyAsNewTask(item.trace.id)
        }
        TaskCycleConversionMenuSection(
            chainID: item.trace.chainID,
            traceID: item.trace.id,
            accessibilityIdentifier:
            "task-cycle-conversion.completed.\(item.trace.chainID.description)"
        )
    }
}

struct CompletedSubtaskContextMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord

    var body: some View {
        Button(store.copy.openDay) {
            store.selectedDate = record.date
            store.page = .day
            store.selectTrace(record.parentTrace.id)
        }
        Button(store.copy.copyParentAsNewTask) {
            store.copyAsNewTask(record.parentTrace.id)
        }
    }
}

struct CompletionKindPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

struct CompletionMomentText: View {
    let date: String
    let time: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(date)
            if let time {
                Text(time)
            }
        }
        .font(.noonmarkSystem(size: 11))
        .foregroundStyle(Theme.text3)
        .monospacedDigit()
        .lineLimit(1)
    }
}

struct CompletedTrajectoryNode: Identifiable {
    let id: String
    let date: LocalDate
    let status: TraceStatus

    init(trace: DayTrace) {
        id = trace.id.rawValue.uuidString
        date = trace.date
        status = trace.status
    }

    init(subtask: Subtask, date: LocalDate) {
        id = subtask.id.rawValue.uuidString
        self.date = date
        status = .completed
    }
}

struct CompletedTrajectoryNodes: View {
    @EnvironmentObject private var store: NoonmarkStore
    let nodes: [CompletedTrajectoryNode]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.noonmarkSystem(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 14)
                }
                HStack(spacing: 4) {
                    StatusDot(status: node.status, size: 4)
                    Text(store.displayDate(node.date))
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                    Text(store.copy.traceStatusLabel(node.status))
                        .font(.noonmarkSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(node.status.uiStyle.foreground)
                }
                .padding(.trailing, 2)
            }
        }
    }
}

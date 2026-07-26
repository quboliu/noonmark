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

    var cycleTracks: [TaskCycleTrack] {
        store.engine.taskCycleTracks(
            today: store.today,
            collection: .completed
        )
    }

    var items: [CompletedPoolItem] {
        store.standaloneCollectionItems(
            store.engine.completedPool(),
            chainID: \.trace.chainID
        )
    }

    var subtaskRecords: [CompletedSubtaskRecord] { store.engine.completedSubtaskRecords() }

    private var entries: [CompletedCollectionEntry] {
        items.map(CompletedCollectionEntry.task) + subtaskRecords.map(CompletedCollectionEntry.subtask)
    }

    private var entriesByID: [String: CompletedCollectionEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let rows = entries.map { entry in
            let title = switch entry {
            case let .task(item):
                store.copy.displayTaskTitle(item.definition.title)
            case .subtask:
                entry.title
            }
            return TaskCollectionPresentationItem(
                id: entry.id,
                title: title,
                time: entry.completedAt,
                category: historicalCategory(for: entry.classificationTrace)
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: rows,
            preference: presentationPreference,
            ungroupedTitle: store.copy.ungrouped
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navCompleted, subtitle: store.copy.completedSubtitle) {
                TaskCollectionPresentationMenu(
                    copy: store.copy,
                    accessibilityIdentifier: "task-collection-view.completed",
                    preference: $presentationPreference
                )
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TaskCycleSection(
                        tracks: cycleTracks,
                        collection: .completed
                    )
                    ForEach(presentationSections, id: \.id) { section in
                        if presentationPreference.organization == .grouped {
                            TaskCollectionSectionHeader(section: section, count: section.items.count)
                        }
                        ForEach(section.items, id: \.id) { row in
                            if let entry = entriesByID[row.id] {
                                switch entry {
                                case let .task(item):
                                    CompletedRow(item: item)
                                case let .subtask(record):
                                    CompletedSubtaskRow(record: record)
                                }
                            }
                        }
                    }
                    if items.isEmpty && subtaskRecords.isEmpty
                        && cycleTracks.isEmpty
                    {
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
    }

    private func historicalCategory(
        for trace: DayTrace
    ) -> TaskCollectionCategoryPresentation? {
        if case let .history(projection) = try? store.engine.classification(.history(trace.id)),
           let category = projection.category
        {
            let catalogCategory = store.classificationCatalog()?.categories.first {
                $0.id == category.id
            }
            return TaskCollectionCategoryPresentation(
                id: category.id,
                name: category.name,
                colorHex: catalogCategory?.colorHex ?? category.colorHex,
                approval: catalogCategory?.presentationApproval == .userApproved
                    ? .userApproved
                    : .pendingAIReview
            )
        }
        return nil
    }
}

private enum CompletedCollectionEntry {
    case task(CompletedPoolItem)
    case subtask(CompletedSubtaskRecord)

    var id: String {
        switch self {
        case let .task(item): "task:\(item.trace.id.description)"
        case let .subtask(record): "subtask:\(record.subtask.id.description)"
        }
    }

    var title: String {
        switch self {
        case let .task(item): item.definition.title
        case let .subtask(record): record.subtask.title
        }
    }

    var completedAt: Date {
        switch self {
        case let .task(item): item.trace.completedAt ?? item.trace.createdAt
        case let .subtask(record): record.subtask.completedAt ?? record.subtask.updatedAt
        }
    }

    var classificationTrace: DayTrace {
        switch self {
        case let .task(item): item.trace
        case let .subtask(record): record.parentTrace
        }
    }
}

struct CompletedRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

    var body: some View {
        let isSelected = store.isWorkspaceItemSelected(.completedTrace(item.trace.id))
        let trajectoryNodes = item.trajectory.traces.map(
            CompletedTrajectoryNode.init(trace:)
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(store.copy.displayTaskTitle(item.definition.title))
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let classification = store.displayableClassification(for: item.trace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: item.definition.title,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "completed-row",
                                instanceID: item.trace.id.description
                            )
                        )
                        .padding(.top, 4)
                    }
                    AutomaticTaskClassificationStatusView(
                        chainID: item.trace.chainID,
                        taskTitle: item.definition.title,
                        accessibilitySurface: .completedRow,
                        accessibilityInstanceID: item.trace.id.description
                    )
                    .padding(.top, 3)
                }
                Spacer()
                CompletionMomentText(
                    date: store.displayDate(item.trace.date),
                    time: store.displayTime(item.trace.completedAt)
                )
            }
            if trajectoryNodes.count >= MacUICompletedPoolRowLayout.minimumVisibleTrajectoryNodeCount {
                CompletedTrajectoryNodes(nodes: trajectoryNodes)
                    .padding(.leading, 28)
            }
        }
        .frame(minHeight: 52, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .workspaceSelectable(.completedTrace(item.trace.id))
        .onTapGesture { store.userSelectCompleted(item.trace.id) }
        .contextMenu {
            CompletedTaskContextMenu(item: item)
        }
    }
}

struct CompletedSubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let record: CompletedSubtaskRecord

    var body: some View {
        let isSelected = store.isWorkspaceItemSelected(.completedSubtask(record.subtask.id))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 1) {
                    MarkdownInlineText(record.subtask.title)
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(
                        store.copy.belongsToTask(
                            store.copy.displayTaskTitle(record.parentDefinition.title)
                        )
                    )
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    if let classification = store.displayableClassification(for: record.parentTrace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: record.parentDefinition.title,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "completed-subtask-row",
                                instanceID: record.subtask.id.description
                            )
                        )
                        .padding(.top, 4)
                    }
                    AutomaticTaskClassificationStatusView(
                        chainID: record.parentTrace.chainID,
                        taskTitle: record.parentDefinition.title,
                        accessibilitySurface: .completedSubtaskRow,
                        accessibilityInstanceID: record.subtask.id.description
                    )
                    .padding(.top, 3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    CompletionKindPill(
                        text: store.copy.subtask,
                        color: Theme.accent
                    )
                    CompletionMomentText(
                        date: store.displayDate(record.date),
                        time: store.displayTime(record.subtask.completedAt)
                    )
                }
            }
        }
        .frame(minHeight: 66, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: isSelected, tint: Theme.accent, separatorLeadingInset: 40)
        .workspaceSelectable(.completedSubtask(record.subtask.id))
        .onTapGesture { store.userSelectCompletedSubtask(record.subtask.id) }
        .contextMenu {
            CompletedSubtaskContextMenu(record: record)
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
        if store.engine.chains[
            item.trace.chainID
        ]?.cycleMembership == nil {
            Divider()
            Button(store.copy.convertToRecurringTask) {
                store.beginTaskCycleConversion(
                    chainID: item.trace.chainID,
                    traceID: item.trace.id
                )
            }
        }
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

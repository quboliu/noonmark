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
    var items: [CompletedPoolItem] { store.engine.completedPool() }
    var subtaskRecords: [CompletedSubtaskRecord] { store.engine.completedSubtaskRecords() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: store.copy.navCompleted, subtitle: store.copy.completedSubtitle)
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedDates, id: \.self) { date in
                        let dayItems = items.filter { $0.trace.date == date }
                        let daySubtasks = subtaskRecords.filter { $0.date == date }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Text(groupTitle(for: date))
                                    .font(.noonmarkSystem(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                            }
                            .padding(.top, 2)
                            .padding(.bottom, 4)

                            ForEach(dayItems, id: \.trace.id) { item in
                                CompletedRow(item: item)
                            }
                            ForEach(daySubtasks, id: \.subtask.id) { record in
                                CompletedSubtaskRow(record: record)
                            }
                        }
                    }
                    if items.isEmpty && subtaskRecords.isEmpty {
                        EmptyState(kind: .completedPool, text: store.copy.emptyCompleted)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }

    var groupedDates: [LocalDate] {
        Array(Set(items.map { $0.trace.date } + subtaskRecords.map(\.date))).sorted(by: >)
    }

    func groupTitle(for date: LocalDate) -> String {
        let suffix = date == store.today ? " · \(store.copy.today)" : ""
        return "\(store.displayDate(date)) \(store.weekday(date))\(suffix)"
    }
}

struct CompletedRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: CompletedPoolItem

    var body: some View {
        let isSelected = store.isWorkspaceItemSelected(.completedTrace(item.trace.id))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusGlyph(status: .completed)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(item.definition.title)
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
                CompletionTimeText(time: store.displayTime(item.trace.completedAt))
            }
            CompletedTrajectoryNodes(nodes: item.trajectory.traces.map(CompletedTrajectoryNode.init(trace:)))
                .padding(.leading, 28)
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
                    Text(store.copy.belongsToTask(record.parentDefinition.title))
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
                CompletionKindPill(text: store.copy.subtask, color: Theme.accent)
            }
            CompletedTrajectoryNodes(nodes: [CompletedTrajectoryNode(subtask: record.subtask, date: record.date)])
                .padding(.leading, 28)
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

struct CompletionTimeText: View {
    let time: String?

    var body: some View {
        if let time {
            Text(time)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
    }
}

struct CompletedTrajectoryNode: Identifiable {
    let id: String
    let date: LocalDate
    let glyph: String
    let foreground: Color
    let background: Color

    init(trace: DayTrace) {
        id = trace.id.rawValue.uuidString
        date = trace.date
        glyph = trace.status.uiStyle.glyph.isEmpty ? "•" : trace.status.uiStyle.glyph
        foreground = trace.status == .completed ? .white : trace.status.uiStyle.glyphForeground
        background = trace.status == .completed ? Theme.ok : trace.status.uiStyle.glyphBackground
    }

    init(subtask: Subtask, date: LocalDate) {
        id = subtask.id.rawValue.uuidString
        self.date = date
        glyph = "✓"
        foreground = .white
        background = Theme.ok
    }
}

struct CompletedTrajectoryNodes: View {
    @EnvironmentObject private var store: NoonmarkStore
    let nodes: [CompletedTrajectoryNode]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.line2)
                        .frame(width: 14, height: 1.5)
                }
                HStack(spacing: 4) {
                    Text(node.glyph)
                        .font(.noonmarkSystem(size: 9, weight: .bold))
                        .foregroundStyle(node.foreground)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(node.background))
                    Text(store.displayDate(node.date))
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.trailing, 2)
            }
        }
    }
}

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

struct PoolTaskContextMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask
    let surface: String

    private var accessibilityPrefix: String {
        "pool.context.\(surface).\(task.chain.id.description)"
    }

    var body: some View {
        Button(store.copy.scheduleToday) {
            store.schedulePoolTask(task.chain.id, date: store.today)
        }
        .accessibilityIdentifier("\(accessibilityPrefix).schedule-today")
        Button(store.copy.scheduleTomorrow) {
            store.schedulePoolTask(
                task.chain.id,
                date: NoonmarkStore.offset(store.today, by: 1)
            )
        }
        .accessibilityIdentifier("\(accessibilityPrefix).schedule-tomorrow")
        Button(store.copy.chooseScheduleDate) {
            store.showingPicker = .schedulePool(task.chain.id)
        }
        .accessibilityIdentifier("\(accessibilityPrefix).schedule-date")
        Divider()
        Button(store.copy.deleteTask, role: .destructive) {
            store.deletePoolTask(task.chain.id)
        }
        .accessibilityIdentifier("\(accessibilityPrefix).delete")
    }
}

struct TaskPoolPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var quickAddFocusRequest = 0

    var tasks: [PoolTask] { store.engine.taskPool() }
    var groups: [PoolTaskGroup] {
        Dictionary(grouping: tasks, by: {
            store.currentClassification(for: $0.chain.id)?.category?.name ?? store.copy.ungrouped
        })
            .map { PoolTaskGroup(title: $0.key, tasks: $0.value.sorted { $0.definition.createdAt < $1.definition.createdAt }) }
            .sorted {
                if $0.title == store.copy.ungrouped { return false }
                if $1.title == store.copy.ungrouped { return true }
                return ClassificationNameCanonicalizer.canonicalKey($0.title)
                    < ClassificationNameCanonicalizer.canonicalKey($1.title)
            }
    }

    var shouldShowGroups: Bool {
        groups.count > 1 || groups.contains { $0.title != store.copy.ungrouped }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(title: store.copy.navPool, subtitle: store.copy.poolSubtitle)
                Spacer()
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                VStack(spacing: 0) {
                    PoolQuickAdd(focusRequest: quickAddFocusRequest)
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 0) {
                        if shouldShowGroups {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 8) {
                                        Text(group.title)
                                            .font(.noonmarkSystem(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.text2)
                                        Text("\(group.tasks.count)")
                                            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                                            .foregroundStyle(Theme.text3)
                                            .padding(.horizontal, 6)
                                            .frame(height: 18)
                                            .background(Capsule().fill(Theme.chip))
                                        Spacer()
                                    }
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                    ForEach(group.tasks, id: \.chain.id) { task in
                                        PoolTaskRow(task: task)
                                    }
                                }
                            }
                        } else {
                            ForEach(tasks, id: \.chain.id) { task in
                                PoolTaskRow(task: task)
                            }
                        }
                        if tasks.isEmpty {
                            EmptyState(
                                kind: .taskPool,
                                text: store.copy.emptyPool,
                                actionTitle: store.copy.addTask
                            ) {
                                quickAddFocusRequest &+= 1
                            }
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct PoolTaskGroup: Identifiable {
    let title: String
    let tasks: [PoolTask]

    var id: String { title }
}

struct PoolQuickAdd: View {
    @EnvironmentObject private var store: NoonmarkStore
    let focusRequest: Int

    var body: some View {
        NewTaskInlineField(
            placeholder: store.copy.poolQuickAddPlaceholder,
            text: $store.poolText,
            nativeAccessibilityIdentifier: "quick-add.pool",
            focusRequest: focusRequest
        ) {
            store.addPoolTask()
        }
    }
}

struct PoolTaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let task: PoolTask

    var body: some View {
        let selected = store.isWorkspaceItemSelected(.poolTask(task.chain.id))
        let e2eNamespace = PoolTaskRowE2ENamespace(
            taskIdentifier: task.chain.id.description
        )
        HStack(spacing: 10) {
            PoolTaskPlaceholderGlyph()
            MarkdownInlineText(task.definition.title)
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .layoutPriority(1)
                .background {
                    AppE2EViewAnchor(
                        identifier: e2eNamespace.titleIdentifier,
                        verificationText: task.definition.title
                    )
                }
            if let classification = store.currentClassification(for: task.chain.id) {
                TaskClassificationBadges(
                    display: .current(classification),
                    taskTitle: task.definition.title,
                    accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                        surface: "pool-row",
                        instanceID: task.chain.id.description
                    ),
                    showsCategory: false
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: selected, tint: Theme.navPool, separatorLeadingInset: 40)
        .workspaceSelectable(.poolTask(task.chain.id))
        .onTapGesture { store.userSelectPool(task.chain.id) }
        .contextMenu {
            PoolTaskContextMenu(task: task, surface: "task-row")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pool.task.\(task.chain.id.description)")
        .accessibilityLabel(store.copy.taskAccessibilityLabel(task.definition.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.selectPool(task.chain.id) }
    }
}

struct PoolTaskPlaceholderGlyph: View {
    var body: some View {
        Circle()
            .stroke(Theme.line2, style: StrokeStyle(lineWidth: 1.5, dash: [2.4, 2]))
            .frame(width: 18, height: 18)
    }
}

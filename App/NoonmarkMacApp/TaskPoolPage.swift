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
        TaskCycleConversionMenuSection(
            chainID: task.chain.id,
            traceID: nil,
            accessibilityIdentifier:
            "\(accessibilityPrefix).convert-recurring"
        )
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
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .taskPool)
        )
    }

    var tasks: [PoolTask] {
        store.taskPool()
    }

    private var tasksByID: [String: PoolTask] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.chain.id.description, $0) })
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let items = tasks.map { task in
            TaskCollectionPresentationItem(
                id: task.chain.id.description,
                title: store.copy.displayTaskTitle(task.definition.title),
                time: task.definition.createdAt,
                category: store.currentClassification(for: task.chain.id)?.category?
                    .taskCollectionCategoryPresentation
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: items,
            preference: presentationPreference,
            ungroupedTitle: store.copy.ungrouped
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspacePageHeader(title: store.copy.navPool, subtitle: store.copy.poolSubtitle) {
                TaskCollectionPresentationMenu(
                    copy: store.copy,
                    accessibilityIdentifier:
                    "task-collection-view.pool",
                    preference: $presentationPreference
                )
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                VStack(spacing: 0) {
                    PoolQuickAdd(focusRequest: quickAddFocusRequest)
                        .padding(.bottom, 12)

                    LazyVStack(spacing: 0) {
                        ForEach(presentationSections, id: \.id) { section in
                            if presentationPreference.organization == .grouped {
                                VStack(alignment: .leading, spacing: 0) {
                                    TaskCollectionSectionHeader(
                                        section: section,
                                        count: section.items.count
                                    )
                                    ForEach(section.items, id: \.id) { item in
                                        if let task = tasksByID[item.id] {
                                            PoolTaskRow(task: task)
                                        }
                                    }
                                }
                            } else {
                                ForEach(section.items, id: \.id) { item in
                                    if let task = tasksByID[item.id] {
                                        PoolTaskRow(task: task)
                                    }
                                }
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
        .taskCollectionCategoryVisibility(presentationPreference)
        .onChange(of: presentationPreference) { _, preference in
            presentationRepository.save(preference, for: .taskPool)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "pool.page",
                verificationText: store.copy.navPool
            )
        }
    }
}

struct PoolQuickAdd: View {
    @EnvironmentObject private var store: NoonmarkStore
    let focusRequest: Int

    var body: some View {
        NewTaskInlineField(
            placeholder: store.copy.poolQuickAddPlaceholder,
            draft: store.poolTextDraft,
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
            MarkdownInlineText(store.copy.displayTaskTitle(task.definition.title))
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .layoutPriority(1)
                .background {
                    AppE2EViewAnchor(
                        identifier: e2eNamespace.titleIdentifier,
                        verificationText: store.copy.displayTaskTitle(
                            task.definition.title
                        )
                    )
                }
            if let classification = store.currentClassification(for: task.chain.id) {
                TaskClassificationBadges(
                    display: .current(classification),
                    taskTitle: task.definition.title,
                    accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                        surface: "pool-row",
                        instanceID: task.chain.id.description
                    )
                )
            }
            AutomaticTaskClassificationStatusView(
                chainID: task.chain.id,
                taskTitle: task.definition.title,
                accessibilitySurface: .taskPoolRow,
                accessibilityInstanceID: task.chain.id.description
            )
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

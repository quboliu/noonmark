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

struct UnfinishedPoolPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .unfinished)
        )
    }

    var items: [UnfinishedPoolItem] {
        store.engine.unfinishedPool()
    }

    private var itemsByID: [String: UnfinishedPoolItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.chain.id.description, $0) })
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let rows = items.map { item in
            let traceTime = (item.unfinishedTraces + (item.activeTrace.map { [$0] } ?? []))
                .map(\.createdAt)
                .max()
            return TaskCollectionPresentationItem(
                id: item.chain.id.description,
                title: store.copy.displayTaskTitle(item.definition.title),
                time: traceTime ?? item.definition.createdAt,
                category: store.currentClassification(for: item.chain.id)?.category?
                    .taskCollectionCategoryPresentation
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
            WorkspacePageHeader(title: store.copy.navUnfinished, subtitle: store.copy.unfinishedSubtitle) {
                TaskCollectionPresentationMenu(
                    copy: store.copy,
                    accessibilityIdentifier: "task-collection-view.unfinished",
                    preference: $presentationPreference
                )
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(presentationSections, id: \.id) { section in
                        if presentationPreference.organization == .grouped {
                            TaskCollectionSectionHeader(section: section, count: section.items.count)
                        }
                        ForEach(section.items, id: \.id) { row in
                            if let item = itemsByID[row.id] {
                                UnfinishedRow(item: item)
                            }
                        }
                    }
                    if items.isEmpty {
                        EmptyState(kind: .unfinishedPool, text: store.copy.emptyUnfinished)
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
            presentationRepository.save(preference, for: .unfinished)
        }
    }
}

extension UnfinishedPoolItem {
    var latestUnfinishedTrace: DayTrace? {
        unfinishedTraces.last
    }

    var isAbandoned: Bool {
        chain.state == .abandoned || latestUnfinishedTrace?.status == .abandoned
    }

    var continuationCount: Int {
        let activeTraces = activeTrace.map { [$0] } ?? []
        let chainTraces = unfinishedTraces + activeTraces
        let latestSequence = chainTraces.map(\.continuationSeq).max() ?? 1
        return max(0, latestSequence - 1)
    }
}

struct UnfinishedTaskContextMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: UnfinishedPoolItem

    var body: some View {
        ForEach(item.actionPlan, id: \.self) { action in
            switch action {
            case let .continueTrace(traceID):
                Button(store.copy.continueTo) {
                    store.showingPicker = .continueTrace(traceID)
                }
            case let .abandonChain(traceID):
                Button(store.copy.abandonChain, role: .destructive) {
                    store.abandon(traceID)
                }
            case let .reactivateChain(traceID):
                Button(store.copy.reactivateChain) {
                    store.reactivateAbandonedChain(from: traceID)
                }
            case let .openTaskPool(chainID):
                Button(store.copy.openCurrentTaskPool) {
                    store.page = .pool
                    store.selectPool(chainID)
                }
            case let .abandonPooledChain(chainID):
                Button(store.copy.abandonChain, role: .destructive) {
                    store.deletePoolTask(chainID)
                }
            }
        }
        TaskCycleConversionMenuSection(
            chainID: item.chain.id,
            traceID:
            item.activeTrace?.id
                ?? item.unfinishedTraces.last?.id,
            accessibilityIdentifier:
            "task-cycle-conversion.unfinished.\(item.chain.id.description)"
        )
    }
}

struct UnfinishedRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: UnfinishedPoolItem

    var expanded: Bool { store.expandedUnfinishedChainIDs.contains(item.chain.id) }
    private var activeDateLabel: String {
        guard let active = item.activeTrace else { return "" }
        return active.date == store.today ? store.copy.today : store.displayDate(active.date)
    }

    var body: some View {
        let selected = store.isWorkspaceItemSelected(.unfinishedTask(item.chain.id))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                StatusGlyph(status: item.isAbandoned ? .abandoned : .unfinished)
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownInlineText(store.copy.displayTaskTitle(item.definition.title))
                        .font(.noonmarkSystem(size: 13, weight: .semibold))
                        .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.text1)
                        .lineLimit(1)
                    if let classificationTrace = item.activeTrace ?? item.latestUnfinishedTrace {
                        if let classification = store.displayableClassification(for: classificationTrace) {
                            TaskClassificationBadges(
                                display: classification,
                                taskTitle: item.definition.title,
                                accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                    surface: "unfinished-row",
                                    instanceID: classificationTrace.id.description
                                )
                            )
                            .padding(.top, 4)
                        }
                    }
                    AutomaticTaskClassificationStatusView(
                        chainID: item.chain.id,
                        taskTitle: item.definition.title,
                        accessibilitySurface: .unfinishedRow,
                        accessibilityInstanceID: item.chain.id.description
                    )
                    .padding(.top, 3)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Text(
                    item.isAbandoned
                        ? store.copy.abandoned
                        : store.copy.unfinishedMissedCount(item.unfinishedTraces.count)
                )
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(item.isAbandoned ? Theme.text2 : Theme.warn)
                    .monospacedDigit()
                UnfinishedMetaSeparator()
                Text(store.copy.unfinishedContinuationCount(item.continuationCount))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                if let latestUnfinished = item.latestUnfinishedTrace {
                    UnfinishedMetaSeparator()
                    Text(store.copy.lastMissedDate(store.displayDate(latestUnfinished.date)))
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                if let active = item.activeTrace {
                    Button(store.copy.continuedToCurrent(activeDateLabel)) {
                        store.selectedDate = active.date
                        store.page = .day
                        store.selectTrace(active.id)
                    }
                    .buttonStyle(.plain)
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.accentSoft))
                } else if item.isInTaskPool {
                    Button(store.copy.openCurrentTaskPool) {
                        store.page = .pool
                        store.selectPool(item.chain.id)
                    }
                    .buttonStyle(.plain)
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.navPool)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.navPool.opacity(0.10)))
                }
                Spacer()
                Button(expanded ? store.copy.detailExpanded : store.copy.detailCollapsed) {
                    if expanded {
                        store.expandedUnfinishedChainIDs.remove(item.chain.id)
                    } else {
                        store.expandedUnfinishedChainIDs.insert(item.chain.id)
                    }
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
            }
            .padding(.leading, 28)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.unfinishedTraces, id: \.id) { trace in
                        UnfinishedInlineTrace(trace: trace)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .listRowSurface(selected: selected, tint: Theme.accent, separatorLeadingInset: 40)
        .workspaceSelectable(.unfinishedTask(item.chain.id))
        .onTapGesture { store.userSelectUnfinished(item.chain.id) }
        .contextMenu {
            UnfinishedTaskContextMenu(item: item)
        }
    }
}

struct UnfinishedMetaSeparator: View {
    var body: some View {
        Text("·")
            .font(.noonmarkSystem(size: 11))
            .foregroundStyle(Theme.text3)
    }
}

struct UnfinishedInlineTrace: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: trace.status)
            Text(store.displayDate(trace.date))
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 74, alignment: .leading)
            Text(statusLabel)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(store.copy.continuationOrdinal(trace.continuationSeq))
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
    }

    var statusLabel: String {
        switch trace.status {
        case .abandoned:
            store.copy.traceStatusLabel(trace.status)
        default:
            store.copy.traceStatusLabel(.unfinished)
        }
    }

    var statusColor: Color {
        switch trace.status {
        case .abandoned:
            return Theme.text2
        default:
            return Theme.warn
        }
    }
}

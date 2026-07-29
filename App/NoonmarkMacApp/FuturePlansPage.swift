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

struct FuturePlansPage: View {
    @EnvironmentObject private var store: NoonmarkStore

    var plans: [FuturePlanItem] {
        store.visibleFuturePlanItems()
    }

    var grouped: [(LocalDate, [FuturePlanItem])] {
        Dictionary(grouping: plans) { $0.trace.date }
            .map { ($0.key, $0.value.sorted { $0.trace.priority < $1.trace.priority }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: store.copy.navFuture,
                subtitle: store.copy.futureSubtitle
            ) {
                RecurringFutureVisibilityMenu()
            }
            WorkspaceBulkActionBar()
            TaskSelectionClearingScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 10) {
                                Text("\(store.displayDate(date)) · \(store.weekday(date))")
                                    .font(.noonmarkSystem(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text1)
                                    .monospacedDigit()
                                TextActionButton(store.copy.openDay) {
                                    store.selectedDate = date
                                    store.page = .day
                                }
                            }
                            .padding(.bottom, 4)
                            ForEach(items, id: \.trace.id) { item in
                                FuturePlanRow(item: item)
                            }
                        }
                    }
                    if plans.isEmpty {
                        EmptyState(
                            kind: .futurePlans,
                            text: store.copy.emptyFuture,
                            actionTitle: store.copy.navPool
                        ) {
                            store.selectPage(.pool)
                        }
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
    }
}

struct FuturePlanRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let item: FuturePlanItem

    private var isRecurringOccurrence: Bool {
        store.engine.isRecurringTaskChain(item.trace.chainID)
    }

    var body: some View {
        let selected = store.isWorkspaceItemSelected(.futureTrace(item.trace.id))
        HStack(spacing: 10) {
            PlanningGlyph(
                systemName:
                isRecurringOccurrence
                    ? "repeat"
                    : "calendar.badge.clock",
                color:
                isRecurringOccurrence
                    ? Theme.navRecurring
                    : Theme.navFuture
            )
            VStack(alignment: .leading, spacing: 0) {
                MarkdownInlineText(store.copy.displayTaskTitle(item.definition.title))
                    .font(.noonmarkSystem(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                if let classification = store.displayableClassification(for: item.trace) {
                    TaskClassificationBadges(
                        display: classification,
                        taskTitle: item.definition.title,
                        accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                            surface: "future-row",
                            instanceID: item.trace.id.description
                        )
                    )
                    .padding(.top, 4)
                }
                AutomaticTaskClassificationStatusView(
                    chainID: item.trace.chainID,
                    taskTitle: item.definition.title,
                    accessibilitySurface: .futureRow,
                    accessibilityInstanceID: item.trace.id.description
                )
                .padding(.top, 3)
                if let source = store.carryoverSource(for: item.trace) {
                    Text(
                        store.engine.carryoverKind(for: item.trace.id) == .deferral
                            ? store.copy.deferredFromLink(
                                store.displayDate(source.date)
                            )
                            : store.copy.continuedFromUnfinishedLink(
                                store.displayDate(source.date)
                            )
                    )
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 3)
                }
            }
            Spacer()
            if selected {
                PriorityStepper(
                    canMoveUp: canMoveUp,
                    canMoveDown: canMoveDown,
                    moveUp: { store.movePriority(item.trace.id, delta: -1) },
                    moveDown: { store.movePriority(item.trace.id, delta: 1) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)
        .listRowSurface(selected: selected, tint: Theme.navFuture, separatorLeadingInset: 40)
        .workspaceSelectable(.futureTrace(item.trace.id))
        .draggable(
            TaskPriorityDragItem(
                traceID: item.trace.id,
                date: item.trace.date
            )
        )
        .dropDestination(
            for: TaskPriorityDragItem.self,
            action: { items, _ in
                guard let moving = items.first,
                      moving.date == item.trace.date
                else {
                    WorkspaceDragE2EDiagnostics.recordDrop(
                        targetTraceID: item.trace.id,
                        items: items,
                        accepted: false
                    )
                    return false
                }
                let accepted = store.enqueueTraceReorder(
                    moving.traceID,
                    before: item.trace.id
                ) { committed in
                    WorkspaceDragE2EDiagnostics.recordDrop(
                        targetTraceID: item.trace.id,
                        items: items,
                        accepted: committed
                    )
                }
                if accepted == false {
                    WorkspaceDragE2EDiagnostics.recordDrop(
                        targetTraceID: item.trace.id,
                        items: items,
                        accepted: false
                    )
                }
                return accepted
            },
            isTargeted: { isTargeted in
                WorkspaceDragE2EDiagnostics.recordTarget(
                    traceID: item.trace.id,
                    isTargeted: isTargeted
                )
            }
        )
        .onTapGesture { store.userSelectTrace(item.trace.id) }
        .contextMenu {
            Button(store.copy.viewDetails) { store.selectTrace(item.trace.id) }
            TaskContextMenu(trace: item.trace)
        }
    }

    var canMoveUp: Bool {
        store.canMovePriority(item.trace.id, delta: -1)
    }

    var canMoveDown: Bool {
        store.canMovePriority(item.trace.id, delta: 1)
    }
}

private struct RecurringFutureVisibilityMenu: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        Menu {
            Picker(
                store.copy.recurringFutureVisibilityTitle,
                selection: Binding(
                    get: {
                        store.recurringFuturePlanVisibility
                    },
                    set: {
                        store.setRecurringFuturePlanVisibility($0)
                    }
                )
            ) {
                ForEach(
                    RecurringFuturePlanVisibility.allCases,
                    id: \.self
                ) { visibility in
                    Text(
                        store.copy.recurringFutureVisibilityOption(
                            visibility.dayCount
                        )
                    )
                    .tag(visibility)
                }
            }
        } label: {
            Label(
                store.copy.recurringFutureVisibilityOption(
                    store.recurringFuturePlanVisibility.dayCount
                ),
                systemImage: "repeat"
            )
            .font(.noonmarkSystem(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("future.recurring-visibility")
        .background {
            AppE2EViewAnchor(
                identifier: "future.recurring-visibility",
                verificationText:
                "\(store.recurringFuturePlanVisibility.dayCount)"
            )
        }
    }
}

struct PlanningGlyph: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.noonmarkSystem(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .background(Circle().fill(color.opacity(0.12)))
    }
}

struct PlanMetaPill: View {
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

import NoonmarkCore
import NoonmarkMacUIContract
import SwiftUI

struct TaskCycleTrackRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var showingStopConfirmation = false
    let track: TaskCycleTrack

    private var expanded: Bool {
        store.expandedTaskCycleSeriesIDs.contains(track.id)
    }

    private var accent: Color {
        Theme.navRecurring
    }

    private var lifecycleStyle: TaskCycleLifecycleVisualStyle {
        switch track.lifecycle {
        case .active:
            TaskCycleLifecycleVisualStyle(
                contract: MacUIRecurringLifecycleStyles.active,
                iconColor: Theme.recurringActiveIcon
            )
        case .upcoming:
            TaskCycleLifecycleVisualStyle(
                contract: MacUIRecurringLifecycleStyles.upcoming,
                iconColor: Theme.recurringUpcomingIcon
            )
        case .ended:
            TaskCycleLifecycleVisualStyle(
                contract: MacUIRecurringLifecycleStyles.ended,
                iconColor: Theme.recurringEndedIcon
            )
        case .stopped:
            TaskCycleLifecycleVisualStyle(
                contract: MacUIRecurringLifecycleStyles.stopped,
                iconColor: Theme.recurringStoppedIcon
            )
        }
    }

    private var lifecycleSummary: String {
        store.copy.taskCycleLifecycleSummary(
            track,
            displayDate: store.displayDate
        )
    }

    private var accessibilityIdentifier: String {
        "task-cycle-track.recurring.\(track.id.description)"
    }

    private var selected: Bool {
        store.isWorkspaceItemSelected(.taskCycleSeries(track.id))
    }

    private var classification: TaskClassificationProjection? {
        try? store.engine.taskCycleTemplateClassification(
            seriesID: track.id
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.userSelectTaskCycleSeries(track.id)
                } label: {
                    HStack(spacing: 10) {
                    PlanningGlyph(
                        systemName:
                        lifecycleStyle.contract.systemSymbolName,
                        color: lifecycleStyle.iconColor
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "\(accessibilityIdentifier).lifecycle-icon",
                            verificationText:
                            lifecycleStyle.contract.verificationText
                        )
                    }
                    MarkdownInlineText(
                        store.copy.displayTaskTitle(track.title)
                    )
                    .font(
                        .noonmarkSystem(
                            size: 13,
                            weight: lifecycleStyle.titleWeight
                        )
                    )
                    .foregroundStyle(lifecycleStyle.titleColor)
                    .lineLimit(1)
                    .layoutPriority(1)

                    if let classification,
                       classification.category != nil
                        || classification.labels.isEmpty == false
                    {
                        TaskClassificationBadges(
                            display: .current(classification),
                            taskTitle: track.title,
                            accessibilityNamespace:
                            TaskClassificationAccessibilityNamespace(
                                surface: "task-cycle-row",
                                instanceID: track.id.description
                            )
                        )
                        .taskRowCategoryVisibility(true)
                    }

                    Text(store.copy.taskCycleSchedule(track.schedule))
                        .font(.noonmarkSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(lifecycleStyle.scheduleColor)

                    Spacer(minLength: 8)

                    Text(lifecycleSummary)
                    .font(
                        .noonmarkSystem(
                            size: 10.5,
                            weight:
                            lifecycleStyle.contract.textWeight.fontWeight
                        )
                    )
                    .foregroundStyle(lifecycleStyle.summaryColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(2)
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "\(accessibilityIdentifier).lifecycle",
                            verificationText: lifecycleSummary
                        )
                    }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    store.copy.displayTaskTitle(track.title)
                )
                .accessibilityValue(lifecycleSummary)
                .accessibilityIdentifier(
                    "\(accessibilityIdentifier).detail"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier: "\(accessibilityIdentifier).detail",
                        verificationText: track.title
                    )
                }

                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        Text(store.copy.recurringTaskTrack)
                        Image(
                            systemName: expanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                    }
                    .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.copy.recurringTaskTrack)
                .accessibilityIdentifier(
                    "\(accessibilityIdentifier).disclosure"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier:
                        "\(accessibilityIdentifier).disclosure",
                        verificationText: store.copy.recurringTaskTrack
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(
                .vertical,
                NoonmarkVisualMetrics.taskRowVerticalPadding
            )

            if expanded {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(track.days) { day in
                            TaskCycleTrackDayButton(
                                seriesID: track.id,
                                day: day
                            )
                        }
                    }
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        .listRowSurface(
            selected: selected,
            tint: accent,
            separatorLeadingInset: 40
        )
        .workspaceSelectable(.taskCycleSeries(track.id))
        .contextMenu {
            if track.canStop {
                Button(store.copy.stopRecurringTask, role: .destructive) {
                    showingStopConfirmation = true
                }
            }
        }
        .confirmationDialog(
            store.copy.stopRecurringTask,
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(store.copy.stopRecurringTask, role: .destructive) {
                store.stopTaskCycleSeries(track.id)
            }
            Button(store.copy.cancelRecurringTaskCreation, role: .cancel) {}
        } message: {
            Text(store.copy.stopRecurringTaskConfirmation)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .background {
            AppE2EViewAnchor(identifier: accessibilityIdentifier)
        }
    }

    private func toggleExpanded() {
        if expanded {
            store.expandedTaskCycleSeriesIDs.remove(track.id)
        } else {
            store.expandedTaskCycleSeriesIDs.insert(track.id)
        }
    }
}

private struct TaskCycleLifecycleVisualStyle {
    let contract: MacUIRecurringLifecycleStyle
    let iconColor: Color

    var titleColor: Color {
        switch contract.rowEmphasis {
        case .primary:
            Theme.text1
        case .muted:
            Theme.terminalTaskText
        }
    }

    var titleWeight: Font.Weight {
        switch contract.rowEmphasis {
        case .primary:
            .semibold
        case .muted:
            .regular
        }
    }

    var scheduleColor: Color {
        switch contract.rowEmphasis {
        case .primary:
            Theme.text3
        case .muted:
            Theme.terminalTaskText
        }
    }

    var summaryColor: Color {
        switch contract.role {
        case .active:
            Theme.recurringActiveText
        case .upcoming:
            Theme.recurringUpcomingText
        case .ended, .stopped:
            Theme.terminalTaskText
        }
    }
}

private extension MacUIRecurringTextWeight {
    var fontWeight: Font.Weight {
        switch self {
        case .regular:
            .regular
        case .semibold:
            .semibold
        }
    }
}

private struct TaskCycleTrackDayButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    let seriesID: TaskCycleSeriesID
    let day: TaskCycleTrackDay

    private var navigationTarget: TaskCycleTraceTarget? {
        day.navigationTarget
    }

    private var presentationState: TaskCycleTrackDayState {
        day.state
    }

    private var movedFutureTargetDate: LocalDate? {
        guard let targetDate = day.futurePlanTarget?.date,
              targetDate != day.date
        else {
            return nil
        }
        return targetDate
    }

    private var accessibilityLabel: String {
        let state = store.copy.taskCycleState(presentationState)
        let base = "\(store.displayDate(day.date))，\(state)"
        guard let targetDate = movedFutureTargetDate else {
            return base
        }
        return "\(base)，\(store.copy.taskCycleFutureTarget(store.displayDate(targetDate)))"
    }

    private var accessibilityIdentifier: String {
        "task-cycle-day.recurring.\(seriesID.description).\(day.date.description).\(presentationState.rawValue)"
    }

    var body: some View {
        Button {
            guard let navigationTarget else { return }
            store.selectedDate = navigationTarget.date
            store.page = .day
            store.selectTrace(navigationTarget.traceID)
        } label: {
            VStack(spacing: 3) {
                Text(store.weekdayNarrow(day.date))
                    .font(.noonmarkSystem(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Text("\(day.date.day)")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(
                        presentationState == .pendingToday
                            ? Theme.accent
                            : Theme.text2
                    )
                    .monospacedDigit()
                HStack(spacing: 1) {
                    Image(systemName: presentationState.symbolName)
                    if let movedFutureTargetDate {
                        Text(
                            "→\(movedFutureTargetDate.month)/\(movedFutureTargetDate.day)"
                        )
                        .monospacedDigit()
                    }
                }
                .font(.noonmarkSystem(size: 7.5, weight: .bold))
                .foregroundStyle(presentationState.color)
                .lineLimit(1)
                    .frame(height: 8)
            }
            .frame(
                width: movedFutureTargetDate == nil ? 28 : 48,
                height: 36
            )
            .background {
                if presentationState == .pendingToday {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accentSoft)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(navigationTarget == nil)
        .contextMenu {
            if day.date > store.today,
               (day.futurePlanTarget?.date ?? day.date) > store.today,
               presentationState != .skipped
            {
                Button(store.copy.skipRecurringOccurrence) {
                    store.skipTaskCycleOccurrence(
                        seriesID: seriesID,
                        occurrenceDate: day.date
                    )
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: accessibilityLabel
            )
        }
    }
}

private extension TaskCycleTrackDayState {
    var symbolName: String {
        switch self {
        case .notScheduled:
            "minus"
        case .pendingPast:
            "clock.fill"
        case .pendingToday, .planned:
            "circle.fill"
        case .completed:
            "checkmark"
        case .unfinished, .abandoned:
            "xmark"
        case .deferred:
            "arrow.right"
        case .changed:
            "arrow.triangle.2.circlepath"
        case .returnedToPool:
            "tray.and.arrow.down"
        case .skipped:
            "forward.end"
        }
    }

    var color: Color {
        switch self {
        case .notScheduled:
            Theme.line2
        case .pendingPast, .unfinished:
            Theme.warn
        case .pendingToday:
            Theme.accent
        case .planned:
            Theme.navFuture
        case .completed:
            Theme.ok
        case .deferred:
            Theme.navFuture
        case .changed, .returnedToPool:
            Theme.text2
        case .skipped, .abandoned:
            Theme.text3
        }
    }
}

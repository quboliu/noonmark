import NoonmarkCore
import SwiftUI

struct TaskCycleTrackRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let track: TaskCycleTrack
    let collection: TaskCycleCollection

    private var accent: Color {
        switch collection {
        case .future:
            Theme.navFuture
        case .unfinished:
            Theme.navUnfinished
        case .completed:
            Theme.navCompleted
        }
    }

    private var accessibilityIdentifier: String {
        "task-cycle-track.\(collection.accessibilityName).\(track.id.description)"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accent)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MarkdownInlineText(store.copy.displayTaskTitle(track.title))
                        .font(.noonmarkSystem(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(store.copy.taskCycleSchedule(track.schedule))
                        .font(.noonmarkSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    Text(
                        store.copy.taskCycleSummary(
                            track,
                            collection: collection
                        )
                    )
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(track.days) { day in
                            TaskCycleTrackDayButton(
                                seriesID: track.id,
                                collection: collection,
                                day: day
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .listRowSurface(
            selected: false,
            tint: accent,
            separatorLeadingInset: 24
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .background {
            AppE2EViewAnchor(identifier: accessibilityIdentifier)
        }
    }
}

private struct TaskCycleTrackDayButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    let seriesID: TaskCycleSeriesID
    let collection: TaskCycleCollection
    let day: TaskCycleTrackDay

    private var navigationTarget: TaskCycleTraceTarget? {
        day.navigationTarget(in: collection)
    }

    private var presentationState: TaskCycleTrackDayState {
        day.presentationState(in: collection)
    }

    private var movedFutureTargetDate: LocalDate? {
        guard collection == .future,
              let targetDate = day.futurePlanTarget?.date,
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
        "task-cycle-day.\(collection.accessibilityName).\(seriesID.description).\(day.date.description).\(presentationState.rawValue)"
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

private extension TaskCycleCollection {
    var accessibilityName: String {
        switch self {
        case .future: "future"
        case .unfinished: "unfinished"
        case .completed: "completed"
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

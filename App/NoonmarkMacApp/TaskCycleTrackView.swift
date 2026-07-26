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
                            TaskCycleTrackDayButton(day: day)
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
        .accessibilityIdentifier(
            "task-cycle-track.\(collection.accessibilityName).\(track.id.description)"
        )
    }
}

private struct TaskCycleTrackDayButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    let day: TaskCycleTrackDay

    var body: some View {
        Button {
            guard let traceID = day.traceID else { return }
            store.selectedDate = day.date
            store.page = .day
            store.selectTrace(traceID)
        } label: {
            VStack(spacing: 3) {
                Text(store.weekdayNarrow(day.date))
                    .font(.noonmarkSystem(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.text3)
                Text("\(day.date.day)")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(
                        day.state == .pendingToday
                            ? Theme.accent
                            : Theme.text2
                    )
                    .monospacedDigit()
                Image(systemName: day.state.symbolName)
                    .font(.noonmarkSystem(size: 7.5, weight: .bold))
                    .foregroundStyle(day.state.color)
                    .frame(height: 8)
            }
            .frame(width: 28, height: 36)
            .background {
                if day.state == .pendingToday {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accentSoft)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(day.traceID == nil)
        .accessibilityLabel(
            "\(store.displayDate(day.date))，\(store.copy.taskCycleState(day.state))"
        )
        .accessibilityIdentifier(
            "task-cycle-day.\(day.date.description).\(day.state.rawValue)"
        )
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

import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

enum TaskCycleFrequencyKind: String, CaseIterable {
    case dayInterval
    case selectedWeekdays
}

enum TaskCycleEndKind: String, CaseIterable {
    case duration
    case completionTarget
    case date
}

struct TaskCyclePlanEditorState: Equatable {
    var frequencyKind: TaskCycleFrequencyKind = .dayInterval
    var dayInterval = 1
    var weekInterval = 1
    var weekdays: Set<TaskCycleWeekday> = [.monday]
    var endKind: TaskCycleEndKind = .duration
    var durationDays = 7
    var completionTarget = 7
    var deadline = Date()

    var schedule: TaskCycleSchedule {
        switch frequencyKind {
        case .dayInterval:
            .everyDays(dayInterval)
        case .selectedWeekdays:
            .selectedWeekdays(
                weekdays: weekdays,
                everyWeeks: weekInterval
            )
        }
    }

    func endCondition(
        startDate: LocalDate,
        formatter: AppDateTimeFormatter
    ) -> TaskCycleEndCondition? {
        switch endKind {
        case .duration:
            return .durationDays(durationDays)
        case .completionTarget:
            guard let date = try? formatter.localDate(from: deadline)
            else {
                return nil
            }
            return .completionTarget(
                count: completionTarget,
                latestDate: date
            )
        case .date:
            guard let date = try? formatter.localDate(from: deadline)
            else {
                return nil
            }
            return .onDate(date)
        }
    }

    static func editing(
        _ series: TaskCycleSeries,
        formatter: AppDateTimeFormatter
    ) -> TaskCyclePlanEditorState {
        var result = TaskCyclePlanEditorState()
        switch series.schedule {
        case let .everyDays(interval):
            result.frequencyKind = .dayInterval
            result.dayInterval = interval
        case let .selectedWeekdays(weekdays, interval):
            result.frequencyKind = .selectedWeekdays
            result.weekdays = weekdays
            result.weekInterval = interval
        }
        switch series.endCondition {
        case let .durationDays(days):
            result.endKind = .duration
            result.durationDays = days
        case let .completionTarget(count, latestDate):
            result.endKind = .completionTarget
            result.completionTarget = count
            result.deadline =
                (try? formatter.foundationDate(from: latestDate))
                    ?? Date()
        case let .onDate(date):
            result.endKind = .date
            result.deadline =
                (try? formatter.foundationDate(from: date))
                    ?? Date()
        }
        return result
    }
}

struct TaskCyclePlanEditor: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var state: TaskCyclePlanEditorState
    let startDate: Date
    let formatter: AppDateTimeFormatter
    let accessibilityNamespace: String

    private var maximumDeadline: Date {
        guard let localStart = try? formatter.localDate(from: startDate)
        else {
            return startDate
        }
        return (try? formatter.foundationDate(
            from: NoonmarkStore.offset(localStart, by: 365)
        )) ?? startDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(
                store.copy.recurringTaskSchedule,
                selection: $state.frequencyKind
            ) {
                Text(store.copy.taskCycleEveryDaysMode)
                    .tag(TaskCycleFrequencyKind.dayInterval)
                Text(store.copy.taskCycleWeekdayMode)
                    .tag(TaskCycleFrequencyKind.selectedWeekdays)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(
                "\(accessibilityNamespace).frequency"
            )

            switch state.frequencyKind {
            case .dayInterval:
                Stepper(
                    store.copy.taskCycleEveryDays(state.dayInterval),
                    value: $state.dayInterval,
                    in: 1 ... 30
                )
                .accessibilityIdentifier(
                    "\(accessibilityNamespace).day-interval"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier:
                        "\(accessibilityNamespace).day-interval",
                        verificationText: "\(state.dayInterval)"
                    )
                }
            case .selectedWeekdays:
                Stepper(
                    store.copy.taskCycleEveryWeeks(state.weekInterval),
                    value: $state.weekInterval,
                    in: 1 ... 4
                )
                .accessibilityIdentifier(
                    "\(accessibilityNamespace).week-interval"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier:
                        "\(accessibilityNamespace).week-interval",
                        verificationText: "\(state.weekInterval)"
                    )
                }
                weekdaySelector
            }

            Divider()

            Picker(
                store.copy.taskCycleEndRule,
                selection: $state.endKind
            ) {
                Text(store.copy.taskCycleEndByDuration)
                    .tag(TaskCycleEndKind.duration)
                Text(store.copy.taskCycleEndByCompletion)
                    .tag(TaskCycleEndKind.completionTarget)
                Text(store.copy.taskCycleEndByDate)
                    .tag(TaskCycleEndKind.date)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(
                "\(accessibilityNamespace).end-kind"
            )

            switch state.endKind {
            case .duration:
                Stepper(
                    store.copy.taskCycleDurationDays(
                        state.durationDays
                    ),
                    value: $state.durationDays,
                    in: 1 ... 366
                )
                .accessibilityIdentifier(
                    "\(accessibilityNamespace).duration-days"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier:
                        "\(accessibilityNamespace).duration-days",
                        verificationText: "\(state.durationDays)"
                    )
                }
            case .completionTarget:
                Stepper(
                    store.copy.taskCycleCompletionTarget(
                        state.completionTarget
                    ),
                    value: $state.completionTarget,
                    in: 1 ... 366
                )
                .accessibilityIdentifier(
                    "\(accessibilityNamespace).completion-target"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier:
                        "\(accessibilityNamespace).completion-target",
                        verificationText: "\(state.completionTarget)"
                    )
                }
                deadlinePicker(
                    title: store.copy.taskCycleLatestDate
                )
                Text(store.copy.taskCycleCompletionLockNotice)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
            case .date:
                deadlinePicker(title: store.copy.recurringTaskEndDate)
            }
        }
        .onChange(of: startDate) { _, value in
            if state.deadline < value {
                state.deadline = value
            } else if state.deadline > maximumDeadline {
                state.deadline = maximumDeadline
            }
        }
    }

    private var weekdaySelector: some View {
        HStack(spacing: 5) {
            ForEach(TaskCycleWeekday.allCases, id: \.self) {
                weekday in
                let selected = state.weekdays.contains(weekday)
                Button {
                    if selected, state.weekdays.count > 1 {
                        state.weekdays.remove(weekday)
                    } else {
                        state.weekdays.insert(weekday)
                    }
                } label: {
                    Text(store.copy.taskCycleWeekday(weekday))
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .frame(width: 27, height: 25)
                        .foregroundStyle(
                            selected ? Color.white : Theme.text2
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    selected
                                        ? Theme.accent
                                        : Theme.controlFill
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "\(accessibilityNamespace).weekday.\(weekday.rawValue)"
                )
            }
        }
    }

    private func deadlinePicker(title: String) -> some View {
        LabeledContent(title) {
            DatePicker(
                "",
                selection: $state.deadline,
                in: startDate ... maximumDeadline,
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityIdentifier(
                "\(accessibilityNamespace).deadline"
            )
        }
    }
}

import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct TaskCycleCreationSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var title = ""
    @State private var schedule = TaskCycleSchedule.daily
    @State private var startDate = Date()
    @State private var endDate = Date()
    @FocusState private var titleIsFocused: Bool

    private var request: TaskCycleCreationRequest? {
        store.taskCycleCreationRequest
    }

    private var convertsExistingTask: Bool {
        guard let request else { return false }
        if case .existingTask = request.origin {
            return true
        }
        return false
    }

    private var allowsTitleEditing: Bool {
        convertsExistingTask == false
            || request?.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == true
    }

    private var sheetTitle: String {
        let source = convertsExistingTask
            ? store.copy.convertToRecurringTask
            : store.copy.newRecurringTask
        return source.replacingOccurrences(of: "…", with: "")
    }

    private var primaryActionTitle: String {
        convertsExistingTask
            ? store.copy.confirmRecurringTaskConversion
            : store.copy.createRecurringTask
    }

    private var formatter: AppDateTimeFormatter {
        AppDateTimeFormatter(
            language: store.engine.preferences.language,
            timeZone: TimeZone(
                identifier: store.naturalDayState.timeZoneIdentifier
            ) ?? .autoupdatingCurrent
        )
    }

    private var startLocalDate: LocalDate? {
        try? formatter.localDate(from: startDate)
    }

    private var endLocalDate: LocalDate? {
        try? formatter.localDate(from: endDate)
    }

    private var latestEndDate: Date {
        let local = startLocalDate.map {
            NoonmarkStore.offset($0, by: 365)
        } ?? NoonmarkStore.offset(store.today, by: 365)
        return (try? formatter.foundationDate(from: local))
            ?? endDate
    }

    private var occurrenceCount: Int? {
        guard let startLocalDate, let endLocalDate else {
            return nil
        }
        return try? schedule.occurrenceCount(
            from: startLocalDate,
            through: endLocalDate
        )
    }

    private var canCreate: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            == false
            && startLocalDate.map { $0 >= store.today } == true
            && endLocalDate.map { end in
                startLocalDate.map { end >= $0 } == true
            } == true
            && occurrenceCount.map { $0 > 0 } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheetTitle)
            .font(.noonmarkSystem(size: 17, weight: .semibold))
            .foregroundStyle(Theme.text1)

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(store.copy.recurringTaskTitle) {
                    TextField("", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                        .focused($titleIsFocused)
                        .accessibilityIdentifier(
                            "task-cycle-create.title"
                        )
                        .background {
                            AppE2EViewAnchor(
                                identifier: "task-cycle-create.title",
                                verificationText: title
                            )
                        }
                        .onSubmit(create)
                        .disabled(allowsTitleEditing == false)
                }

                LabeledContent(store.copy.recurringTaskSchedule) {
                    Picker("", selection: $schedule) {
                        ForEach(TaskCycleSchedule.allCases, id: \.self) {
                            value in
                            Text(store.copy.taskCycleSchedule(value))
                                .tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .accessibilityIdentifier(
                        "task-cycle-create.schedule"
                    )
                }

                LabeledContent(store.copy.recurringTaskStartDate) {
                    DatePicker(
                        "",
                        selection: $startDate,
                        in: todayFoundationDate ... Date.distantFuture,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityIdentifier(
                        "task-cycle-create.start-date"
                    )
                    .disabled(request?.locksStartDate == true)
                }

                LabeledContent(store.copy.recurringTaskEndDate) {
                    DatePicker(
                        "",
                        selection: $endDate,
                        in: startDate ... latestEndDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityIdentifier(
                        "task-cycle-create.end-date"
                    )
                }
            }

            if let occurrenceCount {
                Text(store.copy.taskCycleOccurrencePreview(occurrenceCount))
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .monospacedDigit()
                    .accessibilityIdentifier(
                        "task-cycle-create.preview"
                    )
            }

            if let request,
               request.categoryName != nil
                || request.labelNames.isEmpty == false
            {
                Text(
                    ([request.categoryName].compactMap { $0 }
                        .map { "@\($0)" }
                        + request.labelNames.map { "#\($0)" })
                        .joined(separator: "  ")
                )
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text2)
            }

            Divider()

            HStack {
                Spacer()
                Button(store.copy.cancelRecurringTaskCreation) {
                    store.cancelTaskCycleCreation()
                }
                .keyboardShortcut(.cancelAction)
                Button(primaryActionTitle, action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(canCreate == false)
                    .accessibilityIdentifier(
                        "task-cycle-create.confirm"
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier: "task-cycle-create.confirm",
                            verificationText: primaryActionTitle
                        )
                    }
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear {
            title = request?.title ?? ""
            startDate = request.flatMap {
                try? formatter.foundationDate(from: $0.startDate)
            } ?? todayFoundationDate
            endDate = (try? formatter.foundationDate(
                from: NoonmarkStore.offset(
                    request?.startDate ?? store.today,
                    by: 6
                )
            )) ?? todayFoundationDate
            titleIsFocused = allowsTitleEditing
        }
        .onDisappear {
            if store.showingTaskCycleCreation == false {
                store.taskCycleCreationRequest = nil
            }
        }
        .onChange(of: startDate) { _, newStartDate in
            if endDate < newStartDate {
                endDate = newStartDate
            } else if endDate > latestEndDate {
                endDate = latestEndDate
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier: "task-cycle-create.sheet",
                verificationText: sheetTitle
            )
        }
    }

    private var todayFoundationDate: Date {
        (try? formatter.foundationDate(from: store.today)) ?? Date()
    }

    private func create() {
        guard canCreate,
              let startLocalDate,
              let endLocalDate
        else {
            return
        }
        _ = store.createTaskCycleSeries(
            title: title,
            startDate: startLocalDate,
            endDate: endLocalDate,
            schedule: schedule
        )
    }
}

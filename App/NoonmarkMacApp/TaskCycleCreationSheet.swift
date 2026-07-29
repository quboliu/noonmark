import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct TaskCycleCreationSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var title = ""
    @State private var plan = TaskCyclePlanEditorState()
    @State private var startDate = Date()
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

    private var endCondition: TaskCycleEndCondition? {
        guard let startLocalDate else { return nil }
        return plan.endCondition(
            startDate: startLocalDate,
            formatter: formatter
        )
    }

    private var occurrenceCount: Int? {
        guard let startLocalDate,
              let endDate = try? endCondition?.resolvedEndDate(
                  from: startLocalDate
              )
        else {
            return nil
        }
        return try? plan.schedule.occurrenceCount(
            from: startLocalDate,
            through: endDate
        )
    }

    private var canCreate: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            == false
            && startLocalDate.map { $0 >= store.today } == true
            && endCondition != nil
            && occurrenceCount.map { $0 > 0 } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

                TaskCyclePlanEditor(
                    state: $plan,
                    startDate: startDate,
                    formatter: formatter,
                    accessibilityNamespace: "task-cycle-create.plan"
                )
                .accessibilityIdentifier(
                    "task-cycle-create.schedule"
                )
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
            plan.deadline = (try? formatter.foundationDate(
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
            if plan.deadline < newStartDate {
                plan.deadline = newStartDate
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
              let endCondition
        else {
            return
        }
        _ = store.createTaskCycleSeries(
            title: title,
            startDate: startLocalDate,
            schedule: plan.schedule,
            endCondition: endCondition
        )
    }
}

import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct TaskCycleDetail: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var showingPlanEditor = false
    @State private var showingStopConfirmation = false
    let series: TaskCycleSeries

    private var isStopped: Bool {
        series.stoppedAfterDate != nil
    }

    private var track: TaskCycleTrack? {
        store.engine.taskCycleTracks(today: store.today).first {
            $0.id == series.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailHeader(
                store.copy.taskCycleTemplateTitle,
                onClose: { store.clearSelection() }
            )
            DetailPrimaryText {
                EditableDetailTitleRow(
                    series.title,
                    editable: isStopped == false
                ) {
                    store.updateTaskCycleTitle(
                        seriesID: series.id,
                        title: $0
                    )
                }
            } description: {
                DetailDescriptionBlock(
                    text: Binding(
                        get: { series.descriptionText ?? "" },
                        set: {
                            store.updateTaskCycleDescription(
                                seriesID: series.id,
                                descriptionText: $0
                            )
                        }
                    ),
                    placeholder: store.copy.taskDescriptionPlaceholder,
                    editable: isStopped == false
                )
            }

            if isStopped {
                Text(store.copy.taskCycleStoppedNotice)
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }

            DetailSection(
                store.copy.classificationAndLabelsTitle,
                showsTitle: false
            ) {
                TaskClassificationEditor(
                    seriesID: series.id,
                    taskTitle: series.title
                )
            }

            DetailSection(store.copy.subtasksTitle, showsTitle: false) {
                TaskCyclePlannedSubtasksSection(
                    series: series,
                    editable: isStopped == false
                )
            }

            DetailSection(store.copy.taskCycleSettingsTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    taskCycleSetting(
                        store.copy.recurringTaskStartDate,
                        store.displayDate(series.startDate)
                    )
                    taskCycleSetting(
                        store.copy.recurringTaskSchedule,
                        store.copy.taskCycleSchedule(series.schedule)
                    )
                    taskCycleSetting(
                        store.copy.taskCycleEndRule,
                        store.copy.taskCycleEndCondition(
                            series.endCondition,
                            startDate: series.startDate
                        )
                    )

                    Text(store.copy.taskCyclePlanEffectiveNotice)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)

                    if isStopped == false {
                        Button(store.copy.taskCycleEditPlan) {
                            showingPlanEditor = true
                        }
                        .accessibilityIdentifier(
                            "task-cycle-detail.edit-plan"
                        )
                        .background {
                            AppE2EViewAnchor(
                                identifier:
                                "task-cycle-detail.edit-plan",
                                verificationText:
                                store.copy.taskCycleEditPlan
                            )
                        }
                    }
                }
            }

            if let track {
                DetailSection(store.copy.recurringTaskTrack) {
                    Text(
                        store.copy.taskCycleSummary(
                            track,
                            collection: .recurringPlans
                        )
                    )
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .monospacedDigit()
                }
            }

            if isStopped == false, track?.futurePlanCount ?? 0 > 0 {
                Button(
                    store.copy.stopRecurringTask,
                    role: .destructive
                ) {
                    showingStopConfirmation = true
                }
                .accessibilityIdentifier("task-cycle-detail.stop")
                .background {
                    AppE2EViewAnchor(
                        identifier: "task-cycle-detail.stop",
                        verificationText:
                        store.copy.stopRecurringTask
                    )
                }
            }
        }
        .accessibilityIdentifier(
            "task-cycle-detail.\(series.id.description)"
        )
        .background {
            AppE2EViewAnchor(
                identifier:
                "task-cycle-detail.\(series.id.description)",
                verificationText: series.title
            )
        }
        .sheet(isPresented: $showingPlanEditor) {
            TaskCyclePlanEditingSheet(series: series)
                .environmentObject(store)
        }
        .confirmationDialog(
            store.copy.stopRecurringTask,
            isPresented: $showingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button(store.copy.stopRecurringTask, role: .destructive) {
                store.stopTaskCycleSeries(series.id)
            }
            Button(
                store.copy.cancelRecurringTaskCreation,
                role: .cancel
            ) {}
        } message: {
            Text(store.copy.stopRecurringTaskConfirmation)
        }
    }

    private func taskCycleSetting(
        _ name: String,
        _ value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.text1)
        }
    }
}

private struct TaskCyclePlanEditingSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Environment(\.dismiss) private var dismiss
    @State private var state = TaskCyclePlanEditorState()
    @State private var editedStartDate = Date()
    let series: TaskCycleSeries

    private var formatter: AppDateTimeFormatter {
        AppDateTimeFormatter(
            language: store.engine.preferences.language,
            timeZone: TimeZone(
                identifier: store.naturalDayState.timeZoneIdentifier
            ) ?? .autoupdatingCurrent
        )
    }

    private var storedStartDate: Date {
        (try? formatter.foundationDate(from: series.startDate))
            ?? Date()
    }

    private var todayFoundationDate: Date {
        (try? formatter.foundationDate(from: store.today))
            ?? Date()
    }

    private var canReviseStartDate: Bool {
        store.engine.canReviseTaskCycleStartDate(
            seriesID: series.id,
            today: store.today
        )
    }

    private var planStartDate: Date {
        canReviseStartDate ? editedStartDate : storedStartDate
    }

    private var planStartLocalDate: LocalDate? {
        try? formatter.localDate(from: planStartDate)
    }

    private var canSave: Bool {
        guard let planStartLocalDate,
            let condition = state.endCondition(
                startDate: planStartLocalDate,
                formatter: formatter
            ),
            let endDate = try? condition.resolvedEndDate(
                from: planStartLocalDate
            )
        else {
            return false
        }
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        let effectiveFrom = canReviseStartDate
            ? planStartLocalDate
            : max(series.startDate, tomorrow)
        return planStartLocalDate >= store.today
            && endDate >= effectiveFrom
            && ((try? state.schedule.occurrenceCount(
                from: effectiveFrom,
                through: endDate
            )) ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.copy.taskCycleSettingsTitle)
                .font(.noonmarkSystem(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text1)

            if canReviseStartDate {
                LabeledContent(store.copy.recurringTaskStartDate) {
                    DatePicker(
                        "",
                        selection: $editedStartDate,
                        in: todayFoundationDate ... Date.distantFuture,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .accessibilityIdentifier(
                        "task-cycle-plan-edit.start-date"
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "task-cycle-plan-edit.start-date.anchor",
                            verificationText:
                            planStartLocalDate?.description ?? ""
                        )
                    }
                }
            }

            TaskCyclePlanEditor(
                state: $state,
                startDate: planStartDate,
                formatter: formatter,
                accessibilityNamespace: "task-cycle-plan-edit"
            )

            Text(store.copy.taskCyclePlanEffectiveNotice)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)

            Divider()

            HStack {
                Spacer()
                Button(store.copy.cancelRecurringTaskCreation) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(store.copy.taskCycleSavePlan) {
                    guard let planStartLocalDate else {
                        return
                    }
                    guard let endCondition = state.endCondition(
                        startDate: planStartLocalDate,
                        formatter: formatter
                    ) else {
                        return
                    }
                    if store.reviseTaskCycleSeries(
                        seriesID: series.id,
                        startDate: canReviseStartDate
                            ? planStartLocalDate
                            : nil,
                        schedule: state.schedule,
                        endCondition: endCondition
                    ) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSave == false)
                .accessibilityIdentifier(
                    "task-cycle-plan-edit.confirm"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier: "task-cycle-plan-edit.confirm",
                        verificationText: store.copy.taskCycleSavePlan
                    )
                }
            }
        }
        .padding(22)
        .frame(width: 430)
        .onAppear {
            editedStartDate = storedStartDate
            state = .editing(series, formatter: formatter)
        }
    }
}

private struct TaskCyclePlannedSubtasksSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    let series: TaskCycleSeries
    let editable: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(series.plannedSubtasks) { subtask in
                HStack(spacing: 8) {
                    EditableSubtaskTitle(
                        title: subtask.title,
                        editable: editable,
                        accessibilityIdentifier:
                        "task-cycle-subtask.\(subtask.id.description).title"
                    ) {
                        store.renameTaskCyclePlannedSubtask(
                            seriesID: series.id,
                            subtaskID: subtask.id,
                            title: $0
                        )
                    }

                    Spacer()

                    Menu {
                        ForEach(
                            SubtaskDifficulty.allCases,
                            id: \.self
                        ) { difficulty in
                            Button {
                                store
                                    .setTaskCyclePlannedSubtaskDifficulty(
                                        seriesID: series.id,
                                        subtaskID: subtask.id,
                                        difficulty: difficulty
                                    )
                            } label: {
                                Text(
                                    store.copy.subtaskDifficulty(
                                        difficulty,
                                        compact: true
                                    )
                                )
                            }
                        }
                    } label: {
                        Text(
                            store.copy.subtaskDifficulty(
                                subtask.difficulty,
                                compact: true
                            )
                        )
                        .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                    }
                    .disabled(editable == false)

                    if editable {
                        Button {
                            store.removeTaskCyclePlannedSubtask(
                                seriesID: series.id,
                                subtaskID: subtask.id
                            )
                        } label: {
                            Image(systemName: "xmark")
                                .font(.noonmarkSystem(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if editable {
                MarkdownEditor(
                    text: $store.detailSubtaskText,
                    placeholder: store.copy.addSubtaskPlaceholder,
                    style: .compact,
                    commitsOnReturn: true,
                    onCommit: {
                        store.addTaskCyclePlannedSubtask(
                            seriesID: series.id,
                            title: store.detailSubtaskText
                        )
                    },
                    nativeAccessibilityIdentifier:
                    "task-cycle-subtask.\(series.id.description).new"
                )
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.panel2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Theme.line)
                )
            }
        }
    }
}

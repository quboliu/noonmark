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
                .disabled(isStopped)
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
                            collection: collection
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

    private var collection: TaskCycleCollection {
        switch store.page {
        case .pool:
            .pool
        case .future:
            .future
        case .unfinished:
            .unfinished
        case .completed:
            .completed
        case .day, .calendar, .zhulong, .settings:
            .pool
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
    let series: TaskCycleSeries

    private var formatter: AppDateTimeFormatter {
        AppDateTimeFormatter(
            language: store.engine.preferences.language,
            timeZone: TimeZone(
                identifier: store.naturalDayState.timeZoneIdentifier
            ) ?? .autoupdatingCurrent
        )
    }

    private var startDate: Date {
        (try? formatter.foundationDate(from: series.startDate))
            ?? Date()
    }

    private var canSave: Bool {
        guard let condition = state.endCondition(
            startDate: series.startDate,
            formatter: formatter
        ),
            let endDate = try? condition.resolvedEndDate(
                from: series.startDate
            )
        else {
            return false
        }
        let tomorrow = NoonmarkStore.offset(store.today, by: 1)
        return endDate >= max(series.startDate, tomorrow)
            && ((try? state.schedule.occurrenceCount(
                from: max(series.startDate, tomorrow),
                through: endDate
            )) ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.copy.taskCycleSettingsTitle)
                .font(.noonmarkSystem(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text1)

            TaskCyclePlanEditor(
                state: $state,
                startDate: startDate,
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
                    guard let endCondition = state.endCondition(
                        startDate: series.startDate,
                        formatter: formatter
                    ) else {
                        return
                    }
                    if store.reviseTaskCycleSeries(
                        seriesID: series.id,
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

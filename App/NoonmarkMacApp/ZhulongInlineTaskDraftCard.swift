import Foundation
import NoonmarkCore
import NoonmarkZhulong
import SwiftUI

struct ZhulongInlineTaskDraftState: Equatable {
    struct Subtask: Identifiable, Hashable {
        let id: UUID
        var title: String
        var difficulty: SubtaskDifficulty
    }

    struct Task: Identifiable, Hashable {
        enum Destination: String, CaseIterable {
            case taskPool
            case today
            case future
        }

        let id: ZhulongTodoDiffItemID
        var title: String
        var descriptionText: String
        var note: String
        var destination: Destination
        var targetDateText: String
        var subtasks: [Subtask]
    }

    enum ValidationError: Error {
        case emptyPlan
        case missingTitle
        case missingSubtaskTitle
        case invalidDate
    }

    var sourceDraftID: ZhulongTodoDiffID
    private let originalItems: [ZhulongTodoDiffItem]
    var tasks: [Task]

    init?(
        draft: ZhulongTodoDiffDraft,
        today: LocalDate
    ) {
        let tasks = draft.items.compactMap {
            item -> Task? in
            guard case let .createTask(
                title,
                descriptionText,
                initialNoteBody,
                plannedSubtasks,
                targetDate
            ) = item.operation else {
                return nil
            }
            let destination: Task.Destination = if targetDate == nil {
                .taskPool
            } else if targetDate == today {
                .today
            } else {
                .future
            }
            return Task(
                id: item.id,
                title: title,
                descriptionText: descriptionText ?? "",
                note: initialNoteBody ?? "",
                destination: destination,
                targetDateText:
                targetDate == today
                    ? ""
                    : targetDate?.description ?? "",
                subtasks: plannedSubtasks.map {
                    Subtask(
                        id: UUID(),
                        title: $0.title,
                        difficulty: $0.difficulty
                    )
                }
            )
        }
        guard tasks.count == draft.items.count else {
            return nil
        }
        sourceDraftID = draft.id
        originalItems = draft.items
        self.tasks = tasks
    }

    func isModified(today: LocalDate) -> Bool {
        (try? makeItems(today: today)) != originalItems
    }

    func makeItems(today: LocalDate) throws -> [ZhulongTodoDiffItem] {
        guard tasks.isEmpty == false else {
            throw ValidationError.emptyPlan
        }
        return try tasks.map { task in
            let title = task.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard title.isEmpty == false else {
                throw ValidationError.missingTitle
            }
            let subtasks = try task.subtasks.map { subtask in
                let title = subtask.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard title.isEmpty == false else {
                    throw ValidationError.missingSubtaskTitle
                }
                return try ZhulongPlannedSubtaskDraft(
                    title: title,
                    difficulty: subtask.difficulty
                )
            }
            let targetDate: LocalDate? = switch task.destination {
            case .taskPool:
                nil
            case .today:
                today
            case .future:
                try futureDate(
                    task.targetDateText,
                    today: today
                )
            }
            return ZhulongTodoDiffItem(
                id: task.id,
                operation: .createTask(
                    title: title,
                    descriptionText: normalizedOptional(
                        task.descriptionText
                    ),
                    initialNoteBody: normalizedOptional(task.note),
                    plannedSubtasks: subtasks,
                    targetDate: targetDate
                )
            )
        }
    }

    mutating func addTask() {
        tasks.append(
            Task(
                id: ZhulongTodoDiffItemID(),
                title: "",
                descriptionText: "",
                note: "",
                destination: .taskPool,
                targetDateText: "",
                subtasks: []
            )
        )
    }

    private func normalizedOptional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private func parseLocalDate(_ value: String) throws -> LocalDate {
        guard let date = LocalDate(
            validatingISO8601Date: value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
        else {
            throw ValidationError.invalidDate
        }
        return date
    }

    private func futureDate(
        _ value: String,
        today: LocalDate
    ) throws -> LocalDate {
        let date = try parseLocalDate(value)
        guard date > today else {
            throw ValidationError.invalidDate
        }
        return date
    }
}

struct ZhulongInlineTaskDraftCard: View {
    @Binding var state: ZhulongInlineTaskDraftState

    let language: AppLanguage
    let artifactIdentifier: String
    let isApplied: Bool
    let isUpdating: Bool
    let onSubmit: () -> Void

    private var copy: AppCopy {
        AppCopy(language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(copy.zhulongTaskDraftTitle)
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(
                    isApplied
                        ? copy.zhulongTaskDraftCommittedStatus
                        : isUpdating
                        ? copy.zhulongTaskDraftUpdatingStatus
                        : copy.zhulongTaskDraftEditableStatus
                )
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(isApplied ? Theme.ok : Theme.accent)
                Spacer()
                Text(
                    copy.zhulongTaskDraftTaskCount(state.tasks.count)
                )
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
            }
            .padding(.bottom, 16)

            ForEach($state.tasks) { task in
                taskEditor(task: task)
                if task.wrappedValue.id != state.tasks.last?.id {
                    RailDivider()
                        .padding(.vertical, 16)
                }
            }

            if isApplied == false, isUpdating == false {
                Button {
                    state.addTask()
                } label: {
                    Label(
                        copy.addZhulongTaskDraftTask,
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 16)

                HStack(spacing: 12) {
                    Text(
                        copy.zhulongTaskDraftRevisionHint
                    )
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    Spacer()
                    SmallActionButton(
                        copy.commitZhulongTaskDraft,
                        tone: .accent,
                        action: onSubmit
                    )
                    .accessibilityIdentifier(
                        "zhulong-inline-task-draft-submit-\(artifactIdentifier)"
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "zhulong-inline-task-draft-submit-anchor-\(artifactIdentifier)",
                            verificationText:
                            copy.commitZhulongTaskDraft
                        )
                    }
                }
                .padding(.top, 16)
            } else if isApplied {
                Label(
                    copy.zhulongTaskDraftAppliedNotice,
                    systemImage: "checkmark.circle.fill"
                )
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ok)
                .padding(.top, 16)
            } else {
                Label(
                    copy.zhulongTaskDraftUpdatingNotice,
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 16)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isApplied
                        ? Theme.ok.opacity(0.25)
                        : Theme.accentStroke
                )
        )
        .accessibilityIdentifier(
            "zhulong-inline-task-draft-\(artifactIdentifier)"
        )
        .disabled(isApplied || isUpdating)
        .background {
            AppE2EViewAnchor(
                identifier:
                "zhulong-inline-task-draft-anchor-\(artifactIdentifier)",
                verificationText:
                copy.zhulongTaskDraftTitle
            )
        }
    }

    private func taskEditor(
        task: Binding<ZhulongInlineTaskDraftState.Task>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.noonmarkSystem(size: 13))
                    .foregroundStyle(Theme.accent)

                IMECompositionIsolatedTextField(
                    text: task.title,
                    placeholder:
                    copy.zhulongTaskTitlePlaceholder,
                    font: .noonmarkSystemFont(
                        ofSize: 13,
                        weight: .semibold
                    ),
                    textColor: .labelColor,
                    nativeAccessibilityIdentifier:
                    taskInputIdentifier(
                        task.wrappedValue.id,
                        field: "title"
                    )
                )
                .frame(height: 16)
                .accessibilityIdentifier(
                    taskInputIdentifier(
                        task.wrappedValue.id,
                        field: "title"
                    )
                )
                .background {
                    AppE2EViewAnchor(
                        identifier: taskInputIdentifier(
                            task.wrappedValue.id,
                            field: "title"
                        ),
                        verificationText: task.wrappedValue.title
                    )
                }

                if state.tasks.count > 1 {
                    Button {
                        state.tasks.removeAll {
                            $0.id == task.wrappedValue.id
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                }
            }

            IMECompositionIsolatedTextField(
                text: task.descriptionText,
                placeholder:
                copy.zhulongTaskDescriptionPlaceholder,
                font: .noonmarkSystemFont(
                    ofSize: 11.5
                ),
                textColor: .secondaryLabelColor,
                nativeAccessibilityIdentifier:
                taskInputIdentifier(
                    task.wrappedValue.id,
                    field: "description"
                )
            )
            .frame(height: 13)
            .padding(.leading, 22)
            .accessibilityIdentifier(
                taskInputIdentifier(
                    task.wrappedValue.id,
                    field: "description"
                )
            )
            .background {
                AppE2EViewAnchor(
                    identifier: taskInputIdentifier(
                        task.wrappedValue.id,
                        field: "description"
                    ),
                    verificationText:
                    task.wrappedValue.descriptionText
                )
            }

            IMECompositionIsolatedTextField(
                text: task.note,
                placeholder:
                copy.zhulongTaskNotePlaceholder,
                font: .noonmarkSystemFont(
                    ofSize: 11.5
                ),
                textColor: .secondaryLabelColor,
                nativeAccessibilityIdentifier:
                taskInputIdentifier(
                    task.wrappedValue.id,
                    field: "note"
                )
            )
            .frame(height: 13)
            .padding(.leading, 22)
            .accessibilityIdentifier(
                taskInputIdentifier(
                    task.wrappedValue.id,
                    field: "note"
                )
            )
            .background {
                AppE2EViewAnchor(
                    identifier: taskInputIdentifier(
                        task.wrappedValue.id,
                        field: "note"
                    ),
                    verificationText: task.wrappedValue.note
                )
            }

            HStack(spacing: 8) {
                Picker(
                    "",
                    selection: task.destination
                ) {
                    Text(copy.zhulongTaskPoolDestination)
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.taskPool
                        )
                    Text(copy.zhulongTaskTodayDestination)
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.today
                        )
                    Text(copy.zhulongTaskFutureDestination)
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.future
                        )
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)

                if task.wrappedValue.destination == .future {
                    IMECompositionIsolatedTextField(
                        text: task.targetDateText,
                        placeholder: "YYYY-MM-DD",
                        font: .noonmarkSystemFont(
                            ofSize: 13
                        ),
                        textColor: .labelColor,
                        nativeAccessibilityIdentifier:
                        taskInputIdentifier(
                            task.wrappedValue.id,
                            field: "target-date"
                        ),
                        surface: .rounded
                    )
                    .frame(width: 118)
                    .accessibilityIdentifier(
                        taskInputIdentifier(
                            task.wrappedValue.id,
                            field: "target-date"
                        )
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier: taskInputIdentifier(
                                task.wrappedValue.id,
                                field: "target-date"
                            ),
                            verificationText:
                            task.wrappedValue.targetDateText
                        )
                    }
                }
                Spacer()
            }
            .padding(.leading, 22)

            if task.wrappedValue.subtasks.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        Array(
                            task.wrappedValue.subtasks.indices
                        ),
                        id: \.self
                    ) { index in
                        subtaskEditor(
                            subtask: task.subtasks[index],
                            task: task,
                            accessibilityIdentifier:
                            "zhulong-inline-subtask."
                                + taskIdentifierSuffix(
                                    task.wrappedValue.id
                                )
                                + "."
                                + "\(index).title"
                        )
                    }
                }
                .padding(.leading, 22)
            }

            Button {
                task.wrappedValue.subtasks.append(
                    .init(
                        id: UUID(),
                        title: "",
                        difficulty: .simple
                    )
                )
            } label: {
                Label(
                    copy.addZhulongSubtask,
                    systemImage: "plus"
                )
            }
            .buttonStyle(.plain)
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text3)
            .padding(.leading, 22)
        }
    }

    private func taskInputIdentifier(
        _ id: ZhulongTodoDiffItemID,
        field: String
    ) -> String {
        "zhulong-inline-task."
            + taskIdentifierSuffix(id)
            + ".\(field)"
    }

    private func taskIdentifierSuffix(
        _ id: ZhulongTodoDiffItemID
    ) -> String {
        id.rawValue.uuidString.lowercased()
    }

    private func subtaskEditor(
        subtask: Binding<ZhulongInlineTaskDraftState.Subtask>,
        task: Binding<ZhulongInlineTaskDraftState.Task>,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: SubtaskRowMetrics.controlSpacing) {
            Image(systemName: "arrow.turn.down.right")
                .font(.noonmarkSystem(size: 9))
                .foregroundStyle(Theme.text3)
            IMECompositionIsolatedTextField(
                text: subtask.title,
                placeholder:
                copy.zhulongSubtaskPlaceholder,
                font: .noonmarkSystemFont(
                    ofSize: 11.5
                ),
                textColor: .secondaryLabelColor,
                nativeAccessibilityIdentifier:
                accessibilityIdentifier
            )
            .frame(height: 13)
            .accessibilityIdentifier(accessibilityIdentifier)
            .background {
                AppE2EViewAnchor(
                    identifier: accessibilityIdentifier,
                    verificationText: subtask.wrappedValue.title
                )
            }
            SubtaskDifficultyDotMenu(
                difficulty: subtask.wrappedValue.difficulty,
                copy: copy,
                isEnabled: isApplied == false && isUpdating == false,
                accessibilityIdentifier: "\(accessibilityIdentifier).difficulty"
            ) { difficulty in
                subtask.wrappedValue.difficulty = difficulty
            }
            Button {
                task.wrappedValue.subtasks.removeAll {
                    $0.id == subtask.wrappedValue.id
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text3)
        }
    }
}

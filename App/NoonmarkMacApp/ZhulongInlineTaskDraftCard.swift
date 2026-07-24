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

    let sourceDraftID: ZhulongTodoDiffID
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

    private var isChinese: Bool {
        language == .chinese
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(isChinese ? "任务草稿" : "Task draft")
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(
                    isApplied
                        ? (isChinese ? "已提交" : "Committed")
                        : isUpdating
                        ? (isChinese
                            ? "烛龙正在更新"
                            : "Zhulong is updating")
                        : (isChinese ? "可直接编辑" : "Editable")
                )
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(isApplied ? Theme.ok : Theme.accent)
                Spacer()
                Text(
                    isChinese
                        ? "\(state.tasks.count) 个任务"
                        : "\(state.tasks.count) tasks"
                )
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
            }
            .padding(.bottom, 14)

            ForEach($state.tasks) { task in
                taskEditor(task: task)
                if task.wrappedValue.id != state.tasks.last?.id {
                    Divider()
                        .overlay(Theme.line.opacity(0.72))
                        .padding(.vertical, 14)
                }
            }

            if isApplied == false, isUpdating == false {
                Button {
                    state.addTask()
                } label: {
                    Label(
                        isChinese ? "增加任务" : "Add task",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 14)

                HStack(spacing: 12) {
                    Text(
                        isChinese
                            ? "继续对话可以调整方案；说“提交”也会执行当前可见版本。"
                            : "Keep chatting to revise, or say “commit” to apply this visible version."
                    )
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    Spacer()
                    Button(
                        isChinese ? "提交任务" : "Commit tasks",
                        action: onSubmit
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "zhulong-inline-task-draft-submit-\(artifactIdentifier)"
                    )
                    .background {
                        AppE2EViewAnchor(
                            identifier:
                            "zhulong-inline-task-draft-submit-anchor-\(artifactIdentifier)",
                            verificationText:
                            isChinese ? "提交任务" : "Commit tasks"
                        )
                    }
                }
                .padding(.top, 16)
            } else if isApplied {
                Label(
                    isChinese
                        ? "这些任务已经写入对应的任务池、Day Todo 或未来计划。"
                        : "These tasks were written to their selected destinations.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ok)
                .padding(.top, 16)
            } else {
                Label(
                    isChinese
                        ? "当前可见版本已保存；烛龙返回修订前暂不可编辑。"
                        : "This visible version is saved and locked until Zhulong returns the revision.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 16)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isApplied
                        ? Theme.ok.opacity(0.25)
                        : Theme.accent.opacity(0.22)
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
                isChinese ? "任务草稿" : "Task draft"
            )
        }
    }

    private func taskEditor(
        task: Binding<ZhulongInlineTaskDraftState.Task>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "circle")
                    .font(.noonmarkSystem(size: 13))
                    .foregroundStyle(Theme.accent)

                TextField(
                    isChinese ? "任务标题" : "Task title",
                    text: task.title
                )
                .textFieldStyle(.plain)
                .font(.noonmarkSystem(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text1)

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

            TextField(
                isChinese ? "补充目标或完成标准（可选）" : "Goal or completion criteria (optional)",
                text: task.descriptionText
            )
            .textFieldStyle(.plain)
            .font(.noonmarkSystem(size: 11.5))
            .foregroundStyle(Theme.text2)
            .padding(.leading, 22)

            TextField(
                isChinese ? "附言（可选）" : "Note (optional)",
                text: task.note
            )
            .textFieldStyle(.plain)
            .font(.noonmarkSystem(size: 11.5))
            .foregroundStyle(Theme.text2)
            .padding(.leading, 22)

            HStack(spacing: 8) {
                Picker(
                    "",
                    selection: task.destination
                ) {
                    Text(isChinese ? "任务池" : "Task Pool")
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.taskPool
                        )
                    Text(isChinese ? "今天" : "Today")
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.today
                        )
                    Text(isChinese ? "未来日期" : "Future")
                        .tag(
                            ZhulongInlineTaskDraftState.Task
                                .Destination.future
                        )
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)

                if task.wrappedValue.destination == .future {
                    TextField(
                        "YYYY-MM-DD",
                        text: task.targetDateText
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 118)
                }
                Spacer()
            }
            .padding(.leading, 22)

            if task.wrappedValue.subtasks.isEmpty == false {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(task.subtasks) { subtask in
                        subtaskEditor(
                            subtask: subtask,
                            task: task
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
                    isChinese ? "增加子任务" : "Add subtask",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.plain)
            .font(.noonmarkSystem(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.text3)
            .padding(.leading, 22)
        }
    }

    private func subtaskEditor(
        subtask: Binding<ZhulongInlineTaskDraftState.Subtask>,
        task: Binding<ZhulongInlineTaskDraftState.Task>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.noonmarkSystem(size: 9))
                .foregroundStyle(Theme.text3)
            TextField(
                isChinese ? "子任务" : "Subtask",
                text: subtask.title
            )
            .textFieldStyle(.plain)
            .font(.noonmarkSystem(size: 11.5))
            .foregroundStyle(Theme.text2)
            Picker("", selection: subtask.difficulty) {
                Text(isChinese ? "简" : "S")
                    .tag(SubtaskDifficulty.simple)
                Text(isChinese ? "中" : "M")
                    .tag(SubtaskDifficulty.medium)
                Text(isChinese ? "难" : "H")
                    .tag(SubtaskDifficulty.hard)
            }
            .labelsHidden()
            .frame(width: 54)
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

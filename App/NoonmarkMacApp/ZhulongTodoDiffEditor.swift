import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkZhulong
import SwiftUI

struct ZhulongTodoDiffEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: NoonmarkStore
    @State private var items: [EditableTodoDiffItem]
    @State private var validationMessage: String?

    let version: Int
    let onSave: ([ZhulongTodoDiffItem]) -> Bool

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    init(
        diff: ZhulongTodoDiffDraft,
        onSave: @escaping ([ZhulongTodoDiffItem]) -> Bool
    ) {
        version = diff.version
        self.onSave = onSave
        _items = State(initialValue: diff.items.map(EditableTodoDiffItem.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.todoEditorTitle)
                    .font(.noonmarkSystem(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(copy.todoRevisionSubtitle(version: version))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            .padding(18)

            RailDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($items) { $item in
                        editorRow(item: $item)
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.noonmarkSystem(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.warn)
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 440)

            RailDivider()

            HStack(spacing: 8) {
                Text(copy.todoRevisionBoundary)
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button(copy.cancelAction) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(copy.saveNewVersionAction) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
                    .accessibilityIdentifier("zhulong-save-todo-diff-revision")
            }
            .padding(14)
        }
        .frame(width: 640)
        .background(Theme.background)
        .accessibilityIdentifier("zhulong-todo-diff-editor")
    }

    private func editorRow(item: Binding<EditableTodoDiffItem>) -> some View {
        let value = item.wrappedValue
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: value.symbolName)
                    .foregroundStyle(Theme.accent)
                Text(value.kindLabel(copy: copy))
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer()
                if value.canSplit {
                    Button(copy.splitAction) { split(value.id) }
                        .buttonStyle(.borderless)
                        .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                        .accessibilityIdentifier(
                            "zhulong-split-todo-diff-item-\(value.identifierSuffix)"
                        )
                }
                Button {
                    remove(value.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.warn)
                .disabled(items.count == 1)
                .accessibilityLabel(copy.removeTodoChangeAccessibilityLabel)
            }

            if value.hasEditableTitle {
                MarkdownEditor(
                    text: item.title,
                    placeholder: copy.taskTitlePlaceholder,
                    style: .title,
                    showsSurface: true
                )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityIdentifier(
                        "zhulong-todo-diff-title-\(value.identifierSuffix)"
                    )
            } else {
                Text(value.fixedDescription(copy: copy))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text2)
            }

            if value.hasEditableDate {
                HStack(spacing: 8) {
                    Text(copy.targetDateTitle(required: value.requiresDate))
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    TextField(copy.isoDatePlaceholder, text: item.targetDateText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 142)
                        .accessibilityIdentifier(
                            "zhulong-todo-diff-target-date-\(value.identifierSuffix)"
                        )
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }

    private func remove(_ id: ZhulongTodoDiffItemID) {
        guard items.count > 1 else { return }
        items.removeAll { $0.id == id }
        validationMessage = nil
    }

    private func split(_ id: ZhulongTodoDiffItemID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let second = items[index].splitCopy(copy: copy)
        else { return }
        items[index].title += copy.todoTitlePart(1)
        items.insert(second, at: index + 1)
        validationMessage = nil
    }

    private func save() {
        do {
            let revisedItems = try items.map { try $0.makeDiffItem() }
            if onSave(revisedItems) {
                dismiss()
            }
        } catch let error as EditableTodoDiffItem.ValidationError {
            validationMessage = copy.todoValidationMessage(error.presentationFailure)
        } catch {
            validationMessage = copy.todoValidationMessage(.revisionFailed)
        }
    }
}

private struct EditableTodoDiffItem: Identifiable {
    enum Kind {
        case createTask(
            descriptionText: String?,
            initialNoteBody: String?,
            plannedSubtasks: [ZhulongPlannedSubtaskDraft]
        )
        case addSubtask(traceID: DayTraceID, difficulty: SubtaskDifficulty)
        case scheduleFromPool(chainID: TaskChainID)
        case continueTrace(traceID: DayTraceID)
        case abandonChain(traceID: DayTraceID)
    }

    enum ValidationError: Error {
        case missingTitle
        case invalidDate

        var presentationFailure: ZhulongTodoValidationFailure {
            switch self {
            case .missingTitle: .missingTitle
            case .invalidDate: .invalidDate
            }
        }
    }

    let id: ZhulongTodoDiffItemID
    var kind: Kind
    var title: String
    var targetDateText: String

    var identifierSuffix: String { id.rawValue.uuidString.lowercased() }

    init(_ item: ZhulongTodoDiffItem) {
        id = item.id
        switch item.operation {
        case let .createTask(title, descriptionText, initialNoteBody, plannedSubtasks, targetDate):
            kind = .createTask(
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                plannedSubtasks: plannedSubtasks
            )
            self.title = title
            targetDateText = targetDate?.description ?? ""
        case let .addSubtask(traceID, title, difficulty):
            kind = .addSubtask(traceID: traceID, difficulty: difficulty)
            self.title = title
            targetDateText = ""
        case let .scheduleFromPool(chainID, targetDate):
            kind = .scheduleFromPool(chainID: chainID)
            title = ""
            targetDateText = targetDate.description
        case let .continueTrace(traceID, targetDate):
            kind = .continueTrace(traceID: traceID)
            title = ""
            targetDateText = targetDate.description
        case let .abandonChain(traceID):
            kind = .abandonChain(traceID: traceID)
            title = ""
            targetDateText = ""
        }
    }

    private init(
        id: ZhulongTodoDiffItemID,
        kind: Kind,
        title: String,
        targetDateText: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.targetDateText = targetDateText
    }

    var canSplit: Bool {
        if case .createTask = kind { return true }
        return false
    }

    var hasEditableTitle: Bool {
        switch kind {
        case .createTask, .addSubtask: true
        default: false
        }
    }

    var hasEditableDate: Bool {
        switch kind {
        case .createTask, .scheduleFromPool, .continueTrace: true
        default: false
        }
    }

    var requiresDate: Bool {
        switch kind {
        case .scheduleFromPool, .continueTrace: true
        default: false
        }
    }

    private var copyKey: ZhulongTodoEditorKindCopyKey {
        switch kind {
        case .createTask: .createTask
        case .addSubtask: .addSubtask
        case .scheduleFromPool: .scheduleFromPool
        case .continueTrace: .continueTrace
        case .abandonChain: .abandonChain
        }
    }

    func kindLabel(copy: ZhulongCopy) -> String {
        copy.todoEditorKindTitle(copyKey)
    }

    var symbolName: String {
        switch kind {
        case .createTask: "plus.circle"
        case .addSubtask: "list.bullet.indent"
        case .scheduleFromPool, .continueTrace: "calendar.badge.clock"
        case .abandonChain: "archivebox"
        }
    }

    func fixedDescription(copy: ZhulongCopy) -> String {
        copy.todoEditorFixedDescription(copyKey)
    }

    func splitCopy(copy: ZhulongCopy) -> Self? {
        guard case let .createTask(descriptionText, initialNoteBody, _) = kind else { return nil }
        return Self(
            id: ZhulongTodoDiffItemID(),
            kind: .createTask(
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                plannedSubtasks: []
            ),
            title: title + copy.todoTitlePart(2),
            targetDateText: targetDateText
        )
    }

    func makeDiffItem() throws -> ZhulongTodoDiffItem {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasEditableTitle, normalizedTitle.isEmpty {
            throw ValidationError.missingTitle
        }
        let targetDate = try parseTargetDate()
        let operation: ZhulongTodoDiffOperation = switch kind {
        case let .createTask(descriptionText, initialNoteBody, plannedSubtasks):
            .createTask(
                title: normalizedTitle,
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                plannedSubtasks: plannedSubtasks,
                targetDate: targetDate
            )
        case let .addSubtask(traceID, difficulty):
            .addSubtask(traceID: traceID, title: normalizedTitle, difficulty: difficulty)
        case let .scheduleFromPool(chainID):
            .scheduleFromPool(chainID: chainID, targetDate: try required(targetDate))
        case let .continueTrace(traceID):
            .continueTrace(traceID: traceID, targetDate: try required(targetDate))
        case let .abandonChain(traceID):
            .abandonChain(traceID: traceID)
        }
        return ZhulongTodoDiffItem(id: id, operation: operation)
    }

    private func parseTargetDate() throws -> LocalDate? {
        let normalized = targetDateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            if requiresDate { throw ValidationError.invalidDate }
            return nil
        }
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1 ... 12).contains(month),
              (1 ... 31).contains(day)
        else { throw ValidationError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else {
            throw ValidationError.invalidDate
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            throw ValidationError.invalidDate
        }
        return LocalDate(year: year, month: month, day: day)
    }

    private func required(_ date: LocalDate?) throws -> LocalDate {
        guard let date else { throw ValidationError.invalidDate }
        return date
    }
}

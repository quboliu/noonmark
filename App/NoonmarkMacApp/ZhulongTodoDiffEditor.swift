import NoonmarkCore
import NoonmarkZhulong
import SwiftUI

struct ZhulongTodoDiffEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [EditableTodoDiffItem]
    @State private var validationMessage: String?

    let version: Int
    let onSave: ([ZhulongTodoDiffItem]) -> Bool

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
            VStack(alignment: .leading, spacing: 5) {
                Text("审查 Todo 变更")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("基于 v\(version) 建立新修订；原版本继续保留在会话日志中。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($items) { $item in
                        editorRow(item: $item)
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.warn)
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 440)

            Divider()

            HStack(spacing: 8) {
                Text("保存修订不会写入 Todo；整批应用仍需再次确认。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存为新版本") { save() }
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
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: value.symbolName)
                    .foregroundStyle(Theme.accent)
                Text(value.kindLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                Spacer()
                if value.canSplit {
                    Button("拆分") { split(value.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5, weight: .semibold))
                        .accessibilityIdentifier("zhulong-split-todo-diff-item")
                }
                Button {
                    remove(value.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.warn)
                .disabled(items.count == 1)
                .accessibilityLabel("移除这项 Todo 变更")
            }

            if value.hasEditableTitle {
                MarkdownEditor(text: item.title, placeholder: "任务标题", style: .title)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                    .accessibilityIdentifier("zhulong-todo-diff-title")
            } else {
                Text(value.fixedDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
            }

            if value.hasEditableDate {
                HStack(spacing: 8) {
                    Text(value.requiresDate ? "目标日期" : "目标日期（可留空）")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    TextField("YYYY-MM-DD", text: item.targetDateText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 142)
                        .accessibilityIdentifier("zhulong-todo-diff-target-date")
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }

    private func remove(_ id: ZhulongTodoDiffItemID) {
        guard items.count > 1 else { return }
        items.removeAll { $0.id == id }
        validationMessage = nil
    }

    private func split(_ id: ZhulongTodoDiffItemID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let second = items[index].splitCopy()
        else { return }
        items[index].title += "（部分 1）"
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
            validationMessage = error.message
        } catch {
            validationMessage = "无法建立修订：\(error.localizedDescription)"
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

        var message: String {
            switch self {
            case .missingTitle: "任务标题不能为空。"
            case .invalidDate: "目标日期必须是有效的 YYYY-MM-DD。"
            }
        }
    }

    let id: ZhulongTodoDiffItemID
    var kind: Kind
    var title: String
    var targetDateText: String

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

    var kindLabel: String {
        switch kind {
        case .createTask: "创建任务"
        case .addSubtask: "添加子任务"
        case .scheduleFromPool: "任务池排期"
        case .continueTrace: "延续任务"
        case .abandonChain: "废弃任务链"
        }
    }

    var symbolName: String {
        switch kind {
        case .createTask: "plus.circle"
        case .addSubtask: "list.bullet.indent"
        case .scheduleFromPool, .continueTrace: "calendar.badge.clock"
        case .abandonChain: "archivebox"
        }
    }

    var fixedDescription: String {
        switch kind {
        case .scheduleFromPool: "将已有任务从任务池排期"
        case .continueTrace: "把未完成任务延续到新日期"
        case .abandonChain: "废弃当前任务链"
        case .createTask, .addSubtask: ""
        }
    }

    func splitCopy() -> Self? {
        guard case let .createTask(descriptionText, initialNoteBody, _) = kind else { return nil }
        return Self(
            id: ZhulongTodoDiffItemID(),
            kind: .createTask(
                descriptionText: descriptionText,
                initialNoteBody: initialNoteBody,
                plannedSubtasks: []
            ),
            title: title + "（部分 2）",
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

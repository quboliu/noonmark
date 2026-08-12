import SwiftUI
import NoonmarkCore

struct IOSTaskDetailView: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let trace: DayTrace
    @State private var title = ""
    @State private var description = ""
    @State private var subtaskDraft = ""
    @State private var noteDraft = ""
    @State private var actionDate = Date()
    @State private var dateAction: DateAction?
    @State private var editingSubtaskID: SubtaskID?
    @State private var subtaskEditText = ""
    @State private var editingNote: TaskNoteEntry?

    private enum DateAction: Identifiable, Equatable {
        case deferTrace
        case reschedule
        var id: Self { self }
    }

    private var currentTrace: DayTrace { store.engine.traces[trace.id] ?? trace }
    private var definition: TaskDefinition? {
        store.engine.definitions[currentTrace.definitionID]
    }

    private var isEditable: Bool {
        currentTrace.status == .pending && currentTrace.date >= store.today
    }

    private var hasSubtasks: Bool {
        store.subtasks(for: currentTrace).isEmpty == false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("ios.task.detail.title")
                        .disabled(isEditable == false)
                    TextField("说明", text: $description, axis: .vertical)
                        .lineLimit(2 ... 8)
                        .accessibilityIdentifier("ios.task.detail.description")
                        .disabled(isEditable == false)
                    Button("保存任务内容") {
                        store.setTraceTitle(currentTrace, title: title)
                        store.setTraceDescription(currentTrace, text: description)
                    }
                    .accessibilityIdentifier("ios.task.detail.save")
                    .disabled(isEditable == false)
                }

                Section("状态") {
                    LabeledContent("日期", value: currentTrace.date.description)
                    LabeledContent("状态", value: currentTrace.status.rawValue)
                    if hasSubtasks {
                        let progress = store.engine.traceProgress(for: currentTrace.id)
                        LabeledContent("进度", value: "\(progress.percent)%")
                    } else {
                        Slider(
                            value: Binding(
                                get: { Double(store.engine.traceProgress(for: currentTrace.id).percent) },
                                set: { store.setManualProgress(for: currentTrace, percent: Int($0.rounded())) }
                            ),
                            in: 0 ... 100,
                            step: 1
                        )
                        .disabled(currentTrace.date == store.today && isEditable == true ? false : true)
                    }
                }

                Section("分类与标签") {
                    IOSClassificationEditor(target: .task(currentTrace.chainID))
                        .environmentObject(store)
                }

                if isEditable {
                    Section("子任务") {
                        ForEach(store.subtasks(for: currentTrace), id: \.id) { subtask in
                            HStack {
                                Button {
                                    store.toggleSubtask(subtask)
                                } label: {
                                    Image(systemName: subtask.status == .completed ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                if editingSubtaskID == subtask.id {
                                    TextField("子任务名称", text: $subtaskEditText)
                                    Button("保存") {
                                        store.renameSubtask(subtask, title: subtaskEditText)
                                        editingSubtaskID = nil
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("ios.task.detail.subtask.save")
                                } else {
                                    Text(subtask.title)
                                        .strikethrough(subtask.status == .completed)
                                        .onTapGesture {
                                            subtaskEditText = subtask.title
                                            editingSubtaskID = subtask.id
                                        }
                                }
                                Spacer()
                                Menu {
                                    ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                                        Button(difficulty.label) {
                                            store.setSubtaskDifficulty(subtask, difficulty: difficulty)
                                        }
                                    }
                                    if subtask.status == .pending {
                                        Button("废弃", role: .destructive) {
                                            store.abandonSubtask(subtask)
                                        }
                                    }
                                } label: {
                                    Text(subtask.difficulty.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    store.deleteSubtask(subtask)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack {
                            TextField("添加子任务", text: $subtaskDraft)
                                .accessibilityIdentifier("ios.task.detail.subtask.add")
                            Button("添加") {
                                store.addSubtask(to: currentTrace, title: subtaskDraft)
                                subtaskDraft = ""
                            }
                            .accessibilityIdentifier("ios.task.detail.subtask.addButton")
                            .disabled(subtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                Section("备注") {
                    ForEach(currentTrace.activeNoteEntries, id: \.id) { note in
                        Text(note.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("编辑") { editingNote = note }
                                Button("删除", role: .destructive) {
                                    store.deleteTraceNote(currentTrace, note: note)
                                }
                            }
                    }
                    HStack {
                        TextField("添加备注", text: $noteDraft)
                            .accessibilityIdentifier("ios.task.detail.note.add")
                        Button("添加") {
                            store.appendTraceNote(currentTrace, body: noteDraft)
                            noteDraft = ""
                        }
                        .accessibilityIdentifier("ios.task.detail.note.addButton")
                        .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isEditable == false)
                    }
                }

                Section("操作") {
                    if currentTrace.status == .pending {
                        Button(currentTrace.pinOrder == nil ? "置顶" : "取消置顶") {
                            if currentTrace.pinOrder == nil {
                                store.pin(currentTrace)
                            } else {
                                store.unpin(currentTrace)
                            }
                        }
                        if currentTrace.date == store.today {
                            Button("完成") { store.toggleCompletion(for: currentTrace) }
                            Button("延期") {
                                actionDate = Date()
                                dateAction = .deferTrace
                            }
                            Button("回到任务池") { store.returnToPool(currentTrace) }
                            Button("上移优先级") { store.movePriority(currentTrace, by: -1) }
                            Button("下移优先级") { store.movePriority(currentTrace, by: 1) }
                        } else if currentTrace.date > store.today {
                            Button("重新排期") {
                                actionDate = Date()
                                dateAction = .reschedule
                            }
                        }
                    } else if currentTrace.status == .completed {
                        Button("撤销完成") { store.toggleCompletion(for: currentTrace) }
                    }
                    Button("复制为新任务") { store.copyAsNewTask(currentTrace) }
                    if store.engine.canDeleteNewCurrentDayTask(traceID: currentTrace.id, today: store.today) {
                        Button("删除今天新建任务", role: .destructive) {
                            store.deleteNewCurrentDayTask(currentTrace)
                            dismiss()
                        }
                    }
                }

                Section("任务轨迹") {
                    if let trail = try? store.engine.taskTrail(chainID: currentTrace.chainID) {
                        ForEach(trail) { entry in
                            HStack {
                                Text(entry.kind.rawValue)
                                Spacer()
                                Text(entry.date?.description ?? "—")
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(definition?.title ?? "任务详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                title = definition?.title ?? ""
                description = currentTrace.descriptionText ?? definition?.descriptionText ?? ""
            }
            .sheet(item: $dateAction) { action in
                NavigationStack {
                    Form {
                        DatePicker(
                            "日期",
                            selection: $actionDate,
                            in: action == .deferTrace ? Date()... : Date()...,
                            displayedComponents: .date
                        )
                    }
                    .navigationTitle(action == .deferTrace ? "延期到" : "重新排期")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let date = LocalDate.fromFoundation(actionDate)
                                if action == .deferTrace {
                                    store.deferTrace(currentTrace, to: date)
                                } else {
                                    store.reschedule(currentTrace, to: date)
                                }
                                dateAction = nil
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingNote) { note in
                IOSNoteEditor(title: "编辑任务备注", body: note.body) { body in
                    store.editTraceNote(currentTrace, note: note, body: body)
                    editingNote = nil
                }
            }
        }
    }
}

struct IOSPoolTaskDetailView: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let task: PoolTask
    @State private var title = ""
    @State private var description = ""
    @State private var subtaskDraft = ""
    @State private var noteDraft = ""
    @State private var editingPlannedSubtaskID: PlannedSubtaskID?
    @State private var plannedSubtaskEditText = ""
    @State private var editingNote: TaskNoteEntry?

    private var currentTask: PoolTask { store.selectedPoolTask ?? task }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("ios.pool.detail.title")
                    TextField("说明", text: $description, axis: .vertical)
                        .lineLimit(2 ... 8)
                        .accessibilityIdentifier("ios.pool.detail.description")
                    Button("保存") {
                        store.setPoolTask(currentTask, title: title, description: description)
                    }
                    .accessibilityIdentifier("ios.pool.detail.save")
                }
                Section("分类与标签") {
                    IOSClassificationEditor(target: .task(currentTask.chain.id))
                        .environmentObject(store)
                }
                Section("计划子任务") {
                    ForEach(currentTask.definition.plannedSubtasks) { subtask in
                        HStack {
                            if editingPlannedSubtaskID == subtask.id {
                                TextField("计划子任务名称", text: $plannedSubtaskEditText)
                                Button("保存") {
                                    store.renamePlannedSubtask(
                                        subtask,
                                        on: currentTask,
                                        title: plannedSubtaskEditText
                                    )
                                    editingPlannedSubtaskID = nil
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("ios.pool.detail.subtask.save")
                            } else {
                                Text(subtask.title)
                                    .onTapGesture {
                                        plannedSubtaskEditText = subtask.title
                                        editingPlannedSubtaskID = subtask.id
                                    }
                            }
                            Spacer()
                            Menu {
                                ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                                    Button(difficulty.label) {
                                        store.setPlannedSubtaskDifficulty(
                                            subtask,
                                            on: currentTask,
                                            difficulty: difficulty
                                        )
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    store.deletePlannedSubtask(subtask, from: currentTask)
                                }
                            } label: {
                                Text(subtask.difficulty.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        TextField("添加计划子任务", text: $subtaskDraft)
                            .accessibilityIdentifier("ios.pool.detail.subtask.add")
                        Button("添加") {
                            store.addPlannedSubtask(to: currentTask, title: subtaskDraft)
                            subtaskDraft = ""
                        }
                        .accessibilityIdentifier("ios.pool.detail.subtask.addButton")
                        .disabled(subtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("备注") {
                    ForEach(currentTask.chain.activeNoteEntries, id: \.id) { note in
                        Text(note.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("编辑") { editingNote = note }
                                Button("删除", role: .destructive) {
                                    store.deletePoolNote(currentTask, note: note)
                                }
                            }
                    }
                    HStack {
                        TextField("添加备注", text: $noteDraft)
                            .accessibilityIdentifier("ios.pool.detail.note.add")
                        Button("添加") {
                            store.appendPoolNote(currentTask, body: noteDraft)
                            noteDraft = ""
                        }
                        .accessibilityIdentifier("ios.pool.detail.note.addButton")
                    }
                }
                Section("操作") {
                    Button("删除任务", role: .destructive) {
                        store.deletePoolTask(currentTask)
                        dismiss()
                    }
                }
            }
            .navigationTitle("任务池详情")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                title = currentTask.definition.title
                description = currentTask.definition.descriptionText ?? ""
            }
            .sheet(item: $editingNote) { note in
                IOSNoteEditor(title: "编辑池中备注", body: note.body) { body in
                    store.editPoolNote(currentTask, note: note, body: body)
                    editingNote = nil
                }
            }
        }
    }
}

struct IOSNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (String) -> Void
    @State private var draftBody: String

    init(title: String, body: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _draftBody = State(initialValue: body)
    }

    var bodyView: some View {
        Form {
            TextEditor(text: $draftBody)
                .frame(minHeight: 160)
                .accessibilityIdentifier("ios.note.editor")
        }
    }

    var body: some View {
        NavigationStack {
            bodyView
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(draftBody)
                            dismiss()
                        }
                        .disabled(draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private extension LocalDate {
    static func fromFoundation(_ date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return LocalDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }
}

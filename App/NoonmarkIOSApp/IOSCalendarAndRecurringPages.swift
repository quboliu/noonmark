import SwiftUI
import NoonmarkCore

struct IOSCalendarPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var reviewIsPresented = false

    private var monthTitle: String {
        let date = FoundationCalendar.date(for: store.selectedDate)
        return date.formatted(.dateTime.year().month(.wide))
    }

    private var monthDays: [LocalDate?] {
        FoundationCalendar.monthGrid(containing: store.selectedDate)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button {
                        store.moveSelectedMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("上个月")
                    Spacer()
                    Text(monthTitle).font(.headline)
                    Spacer()
                    Button {
                        store.moveSelectedMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("下个月")
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible()), count: 7),
                    spacing: 8
                ) {
                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(monthDays.enumerated()), id: \.offset) { _, date in
                        if let date {
                            let summary = store.engine.calendarSummary(for: date)
                            Button {
                                store.selectedDate = date
                            } label: {
                                VStack(spacing: 3) {
                                    Text("\(date.day)")
                                    Circle()
                                        .fill(heatColor(summary.heatLevel))
                                        .frame(width: 6, height: 6)
                                }
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(
                                    date == store.selectedDate
                                        ? IOSTheme.accent.opacity(0.16)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ios.calendar.\(date.description)")
                        } else {
                            Color.clear.frame(minHeight: 40)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                Text("\(store.selectedDate.description) 统计")
                    .font(.headline)
                let summary = store.engine.calendarSummary(for: store.selectedDate)
                LabeledContent("总数", value: "\(summary.total)")
                LabeledContent("完成", value: "\(summary.completed)")
                LabeledContent("待办", value: "\(summary.pending)")
                LabeledContent("未完成", value: "\(summary.unfinished)")
                Button("编辑日复盘") { reviewIsPresented = true }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.panel, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text("当天轨迹")
                    .font(.headline)
                ForEach(store.engine.calendarTraces(for: store.selectedDate), id: \.id) { trace in
                    Button {
                        store.selectedTraceID = trace.id
                    } label: {
                        HStack {
                            Image(systemName: trace.status == .completed ? "checkmark.circle.fill" : "circle")
                            Text(store.engine.definitions[trace.definitionID]?.title ?? "无标题")
                            Spacer()
                            Text(trace.status.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding()
        }
        .navigationTitle("日历")
        .sheet(isPresented: $reviewIsPresented) {
            IOSDailyReviewEditor(date: store.selectedDate)
                .environmentObject(store)
        }
    }

    private func heatColor(_ level: Int) -> Color {
        switch level {
        case 4: .green
        case 3: .green.opacity(0.75)
        case 2: .orange.opacity(0.8)
        case 1: .orange.opacity(0.45)
        default: IOSTheme.line
        }
    }
}

struct IOSDailyReviewEditor: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let date: LocalDate
    @State private var summary = ""
    @State private var unfinishedReason = ""
    @State private var tomorrowNote = ""

    var body: some View {
        NavigationStack {
            Form {
                Text("复盘 \(date.description)")
                    .font(.headline)
                TextField("今天完成了什么", text: $summary, axis: .vertical)
                    .lineLimit(3 ... 8)
                    .accessibilityIdentifier("ios.daily.review.summary")
                TextField("未完成原因", text: $unfinishedReason, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .accessibilityIdentifier("ios.daily.review.unfinished")
                TextField("明天要记得什么", text: $tomorrowNote, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .accessibilityIdentifier("ios.daily.review.tomorrow")
            }
            .navigationTitle("日复盘")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateDailyReview(
                            summary: summary,
                            unfinishedReason: unfinishedReason,
                            tomorrowNote: tomorrowNote
                        )
                        dismiss()
                    }
                    .accessibilityIdentifier("ios.daily.review.save")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                let day = store.engine.days[date]
                summary = day?.reviewSummary ?? ""
                unfinishedReason = day?.reviewUnfinishedReason ?? ""
                tomorrowNote = day?.reviewTomorrowNote ?? ""
            }
        }
    }
}

struct IOSRecurringPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var editor: RecurringEditorMode?

    private enum RecurringEditorMode: Identifiable {
        case create
        case edit(TaskCycleTrack)
        var id: String {
            switch self {
            case .create: "create"
            case let .edit(track): "edit-\(track.id)"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    editor = .create
                } label: {
                    Label("新建重复计划", systemImage: "plus")
                }
            }
            if store.taskCycleTracks.isEmpty {
                ContentUnavailableView(
                    "还没有重复计划",
                    systemImage: "repeat",
                    description: Text("重复计划会在这里显示完整轨迹。")
                )
            } else {
                ForEach(store.taskCycleTracks) { track in
                    cycleSection(track)
                }
            }
        }
        .navigationTitle("重复计划")
        .sheet(item: $editor) { mode in
            switch mode {
            case .create:
                IOSRecurringEditor()
                    .environmentObject(store)
            case let .edit(track):
                IOSRecurringEditor(track: track)
                    .environmentObject(store)
            }
        }
    }

    private func cycleSection(_ track: TaskCycleTrack) -> some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已排期 \(track.scheduledCount) · 完成 \(track.completedCount) · 待办 \(track.futurePlanCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ios.recurring.scheduled.\(track.id)")
                    ForEach(track.days) { day in
                        HStack {
                            Image(systemName: cycleSymbol(day.state))
                                .foregroundStyle(cycleColor(day.state))
                            Text(day.date.description)
                            Spacer()
                            Text(cycleState(day.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if day.date > store.today, day.state == .planned {
                                Button("跳过") {
                                    store.skipTaskCycleOccurrence(track, on: day.date)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let target = day.navigationTarget {
                                store.selectedTraceID = target.traceID
                            }
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.body.weight(.medium))
                    Text("\(track.startDate.description) – \(track.endDate.description) · \(scheduleText(track.schedule))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("编辑") { editor = .edit(track) }
                if track.canStop {
                    Button("停止", role: .destructive) { store.stopTaskCycle(track) }
                }
            }
        }
    }

    private func cycleSymbol(_ state: TaskCycleTrackDayState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .planned, .pendingToday, .pendingPast: "circle"
        case .skipped: "slash.circle"
        case .unfinished: "exclamationmark.circle"
        default: "minus.circle"
        }
    }

    private func cycleColor(_ state: TaskCycleTrackDayState) -> Color {
        switch state {
        case .completed: .green
        case .skipped, .abandoned: .secondary
        case .unfinished: .orange
        default: IOSTheme.accent
        }
    }

    private func cycleState(_ state: TaskCycleTrackDayState) -> String {
        switch state {
        case .notScheduled: "未排期"
        case .pendingPast: "过去待办"
        case .pendingToday: "今天"
        case .planned: "已计划"
        case .completed: "已完成"
        case .unfinished: "未完成"
        case .deferred: "已延期"
        case .changed: "已变更"
        case .returnedToPool: "已回池"
        case .skipped: "已跳过"
        case .abandoned: "已废弃"
        }
    }

    private func scheduleText(_ schedule: TaskCycleSchedule) -> String {
        switch schedule {
        case let .everyDays(interval): "每 \(interval) 天"
        case let .selectedWeekdays(weekdays, everyWeeks):
            "每 \(everyWeeks) 周 · \(weekdays.map(weekdayText).sorted().joined(separator: "、"))"
        }
    }

    private func weekdayText(_ weekday: TaskCycleWeekday) -> String {
        [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"][weekday.rawValue] ?? "?"
    }
}

struct IOSRecurringEditor: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.dismiss) private var dismiss
    let track: TaskCycleTrack?
    @State private var title = ""
    @State private var description = ""
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var endConditionMode = 0
    @State private var durationDays = 7
    @State private var completionTargetCount = 5
    @State private var completionLatestDate = Date()
    @State private var scheduleMode = 0
    @State private var interval = 1
    @State private var selectedWeekdays: Set<TaskCycleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var everyWeeks = 1
    @State private var plannedSubtasks: [PlannedSubtask] = []
    @State private var plannedSubtaskDraft = ""
    @State private var editingPlannedSubtaskID: PlannedSubtaskID?
    @State private var plannedSubtaskEditText = ""

    init(track: TaskCycleTrack? = nil) {
        self.track = track
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("标题", text: $title)
                        .accessibilityIdentifier("ios.recurring.editor.title")
                    TextField("说明", text: $description, axis: .vertical)
                        .lineLimit(2 ... 5)
                        .accessibilityIdentifier("ios.recurring.editor.description")
                }
                Section("计划子任务") {
                    ForEach(plannedSubtasks) { subtask in
                        HStack {
                            if editingPlannedSubtaskID == subtask.id {
                                TextField("计划子任务名称", text: $plannedSubtaskEditText)
                                Button("保存") {
                                    renamePlannedSubtask(subtask)
                                }
                                .buttonStyle(.borderedProminent)
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
                                        updateDifficulty(for: subtask, to: difficulty)
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    plannedSubtasks.removeAll { $0.id == subtask.id }
                                }
                            } label: {
                                Text(subtask.difficulty.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        TextField("添加计划子任务", text: $plannedSubtaskDraft)
                            .accessibilityIdentifier("ios.recurring.subtask.add")
                        Button("添加") {
                            addPlannedSubtask()
                        }
                        .accessibilityIdentifier("ios.recurring.subtask.addButton")
                        .disabled(plannedSubtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("日期") {
                    DatePicker("开始", selection: $startDate, in: Date()..., displayedComponents: .date)
                }
                Section("结束条件") {
                    Picker("方式", selection: $endConditionMode) {
                        Text("指定日期").tag(0)
                        Text("持续天数").tag(1)
                        Text("完成次数").tag(2)
                    }
                    switch endConditionMode {
                    case 1:
                        Stepper("持续 (durationDays) 天", value: $durationDays, in: 1 ... 366)
                    case 2:
                        Stepper("完成 (completionTargetCount) 次", value: $completionTargetCount, in: 1 ... 366)
                        DatePicker(
                            "最迟日期",
                            selection: $completionLatestDate,
                            in: startDate...,
                            displayedComponents: .date
                        )
                    default:
                        DatePicker("结束", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
                Section("重复规则") {
                    Picker("规则", selection: $scheduleMode) {
                        Text("每隔几天").tag(0)
                        Text("选择星期").tag(1)
                    }
                    if scheduleMode == 0 {
                        Stepper("每 \(interval) 天", value: $interval, in: 1 ... 30)
                    } else {
                        Stepper("每 \(everyWeeks) 周", value: $everyWeeks, in: 1 ... 4)
                        ForEach(TaskCycleWeekday.allCases, id: \.self) { weekday in
                            Toggle(weekdayName(weekday), isOn: Binding(
                                get: { selectedWeekdays.contains(weekday) },
                                set: { enabled in
                                    if enabled {
                                        selectedWeekdays.insert(weekday)
                                    } else {
                                        selectedWeekdays.remove(weekday)
                                    }
                                }
                            ))
                        }
                    }
                }
                if let track {
                    Section("分类与标签") {
                        IOSClassificationEditor(target: .taskCycle(track.id))
                            .environmentObject(store)
                    }
                }
            }
            .navigationTitle(track == nil ? "新建重复计划" : "编辑重复计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("ios.recurring.editor.save")
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (scheduleMode == 1 && selectedWeekdays.isEmpty))
                }
            }
            .onAppear(perform: load)
        }
    }

    private func save() {
        let schedule: TaskCycleSchedule = if scheduleMode == 0 {
            .everyDays(interval)
        } else {
            .selectedWeekdays(weekdays: selectedWeekdays, everyWeeks: everyWeeks)
        }
        let endCondition: TaskCycleEndCondition = switch endConditionMode {
        case 1:
            .durationDays(durationDays)
        case 2:
            .completionTarget(
                count: completionTargetCount,
                latestDate: LocalDate.fromFoundation(completionLatestDate)
            )
        default:
            .onDate(LocalDate.fromFoundation(endDate))
        }
        if let track {
            store.updateTaskCycleContent(
                seriesID: track.id,
                title: title,
                description: description,
                plannedSubtasks: plannedSubtasks
            )
            store.reviseTaskCycle(
                track,
                startDate: LocalDate.fromFoundation(startDate),
                endDate: LocalDate.fromFoundation(endDate),
                schedule: schedule,
                endCondition: endCondition
            )
        } else {
            store.createTaskCycle(
                title: title,
                description: description,
                startDate: LocalDate.fromFoundation(startDate),
                endDate: LocalDate.fromFoundation(endDate),
                schedule: schedule,
                endCondition: endCondition,
                plannedSubtasks: plannedSubtasks
            )
        }
        dismiss()
    }

    private func load() {
        guard let track else { return }
        title = track.title
        if let series = store.engine.taskCycleSeries[track.id] {
            description = series.descriptionText ?? ""
            plannedSubtasks = series.plannedSubtasks
        }
        startDate = FoundationCalendar.date(for: track.startDate)
        endDate = FoundationCalendar.date(for: track.endDate)
        switch track.endCondition {
        case let .durationDays(days):
            endConditionMode = 1
            durationDays = days
        case let .completionTarget(count, latestDate):
            endConditionMode = 2
            completionTargetCount = count
            completionLatestDate = FoundationCalendar.date(for: latestDate)
        case let .onDate(date):
            endConditionMode = 0
            endDate = FoundationCalendar.date(for: date)
        }
        switch track.schedule {
        case let .everyDays(value):
            scheduleMode = 0
            interval = value
        case let .selectedWeekdays(weekdays, weeks):
            scheduleMode = 1
            selectedWeekdays = weekdays
            everyWeeks = weeks
        }
    }

    private func addPlannedSubtask() {
        let normalized = plannedSubtaskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        plannedSubtasks.append(
            PlannedSubtask(
                title: normalized,
                position: plannedSubtasks.count + 1,
                now: Date()
            )
        )
        plannedSubtaskDraft = ""
    }

    private func renamePlannedSubtask(_ subtask: PlannedSubtask) {
        let normalized = plannedSubtaskEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              let index = plannedSubtasks.firstIndex(where: { $0.id == subtask.id })
        else { return }
        plannedSubtasks[index].title = normalized
        editingPlannedSubtaskID = nil
    }

    private func updateDifficulty(for subtask: PlannedSubtask, to difficulty: SubtaskDifficulty) {
        guard let index = plannedSubtasks.firstIndex(where: { $0.id == subtask.id }) else { return }
        plannedSubtasks[index].difficulty = difficulty
    }

    private func weekdayName(_ weekday: TaskCycleWeekday) -> String {
        [1: "星期日", 2: "星期一", 3: "星期二", 4: "星期三", 5: "星期四", 6: "星期五", 7: "星期六"][weekday.rawValue] ?? "星期?"
    }
}

private enum FoundationCalendar {
    static var current: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_SG")
        return calendar
    }

    static func date(for localDate: LocalDate) -> Date {
        current.date(from: DateComponents(year: localDate.year, month: localDate.month, day: localDate.day)) ?? Date()
    }

    static func monthGrid(containing date: LocalDate) -> [LocalDate?] {
        let monthStart = current.date(from: DateComponents(year: date.year, month: date.month, day: 1)) ?? Date()
        let firstWeekday = current.component(.weekday, from: monthStart)
        let range: Range<Int> = current.range(of: .day, in: .month, for: monthStart) ?? 1 ..< 32
        let leading = firstWeekday - 1
        let days = (0 ..< range.count).map { offset -> LocalDate in
            let day = range.lowerBound + offset
            return LocalDate(year: date.year, month: date.month, day: day)
        }
        return [LocalDate?](repeating: nil, count: leading) + days.map { Optional($0) }
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

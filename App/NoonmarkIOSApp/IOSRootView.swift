@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct IOSRootView: View {
    @EnvironmentObject private var store: IOSStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isPageMenuPresented = false
    @State private var pendingImportURL: URL?
    @State private var isImportConfirmationPresented = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactRoot
            } else {
                regularRoot
            }
        }
        .tint(IOSTheme.accent)
        .alert(
            "无法保存",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: {
                    if $0 == false {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .alert(
            "确认导入数据包？",
            isPresented: $isImportConfirmationPresented,
            presenting: pendingImportURL
        ) { url in
            Button("取消", role: .cancel) {
                pendingImportURL = nil
            }
            Button("导入", role: .destructive) {
                store.importDataPackage(from: url)
                pendingImportURL = nil
            }
        } message: { _ in
            Text("导入会替换当前 development 工作区的数据；校验失败时会保留现有数据。")
        }
        .fileExporter(
            isPresented: $store.isExportingData,
            document: store.dataPackageDocument,
            contentType: .json,
            defaultFilename: "Noonmark-data"
        ) { result in
            if case let .failure(error) = result {
                store.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $store.isExportingDiagnostics,
            document: store.diagnosticDocument,
            contentType: .json,
            defaultFilename: "Noonmark-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                store.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $store.isImportingData,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                pendingImportURL = url
                isImportConfirmationPresented = true
            case let .failure(error):
                store.errorMessage = error.localizedDescription
            }
        }
        .sheet(
            isPresented: Binding(
                get: { store.selectedTraceID != nil },
                set: {
                    if $0 == false {
                        store.selectedTraceID = nil
                    }
                }
            )
        ) {
            if let trace = store.selectedTrace {
                IOSTaskDetailView(trace: trace)
                    .environmentObject(store)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { store.selectedPoolChainID != nil },
                set: {
                    if $0 == false {
                        store.selectedPoolChainID = nil
                    }
                }
            )
        ) {
            if let task = store.selectedPoolTask {
                IOSPoolTaskDetailView(task: task)
                    .environmentObject(store)
            }
        }
    }

    private var regularRoot: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            pageMenu
        } detail: {
            detailView
                .background(IOSTheme.background)
        }
    }

    private var compactRoot: some View {
        NavigationStack {
            detailView
                .background(IOSTheme.background)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isPageMenuPresented = true
                        } label: {
                            Image(systemName: "sidebar.leading")
                        }
                        .accessibilityLabel("打开目录")
                    }
                }
        }
        .sheet(isPresented: $isPageMenuPresented) {
            NavigationStack {
                IOSCompactPageMenu()
                    .environmentObject(store)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") {
                                isPageMenuPresented = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .onChange(of: store.page) { _, _ in
            isPageMenuPresented = false
        }
    }

    private var pageMenu: some View {
        List {
            Section("计划") {
                pageRow(.day)
                pageRow(.pool, count: store.poolTasks.count)
                pageRow(.future, count: store.futurePlans.count)
                pageRow(.recurring)
            }
            Section("轨迹") {
                pageRow(.unfinished, count: store.unfinishedTasks.count)
                pageRow(.completed, count: store.completedHierarchies.count)
                pageRow(.calendar)
                pageRow(.zhulong)
            }
            Section("札记") {
                pageRow(.stickyNotes, count: store.stickyEntries.count)
                pageRow(.flylight, count: store.flylightEntries.count)
            }
            Section("系统") {
                pageRow(.settings)
            }
        }
        .navigationTitle("晷迹")
    }

    private var detailView: some View {
        Group {
            switch store.page {
            case .day: IOSDayPage()
            case .pool: IOSPoolPage()
            case .future: IOSFuturePage()
            case .recurring: IOSRecurringPage()
            case .unfinished: IOSUnfinishedPage()
            case .completed: IOSCompletedPage()
            case .calendar: IOSCalendarPage()
            case .zhulong: IOSZhulongPage()
            case .stickyNotes: IOSStickyNotesPage()
            case .flylight: IOSFlylightPage()
            case .settings: IOSSettingsPage()
            }
        }
        .accessibilityIdentifier("ios.detail.\(store.page.rawValue)")
    }

    private func pageRow(_ page: IOSStore.Page, count: Int? = nil) -> some View {
        Button {
            store.page = page
            isPageMenuPresented = false
        } label: {
            Label {
            HStack {
                Text(page.title)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
            }
            } icon: {
                Image(systemName: page.symbol)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios.page.\(page.rawValue)")
    }
}

private struct IOSCompactPageMenu: View {
    @EnvironmentObject private var store: IOSStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuSection("计划") {
                pageRow(.day)
                pageRow(.pool, count: store.poolTasks.count)
                pageRow(.future, count: store.futurePlans.count)
                pageRow(.recurring)
            }
            menuSection("轨迹") {
                pageRow(.unfinished, count: store.unfinishedTasks.count)
                pageRow(.completed, count: store.completedHierarchies.count)
                pageRow(.calendar)
                pageRow(.zhulong)
            }
            menuSection("札记") {
                pageRow(.stickyNotes, count: store.stickyEntries.count)
                pageRow(.flylight, count: store.flylightEntries.count)
            }
            menuSection("系统") {
                pageRow(.settings)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .navigationTitle("晷迹")
    }

    private func menuSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            content()
        }
    }

    private func pageRow(_ page: IOSStore.Page, count: Int? = nil) -> some View {
        NavigationLink {
            Color.clear
                .onAppear {
                    store.page = page
                }
        } label: {
            Label {
                HStack {
                    Text(page.title)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                    }
                }
            } icon: {
                Image(systemName: page.symbol)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("ios.page.\(page.rawValue)")
    }
}

struct IOSDayPage: View {
    @EnvironmentObject private var store: IOSStore

    var body: some View {
        ScrollView {
            IOSPageHeader(title: "Day Todo", subtitle: store.selectedDate.description) {
                HStack(spacing: 12) {
                    Button {
                        store.moveSelectedDate(by: -1)
                    } label: { Image(systemName: "chevron.left") }
                    Button {
                        store.moveSelectedDate(by: 1)
                    } label: { Image(systemName: "chevron.right") }
                }
            }
            IOSComposer(
                text: $store.quickTaskText,
                placeholder: "记录今天要推进的任务",
                actionTitle: "加入"
            ) {
                store.addTaskToSelectedDay()
            }
            LazyVStack(spacing: 10) {
                ForEach(store.dayTodo.traces, id: \.id) { trace in
                    IOSTraceRow(trace: trace)
                }
            }
            .padding()
        }
        .navigationTitle("今日")
    }
}

struct IOSTraceRow: View {
    @EnvironmentObject private var store: IOSStore
    let trace: DayTrace

    private var title: String {
        store.engine.definitions[trace.definitionID]?.title ?? "无标题"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.toggleCompletion(for: trace)
            } label: {
                Image(systemName: trace.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(trace.status == .completed ? .green : IOSTheme.accent)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.body.weight(.medium))
                    .strikethrough(trace.status == .completed)
                if let description = trace.descriptionText, description.isEmpty == false {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(3)
                }
                HStack {
                    IOSStatusPill(text: trace.status.rawValue)
                    if trace.continuationSeq > 0 {
                        IOSStatusPill(text: "延续 \(trace.continuationSeq)")
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .background(IOSTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(IOSTheme.line)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedTraceID = trace.id
        }
        .contextMenu {
            if trace.status == .pending, trace.date == store.today {
                Button("回到任务池") { store.returnToPool(trace) }
            }
        }
    }
}

struct IOSPoolPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var scheduleTask: PoolTask?
    @State private var scheduleDate = Date()
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .taskPool)
        )
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let items = store.poolTasks.map { task in
            TaskCollectionPresentationItem(
                id: task.chain.id.description,
                title: task.definition.title,
                time: task.definition.createdAt,
                category: store.taskClassification(for: task.chain.id)?.category?
                    .iosTaskCollectionCategoryPresentation
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: items,
            preference: presentationPreference,
            ungroupedTitle: "未分类"
        )
    }

    private var tasksByID: [String: PoolTask] {
        Dictionary(uniqueKeysWithValues: store.poolTasks.map { ($0.chain.id.description, $0) })
    }

    var body: some View {
        List {
            Section {
                IOSComposer(
                    text: $store.poolTaskText,
                    placeholder: "先放入任务池",
                    actionTitle: "新增"
                ) { store.addTaskToPool() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            ForEach(presentationSections, id: \.id) { section in
                Section {
                    ForEach(section.items, id: \.id) { item in
                        if let task = tasksByID[item.id] {
                            IOSPoolTaskRow(
                                task: task,
                                onSchedule: {
                                    scheduleTask = task
                                    scheduleDate = Date()
                                }
                            )
                            .onTapGesture {
                                store.selectedPoolChainID = task.chain.id
                            }
                        }
                    }
                } header: {
                    IOSTaskCollectionSectionHeader(
                        section: section,
                        count: section.items.count
                    )
                }
            }
        }
        .navigationTitle("任务池")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IOSTaskCollectionPresentationMenu(
                    accessibilityIdentifier: "ios.task-collection-view.pool",
                    preference: $presentationPreference
                )
            }
        }
        .onChange(of: presentationPreference) { _, value in
            presentationRepository.save(value, for: .taskPool)
        }
        .sheet(
            isPresented: Binding(
                get: { scheduleTask != nil },
                set: {
                    if $0 == false {
                        scheduleTask = nil
                    }
                }
            )
        ) {
            if let task = scheduleTask {
            NavigationStack {
                Form {
                    DatePicker("日期", selection: $scheduleDate, in: Date()..., displayedComponents: .date)
                }
                .navigationTitle("排期任务")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            let calendar = Calendar.current
                            let c = calendar.dateComponents([.year, .month, .day], from: scheduleDate)
                            store.schedule(task, on: LocalDate(year: c.year ?? store.today.year, month: c.month ?? store.today.month, day: c.day ?? store.today.day))
                            scheduleTask = nil
                        }
                    }
                }
            }
            }
        }
    }
}

private struct IOSPoolTaskRow: View {
    let task: PoolTask
    let onSchedule: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.definition.title.isEmpty ? "无标题" : task.definition.title)
                if let description = task.definition.descriptionText {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("排期", action: onSchedule)
                .buttonStyle(.bordered)
        }
    }
}

struct IOSFuturePage: View {
    @EnvironmentObject private var store: IOSStore

    var body: some View {
        List(store.futurePlans, id: \.trace.id) { item in
            VStack(alignment: .leading, spacing: 5) {
                Text(item.definition.title.isEmpty ? "无标题" : item.definition.title)
                HStack {
                    Text(item.trace.date.description)
                    Spacer()
                    Button("回池") { store.returnToPool(item.trace) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectedTraceID = item.trace.id
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("未来计划")
    }
}

struct IOSUnfinishedPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .unfinished)
        )
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let items = store.unfinishedTasks.map { item in
            let traceTime = (item.unfinishedTraces + (item.activeTrace.map { [$0] } ?? []))
                .map(\.createdAt)
                .max()
            return TaskCollectionPresentationItem(
                id: item.chain.id.description,
                title: item.definition.title,
                time: traceTime ?? item.definition.createdAt,
                category: store.taskClassification(for: item.chain.id)?.category?
                    .iosTaskCollectionCategoryPresentation
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: items,
            preference: presentationPreference,
            ungroupedTitle: "未分类"
        )
    }

    private var itemsByID: [String: UnfinishedPoolItem] {
        Dictionary(uniqueKeysWithValues: store.unfinishedTasks.map { ($0.chain.id.description, $0) })
    }

    var body: some View {
        List {
            ForEach(presentationSections, id: \.id) { section in
                Section {
                    ForEach(section.items, id: \.id) { item in
                        if let unfinished = itemsByID[item.id] {
                            IOSUnfinishedTaskRow(item: unfinished, nextDay: nextDay(from: store.today))
                        }
                    }
                } header: {
                    IOSTaskCollectionSectionHeader(section: section, count: section.items.count)
                }
            }
        }
        .navigationTitle("未完成")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IOSTaskCollectionPresentationMenu(
                    accessibilityIdentifier: "ios.task-collection-view.unfinished",
                    preference: $presentationPreference
                )
            }
        }
        .onChange(of: presentationPreference) { _, value in
            presentationRepository.save(value, for: .unfinished)
        }
    }

    private func nextDay(from date: LocalDate) -> LocalDate {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day)) ?? Date()
        let next = calendar.date(byAdding: .day, value: 1, to: base) ?? base
        let c = calendar.dateComponents([.year, .month, .day], from: next)
        return LocalDate(year: c.year ?? date.year, month: c.month ?? date.month, day: c.day ?? date.day)
    }
}

private struct IOSUnfinishedTaskRow: View {
    @EnvironmentObject private var store: IOSStore
    let item: UnfinishedPoolItem
    let nextDay: LocalDate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.definition.title.isEmpty ? "无标题" : item.definition.title)
                .font(.body.weight(.medium))
            ForEach(item.unfinishedTraces, id: \.id) { trace in
                HStack {
                    Button {
                        store.selectedTraceID = trace.id
                    } label: {
                        Text(trace.date.description).font(.caption)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if trace.status == .abandoned {
                        Button("重新启用") { store.reactivate(trace) }
                    } else {
                        Button("延续到明天") { store.continueTrace(trace, to: nextDay) }
                        Button("废弃") { store.abandon(trace) }
                    }
                }
            }
        }
    }
}

struct IOSCompletedPage: View {
    @EnvironmentObject private var store: IOSStore
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .completed)
        )
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        let items = store.completedHierarchies.map { hierarchy in
            TaskCollectionPresentationItem(
                id: hierarchy.chain.id.description,
                title: hierarchy.definition.title,
                time: hierarchy.latestCompletionAt,
                category: store.taskClassification(for: hierarchy.chain.id)?.category?
                    .iosTaskCollectionCategoryPresentation
            )
        }
        return TaskCollectionPresentationProjector().sections(
            for: items,
            preference: presentationPreference,
            ungroupedTitle: "未分类"
        )
    }

    private var hierarchiesByID: [String: CompletedTaskHierarchy] {
        Dictionary(uniqueKeysWithValues: store.completedHierarchies.map { ($0.chain.id.description, $0) })
    }

    var body: some View {
        List {
            ForEach(presentationSections, id: \.id) { section in
                Section {
                    ForEach(section.items, id: \.id) { item in
                        if let hierarchy = hierarchiesByID[item.id] {
                            IOSCompletedHierarchyRow(hierarchy: hierarchy)
                        }
                    }
                } header: {
                    IOSTaskCollectionSectionHeader(section: section, count: section.items.count)
                }
            }
        }
        .navigationTitle("已完成")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IOSTaskCollectionPresentationMenu(
                    accessibilityIdentifier: "ios.task-collection-view.completed",
                    preference: $presentationPreference
                )
            }
        }
        .onChange(of: presentationPreference) { _, value in
            presentationRepository.save(value, for: .completed)
        }
    }
}

private struct IOSCompletedHierarchyRow: View {
    @EnvironmentObject private var store: IOSStore
    let hierarchy: CompletedTaskHierarchy
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    store.selectedTraceID = hierarchy.parentCompletion?.trace.id
                } label: {
                    Text(hierarchy.definition.title.isEmpty ? "无标题" : hierarchy.definition.title)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if hierarchy.completedChildren.isEmpty == false {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起子任务" : "展开子任务")
                }
            }
            if let completion = hierarchy.parentCompletion {
                Text("完成于 \(completion.trace.date.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                ForEach(hierarchy.completedChildren, id: \.subtask.id) { record in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(record.subtask.title)
                        Spacer()
                        Text(record.date.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }
}

struct IOSStickyNotesPage: View {
    @EnvironmentObject private var store: IOSStore
    @AppStorage("noonmark.ios.sticky-note.presentation-mode")
    private var presentationModeRaw = StickyNotePresentationMode.stream.rawValue

    private var presentationMode: Binding<StickyNotePresentationMode> {
        Binding(
            get: {
                StickyNotePresentationMode(rawValue: presentationModeRaw) ?? .stream
            },
            set: { presentationModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("展示", selection: presentationMode) {
                Text("清单流").tag(StickyNotePresentationMode.stream)
                Text("便签墙").tag(StickyNotePresentationMode.wall)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("ios.sticky.presentation")

            if store.stickyEntries.isEmpty {
                ContentUnavailableView("还没有 Sticky Note", systemImage: "pin", description: Text("前往飞光，选择值得反复看见的内容。"))
            } else {
                switch presentationMode.wrappedValue {
                case .stream:
                    stream
                case .wall:
                    wall
                }
            }
        }
        .navigationTitle("Sticky Note")
    }

    private var stream: some View {
        List {
            ForEach(store.stickyEntries) { idea in
                stickyRow(idea)
                    .swipeActions {
                        Button("移出") { store.toggleSticky(idea) }
                    }
            }
        }
    }

    private var wall: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                ForEach(store.stickyEntries) { idea in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(idea.body)
                            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                        Text(idea.createdAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("移出") { store.toggleSticky(idea) }
                            .font(.caption)
                    }
                    .padding(14)
                    .background(IOSTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).stroke(IOSTheme.line)
                    }
                    .onTapGesture(count: 2) {
                        store.page = .flylight
                        store.selectedIdeaID = idea.id
                    }
                }
            }
            .padding()
        }
    }

    private func stickyRow(_ idea: IdeaEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(idea.body)
            Text(idea.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onTapGesture(count: 2) {
            store.page = .flylight
            store.selectedIdeaID = idea.id
        }
    }
}

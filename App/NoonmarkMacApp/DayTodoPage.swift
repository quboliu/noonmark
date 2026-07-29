import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct DayTodoPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var quickAddFocusRequest = 0
    @State private var presentationPreference: TaskCollectionPresentationPreference
    private let presentationRepository: TaskCollectionPresentationPreferenceRepository

    init(
        presentationRepository: TaskCollectionPresentationPreferenceRepository =
            TaskCollectionPresentationPreferenceRepository()
    ) {
        self.presentationRepository = presentationRepository
        _presentationPreference = State(
            initialValue: presentationRepository.load(for: .dayTodo)
        )
    }

    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedDate).traces
    }

    private var tracesByID: [String: DayTrace] {
        Dictionary(uniqueKeysWithValues: traces.map { ($0.id.description, $0) })
    }

    private var presentationSections: [TaskCollectionPresentationSection] {
        store.dayTodoPresentationSections(
            date: store.selectedDate,
            preference: presentationPreference
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayTodoHeader(
                dayBadge: dayBadge,
                badgeColor: badgeColor,
                presentationPreference: $presentationPreference
            )

            DateStrip()
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.bottom, 10)

            if store.isHistory {
                Notice(text: store.copy.lockedDayNotice, tone: .locked)
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
            } else if store.isFuture {
                Notice(text: store.copy.futureDayNotice, tone: .future)
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
            }

            WorkspaceBulkActionBar()

            TaskSelectionClearingScrollView {
                VStack(spacing: 0) {
                    if store.isHistory == false {
                        DayQuickAdd(focusRequest: quickAddFocusRequest)
                            .padding(.bottom, 12)
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(presentationSections, id: \.id) { section in
                            if presentationPreference.organization == .grouped, section.title != nil {
                                TaskCollectionSectionHeader(
                                    section: section,
                                    count: section.items.count
                                )
                            }
                            ForEach(section.items, id: \.id) { item in
                                if let trace = tracesByID[item.id] {
                                    TaskRow(trace: trace)
                                        .taskCollectionCategoryVisibility(
                                            presentationPreference,
                                            in: section
                                        )
                                }
                            }
                        }

                        if traces.isEmpty {
                            if store.isHistory {
                                EmptyState(kind: .dayTodo, text: store.copy.emptyDay)
                                    .padding(.top, 40)
                            } else {
                                EmptyState(
                                    kind: .dayTodo,
                                    text: store.copy.emptyDay,
                                    actionTitle: store.copy.addTask
                                ) {
                                    quickAddFocusRequest &+= 1
                                }
                                .padding(.top, 40)
                            }
                        }
                    }
                }
                .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                .padding(.top, store.isHistory ? 12 : 14)
                .padding(.bottom, 20)
            }
        }
        .taskCollectionCategoryVisibility(presentationPreference)
        .onChange(of: presentationPreference) { _, preference in
            presentationRepository.save(preference, for: .dayTodo)
        }
        .background {
            HorizontalPageNavigationBridge(
                isEnabled: { store.page == .day && store.canNavigateDatePage },
                onNavigate: { store.moveSelectedPageFromSwipe($0) }
            )
        }
    }

    private var dayBadge: String {
        if store.selectedDate == store.today { return store.copy.dayBadgeToday }
        if store.isHistory { return store.copy.dayBadgeLocked }
        return store.copy.dayBadgeFuture
    }

    private var badgeColor: Color {
        if store.selectedDate == store.today { return Theme.accent }
        if store.isHistory { return Theme.text2 }
        return Theme.accent
    }
}

struct DayTodoHeader: View {
    @EnvironmentObject private var store: NoonmarkStore
    let dayBadge: String
    let badgeColor: Color
    @Binding var presentationPreference: TaskCollectionPresentationPreference

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            compactHeader
        }
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.top, 16)
    }

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            identity
            Spacer(minLength: 8)
            presentationMenu
            navigationActions
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                presentationMenu
                navigationActions
            }
        }
    }

    private var presentationMenu: some View {
        TaskCollectionPresentationMenu(
            copy: store.copy,
            accessibilityIdentifier: "task-collection-view.day-todo",
            preference: $presentationPreference
        )
    }

    private var identity: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.displayFullDate(store.selectedDate))
                .font(.noonmarkSystem(size: 20, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(3)
                .background {
                    AppE2EViewAnchor(
                        identifier: "day.header.date",
                        verificationText: store.displayFullDate(store.selectedDate)
                    )
                }
                .accessibilityIdentifier("day.header.date")
            Text(store.weekday(store.selectedDate))
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            DayStateBadge(
                text: dayBadge,
                color: badgeColor,
                filled: store.selectedDate == store.today
            )
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
            .background {
                AppE2EViewAnchor(
                    identifier: "day.header.state",
                    verificationText: dayBadge
                )
            }
            .accessibilityIdentifier("day.header.state")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var navigationActions: some View {
        HStack(spacing: 8) {
            navigationButton(
                "‹",
                accessibilityLabel: store.copy.previousDay,
                identifier: "day.header.previous-action"
            ) {
                store.moveSelectedPage(.previous)
            }
            if store.selectedDate != store.today {
                navigationButton(
                    store.copy.today,
                    identifier: "day.header.today-action"
                ) {
                    store.selectedDate = store.today
                }
            }
            navigationButton(
                "›",
                accessibilityLabel: store.copy.nextDay,
                identifier: "day.header.next-action"
            ) {
                store.moveSelectedPage(.next)
            }
            navigationButton(
                store.copy.chooseDate,
                identifier: "day.header.choose-date-action"
            ) {
                store.showingPicker = .gotoDay
            }
            if store.hasDetailRailContent && store.isDetailRailExpanded == false {
                PaneBoundaryToggle(
                    direction: .left,
                    accessibilityLabel: store.copy.expandDetailRail,
                    identifier: "shell.detail-rail.toggle"
                ) {
                    store.toggleDetailRail()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func navigationButton(
        _ title: String,
        accessibilityLabel: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HeaderButton(
            title,
            accessibilityLabel: accessibilityLabel,
            action: action
        )
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: accessibilityLabel ?? title
            )
        }
        .accessibilityIdentifier(identifier)
    }
}

struct DayStateBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(filled ? color : color.opacity(0.12)))
    }
}

struct DayQuickAdd: View {
    @EnvironmentObject private var store: NoonmarkStore
    let focusRequest: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NewTaskInlineField(
                placeholder: store.isFuture
                    ? store.copy.dayQuickAddFuturePlaceholder
                    : store.copy.dayQuickAddTodayPlaceholder,
                text: $store.quickText,
                nativeAccessibilityIdentifier: "quick-add.day",
                focusRequest: focusRequest
            ) {
                store.addQuickTask()
            }
            HeaderButton(store.copy.scheduleFromPool) { store.showingFromPoolPicker = true }
        }
    }
}

struct NewTaskInlineField: View {
    @EnvironmentObject private var store: NoonmarkStore
    let placeholder: String
    @Binding var text: String
    let nativeAccessibilityIdentifier: String
    let focusRequest: Int
    let onSubmit: () -> Void

    var suggestions: [ClassificationCatalogItemProjection] {
        store.newTaskClassificationSuggestions(for: text)
    }

    var activeToken: NewTaskClassificationToken? {
        store.newTaskClassificationToken(for: text)
    }

    var showsSuggestions: Bool {
        store.shouldShowNewTaskClassificationSuggestions(for: text)
    }

    var showsSlashCommand: Bool {
        store.newTaskSlashCommandMatches(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownEditor(
                text: $text,
                placeholder: placeholder,
                style: .compact,
                commitsOnReturn: true,
                onCommit: onSubmit,
                nativeAccessibilityIdentifier: nativeAccessibilityIdentifier,
                focusRequest: focusRequest
            )
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lineSubtle))

            if showsSlashCommand {
                NewTaskSlashCommandSuggestion {
                    text = store.completeNewTaskSlashCommand()
                }
            } else if showsSuggestions, let activeToken {
                NewTaskClassificationSuggestionList(
                    tokenKind: activeToken.kind,
                    suggestions: Array(suggestions.prefix(6))
                ) { suggestion in
                    text = store.completeNewTaskClassificationToken(
                        in: text,
                        with: suggestion.name
                    )
                }
            }

            if let issue = store.newTaskDraftIssueMessage(for: text) {
                Text(issue)
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warn)
            }
        }
        .layoutPriority(1)
    }
}

struct NewTaskSlashCommandSuggestion: View {
    @EnvironmentObject private var store: NoonmarkStore
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text("/")
                    .font(.noonmarkSystem(
                        size: 10,
                        weight: .black,
                        design: .rounded
                    ))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent.opacity(0.10))
                    )
                Text(store.copy.recurringSlashCommand)
                    .font(.noonmarkSystem(
                        size: 11.5,
                        weight: .semibold
                    ))
                    .foregroundStyle(Theme.text1)
                Text(store.copy.recurringSlashCommandDescription)
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.lineSubtle)
        )
        .shadow(color: Theme.shadowSubtle, radius: 8, y: 4)
        .accessibilityIdentifier("new-task.slash-command.recurring")
        .background {
            AppE2EViewAnchor(
                identifier: "new-task.slash-command.recurring",
                verificationText: store.copy.recurringSlashCommand
            )
        }
    }
}

struct NewTaskClassificationSuggestionList: View {
    let tokenKind: NewTaskClassificationTokenKind
    let suggestions: [ClassificationCatalogItemProjection]
    let onSelect: (ClassificationCatalogItemProjection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Text(String(tokenKind.marker))
                            .font(.noonmarkSystem(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(suggestion.color)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(suggestion.color.opacity(0.10))
                            )
                        Text("\(String(tokenKind.marker))\(suggestion.name)")
                            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.lineSubtle))
        .shadow(color: Theme.shadowSubtle, radius: 8, y: 4)
        .accessibilityIdentifier("new-task.classification-suggestions")
        .background {
            AppE2EViewAnchor(
                identifier: "new-task.classification-suggestions",
                verificationText:
                    "\(String(tokenKind.marker)):"
                    + suggestions.map(\.name).joined(separator: ",")
            )
        }
    }
}

struct DateStrip: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var focusRequest = 0
    @State private var hasKeyboardFocus = false

    var dates: [LocalDate] { store.dateStripDates() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            DateStripSelectionPill(selectedIndex: store.selectedDateStripIndex, cellCount: dates.count)
                .frame(height: 52)
                .clipped()

            HStack(spacing: 0) {
                ForEach(dates, id: \.self) { date in
                    let selected = date == store.selectedDate
                    let today = date == store.today
                    let traces = store.engine.getDayTodo(date: date).traces
                    let count = traces.count
                    let pendingCount = traces.count(where: { $0.status == .pending })
                    Button {
                        focusRequest &+= 1
                        withAnimation(
                            Theme.shouldReduceMotion
                                ? nil
                                : .spring(
                                    response: MacUIAnimationMetrics.dateStripSpringResponse,
                                    dampingFraction: MacUIAnimationMetrics.dateStripSpringDampingFraction
                                )
                        ) {
                            store.selectedDate = date
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(store.weekdayNarrow(date))
                                .font(.noonmarkSystem(size: 10))
                                .foregroundStyle(Theme.text3)
                            Text("\(date.day)")
                                .font(.noonmarkSystem(size: 12, weight: .medium))
                                .foregroundStyle(selected ? .white : today ? Theme.accent : Theme.text1)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(today && !selected ? Theme.accent : .clear, lineWidth: 1.5))
                            Group {
                                if pendingCount > 0, Theme.shouldDifferentiateWithoutColor {
                                    Text("\(min(pendingCount, 99))")
                                        .font(.noonmarkSystem(size: 8.5, weight: .bold))
                                        .foregroundStyle(selected ? .white : Theme.text2)
                                        .monospacedDigit()
                                } else {
                                    Circle()
                                        .fill(pendingCount > 0 ? (selected ? .white.opacity(0.9) : Theme.accent) : .clear)
                                        .frame(width: 3, height: 3)
                                }
                            }
                            .frame(height: 9)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background {
                            AppE2EViewAnchor(
                                identifier: "day.date-strip.cell.\(date.description)",
                                verificationText: selected ? "selected" : ""
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        store.copy.dateCellAccessibilityLabel(
                            date: store.displayDate(date),
                            weekday: store.weekday(date),
                            taskCount: count,
                            isToday: today,
                            isSelected: selected
                        )
                    )
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .background {
            DateNavigationKeyboardFocusBridge(
                focusRequest: focusRequest,
                onMoveCommand: { store.moveSelectedDate($0) },
                onFocusChange: { hasKeyboardFocus = $0 }
            )
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(hasKeyboardFocus ? Theme.accent.opacity(0.72) : Theme.line.opacity(0.62))
                .frame(height: hasKeyboardFocus ? 1.5 : 1)
        }
    }
}

struct DateStripSelectionPill: View {
    let selectedIndex: Int?
    let cellCount: Int

    var body: some View {
        GeometryReader { proxy in
            if let selectedIndex, cellCount > 0 {
                let cellWidth = proxy.size.width / CGFloat(cellCount)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 24, height: 24)
                    .shadow(color: Theme.accent.opacity(0.34), radius: 6, x: 0, y: 2)
                    .offset(
                        x: cellWidth * CGFloat(selectedIndex) + (cellWidth - 24) / 2,
                        y: 18
                    )
                    .animation(
                        Theme.shouldReduceMotion
                            ? nil
                            : .spring(
                                response: MacUIAnimationMetrics.dateStripSpringResponse,
                                dampingFraction: MacUIAnimationMetrics.dateStripSpringDampingFraction
                            ),
                        value: selectedIndex
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

struct TaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var definition: TaskDefinition? { store.definition(for: trace) }
    var progress: TraceProgress { store.engine.traceProgress(for: trace.id) }
    var subtasks: [Subtask] { store.subtasks(for: trace.id) }
    var taskCycleSeries: TaskCycleSeries? {
        guard let seriesID = store.engine.chains[
            trace.chainID
        ]?.cycleMembership?.seriesID else {
            return nil
        }
        return store.engine.taskCycleSeries[seriesID]
    }

    var selected: Bool {
        store.isWorkspaceItemSelected(.dayTrace(trace.id))
    }

    var expanded: Bool { store.expandedTraceIDs.contains(trace.id) }

    private var titleColor: Color {
        trace.status == .completed
            ? Theme.terminalTaskText
            : trace.status.uiStyle.titleColor
    }

    private var titleWeight: Font.Weight {
        trace.status == .completed ? .regular : .medium
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: NoonmarkVisualMetrics.taskRowAccessorySpacing) {
                completionControl

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MarkdownInlineText(
                            store.copy.displayTaskTitle(definition?.title)
                        )
                        .font(
                            .noonmarkSystem(
                                size: 13,
                                weight: titleWeight
                            )
                        )
                        .foregroundStyle(titleColor)
                        .strikethrough(
                            trace.status.uiStyle.strikethrough
                        )

                        if let taskCycleSeries {
                            Text(
                                store.copy.taskCycleDayMarker(
                                    taskCycleSeries.schedule
                                )
                            )
                            .font(.noonmarkSystem(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .accessibilityIdentifier(
                                "day-row.task-cycle.\(trace.id.description)"
                            )
                            .background {
                                AppE2EViewAnchor(
                                    identifier:
                                    "day-row.task-cycle.\(trace.id.description)",
                                    verificationText:
                                    store.copy.taskCycleDayMarker(
                                        taskCycleSeries.schedule
                                    )
                                )
                            }
                        }
                    }

                    if let classification = store.displayableClassification(for: trace) {
                        TaskClassificationBadges(
                            display: classification,
                            taskTitle: definition?.title ?? store.copy.untitledTask,
                            accessibilityNamespace: TaskClassificationAccessibilityNamespace(
                                surface: "day-row",
                                instanceID: trace.id.description
                            )
                        )
                        .padding(.top, 4)
                    }

                    AutomaticTaskClassificationStatusView(
                        chainID: trace.chainID,
                        taskTitle: definition?.title ?? store.copy.untitledTask,
                        accessibilitySurface: .dayRow,
                        accessibilityInstanceID: trace.id.description
                    )
                    .padding(.top, 3)

                    if showsProgress {
                        HStack(spacing: 6) {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.chip)
                                    Capsule()
                                        .fill(progress.percent == 100 ? Theme.ok : Theme.accent)
                                        .frame(width: proxy.size.width * CGFloat(progress.percent) / 100)
                                }
                            }
                            .frame(width: 150, height: 4)
                            Text("\(progress.percent)%")
                                .font(.noonmarkSystem(size: 10, weight: .semibold))
                                .foregroundStyle(progress.percent == 100 ? Theme.ok : Theme.accent)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.top, 5)
                    }

                    if metaText.isEmpty == false {
                        Text(metaText)
                            .font(.noonmarkSystem(size: 11))
                            .foregroundStyle(Theme.text3)
                            .padding(.top, 2)
                    }

                    if let relationLabel {
                        TextActionButton(relationLabel.title, action: relationLabel.action)
                            .padding(.top, 2)
                    }

                    if let changedTarget = store.changedTarget(for: trace) {
                        ChangedTargetButton(
                            title: changedTarget.definition.title,
                            compact: true
                        ) {
                            store.openChangedTarget(from: trace)
                        }
                        .padding(.top, 3)
                    } else if let changedSource = store.changedSource(for: trace) {
                        ChangedSourceButton(
                            title: changedSource.definition.title,
                            compact: true
                        ) {
                            store.openChangedSource(from: trace)
                        }
                        .padding(.top, 3)
                    }
                }
                .layoutPriority(1)

                HStack(spacing: NoonmarkVisualMetrics.taskRowAccessorySpacing) {
                    if trace.pinOrder != nil {
                        Image(systemName: "pin.fill")
                            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(store.copy.pinToTop)
                            .help(store.copy.pinToTop)
                    }

                    if subtasks.isEmpty == false {
                        Button {
                            if expanded {
                                store.expandedTraceIDs.remove(trace.id)
                            } else {
                                store.expandedTraceIDs.insert(trace.id)
                            }
                        } label: {
                            SubtaskDisclosureLabel(count: subtasks.count, expanded: expanded)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, NoonmarkVisualMetrics.taskRowVerticalPadding)

            if expanded {
                VStack(spacing: 6) {
                    ForEach(subtasks, id: \.id) { subtask in
                        SubtaskRow(
                            subtask: subtask,
                            surface: .dayList
                        )
                    }
                }
                .padding(.top, 1)
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
        .listRowSurface(selected: selected, tint: Theme.accent, separatorLeadingInset: 44)
        .contentShape(Rectangle())
        .workspaceSelectable(.dayTrace(trace.id))
        .onTapGesture { store.userSelectTrace(trace.id) }
        .contextMenu {
            TaskContextMenu(trace: trace)
        }
    }

    var completionCapability: DayTraceCompletionCapability {
        (try? store.engine.completionCapability(
            for: trace.id,
            today: store.today
        )) ?? .unavailable(.unsupportedStatus(trace.status))
    }

    @ViewBuilder
    var completionControl: some View {
        switch completionCapability {
        case let .available(action):
            completionButton(
                label: action == .undo
                    ? store.copy.undoComplete
                    : store.copy.markComplete
            )
        case .unavailable(.openSubtasks):
            completionButton(
                label: store.copy.openSubtasksPreventCompletion
            )
        case .unavailable:
            StatusGlyph(status: trace.status)
                .frame(
                    width: NoonmarkVisualMetrics.taskRowCompletionControlSize,
                    height: NoonmarkVisualMetrics.taskRowCompletionControlSize
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(store.copy.traceStatusLabel(trace.status))
        }
    }

    private func completionButton(label: String) -> some View {
        Button {
            store.toggleComplete(trace.id)
        } label: {
            StatusGlyph(status: trace.status)
                .frame(
                    width: NoonmarkVisualMetrics.taskRowCompletionControlSize,
                    height: NoonmarkVisualMetrics.taskRowCompletionControlSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityIdentifier(
            "day.trace.\(trace.id.description).completion"
        )
        .help(label)
    }

    var metaText: String {
        var parts: [String] = []
        if trace.continuationSeq > 0 {
            parts.append(
                store.copy.continuationDuration(
                    sequence: trace.continuationSeq,
                    days: store.continuationDurationDays(for: trace)
                )
            )
        }
        if trace.status == .returnedToPool { parts.append(store.copy.returnedToPoolOnDay) }
        return parts.joined(separator: " · ")
    }

    var relationLabel: (title: String, action: () -> Void)? {
        if let target = store.carryoverTarget(for: trace) {
            let title = trace.status == .deferred
                ? store.copy.deferredToLink(store.displayDate(target.date))
                : store.copy.continuedToLink(store.displayDate(target.date))
            return (title, { store.openCarryoverTarget(from: trace) })
        }
        guard let source = store.carryoverSource(for: trace) else {
            return nil
        }
        let title = store.engine.carryoverKind(for: trace.id) == .deferral
            ? store.copy.deferredFromLink(store.displayDate(source.date))
            : store.copy.continuedFromUnfinishedLink(
                store.displayDate(source.date)
            )
        return (title, { store.openCarryoverSource(from: trace) })
    }

    var showsProgress: Bool {
        guard progress.percent > 0, progress.percent < 100 else { return false }
        switch trace.status {
        case .pending, .deferred, .unfinished:
            return true
        case .completed, .changed, .returnedToPool, .abandoned:
            return false
        case .cancelledDraft:
            preconditionFailure("Internal trace status cannot appear in Day Todo")
        }
    }
}

struct SubtaskDisclosureLabel: View {
    @EnvironmentObject private var store: NoonmarkStore
    let count: Int
    let expanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.noonmarkSystem(size: 9, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text(store.copy.subtaskCount(count))
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Theme.accentSoft))
        .contentShape(Capsule())
    }
}

struct ChangedTargetButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    let title: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(store.copy.changedToPrefix)
                    .foregroundStyle(Theme.text3)
                MarkdownInlineText(store.copy.displayTaskTitle(title))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.noonmarkSystem(size: compact ? 8.5 : 9.5, weight: .bold))
            }
            .font(.noonmarkSystem(size: compact ? 10.5 : 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 0 : 7)
            .frame(height: compact ? nil : 22)
            .background {
                if !compact {
                    Capsule().fill(Theme.accentSoft)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ChangedSourceButton: View {
    @EnvironmentObject private var store: NoonmarkStore
    let title: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(.noonmarkSystem(size: compact ? 8.5 : 9.5, weight: .bold))
                Text(store.copy.changedFromPrefix)
                    .foregroundStyle(Theme.text3)
                MarkdownInlineText(store.copy.displayTaskTitle(title))
                    .lineLimit(1)
            }
            .font(.noonmarkSystem(size: compact ? 10.5 : 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 0 : 7)
            .frame(height: compact ? nil : 22)
            .background {
                if !compact {
                    Capsule().fill(Theme.accentSoft)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

enum SubtaskRowSurface {
    case dayList
    case dayDetail

    private var accessibilityNamespace: String {
        switch self {
        case .dayList:
            "day-list"
        case .dayDetail:
            "day"
        }
    }

    func accessibilityPrefix(for subtaskID: SubtaskID) -> String {
        "\(accessibilityNamespace).subtask.\(subtaskID.description)"
    }

    func completionIdentifier(for subtaskID: SubtaskID) -> String {
        "\(accessibilityPrefix(for: subtaskID)).completion"
    }

    func titleIdentifier(for subtaskID: SubtaskID) -> String {
        "\(accessibilityPrefix(for: subtaskID)).title"
    }

    func titleInputIdentifier(for subtaskID: SubtaskID) -> String {
        "\(titleIdentifier(for: subtaskID)).input"
    }

    func deleteIdentifier(for subtaskID: SubtaskID) -> String {
        "\(accessibilityPrefix(for: subtaskID)).delete"
    }

    func newEditorIdentifier(for traceID: DayTraceID) -> String {
        "\(accessibilityNamespace).subtask.\(traceID.description).new"
    }
}

struct SubtaskRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let subtask: Subtask
    let surface: SubtaskRowSurface

    private var accessibilityPrefix: String {
        surface.accessibilityPrefix(for: subtask.id)
    }

    var canToggle: Bool {
        store.canToggleSubtask(subtask)
    }

    var canEdit: Bool {
        store.canEditSubtask(subtask)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                store.toggleSubtask(subtask.id)
            } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(subtask.status == .completed ? Theme.ok : Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(subtask.status == .completed ? Theme.ok : Theme.line2, lineWidth: 1.5))
                    .overlay(Text(subtask.status == .completed ? "✓" : "").font(.noonmarkSystem(size: 9)).foregroundStyle(.white))
                    .frame(width: 15, height: 15)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                subtask.status == .completed
                    ? store.copy.undoComplete
                    : store.copy.markComplete
            )
            .accessibilityIdentifier(surface.completionIdentifier(for: subtask.id))
            .disabled(canToggle == false)

            EditableSubtaskTitle(
                title: subtask.title,
                editable: canEdit,
                accessibilityIdentifier: surface.titleIdentifier(for: subtask.id)
            ) {
                store.renameSubtask(
                    subtask.id,
                    title: $0,
                    immediately: true
                )
            }
            .foregroundStyle(
                subtask.status == .completed
                    ? Theme.terminalTaskText
                    : Theme.text1
            )
            .strikethrough(subtask.status == .completed)

            Spacer()

            if subtask.completedAt != nil && canEdit == false {
                Image(systemName: "lock.fill")
                    .font(.noonmarkSystem(size: 9))
                    .foregroundStyle(Theme.text3)
            }

            Menu {
                ForEach(SubtaskDifficulty.allCases, id: \.self) { difficulty in
                    Button {
                        store.setSubtaskDifficulty(subtask.id, difficulty: difficulty)
                    } label: {
                        Label(
                            difficultyMenuTitle(difficulty),
                            systemImage: difficulty == subtask.difficulty ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.noonmarkSystem(size: 9, weight: .semibold))
                    Text(store.copy.subtaskDifficulty(subtask.difficulty, compact: true))
                    MicroLabel(
                        systemImage: "chevron.down",
                        color: subtask.difficulty == .hard ? Theme.warn : Theme.text2
                    )
                }
                .font(.noonmarkSystem(size: 9, weight: .bold))
                .foregroundStyle(subtask.difficulty == .hard ? Theme.warn : Theme.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(subtask.difficulty == .hard ? Theme.warnSoft : Theme.chip))
                .overlay(Capsule().stroke(Theme.line2))
            }
            .buttonStyle(.plain)
            .disabled(canEdit == false)
            .help(store.copy.subtaskDifficultyHelp(canMutate: canEdit))

            if canEdit {
                Button {
                    store.deleteSubtask(subtask.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.noonmarkSystem(size: 10, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.copy.removeSubtaskAction)
                .accessibilityIdentifier(
                    "\(surface.deleteIdentifier(for: subtask.id)).ax"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier: surface.deleteIdentifier(for: subtask.id)
                    )
                }
                .help(store.copy.removeSubtaskAction)
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier: "\(accessibilityPrefix).row"
            )
        }
    }

    private func difficultyMenuTitle(_ difficulty: SubtaskDifficulty) -> String {
        store.copy.subtaskDifficulty(difficulty)
    }
}

struct EditableSubtaskTitle: View {
    @EnvironmentObject private var store: NoonmarkStore
    let title: String
    let editable: Bool
    let accessibilityIdentifier: String
    let onChange: (String) -> Void

    @State private var draft: String
    @State private var pendingPersistedTitle: String?
    @State private var persistenceRevision: UInt64 = 0
    private let autosaveDelay = Duration.milliseconds(300)

    init(
        title: String,
        editable: Bool,
        accessibilityIdentifier: String,
        onChange: @escaping (String) -> Void
    ) {
        self.title = title
        self.editable = editable
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onChange = onChange
        _draft = State(initialValue: title)
    }

    var body: some View {
        if editable {
            MarkdownEditor(
                text: $draft,
                placeholder: store.copy.subtask,
                style: .subtask,
                showsSurface: false,
                commitsOnReturn: true,
                onCommit: finishEditing,
                onEndEditing: finishEditing,
                onTextChange: scheduleAutosave,
                nativeAccessibilityIdentifier: accessibilityIdentifier
            )
            .onChange(of: title) { _, newValue in
                if pendingPersistedTitle == newValue {
                    pendingPersistedTitle = nil
                    return
                }
                persistenceRevision &+= 1
                if draft != newValue {
                    draft = newValue
                }
            }
            .font(.noonmarkSystem(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownInlineText(title)
                .font(.noonmarkSystem(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scheduleAutosave(_ value: String) {
        persistenceRevision &+= 1
        let revision = persistenceRevision
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false, normalized != title else { return }
        Task { @MainActor in
            try? await Task.sleep(for: autosaveDelay)
            guard persistenceRevision == revision else { return }
            persist(normalized)
        }
    }

    private func finishEditing() {
        persistenceRevision &+= 1
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            draft = title
            return
        }
        persist(normalized)
    }

    private func persist(_ normalized: String) {
        guard normalized != title else { return }
        pendingPersistedTitle = normalized
        onChange(normalized)
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace
    var actions: [NoonmarkStore.TraceContextAction] { store.contextMenuActions(for: trace) }

    var body: some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .markComplete:
                Button(store.copy.markComplete) { store.toggleComplete(trace.id) }
            case .undoComplete:
                Button(store.copy.undoComplete) { store.toggleComplete(trace.id) }
            case .pinToTop:
                Button(store.copy.pinToTop) {
                    store.setTracePinned(trace.id, pinned: true)
                }
            case .unpin:
                Button(store.copy.unpin) {
                    store.setTracePinned(trace.id, pinned: false)
                }
            case .deferTo:
                Button(store.copy.deferTo) {
                    store.showingPicker = .deferTrace(trace.id)
                }
            case .withdrawDeferral:
                Button(store.copy.withdrawDeferral) {
                    store.withdrawDeferral(trace.id)
                }
            case .continueTo:
                Button(store.copy.continueTo) { store.showingPicker = .continueTrace(trace.id) }
            case .changeToNewTask:
                Button(store.copy.changeToNewTask) {
                    store.selectTrace(trace.id)
                    store.changeText = store.definition(for: trace)?.title ?? ""
                    store.showingChangeDialog = true
                }
            case .returnToPool:
                Button(store.copy.returnToPoolWithTrace) { store.returnToPool(trace.id) }
            case .reschedule:
                Button(store.copy.reschedule) { store.showingPicker = .reschedule(trace.id) }
            case .copyAsNewTask:
                Button(store.copy.copyAsNewTask) { store.copyAsNewTask(trace.id) }
            case .deleteNewCurrentDayTask:
                Button(store.copy.deleteTask, role: .destructive) {
                    store.deleteNewCurrentDayTask(trace.id)
                }
            case .abandonChain:
                Button(store.copy.abandonChain, role: .destructive) { store.abandon(trace.id) }
            }
        }
        TaskCycleConversionMenuSection(
            chainID: trace.chainID,
            traceID: trace.id,
            accessibilityIdentifier:
            "task-cycle-conversion.day.\(trace.chainID.description)"
        )
    }
}

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

struct CalendarPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var focusRequest = 0

    var calendarCells: [CalendarCellModel] {
        let year = store.selectedCalendarDate.year
        let month = store.selectedCalendarDate.month
        let lead = NoonmarkStore.mondayLeadBlankCount(year: year, month: month)
        let dayCount = NoonmarkStore.daysInMonth(year: year, month: month)
        var cells = (0..<lead).map { CalendarCellModel.blank(id: "blank-\($0)") }
        cells += (1...dayCount).map { day in
            .date(LocalDate(year: year, month: month, day: day))
        }
        return cells
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(store.displayMonthYear(store.selectedCalendarDate))
                    .font(.noonmarkSystem(size: 21, weight: .bold))
                    .foregroundStyle(Theme.text1)
                    .monospacedDigit()
                Spacer()
                HeaderButton("‹", accessibilityLabel: store.copy.previousMonth) {
                    store.selectedCalendarDate = NoonmarkStore.shiftedMonth(from: store.selectedCalendarDate, by: -1)
                }
                HeaderButton(store.copy.today) { store.selectedCalendarDate = store.today }
                HeaderButton("›", accessibilityLabel: store.copy.nextMonth) {
                    store.selectedCalendarDate = NoonmarkStore.shiftedMonth(from: store.selectedCalendarDate, by: 1)
                }
            }

            Text(store.copy.calendarSubtitle)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text3)
                .padding(.top, 4)

            HStack {
                ForEach(
                    Array(store.calendarWeekdayLabels().enumerated()),
                    id: \.offset
                ) { _, label in
                    Text(label)
                        .font(.noonmarkSystem(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
                }
            }
            .padding(.top, 14)

            GeometryReader { proxy in
                let rows = max(5, Int(ceil(Double(calendarCells.count) / 7.0)))
                let rowHeight = max(88, proxy.size.height / CGFloat(rows))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                    spacing: 0
                ) {
                    ForEach(calendarCells) { cell in
                        switch cell.kind {
                        case .blank:
                            Color.clear
                                .frame(height: rowHeight)
                        case let .date(date):
                            CalendarCell(
                                date: date,
                                height: rowHeight,
                                onSelect: {
                                    focusRequest &+= 1
                                    store.selectedCalendarDate = date
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 14)
        }
        .padding(.top, 16)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .background {
            DateNavigationKeyboardFocusBridge(
                focusRequest: focusRequest,
                onMoveCommand: { store.moveSelectedDate($0) },
                onFocusChange: { _ in }
            )
        }
    }
}

struct CalendarCellModel: Identifiable {
    enum Kind {
        case blank
        case date(LocalDate)
    }

    let id: String
    let kind: Kind

    static func blank(id: String) -> CalendarCellModel {
        CalendarCellModel(id: id, kind: .blank)
    }

    static func date(_ date: LocalDate) -> CalendarCellModel {
        CalendarCellModel(id: date.description, kind: .date(date))
    }
}

struct CalendarCell: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var isHovered = false
    let date: LocalDate
    let height: CGFloat
    let onSelect: () -> Void

    var summary: CalendarDaySummary { store.engine.calendarSummary(for: date) }
    var traces: [DayTrace] {
        store.engine.getDayTodo(date: date).traces.sorted { $0.priority < $1.priority }
    }

    var selected: Bool { store.selectedCalendarDate == date }

    var isToday: Bool { date == store.today }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(date.day)")
                        .font(.noonmarkSystem(size: 12.5, weight: isToday || selected ? .bold : .medium))
                        .foregroundStyle(selected ? Theme.accent : traces.isEmpty ? Theme.text3 : Theme.text1)
                        .monospacedDigit()
                        .lineLimit(1)
                    if isToday {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 4, height: 4)
                    }
                    Spacer()
                    if summary.total > 0 {
                        Text("\(summary.completed)/\(summary.total)")
                            .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                            .foregroundStyle(
                                summary.completed == summary.total
                                    ? Theme.ok
                                    : Theme.text2
                            )
                            .monospacedDigit()
                            .accessibilityLabel(
                                store.copy.completedAccessibility(
                                    completed: summary.completed,
                                    total: summary.total
                                )
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(traces.prefix(6), id: \.id) { trace in
                        HStack(spacing: 3) {
                            Text(trace.status.uiStyle.glyph.isEmpty ? "○" : trace.status.uiStyle.glyph)
                                .font(.noonmarkSystem(size: 8, weight: .bold))
                                .foregroundStyle(dotColor(for: trace.status))
                                .frame(width: 8)
                                .accessibilityHidden(true)
                            MarkdownInlineText(store.definition(for: trace)?.title ?? "")
                                .font(.noonmarkSystem(size: 9.5))
                                .foregroundStyle(titleColor(for: trace.status))
                                .strikethrough(trace.status == .completed || trace.status == .abandoned)
                                .lineLimit(1)
                        }
                        .frame(height: 12, alignment: .leading)
                    }
                    if traces.count > 6 {
                        Text("+\(traces.count - 6)")
                            .font(.noonmarkSystem(size: 9))
                            .foregroundStyle(Theme.text3)
                            .padding(.leading, 7)
                    }
                }
                .padding(.top, 3)

                Spacer()
            }
            .padding(.top, 5)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            .frame(height: height, alignment: .top)
            .background(selected ? Theme.accentSoft : isHovered ? Theme.panel2 : Theme.panel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.line).frame(width: 1)
            }
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                }
            }
            .contentShape(Rectangle())
            .background {
                AppE2EViewAnchor(
                    identifier: "calendar.date-cell.\(date.description)",
                    verificationText: selected ? "selected" : ""
                )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(store.displayAccessibilityDate(date))
        .accessibilityValue(
            summary.total == 0
                ? store.copy.emptyDay
                : "\(summary.completed) / \(summary.total)"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func dotColor(for status: TraceStatus) -> Color {
        status.uiStyle.dotColor
    }

    func titleColor(for status: TraceStatus) -> Color {
        status.uiStyle.titleColor
    }
}

struct CalendarDayInsight {
    let stats: DailyReviewStats
    let completionRate: Int
    let continuationSummary: String
    let changeSummary: String
    let riskSummary: String

    var hasEnhancedContent: Bool {
        stats.total >= 0
            && completionRate >= 0
            && continuationSummary.isEmpty == false
            && changeSummary.isEmpty == false
            && riskSummary.isEmpty == false
    }

    @MainActor
    static func make(for date: LocalDate, store: NoonmarkStore) -> CalendarDayInsight {
        let traces = store.engine.getDayTodo(date: date).traces
        let stats = store.engine.dailyReviewStats(date: date)
        let completionRate = stats.total == 0 ? 0 : Int((Double(stats.completed) / Double(stats.total) * 100).rounded())
        let continuedBySeq = traces.filter { $0.continuationSeq > 0 }.count
        let continuationCount = max(stats.continued, continuedBySeq)
        let changedTargets = traces.filter { $0.changedToTraceID != nil }.count
        let pending = max(
            0,
            stats.total
                - stats.completed
                - stats.unfinished
                - stats.continued
                - stats.changed
                - stats.returnedToPool
                - stats.abandoned
        )

        let continuationSummary = store.copy.calendarContinuationSummary(continuationCount)
        let changeSummary = store.copy.calendarChangeSummary(stats.changed + changedTargets)
        let riskSummary = store.copy.calendarRiskSummary(
            position: date < store.today
                ? .history
                : (date > store.today ? .future : .today),
            unresolved: stats.unfinished + stats.abandoned,
            pending: pending,
            total: stats.total
        )

        return CalendarDayInsight(
            stats: stats,
            completionRate: completionRate,
            continuationSummary: continuationSummary,
            changeSummary: changeSummary,
            riskSummary: riskSummary
        )
    }
}

struct CalendarDayInsightPanel: View {
    @EnvironmentObject private var store: NoonmarkStore
    let insight: CalendarDayInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.copy.dayAnalysis)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                Spacer()
                Text(store.copy.completionRate(insight.completionRate))
                    .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                    .foregroundStyle(insight.completionRate == 100 && insight.stats.total > 0 ? Theme.ok : Theme.accent)
                    .monospacedDigit()
            }

            ReviewStatsCard(stats: insight.stats)

            VStack(alignment: .leading, spacing: 7) {
                CalendarInsightRow(label: store.copy.continuation, text: insight.continuationSummary)
                CalendarInsightRow(label: store.copy.change, text: insight.changeSummary)
                CalendarInsightRow(label: store.copy.risk, text: insight.riskSummary)
            }
        }
    }
}

struct CalendarInsightRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .frame(width: 28, alignment: .leading)
            Text(text)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CalendarDetailPanel: View {
    @EnvironmentObject private var store: NoonmarkStore
    var traces: [DayTrace] {
        store.engine.getDayTodo(date: store.selectedCalendarDate).traces.sorted { $0.priority < $1.priority }
    }

    var insight: CalendarDayInsight {
        CalendarDayInsight.make(for: store.selectedCalendarDate, store: store)
    }

    var dayKind: (text: String, background: Color, foreground: Color) {
        if store.selectedCalendarDate == store.today {
            return (
                store.copy.calendarScopeLabel(isToday: true, isHistory: false),
                Theme.accent,
                .white
            )
        }
        if store.selectedCalendarDate < store.today {
            return (
                store.copy.calendarScopeLabel(isToday: false, isHistory: true),
                Theme.chip,
                Theme.text2
            )
        }
        return (
            store.copy.calendarScopeLabel(isToday: false, isHistory: false),
            Theme.accentSoft,
            Theme.accent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.displayFullDate(store.selectedCalendarDate))
                        .font(.noonmarkSystem(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text1)
                        .monospacedDigit()
                    Text(store.weekday(store.selectedCalendarDate))
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                }

                HStack(spacing: 8) {
                    Text(dayKind.text)
                        .font(.noonmarkSystem(size: 11, weight: .semibold))
                        .foregroundStyle(dayKind.foreground)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(dayKind.background))
                    Text(store.copy.taskCount(traces.count))
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
                .padding(.top, 7)

                Button(store.copy.openDayTodo) {
                    store.selectedDate = store.selectedCalendarDate
                    store.page = .day
                }
                .buttonStyle(.plain)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.accent)
                .padding(.top, 9)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line.opacity(0.62)).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    CalendarDayInsightPanel(insight: insight)
                        .padding(.bottom, 2)

                    ForEach(traces, id: \.id) { trace in
                        CalendarDetailRow(trace: trace)
                    }
                    if traces.isEmpty {
                        EmptyState(
                            kind: .calendar,
                            text: store.copy.emptyDay,
                            actionTitle: store.copy.openDayTodo
                        ) {
                            store.selectedDate = store.selectedCalendarDate
                            store.selectPage(.day)
                        }
                            .padding(.vertical, 36)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Theme.panel)
    }
}

struct CalendarDetailRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let trace: DayTrace

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(status: trace.status, scale: .compact)

            VStack(alignment: .leading, spacing: 1) {
                MarkdownInlineText(store.definition(for: trace)?.title ?? "")
                    .font(.noonmarkSystem(size: 12.5, weight: .medium))
                    .foregroundStyle(titleColor)
                    .strikethrough(trace.status == .completed || trace.status == .abandoned)
                    .lineLimit(1)
                if metaText.isEmpty == false {
                    Text(metaText)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
                if let changedTarget = store.changedTarget(for: trace) {
                    ChangedTargetButton(
                        title: changedTarget.definition.title,
                        compact: true
                    ) {
                        store.openChangedTarget(from: trace)
                    }
                }
            }

            Spacer()
            StatusChip(status: trace.status, scale: .compact)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .listRowSurface(selected: false, tint: Theme.accent, cornerRadius: 7, separatorLeadingInset: 36)
    }

    var titleColor: Color {
        trace.status.uiStyle.titleColor
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
        return parts.joined(separator: " · ")
    }
}

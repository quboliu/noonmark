import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

struct DatePickerSheet: View {
    @EnvironmentObject private var store: NoonmarkStore
    let purpose: NoonmarkStore.DatePickerPurpose

    @State private var pickedDate: LocalDate?
    @State private var displayedMonth: LocalDate?
    @State private var validationMessage: String?
    @State private var calendarFocusRequest = 0

    private var initialDate: LocalDate {
        switch purpose {
        case .gotoDay:
            store.selectedDate
        case .deferTrace, .reschedule:
            NoonmarkStore.offset(store.today, by: 1)
        case .schedulePool, .continueTrace:
            store.today
        }
    }

    private var selectedDate: LocalDate {
        pickedDate ?? initialDate
    }

    private var visibleMonth: LocalDate {
        displayedMonth ?? monthStart(containing: initialDate)
    }

    private var monthGrid: WorkspaceMonthGrid {
        NoonmarkStore.monthGrid(
            containing: visibleMonth,
            rowCount: .fixed(MacUIDatePickerLayout.rowCount),
            outsideMonth: .adjacentDates
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleSection
            calendarSection
            footer
        }
        .padding(CGFloat(MacUIDatePickerLayout.outerPadding))
        .frame(width: CGFloat(MacUIDatePickerLayout.sheetWidth))
        .background(Theme.panel)
        .background {
            AppE2EViewAnchor(
                identifier: "date-picker.sheet",
                verificationText: purpose.id
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(purpose.title(copy: store.copy))
        .background {
            DateNavigationKeyboardFocusBridge(
                focusRequest: calendarFocusRequest,
                onMoveCommand: moveSelection,
                onFocusChange: { _ in }
            )
        }
        .onAppear {
            if pickedDate == nil {
                pickedDate = initialDate
            }
            if displayedMonth == nil {
                displayedMonth = monthStart(containing: selectedDate)
            }
            calendarFocusRequest &+= 1
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(purpose.title(copy: store.copy))
                .font(.noonmarkSystem(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .accessibilityAddTraits(.isHeader)
                .background {
                    AppE2EViewAnchor(
                        identifier: "date-picker.title",
                        verificationText: purpose.title(copy: store.copy)
                    )
                }

            if purpose.hasRangeConstraint {
                Text(purpose.rangeHint(copy: store.copy))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        AppE2EViewAnchor(
                            identifier: "date-picker.hint",
                            verificationText: purpose.rangeHint(copy: store.copy)
                        )
                    }
            }
        }
    }

    private var calendarSection: some View {
        VStack(spacing: 8) {
            monthHeader
            weekdayHeader
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(dayCellWidth),
                        spacing: CGFloat(MacUIDatePickerLayout.columnSpacing)
                    ),
                    count: MacUIDatePickerLayout.columnCount
                ),
                spacing: CGFloat(MacUIDatePickerLayout.rowSpacing)
            ) {
                ForEach(monthGrid.slots, id: \.index) { slot in
                    dayCell(for: slot)
                }
            }
            .frame(width: CGFloat(MacUIDatePickerLayout.contentWidth))
            .background {
                AppE2EViewAnchor(
                    identifier: "date-picker.grid",
                    verificationText: "slots=\(monthGrid.slots.count)"
                )
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 6) {
            Text(store.displayMonthYear(visibleMonth))
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .monospacedDigit()
                .background {
                    AppE2EViewAnchor(
                        identifier: "date-picker.month-label",
                        verificationText: String(
                            format: "%04d-%02d",
                            visibleMonth.year,
                            visibleMonth.month
                        )
                    )
                }

            Spacer()

            if purpose.allows(store.today, today: store.today) {
                HeaderButton(store.copy.today) {
                    select(store.today)
                }
                .background {
                    AppE2EViewAnchor(
                        identifier: "date-picker.today",
                        verificationText: store.today.description
                    )
                }
            }

            monthNavigationButton(
                "‹",
                identifier: "date-picker.previous-month",
                accessibilityLabel: store.copy.previousMonth,
                delta: -1
            )
            monthNavigationButton(
                "›",
                identifier: "date-picker.next-month",
                accessibilityLabel: store.copy.nextMonth,
                delta: 1
            )
        }
        .frame(height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize))
    }

    private var weekdayHeader: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .fixed(dayCellWidth),
                    spacing: CGFloat(MacUIDatePickerLayout.columnSpacing)
                ),
                count: MacUIDatePickerLayout.columnCount
            ),
            spacing: 0
        ) {
            ForEach(
                Array(store.calendarWeekdayLabels().enumerated()),
                id: \.offset
            ) { _, label in
                Text(label)
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: dayCellWidth, height: 18)
            }
        }
        .frame(width: CGFloat(MacUIDatePickerLayout.contentWidth))
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
                .overlay(Theme.line)

            HStack(spacing: 8) {
                Text(validationMessage ?? selectionSummary)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(validationMessage == nil ? Theme.text2 : Theme.warn)
                    .lineLimit(1)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Button(store.copy.cancel) {
                    store.showingPicker = nil
                }
                .keyboardShortcut(.cancelAction)
                .background {
                    AppE2EViewAnchor(
                        identifier: "date-picker.cancel",
                        verificationText: store.copy.cancel
                    )
                }

                Button(purpose.confirmationTitle(copy: store.copy)) {
                    confirmSelection()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .background {
                    AppE2EViewAnchor(
                        identifier: "date-picker.confirm",
                        verificationText: purpose.confirmationTitle(copy: store.copy)
                    )
                }
            }
            .frame(minHeight: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize))
        }
    }

    private var dayCellWidth: CGFloat {
        let gaps = Double(MacUIDatePickerLayout.columnCount - 1)
            * MacUIDatePickerLayout.columnSpacing
        return CGFloat(
            (MacUIDatePickerLayout.contentWidth - gaps)
                / Double(MacUIDatePickerLayout.columnCount)
        )
    }

    private var selectionSummary: String {
        "\(store.displayFullDate(selectedDate)) · \(store.weekday(selectedDate))"
    }

    @ViewBuilder
    private func dayCell(for slot: WorkspaceMonthGrid.Slot) -> some View {
        switch slot.content {
        case .blank:
            Color.clear
                .frame(
                    width: dayCellWidth,
                    height: CGFloat(MacUIDatePickerLayout.dayCellHeight)
                )
                .accessibilityHidden(true)
        case let .date(date, isInDisplayedMonth):
            let state = DatePickerDayState(
                isInDisplayedMonth: isInDisplayedMonth,
                isToday: date == store.today,
                isSelected: date == selectedDate,
                isEnabled: purpose.allows(date, today: store.today)
            )
            DatePickerDayButton(
                date: date,
                accessibilityLabel: store.displayAccessibilityDate(date),
                accessibilityValue: store.copy.datePickerDayAccessibilityValue(
                    isToday: state.isToday,
                    isSelected: state.isSelected,
                    isEnabled: state.isEnabled
                ),
                state: state,
                action: { select(date) }
            )
        }
    }

    private func monthNavigationButton(
        _ title: String,
        identifier: String,
        accessibilityLabel: String,
        delta: Int
    ) -> some View {
        let candidate = monthCandidate(by: delta)
        return HeaderButton(
            title,
            accessibilityLabel: accessibilityLabel
        ) {
            guard let candidate else { return }
            displayedMonth = candidate
            calendarFocusRequest &+= 1
        }
        .disabled(candidate == nil)
        .opacity(candidate == nil ? 0.42 : 1)
        .background {
            AppE2EViewAnchor(
                identifier: identifier,
                verificationText: candidate?.description ?? "disabled"
            )
        }
    }

    private func monthCandidate(by delta: Int) -> LocalDate? {
        let shifted = NoonmarkStore.shiftedMonth(from: visibleMonth, by: delta)
        guard let minimumDate = purpose.minimumDate(today: store.today) else {
            return shifted
        }
        return shifted >= monthStart(containing: minimumDate) ? shifted : nil
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let offset: Int
        switch direction {
        case .left:
            offset = -1
        case .right:
            offset = 1
        case .up:
            offset = -7
        case .down:
            offset = 7
        @unknown default:
            return
        }
        select(NoonmarkStore.offset(selectedDate, by: offset))
    }

    private func select(_ date: LocalDate) {
        guard purpose.allows(date, today: store.today) else { return }
        validationMessage = nil
        pickedDate = date
        displayedMonth = monthStart(containing: date)
        calendarFocusRequest &+= 1
    }

    private func monthStart(containing date: LocalDate) -> LocalDate {
        NoonmarkStore.shiftedMonth(from: date, by: 0)
    }

    private func confirmSelection() {
        guard purpose.allows(selectedDate, today: store.today) else {
            validationMessage = purpose.rangeHint(copy: store.copy)
            return
        }
        validationMessage = nil
        store.performDateChoice(selectedDate, for: purpose)
    }
}

private struct DatePickerDayState {
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isEnabled: Bool

    var verificationText: String {
        "selected=\(isSelected ? 1 : 0);"
            + "enabled=\(isEnabled ? 1 : 0);"
            + "outsideMonth=\(isInDisplayedMonth ? 0 : 1)"
    }
}

private struct DatePickerDayButton: View {
    let date: LocalDate
    let accessibilityLabel: String
    let accessibilityValue: String
    let state: DatePickerDayState
    let action: () -> Void

    @State private var isHovered = false

    private var identifier: String {
        "date-picker.day.\(date.description)"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered && state.isEnabled ? Theme.listRowHover : Color.clear)

                Circle()
                    .fill(state.isSelected ? Theme.accent : Color.clear)
                    .overlay {
                        if state.isToday && state.isSelected == false {
                            Circle()
                                .stroke(Theme.accent.opacity(0.78), lineWidth: 1)
                        }
                    }
                    .frame(
                        width: CGFloat(MacUIDatePickerLayout.selectionDiameter),
                        height: CGFloat(MacUIDatePickerLayout.selectionDiameter)
                    )

                Text("\(date.day)")
                    .font(
                        .noonmarkSystem(
                            size: 11.5,
                            weight: state.isSelected ? .semibold : .regular
                        )
                    )
                    .foregroundStyle(foregroundColor)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(MacUIDatePickerLayout.dayCellHeight))
            .contentShape(Rectangle())
            .background {
                AppE2EViewAnchor(
                    identifier: identifier,
                    verificationText: state.verificationText
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(state.isEnabled == false)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("date-picker.action.day.\(date.description)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(state.isSelected ? .isSelected : [])
        .animation(
            Theme.shouldReduceMotion ? nil : .easeOut(duration: 0.12),
            value: state.isSelected
        )
    }

    private var foregroundColor: Color {
        if state.isEnabled == false {
            return Theme.line2.opacity(0.72)
        }
        if state.isSelected {
            return .white
        }
        if state.isToday {
            return Theme.accent
        }
        return state.isInDisplayedMonth ? Theme.text1 : Theme.text3
    }
}

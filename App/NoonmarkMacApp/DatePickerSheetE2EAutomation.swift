import AppKit
import Foundation
import NoonmarkCore

/// Exercises the custom date picker through the signed App and physical
/// WindowServer input. Store access is limited to fixture setup and assertions;
/// every presentation and date mutation in the primary flow uses product UI.
@MainActor
struct DatePickerSheetE2EAutomation: LaunchAutomationRunnable {
    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private struct Fixture {
        let poolChainID: TaskChainID
        let futureTraceID: DayTraceID
        let futureDate: LocalDate
        let unfinishedChainID: TaskChainID
        let unfinishedTraceID: DayTraceID
    }

    private struct SheetPresentation {
        let window: NSWindow
        let identity: AppViewTreeE2E.PresentationWindowIdentity
    }

    private struct ContextMenuEntry {
        let page: NoonmarkStore.Page
        let rowIdentifier: String
        let menuItemPosition: Int
        let purpose: NoonmarkStore.DatePickerPurpose
    }

    private static let fixedToday = LocalDate(year: 2026, month: 7, day: 5)
    private static let julyStart = LocalDate(year: 2026, month: 7, day: 1)
    private static let hitPoints = [
        NSPoint(x: 0.12, y: 0.12),
        NSPoint(x: 0.50, y: 0.12),
        NSPoint(x: 0.88, y: 0.12),
        NSPoint(x: 0.12, y: 0.50),
        NSPoint(x: 0.50, y: 0.50),
        NSPoint(x: 0.88, y: 0.50),
        NSPoint(x: 0.12, y: 0.88),
        NSPoint(x: 0.50, y: 0.88),
        NSPoint(x: 0.88, y: 0.88)
    ]

    private let resultURL: URL
    private let screenshotURL: URL

    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains("--e2e-date-picker-sheet"),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-date-picker-result-url"
              ),
              let screenshotPath = AppLaunchArguments.value(
                  after: "--e2e-date-picker-screenshot-url"
              )
        else {
            return nil
        }
        return Self(
            resultURL: URL(fileURLWithPath: resultPath),
            screenshotURL: URL(fileURLWithPath: screenshotPath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try await exercise(on: store)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        guard store.today == Self.fixedToday else {
            throw Failure.failed(
                "date picker fixed day was \(store.today), expected \(Self.fixedToday)"
            )
        }

        let mainWindow = try await visibleMainWindow()
        let input = try WindowServerInputDriver()
        let fixture = try prepareFixture(on: store)
        store.page = .day
        store.selectedDate = Self.fixedToday
        store.selectedCalendarDate = Self.fixedToday
        store.isDetailRailExpanded = false
        store.showingPicker = nil
        try await activate(mainWindow)

        let firstPresentation = try await openGotoSheet(
            mainWindow: mainWindow,
            input: input
        )
        try verifySheetContract(
            firstPresentation,
            store: store,
            selectedDate: Self.fixedToday,
            purpose: .gotoDay
        )
        try captureSheet(firstPresentation.window)
        try await exerciseMonthHitTargets(
            firstPresentation,
            store: store,
            input: input
        )

        let pointerTarget = LocalDate(year: 2026, month: 7, day: 12)
        try await exerciseDayHitTargets(
            firstPresentation,
            target: pointerTarget,
            reset: Self.fixedToday,
            input: input
        )
        try await verifyPresentationSurvivesRootRefresh(
            firstPresentation,
            selectedDate: pointerTarget,
            store: store
        )
        try await click(
            "date-picker.confirm",
            in: firstPresentation.window,
            input: input
        )
        try await waitForClosed(firstPresentation) {
            store.selectedDate == pointerTarget
                && store.selectedCalendarDate == pointerTarget
                && store.showingPicker == nil
        }

        try await exerciseKeyboardAndReturn(
            store: store,
            mainWindow: mainWindow,
            input: input,
            startingDate: LocalDate(year: 2026, month: 7, day: 31)
        )
        try await exerciseEscape(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseCancel(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await verifyScheduleAndContinueEntries(
            store: store,
            fixture: fixture,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseRescheduleConstraint(
            store: store,
            fixture: fixture,
            mainWindow: mainWindow,
            input: input
        )
        try await verifyEnglishPurposeEntries(
            store: store,
            fixture: fixture,
            mainWindow: mainWindow,
            input: input
        )
    }

    private func captureSheet(_ window: NSWindow) throws {
        do {
            try AppE2EScreenshot.captureContent(
                of: window,
                to: screenshotURL
            )
        } catch {
            throw Failure.failed(
                "date picker sheet screenshot failed: "
                    + error.localizedDescription
            )
        }
    }

    private func prepareFixture(
        on store: NoonmarkStore
    ) throws -> Fixture {
        var timeline = try E2EFixtureTimeline(store: store, eventCount: 6)
        let engine = NoonmarkEngine()
        let poolChainID = try engine.createPoolTask(
            title: "E2E date picker unscheduled task",
            now: try timeline.nextInstant()
        )
        let scheduledChainID = try engine.createPoolTask(
            title: "E2E date picker reschedule task",
            now: try timeline.nextInstant()
        )
        let originalDate = NoonmarkStore.offset(Self.fixedToday, by: 2)
        let traceID = try engine.scheduleFromPool(
            chainID: scheduledChainID,
            date: originalDate,
            today: Self.fixedToday,
            now: try timeline.nextInstant()
        )
        let unfinishedChainID = try engine.createPoolTask(
            title: "E2E date picker unfinished task",
            now: try timeline.nextInstant()
        )
        let yesterday = NoonmarkStore.offset(Self.fixedToday, by: -1)
        let unfinishedTraceID = try engine.scheduleFromPool(
            chainID: unfinishedChainID,
            date: yesterday,
            today: yesterday,
            now: try timeline.nextInstant()
        )
        try engine.settleDays(
            upTo: Self.fixedToday,
            now: try timeline.nextInstant()
        )
        _ = try timeline.finish()
        store.engine = engine
        guard engine.unfinishedPool().first(where: {
            $0.chain.id == unfinishedChainID
        })?.actionPlan == [
            .continueTrace(unfinishedTraceID),
            .abandonChain(unfinishedTraceID)
        ] else {
            throw Failure.failed(
                "date picker unfinished fixture did not expose continue first"
            )
        }
        return Fixture(
            poolChainID: poolChainID,
            futureTraceID: traceID,
            futureDate: originalDate,
            unfinishedChainID: unfinishedChainID,
            unfinishedTraceID: unfinishedTraceID
        )
    }

    private func openGotoSheet(
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws -> SheetPresentation {
        try await activate(mainWindow)
        try await waitUntil("date picker launch action did not render") {
            AppViewTreeE2E.view(
                identifier: "day.header.choose-date-action",
                in: mainWindow
            ) != nil
        }
        try await click(
            "day.header.choose-date-action",
            in: mainWindow,
            input: input
        )
        return try await presentedSheet(mainWindow: mainWindow)
    }

    private func openContextMenuSheet(
        entry: ContextMenuEntry,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws -> SheetPresentation {
        guard entry.menuItemPosition > 0 else {
            throw Failure.failed("date picker menu position must be positive")
        }
        store.page = entry.page
        store.clearSelection()
        store.isDetailRailExpanded = false
        try await activate(mainWindow)
        try await waitUntil(
            "date picker context row did not render: \(entry.rowIdentifier)"
        ) {
            AppViewTreeE2E.view(
                identifier: entry.rowIdentifier,
                in: mainWindow
            ) != nil
        }

        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click(
            entry.rowIdentifier,
            in: mainWindow,
            modifiers: [.control],
            input: input
        )
        try await waitUntil("date picker context menu did not begin tracking") {
            probe.didBeginTracking
        }
        for _ in 0 ..< entry.menuItemPosition {
            try input.postKey(keyCode: 125)
        }
        try input.postKey(keyCode: 36)

        let presentation = try await presentedSheet(mainWindow: mainWindow)
        guard store.showingPicker?.id == entry.purpose.id else {
            throw Failure.failed(
                "date picker context menu opened \(store.showingPicker?.id ?? "nil"), "
                    + "expected \(entry.purpose.id)"
            )
        }
        return presentation
    }

    private func presentedSheet(
        mainWindow: NSWindow
    ) async throws -> SheetPresentation {
        var resolved: SheetPresentation?
        try await waitUntil("date picker was not mapped as a real sheet") {
            guard let identity = AppViewTreeE2E.mappedPresentationWindow(
                identifier: "date-picker.sheet"
            ), identity.mainWindowNumber == mainWindow.windowNumber,
                  let sheetAnchor = AppViewTreeE2E.view(
                      identifier: "date-picker.sheet"
                  ), let sheetWindow = sheetAnchor.window,
                  sheetWindow !== mainWindow,
                  sheetWindow.windowNumber == identity.presentationWindowNumber,
                  sheetWindow.sheetParent === mainWindow,
                  mainWindow.attachedSheet === sheetWindow,
                  NSApp.keyWindow === sheetWindow
            else {
                return false
            }
            resolved = SheetPresentation(
                window: sheetWindow,
                identity: identity
            )
            return true
        }
        guard let resolved else {
            throw Failure.failed("date picker sheet disappeared after mapping")
        }
        return resolved
    }

    private func verifySheetContract(
        _ presentation: SheetPresentation,
        store: NoonmarkStore,
        selectedDate: LocalDate,
        purpose: NoonmarkStore.DatePickerPurpose
    ) throws {
        try assertStable(presentation)
        let sheet = try anchor("date-picker.sheet", in: presentation.window)
        let title = try anchor("date-picker.title", in: presentation.window)
        let month = try anchor("date-picker.month-label", in: presentation.window)
        let previous = try anchor(
            "date-picker.previous-month",
            in: presentation.window
        )
        let next = try anchor("date-picker.next-month", in: presentation.window)
        let grid = try anchor("date-picker.grid", in: presentation.window)
        let cancel = try anchor("date-picker.cancel", in: presentation.window)
        let confirm = try anchor("date-picker.confirm", in: presentation.window)

        let sheetFrame = AppViewTreeE2E.frameInWindow(for: sheet)
        let gridFrame = AppViewTreeE2E.frameInWindow(for: grid)
        guard abs(sheetFrame.width - 340) <= 1,
              abs(presentation.window.frame.width - 340) <= 1
        else {
            throw Failure.failed(
                "date picker sheet width was not 340pt: "
                    + "anchor=\(sheetFrame.width),window=\(presentation.window.frame.width)"
            )
        }
        guard abs(gridFrame.width - 304) <= 1 else {
            throw Failure.failed(
                "date picker grid width was not 304pt: \(gridFrame.width)"
            )
        }
        for control in [previous, next] {
            let frame = AppViewTreeE2E.frameInWindow(for: control)
            guard frame.width >= 28, frame.height >= 28 else {
                throw Failure.failed(
                    "date picker month action was smaller than 28×28pt: \(frame)"
                )
            }
        }
        guard AppViewTreeE2E.verificationText(for: title)
            == purpose.title(copy: store.copy),
            AppViewTreeE2E.verificationText(for: month) == "2026-07",
            AppViewTreeE2E.verificationText(for: cancel) == store.copy.cancel,
            AppViewTreeE2E.verificationText(for: confirm)
                == expectedConfirmationTitle(for: purpose, copy: store.copy)
        else {
            throw Failure.failed("date picker copy or purpose-specific action was wrong")
        }
        if purpose.hasRangeConstraint {
            let hint = try anchor("date-picker.hint", in: presentation.window)
            guard AppViewTreeE2E.verificationText(for: hint)
                == purpose.rangeHint(copy: store.copy)
            else {
                throw Failure.failed("constrained date picker hint was wrong")
            }
        } else if AppViewTreeE2E.hasNoVisibleView(
            identifier: "date-picker.hint"
        ) == false {
            throw Failure.failed("goto date picker rendered a redundant range hint")
        }
        try verifyJulyGrid(
            in: presentation.window,
            selectedDate: selectedDate,
            minimumDate: expectedMinimumDate(for: purpose)
        )
    }

    private func verifyJulyGrid(
        in window: NSWindow,
        selectedDate: LocalDate,
        minimumDate: LocalDate?
    ) throws {
        let firstGridDate = LocalDate(year: 2026, month: 6, day: 29)
        let dates = (0 ..< 42).map {
            NoonmarkStore.offset(firstGridDate, by: $0)
        }
        let expectedIdentifiers = Set(dates.map(dayIdentifier))
        guard AppViewTreeE2E.identifiers(withPrefix: "date-picker.day.")
            == expectedIdentifiers
        else {
            throw Failure.failed("date picker July grid did not expose exactly 42 dates")
        }

        let grid = try anchor("date-picker.grid", in: window)
        let gridFrame = AppViewTreeE2E.frameInWindow(for: grid)
        var cellFrames: [NSRect] = []
        for date in dates {
            let cell = try anchor(dayIdentifier(date), in: window)
            let frame = AppViewTreeE2E.frameInWindow(for: cell)
            let enabled = minimumDate.map { date >= $0 } ?? true
            let expectedState = dayState(
                selected: date == selectedDate,
                enabled: enabled,
                outsideMonth: date.month != 7
            )
            guard AppViewTreeE2E.verificationText(for: cell) == expectedState else {
                throw Failure.failed(
                    "date picker state mismatch for \(date): "
                        + "\(AppViewTreeE2E.verificationText(for: cell) ?? "nil")"
                )
            }
            guard gridFrame.insetBy(dx: -1, dy: -1).contains(frame) else {
                throw Failure.failed("date picker day \(date) escaped its grid")
            }
            cellFrames.append(frame)
        }
        let columnCenters = Set(cellFrames.map { rounded($0.midX) })
        let rowCenters = Set(cellFrames.map { rounded($0.midY) })
        guard columnCenters.count == 7, rowCenters.count == 6 else {
            throw Failure.failed(
                "date picker grid topology was not 7×6: "
                    + "columns=\(columnCenters.count),rows=\(rowCenters.count)"
            )
        }
    }

    private func exerciseMonthHitTargets(
        _ presentation: SheetPresentation,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        var expectedMonth = Self.julyStart
        for point in Self.hitPoints {
            expectedMonth = NoonmarkStore.shiftedMonth(
                from: expectedMonth,
                by: -1
            )
            try await click(
                "date-picker.previous-month",
                in: presentation.window,
                unitPoint: point,
                input: input
            )
            try await waitForMonth(expectedMonth, in: presentation)
        }
        for point in Self.hitPoints {
            expectedMonth = NoonmarkStore.shiftedMonth(
                from: expectedMonth,
                by: 1
            )
            try await click(
                "date-picker.next-month",
                in: presentation.window,
                unitPoint: point,
                input: input
            )
            try await waitForMonth(expectedMonth, in: presentation)
        }
        guard expectedMonth == Self.julyStart else {
            throw Failure.failed("month hit-target probe did not return to July")
        }
        try verifySheetContract(
            presentation,
            store: store,
            selectedDate: Self.fixedToday,
            purpose: .gotoDay
        )
    }

    private func exerciseDayHitTargets(
        _ presentation: SheetPresentation,
        target: LocalDate,
        reset: LocalDate,
        input: WindowServerInputDriver
    ) async throws {
        for (index, point) in Self.hitPoints.enumerated() {
            if index > 0 {
                try await click(
                    dayIdentifier(reset),
                    in: presentation.window,
                    input: input
                )
                try await waitForSelection(
                    reset,
                    deselected: target,
                    in: presentation
                )
            }
            try await click(
                dayIdentifier(target),
                in: presentation.window,
                unitPoint: point,
                input: input
            )
            try await waitForSelection(
                target,
                deselected: reset,
                in: presentation
            )
        }
    }

    private func verifyPresentationSurvivesRootRefresh(
        _ presentation: SheetPresentation,
        selectedDate: LocalDate,
        store: NoonmarkStore
    ) async throws {
        let refreshMessage = "E2E date picker root refresh"
        store.showToast(refreshMessage)
        try await waitUntil("root refresh toast did not render over date picker") {
            guard let toast = AppViewTreeE2E.view(identifier: "app.toast")
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: toast)
                == refreshMessage
        }
        try assertStable(presentation)
        try await waitForSelection(
            selectedDate,
            deselected: Self.fixedToday,
            in: presentation
        )

        store.toastScheduler.cancel()
        store.toast = nil
        try await waitUntil("root refresh toast did not clear") {
            AppViewTreeE2E.hasNoVisibleView(identifier: "app.toast")
        }
        try assertStable(presentation)
        try await waitForSelection(
            selectedDate,
            deselected: Self.fixedToday,
            in: presentation
        )
    }

    private func exerciseKeyboardAndReturn(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver,
        startingDate: LocalDate
    ) async throws {
        let presentation = try await openGotoSheet(
            mainWindow: mainWindow,
            input: input
        )
        try await click(
            dayIdentifier(startingDate),
            in: presentation.window,
            input: input
        )
        let augustStart = LocalDate(year: 2026, month: 8, day: 1)
        let movements: [(CGKeyCode, LocalDate, LocalDate)] = [
            (124, NoonmarkStore.offset(startingDate, by: 1), augustStart),
            (125, NoonmarkStore.offset(startingDate, by: 8), augustStart),
            (123, NoonmarkStore.offset(startingDate, by: 7), augustStart),
            (126, startingDate, Self.julyStart)
        ]
        var previousDate = startingDate
        for (keyCode, expectedDate, expectedMonth) in movements {
            try input.postKey(keyCode: keyCode)
            try await waitForSelection(
                expectedDate,
                deselected: previousDate,
                displayedMonth: expectedMonth,
                in: presentation
            )
            previousDate = expectedDate
        }

        let returnDate = NoonmarkStore.offset(startingDate, by: 1)
        try input.postKey(keyCode: 124)
        try await waitForSelection(
            returnDate,
            deselected: startingDate,
            displayedMonth: augustStart,
            in: presentation
        )
        try input.postKey(keyCode: 36)
        try await waitForClosed(presentation) {
            store.selectedDate == returnDate
                && store.selectedCalendarDate == returnDate
                && store.showingPicker == nil
        }
    }

    private func exerciseEscape(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let unchangedDate = store.selectedDate
        let presentation = try await openGotoSheet(
            mainWindow: mainWindow,
            input: input
        )
        let draftDate = NoonmarkStore.offset(unchangedDate, by: 1)
        try await click(
            dayIdentifier(draftDate),
            in: presentation.window,
            input: input
        )
        try await waitForSelection(
            draftDate,
            deselected: unchangedDate,
            in: presentation
        )
        try input.postKey(keyCode: 53)
        try await waitForClosed(presentation) {
            store.selectedDate == unchangedDate && store.showingPicker == nil
        }
    }

    private func exerciseCancel(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let unchangedDate = store.selectedDate
        let presentation = try await openGotoSheet(
            mainWindow: mainWindow,
            input: input
        )
        let draftDate = NoonmarkStore.offset(unchangedDate, by: 2)
        try await click(
            dayIdentifier(draftDate),
            in: presentation.window,
            input: input
        )
        try await waitForSelection(
            draftDate,
            deselected: unchangedDate,
            in: presentation
        )
        try await click(
            "date-picker.cancel",
            in: presentation.window,
            input: input
        )
        try await waitForClosed(presentation) {
            store.selectedDate == unchangedDate && store.showingPicker == nil
        }
    }

    private func verifyScheduleAndContinueEntries(
        store: NoonmarkStore,
        fixture: Fixture,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let schedulePurpose = NoonmarkStore.DatePickerPurpose.schedulePool(
            fixture.poolChainID
        )
        let schedulePresentation = try await openContextMenuSheet(
            entry: ContextMenuEntry(
                page: .pool,
                rowIdentifier: "workspace.item.pool.\(fixture.poolChainID.description)",
                menuItemPosition: 3,
                purpose: schedulePurpose
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try verifySheetContract(
            schedulePresentation,
            store: store,
            selectedDate: Self.fixedToday,
            purpose: schedulePurpose
        )
        try input.postKey(keyCode: 53)
        try await waitForClosed(schedulePresentation) {
            store.showingPicker == nil
        }

        let continuePurpose = NoonmarkStore.DatePickerPurpose.continueTrace(
            fixture.unfinishedTraceID
        )
        let continuePresentation = try await openContextMenuSheet(
            entry: ContextMenuEntry(
                page: .unfinished,
                rowIdentifier: "workspace.item.unfinished.\(fixture.unfinishedChainID.description)",
                menuItemPosition: 1,
                purpose: continuePurpose
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try verifySheetContract(
            continuePresentation,
            store: store,
            selectedDate: Self.fixedToday,
            purpose: continuePurpose
        )
        try input.postKey(keyCode: 53)
        try await waitForClosed(continuePresentation) {
            store.showingPicker == nil
        }
    }

    private func exerciseRescheduleConstraint(
        store: NoonmarkStore,
        fixture: Fixture,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let purpose = NoonmarkStore.DatePickerPurpose.reschedule(
            fixture.futureTraceID
        )
        let presentation = try await openContextMenuSheet(
            entry: ContextMenuEntry(
                page: .future,
                rowIdentifier: "workspace.item.future.\(fixture.futureTraceID.description)",
                menuItemPosition: 2,
                purpose: purpose
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        let tomorrow = NoonmarkStore.offset(Self.fixedToday, by: 1)
        try verifySheetContract(
            presentation,
            store: store,
            selectedDate: tomorrow,
            purpose: purpose
        )

        let todayIdentifier = dayIdentifier(Self.fixedToday)
        let today = try anchor(todayIdentifier, in: presentation.window)
        guard AppViewTreeE2E.verificationText(for: today)
            == dayState(selected: false, enabled: false, outsideMonth: false)
        else {
            throw Failure.failed("reschedule picker did not disable today")
        }
        try await click(
            todayIdentifier,
            in: presentation.window,
            input: input
        )
        try await waitUntil("disabled reschedule date changed the draft") {
            guard AppViewTreeE2E.isPresentationWindowOpen(
                presentation.identity
            ), let today = AppViewTreeE2E.view(
                identifier: todayIdentifier,
                in: presentation.window
            ), let tomorrow = AppViewTreeE2E.view(
                identifier: self.dayIdentifier(tomorrow),
                in: presentation.window
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: today)
                    == self.dayState(
                        selected: false,
                        enabled: false,
                        outsideMonth: false
                    )
                && AppViewTreeE2E.verificationText(for: tomorrow)
                    == self.dayState(
                        selected: true,
                        enabled: true,
                        outsideMonth: false
                    )
        }
        guard store.engine.traces[fixture.futureTraceID]?.date == fixture.futureDate
        else {
            throw Failure.failed("disabled reschedule date mutated the trace")
        }
        try assertStable(presentation)
        try await click(
            "date-picker.cancel",
            in: presentation.window,
            input: input
        )
        try await waitForClosed(presentation) {
            store.showingPicker == nil
                && store.engine.traces[fixture.futureTraceID]?.date
                    == fixture.futureDate
        }
    }

    private func verifyEnglishPurposeEntries(
        store: NoonmarkStore,
        fixture: Fixture,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        store.setLanguage(.english)
        try await waitUntil("date picker fixture did not switch to English") {
            store.engine.preferences.language == .english
        }
        store.page = .day
        store.selectedDate = Self.fixedToday
        store.selectedCalendarDate = Self.fixedToday
        store.clearSelection()
        try await activate(mainWindow)
        try await waitUntil("date picker English day header did not render") {
            guard let action = AppViewTreeE2E.view(
                identifier: "day.header.choose-date-action",
                in: mainWindow
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: action)
                == store.copy.chooseDate
        }

        let gotoPresentation = try await openGotoSheet(
            mainWindow: mainWindow,
            input: input
        )
        try verifySheetContract(
            gotoPresentation,
            store: store,
            selectedDate: Self.fixedToday,
            purpose: .gotoDay
        )
        try input.postKey(keyCode: 53)
        try await waitForClosed(gotoPresentation) {
            store.showingPicker == nil
        }

        try await verifyScheduleAndContinueEntries(
            store: store,
            fixture: fixture,
            mainWindow: mainWindow,
            input: input
        )

        let reschedulePurpose = NoonmarkStore.DatePickerPurpose.reschedule(
            fixture.futureTraceID
        )
        let reschedulePresentation = try await openContextMenuSheet(
            entry: ContextMenuEntry(
                page: .future,
                rowIdentifier: "workspace.item.future.\(fixture.futureTraceID.description)",
                menuItemPosition: 2,
                purpose: reschedulePurpose
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try verifySheetContract(
            reschedulePresentation,
            store: store,
            selectedDate: NoonmarkStore.offset(Self.fixedToday, by: 1),
            purpose: reschedulePurpose
        )
        try input.postKey(keyCode: 53)
        try await waitForClosed(reschedulePresentation) {
            store.showingPicker == nil
        }
    }

    private func waitForMonth(
        _ date: LocalDate,
        in presentation: SheetPresentation
    ) async throws {
        let expected = monthText(date)
        try await waitUntil("date picker month did not become \(expected)") {
            guard AppViewTreeE2E.isPresentationWindowOpen(
                presentation.identity
            ), let month = AppViewTreeE2E.view(
                identifier: "date-picker.month-label",
                in: presentation.window
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: month) == expected
        }
        try assertStable(presentation)
    }

    private func waitForSelection(
        _ selected: LocalDate,
        deselected: LocalDate,
        displayedMonth: LocalDate? = nil,
        in presentation: SheetPresentation
    ) async throws {
        let expectedMonth = displayedMonth
            ?? NoonmarkStore.shiftedMonth(from: selected, by: 0)
        try await waitUntil("date picker did not select \(selected)") {
            guard AppViewTreeE2E.isPresentationWindowOpen(
                presentation.identity
            ), let month = AppViewTreeE2E.view(
                identifier: "date-picker.month-label",
                in: presentation.window
            ), let selectedView = AppViewTreeE2E.view(
                identifier: self.dayIdentifier(selected),
                in: presentation.window
            ), let deselectedView = AppViewTreeE2E.view(
                identifier: self.dayIdentifier(deselected),
                in: presentation.window
            ) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: month)
                    == self.monthText(expectedMonth)
                && AppViewTreeE2E.verificationText(for: selectedView)
                    == self.dayState(
                        selected: true,
                        enabled: true,
                        outsideMonth: self.isOutsideMonth(
                            selected,
                            displayedMonth: expectedMonth
                        )
                    )
                && AppViewTreeE2E.verificationText(for: deselectedView)
                    == self.dayState(
                        selected: false,
                        enabled: true,
                        outsideMonth: self.isOutsideMonth(
                            deselected,
                            displayedMonth: expectedMonth
                        )
                    )
        }
        try assertStable(presentation)
    }

    private func waitForClosed(
        _ presentation: SheetPresentation,
        stateMatches: @MainActor () -> Bool
    ) async throws {
        try await waitUntil("date picker sheet did not close cleanly") {
            AppViewTreeE2E.isPresentationWindowOpen(presentation.identity) == false
                && AppViewTreeE2E.hasNoAttachedSheets()
                && stateMatches()
        }
    }

    private func click(
        _ identifier: String,
        in expectedWindow: NSWindow,
        unitPoint: NSPoint = NSPoint(x: 0.5, y: 0.5),
        modifiers: NSEvent.ModifierFlags = [],
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentView = AppViewTreeE2E.view(
                identifier: identifier,
                in: expectedWindow
            ), currentView.window === expectedWindow,
                  currentView.isHiddenOrHasHiddenAncestor == false,
                  currentView.bounds.width > 0,
                  currentView.bounds.height > 0
            else {
                throw Failure.failed(
                    "date picker target changed before mouseDown: \(identifier)"
                )
            }
            let point = currentView.convert(
                NSPoint(
                    x: currentView.bounds.minX
                        + currentView.bounds.width * unitPoint.x,
                    y: currentView.bounds.minY
                        + currentView.bounds.height * unitPoint.y
                ),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: point,
                in: expectedWindow
            )
        }
        do {
            try await input.postClick(
                at: try resolveTarget(),
                modifiers: modifiers,
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "date picker WindowServer click failed for \(identifier): "
                    + error.localizedDescription
            )
        }
    }

    private func anchor(
        _ identifier: String,
        in window: NSWindow
    ) throws -> NSView {
        guard let view = AppViewTreeE2E.view(
            identifier: identifier,
            in: window
        ), view.window === window else {
            throw Failure.failed("date picker anchor was missing: \(identifier)")
        }
        return view
    }

    private func assertStable(
        _ presentation: SheetPresentation
    ) throws {
        guard AppViewTreeE2E.isPresentationWindowOpen(presentation.identity),
              AppViewTreeE2E.mappedPresentationWindow(
                  identifier: "date-picker.sheet"
              ) == presentation.identity,
              AppViewTreeE2E.view(
                  identifier: "date-picker.sheet",
                  in: presentation.window
              )?.window === presentation.window
        else {
            throw Failure.failed("date picker presentation identity changed")
        }
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var window: NSWindow?
        try await waitUntil("date picker main window was not visible") {
            window = NSApp.windows.first {
                $0 is NoonmarkWindow
                    && $0.isVisible
                    && $0.isMiniaturized == false
            }
            return window != nil
        }
        guard let window else {
            throw Failure.failed("date picker main window disappeared")
        }
        return window
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("date picker main window did not become active") {
            NSApp.isActive && window.isMainWindow && window.isKeyWindow
        }
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func dayIdentifier(_ date: LocalDate) -> String {
        "date-picker.day.\(date.description)"
    }

    private func dayState(
        selected: Bool,
        enabled: Bool,
        outsideMonth: Bool
    ) -> String {
        "selected=\(selected ? 1 : 0);"
            + "enabled=\(enabled ? 1 : 0);"
            + "outsideMonth=\(outsideMonth ? 1 : 0)"
    }

    private func expectedMinimumDate(
        for purpose: NoonmarkStore.DatePickerPurpose
    ) -> LocalDate? {
        purpose.minimumDate(today: Self.fixedToday)
    }

    private func expectedConfirmationTitle(
        for purpose: NoonmarkStore.DatePickerPurpose,
        copy: AppCopy
    ) -> String {
        purpose.confirmationTitle(copy: copy)
    }

    private func isOutsideMonth(
        _ date: LocalDate,
        displayedMonth: LocalDate
    ) -> Bool {
        date.year != displayedMonth.year || date.month != displayedMonth.month
    }

    private func monthText(_ date: LocalDate) -> String {
        String(format: "%04d-%02d", date.year, date.month)
    }

    private func rounded(_ value: CGFloat) -> Int {
        Int((value * 10).rounded())
    }

    @MainActor
    private final class MenuTrackingProbe: @unchecked Sendable {
        private(set) var didBeginTracking = false
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.didBeginTracking = true
                }
            }
        }

        func stop() {
            guard let observer else { return }
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

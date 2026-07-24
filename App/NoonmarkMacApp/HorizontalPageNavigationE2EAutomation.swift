import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

@MainActor
struct HorizontalPageNavigationE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-horizontal-page-navigation-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
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
            E2EApplicationTermination.schedule()
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let input = try WindowServerInputDriver()
        try await exercise(.day, on: store, input: input)
        try await exercise(.calendar, on: store, input: input)
    }

    private func exercise(
        _ surface: Surface,
        on store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        store.page = surface.page
        surface.resetSelection(in: store)
        guard AppViewTreeE2E.requestMainWindowActivation() else {
            throw Failure.failed("\(surface.name) 主窗口无法请求激活")
        }
        try await waitUntil("\(surface.name) 主窗口或目标区域没有就绪") {
            AppViewTreeE2E.mainWindowHasInteractionIdentity()
                && AppViewTreeE2E.view(
                    identifier: surface.anchorIdentifier
                ) != nil
        }

        let initialValue = surface.selectedValue(in: store)
        let expectedNextValue = surface.shiftedValue(
            from: initialValue,
            by: 1
        )
        try await swipe(
            .next,
            surface: surface,
            input: input
        )
        try await waitUntil(
            "\(surface.name) 向左滑动没有切到下一\(surface.unitName)"
        ) {
            surface.selectedValue(in: store) == expectedNextValue
                && surface.renderedHeaderMatches(store)
        }

        let expectedPreviousValue = surface.shiftedValue(
            from: expectedNextValue,
            by: -1
        )
        try await swipe(
            .previous,
            surface: surface,
            input: input
        )
        try await waitUntil(
            "\(surface.name) 向右滑动没有切到上一\(surface.unitName)"
        ) {
            surface.selectedValue(in: store) == expectedPreviousValue
                && surface.renderedHeaderMatches(store)
        }
    }

    private func swipe(
        _ direction: HorizontalPageNavigationDirection,
        surface: Surface,
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget = {
            try targetCoordinate(
                identifier: surface.anchorIdentifier,
                input: input
            )
        }
        let coordinate = try resolveTarget()
        try await input.postHorizontalTrackpadSwipe(
            at: coordinate,
            toward: direction,
            resolveTarget: resolveTarget
        )
    }

    private func targetCoordinate(
        identifier: String,
        input: WindowServerInputDriver
    ) throws -> WindowServerInputDriver.PointerCoordinate {
        guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
              let target = AppViewTreeE2E.view(
                  identifier: identifier,
                  in: window
              )
        else {
            throw Failure.failed("触控板目标区域 \(identifier) 已消失")
        }
        let point = target.convert(
            NSPoint(x: target.bounds.midX, y: target.bounds.midY),
            to: nil
        )
        return try input.pointerCoordinate(windowPoint: point, in: window)
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private enum Surface {
        case day
        case calendar

        var page: NoonmarkStore.Page {
            switch self {
            case .day: .day
            case .calendar: .calendar
            }
        }

        var name: String {
            switch self {
            case .day: "Day Todo"
            case .calendar: "日历"
            }
        }

        var unitName: String {
            switch self {
            case .day: "天"
            case .calendar: "月"
            }
        }

        var anchorIdentifier: String {
            switch self {
            case .day: "day.header.date"
            case .calendar: "calendar.header.month"
            }
        }

        func resetSelection(in store: NoonmarkStore) {
            switch self {
            case .day:
                store.selectedDate = store.today
            case .calendar:
                store.selectedCalendarDate = store.today
            }
        }

        func selectedValue(in store: NoonmarkStore) -> LocalDate {
            switch self {
            case .day:
                store.selectedDate
            case .calendar:
                store.selectedCalendarDate
            }
        }

        func shiftedValue(
            from date: LocalDate,
            by offset: Int
        ) -> LocalDate {
            switch self {
            case .day:
                NoonmarkStore.offset(date, by: offset)
            case .calendar:
                NoonmarkStore.shiftedMonth(from: date, by: offset)
            }
        }

        func renderedHeaderMatches(_ store: NoonmarkStore) -> Bool {
            guard let header = AppViewTreeE2E.view(
                identifier: anchorIdentifier
            ) else {
                return false
            }
            let expectedText = switch self {
            case .day:
                store.displayFullDate(store.selectedDate)
            case .calendar:
                store.displayMonthYear(store.selectedCalendarDate)
            }
            return AppViewTreeE2E.verificationText(for: header)
                == expectedText
        }
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }
}

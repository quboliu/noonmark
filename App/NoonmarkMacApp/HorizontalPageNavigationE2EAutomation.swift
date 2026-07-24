import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

@MainActor
struct HorizontalPageNavigationE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL
    let screenshotURL: URL

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-horizontal-page-navigation-result-url"
        ), let screenshotPath = AppLaunchArguments.value(
            after: "--e2e-horizontal-page-navigation-screenshot-url"
        ) else {
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
            E2EApplicationTermination.schedule()
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let input = try WindowServerInputDriver()
        guard store.horizontalPageNavigationSwipeDirection == .book else {
            throw Failure.failed("滑动方向默认值不是翻书方向")
        }
        try await exercise(
            .day,
            swipeDirection: .book,
            on: store,
            input: input
        )
        try await exercise(
            .calendar,
            swipeDirection: .book,
            on: store,
            input: input
        )

        let settingsWindow = try await selectReversedDirection(
            on: store,
            input: input
        )
        try capture(settingsWindow)
        guard HorizontalSwipePreferenceRepository().load()
            == .reversed
        else {
            throw Failure.failed("反向滑动设置没有持久化到本机偏好")
        }
        try await closeSettingsAndActivateMainWindow(settingsWindow)

        try await exercise(
            .day,
            swipeDirection: .reversed,
            on: store,
            input: input
        )
        try await exercise(
            .calendar,
            swipeDirection: .reversed,
            on: store,
            input: input
        )
    }

    private func exercise(
        _ surface: Surface,
        swipeDirection: HorizontalPageNavigationSwipeDirection,
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
        let leftSwipeOffset = swipeDirection == .book ? 1 : -1
        let expectedLeftSwipeValue = surface.shiftedValue(
            from: initialValue,
            by: leftSwipeOffset
        )
        try await swipe(
            .left,
            surface: surface,
            input: input
        )
        try await waitUntil(
            "\(surface.name) \(swipeDirection.rawValue) 向左滑动方向错误"
        ) {
            surface.selectedValue(in: store) == expectedLeftSwipeValue
                && surface.renderedHeaderMatches(store)
        }

        let expectedRightSwipeValue = surface.shiftedValue(
            from: expectedLeftSwipeValue,
            by: -leftSwipeOffset
        )
        try await swipe(
            .right,
            surface: surface,
            input: input
        )
        try await waitUntil(
            "\(surface.name) \(swipeDirection.rawValue) 向右滑动方向错误"
        ) {
            surface.selectedValue(in: store) == expectedRightSwipeValue
                && surface.renderedHeaderMatches(store)
        }
    }

    private func swipe(
        _ direction: WindowServerInputDriver
            .HorizontalTrackpadSwipeDirection,
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

    private func selectReversedDirection(
        on store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws -> NSWindow {
        guard let mainWindow = NSApp.windows.first(
            where: { $0 is NoonmarkWindow }
        ), NSApp.sendAction(
            NoonmarkMenuAction.showSettings,
            to: nil,
            from: nil
        )
        else {
            throw Failure.failed("无法从主窗口打开设置")
        }

        var settingsWindow: NSWindow?
        try await waitUntil("滑动方向设置没有出现在原生设置窗口") {
            settingsWindow = NSApp.windows.first {
                $0.identifier
                    == NoonmarkSettingsWindowController.windowIdentifier
                    && $0.isVisible
                    && $0.isMiniaturized == false
            }
            guard let settingsWindow else { return false }
            settingsWindow.makeKeyAndOrderFront(nil)
            return NSApp.keyWindow === settingsWindow
                && ReadOnlyAccessibilityTarget.uniqueElement(
                    identifier: "settings.preferences.swipe-direction",
                    enabled: true
                )?.frame != nil
        }
        guard let settingsWindow,
              let frame = ReadOnlyAccessibilityTarget.uniqueElement(
                  identifier: "settings.preferences.swipe-direction",
                  enabled: true
              )?.frame
        else {
            throw Failure.failed("无法解析滑动方向设置的可访问性位置")
        }

        let point = CGPoint(
            x: frame.minX + frame.width * 0.75,
            y: frame.midY
        )
        let resolveTarget = {
            guard NSApp.keyWindow === settingsWindow,
                  let currentFrame = ReadOnlyAccessibilityTarget.uniqueElement(
                      identifier: "settings.preferences.swipe-direction",
                      enabled: true
                  )?.frame
            else {
                throw Failure.failed("滑动方向设置在点击前发生变化")
            }
            return try input.pointerCoordinate(
                quartzPoint: CGPoint(
                    x: currentFrame.minX + currentFrame.width * 0.75,
                    y: currentFrame.midY
                ),
                in: settingsWindow
            )
        }
        try await input.postClick(
            at: input.pointerCoordinate(
                quartzPoint: point,
                in: settingsWindow
            ),
            modifiers: [],
            resolveTarget: resolveTarget
        )
        try await waitUntil("设置界面的反向选项没有生效") {
            store.horizontalPageNavigationSwipeDirection == .reversed
        }
        guard mainWindow.isVisible else {
            throw Failure.failed("设置交互期间主窗口意外消失")
        }
        return settingsWindow
    }

    private func closeSettingsAndActivateMainWindow(
        _ settingsWindow: NSWindow
    ) async throws {
        settingsWindow.performClose(nil)
        try await waitUntil("设置窗口没有关闭") {
            settingsWindow.isVisible == false
        }
        guard AppViewTreeE2E.requestMainWindowActivation() else {
            throw Failure.failed("关闭设置后无法重新激活主窗口")
        }
        try await waitUntil("关闭设置后主窗口没有成为交互窗口") {
            AppViewTreeE2E.mainWindowHasInteractionIdentity()
        }
    }

    private func capture(_ window: NSWindow) throws {
        guard let contentView = window.contentView,
              contentView.bounds.width > 0,
              contentView.bounds.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(
                  in: contentView.bounds
              )
        else {
            throw Failure.failed("滑动方向设置截图缓冲区不可用")
        }
        window.displayIfNeeded()
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw Failure.failed("滑动方向设置截图编码失败")
        }
        try data.write(to: screenshotURL, options: .atomic)
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

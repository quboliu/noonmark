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

struct DateStripE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> DateStripE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-date-strip-selection") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-date-strip-result-url")
            .map { URL(fileURLWithPath: $0) }
        return DateStripE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.page = .day
            store.selectedDate = store.today
            let initialDates = store.dateStripDates()
            guard initialDates == (-6...7).map({ NoonmarkStore.offset(store.today, by: $0) }),
                  store.selectedDateStripIndex == 6
            else {
                throw DateStripE2EAutomationError.failed("today index did not match 14-day strip")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: 1)
            guard store.selectedDateStripIndex == 7 else {
                throw DateStripE2EAutomationError.failed("next-day index did not move by one cell")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: -6)
            guard store.selectedDateStripIndex == 0 else {
                throw DateStripE2EAutomationError.failed("leading strip date did not map to first cell")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: 8)
            guard store.dateStripDates() == (8...21).map({ NoonmarkStore.offset(store.today, by: $0) }),
                  store.selectedDateStripIndex == 0
            else {
                throw DateStripE2EAutomationError.failed("forward boundary did not advance to the next 14-day strip")
            }

            store.selectedDate = NoonmarkStore.offset(store.today, by: -7)
            guard store.dateStripDates() == (-20 ... -7).map({ NoonmarkStore.offset(store.today, by: $0) }),
                  store.selectedDateStripIndex == 13
            else {
                throw DateStripE2EAutomationError.failed("backward boundary did not move to the previous 14-day strip")
            }

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum DateStripE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct KeyboardDateNavigationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> KeyboardDateNavigationE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-keyboard-date-navigation") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-keyboard-date-result-url")
            .map { URL(fileURLWithPath: $0) }
        return KeyboardDateNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let resultURL else {
                throw KeyboardDateNavigationE2EAutomationError.failed("missing result URL")
            }
            DateNavigationUIE2EDriver.start(store: store, resultURL: resultURL)
        } catch {
            try? writeResult("failed: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum KeyboardDateNavigationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct DetailRailLayoutE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> DetailRailLayoutE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-detail-rail-layout"),
              let path = AppLaunchArguments.value(
                  after: "--e2e-detail-rail-result-url"
              )
        else {
            return nil
        }
        return DetailRailLayoutE2EAutomation(
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .day
        store.clearSelection()
        store.isDetailRailExpanded = false
        DetailRailLayoutUIE2EDriver.start(store: store, resultURL: resultURL)
    }
}

struct ZhulongNavigationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> ZhulongNavigationE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-zhulong-navigation") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-zhulong-navigation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return ZhulongNavigationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.setZhulongPageEnabled(false)
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong entry remained visible")
            store.selectPage(.zhulong)
            try expect(store.page == .day, "disabled zhulong selection bypassed the visible-page guard")

            store.setZhulongPageEnabled(true)
            try expect(store.visibleNavigationPages.contains(.zhulong), "enabled zhulong was not visible")
            store.setAutomaticClassificationEnabled(false)
            try expect(
                store.visibleNavigationPages.contains(.zhulong),
                "disabling automatic classification hid the Zhulong page"
            )
            try expect(
                store.zhulongProviderDraft.enabled == false,
                "automatic classification switch changed Provider enabled state"
            )
            store.setAutomaticClassificationEnabled(true)
            store.selectPage(.zhulong)
            try expect(store.page == .zhulong, "enabled zhulong selection did not open the page")
            store.zhulongWorkspace.showHome()
            try expect(store.shouldShowDetailRail == false, "empty zhulong home kept the detail rail visible")
            try expect(ZhulongHomeIntentResolver.task(for: "结束今天并安排明天") == .dailyReview, "review intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "给任务池重新排期") == .scheduling, "scheduling intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "帮我整理分组") == .classification, "group intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "整理标签") == .classification, "label intent was routed incorrectly")
            try expect(ZhulongHomeIntentResolver.task(for: "梳理一个模糊任务") == .taskDecomposition, "default intent was routed incorrectly")

            let sessionCount = store.zhulongWorkspace.sessions.count
            store.startZhulongWorkspaceSession(intent: "结束今天并安排明天")
            try expect(store.zhulongWorkspace.sessions.count == sessionCount + 1, "workspace session was not created")
            try expect(store.zhulongWorkspace.selectedSession?.phase == .scopeReview, "new session bypassed scope review")
            try expect(store.zhulongWorkspace.selectedSession?.purpose == .freeform, "natural chat intent became a workflow")
            store.authorizeCurrentZhulongWorkspaceSession()
            try expect(store.zhulongWorkspace.selectedSession?.phase == .readyForProvider, "scope authorization was not persisted")

            store.requestZhulongDailyReviewFromReviewRail()
            try expect(
                store.zhulongWorkspace.selectedSession?.purpose == .dailyClose,
                "explicit daily review entry lost its workflow"
            )

            store.zhulongProviderDraft.enabled = false
            try expect(
                store.visibleNavigationPages.contains(.zhulong),
                "disabling Provider hid the independently enabled Zhulong page"
            )
            store.setZhulongPageEnabled(false)
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong entry remained visible")
            try expect(store.page == .day, "disabling zhulong did not leave the hidden workspace")
            try expect(
                store.isAutomaticClassificationEnabled,
                "disabling the Zhulong page disabled automatic classification"
            )

            if let resultURL {
                ZhulongNavigationUIE2EDriver.start(store: store, resultURL: resultURL)
            }
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.terminate(nil)
            }
        }
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ZhulongNavigationE2EAutomationError.failed(message) }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum ZhulongNavigationE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct WindowResizeE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WindowResizeE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-window-resize-probe") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-window-resize-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WindowResizeE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
                throw WindowResizeE2EAutomationError.failed("missing NoonmarkWindow")
            }
            guard window.styleMask.contains(.resizable) else {
                throw WindowResizeE2EAutomationError.failed("window was not resizable")
            }
            guard window.minSize == NoonmarkVisualMetrics.minimumSize else {
                throw WindowResizeE2EAutomationError.failed(
                    "window minSize was not preserved: actual=\(NSStringFromSize(window.minSize)) " +
                        "content=\(NSStringFromSize(window.contentMinSize)) " +
                        "expected=\(NSStringFromSize(NoonmarkVisualMetrics.minimumSize))"
                )
            }
            let expectedContentMinimum = window.contentRect(
                forFrameRect: NSRect(
                    origin: .zero,
                    size: NoonmarkVisualMetrics.minimumSize
                )
            ).size
            guard window.contentMinSize == expectedContentMinimum else {
                throw WindowResizeE2EAutomationError.failed(
                    "window contentMinSize did not match AppKit frame conversion: " +
                        "actual=\(NSStringFromSize(window.contentMinSize)) " +
                        "expected=\(NSStringFromSize(expectedContentMinimum))"
                )
            }
            guard Int(window.frame.width.rounded()) == Int(NoonmarkVisualMetrics.launchSize.width),
                  Int(window.frame.height.rounded()) == Int(NoonmarkVisualMetrics.launchSize.height)
            else {
                throw WindowResizeE2EAutomationError.failed("window launch size was not preserved")
            }

            let originalFrame = window.frame
            let resizedFrame = NSRect(
                x: originalFrame.minX,
                y: originalFrame.maxY - NoonmarkVisualMetrics.minimumSize.height,
                width: NoonmarkVisualMetrics.minimumSize.width,
                height: NoonmarkVisualMetrics.minimumSize.height
            )
            window.setFrame(resizedFrame, display: true)
            guard Int(window.frame.width.rounded()) == Int(NoonmarkVisualMetrics.minimumSize.width),
                  Int(window.frame.height.rounded()) == Int(NoonmarkVisualMetrics.minimumSize.height)
            else {
                throw WindowResizeE2EAutomationError.failed("window frame did not resize")
            }

            window.zoom(nil)
            guard window.frame != resizedFrame else {
                throw WindowResizeE2EAutomationError.failed("window zoom did not change frame")
            }
            window.setFrame(originalFrame, display: true)

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum WindowResizeE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct WindowCloseBehaviorE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> WindowCloseBehaviorE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-window-close-behavior-probe") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-window-close-behavior-result-url")
            .map { URL(fileURLWithPath: $0) }
        return WindowCloseBehaviorE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                guard let delegate = NSApp.delegate as? NoonmarkMacApp else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("missing app delegate")
                }
                guard delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("closing last window would terminate app")
                }
                guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }) else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("missing NoonmarkWindow")
                }
                guard let closeButton = window.standardWindowButton(.closeButton),
                      AppViewTreeE2E.click(closeButton)
                else {
                    throw WindowCloseBehaviorE2EAutomationError.failed(
                        "native close button did not accept a real mouse event"
                    )
                }

                try await Task.sleep(nanoseconds: 250_000_000)

                let visibleNoonmarkWindows = NSApp.windows.filter { $0 is NoonmarkWindow && $0.isVisible }
                guard visibleNoonmarkWindows.isEmpty else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("window remained visible after close")
                }

                guard delegate.applicationShouldHandleReopen(
                    NSApp,
                    hasVisibleWindows: false
                ) else {
                    throw WindowCloseBehaviorE2EAutomationError.failed(
                        "dock activation was not handled"
                    )
                }
                try await Task.sleep(nanoseconds: 250_000_000)

                guard window.identifier == NoonmarkMainWindowState.identifier,
                      NSApp.windows.contains(where: {
                          $0 === window && $0.isVisible && $0.isKeyWindow
                      })
                else {
                    throw WindowCloseBehaviorE2EAutomationError.failed("window did not reopen after dock activation")
                }

                try writeResult("ok")
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
            }

            store.persist()
            NSApp.terminate(nil)
        }
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

private enum WindowCloseBehaviorE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct SummarySidebarE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> SummarySidebarE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-summary-sidebar-probe") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-summary-sidebar-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SummarySidebarE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                let fixture = try installFixture(on: store)
                let input = try WindowServerInputDriver()
                try await exerciseLocalSummaryRails(
                    store: store,
                    poolChainID: fixture.poolChainID,
                    input: input
                )
                try await exerciseCalendarAndTimeline(
                    store: store,
                    fixture: fixture
                )
                try writeResult("ok")
            } catch {
                if let resultURL {
                    AppViewTreeE2E.writeDump(beside: resultURL)
                }
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    @MainActor
    private func installFixture(
        on store: NoonmarkStore
    ) throws -> Fixture {
        store.engine = NoonmarkEngine()
        store.setLanguage(.chinese)
        store.zhulongProviderDraft.enabled = false
        store.setZhulongPageEnabled(false)
        var timeline = try E2EFixtureTimeline(
            store: store,
            eventCount: 26
        )
        let today = timeline.today
        let yesterday = NoonmarkStore.offset(today, by: -1)
        let tomorrow = NoonmarkStore.offset(today, by: 1)

        let poolChainID = try store.engine.createPoolTask(
            title: "E2E 本地摘要任务池",
            descriptionText: "本地摘要不依赖烛龙。",
            now: try timeline.nextInstant()
        )

        let futureChainID = try store.engine.createPoolTask(
            title: "E2E 本地摘要未来计划",
            now: try timeline.nextInstant()
        )
        _ = try store.engine.scheduleFromPool(
            chainID: futureChainID,
            date: tomorrow,
            today: today,
            now: try timeline.nextInstant()
        )

        let unfinishedChainID = try store.engine.createPoolTask(
            title: "E2E 已延续待完成",
            now: try timeline.nextInstant()
        )
        let historicalTraceID = try store.engine.scheduleFromPool(
            chainID: unfinishedChainID,
            date: yesterday,
            today: yesterday,
            now: try timeline.nextInstant()
        )
        try store.engine.settleDays(
            upTo: today,
            now: try timeline.nextInstant()
        )
        let activeTraceID = try store.engine.continueUnfinishedTrace(
            traceID: historicalTraceID,
            targetDate: today,
            today: today,
            now: try timeline.nextInstant()
        )

        let completedChainID = try store.engine.createPoolTask(
            title: "E2E 日历完成热度",
            now: try timeline.nextInstant()
        )
        let completedTraceID = try store.engine.scheduleFromPool(
            chainID: completedChainID,
            date: today,
            today: today,
            now: try timeline.nextInstant()
        )
        try store.engine.markCompleted(
            traceID: completedTraceID,
            today: today,
            now: try timeline.nextInstant()
        )

        for index in 1 ... 4 {
            let chainID = try store.engine.createPoolTask(
                title: "E2E 当日风险文案 \(index)",
                now: try timeline.nextInstant()
            )
            _ = try store.engine.scheduleFromPool(
                chainID: chainID,
                date: today,
                today: today,
                now: try timeline.nextInstant()
            )
        }

        let futureDate = NoonmarkStore.offset(today, by: 30)
        for index in 1 ... 4 {
            let chainID = try store.engine.createPoolTask(
                title: "E2E 未来风险文案 \(index)",
                now: try timeline.nextInstant()
            )
            _ = try store.engine.scheduleFromPool(
                chainID: chainID,
                date: futureDate,
                today: today,
                now: try timeline.nextInstant()
            )
        }
        _ = try timeline.finish()

        return Fixture(
            poolChainID: poolChainID,
            historicalTraceID: historicalTraceID,
            activeTraceID: activeTraceID,
            completedTraceID: completedTraceID,
            futureDate: futureDate
        )
    }

    @MainActor
    private func exerciseLocalSummaryRails(
        store: NoonmarkStore,
        poolChainID: TaskChainID,
        input: WindowServerInputDriver
    ) async throws {
        store.page = .pool
        store.clearSelection()
        store.isDetailRailExpanded = false
        guard AppViewTreeE2E.activateMainWindow() else {
            throw SummarySidebarE2EAutomationError.failed(
                "main window could not become active"
            )
        }
        try await waitUntil("local summary toolbar route did not settle") {
            store.detailRailRoute == .pageSummary(.pool)
                && store.hasDetailRailContent
                && store.shouldShowDetailRail == false
                && AppViewTreeE2E.view(
                    identifier: "shell.detail-rail.toggle"
                ) != nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "shell.detail-rail"
                )
        }
        try await click(
            identifier: "shell.detail-rail.toggle",
            input: input
        )

        let pages: [NoonmarkStore.Page] = [
            .pool,
            .future,
            .unfinished,
            .completed
        ]
        for page in pages {
            store.page = page
            store.clearSelection()
            try await assertSummary(
                page: page,
                store: store,
                zhulongEnabled: false
            )
        }

        store.page = .pool
        store.clearSelection()
        let poolRowIdentifier = "workspace.item.pool.\(poolChainID.description)"
        try await waitUntil("real Task Pool row was unavailable") {
            AppViewTreeE2E.view(identifier: poolRowIdentifier) != nil
        }
        try await click(identifier: poolRowIdentifier, input: input)
        try await waitUntil("selection detail did not replace page summary") {
            store.selectedPoolTask?.chain.id == poolChainID
                && store.detailRailRoute == .selection
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "detail.summary.pool"
                )
        }
        store.clearSelection()
        try await assertSummary(
            page: .pool,
            store: store,
            zhulongEnabled: false
        )

        store.setZhulongPageEnabled(true)
        for page in pages {
            store.page = page
            store.clearSelection()
            try await assertSummary(
                page: page,
                store: store,
                zhulongEnabled: true
            )
        }
    }

    @MainActor
    private func assertSummary(
        page: NoonmarkStore.Page,
        store: NoonmarkStore,
        zhulongEnabled: Bool
    ) async throws {
        let prefix = "detail.summary.\(page.rawValue)"
        try await waitUntil("\(page.rawValue) local summary was not visible") {
            store.detailRailRoute == .pageSummary(page)
                && store.shouldShowDetailRail
                && AppViewTreeE2E.view(identifier: prefix) != nil
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).metrics"
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).signals"
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "\(prefix).recommendations"
                ) != nil
                && (
                    zhulongEnabled
                        ? AppViewTreeE2E.view(
                            identifier: "\(prefix).zhulong-action"
                        ) != nil
                        : AppViewTreeE2E.view(
                            identifier: "\(prefix).zhulong-hint"
                        ) != nil
                )
                && (
                    zhulongEnabled
                        ? AppViewTreeE2E.hasNoVisibleView(
                            identifier: "\(prefix).zhulong-hint"
                        )
                        : AppViewTreeE2E.hasNoVisibleView(
                            identifier: "\(prefix).zhulong-action"
                        )
                )
        }
    }

    @MainActor
    private func exerciseCalendarAndTimeline(
        store: NoonmarkStore,
        fixture: Fixture
    ) async throws {
        store.zhulongProviderDraft.enabled = false
        store.page = .calendar
        store.selectedCalendarDate = store.today
        let todaySummary = store.engine.calendarSummary(for: store.today)
        let heatIdentifier = "calendar.date-cell.\(store.today.description).heat"
        let completedDotIdentifier = "calendar.trace.\(fixture.completedTraceID.description).status-dot"
        let pendingDotIdentifier = "calendar.trace.\(fixture.activeTraceID.description).status-dot"
        try await waitUntil("calendar heat or status-dot contract was unavailable") {
            guard let heat = AppViewTreeE2E.view(identifier: heatIdentifier),
                  let completedDot = AppViewTreeE2E.view(
                      identifier: completedDotIdentifier
                  ),
                  let pendingDot = AppViewTreeE2E.view(
                      identifier: pendingDotIdentifier
                  )
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: heat)
                == "\(todaySummary.heatLevel)"
                && AppViewTreeE2E.verificationText(for: completedDot)
                == TraceStatus.completed.rawValue
                && AppViewTreeE2E.verificationText(for: pendingDot)
                == TraceStatus.pending.rawValue
        }

        let todayInsight = CalendarDayInsight.make(
            for: store.today,
            store: store
        )
        guard todayInsight.hasEnhancedContent,
              todayInsight.riskSummary.contains("延续复制"),
              todayInsight.riskSummary.contains("改期") == false
        else {
            throw SummarySidebarE2EAutomationError.failed(
                "today calendar risk did not preserve continuation semantics"
            )
        }
        let futureInsight = CalendarDayInsight.make(
            for: fixture.futureDate,
            store: store
        )
        guard futureInsight.hasEnhancedContent,
              futureInsight.riskSummary.contains("改期"),
              futureInsight.riskSummary.contains("延续复制") == false
        else {
            throw SummarySidebarE2EAutomationError.failed(
                "future calendar risk did not use plan-draft language"
            )
        }

        store.page = .day
        store.selectedDate = store.today
        store.selectTrace(fixture.activeTraceID)
        let continued = try trace(fixture.historicalTraceID, in: store)
        let pending = try trace(fixture.activeTraceID, in: store)
        try await assertTimelineNode(continued, store: store)
        try await assertTimelineNode(pending, store: store)
    }

    @MainActor
    private func assertTimelineNode(
        _ trace: DayTrace,
        store: NoonmarkStore
    ) async throws {
        let identifier = "timeline.trace.\(trace.id.description)"
        let expected = [
            trace.status.rawValue,
            trace.status.uiStyle.glyph,
            store.copy.traceStatusLabel(trace.status)
        ].joined(separator: "|")
        try await waitUntil(
            "\(trace.status.rawValue) timeline style did not use shared mapping"
        ) {
            guard let anchor = AppViewTreeE2E.view(identifier: identifier) else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: anchor) == expected
        }
    }

    @MainActor
    private func trace(
        _ id: DayTraceID,
        in store: NoonmarkStore
    ) throws -> DayTrace {
        guard let trace = store.engine.traces[id] else {
            throw SummarySidebarE2EAutomationError.failed(
                "timeline fixture trace was missing"
            )
        }
        return trace
    }

    @MainActor
    private func click(
        identifier: String,
        input: WindowServerInputDriver
    ) async throws {
        guard let view = AppViewTreeE2E.view(identifier: identifier),
              let window = view.window,
              window.isKeyWindow,
              NSApp.isActive
        else {
            throw SummarySidebarE2EAutomationError.failed(
                "visible WindowServer click target was missing: \(identifier)"
            )
        }
        let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let currentView = AppViewTreeE2E.view(identifier: identifier),
                  let currentWindow = currentView.window,
                  currentWindow === window,
                  currentWindow.isKeyWindow,
                  currentView.isHiddenOrHasHiddenAncestor == false,
                  currentView.bounds.width > 0,
                  currentView.bounds.height > 0
            else {
                throw SummarySidebarE2EAutomationError.failed(
                    "WindowServer click target changed before mouseDown: \(identifier)"
                )
            }
            let currentPoint = currentView.convert(
                NSPoint(
                    x: currentView.bounds.midX,
                    y: currentView.bounds.midY
                ),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: currentPoint,
                in: currentWindow
            )
        }
        let coordinate = try resolveTarget()
        try await input.postClick(
            at: coordinate,
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    @MainActor
    private func waitUntil(
        _ failure: String,
        attempts: Int = 80,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SummarySidebarE2EAutomationError.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        guard let resultURL else { return }
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        let poolChainID: TaskChainID
        let historicalTraceID: DayTraceID
        let activeTraceID: DayTraceID
        let completedTraceID: DayTraceID
        let futureDate: LocalDate
    }
}

private enum SummarySidebarE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

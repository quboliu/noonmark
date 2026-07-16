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
            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong entry remained visible")
            store.selectPage(.zhulong)
            try expect(store.page == .day, "disabled zhulong selection bypassed the visible-page guard")

            store.zhulongProviderDraft.enabled = true
            try expect(store.visibleNavigationPages.contains(.zhulong), "enabled zhulong was not visible")
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
            try expect(store.zhulongWorkspace.selectedSession?.purpose == .dailyClose, "freeform daily close lost its purpose")
            store.authorizeCurrentZhulongWorkspaceSession()
            try expect(store.zhulongWorkspace.selectedSession?.phase == .readyForProvider, "scope authorization was not persisted")

            store.zhulongProviderDraft.enabled = false
            store.ensureVisiblePage()
            try expect(store.visibleNavigationPages.contains(.zhulong) == false, "disabled zhulong entry remained visible")
            try expect(store.page == .day, "disabling zhulong did not leave the hidden workspace")

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

struct SubtaskMutationE2EAutomation: LaunchAutomationRunnable {
    var resultURL: URL?

    @MainActor
    static func fromCommandLine() -> SubtaskMutationE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-subtask-mutation") else { return nil }
        let resultURL = AppLaunchArguments.value(after: "--e2e-subtask-mutation-result-url")
            .map { URL(fileURLWithPath: $0) }
        return SubtaskMutationE2EAutomation(resultURL: resultURL)
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        do {
            store.page = .day
            store.selectedDate = store.today
            guard let trace = store.engine.getDayTodo(date: store.today).traces.first(where: { store.subtasks(for: $0.id).contains { $0.status == .pending } }),
                  let subtask = store.subtasks(for: trace.id).first(where: { $0.status == .pending })
            else {
                throw SubtaskMutationE2EAutomationError.failed("missing current pending subtask")
            }

            store.selectTrace(trace.id)
            store.toggleSubtask(subtask.id)
            try expect(store.engine.subtasks[subtask.id]?.status == .completed, "subtask did not complete")
            try expect(store.engine.subtasks[subtask.id]?.completedAt != nil, "completedAt was not recorded")

            store.toggleSubtask(subtask.id)
            try expect(store.engine.subtasks[subtask.id]?.status == .pending, "subtask did not undo completion")
            try expect(store.engine.subtasks[subtask.id]?.completedAt == nil, "completedAt was not cleared")

            store.setSubtaskDifficulty(subtask.id, difficulty: .hard)
            try expect(store.engine.subtasks[subtask.id]?.difficulty == .hard, "subtask difficulty did not update")

            try writeResult("ok")
        } catch {
            try? writeResult("failed: \(error.localizedDescription)")
        }
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SubtaskMutationE2EAutomationError.failed(message) }
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

private enum SubtaskMutationE2EAutomationError: LocalizedError {
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
        do {
            store.page = .pool
            store.clearSelection()
            store.zhulongProviderDraft.enabled = true
            store.isDetailRailExpanded = false
            guard store.usesZhulongContextRail,
                  store.hasDetailRailContent,
                  store.shouldShowDetailRail == false
            else {
                throw SummarySidebarE2EAutomationError.failed("enabled zhulong context rail was unavailable")
            }
            store.toggleDetailRail()

            for page in [NoonmarkStore.Page.pool, .future, .unfinished, .completed] {
                store.page = page
                store.clearSelection()
                guard store.usesZhulongContextRail,
                      store.hasDetailRailContent,
                      store.shouldShowDetailRail
                else {
                    throw SummarySidebarE2EAutomationError.failed("\(page.rawValue) zhulong context rail was unavailable")
                }
            }

            store.page = .pool
            if let task = store.engine.taskPool().first {
                store.selectPool(task.chain.id)
            }
            guard store.hasActiveDetailSelection, store.shouldShowDetailRail else {
                throw SummarySidebarE2EAutomationError.failed("selection detail rail did not override local analysis")
            }

            store.page = .calendar
            store.setLanguage(.chinese)
            store.selectedCalendarDate = store.today
            for index in 1 ... 4 {
                let chainID = try store.engine.createPoolTask(
                    title: "E2E 当日风险文案 \(index)",
                    now: Date()
                )
                _ = try store.engine.scheduleFromPool(
                    chainID: chainID,
                    date: store.today,
                    today: store.today,
                    now: Date()
                )
            }
            let todayInsight = CalendarDayInsight.make(
                for: store.selectedCalendarDate,
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

            let futureDate = NoonmarkStore.offset(store.today, by: 30)
            for index in 1 ... 4 {
                let chainID = try store.engine.createPoolTask(
                    title: "E2E 未来风险文案 \(index)",
                    now: Date()
                )
                _ = try store.engine.scheduleFromPool(
                    chainID: chainID,
                    date: futureDate,
                    today: store.today,
                    now: Date()
                )
            }
            let futureInsight = CalendarDayInsight.make(
                for: futureDate,
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

private enum SummarySidebarE2EAutomationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

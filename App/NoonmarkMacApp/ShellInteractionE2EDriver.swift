import AppKit
import Foundation
import NoonmarkCore

@MainActor
enum DateNavigationUIE2EDriver {
    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    private enum Surface: Equatable {
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

        var cellIdentifierPrefix: String {
            switch self {
            case .day: "day.date-strip.cell"
            case .calendar: "calendar.date-cell"
            }
        }
    }

    private struct Step {
        let key: DateNavigationKey
        let expectedDayOffset: Int
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL
        private let steps = [
            Step(key: .right, expectedDayOffset: 1),
            Step(key: .left, expectedDayOffset: 0),
            Step(key: .down, expectedDayOffset: 7),
            Step(key: .up, expectedDayOffset: 0)
        ]
        private var surface = Surface.day
        private var stepIndex = 0

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start() {
            begin(.day)
        }

        private func begin(_ nextSurface: Surface) {
            surface = nextSurface
            stepIndex = 0
            store.page = nextSurface.page
            switch nextSurface {
            case .day:
                store.selectedDate = store.today
            case .calendar:
                store.selectedCalendarDate = store.today
            }
            waitForDateCell()
        }

        private func waitForDateCell(attemptsRemaining: Int = 80) {
            let identifier = "\(surface.cellIdentifierPrefix).\(store.today.description)"
            guard let dateCell = AppViewTreeE2E.view(identifier: identifier) else {
                retry(attemptsRemaining, action: waitForDateCell) { [self] in
                    "failed: \(surface.name) 日期单元没有出现在真实 view tree"
                }
                return
            }
            guard AppViewTreeE2E.click(dateCell) else {
                retry(attemptsRemaining, action: waitForDateCell) { [self] in
                    "failed: 无法用真实鼠标事件点击 \(surface.name) 日期"
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForDateFocus()
            }
        }

        private func waitForDateFocus(attemptsRemaining: Int = 60) {
            let window = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0 is NoonmarkWindow })
            guard selectedDate == store.today,
                  window?.firstResponder is DateNavigationKeyboardFocusView
            else {
                retry(attemptsRemaining, action: waitForDateFocus) {
                    "failed: 点击 \(self.surface.name) 日期后没有把日期区域设为 first responder"
                }
                return
            }
            sendCurrentStep()
        }

        private func sendCurrentStep() {
            let step = steps[stepIndex]
            guard AppViewTreeE2E.sendKey(step.key) else {
                finish("failed: 无法向真实窗口发送\(directionName(for: step.key))方向键")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                waitForCurrentStep()
            }
        }

        private func waitForCurrentStep(attemptsRemaining: Int = 60) {
            let step = steps[stepIndex]
            let expectedDate = NoonmarkStore.offset(
                store.today,
                by: step.expectedDayOffset
            )
            let window = NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0 is NoonmarkWindow })
            guard selectedDate == expectedDate,
                  window?.title == store.windowTitle,
                  window?.firstResponder is DateNavigationKeyboardFocusView
            else {
                retry(attemptsRemaining, action: waitForCurrentStep) { [self] in
                    "failed: \(surface.name) 的\(directionName(for: step.key))方向键没有切到预期日期"
                }
                return
            }

            stepIndex += 1
            if stepIndex < steps.count {
                sendCurrentStep()
            } else if surface == .day {
                begin(.calendar)
            } else {
                finish("ok")
            }
        }

        private var selectedDate: LocalDate {
            switch surface {
            case .day:
                store.selectedDate
            case .calendar:
                store.selectedCalendarDate
            }
        }

        private func directionName(for key: DateNavigationKey) -> String {
            switch key {
            case .left: "左"
            case .right: "右"
            case .down: "下"
            case .up: "上"
            }
        }

        private func retry(
            _ attemptsRemaining: Int,
            action: @escaping (Int) -> Void,
            failure: () -> String
        ) {
            guard attemptsRemaining > 1 else {
                finish(failure())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action(attemptsRemaining - 1)
            }
        }

        private func finish(_ result: String) {
            ShellInteractionE2EResult.finish(result, at: resultURL)
        }
    }
}

@MainActor
enum DetailRailLayoutUIE2EDriver {
    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL
        private var initialWindowFrame: NSRect?
        private var initialMiddleWidth: CGFloat?

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let toggle = AppViewTreeE2E.view(identifier: "shell.detail-rail.toggle"),
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail")
            else {
                retry(attemptsRemaining, action: start) {
                    "failed: 默认收起状态的 Shell 几何锚点不完整"
                }
                return
            }
            guard store.hasDetailRailContent,
                  store.isDetailRailExpanded == false,
                  store.shouldShowDetailRail == false
            else {
                finish("failed: 右侧栏没有默认收起")
                return
            }

            initialWindowFrame = window.frame
            initialMiddleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            guard AppViewTreeE2E.click(toggle) else {
                finish("failed: 无法用真实鼠标事件展开右侧栏")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForExpandedRail()
            }
        }

        private func waitForExpandedRail(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let initialMiddleWidth,
                  let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let rail = AppViewTreeE2E.view(identifier: "shell.detail-rail")
            else {
                retry(attemptsRemaining, action: waitForExpandedRail) {
                    "failed: 展开后缺少右侧栏或中栏几何锚点"
                }
                return
            }
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            let railWidth = AppViewTreeE2E.frameInWindow(for: rail).width
            guard store.shouldShowDetailRail,
                  window.frame == initialWindowFrame,
                  abs(railWidth - NoonmarkVisualMetrics.detailRailWidth) <= 1,
                  abs(initialMiddleWidth - middleWidth - railWidth) <= 1
            else {
                retry(attemptsRemaining, action: waitForExpandedRail) {
                    "failed: 展开右栏时窗口尺寸改变，或中栏没有按右栏宽度缩放"
                }
                return
            }
            guard let toggle = AppViewTreeE2E.view(
                identifier: "shell.detail-rail.toggle"
            ), AppViewTreeE2E.click(toggle) else {
                finish("failed: 无法用真实鼠标事件收起右侧栏")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForCollapsedRail()
            }
        }

        private func waitForCollapsedRail(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let initialMiddleWidth,
                  let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane")
            else {
                retry(attemptsRemaining, action: waitForCollapsedRail) {
                    "failed: 收起后缺少窗口或中栏几何锚点"
                }
                return
            }
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            guard store.shouldShowDetailRail == false,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail"),
                  window.frame == initialWindowFrame,
                  abs(middleWidth - initialMiddleWidth) <= 1
            else {
                retry(attemptsRemaining, action: waitForCollapsedRail) {
                    "failed: 收起右栏后窗口或中栏没有恢复原始几何"
                }
                return
            }
            finish("ok")
        }

        private func retry(
            _ attemptsRemaining: Int,
            action: @escaping (Int) -> Void,
            failure: () -> String
        ) {
            guard attemptsRemaining > 1 else {
                finish(failure())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action(attemptsRemaining - 1)
            }
        }

        private func finish(_ result: String) {
            ShellInteractionE2EResult.finish(result, at: resultURL)
        }
    }
}

@MainActor
private enum ShellInteractionE2EResult {
    static func finish(_ result: String, at resultURL: URL) {
        if result != "ok" {
            AppViewTreeE2E.writeDump(beside: resultURL)
        }
        do {
            try FileManager.default.createDirectory(
                at: resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.write(to: resultURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog(
                "Noonmark Shell interaction UI E2E result write failed: %@",
                String(describing: error)
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }
}

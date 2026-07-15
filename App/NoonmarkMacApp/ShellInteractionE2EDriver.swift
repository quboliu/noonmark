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
        private let basicSteps = [
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
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow })
            else {
                retry(attemptsRemaining, action: waitForDateCell) {
                    "failed: \(self.surface.name) 没有可交互的真实窗口"
                }
                return
            }
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            guard AppViewTreeE2E.view(identifier: identifier) != nil else {
                retry(attemptsRemaining, action: waitForDateCell) { [self] in
                    "failed: \(surface.name) 日期单元没有出现在真实 view tree"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                guard let dateCell = AppViewTreeE2E.view(identifier: identifier) else {
                    retry(attemptsRemaining, action: waitForDateCell) {
                        "failed: \(self.surface.name) 日期单元在点击前离开真实 view tree"
                    }
                    return
                }
                let clickTarget = AppViewTreeE2E.button(overlapping: dateCell) ?? dateCell
                guard AppViewTreeE2E.click(clickTarget) else {
                    retry(attemptsRemaining, action: waitForDateCell) {
                        "failed: 无法用真实鼠标事件点击 \(self.surface.name) 日期"
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                    waitForDateFocus()
                }
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
            let advancedDayStripIsMissing = surface == .day
                && stepIndex == steps.count - 1
                && hasExpectedAdvancedDayStrip() == false
            if advancedDayStripIsMissing {
                retry(attemptsRemaining, action: waitForCurrentStep) {
                    "failed: Day Todo 右移到 7 月 13 日后，日期带没有切换为后续 14 天"
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

        private var steps: [Step] {
            guard surface == .day else { return basicSteps }
            return basicSteps + (1...8).map {
                Step(key: .right, expectedDayOffset: $0)
            }
        }

        private func hasExpectedAdvancedDayStrip() -> Bool {
            let prefix = "day.date-strip.cell."
            let expected = Set((8...21).map {
                "\(prefix)\(NoonmarkStore.offset(store.today, by: $0).description)"
            })
            return AppViewTreeE2E.identifiers(withPrefix: prefix) == expected
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
enum ZhulongNavigationUIE2EDriver {
    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            guard store.isZhulongEnabled == false,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.zhulong"),
                  clickControl(identifier: "sidebar.nav.settings")
            else {
                retry(attemptsRemaining, action: start) {
                    "failed: 关闭烛龙后，真实侧栏仍显示烛龙入口"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                enableFromSettings()
            }
        }

        private func enableFromSettings(attemptsRemaining: Int = 60) {
            guard store.page == .settings,
                  clickControl(identifier: "settings.pane.zhulong")
            else {
                retry(attemptsRemaining, action: enableFromSettings) {
                    "failed: 设置页无法打开烛龙配置区"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForDisabledSetting()
            }
        }

        private func waitForDisabledSetting(attemptsRemaining: Int = 60) {
            guard store.page == .settings,
                  let toggle = AppViewTreeE2E.view(
                      identifier: "settings.zhulong.enabled"
                  ),
                  AppViewTreeE2E.verificationText(for: toggle) == "disabled",
                  clickControl(identifier: "settings.zhulong.enabled")
            else {
                retry(attemptsRemaining, action: waitForDisabledSetting) {
                    "failed: 无法通过设置中的启用烛龙开关开启功能"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                openEnabledZhulong()
            }
        }

        private func openEnabledZhulong(attemptsRemaining: Int = 60) {
            guard store.isZhulongEnabled,
                  clickControl(identifier: "sidebar.nav.zhulong")
            else {
                retry(attemptsRemaining, action: openEnabledZhulong) {
                    "failed: 设置启用后，真实侧栏没有显示烛龙入口"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                disableFromSettings()
            }
        }

        private func disableFromSettings(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong,
                  clickControl(identifier: "sidebar.nav.settings")
            else {
                retry(attemptsRemaining, action: disableFromSettings) {
                    "failed: 真实侧栏中的烛龙入口无法打开工作区"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                openZhulongSettingsForDisable()
            }
        }

        private func openZhulongSettingsForDisable(attemptsRemaining: Int = 60) {
            guard store.page == .settings,
                  clickControl(identifier: "settings.pane.zhulong")
            else {
                retry(attemptsRemaining, action: openZhulongSettingsForDisable) {
                    "failed: 返回设置页后无法打开烛龙配置区"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForEnabledSetting()
            }
        }

        private func waitForEnabledSetting(attemptsRemaining: Int = 60) {
            guard store.page == .settings,
                  let toggle = AppViewTreeE2E.view(identifier: "settings.zhulong.enabled"),
                  AppViewTreeE2E.verificationText(for: toggle) == "enabled",
                  clickControl(identifier: "settings.zhulong.enabled")
            else {
                retry(attemptsRemaining, action: waitForEnabledSetting) {
                    "failed: 无法通过设置中的启用烛龙开关关闭功能"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForHiddenZhulong()
            }
        }

        private func waitForHiddenZhulong(attemptsRemaining: Int = 60) {
            guard store.isZhulongEnabled == false,
                  store.page == .settings,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.zhulong")
            else {
                retry(attemptsRemaining, action: waitForHiddenZhulong) {
                    "failed: 设置关闭后，真实侧栏没有隐藏烛龙入口"
                }
                return
            }

            store.zhulongProviderDraft.enabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                reopenZhulongForFallbackCheck()
            }
        }

        private func reopenZhulongForFallbackCheck(attemptsRemaining: Int = 60) {
            guard store.isZhulongEnabled,
                  clickControl(identifier: "sidebar.nav.zhulong")
            else {
                retry(attemptsRemaining, action: reopenZhulongForFallbackCheck) {
                    "failed: 重新启用后，烛龙入口没有恢复"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                disableOpenZhulong()
            }
        }

        private func disableOpenZhulong(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong else {
                retry(attemptsRemaining, action: disableOpenZhulong) {
                    "failed: 重新启用的烛龙入口无法打开工作区"
                }
                return
            }
            store.zhulongProviderDraft.enabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForVisiblePageFallback()
            }
        }

        private func waitForVisiblePageFallback(attemptsRemaining: Int = 60) {
            guard store.page == .day,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.zhulong")
            else {
                retry(attemptsRemaining, action: waitForVisiblePageFallback) {
                    "failed: 关闭烛龙后，已打开的烛龙页没有切回 Day Todo"
                }
                return
            }
            finish("ok")
        }

        private func clickControl(identifier: String) -> Bool {
            guard let anchor = AppViewTreeE2E.view(identifier: identifier) else {
                return false
            }
            if let button = AppViewTreeE2E.button(overlapping: anchor) {
                return AppViewTreeE2E.click(button)
            }
            return AppViewTreeE2E.click(anchor)
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
    private enum Stage {
        case dayDetailRail
        case calendarDetailRail
        case sidebar
    }

    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL
        private var stage = Stage.dayDetailRail
        private var initialWindowFrame: NSRect?
        private var initialMiddleWidth: CGFloat?
        private var initialSidebarWidth: CGFloat?

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
                  abs(railWidth - expectedDetailRailWidth) <= 1,
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
            switch stage {
            case .dayDetailRail:
                stage = .calendarDetailRail
                store.isDetailRailExpanded = true
                store.selectPage(.calendar)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                    start()
                }
            case .calendarDetailRail:
                stage = .sidebar
                store.selectPage(.day)
                store.isDetailRailExpanded = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                    startSidebar()
                }
            case .sidebar:
                finish("failed: 右栏测试进入了无效阶段")
            }
        }

        private var expectedDetailRailWidth: CGFloat {
            store.page == .calendar
                ? NoonmarkVisualMetrics.calendarRailWidth
                : NoonmarkVisualMetrics.detailRailWidth
        }

        private func startSidebar(attemptsRemaining: Int = 80) {
            guard let viewMenu = NSApp.mainMenu?.item(withTitle: store.copy.viewMenu)?.submenu,
                  let sidebarMenuItem = viewMenu.items.first(where: {
                      $0.action == NSSelectorFromString("toggleSidebarAction:")
                  }),
                  let detailMenuItem = viewMenu.items.first(where: {
                      $0.action == NSSelectorFromString("toggleDetailRailAction:")
                  }),
                  let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let toolbar = AppViewTreeE2E.view(identifier: "shell.window-toolbar"),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let sidebarToggle = AppViewTreeE2E.view(identifier: "shell.sidebar.toggle"),
                  let detailToggle = AppViewTreeE2E.view(identifier: "shell.detail-rail.toggle"),
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail")
            else {
                retry(attemptsRemaining, action: startSidebar) {
                    "failed: 左栏默认展开状态的 Shell 几何锚点不完整"
                }
                return
            }
            let toolbarFrame = AppViewTreeE2E.frameInWindow(for: toolbar)
            let sidebarToggleFrame = AppViewTreeE2E.frameInWindow(for: sidebarToggle)
            let detailToggleFrame = AppViewTreeE2E.frameInWindow(for: detailToggle)
            let sidebarWidth = AppViewTreeE2E.frameInWindow(for: sidebar).width
            guard store.isSidebarExpanded,
                  sidebarMenuItem.title == store.copy.collapseSidebar,
                  sidebarMenuItem.keyEquivalent == "s",
                  sidebarMenuItem.keyEquivalentModifierMask == [.command, .control],
                  detailMenuItem.title == store.copy.expandDetailRail,
                  detailMenuItem.keyEquivalent == "i",
                  detailMenuItem.keyEquivalentModifierMask == [.command, .option],
                  abs(sidebarWidth - NoonmarkVisualMetrics.sidebarWidth) <= 1,
                  abs(toolbarFrame.width - window.frame.width) <= 1,
                  abs(toolbarFrame.height - NoonmarkVisualMetrics.windowToolbarHeight) <= 1,
                  sidebarToggleFrame.midX < toolbarFrame.width * 0.2,
                  detailToggleFrame.midX > toolbarFrame.width * 0.8
            else {
                finish("failed: 左栏默认几何或窗口两端的栏位入口不正确")
                return
            }
            initialWindowFrame = window.frame
            initialMiddleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            initialSidebarWidth = sidebarWidth
            guard AppViewTreeE2E.click(sidebarToggle) else {
                finish("failed: 无法用真实鼠标事件收起左栏")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForCollapsedSidebar()
            }
        }

        private func waitForCollapsedSidebar(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let initialMiddleWidth,
                  let initialSidebarWidth,
                  let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let toggle = AppViewTreeE2E.view(identifier: "shell.sidebar.toggle")
            else {
                retry(attemptsRemaining, action: waitForCollapsedSidebar) {
                    "failed: 左栏收起后缺少窗口、开关或几何锚点"
                }
                return
            }
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            guard store.isSidebarExpanded == false,
                  window.frame == initialWindowFrame,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.sidebar"),
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.calendar"),
                  abs(middleWidth - initialMiddleWidth - initialSidebarWidth) <= 1
            else {
                retry(attemptsRemaining, action: waitForCollapsedSidebar) {
                    "failed: 左栏没有完全隐藏，窗口尺寸改变，或中栏没有接收完整宽度"
                }
                return
            }
            guard AppViewTreeE2E.click(toggle) else {
                finish("failed: 左栏完全隐藏后无法通过窗口入口重新展开")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForExpandedSidebar()
            }
        }

        private func waitForExpandedSidebar(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let initialMiddleWidth,
                  let initialSidebarWidth,
                  let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let calendarNavigation = AppViewTreeE2E.view(identifier: "sidebar.nav.calendar")
            else {
                retry(attemptsRemaining, action: waitForExpandedSidebar) {
                    "failed: 左栏展开后缺少窗口、导航或几何锚点"
                }
                return
            }
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            let sidebarWidth = AppViewTreeE2E.frameInWindow(for: sidebar).width
            guard store.isSidebarExpanded,
                  window.frame == initialWindowFrame,
                  abs(sidebarWidth - initialSidebarWidth) <= 1,
                  abs(middleWidth - initialMiddleWidth) <= 1
            else {
                retry(attemptsRemaining, action: waitForExpandedSidebar) {
                    "failed: 展开左栏后窗口或中栏没有恢复原始几何"
                }
                return
            }
            guard AppViewTreeE2E.click(calendarNavigation) else {
                finish("failed: 左栏重新展开后无法通过真实鼠标导航")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForExpandedSidebarNavigation()
            }
        }

        private func waitForExpandedSidebarNavigation(attemptsRemaining: Int = 60) {
            guard store.page == .calendar,
                  store.isSidebarExpanded,
                  store.shouldShowDetailRail == false,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail"),
                  AppViewTreeE2E.view(identifier: "shell.detail-rail.toggle") != nil
            else {
                retry(attemptsRemaining, action: waitForExpandedSidebarNavigation) {
                    "failed: 左栏恢复后的导航没有进入默认收起右栏的日历"
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

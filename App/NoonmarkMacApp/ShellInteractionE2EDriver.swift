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
        private weak var mainWindow: NSWindow?
        private var pageBeforeSettings: NoonmarkStore.Page?

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            guard store.isZhulongEnabled == false,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.zhulong"),
                  openNativeSettingsFromMainWindow()
            else {
                retry(attemptsRemaining, action: start) {
                    "failed: 关闭烛龙后侧栏仍显示入口，或标准 Settings action 无法打开原生窗口"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                enableFromSettings()
            }
        }

        private func enableFromSettings(attemptsRemaining: Int = 60) {
            guard let mainWindow,
                  let pageBeforeSettings,
                  store.page == pageBeforeSettings,
                  NativeSettingsWindowE2E.isReady(
                      excluding: mainWindow,
                      paneIdentifier: "settings.sidebar.zhulong",
                      title: store.copy.navSettings
                  ),
                  clickControl(identifier: "settings.sidebar.zhulong")
            else {
                retry(attemptsRemaining, action: enableFromSettings) {
                    "failed: 原生 Settings window 或烛龙 sidebar pane anchor 不可用"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForDisabledSetting()
            }
        }

        private func waitForDisabledSetting(attemptsRemaining: Int = 60) {
            guard let pageBeforeSettings,
                  store.page == pageBeforeSettings,
                  let toggle = AppViewTreeE2E.view(
                      identifier: "settings.zhulong.page.enabled"
                  ),
                  AppViewTreeE2E.verificationText(for: toggle) == "disabled",
                  clickControl(identifier: "settings.zhulong.page.enabled")
            else {
                retry(attemptsRemaining, action: waitForDisabledSetting) {
                    "failed: 无法通过设置中的启用烛龙开关开启功能"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                closeSettingsAfterEnable()
            }
        }

        private func closeSettingsAfterEnable(attemptsRemaining: Int = 60) {
            guard let pageBeforeSettings,
                  store.isZhulongEnabled,
                  store.page == pageBeforeSettings,
                  let settingsWindow = NativeSettingsWindowE2E.visibleWindow(),
                  NativeSettingsWindowE2E.close(settingsWindow)
            else {
                retry(attemptsRemaining, action: closeSettingsAfterEnable) {
                    "failed: 启用烛龙后无法关闭原生 Settings window"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                openEnabledZhulong()
            }
        }

        private func openEnabledZhulong(attemptsRemaining: Int = 60) {
            guard let mainWindow,
                  let pageBeforeSettings,
                  NativeSettingsWindowE2E.visibleWindow() == nil,
                  NSApp.keyWindow === mainWindow,
                  mainWindow.isVisible,
                  store.page == pageBeforeSettings,
                  store.isZhulongEnabled
            else {
                retry(attemptsRemaining, action: openEnabledZhulong) {
                    "failed: 关闭 Settings 后没有回到原主窗口与原页面"
                }
                return
            }

            store.zhulongWorkspace.showHome()
            guard clickControl(identifier: "sidebar.nav.zhulong") else {
                retry(attemptsRemaining, action: openEnabledZhulong) {
                    "failed: 设置启用后，真实侧栏没有显示烛龙入口"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForZhulongHomeToolbar()
            }
        }

        private func waitForZhulongHomeToolbar(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong,
                  store.zhulongWorkspace.selectedSession == nil,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail.toggle"),
                  clickControl(identifier: "zhulong-home-workflow-task-shaping")
            else {
                retry(attemptsRemaining, action: waitForZhulongHomeToolbar) {
                    "failed: 烛龙首页仍显示右栏入口，或无法通过真实入口建立会话"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForZhulongSessionToolbar()
            }
        }

        private func waitForZhulongSessionToolbar(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong,
                  store.zhulongWorkspace.selectedSession != nil,
                  AppViewTreeE2E.view(identifier: "shell.detail-rail.toggle") != nil,
                  clickControl(identifier: "zhulong-session-show-home")
            else {
                retry(attemptsRemaining, action: waitForZhulongSessionToolbar) {
                    "failed: 烛龙会话没有同步显示原生右栏入口"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForReturnedZhulongHomeToolbar()
            }
        }

        private func waitForReturnedZhulongHomeToolbar(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong,
                  store.zhulongWorkspace.selectedSession == nil,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail.toggle")
            else {
                retry(attemptsRemaining, action: waitForReturnedZhulongHomeToolbar) {
                    "failed: 烛龙返回首页后仍残留右栏入口"
                }
                return
            }
            disableFromSettings()
        }

        private func disableFromSettings(attemptsRemaining: Int = 60) {
            guard store.page == .zhulong,
                  openNativeSettingsFromMainWindow()
            else {
                retry(attemptsRemaining, action: disableFromSettings) {
                    "failed: 无法从烛龙工作区通过标准 action 打开原生 Settings window"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                openZhulongSettingsForDisable()
            }
        }

        private func openZhulongSettingsForDisable(attemptsRemaining: Int = 60) {
            guard let mainWindow,
                  let pageBeforeSettings,
                  store.page == pageBeforeSettings,
                  NativeSettingsWindowE2E.isReady(
                      excluding: mainWindow,
                      paneIdentifier: "settings.sidebar.zhulong",
                      title: store.copy.navSettings
                  ),
                  clickControl(identifier: "settings.sidebar.zhulong")
            else {
                retry(attemptsRemaining, action: openZhulongSettingsForDisable) {
                    "failed: 原生 Settings window 无法打开烛龙 sidebar pane"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForEnabledSetting()
            }
        }

        private func waitForEnabledSetting(attemptsRemaining: Int = 60) {
            guard let pageBeforeSettings,
                  store.page == pageBeforeSettings,
                  let toggle = AppViewTreeE2E.view(
                      identifier: "settings.zhulong.page.enabled"
                  ),
                  AppViewTreeE2E.verificationText(for: toggle) == "enabled",
                  clickControl(identifier: "settings.zhulong.page.enabled")
            else {
                retry(attemptsRemaining, action: waitForEnabledSetting) {
                    "failed: 无法通过设置中的启用烛龙开关关闭功能"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                closeSettingsAfterDisable()
            }
        }

        private func closeSettingsAfterDisable(attemptsRemaining: Int = 60) {
            guard store.isZhulongEnabled == false,
                  store.page == .day,
                  let settingsWindow = NativeSettingsWindowE2E.visibleWindow(),
                  NativeSettingsWindowE2E.close(settingsWindow)
            else {
                retry(attemptsRemaining, action: closeSettingsAfterDisable) {
                    "failed: Settings 关闭烛龙后没有回退 Day Todo，或窗口无法关闭"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
                waitForHiddenZhulong()
            }
        }

        private func waitForHiddenZhulong(attemptsRemaining: Int = 60) {
            guard let mainWindow,
                  NativeSettingsWindowE2E.visibleWindow() == nil,
                  NSApp.keyWindow === mainWindow,
                  mainWindow.isVisible,
                  store.isZhulongEnabled == false,
                  store.page == .day,
                  AppViewTreeE2E.hasNoVisibleView(identifier: "sidebar.nav.zhulong")
            else {
                retry(attemptsRemaining, action: waitForHiddenZhulong) {
                    "failed: 关闭 Settings 后未回到原主窗口，或侧栏仍显示烛龙入口"
                }
                return
            }

            store.setZhulongPageEnabled(true)
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
            store.setZhulongPageEnabled(false)
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

        private func openNativeSettingsFromMainWindow() -> Bool {
            guard let window = mainWindow ?? NSApp.windows.first(where: {
                $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
            }) else {
                return false
            }
            mainWindow = window
            pageBeforeSettings = store.page
            return NativeSettingsWindowE2E.open(from: window)
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
                  let closeButton = window.standardWindowButton(.closeButton),
                  let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
                  let zoomButton = window.standardWindowButton(.zoomButton),
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
            let sidebarToggleFrame = AppViewTreeE2E.frameInWindow(for: sidebarToggle)
            let detailToggleFrame = AppViewTreeE2E.frameInWindow(for: detailToggle)
            let sidebarWidth = AppViewTreeE2E.frameInWindow(for: sidebar).width
            let contentFrame = window.contentView.map {
                $0.convert($0.bounds, to: nil)
            } ?? .zero
            let workspaceFrame = AppViewTreeE2E.view(
                identifier: "shell.workspace-split"
            ).map(AppViewTreeE2E.frameInWindow) ?? .zero
            viewMenu.update()
            let contractChecks: [(String, Bool)] = [
                ("sidebar-expanded", store.isSidebarExpanded),
                ("sidebar-menu-title", sidebarMenuItem.title == store.copy.collapseSidebar),
                ("sidebar-menu-key", sidebarMenuItem.keyEquivalent == "s"),
                (
                    "sidebar-menu-modifiers",
                    sidebarMenuItem.keyEquivalentModifierMask == [.command, .control]
                ),
                ("detail-menu-title", detailMenuItem.title == store.copy.expandDetailRail),
                ("detail-menu-key", detailMenuItem.keyEquivalent == "i"),
                (
                    "detail-menu-modifiers",
                    detailMenuItem.keyEquivalentModifierMask == [.command, .option]
                ),
                (
                    "sidebar-width",
                    abs(sidebarWidth - NoonmarkVisualMetrics.sidebarWidth) <= 1
                ),
                ("no-empty-native-toolbar", window.toolbar == nil),
                ("integrated-titlebar", window.titlebarSeparatorStyle == .none),
                (
                    "workspace-enters-titlebar",
                    abs(workspaceFrame.maxY - contentFrame.maxY) <= 1
                        && abs(workspaceFrame.height - contentFrame.height) <= 1
                ),
                ("close-visible", closeButton.isHidden == false),
                ("miniaturize-visible", miniaturizeButton.isHidden == false),
                ("zoom-visible", zoomButton.isHidden == false),
                (
                    "sidebar-toggle-position",
                    sidebarToggleFrame.midX <= sidebarWidth
                ),
                (
                    "detail-toggle-position",
                    detailToggleFrame.midX > window.frame.width * 0.8
                ),
                (
                    "no-custom-toolbar",
                    AppViewTreeE2E.hasNoVisibleView(identifier: "shell.window-toolbar")
                )
            ]
            let failedChecks = contractChecks.compactMap { name, passed in
                passed ? nil : name
            }
            guard failedChecks.isEmpty else {
                finish(
                    "failed: 原生窗口工具栏、系统 traffic lights 或两端栏位入口不正确 "
                        + "[\(failedChecks.joined(separator: ","))]"
                )
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
            guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let calendarNavigation = AppViewTreeE2E.view(
                      identifier: "sidebar.nav.calendar"
                  )
            else {
                retry(attemptsRemaining, action: waitForCollapsedSidebar) {
                    "failed: 左栏紧凑态没有保留栏位或导航图标"
                }
                return
            }
            let compactSidebarWidth = AppViewTreeE2E.frameInWindow(
                for: sidebar
            ).width
            guard store.isSidebarExpanded == false,
                  window.frame == initialWindowFrame,
                  calendarNavigation.isHidden == false,
                  abs(
                      compactSidebarWidth
                          - NoonmarkVisualMetrics.compactSidebarWidth
                  ) <= 1,
                  abs(
                      middleWidth
                          - initialMiddleWidth
                          - initialSidebarWidth
                          + compactSidebarWidth
                  ) <= 1
            else {
                retry(attemptsRemaining, action: waitForCollapsedSidebar) {
                    "failed: 左栏没有收成固定图标列，窗口尺寸改变，或中栏宽度不正确"
                }
                return
            }
            guard AppViewTreeE2E.click(toggle) else {
                finish("failed: 左栏紧凑后无法通过图标列入口重新展开")
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
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  store.page == .calendar,
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
            guard NativeSettingsWindowE2E.open(from: window) else {
                finish("failed: 无法通过标准 Settings action 打开原生窗口")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForNativeSettingsWindow()
            }
        }

        private func waitForNativeSettingsWindow(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let mainWindow = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let settingsWindow = NativeSettingsWindowE2E.visibleWindow()
            else {
                retry(attemptsRemaining, action: waitForNativeSettingsWindow) {
                    "failed: 原生 Settings window 没有出现"
                }
                return
            }
            let settingsChecks: [(String, Bool)] = [
                ("calendar-page", store.page == .calendar),
                ("main-window-frame", mainWindow.frame == initialWindowFrame),
                (
                    "settings-ready",
                    NativeSettingsWindowE2E.isReady(
                        excluding: mainWindow,
                        paneIdentifier: "settings.sidebar.general",
                        title: store.copy.navSettings
                    )
                ),
                (
                    "main-boundary-toggle-retained",
                    AppViewTreeE2E.view(
                        identifier: "shell.detail-rail.toggle",
                        in: mainWindow
                    ) != nil
                ),
                (
                    "main-toolbar-removed",
                    mainWindow.toolbar == nil
                )
            ]
            let failedChecks = settingsChecks.compactMap { name, passed in
                passed ? nil : name
            }
            guard failedChecks.isEmpty,
                  NativeSettingsWindowE2E.close(settingsWindow)
            else {
                retry(attemptsRemaining, action: waitForNativeSettingsWindow) {
                    "failed: Settings window anchor、sidebar pane 或独立布局不正确 "
                        + "[\(failedChecks.joined(separator: ","))]"
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [self] in
                waitForMainWindowAfterSettings()
            }
        }

        private func waitForMainWindowAfterSettings(attemptsRemaining: Int = 60) {
            guard let initialWindowFrame,
                  let initialMiddleWidth,
                  let initialSidebarWidth,
                  let mainWindow = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane"),
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar")
            else {
                retry(attemptsRemaining, action: waitForMainWindowAfterSettings) {
                    "failed: 关闭 Settings 后原主窗口几何锚点没有恢复"
                }
                return
            }
            let middleWidth = AppViewTreeE2E.frameInWindow(for: middle).width
            let sidebarWidth = AppViewTreeE2E.frameInWindow(for: sidebar).width
            guard NativeSettingsWindowE2E.visibleWindow() == nil,
                  NSApp.keyWindow === mainWindow,
                  store.page == .calendar,
                  store.isSidebarExpanded,
                  store.shouldShowDetailRail == false,
                  mainWindow.frame == initialWindowFrame,
                  abs(middleWidth - initialMiddleWidth) <= 1,
                  abs(sidebarWidth - initialSidebarWidth) <= 1,
                  AppViewTreeE2E.view(identifier: "sidebar.nav.calendar") != nil,
                  AppViewTreeE2E.view(identifier: "shell.detail-rail.toggle") != nil,
                  mainWindow.toolbar == nil
            else {
                retry(attemptsRemaining, action: waitForMainWindowAfterSettings) {
                    "failed: 关闭 Settings 后没有回到原日历窗口与原始布局"
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
private enum NativeSettingsWindowE2E {
    static func open(from mainWindow: NSWindow) -> Bool {
        guard mainWindow.isVisible, mainWindow.isMiniaturized == false else {
            return false
        }
        mainWindow.makeKeyAndOrderFront(nil)
        mainWindow.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        return NSApp.sendAction(
            NoonmarkMenuAction.showSettings,
            to: nil,
            from: nil
        )
    }

    static func visibleWindow() -> NSWindow? {
        let matches = NSApp.windows.filter {
            $0.identifier == NoonmarkSettingsWindowController.windowIdentifier
                && $0.isVisible
                && $0.isMiniaturized == false
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    static func isReady(
        excluding mainWindow: NSWindow,
        paneIdentifier: String,
        title: String
    ) -> Bool {
        guard let settingsWindow = visibleWindow(),
              settingsWindow !== mainWindow,
              settingsWindow is NSPanel == false,
              settingsWindow.parent == nil,
              settingsWindow.isKeyWindow,
              settingsWindow.title == title,
              let windowAnchor = uniqueVisibleView(
                  identifier: "settings.window",
                  in: settingsWindow
              ),
              let sidebarAnchor = uniqueVisibleView(
                  identifier: "settings.sidebar",
                  in: settingsWindow
              ),
              let paneAnchor = uniqueVisibleView(
                  identifier: paneIdentifier,
                  in: settingsWindow
              ),
              AppViewTreeE2E.verificationText(for: windowAnchor) == title,
              sidebarAnchor.window === settingsWindow,
              paneAnchor.window === settingsWindow
        else {
            return false
        }
        return true
    }

    static func close(_ settingsWindow: NSWindow) -> Bool {
        guard settingsWindow.identifier
            == NoonmarkSettingsWindowController.windowIdentifier
        else {
            return false
        }
        return NSApp.sendAction(
            #selector(NSWindow.performClose(_:)),
            to: settingsWindow,
            from: nil
        )
    }

    private static func uniqueVisibleView(
        identifier: String,
        in window: NSWindow
    ) -> NSView? {
        guard let root = window.contentView?.superview ?? window.contentView else {
            return nil
        }
        var pending = [root]
        var matches: [NSView] = []
        var visited: Set<ObjectIdentifier> = []
        while let view = pending.popLast(), visited.count < 5000 {
            guard visited.insert(ObjectIdentifier(view)).inserted else {
                continue
            }
            let matchesTarget = view.identifier?.rawValue == identifier && view.window === window
            let isVisible = view.isHiddenOrHasHiddenAncestor == false && view.alphaValue > 0 && view.bounds.width > 0 && view.bounds.height > 0 && view.visibleRect.width > 0 && view.visibleRect.height > 0
            if matchesTarget, isVisible {
                matches.append(view)
            }
            pending.append(contentsOf: view.subviews)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

@MainActor
enum ShellInteractionE2EResult {
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

import AppKit
import Foundation

struct MainWindowChromeE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> MainWindowChromeE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-main-window-chrome"),
              let path = AppLaunchArguments.value(
                  after: "--e2e-main-window-chrome-result-url"
              )
        else {
            return nil
        }
        return MainWindowChromeE2EAutomation(
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .day
        store.isDetailRailExpanded = false
        MainWindowChromeE2EDriver.start(store: store, resultURL: resultURL)
    }
}

@MainActor
private enum MainWindowChromeE2EDriver {
    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL
        private let hitPoints = [
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
        private var failures: [String] = []
        private var pointIndex = 0
        private var stateBeforeClick = true
        private var isExercisingDetailRail = false
        private var initialWindowFrame: NSRect?

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let contentView = window.contentView,
                  let splitView = AppViewTreeE2E.view(
                      identifier: "shell.workspace-split"
                  ) as? NSSplitView,
                  let toggle = AppViewTreeE2E.view(
                      identifier: "shell.sidebar.toggle"
                  ),
                  let dayHeaderDate = AppViewTreeE2E.view(
                      identifier: "day.header.date"
                  ),
                  let close = window.standardWindowButton(.closeButton),
                  let miniaturize = window.standardWindowButton(.miniaturizeButton),
                  let zoom = window.standardWindowButton(.zoomButton)
            else {
                retry(attemptsRemaining, action: start) {
                    "主窗口外壳几何锚点不完整"
                }
                return
            }

            let contentFrame = contentView.convert(contentView.bounds, to: nil)
            let splitFrame = AppViewTreeE2E.frameInWindow(for: splitView)
            let toggleFrame = AppViewTreeE2E.frameInWindow(for: toggle)
            let dayHeaderDateFrame = AppViewTreeE2E.frameInWindow(
                for: dayHeaderDate
            )
            let trafficFrames = [close, miniaturize, zoom].map {
                $0.convert($0.bounds, to: nil)
            }

            if window.toolbar != nil {
                failures.append("主窗口仍安装空 toolbar")
            }
            let splitMatchesContent = abs(
                splitFrame.height - contentFrame.height
            ) <= 1 && abs(splitFrame.maxY - contentFrame.maxY) <= 1
            if splitMatchesContent == false {
                failures.append(
                    "工作区没有进入窗口顶部：split=\(splitFrame),content=\(contentFrame)"
                )
            }
            if trafficFrames.contains(where: { splitFrame.contains($0) == false }) {
                failures.append("工作区表面没有延伸到原生 traffic lights 后方")
            }
            if trafficFrames.contains(where: { toggleFrame.intersects($0) }) {
                failures.append("左栏开关与原生 traffic lights 重叠")
            }
            let visibleHeaderTopGap = contentFrame.maxY - dayHeaderDateFrame.maxY
            if visibleHeaderTopGap > 20 {
                failures.append(
                    "页面标题仍被重复顶部安全区推低：gap=\(visibleHeaderTopGap)pt"
                )
            }
            if abs(toggleFrame.width - 28) > 1 || abs(toggleFrame.height - 28) > 1 {
                failures.append("左栏开关视觉边界不是 28×28pt：\(toggleFrame)")
            }
            let sidebarSurfaceFrame = splitView.arrangedSubviews.first.map {
                AppViewTreeE2E.frameInWindow(for: $0)
            }
            if sidebarSurfaceFrame.map({
                abs($0.maxY - contentFrame.maxY) > 1
            }) ?? true {
                failures.append("左栏表面没有覆盖原生标题栏区域")
            }

            initialWindowFrame = window.frame
            exerciseNextHitPoint()
        }

        private func exerciseNextHitPoint(attemptsRemaining: Int = 80) {
            guard pointIndex < hitPoints.count else {
                if isExercisingDetailRail {
                    finish()
                } else {
                    beginDetailRailHitPoints()
                }
                return
            }
            guard let toggle = AppViewTreeE2E.view(
                identifier: isExercisingDetailRail
                    ? "shell.detail-rail.toggle"
                    : "shell.sidebar.toggle"
            ) else {
                retry(attemptsRemaining, action: exerciseNextHitPoint) {
                    "第 \(self.pointIndex + 1) 个命中点前找不到"
                        + (self.isExercisingDetailRail ? "右栏" : "左栏")
                        + "开关"
                }
                return
            }

            let toggleFrame = AppViewTreeE2E.frameInWindow(for: toggle)
            if abs(toggleFrame.width - 28) > 1 || abs(toggleFrame.height - 28) > 1 {
                failures.append(
                    (isExercisingDetailRail ? "右栏" : "左栏")
                        + "开关视觉边界不是 28×28pt：\(toggleFrame)"
                )
            }
            stateBeforeClick = isExercisingDetailRail
                ? store.isDetailRailExpanded
                : store.isSidebarExpanded
            let unitPoint = hitPoints[pointIndex]
            guard postClick(to: toggle, unitPoint: unitPoint) else {
                failures.append("第 \(pointIndex + 1) 个命中点无法投递")
                pointIndex += 1
                exerciseNextHitPoint()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                verifyHitPoint(unitPoint)
            }
        }

        private func verifyHitPoint(_ unitPoint: NSPoint) {
            let currentState = isExercisingDetailRail
                ? store.isDetailRailExpanded
                : store.isSidebarExpanded
            if currentState == stateBeforeClick {
                failures.append(
                    (isExercisingDetailRail ? "右栏" : "左栏")
                        + " 28×28pt 命中区域漏点：x=\(unitPoint.x),y=\(unitPoint.y)"
                )
            }
            let currentWindowFrame = NSApp.windows.first(where: {
                $0 is NoonmarkWindow
            })?.frame
            let windowFrameChanged = initialWindowFrame.map {
                currentWindowFrame != $0
            } ?? false
            if windowFrameChanged {
                failures.append("栏位切换改变了主窗口 frame")
            }
            pointIndex += 1
            exerciseNextHitPoint()
        }

        private func beginDetailRailHitPoints() {
            guard store.hasDetailRailContent else {
                failures.append("Day Todo 没有可供右栏开关验证的详情内容")
                finish()
                return
            }
            verifyCompactSidebarClearsTrafficLights()
            isExercisingDetailRail = true
            pointIndex = 0
            store.isSidebarExpanded = true
            store.isDetailRailExpanded = false
            DispatchQueue.main.async { [self] in
                exerciseNextHitPoint()
            }
        }

        private func verifyCompactSidebarClearsTrafficLights() {
            guard let window = NSApp.windows.first(where: { $0 is NoonmarkWindow }),
                  let splitView = AppViewTreeE2E.view(
                      identifier: "shell.workspace-split"
                  ) as? NSSplitView,
                  let sidebarSurface = splitView.arrangedSubviews.first,
                  let zoom = window.standardWindowButton(.zoomButton)
            else {
                failures.append("无法验证紧凑左栏与 traffic lights 的间距")
                return
            }
            let sidebarFrame = AppViewTreeE2E.frameInWindow(for: sidebarSurface)
            let zoomFrame = zoom.convert(zoom.bounds, to: nil)
            let clearance = sidebarFrame.maxX - zoomFrame.maxX
            if clearance < 6 {
                failures.append(
                    "紧凑左栏分隔线压住绿色 traffic light：clearance=\(clearance)pt"
                )
            }
        }

        private func postClick(to view: NSView, unitPoint: NSPoint) -> Bool {
            guard let window = view.window else { return false }
            let point = view.convert(
                NSPoint(
                    x: view.bounds.minX + view.bounds.width * unitPoint.x,
                    y: view.bounds.minY + view.bounds.height * unitPoint.y
                ),
                to: nil
            )
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let mouseDown = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ), let mouseUp = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: point,
                modifierFlags: [],
                timestamp: timestamp + 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            ) else {
                return false
            }
            NSApp.postEvent(mouseDown, atStart: false)
            NSApp.postEvent(mouseUp, atStart: false)
            return true
        }

        private func retry(
            _ attemptsRemaining: Int,
            action: @escaping (Int) -> Void,
            failure: () -> String
        ) {
            guard attemptsRemaining > 1 else {
                failures.append(failure())
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                action(attemptsRemaining - 1)
            }
        }

        private func finish() {
            let result = failures.isEmpty
                ? "ok"
                : "failed: \(failures.joined(separator: " | "))"
            ShellInteractionE2EResult.finish(result, at: resultURL)
        }
    }
}

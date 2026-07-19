import AppKit
import Foundation
import NoonmarkCore

struct HeaderNavigationHitTargetE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> HeaderNavigationHitTargetE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-header-navigation-hit-target"),
              let path = AppLaunchArguments.value(
                  after: "--e2e-header-navigation-hit-target-result-url"
              )
        else {
            return nil
        }
        return HeaderNavigationHitTargetE2EAutomation(
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        HeaderNavigationHitTargetE2EDriver.start(
            store: store,
            resultURL: resultURL
        )
    }
}

@MainActor
private enum HeaderNavigationHitTargetE2EDriver {
    private enum Step: CaseIterable {
        case previousDay
        case nextDay
        case previousMonth
        case nextMonth

        var page: NoonmarkStore.Page {
            switch self {
            case .previousDay, .nextDay: .day
            case .previousMonth, .nextMonth: .calendar
            }
        }

        var identifier: String {
            switch self {
            case .previousDay: "day.header.previous-action"
            case .nextDay: "day.header.next-action"
            case .previousMonth: "calendar.header.previous-action"
            case .nextMonth: "calendar.header.next-action"
            }
        }

        var name: String {
            switch self {
            case .previousDay: "Day 前一天"
            case .nextDay: "Day 后一天"
            case .previousMonth: "日历上个月"
            case .nextMonth: "日历下个月"
            }
        }
    }

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
        private var stepIndex = 0
        private var pointIndex = 0
        private var expectedDate: LocalDate?
        private var initialWindowFrame: NSRect?

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start() {
            store.selectedDate = store.today
            store.selectedCalendarDate = store.today
            store.isDetailRailExpanded = false
            initialWindowFrame = NSApp.windows.first(where: {
                $0 is NoonmarkWindow
            })?.frame
            beginCurrentStep()
        }

        private func beginCurrentStep(attemptsRemaining: Int = 80) {
            guard stepIndex < Step.allCases.count else {
                finish()
                return
            }
            let step = Step.allCases[stepIndex]
            if store.page != step.page {
                store.selectPage(step.page)
                DispatchQueue.main.async { [self] in
                    beginCurrentStep(attemptsRemaining: attemptsRemaining)
                }
                return
            }
            guard AppViewTreeE2E.view(identifier: step.identifier) != nil else {
                retry(attemptsRemaining, action: beginCurrentStep) {
                    "\(step.name)按钮没有进入真实 view tree"
                }
                return
            }
            exerciseCurrentPoint()
        }

        private func exerciseCurrentPoint(attemptsRemaining: Int = 80) {
            let step = Step.allCases[stepIndex]
            guard let target = AppViewTreeE2E.view(identifier: step.identifier)
            else {
                retry(attemptsRemaining, action: exerciseCurrentPoint) {
                    "\(step.name)第 \(self.pointIndex + 1) 个命中点前消失"
                }
                return
            }
            let frame = AppViewTreeE2E.frameInWindow(for: target)
            if frame.width < 28 || frame.height < 28 {
                failures.append("\(step.name)视觉边界不足 28×28pt：\(frame)")
            }
            let currentDate = selectedDate(for: step)
            expectedDate = expectedDate(after: currentDate, for: step)
            let unitPoint = hitPoints[pointIndex]
            guard postClick(to: target, unitPoint: unitPoint) else {
                failures.append("\(step.name)第 \(pointIndex + 1) 个命中点无法投递")
                advance()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                verifyCurrentPoint(unitPoint)
            }
        }

        private func verifyCurrentPoint(_ unitPoint: NSPoint) {
            let step = Step.allCases[stepIndex]
            if selectedDate(for: step) != expectedDate {
                failures.append(
                    "\(step.name) 28×28pt 命中区域漏点："
                        + "x=\(unitPoint.x),y=\(unitPoint.y)"
                )
            }
            let currentWindowFrame = NSApp.windows.first(where: {
                $0 is NoonmarkWindow
            })?.frame
            let windowFrameChanged = initialWindowFrame.map {
                currentWindowFrame != $0
            } ?? false
            if windowFrameChanged {
                failures.append("\(step.name)改变了主窗口 frame")
            }
            advance()
        }

        private func advance() {
            pointIndex += 1
            if pointIndex == hitPoints.count {
                pointIndex = 0
                stepIndex += 1
                beginCurrentStep()
            } else {
                exerciseCurrentPoint()
            }
        }

        private func selectedDate(for step: Step) -> LocalDate {
            switch step {
            case .previousDay, .nextDay: store.selectedDate
            case .previousMonth, .nextMonth: store.selectedCalendarDate
            }
        }

        private func expectedDate(after date: LocalDate, for step: Step) -> LocalDate {
            switch step {
            case .previousDay:
                NoonmarkStore.offset(date, by: -1)
            case .nextDay:
                NoonmarkStore.offset(date, by: 1)
            case .previousMonth:
                NoonmarkStore.shiftedMonth(from: date, by: -1)
            case .nextMonth:
                NoonmarkStore.shiftedMonth(from: date, by: 1)
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

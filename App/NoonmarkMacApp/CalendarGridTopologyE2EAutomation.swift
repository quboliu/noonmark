import AppKit
import Foundation
import NoonmarkCore

struct CalendarGridTopologyE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> CalendarGridTopologyE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-calendar-grid-topology"),
              let path = AppLaunchArguments.value(
                  after: "--e2e-calendar-grid-topology-result-url"
              )
        else {
            return nil
        }
        return CalendarGridTopologyE2EAutomation(
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        store.page = .calendar
        store.selectedCalendarDate = LocalDate(
            year: 2026,
            month: 8,
            day: 22
        )
        store.isDetailRailExpanded = false
        CalendarGridTopologyE2EDriver.start(
            store: store,
            resultURL: resultURL
        )
    }
}

@MainActor
private enum CalendarGridTopologyE2EDriver {
    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL
        private let expectedSlotCount = 42
        private var failures: [String] = []

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            let slots = (0..<expectedSlotCount).compactMap {
                AppViewTreeE2E.view(identifier: "calendar.grid-slot.\($0)")
            }
            let bottomBoundaries = (0..<expectedSlotCount).compactMap {
                AppViewTreeE2E.view(
                    identifier: "calendar.grid-slot.\($0).bottom-boundary"
                )
            }
            let trailingBoundaries = (0..<expectedSlotCount).compactMap {
                AppViewTreeE2E.view(
                    identifier: "calendar.grid-slot.\($0).trailing-boundary"
                )
            }
            guard slots.count == expectedSlotCount,
                  bottomBoundaries.count == expectedSlotCount,
                  trailingBoundaries.count == expectedSlotCount
            else {
                retry(attemptsRemaining) {
                    "2026 年 8 月网格没有形成 42 个完整槽位："
                        + "slot=\(slots.count),bottom=\(bottomBoundaries.count),"
                        + "trailing=\(trailingBoundaries.count)"
                }
                return
            }

            verifyCompleteGrid(
                slots: slots,
                bottomBoundaries: bottomBoundaries,
                trailingBoundaries: trailingBoundaries
            )
            finish()
        }

        private func verifyCompleteGrid(
            slots: [NSView],
            bottomBoundaries: [NSView],
            trailingBoundaries: [NSView]
        ) {
            let slotFrames = slots.map(AppViewTreeE2E.frameInWindow(for:))
            let bottomFrames = bottomBoundaries.map(
                AppViewTreeE2E.frameInWindow(for:)
            )
            let trailingFrames = trailingBoundaries.map(
                AppViewTreeE2E.frameInWindow(for:)
            )

            if AppViewTreeE2E.view(
                identifier: "calendar.grid-slot.\(expectedSlotCount)"
            ) != nil {
                failures.append("2026 年 8 月网格产生了多余的第 43 个槽位")
            }

            for index in 0..<expectedSlotCount {
                let slot = slotFrames[index]
                let bottom = bottomFrames[index]
                let trailing = trailingFrames[index]
                if slot.width <= 0 || slot.height < 88 {
                    failures.append("日历槽位 \(index) 尺寸无效：\(slot)")
                }
                let hasCompleteBottom = abs(bottom.width - slot.width) <= 1.5
                    && abs(bottom.minY - slot.minY) <= 1.5
                    && abs(bottom.height - 1) <= 1
                if hasCompleteBottom == false {
                    failures.append("日历槽位 \(index) 缺少完整底边：\(bottom)")
                }
                let hasCompleteTrailing = abs(
                    trailing.height - slot.height
                ) <= 1.5
                    && abs(trailing.maxX - slot.maxX) <= 1.5
                    && abs(trailing.width - 1) <= 1
                if hasCompleteTrailing == false {
                    failures.append("日历槽位 \(index) 缺少完整右边：\(trailing)")
                }
            }

            verifyMissingEdgeRegression(
                slotFrames: slotFrames,
                bottomFrames: bottomFrames,
                trailingFrames: trailingFrames
            )
        }

        private func verifyMissingEdgeRegression(
            slotFrames: [NSRect],
            bottomFrames: [NSRect],
            trailingFrames: [NSRect]
        ) {
            let dayOneSlot = slotFrames[5]
            if abs(trailingFrames[4].midX - dayOneSlot.minX) > 1.5 {
                failures.append("1 号左侧没有由前置空白槽位提供连续边界")
            }

            for leadingIndex in 0...4 {
                let nextRowSlot = slotFrames[leadingIndex + 7]
                if abs(bottomFrames[leadingIndex].midY - nextRowSlot.maxY) > 1.5 {
                    failures.append(
                        "\(leadingIndex + 3) 号上方没有由前置空白槽位提供连续边界"
                    )
                }
            }

            let expectedDates = [1: 5, 3: 7, 7: 11]
            for (day, slotIndex) in expectedDates {
                let date = LocalDate(year: 2026, month: 8, day: day)
                guard let dateCell = AppViewTreeE2E.view(
                    identifier: "calendar.date-cell.\(date.description)"
                ) else {
                    failures.append("日历缺少 \(date.description) 日期格")
                    continue
                }
                let dateFrame = AppViewTreeE2E.frameInWindow(for: dateCell)
                if slotFrames[slotIndex].intersects(dateFrame) == false {
                    failures.append("\(date.description) 没有落在预期网格槽位")
                }
            }
        }

        private func retry(
            _ attemptsRemaining: Int,
            failure: @escaping () -> String
        ) {
            guard attemptsRemaining > 1 else {
                failures.append(failure())
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                start(attemptsRemaining: attemptsRemaining - 1)
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

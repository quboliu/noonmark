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
        store.isDetailRailExpanded = true
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
        private let columnCount = 7
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
            let expectedBottomBoundaryCount =
                expectedSlotCount - columnCount
            let expectedTrailingBoundaryCount =
                expectedSlotCount - expectedSlotCount / columnCount
            guard slots.count == expectedSlotCount,
                  bottomBoundaries.count == expectedBottomBoundaryCount,
                  trailingBoundaries.count == expectedTrailingBoundaryCount
            else {
                retry(attemptsRemaining) {
                    "2026 年 8 月网格没有形成 42 个完整槽位："
                        + "slot=\(slots.count),bottom=\(bottomBoundaries.count),"
                        + "trailing=\(trailingBoundaries.count)"
                }
                return
            }

            verifyCompleteGrid(
                slots: slots
            )
            verifyContainerEdgeAlignment(slots: slots)
            finish()
        }

        private func verifyContainerEdgeAlignment(slots: [NSView]) {
            guard let middlePane = AppViewTreeE2E.view(
                identifier: "shell.middle-pane"
            ) else {
                failures.append("日历缺少主区域几何锚点")
                return
            }
            let middleFrame = AppViewTreeE2E.frameInWindow(for: middlePane)
            let slotFrames = slots.map(AppViewTreeE2E.frameInWindow(for:))
            let trailingEdge = (0..<6)
                .map { slotFrames[$0 * 7 + 6].maxX }
                .max() ?? 0
            let bottomEdge = (35..<42)
                .map { slotFrames[$0].minY }
                .min() ?? 0

            if abs(trailingEdge - middleFrame.maxX) > 1.5 {
                failures.append(
                    "日历最右列没有借主区域右边界收口："
                        + "grid=\(trailingEdge),middle=\(middleFrame.maxX)"
                )
            }
            if abs(bottomEdge - middleFrame.minY) > 1.5 {
                failures.append(
                    "日历最后一行没有借主区域底边界收口："
                        + "grid=\(bottomEdge),middle=\(middleFrame.minY)"
                )
            }
        }

        private func verifyCompleteGrid(
            slots: [NSView]
        ) {
            let slotFrames = slots.map(AppViewTreeE2E.frameInWindow(for:))
            var bottomFrames: [Int: NSRect] = [:]
            var trailingFrames: [Int: NSRect] = [:]

            if AppViewTreeE2E.view(
                identifier: "calendar.grid-slot.\(expectedSlotCount)"
            ) != nil {
                failures.append("2026 年 8 月网格产生了多余的第 43 个槽位")
            }

            for index in 0..<expectedSlotCount {
                let slot = slotFrames[index]
                if slot.width <= 0 || slot.height < 88 {
                    failures.append("日历槽位 \(index) 尺寸无效：\(slot)")
                }
                if let bottom = verifiedBottomBoundary(
                    at: index,
                    slot: slot
                ) {
                    bottomFrames[index] = bottom
                }
                if let trailing = verifiedTrailingBoundary(
                    at: index,
                    slot: slot
                ) {
                    trailingFrames[index] = trailing
                }
            }

            verifyMissingEdgeRegression(
                slotFrames: slotFrames,
                bottomFrames: bottomFrames,
                trailingFrames: trailingFrames
            )
        }

        private func verifiedBottomBoundary(
            at index: Int,
            slot: NSRect
        ) -> NSRect? {
            let boundary = AppViewTreeE2E.view(
                identifier: "calendar.grid-slot.\(index).bottom-boundary"
            )
            let shouldShow = index < expectedSlotCount - columnCount
            guard shouldShow else {
                if boundary != nil {
                    failures.append(
                        "日历最后一行槽位 \(index) 重复绘制外部底边"
                    )
                }
                return nil
            }
            guard let boundary else {
                failures.append("日历槽位 \(index) 缺少内部底边")
                return nil
            }
            let frame = AppViewTreeE2E.frameInWindow(for: boundary)
            let isComplete = abs(frame.width - slot.width) <= 1.5
                && abs(frame.minY - slot.minY) <= 1.5
                && abs(frame.height - 1) <= 1
            if isComplete == false {
                failures.append("日历槽位 \(index) 缺少完整底边：\(frame)")
            }
            return frame
        }

        private func verifiedTrailingBoundary(
            at index: Int,
            slot: NSRect
        ) -> NSRect? {
            let boundary = AppViewTreeE2E.view(
                identifier: "calendar.grid-slot.\(index).trailing-boundary"
            )
            let shouldShow = index % columnCount < columnCount - 1
            guard shouldShow else {
                if boundary != nil {
                    failures.append(
                        "日历最右列槽位 \(index) 重复绘制外部右边"
                    )
                }
                return nil
            }
            guard let boundary else {
                failures.append("日历槽位 \(index) 缺少内部右边")
                return nil
            }
            let frame = AppViewTreeE2E.frameInWindow(for: boundary)
            let isComplete = abs(frame.height - slot.height) <= 1.5
                && abs(frame.maxX - slot.maxX) <= 1.5
                && abs(frame.width - 1) <= 1
            if isComplete == false {
                failures.append("日历槽位 \(index) 缺少完整右边：\(frame)")
            }
            return frame
        }

        private func verifyMissingEdgeRegression(
            slotFrames: [NSRect],
            bottomFrames: [Int: NSRect],
            trailingFrames: [Int: NSRect]
        ) {
            let dayOneSlot = slotFrames[5]
            if let leadingBoundary = trailingFrames[4] {
                let isMisaligned =
                    abs(leadingBoundary.midX - dayOneSlot.minX) > 1.5
                if isMisaligned {
                    failures.append(
                        "1 号左侧没有由前置空白槽位提供连续边界"
                    )
                }
            }

            for leadingIndex in 0...4 {
                let nextRowSlot = slotFrames[leadingIndex + 7]
                if let upperBoundary = bottomFrames[leadingIndex] {
                    let isMisaligned =
                        abs(upperBoundary.midY - nextRowSlot.maxY) > 1.5
                    if isMisaligned {
                        failures.append(
                            "\(leadingIndex + 3) 号上方没有由前置空白槽位提供连续边界"
                        )
                    }
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

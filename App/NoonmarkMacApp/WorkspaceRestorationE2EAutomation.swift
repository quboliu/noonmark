import AppKit
import Foundation
import NoonmarkMacRuntime

@MainActor
struct WorkspaceRestorationE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case prepareAutomaticRestart
        case verifyAutomaticRestart
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let windowX: Double
        let windowY: Double
        let windowWidth: Double
        let windowHeight: Double
        let sidebarWidth: Double
        let detailWidth: Double
    }

    private struct AutomaticProbeState: Codable {
        let sidebarWidth: Double
    }

    private struct ObservedGeometry {
        let sidebarWidth: Double
        let detailWidth: Double
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

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains(
            "--e2e-workspace-restoration-automatic-prepare"
        ) {
            mode = .prepareAutomaticRestart
        } else if AppLaunchArguments.contains(
            "--e2e-workspace-restoration-automatic-verify"
        ) {
            mode = .verifyAutomaticRestart
        } else if AppLaunchArguments.contains(
            "--e2e-workspace-restoration-exercise"
        ) {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-workspace-restoration-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }
        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-workspace-restoration-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-workspace-restoration-result-url"
        ) else {
            return nil
        }
        return Self(
            mode: mode,
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .prepareAutomaticRestart:
                    try await prepareAutomaticRestart(store: store)
                case .verifyAutomaticRestart:
                    try await verifyAutomaticRestart(store: store)
                case .exercise:
                    try await exercise(store: store)
                case .verifyRestart:
                    try await verifyRestart(store: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            NSApp.terminate(nil)
        }
    }

    private func prepareAutomaticRestart(store: NoonmarkStore) async throws {
        let window = try await mainWindow()
        let splitView = try await workspaceSplitView()
        store.page = .calendar
        store.isDetailRailExpanded = true
        try await waitForDetailWidth(
            Double(NoonmarkVisualMetrics.calendarRailWidth),
            failure: "calendar automatic detail width did not settle before restart"
        )
        try await activate(window)
        let sidebarWidth = try await setSidebarWidth(
            264,
            splitView: splitView,
            window: window
        )
        try await waitForDetailWidth(
            Double(NoonmarkVisualMetrics.calendarRailWidth),
            failure: "sidebar drag changed the calendar automatic detail width"
        )
        let persisted = WorkspaceStateRepository().load()
        guard persisted.detailExpanded,
              persisted.usesCustomDetailWidth == false
        else {
            throw Failure.failed(
                "automatic calendar width was incorrectly persisted as custom"
            )
        }
        try writeAutomaticState(
            AutomaticProbeState(sidebarWidth: sidebarWidth)
        )
    }

    private func verifyAutomaticRestart(store: NoonmarkStore) async throws {
        let expected = try readAutomaticState()
        _ = try await mainWindow()
        _ = try await workspaceSplitView()
        guard store.page == .day,
              WorkspaceStateRepository().load().usesCustomDetailWidth == false
        else {
            throw Failure.failed(
                "automatic restart did not retain Day and automatic-width semantics"
            )
        }
        try await waitForDetailWidth(
            Double(NoonmarkVisualMetrics.detailRailWidth),
            failure: "Day restart reused the calendar automatic detail width"
        )
        try await waitUntil("automatic restart reset the custom sidebar width") {
            guard let sidebar = AppViewTreeE2E.view(
                identifier: "shell.sidebar"
            ) else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - expected.sidebarWidth
            ) <= 2
        }
    }

    private func exercise(store: NoonmarkStore) async throws {
        WorkspaceDragE2EDiagnostics.reset()
        let window = try await mainWindow()
        try assertNativeWindowContract(window)
        let splitView = try await workspaceSplitView()
        try configureExerciseFrame(window)
        try await ensureDetailExpanded(store: store)

        let expectedSidebarWidth = 264.0
        let expectedDetailWidth = 336.0
        try await activate(window)
        let observedSidebarWidth = try await setSidebarWidth(
            expectedSidebarWidth,
            splitView: splitView,
            window: window
        )
        guard store.page == .day,
              store.shouldShowDetailRail,
              AppViewTreeE2E.hasNoVisibleView(
                  identifier: "shell.detail-rail"
              ) == false
        else {
            throw Failure.failed(
                "sidebar divider drag changed the active page or detail visibility: "
                    + workspaceDiagnostic(store: store)
            )
        }
        let observedDetailWidth = try await setDetailWidth(
            expectedDetailWidth,
            expectedSidebarWidth: expectedSidebarWidth,
            splitView: splitView,
            window: window,
            store: store
        )
        let geometry = ObservedGeometry(
            sidebarWidth: observedSidebarWidth,
            detailWidth: observedDetailWidth
        )
        try await verifyCustomWidthInteractions(
            expectedDetailWidth,
            store: store
        )
        try await collapseSidebarAndPersist(
            geometry: geometry,
            store: store,
            window: window
        )
    }

    private func configureExerciseFrame(_ window: NSWindow) throws {
        guard let visibleFrame = window.screen?.visibleFrame else {
            throw Failure.failed("main window did not have a visible screen")
        }
        let targetSize = NSSize(
            width: min(1128, visibleFrame.width - 80),
            height: min(744, visibleFrame.height - 80)
        )
        let targetFrame = NSRect(
            x: visibleFrame.minX + 47,
            y: visibleFrame.minY + 31,
            width: max(targetSize.width, NoonmarkVisualMetrics.minimumSize.width),
            height: max(targetSize.height, NoonmarkVisualMetrics.minimumSize.height)
        )
        window.setFrame(targetFrame, display: true)
        window.saveFrame(usingName: NoonmarkMainWindowState.frameAutosaveName)
    }

    private func ensureDetailExpanded(store: NoonmarkStore) async throws {
        if store.isDetailRailExpanded == false {
            guard AppViewTreeE2E.click(identifier: "shell.detail-rail.toggle") else {
                throw Failure.failed("detail boundary toggle rejected a real mouse click")
            }
        }
        try await waitUntil("detail rail did not expand") {
            store.shouldShowDetailRail
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail") == false
        }
    }

    private func setSidebarWidth(
        _ expectedSidebarWidth: Double,
        splitView: NSSplitView,
        window: NSWindow
    ) async throws -> Double {
        try await dragDivider(
            at: 0,
            toLeadingPosition: splitView.bounds.minX + expectedSidebarWidth,
            in: splitView,
            window: window
        )
        try await waitUntil("native sidebar divider did not settle") {
            guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar") else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - expectedSidebarWidth
            ) <= 2
        }
        guard WorkspaceStateRepository().load().usesCustomDetailWidth == false else {
            throw Failure.failed(
                "dragging the sidebar incorrectly marked the detail width as custom"
            )
        }
        guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar") else {
            throw Failure.failed("sidebar disappeared after its divider settled")
        }
        return Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
    }

    private func setDetailWidth(
        _ expectedDetailWidth: Double,
        expectedSidebarWidth: Double,
        splitView: NSSplitView,
        window: NSWindow,
        store: NoonmarkStore
    ) async throws -> Double {
        guard let middleBeforeDetailDrag = AppViewTreeE2E.view(
            identifier: "shell.middle-pane"
        ), let detailBeforeDrag = AppViewTreeE2E.view(
            identifier: "shell.detail-rail"
        ) else {
            throw Failure.failed("detail divider geometry anchors were unavailable")
        }
        let windowFrameBeforeDetailDrag = window.frame
        let workspaceWidthBeforeDetailDrag = splitView.bounds.width
        let middleWidthBeforeDetailDrag = Double(
            AppViewTreeE2E.frameInWindow(for: middleBeforeDetailDrag).width
        )
        let detailWidthBeforeDrag = Double(
            AppViewTreeE2E.frameInWindow(for: detailBeforeDrag).width
        )
        try await dragDivider(
            at: 1,
            toLeadingPosition: splitView.bounds.maxX
                - expectedDetailWidth
                - splitView.dividerThickness,
            in: splitView,
            window: window
        )

        var observedSidebarWidth = 0.0
        var observedMiddleWidth = 0.0
        var observedDetailWidth = 0.0
        do {
            try await waitUntil("native divider positions did not settle") {
                guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                      let detail = AppViewTreeE2E.view(identifier: "shell.detail-rail"),
                      let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane")
                else {
                    return false
                }
                observedSidebarWidth = Double(
                    AppViewTreeE2E.frameInWindow(for: sidebar).width
                )
                observedDetailWidth = Double(
                    AppViewTreeE2E.frameInWindow(for: detail).width
                )
                observedMiddleWidth = Double(
                    AppViewTreeE2E.frameInWindow(for: middle).width
                )
                let expectedMiddleWidth = middleWidthBeforeDetailDrag
                    - (expectedDetailWidth - detailWidthBeforeDrag)
                return abs(observedSidebarWidth - expectedSidebarWidth) <= 2
                    && abs(observedDetailWidth - expectedDetailWidth) <= 2
                    && abs(observedMiddleWidth - expectedMiddleWidth) <= 2
            }
        } catch {
            throw Failure.failed(
                "native divider positions did not settle: "
                    + workspaceDiagnostic(store: store)
                    + ",observedSidebar=\(observedSidebarWidth)"
                    + ",observedDetail=\(observedDetailWidth)"
                    + ",drag=\(WorkspaceDragE2EDiagnostics.report)"
            )
        }
        guard window.frame == windowFrameBeforeDetailDrag else {
            throw Failure.failed("dragging the detail divider changed the window frame")
        }
        guard WorkspaceDragE2EDiagnostics.workspaceWidthStayed(
            near: workspaceWidthBeforeDetailDrag,
            tolerance: 2
        ) else {
            throw Failure.failed(
                "dragging a native divider resized the workspace: "
                    + WorkspaceDragE2EDiagnostics.report
            )
        }
        let paneWidthTotal = observedSidebarWidth
            + observedMiddleWidth
            + observedDetailWidth
            + Double(splitView.dividerThickness * 2)
        guard abs(paneWidthTotal - Double(splitView.bounds.width)) <= 2 else {
            throw Failure.failed(
                "native pane widths did not conserve the workspace width: "
                    + "panes=\(paneWidthTotal),workspace=\(splitView.bounds.width)"
            )
        }
        guard WorkspaceStateRepository().load().usesCustomDetailWidth else {
            throw Failure.failed(
                "real detail-divider drag did not persist custom-width mode"
            )
        }
        return observedDetailWidth
    }

    private func workspaceDiagnostic(store: NoonmarkStore) -> String {
        let sidebarWidth = AppViewTreeE2E.view(identifier: "shell.sidebar")
            .map { AppViewTreeE2E.frameInWindow(for: $0).width }
        let middleWidth = AppViewTreeE2E.view(identifier: "shell.middle-pane")
            .map { AppViewTreeE2E.frameInWindow(for: $0).width }
        let detailWidth = AppViewTreeE2E.view(identifier: "shell.detail-rail")
            .map { AppViewTreeE2E.frameInWindow(for: $0).width }
        return "page=\(store.page.rawValue)"
            + ",detailExpanded=\(store.isDetailRailExpanded)"
            + ",hasDetail=\(store.hasDetailRailContent)"
            + ",shouldShowDetail=\(store.shouldShowDetailRail)"
            + ",sidebar=\(sidebarWidth.map(String.init(describing:)) ?? "hidden")"
            + ",middle=\(middleWidth.map(String.init(describing:)) ?? "hidden")"
            + ",detail=\(detailWidth.map(String.init(describing:)) ?? "hidden")"
    }

    private func verifyCustomWidthInteractions(
        _ expectedDetailWidth: Double,
        store: NoonmarkStore
    ) async throws {
        store.page = .calendar
        try await waitForDetailWidth(
            expectedDetailWidth,
            failure: "calendar replaced the user's custom detail width"
        )
        store.page = .day
        try await waitForDetailWidth(
            expectedDetailWidth,
            failure: "returning to Day replaced the user's custom detail width"
        )

        guard AppViewTreeE2E.click(identifier: "shell.detail-rail.toggle") else {
            throw Failure.failed("detail boundary toggle rejected the collapse click")
        }
        try await waitUntil("detail rail did not collapse") {
            store.shouldShowDetailRail == false
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail")
        }
        guard AppViewTreeE2E.click(identifier: "shell.detail-rail.toggle") else {
            throw Failure.failed("detail boundary toggle rejected the expand click")
        }
        try await waitForDetailWidth(
            expectedDetailWidth,
            failure: "collapsing and expanding changed the custom detail width"
        )
    }

    private func collapseSidebarAndPersist(
        geometry: ObservedGeometry,
        store: NoonmarkStore,
        window: NSWindow
    ) async throws {
        guard AppViewTreeE2E.click(identifier: "shell.sidebar.toggle") else {
            throw Failure.failed("sidebar boundary toggle rejected a real mouse click")
        }
        try await waitUntil("sidebar did not collapse after a real mouse click") {
            guard store.isSidebarExpanded == false,
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar")
            else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - WorkspaceGeometry.compactSidebarWidth
            ) <= 2
        }

        let persisted = WorkspaceStateRepository().load()
        guard persisted.sidebarExpanded == false,
              persisted.detailExpanded,
              persisted.usesCustomDetailWidth,
              abs(persisted.expandedSidebarWidth - geometry.sidebarWidth) <= 2
        else {
            throw Failure.failed("workspace repository did not retain collapse state")
        }
        guard let collapsedDetail = AppViewTreeE2E.view(
            identifier: "shell.detail-rail"
        ), abs(
            Double(AppViewTreeE2E.frameInWindow(for: collapsedDetail).width)
                - geometry.detailWidth
        ) <= 2
        else {
            throw Failure.failed("collapsing the sidebar changed the inspector width")
        }
        window.saveFrame(usingName: NoonmarkMainWindowState.frameAutosaveName)
        let frame = window.frame
        try writeState(
            ProbeState(
                windowX: frame.minX,
                windowY: frame.minY,
                windowWidth: frame.width,
                windowHeight: frame.height,
                sidebarWidth: geometry.sidebarWidth,
                detailWidth: geometry.detailWidth
            )
        )
    }

    private func verifyRestart(store: NoonmarkStore) async throws {
        let expected = try readState()
        guard WorkspaceStateRepository().load().usesCustomDetailWidth else {
            throw Failure.failed("restart lost the persisted custom-width mode")
        }
        let window = try await mainWindow()
        try assertNativeWindowContract(window)
        _ = try await workspaceSplitView()

        try await waitUntil("window frame or collapse state was not restored") {
            let frame = window.frame
            return abs(frame.minX - expected.windowX) <= 1
                && abs(frame.minY - expected.windowY) <= 1
                && abs(frame.width - expected.windowWidth) <= 1
                && abs(frame.height - expected.windowHeight) <= 1
                && store.isSidebarExpanded == false
                && store.isDetailRailExpanded
                && AppViewTreeE2E.view(identifier: "shell.sidebar") != nil
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail") == false
        }

        try await waitUntil("compact sidebar width was not restored") {
            guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar")
            else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - WorkspaceGeometry.compactSidebarWidth
            ) <= 2
        }

        var observedDetailWidth = 0.0
        try await waitUntil("detail width did not settle after restart") {
            guard let detail = AppViewTreeE2E.view(identifier: "shell.detail-rail") else {
                return false
            }
            observedDetailWidth = Double(
                AppViewTreeE2E.frameInWindow(for: detail).width
            )
            return abs(observedDetailWidth - expected.detailWidth) <= 2
        }

        store.page = .calendar
        try await waitForDetailWidth(
            expected.detailWidth,
            failure: "calendar replaced the restored custom detail width"
        )
        store.page = .day
        try await waitForDetailWidth(
            expected.detailWidth,
            failure: "returning to Day replaced the restored custom detail width"
        )

        guard AppViewTreeE2E.click(identifier: "shell.sidebar.toggle") else {
            throw Failure.failed("restored sidebar toggle rejected a real mouse click")
        }
        try await waitUntil("restored sidebar did not expand") {
            guard store.isSidebarExpanded,
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let detail = AppViewTreeE2E.view(identifier: "shell.detail-rail")
            else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - expected.sidebarWidth
            ) <= 2
                && abs(
                    Double(AppViewTreeE2E.frameInWindow(for: detail).width)
                        - expected.detailWidth
                ) <= 2
        }

        let persisted = WorkspaceStateRepository().load()
        guard persisted.sidebarExpanded,
              persisted.detailExpanded,
              persisted.usesCustomDetailWidth
        else {
            throw Failure.failed("expanded column state was not persisted after restart")
        }
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not become active before divider drag") {
            NSApp.isActive
                && window.isVisible
                && window.isMiniaturized == false
                && window.isKeyWindow
                && window.isMainWindow
        }
    }

    private func dragDivider(
        at dividerIndex: Int,
        toLeadingPosition targetLeadingPosition: CGFloat,
        in splitView: NSSplitView,
        window: NSWindow
    ) async throws {
        guard splitView.isVertical,
              splitView.arrangedSubviews.indices.contains(dividerIndex),
              splitView.arrangedSubviews.indices.contains(dividerIndex + 1)
        else {
            throw Failure.failed("workspace divider geometry was unavailable")
        }
        let minimumPosition = splitView.minPossiblePositionOfDivider(
            at: dividerIndex
        )
        let maximumPosition = splitView.maxPossiblePositionOfDivider(
            at: dividerIndex
        )
        guard targetLeadingPosition >= minimumPosition,
              targetLeadingPosition <= maximumPosition
        else {
            throw Failure.failed(
                "requested divider position \(targetLeadingPosition) was outside "
                    + "\(minimumPosition)...\(maximumPosition)"
            )
        }

        let thickness = splitView.dividerThickness
        let sourceLeadingPosition = if dividerIndex == 0 {
            splitView.arrangedSubviews[0].frame.maxX
        } else {
            splitView.arrangedSubviews[
                dividerIndex + 1
            ].frame.minX - thickness
        }
        let sourcePoint = splitView.convert(
            NSPoint(
                x: sourceLeadingPosition + thickness / 2,
                y: splitView.bounds.midY
            ),
            to: nil
        )
        let targetPoint = splitView.convert(
            NSPoint(
                x: targetLeadingPosition + thickness / 2,
                y: splitView.bounds.midY
            ),
            to: nil
        )
        let root = window.contentView?.superview ?? window.contentView
        let sourceHit = root?.hitTest(sourcePoint)
        let targetHit = root?.hitTest(targetPoint)
        let dividerRect = NSRect(
            x: sourceLeadingPosition,
            y: splitView.bounds.minY,
            width: thickness,
            height: splitView.bounds.height
        )
        WorkspaceDragE2EDiagnostics.recordPointerEvidence(
            "divider=\(dividerIndex),range=\(minimumPosition)...\(maximumPosition),"
                + "drawn=\(dividerRect),"
                + "sourceWindow=\(sourcePoint),"
                + "sourceHit=\(sourceHit.map { String(describing: type(of: $0)) } ?? "nil"),"
                + "targetWindow=\(targetPoint),"
                + "targetHit=\(targetHit.map { String(describing: type(of: $0)) } ?? "nil")"
        )
        let input: WindowServerInputDriver
        do {
            input = try WindowServerInputDriver()
        } catch {
            throw Failure.failed(
                "WindowServer divider drag could not start: "
                    + error.localizedDescription
            )
        }
        let resolveSource:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            try dividerSourceCoordinate(
                at: dividerIndex,
                in: splitView,
                window: window,
                input: input
            )
        }
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            try dividerTargetCoordinate(
                at: dividerIndex,
                toLeadingPosition: targetLeadingPosition,
                in: splitView,
                window: window,
                input: input
            )
        }
        let sourceCoordinate: WindowServerInputDriver.PointerCoordinate
        let targetCoordinate: WindowServerInputDriver.PointerCoordinate
        do {
            sourceCoordinate = try resolveSource()
            targetCoordinate = try resolveTarget()
            WorkspaceDragE2EDiagnostics.recordPointerEvidence(
                "divider=\(dividerIndex),sourceCoordinate=\(sourceCoordinate.report),"
                    + "targetCoordinate=\(targetCoordinate.report)"
            )
        } catch {
            throw Failure.failed(
                "WindowServer divider coordinates were invalid: "
                    + error.localizedDescription
            )
        }
        let pump = WindowServerDragEventPump(
            window: window,
            input: input,
            sourceCoordinate: sourceCoordinate,
            targetCoordinate: targetCoordinate,
            resolveSource: resolveSource,
            resolveTarget: resolveTarget,
            expectsNativePath: false
        )
        do {
            try pump.start()
            try await waitUntil(
                "WindowServer divider drag did not finish",
                attempts: 160
            ) {
                pump.isFinalized
            }
        } catch {
            let primaryFailure = error.localizedDescription
            pump.cancel()
            var cleanupFailure: String?
            do {
                try await waitUntil(
                    "WindowServer divider drag cleanup did not finish",
                    attempts: 100
                ) {
                    pump.isFinalized
                }
            } catch {
                cleanupFailure = error.localizedDescription
            }
            if input.isLeftButtonDown {
                cleanupFailure = [
                    cleanupFailure,
                    "combined-session left button remained down"
                ].compactMap { $0 }.joined(separator: "; ")
            }
            throw Failure.failed(
                "WindowServer divider drag failed: "
                    + primaryFailure
                    + (cleanupFailure.map { "; cleanup: \($0)" } ?? "")
            )
        }
        if let failure = pump.failure {
            throw Failure.failed("WindowServer divider drag failed: \(failure)")
        }
        guard input.isLeftButtonDown == false else {
            throw Failure.failed(
                "WindowServer divider drag left the combined-session button down"
            )
        }
    }

    private func dividerSourceCoordinate(
        at dividerIndex: Int,
        in splitView: NSSplitView,
        window: NSWindow,
        input: WindowServerInputDriver
    ) throws -> WindowServerInputDriver.PointerCoordinate {
        guard splitView.window === window,
              splitView.isHiddenOrHasHiddenAncestor == false,
              splitView.arrangedSubviews.indices.contains(dividerIndex),
              splitView.arrangedSubviews.indices.contains(dividerIndex + 1)
        else {
            throw Failure.failed(
                "workspace divider source changed before WindowServer event"
            )
        }
        let thickness = splitView.dividerThickness
        let leadingPosition = if dividerIndex == 0 {
            splitView.arrangedSubviews[0].frame.maxX
        } else {
            splitView.arrangedSubviews[
                dividerIndex + 1
            ].frame.minX - thickness
        }
        let point = splitView.convert(
            NSPoint(
                x: leadingPosition + thickness / 2,
                y: splitView.bounds.midY
            ),
            to: nil
        )
        return try input.pointerCoordinate(
            windowPoint: point,
            in: window
        )
    }

    private func dividerTargetCoordinate(
        at dividerIndex: Int,
        toLeadingPosition targetLeadingPosition: CGFloat,
        in splitView: NSSplitView,
        window: NSWindow,
        input: WindowServerInputDriver
    ) throws -> WindowServerInputDriver.PointerCoordinate {
        guard splitView.window === window,
              splitView.isHiddenOrHasHiddenAncestor == false
        else {
            throw Failure.failed(
                "workspace divider destination changed before WindowServer event"
            )
        }
        let minimum = splitView.minPossiblePositionOfDivider(at: dividerIndex)
        let maximum = splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        guard targetLeadingPosition >= minimum,
              targetLeadingPosition <= maximum
        else {
            throw Failure.failed(
                "workspace divider destination left its valid range"
            )
        }
        let point = splitView.convert(
            NSPoint(
                x: targetLeadingPosition + splitView.dividerThickness / 2,
                y: splitView.bounds.midY
            ),
            to: nil
        )
        return try input.pointerCoordinate(
            windowPoint: point,
            in: window
        )
    }

    private func waitForDetailWidth(
        _ expectedWidth: Double,
        failure: String
    ) async throws {
        try await waitUntil(failure) {
            guard let detail = AppViewTreeE2E.view(
                identifier: "shell.detail-rail"
            ) else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: detail).width)
                    - expectedWidth
            ) <= 2
        }
    }

    private func assertNativeWindowContract(_ window: NSWindow) throws {
        guard window.identifier == NoonmarkMainWindowState.identifier,
              window.isRestorable,
              window.restorationClass != nil,
              window.frameAutosaveName == NoonmarkMainWindowState.frameAutosaveName
        else {
            throw Failure.failed("main window restoration contract was incomplete")
        }
    }

    private func mainWindow() async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil("main window was not available") {
            resolved = NSApp.windows.first { $0 is NoonmarkWindow }
            return resolved != nil
        }
        guard let resolved else {
            throw Failure.failed("main window disappeared after becoming available")
        }
        return resolved
    }

    private func workspaceSplitView() async throws -> NSSplitView {
        var resolved: NSSplitView?
        try await waitUntil("native workspace split view was not available") {
            resolved = AppViewTreeE2E.view(
                identifier: "shell.workspace-split"
            ) as? NSSplitView
            return resolved != nil
        }
        guard let resolved else {
            throw Failure.failed("native workspace split view disappeared")
        }
        return resolved
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 100,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeState(_ state: ProbeState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func readState() throws -> ProbeState {
        try JSONDecoder().decode(ProbeState.self, from: Data(contentsOf: stateURL))
    }

    private func writeAutomaticState(_ state: AutomaticProbeState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    private func readAutomaticState() throws -> AutomaticProbeState {
        try JSONDecoder().decode(
            AutomaticProbeState.self,
            from: Data(contentsOf: stateURL)
        )
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

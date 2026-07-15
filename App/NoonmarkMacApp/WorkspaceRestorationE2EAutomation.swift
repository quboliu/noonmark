import AppKit
import Foundation
import NoonmarkMacRuntime

@MainActor
struct WorkspaceRestorationE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
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
        if AppLaunchArguments.contains("--e2e-workspace-restoration-exercise") {
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

    private func exercise(store: NoonmarkStore) async throws {
        let window = try await mainWindow()
        try assertNativeWindowContract(window)
        let splitView = try await workspaceSplitView()
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

        if store.isDetailRailExpanded == false {
            guard AppViewTreeE2E.click(identifier: "shell.detail-rail.toggle") else {
                throw Failure.failed("detail toolbar item rejected a real mouse click")
            }
        }
        try await waitUntil("detail rail did not expand") {
            store.shouldShowDetailRail
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail") == false
        }

        let expectedSidebarWidth = 264.0
        let expectedDetailWidth = 336.0
        splitView.setPosition(CGFloat(expectedSidebarWidth), ofDividerAt: 0)
        splitView.setPosition(
            splitView.bounds.width - CGFloat(expectedDetailWidth),
            ofDividerAt: 1
        )
        splitView.layoutSubtreeIfNeeded()
        var observedSidebarWidth = 0.0
        var observedDetailWidth = 0.0
        try await waitUntil("native divider positions did not settle") {
            guard let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar"),
                  let detail = AppViewTreeE2E.view(identifier: "shell.detail-rail")
            else {
                return false
            }
            observedSidebarWidth = Double(
                AppViewTreeE2E.frameInWindow(for: sidebar).width
            )
            observedDetailWidth = Double(
                AppViewTreeE2E.frameInWindow(for: detail).width
            )
            return abs(observedSidebarWidth - expectedSidebarWidth) <= 2
                && abs(observedDetailWidth - expectedDetailWidth) <= 2
        }

        guard AppViewTreeE2E.click(identifier: "shell.sidebar.toggle") else {
            throw Failure.failed("sidebar toolbar item rejected a real mouse click")
        }
        try await waitUntil("sidebar did not collapse after a real mouse click") {
            store.isSidebarExpanded == false
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.sidebar")
        }

        let persisted = WorkspaceStateRepository().load()
        guard persisted.sidebarExpanded == false,
              persisted.detailExpanded
        else {
            throw Failure.failed("workspace repository did not retain collapse state")
        }
        guard let collapsedDetail = AppViewTreeE2E.view(
            identifier: "shell.detail-rail"
        ), abs(
            Double(AppViewTreeE2E.frameInWindow(for: collapsedDetail).width)
                - observedDetailWidth
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
                sidebarWidth: observedSidebarWidth,
                detailWidth: observedDetailWidth
            )
        )
    }

    private func verifyRestart(store: NoonmarkStore) async throws {
        let expected = try readState()
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
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.sidebar")
                && AppViewTreeE2E.hasNoVisibleView(identifier: "shell.detail-rail") == false
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

        guard AppViewTreeE2E.click(identifier: "shell.sidebar.toggle") else {
            throw Failure.failed("restored sidebar toggle rejected a real mouse click")
        }
        try await waitUntil("restored sidebar did not expand") {
            guard store.isSidebarExpanded,
                  let sidebar = AppViewTreeE2E.view(identifier: "shell.sidebar")
            else {
                return false
            }
            return abs(
                Double(AppViewTreeE2E.frameInWindow(for: sidebar).width)
                    - expected.sidebarWidth
            ) <= 2
        }

        let persisted = WorkspaceStateRepository().load()
        guard persisted.sidebarExpanded, persisted.detailExpanded else {
            throw Failure.failed("expanded column state was not persisted after restart")
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

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

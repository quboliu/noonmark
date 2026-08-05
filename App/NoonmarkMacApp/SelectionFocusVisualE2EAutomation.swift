import AppKit
import Foundation

/// Holds the signed E2E app on a real pointer-selected Day row so the outer
/// screenshot harness can verify the exact focus visual rendered by macOS.
@MainActor
struct SelectionFocusVisualE2EAutomation: LaunchAutomationRunnable {
    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private let resultURL: URL
    private let startGateConfiguration: UIEntryE2EStartGate.Configuration

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-selection-focus-result-url"
        ) else {
            return nil
        }
        let resultURL = URL(fileURLWithPath: resultPath)
        return Self(
            resultURL: resultURL,
            startGateConfiguration: UIEntryE2EStartGate.fromCommandLine(
                resultURL: resultURL
            )
        )
    }

    func run(on store: NoonmarkStore) {
        switch startGateConfiguration {
        case .disabled:
            runSelection(on: store)
        case let .invalid(message):
            try? writeResult("failed: selection focus start gate: \(message)")
        case let .enabled(startGate):
            do {
                try startGate.publishWaiting()
            } catch {
                try? writeResult("failed: selection focus start gate: \(error.localizedDescription)")
                return
            }
            Task { @MainActor in
                do {
                    let expectedWindowNumber = try await startGate.waitForArm()
                    try startGate.activateMainWindow(
                        expectedWindowNumber: expectedWindowNumber
                    )
                    try await preparePointerSelectedRow(on: store)
                    try writeResult("ok")
                } catch {
                    AppViewTreeE2E.writeDump(beside: resultURL)
                    try? writeResult("failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runSelection(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try await preparePointerSelectedRow(on: store)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
        }
    }

    private func preparePointerSelectedRow(on store: NoonmarkStore) async throws {
        store.page = .day
        store.selectedDate = store.today
        store.selectedCalendarDate = store.today
        store.clearSelection()

        guard let traceID = store.engine
            .getDayTodo(date: store.today)
            .traces
            .first?
            .id
        else {
            throw Failure.failed("selection focus fixture has no Day row")
        }
        let identifier = "workspace.item.day.\(traceID.description)"
        let window = try await visibleMainWindow()
        try await waitUntil("selection focus row did not render") {
            AppViewTreeE2E.view(identifier: identifier) != nil
        }
        try await ensureMainWindowActive(window)
        try await click(identifier, in: window)
        try await waitUntil("pointer click did not select the Day row") {
            store.workspaceSelection.selectedIDs == [.dayTrace(traceID)]
                && store.selectedTraceID == traceID
        }
    }

    private func click(_ identifier: String, in window: NSWindow) async throws {
        guard let anchor = AppViewTreeE2E.view(identifier: identifier),
              anchor.window === window,
              AppViewTreeE2E.buttonInteractionTarget(overlapping: anchor) != nil
        else {
            throw Failure.failed("selection focus click target is unavailable")
        }

        let input = try WindowServerInputDriver()
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentAnchor = AppViewTreeE2E.view(identifier: identifier),
                  let target = AppViewTreeE2E.buttonInteractionTarget(
                      overlapping: currentAnchor
                  ),
                  target.window === window,
                  target.window.isKeyWindow
            else {
                throw Failure.failed(
                    "selection focus target changed before mouseDown"
                )
            }
            return try input.pointerCoordinate(
                windowPoint: target.windowPoint,
                in: target.window
            )
        }

        do {
            try await input.postClick(
                at: try resolveTarget(),
                modifiers: [],
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "selection focus WindowServer click failed: "
                    + error.localizedDescription
            )
        }
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var window: NSWindow?
        try await waitUntil("selection focus main window was not visible") {
            window = NSApp.windows.first {
                $0 is NoonmarkWindow
                    && $0.isVisible
                    && $0.isMiniaturized == false
            }
            return window != nil
        }
        guard let window else {
            throw Failure.failed("selection focus main window disappeared")
        }
        return window
    }

    private func ensureMainWindowActive(_ window: NSWindow) async throws {
        requestMainWindowActivation(window)
        try await requestWindowServerForegroundIfNeeded(window)

        var consecutiveActiveSamples = 0
        for _ in 0 ..< 120 {
            if NSApp.isActive && window.isMainWindow && window.isKeyWindow {
                consecutiveActiveSamples += 1
                if consecutiveActiveSamples >= 4 { return }
            } else {
                consecutiveActiveSamples = 0
                requestMainWindowActivation(window)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed("selection focus window did not remain active")
    }

    private func requestWindowServerForegroundIfNeeded(
        _ window: NSWindow
    ) async throws {
        guard NSApp.isActive == false || window.isKeyWindow == false else { return }
        let input = try WindowServerInputDriver()
        let titleBarPoint = CGPoint(
            x: window.frame.midX,
            y: CGDisplayBounds(CGMainDisplayID()).height - window.frame.maxY + 14
        )
        let gestureNumber = input.nextMouseGestureNumber()
        try input.postMouse(
            type: .leftMouseDown,
            at: titleBarPoint,
            gestureNumber: gestureNumber,
            pressure: 1
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        try input.postMouse(
            type: .leftMouseUp,
            at: titleBarPoint,
            gestureNumber: gestureNumber,
            pressure: 0
        )
        try await waitUntil("selection focus title-bar click left button down") {
            input.isLeftButtonDown == false
        }
    }

    private func requestMainWindowActivation(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        let currentApplication = NSRunningApplication.current
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != currentApplication.processIdentifier
        {
            _ = currentApplication.activate(
                from: frontmostApplication,
                options: [.activateAllWindows]
            )
        } else {
            currentApplication.activate(options: [.activateAllWindows])
        }
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }
}

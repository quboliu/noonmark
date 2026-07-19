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

    static func fromCommandLine() -> Self? {
        guard let resultPath = AppLaunchArguments.value(
            after: "--e2e-selection-focus-result-url"
        ) else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    func run(on store: NoonmarkStore) {
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
        guard let view = AppViewTreeE2E.view(identifier: identifier),
              view.window === window,
              view.isHiddenOrHasHiddenAncestor == false,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            throw Failure.failed("selection focus click target is unavailable")
        }

        let input = try WindowServerInputDriver()
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentView = AppViewTreeE2E.view(identifier: identifier),
                  let currentWindow = currentView.window,
                  currentWindow === window,
                  currentWindow.isKeyWindow,
                  currentView.isHiddenOrHasHiddenAncestor == false,
                  currentView.bounds.width > 0,
                  currentView.bounds.height > 0
            else {
                throw Failure.failed(
                    "selection focus target changed before mouseDown"
                )
            }
            let point = currentView.convert(
                NSPoint(x: currentView.bounds.midX, y: currentView.bounds.midY),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: point,
                in: currentWindow
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("selection focus window did not become active") {
            NSApp.isActive && window.isMainWindow && window.isKeyWindow
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

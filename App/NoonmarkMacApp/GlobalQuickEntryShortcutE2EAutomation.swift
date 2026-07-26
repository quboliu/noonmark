import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

/// Verifies the installed Carbon hotkey from a different foreground app.
///
/// The test closes Noonmark's main window with a real keystroke, activates
/// Finder, posts the configured hotkey through WindowServer, types and submits
/// a real task, then checks both persistence state and focus restoration.
@MainActor
struct GlobalQuickEntryShortcutE2EAutomation: LaunchAutomationRunnable {
    private static let fixtureTitle = "globalshortcutrecoverytask"
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.contains(
            "--e2e-global-quick-entry-shortcut"
        ),
            let resultPath = AppLaunchArguments.value(
                after: "--e2e-global-quick-entry-result-url"
            )
        else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: resultPath))
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                try await exercise(on: store)
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let input = try WindowServerInputDriver()
        let mainWindow = try await waitForWindow(
            identifier: NoonmarkMainWindowState.identifier,
            visible: true
        )
        mainWindow.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not become active") {
            mainWindow.isKeyWindow && NSApp.isActive
        }

        try verifyNoonmarkShortcutCatalog()
        try await customizeShortcut(
            toKeyCode: 40,
            expectedTitle: "⌃⇧K",
            input: input
        )

        try input.postKey(keyCode: 13, modifiers: [.command])
        try await waitUntil("Command-W did not close the main window") {
            mainWindow.isVisible == false
                && NSApp.windows.contains(where: {
                    $0.identifier
                        == NoonmarkQuickEntryWindowController.windowIdentifier
                        && $0.isVisible
                }) == false
        }

        let finder = try finderApplication()
        guard finder.activate(options: []) else {
            throw Failure.failed("Finder rejected foreground activation")
        }
        try await waitUntil("Finder did not become the foreground app") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == finder.processIdentifier
        }

        try input.postKey(
            keyCode: 45,
            modifiers: [.control, .shift]
        )
        try await Task.sleep(for: .milliseconds(400))
        guard NSApp.windows.contains(where: {
            $0.identifier
                == NoonmarkQuickEntryWindowController.windowIdentifier
                && $0.isVisible
        }) == false else {
            throw Failure.failed(
                "replaced default shortcut remained registered"
            )
        }

        try input.postKey(
            keyCode: 40,
            modifiers: [.control, .shift]
        )
        let panel = try await waitForWindow(
            identifier: NoonmarkQuickEntryWindowController.windowIdentifier,
            visible: true
        )
        guard panel is NSPanel,
              panel.isKeyWindow,
              mainWindow.isVisible == false
        else {
            throw Failure.failed(
                "global shortcut did not open only the Quick Entry panel"
            )
        }

        let editor = try await waitForEditor(in: panel)
        try input.typeUnicode(Self.fixtureTitle)
        try await waitUntil("Quick Entry did not receive real text input") {
            editor.string == Self.fixtureTitle
        }

        try input.postKey(
            keyCode: 40,
            modifiers: [.control, .shift]
        )
        try await waitUntil("repeated hotkey lost the in-progress draft") {
            panel.isVisible
                && panel.isKeyWindow
                && editor.string == Self.fixtureTitle
        }

        try input.postKey(keyCode: 36)
        try await waitUntil("Return did not submit the global Quick Entry") {
            panel.isVisible == false
                && mainWindow.isVisible == false
                && taskCount(titled: Self.fixtureTitle, in: store) == 1
        }
        try await waitUntil("Quick Entry did not restore Finder focus") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == finder.processIdentifier
        }
    }

    private func verifyNoonmarkShortcutCatalog() throws {
        let expected: Set<GlobalQuickEntryShortcut> = [
            GlobalQuickEntryShortcut(
                key: .h,
                modifiers: [.command, .option]
            ),
            GlobalQuickEntryShortcut(
                key: .i,
                modifiers: [.command, .shift]
            ),
            GlobalQuickEntryShortcut(
                key: .z,
                modifiers: [.command, .shift]
            ),
            GlobalQuickEntryShortcut(
                key: .g,
                modifiers: [.command, .shift]
            ),
            GlobalQuickEntryShortcut(
                key: .f,
                modifiers: [.command, .shift]
            ),
            GlobalQuickEntryShortcut(
                key: .s,
                modifiers: [.command, .control]
            ),
            GlobalQuickEntryShortcut(
                key: .i,
                modifiers: [.command, .option]
            ),
            GlobalQuickEntryShortcut(
                key: .f,
                modifiers: [.command, .control]
            )
        ]
        let actual = NoonmarkMainMenuFactory
            .globalQuickEntryReservedShortcuts(in: NSApp.mainMenu)
        guard expected.isSubset(of: actual) else {
            let missing = expected.subtracting(actual)
                .map(\.displayText)
                .sorted()
                .joined(separator: ",")
            throw Failure.failed(
                "Noonmark shortcut conflict catalog missed \(missing)"
            )
        }
    }

    private func customizeShortcut(
        toKeyCode keyCode: UInt16,
        expectedTitle: String,
        input: WindowServerInputDriver
    ) async throws {
        try input.postKey(keyCode: 43, modifiers: [.command])
        let settingsWindow = try await waitForWindow(
            identifier: NoonmarkSettingsWindowController.windowIdentifier,
            visible: true
        )
        try await waitUntil("Settings did not become active") {
            settingsWindow.isKeyWindow && NSApp.isActive
        }
        let identifier =
            "settings.preferences.global-shortcut.recorder"
        let resolveTarget = {
            () throws -> WindowServerInputDriver.PointerCoordinate in
            guard let view = AppViewTreeE2E.view(
                identifier: identifier,
                in: settingsWindow
            ), let window = view.window,
                window === settingsWindow
            else {
                throw Failure.failed("global shortcut recorder was missing")
            }
            let point = view.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                to: nil
            )
            return try input.pointerCoordinate(
                windowPoint: point,
                in: settingsWindow
            )
        }
        let coordinate = try resolveTarget()
        try await input.postClick(
            at: coordinate,
            modifiers: [],
            resolveTarget: resolveTarget
        )
        try await waitUntil("shortcut recorder did not accept focus") {
            settingsWindow.firstResponder is NSButton
        }
        try input.postKey(
            keyCode: CGKeyCode(keyCode),
            modifiers: [.control, .shift]
        )
        try await waitUntil("shortcut recorder did not save \(expectedTitle)") {
            guard let button = AppViewTreeE2E.view(
                identifier: identifier,
                in: settingsWindow
            ) as? NSButton else {
                return false
            }
            return button.title == expectedTitle
        }

        try input.postKey(keyCode: 13, modifiers: [.command])
        try await waitUntil("Command-W did not close Settings") {
            settingsWindow.isVisible == false
        }
    }

    private func finderApplication() throws -> NSRunningApplication {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            throw Failure.failed("Finder was not running")
        }
        return finder
    }

    private func waitForWindow(
        identifier: NSUserInterfaceItemIdentifier,
        visible: Bool
    ) async throws -> NSWindow {
        var matchedWindow: NSWindow?
        try await waitUntil("window did not reach visibility=\(visible)") {
            matchedWindow = NSApp.windows.first {
                $0.identifier == identifier && $0.isVisible == visible
            }
            return matchedWindow != nil
        }
        guard let matchedWindow else {
            throw Failure.failed("window disappeared after becoming ready")
        }
        return matchedWindow
    }

    private func waitForEditor(in panel: NSWindow) async throws -> NSTextView {
        var editor: NSTextView?
        try await waitUntil("Quick Entry editor did not become first responder") {
            editor = panel.firstResponder as? NSTextView
            return editor != nil
        }
        guard let editor else {
            throw Failure.failed("Quick Entry editor disappeared")
        }
        return editor
    }

    private func taskCount(
        titled title: String,
        in store: NoonmarkStore
    ) -> Int {
        store.engine.traces.values.filter { trace in
            trace.formsDayHistory
                && store.engine.definitions[trace.definitionID]?.title == title
        }.count
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ value: String) throws {
        try Data((value + "\n").utf8).write(
            to: resultURL,
            options: .atomic
        )
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
}

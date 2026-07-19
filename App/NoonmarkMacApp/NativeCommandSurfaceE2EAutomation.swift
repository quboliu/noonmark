import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

/// Exercises Noonmark's native command surface inside the real application.
///
/// Commands and text entry are posted through WindowServer. The driver never
/// invokes a controller action or mutates the store directly.
@MainActor
struct NativeCommandSurfaceE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case helpShortcut
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let taskTitle: String
        let chainID: String
        let traceID: String
        let date: String
    }

    private struct MenuShortcut {
        let action: Selector
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let menuKeyEquivalent: String
        let menuModifiers: NSEvent.ModifierFlags

        init(
            action: Selector,
            key: String,
            modifiers: NSEvent.ModifierFlags,
            menuKeyEquivalent: String? = nil,
            menuModifiers: NSEvent.ModifierFlags? = nil
        ) {
            self.action = action
            self.key = key
            self.modifiers = modifiers
            self.menuKeyEquivalent = menuKeyEquivalent ?? key
            self.menuModifiers = menuModifiers ?? modifiers
        }
    }

    private struct Keystroke {
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags

        var report: String {
            "keyCode=\(keyCode),characters=\(characters.debugDescription),"
                + "charactersIgnoringModifiers="
                + "\(charactersIgnoringModifiers.debugDescription),"
                + "modifiers=\(modifiers.rawValue)"
        }
    }

    @MainActor
    private final class KeyboardEventProbe {
        private(set) var stroke: Keystroke?
        private var monitor: Any?

        init(keyCode: UInt16) {
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard event.keyCode == keyCode else { return event }
                MainActor.assumeIsolated {
                    self?.stroke = Keystroke(
                        characters: event.characters ?? "",
                        charactersIgnoringModifiers:
                        event.charactersIgnoringModifiers ?? "",
                        keyCode: event.keyCode,
                        modifiers: event.modifierFlags.intersection(
                            .deviceIndependentFlagsMask
                        )
                    )
                }
                return event
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    @MainActor
    private final class MenuTrackingProbe: NSObject, NSMenuDelegate, @unchecked Sendable {
        private(set) var openCount = 0
        private(set) var closeCount = 0
        private(set) var beginTrackingCount = 0
        private(set) var sentActionCount = 0
        private var observers: [NSObjectProtocol] = []

        init(menu: NSMenu, trackingRootMenu: NSMenu) {
            super.init()
            let notificationCenter = NotificationCenter.default
            observers.append(
                notificationCenter.addObserver(
                    forName: NSMenu.didBeginTrackingNotification,
                    object: trackingRootMenu,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.beginTrackingCount += 1
                    }
                }
            )
            let actionMenus = menu === trackingRootMenu
                ? [menu]
                : [menu, trackingRootMenu]
            for actionMenu in actionMenus {
                observers.append(
                    notificationCenter.addObserver(
                        forName: NSMenu.didSendActionNotification,
                        object: actionMenu,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.sentActionCount += 1
                        }
                    }
                )
            }
        }

        func menuWillOpen(_ menu: NSMenu) {
            openCount += 1
        }

        func menuDidClose(_ menu: NSMenu) {
            closeCount += 1
        }

        func stop() {
            let notificationCenter = NotificationCenter.default
            for observer in observers {
                notificationCenter.removeObserver(observer)
            }
            observers.removeAll()
        }
    }

    fileprivate enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private static let fixtureTitle = "commandrecoverytask"

    private let mode: Mode
    private let stateURL: URL
    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        let mode: Mode
        if AppLaunchArguments.contains(
            "--e2e-native-command-help-shortcut"
        ) {
            mode = .helpShortcut
        } else if AppLaunchArguments.contains("--e2e-native-command-surface-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains(
            "--e2e-native-command-surface-verify"
        ) {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let statePath = AppLaunchArguments.value(
            after: "--e2e-native-command-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-native-command-result-url"
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
                case .helpShortcut:
                    try await verifyHelpShortcut(on: store)
                case .exercise:
                    try await exercise(on: store)
                case .verifyRestart:
                    try await verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeWindowDump()
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let mainWindow = try await visibleMainWindow()
        let input = try WindowServerInputDriver()
        try assertMenuContract(copy: store.copy)
        guard taskRecord(titled: Self.fixtureTitle, in: store) == nil else {
            throw Failure.failed("isolated command database already contained the fixture")
        }

        try await exerciseSettingsShortcut(
            mainWindow: mainWindow,
            copy: store.copy,
            input: input
        )
        try await exerciseHelpWindow(
            mainWindow: mainWindow,
            copy: store.copy,
            input: input
        )
        try await exerciseQuickEntry(
            mainWindow: mainWindow,
            store: store,
            input: input
        )

        let created = try requireTaskRecord(titled: Self.fixtureTitle, in: store)
        guard created.trace.date == store.today,
              created.trace.status == .pending,
              store.canUndoDomainAction,
              store.canRedoDomainAction == false
        else {
            throw Failure.failed("Quick Entry did not create one undoable task for today")
        }

        try await exerciseAuxiliaryWindowCommandIsolation(
            mainWindow: mainWindow,
            store: store,
            input: input
        )

        try await exerciseMenuUndoRedo(
            mainWindow: mainWindow,
            store: store,
            input: input
        )
        let restored = try requireTaskRecord(titled: Self.fixtureTitle, in: store)
        guard restored.trace.id == created.trace.id,
              restored.trace.chainID == created.trace.chainID
        else {
            throw Failure.failed("menu Redo did not restore the original task identity")
        }

        try await exerciseSearch(
            mainWindow: mainWindow,
            store: store,
            expectedTraceID: restored.trace.id,
            input: input
        )

        try writeState(
            ProbeState(
                taskTitle: Self.fixtureTitle,
                chainID: restored.trace.chainID.description,
                traceID: restored.trace.id.description,
                date: restored.trace.date.description
            )
        )
    }

    private func verifyRestart(on store: NoonmarkStore) async throws {
        let expected = try readState()
        let mainWindow = try await visibleMainWindow()
        let input = try WindowServerInputDriver()
        try assertMenuContract(copy: store.copy)

        let restored = try requireTaskRecord(titled: expected.taskTitle, in: store)
        guard restored.trace.chainID.description == expected.chainID,
              restored.trace.id.description == expected.traceID,
              restored.trace.date.description == expected.date,
              restored.trace.status == .pending
        else {
            throw Failure.failed("redone Quick Entry task identity did not survive restart")
        }
        guard store.canUndoDomainAction == false,
              store.canRedoDomainAction == false
        else {
            throw Failure.failed("session-only Undo/Redo history leaked across restart")
        }

        try await exerciseSearch(
            mainWindow: mainWindow,
            store: store,
            expectedTraceID: restored.trace.id,
            input: input
        )
    }

    private func exerciseSettingsShortcut(
        mainWindow: NSWindow,
        copy: AppCopy,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showSettings,
                key: ",",
                modifiers: .command
            ),
            input: input
        )

        let settingsWindow = try await visibleWindow(
            identifier: NoonmarkSettingsWindowController.windowIdentifier,
            failure: "Settings shortcut did not open its native window"
        )
        let parentIdentifier = settingsWindow.parent?.identifier?.rawValue ?? "nil"
        guard settingsWindow !== mainWindow,
              settingsWindow is NSPanel == false,
              settingsWindow.parent == nil,
              settingsWindow.isKeyWindow,
              settingsWindow.title == copy.navSettings,
              settingsWindow.frameAutosaveName
              == NoonmarkSettingsWindowController.frameAutosaveName,
              settingsWindow.styleMask.contains([.titled, .closable, .resizable])
        else {
            throw Failure.failed(
                "Settings was not presented as a standalone native window: "
                    + "panel=\(settingsWindow is NSPanel), "
                    + "parent=\(parentIdentifier), "
                    + "key=\(settingsWindow.isKeyWindow), "
                    + "title=\(settingsWindow.title), "
                    + "autosave=\(settingsWindow.frameAutosaveName), "
                    + "style=\(settingsWindow.styleMask.rawValue)"
            )
        }
        try await assertMinimumContentSize(
            of: settingsWindow,
            equals: NoonmarkSettingsWindowController.minimumContentSize,
            label: "Settings"
        )
        try await assertAnchor(
            "settings.window",
            verificationText: copy.navSettings,
            in: settingsWindow
        )

        try performMenuShortcut(
            MenuShortcut(
                action: #selector(NSWindow.performClose(_:)),
                key: "w",
                modifiers: .command
            ),
            input: input
        )
        try await waitUntil("Close Window did not close Settings") {
            settingsWindow.isVisible == false && mainWindow.isVisible
        }
    }

    private func verifyHelpShortcut(on store: NoonmarkStore) async throws {
        let mainWindow = try await visibleMainWindow()
        let input = try WindowServerInputDriver()
        try assertMenuContract(copy: store.copy)
        try await activate(mainWindow)
        let helpMenu = try NSApp.helpMenu.unwrapped(
            "native Help menu was missing before its standard shortcut"
        )
        let originalHelpMenuDelegate = helpMenu.delegate
        let trackingProbe = MenuTrackingProbe(
            menu: helpMenu,
            trackingRootMenu: try NSApp.mainMenu.unwrapped(
                "application main menu was missing before its Help shortcut"
            )
        )
        helpMenu.delegate = trackingProbe
        let keyboardProbe = KeyboardEventProbe(keyCode: 44)
        defer {
            keyboardProbe.stop()
            trackingProbe.stop()
            helpMenu.delegate = originalHelpMenuDelegate
        }

        try input.postKey(keyCode: 44, modifiers: [.command, .shift])
        try await waitUntil("physical Command-Question mark did not reach the App") {
            keyboardProbe.stroke != nil
        }
        do {
            try await waitUntil(
                "Command-Question mark did not open the native Help menu"
            ) {
                trackingProbe.openCount >= 1
            }
        } catch {
            throw Failure.failed(
                "Command-Question mark reached the App but did not open its "
                    + "native Help menu: "
                    + (keyboardProbe.stroke?.report ?? "missing event")
            )
        }
        if trackingProbe.openCount > trackingProbe.closeCount {
            try input.postKey(keyCode: 53)
        }
        try await waitUntil("standard Help shortcut menu did not finish tracking") {
            trackingProbe.openCount == trackingProbe.closeCount
        }
    }

    private func exerciseHelpWindow(
        mainWindow: NSWindow,
        copy: AppCopy,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        let helpMenu = try NSApp.helpMenu.unwrapped(
            "native Help menu was missing before its standard shortcut"
        )
        let originalHelpMenuDelegate = helpMenu.delegate
        let trackingProbe = MenuTrackingProbe(
            menu: helpMenu,
            trackingRootMenu: try NSApp.mainMenu.unwrapped(
                "application main menu was missing before Help menu selection"
            )
        )
        helpMenu.delegate = trackingProbe
        defer {
            trackingProbe.stop()
            helpMenu.delegate = originalHelpMenuDelegate
        }

        var helpMenuBarTarget = ReadOnlyAccessibilityTarget.uniqueMenuBarItem(
            title: copy.helpMenu
        )
        try await waitUntil("Help menu bar item lacked stable accessibility geometry") {
            helpMenuBarTarget = ReadOnlyAccessibilityTarget.uniqueMenuBarItem(
                title: copy.helpMenu
            )
            return helpMenuBarTarget?.frame != nil
        }
        guard let helpMenuBarFrame = helpMenuBarTarget?.frame else {
            throw Failure.failed("Help menu bar accessibility geometry disappeared")
        }
        let helpMenuBarPoint = CGPoint(
            x: helpMenuBarFrame.midX,
            y: helpMenuBarFrame.midY
        )
        let helpItem = try menuItem(action: NoonmarkMenuAction.showHelp)
        guard helpMenu.items.first(where: {
            $0.isSeparatorItem == false && $0.isEnabled
        }) === helpItem else {
            throw Failure.failed(
                "native Help command was not the first keyboard-selectable item"
            )
        }
        let keyboardSelection = try input.prepareMenuKeyboardSelection()
        let menuBarGesture = try await input.prepareMenuBarGesture(
            at: helpMenuBarPoint,
            resolveSource: {
                guard let frame = ReadOnlyAccessibilityTarget.uniqueMenuBarItem(
                    title: copy.helpMenu
                )?.frame else {
                    return nil
                }
                return CGPoint(x: frame.midX, y: frame.midY)
            }
        )
        let openCountBeforeSelection = trackingProbe.openCount
        do {
            input.postMenuBarKeyboardSelection(
                menuBarGesture,
                selection: keyboardSelection
            )
            try await waitUntil("physical Help menu selection did not finish tracking") {
                trackingProbe.openCount > openCountBeforeSelection
                    && trackingProbe.beginTrackingCount == 1
                    && trackingProbe.sentActionCount == 1
                    && trackingProbe.openCount == trackingProbe.closeCount
            }
            try await input.waitForMenuBarMouseUp()
        } catch {
            if input.isLeftButtonDown {
                input.postMenuBarMouseUp(menuBarGesture)
                try? await input.waitForMenuBarMouseUp()
            }
            throw Failure.failed(
                "physical Help menu keyboard selection did not select its item: "
                    + "before=\(openCountBeforeSelection),"
                    + "opens=\(trackingProbe.openCount),"
                    + "closes=\(trackingProbe.closeCount),"
                    + "trackingBegins=\(trackingProbe.beginTrackingCount),"
                    + "sentActions=\(trackingProbe.sentActionCount),"
                    + "point=\(helpMenuBarPoint),"
                    + "pointer=\(String(describing: input.currentPointerLocation)),"
                    + "underlying=\(error.localizedDescription)"
            )
        }

        let helpWindow = try await visibleWindow(
            identifier: NoonmarkHelpWindowController.windowIdentifier,
            failure: "physical Help menu selection did not open its native window: "
                + "opens=\(trackingProbe.openCount),"
                + "closes=\(trackingProbe.closeCount),"
                + "trackingBegins=\(trackingProbe.beginTrackingCount),"
                + "sentActions=\(trackingProbe.sentActionCount)"
        )
        guard helpWindow !== mainWindow,
              helpWindow is NSPanel == false,
              helpWindow.parent == nil,
              helpWindow.isKeyWindow,
              helpWindow.title == copy.noonmarkHelp,
              helpWindow.frameAutosaveName
              == NoonmarkHelpWindowController.frameAutosaveName,
              helpWindow.styleMask.contains([.titled, .closable, .resizable])
        else {
            throw Failure.failed("Help was not presented as a standalone native window")
        }
        try await assertMinimumContentSize(
            of: helpWindow,
            equals: NoonmarkHelpWindowController.minimumContentSize,
            label: "Help"
        )
        try await assertAnchor(
            "help.window",
            verificationText: copy.noonmarkHelp,
            in: helpWindow
        )

        try performMenuShortcut(
            MenuShortcut(
                action: #selector(NSWindow.performClose(_:)),
                key: "w",
                modifiers: .command
            ),
            input: input
        )
        try await waitUntil("Close Window did not close Help") {
            helpWindow.isVisible == false && mainWindow.isVisible
        }
    }

    private func exerciseQuickEntry(
        mainWindow: NSWindow,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showQuickEntry,
                key: "n",
                modifiers: .command
            ),
            input: input
        )

        let quickEntryWindow = try await visibleWindow(
            identifier: NoonmarkQuickEntryWindowController.windowIdentifier,
            failure: "Quick Entry shortcut did not open its native panel"
        )
        guard let panel = quickEntryWindow as? NSPanel,
              panel !== mainWindow,
              panel.parent == nil,
              panel.isKeyWindow,
              panel.isFloatingPanel,
              panel.styleMask.contains([.titled, .closable, .utilityWindow])
        else {
            throw Failure.failed("Quick Entry was not presented as a standalone utility panel")
        }
        try await assertAnchor(
            "quick-entry.window",
            verificationText: store.copy.quickEntryTitle,
            in: panel
        )

        let editor = try await focusedTextEditor(
            identifier: "quick-entry.field",
            in: panel,
            input: input
        )
        guard editor.string.isEmpty else {
            throw Failure.failed("Quick Entry did not start with an empty editor")
        }
        try await typeASCII(Self.fixtureTitle, into: editor)
        do {
            try await waitUntil("Quick Entry did not receive real keyboard input") {
                editor.string == Self.fixtureTitle
                    && self.hasEnabledButton(
                        identifier: "quick-entry.add",
                        in: panel
                    )
            }
        } catch {
            throw Failure.failed(
                "Quick Entry did not receive real keyboard input: "
                    + "editor=\(editor.string), "
                    + "responder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), "
                    + "addEnabled=\(hasEnabledButton(identifier: "quick-entry.add", in: panel))"
            )
        }
        try sendKeyDown(
            Keystroke(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: 36,
                modifiers: []
            ),
            to: panel,
            requiring: editor
        )
        try await waitUntil("Quick Entry Return did not create and dismiss") {
            panel.isVisible == false
                && taskRecord(titled: Self.fixtureTitle, in: store) != nil
        }
    }

    private func exerciseMenuUndoRedo(
        mainWindow: NSWindow,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        mainWindow.makeFirstResponder(nil)

        let undoItem = try menuItem(action: NoonmarkMenuAction.undo)
        guard validate(undoItem),
              undoItem.title == store.copy.undoNamed(store.copy.addTaskAction)
        else {
            throw Failure.failed("Undo menu validation did not expose the named task action")
        }
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.undo,
                key: "z",
                modifiers: .command
            ),
            input: input
        )
        try await waitUntil("Command-Z did not undo the Quick Entry task") {
            taskRecord(titled: Self.fixtureTitle, in: store) == nil
                && store.canRedoDomainAction
        }

        let redoItem = try menuItem(action: NoonmarkMenuAction.redo)
        guard validate(redoItem),
              redoItem.title == store.copy.redoNamed(store.copy.addTaskAction)
        else {
            throw Failure.failed("Redo menu validation did not expose the named task action")
        }
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.redo,
                key: "z",
                modifiers: [.command, .shift],
                menuKeyEquivalent: "Z",
                menuModifiers: .command
            ),
            input: input
        )
        try await waitUntil("Shift-Command-Z did not redo the Quick Entry task") {
            taskRecord(titled: Self.fixtureTitle, in: store) != nil
                && store.canUndoDomainAction
                && store.canRedoDomainAction == false
        }
    }

    private func exerciseAuxiliaryWindowCommandIsolation(
        mainWindow: NSWindow,
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        let backgroundEditor = try await focusedTextEditor(
            identifier: "quick-add.day.input",
            in: mainWindow,
            input: input
        )
        if backgroundEditor.string.isEmpty == false {
            try replaceEditorContents(with: "", in: backgroundEditor)
        }
        let expectedDraft = "backgrounddraft"
        try await typeASCII(expectedDraft, into: backgroundEditor)
        let expectedSelection = NSRange(location: 0, length: 0)
        backgroundEditor.setSelectedRange(expectedSelection)
        let expectedTraceID = try requireTaskRecord(
            titled: Self.fixtureTitle,
            in: store
        ).trace.id

        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showSettings,
                key: ",",
                modifiers: .command
            ),
            input: input
        )
        let settingsWindow = try await visibleWindow(
            identifier: NoonmarkSettingsWindowController.windowIdentifier,
            failure: "Settings did not open for command-isolation verification"
        )
        guard settingsWindow.firstResponder is NSTextView == false else {
            throw Failure.failed(
                "Settings unexpectedly focused text during command-isolation verification"
            )
        }

        let isolatedItems = try [
            menuItem(action: NoonmarkMenuAction.undo),
            menuItem(action: NoonmarkMenuAction.redo),
            menuItem(action: NoonmarkMenuAction.selectAll)
        ]
        guard isolatedItems.allSatisfy({ validate($0) == false }) else {
            throw Failure.failed(
                "Edit commands remained enabled through a background main-window text responder"
            )
        }

        try input.postKey(keyCode: 0, modifiers: .command)
        try input.postKey(keyCode: 6, modifiers: .command)
        try performMenuShortcut(
            MenuShortcut(
                action: #selector(NSWindow.performClose(_:)),
                key: "w",
                modifiers: .command
            ),
            input: input
        )
        try await waitUntil("Close Window did not close command-isolation Settings") {
            settingsWindow.isVisible == false && mainWindow.isVisible
        }
        guard backgroundEditor.string == expectedDraft,
              backgroundEditor.selectedRange() == expectedSelection,
              taskRecord(titled: Self.fixtureTitle, in: store)?.trace.id == expectedTraceID,
              store.canUndoDomainAction,
              store.canRedoDomainAction == false
        else {
            throw Failure.failed(
                "auxiliary Edit commands mutated background text or domain history"
            )
        }

        try await activate(mainWindow)
        guard mainWindow.makeFirstResponder(backgroundEditor) else {
            throw Failure.failed("main quick-add editor could not regain focus after Settings")
        }
        try replaceEditorContents(with: "", in: backgroundEditor)
        mainWindow.makeFirstResponder(nil)
    }

    private func exerciseSearch(
        mainWindow: NSWindow,
        store: NoonmarkStore,
        expectedTraceID: DayTraceID,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        mainWindow.makeFirstResponder(nil)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showSearch,
                key: "f",
                modifiers: [.command, .shift]
            ),
            input: input
        )

        let searchWindow = try await visibleWindow(
            identifier: NoonmarkSearchWindowController.windowIdentifier,
            failure: "Search shortcut did not open its native window"
        )
        guard searchWindow !== mainWindow,
              searchWindow is NSPanel == false,
              searchWindow.parent == nil,
              searchWindow.isKeyWindow,
              searchWindow.frameAutosaveName
              == NoonmarkSearchWindowController.frameAutosaveName,
              searchWindow.styleMask.contains([.titled, .closable, .resizable])
        else {
            throw Failure.failed("Search was not presented as a standalone native window")
        }
        try await assertMinimumContentSize(
            of: searchWindow,
            equals: NoonmarkSearchWindowController.minimumContentSize,
            label: "Search"
        )
        try await assertAnchor(
            "search.window",
            verificationText: store.copy.searchCommand,
            in: searchWindow
        )

        let editor = try await focusedTextEditor(
            identifier: "search.field",
            in: searchWindow,
            input: input
        )
        if editor.string.isEmpty == false {
            try replaceEditorContents(with: "", in: editor)
        }
        try await typeASCII(Self.fixtureTitle, into: editor)
        try await waitUntil("Search did not render the persisted Quick Entry result") {
            let indexed = WorkspaceSearchIndex(engine: store.engine).search(
                Self.fixtureTitle
            )
            return editor.string == Self.fixtureTitle
                && indexed.count == 1
                && indexed.first?.title == Self.fixtureTitle
                && self.hasVisibleView(identifier: "search.results", in: searchWindow)
        }

        try sendKeyDown(
            Keystroke(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: 36,
                modifiers: []
            ),
            to: searchWindow,
            requiring: editor
        )
        try await waitUntil("Search Return did not reveal the matching task") {
            searchWindow.isVisible == false
                && store.page == .day
                && store.selectedTraceID == expectedTraceID
                && store.selectedDefinition?.title == Self.fixtureTitle
                && mainWindow.isVisible
        }
    }

    private func assertMinimumContentSize(
        of window: NSWindow,
        equals expected: NSSize,
        label: String
    ) async throws {
        let expectedFrameMinimum = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: expected)
        ).size
        do {
            try await waitUntil(
                "\(label) did not publish its declared minimum after layout"
            ) {
                window.contentView?.layoutSubtreeIfNeeded()
                return window.contentMinSize == expected
                    && window.minSize == expectedFrameMinimum
            }
        } catch {
            throw Failure.failed(
                "\(label) minimum size contract was not preserved after layout: "
                    + "content=\(window.contentMinSize), expectedContent=\(expected), "
                    + "frame=\(window.minSize), expectedFrame=\(expectedFrameMinimum)"
            )
        }

        let originalFrame = window.frame
        window.setContentSize(NSSize(width: 100, height: 100))
        try await waitUntil(
            "\(label) could be resized below its declared content minimum"
        ) {
            window.contentView?.layoutSubtreeIfNeeded()
            let actualContentSize = window.contentRect(
                forFrameRect: window.frame
            ).size
            return actualContentSize.width >= expected.width
                && actualContentSize.height >= expected.height
                && window.contentMinSize == expected
                && window.minSize == expectedFrameMinimum
        }
        window.setFrame(originalFrame, display: false)
    }

    private func assertMenuContract(copy: AppCopy) throws {
        try assertCommercialCopyContract()

        guard let mainMenu = NSApp.mainMenu else {
            throw Failure.failed("application main menu was missing")
        }
        let expectedTopLevelTitles = [
            copy.appName,
            copy.fileMenu,
            copy.editMenu,
            copy.viewMenu,
            copy.windowMenu,
            copy.helpMenu
        ]
        guard mainMenu.items.map(\.title) == expectedTopLevelTitles else {
            throw Failure.failed(
                "top-level menu order was nonstandard: \(mainMenu.items.map(\.title))"
            )
        }

        try assertActions(
            [
                NoonmarkMenuAction.showAbout,
                NoonmarkMenuAction.showSettings,
                #selector(NSApplication.hide(_:)),
                #selector(NSApplication.hideOtherApplications(_:)),
                #selector(NSApplication.unhideAllApplications(_:)),
                #selector(NSApplication.terminate(_:))
            ],
            in: copy.appName
        )
        try assertActions(
            [
                NoonmarkMenuAction.showQuickEntry,
                NoonmarkMenuAction.exportData,
                NoonmarkMenuAction.importData,
                #selector(NSWindow.performClose(_:))
            ],
            in: copy.fileMenu
        )
        try assertActions(
            [
                NoonmarkMenuAction.undo,
                NoonmarkMenuAction.redo,
                #selector(NSText.cut(_:)),
                #selector(NSText.copy(_:)),
                #selector(NSText.paste(_:)),
                #selector(NSText.delete(_:)),
                NoonmarkMenuAction.selectAll,
                NoonmarkMenuAction.showSearch
            ],
            in: copy.editMenu
        )
        try assertActions(
            [NoonmarkMenuAction.toggleSidebar, NoonmarkMenuAction.toggleDetailRail],
            in: copy.viewMenu
        )
        try assertActions(
            [
                #selector(NSWindow.performMiniaturize(_:)),
                #selector(NSWindow.performZoom(_:)),
                #selector(NSWindow.toggleFullScreen(_:)),
                NoonmarkMenuAction.showMainWindow,
                #selector(NSApplication.arrangeInFront(_:))
            ],
            in: copy.windowMenu
        )
        try assertActions([NoonmarkMenuAction.showHelp], in: copy.helpMenu)

        let titledActions: [(Selector, String)] = [
            (NoonmarkMenuAction.showAbout, copy.aboutApp),
            (NoonmarkMenuAction.showSettings, copy.settingsCommand),
            (NoonmarkMenuAction.showQuickEntry, copy.quickEntryCommand),
            (NoonmarkMenuAction.exportData, copy.exportJSON),
            (NoonmarkMenuAction.importData, copy.importData),
            (#selector(NSWindow.performClose(_:)), copy.closeWindow),
            (NoonmarkMenuAction.undo, copy.undo),
            (NoonmarkMenuAction.redo, copy.redo),
            (NoonmarkMenuAction.selectAll, copy.selectAll),
            (NoonmarkMenuAction.showSearch, copy.searchCommand),
            (NoonmarkMenuAction.showMainWindow, copy.mainWindowCommand),
            (NoonmarkMenuAction.showHelp, copy.noonmarkHelp)
        ]
        for (action, expectedTitle) in titledActions {
            let item = try menuItem(action: action)
            guard item.title == expectedTitle else {
                throw Failure.failed(
                    "menu title mismatch action=\(NSStringFromSelector(action)) "
                        + "actual=\(item.title) expected=\(expectedTitle)"
                )
            }
        }

        let servicesItem = try submenu(titled: copy.appName).items.first {
            $0.title == copy.services
        }.unwrapped("Services menu item was missing")
        let registeredWindowsMenu = try submenu(titled: copy.windowMenu)
        let registeredHelpMenu = try submenu(titled: copy.helpMenu)
        guard let servicesMenu = servicesItem.submenu,
              NSApp.servicesMenu === servicesMenu,
              NSApp.windowsMenu === registeredWindowsMenu,
              NSApp.helpMenu === registeredHelpMenu
        else {
            throw Failure.failed("AppKit services/windows/help menu registration was incomplete")
        }

        try assertTextServiceSubmenus(copy: copy)

        let fullScreenShortcut = MenuShortcut(
            action: #selector(NSWindow.toggleFullScreen(_:)),
            key: "f",
            modifiers: [.command, .control]
        )
        let shortcuts = [
            MenuShortcut(action: NoonmarkMenuAction.showSettings, key: ",", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.showQuickEntry, key: "n", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.importData, key: "i", modifiers: [.command, .shift]),
            MenuShortcut(
                action: NoonmarkMenuAction.showSearch,
                key: "f",
                modifiers: [.command, .shift]
            ),
            MenuShortcut(action: NoonmarkMenuAction.selectAll, key: "a", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.undo, key: "z", modifiers: .command),
            MenuShortcut(
                action: NoonmarkMenuAction.redo,
                key: "z",
                modifiers: [.command, .shift],
                menuKeyEquivalent: "Z",
                menuModifiers: .command
            ),
            MenuShortcut(action: #selector(NSWindow.performClose(_:)), key: "w", modifiers: .command),
            fullScreenShortcut,
            MenuShortcut(action: NoonmarkMenuAction.toggleSidebar, key: "s", modifiers: [.command, .control]),
            MenuShortcut(action: NoonmarkMenuAction.toggleDetailRail, key: "i", modifiers: [.command, .option]),
            MenuShortcut(action: #selector(NSApplication.terminate(_:)), key: "q", modifiers: .command),
            MenuShortcut(action: #selector(NSWindow.performMiniaturize(_:)), key: "m", modifiers: .command)
        ]
        for shortcut in shortcuts {
            let item = try menuItem(shortcut: shortcut)
            guard item.keyEquivalent == shortcut.menuKeyEquivalent,
                  normalizedModifiers(item.keyEquivalentModifierMask)
                  == normalizedModifiers(shortcut.menuModifiers)
            else {
                throw Failure.failed(
                    "menu shortcut mismatch action=\(NSStringFromSelector(shortcut.action)) "
                        + "actual=\(item.keyEquivalent)/\(normalizedModifiers(item.keyEquivalentModifierMask).rawValue) "
                        + "expected=\(shortcut.menuKeyEquivalent)/\(normalizedModifiers(shortcut.menuModifiers).rawValue)"
                )
            }
        }
        try assertFullScreenMenuItems(
            copy: copy,
            standardShortcut: fullScreenShortcut
        )

        let helpItem = try menuItem(action: NoonmarkMenuAction.showHelp)
        guard helpItem.keyEquivalent.isEmpty,
              normalizedModifiers(helpItem.keyEquivalentModifierMask).isEmpty
        else {
            throw Failure.failed(
                "Help item duplicated AppKit's standard Command-Question mark "
                    + "Help-menu shortcut"
            )
        }
    }

    private func assertCommercialCopyContract() throws {
        let english = AppCopy(language: .english)
        let chinese = AppCopy(language: .chinese)
        let englishContract: [(String, String)] = [
            (english.emptyDay, "No tasks on this day."),
            (
                english.unfinishedSubtitle,
                "Each unfinished task appears once, grouped by task chain. "
                    + "Continue it or mark it abandoned."
            ),
            (english.emptyUnfinished, "No unfinished tasks."),
            (english.settingsPoemTitle, "Poem"),
            (english.settingsPoemDisplay, "Show poem in About Noonmark"),
            (english.organizationTitle, "Organisation")
        ]
        let chineseContract: [(String, String)] = [
            (chinese.settingsPoemTitle, "关于页诗文"),
            (chinese.settingsPoemDisplay, "在“关于晷迹”中展示诗文")
        ]
        guard (englishContract + chineseContract).allSatisfy({ $0.0 == $0.1 })
        else {
            throw Failure.failed("commercial bilingual copy contract diverged")
        }
    }

    private func assertTextServiceSubmenus(copy: AppCopy) throws {
        let editMenu = try submenu(titled: copy.editMenu)
        let findItem = try editMenu.items.first(where: { $0.title == copy.findMenu })
            .unwrapped("Find menu item was missing")
        let findMenu = try findItem.submenu.unwrapped("Find submenu was missing")
        let findItems = findMenu.items.filter { $0.isSeparatorItem == false }
        let expectedFindItems: [(String, NSTextFinder.Action, String, NSEvent.ModifierFlags)] = [
            (copy.find, .showFindInterface, "f", .command),
            (copy.findNext, .nextMatch, "g", .command),
            (copy.findPrevious, .previousMatch, "g", [.command, .shift])
        ]
        guard findItems.count == expectedFindItems.count else {
            throw Failure.failed("Find submenu item count was nonstandard")
        }
        for (item, expected) in zip(findItems, expectedFindItems) {
            guard item.title == expected.0,
                  item.action == #selector(NSTextView.performTextFinderAction(_:)),
                  item.target == nil,
                  item.tag == expected.1.rawValue,
                  item.keyEquivalent == expected.2,
                  normalizedModifiers(item.keyEquivalentModifierMask)
                  == normalizedModifiers(expected.3)
            else {
                throw Failure.failed("Find submenu did not use the responder-chain text finder")
            }
        }

        let spellingItem = try editMenu.items.first {
            $0.title == copy.spellingAndGrammar
        }.unwrapped("Spelling and Grammar menu item was missing")
        let spellingMenu = try spellingItem.submenu.unwrapped(
            "Spelling and Grammar submenu was missing"
        )
        let spellingItems = spellingMenu.items.filter { $0.isSeparatorItem == false }
        let expectedSpellingItems: [(String, Selector)] = [
            (copy.showSpellingAndGrammar, #selector(NSTextView.showGuessPanel(_:))),
            (copy.checkSpelling, #selector(NSTextView.checkSpelling(_:))),
            (
                copy.checkSpellingWhileTyping,
                #selector(NSTextView.toggleContinuousSpellChecking(_:))
            ),
            (copy.checkGrammarWithSpelling, #selector(NSTextView.toggleGrammarChecking(_:))),
            (
                copy.correctSpellingAutomatically,
                #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))
            )
        ]
        guard spellingItems.count == expectedSpellingItems.count else {
            throw Failure.failed("Spelling and Grammar submenu item count was nonstandard")
        }
        for (item, expected) in zip(spellingItems, expectedSpellingItems) {
            guard item.title == expected.0,
                  item.action == expected.1,
                  item.target == nil
            else {
                throw Failure.failed(
                    "Spelling and Grammar submenu bypassed the responder chain"
                )
            }
        }

        let fullScreenItem = try menuItem(
            shortcut: MenuShortcut(
                action: #selector(NSWindow.toggleFullScreen(_:)),
                key: "f",
                modifiers: [.command, .control]
            )
        )
        guard fullScreenItem.target == nil else {
            throw Failure.failed("Full Screen command bypassed the responder chain")
        }
    }

    private func assertActions(
        _ expected: [Selector],
        in menuTitle: String
    ) throws {
        let actual = try submenu(titled: menuTitle).items.compactMap(\.action)
        var searchStart = actual.startIndex
        for action in expected {
            guard let index = actual[searchStart...].firstIndex(of: action) else {
                throw Failure.failed(
                    "menu \(menuTitle) missing or reordered action "
                        + NSStringFromSelector(action)
                )
            }
            searchStart = actual.index(after: index)
        }
    }

    private func performMenuShortcut(
        _ shortcut: MenuShortcut,
        input: WindowServerInputDriver
    ) throws {
        let item = try menuItem(shortcut: shortcut)
        let keyMatches = item.keyEquivalent == shortcut.menuKeyEquivalent
        let modifiersMatch = normalizedModifiers(item.keyEquivalentModifierMask)
            == normalizedModifiers(shortcut.menuModifiers)
        let isValid = validate(item)
        guard keyMatches, modifiersMatch, isValid
        else {
            throw Failure.failed(
                "menu shortcut was unavailable: \(NSStringFromSelector(shortcut.action)) "
                    + "key=\(item.keyEquivalent) keyMatches=\(keyMatches) "
                    + "modifiers=\(normalizedModifiers(item.keyEquivalentModifierMask).rawValue) "
                    + "modifiersMatch=\(modifiersMatch) valid=\(isValid) title=\(item.title)"
            )
        }
        guard let keyCode = Self.keyCodes[Character(shortcut.key.lowercased())]
        else {
            throw Failure.failed(
                "menu shortcut has no physical key mapping: "
                    + NSStringFromSelector(shortcut.action)
            )
        }
        try input.postKey(keyCode: keyCode, modifiers: shortcut.modifiers)
    }

    private func menuItem(action: Selector) throws -> NSMenuItem {
        let matches = menuItems(action: action)
        guard
            matches.count == 1,
            let item = matches.first
        else {
            throw Failure.failed(
                "menu action was missing or duplicated: \(NSStringFromSelector(action))"
            )
        }
        return item
    }

    private func menuItem(shortcut: MenuShortcut) throws -> NSMenuItem {
        let matches = menuItems(action: shortcut.action).filter { item in
            item.keyEquivalent == shortcut.menuKeyEquivalent
                && normalizedModifiers(item.keyEquivalentModifierMask)
                == normalizedModifiers(shortcut.menuModifiers)
        }
        guard matches.count == 1, let item = matches.first else {
            throw Failure.failed(
                "menu shortcut was missing or duplicated: "
                    + "\(NSStringFromSelector(shortcut.action)) "
                    + "key=\(shortcut.menuKeyEquivalent) "
                    + "modifiers=\(normalizedModifiers(shortcut.menuModifiers).rawValue)"
            )
        }
        return item
    }

    private func menuItems(action: Selector) -> [NSMenuItem] {
        NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.action == action } ?? []
    }

    private func assertFullScreenMenuItems(
        copy: AppCopy,
        standardShortcut: MenuShortcut
    ) throws {
        let items = menuItems(action: standardShortcut.action)
        let shortcutIdentities = Set(items.map { item in
            "\(item.keyEquivalent)|"
                + "\(normalizedModifiers(item.keyEquivalentModifierMask).rawValue)"
        })
        guard items.isEmpty == false,
              items.allSatisfy({ item in
                  item.title == copy.enterFullScreen && item.target == nil
              }),
              shortcutIdentities.count == items.count
        else {
            throw Failure.failed(
                "Full Screen responder-chain commands contained a duplicate shortcut"
            )
        }
        let standardItem = try menuItem(shortcut: standardShortcut)
        guard standardItem.title == copy.enterFullScreen else {
            throw Failure.failed("Full Screen command title was not localized")
        }
    }

    private func submenu(titled title: String) throws -> NSMenu {
        guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu else {
            throw Failure.failed("menu was missing: \(title)")
        }
        return menu
    }

    private func validate(_ item: NSMenuItem) -> Bool {
        guard let validator = item.target as? NSMenuItemValidation else {
            return item.isEnabled
        }
        let enabled = validator.validateMenuItem(item)
        item.isEnabled = enabled
        return enabled
    }

    private func focusedTextEditor(
        identifier: String,
        in window: NSWindow,
        input: WindowServerInputDriver
    ) async throws -> NSTextView {
        var identifiedView: NSView?
        try await waitUntil("text field was missing: \(identifier)") {
            identifiedView = self.uniqueView(identifier: identifier, in: window)
            return identifiedView != nil
        }
        guard let identifiedView else {
            throw Failure.failed("text field disappeared: \(identifier)")
        }
        let clickTarget: NSView? = if identifiedView is NSTextView {
            identifiedView
        } else {
            ([identifiedView] + allViews(from: identifiedView)).first {
                $0 is NSTextField
            } ?? editableTextField(overlapping: identifiedView, in: window)
        }
        guard let clickTarget else {
            throw Failure.failed("editable text field was missing: \(identifier)")
        }
        try await click(
            clickTarget,
            identifier: identifier,
            input: input
        )

        var editor: NSTextView?
        try await waitUntil("text field did not become first responder: \(identifier)") {
            editor = window.firstResponder as? NSTextView
            return editor != nil
        }
        guard let editor else {
            throw Failure.failed("text field editor disappeared: \(identifier)")
        }
        return editor
    }

    private func editableTextField(
        overlapping anchor: NSView,
        in window: NSWindow
    ) -> NSTextField? {
        guard let root = window.contentView?.superview ?? window.contentView else {
            return nil
        }
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        let anchorArea = anchorFrame.width * anchorFrame.height
        guard anchorArea > 0 else { return nil }

        let matches = allViews(from: root).compactMap { view -> NSTextField? in
            guard let field = view as? NSTextField,
                  field.isEditable,
                  field.isEnabled,
                  field.isHiddenOrHasHiddenAncestor == false
            else {
                return nil
            }
            let fieldFrame = field.convert(field.bounds, to: nil)
            let intersection = anchorFrame.intersection(fieldFrame)
            let intersectionArea = intersection.width * intersection.height
            return intersectionArea >= anchorArea * 0.8 ? field : nil
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func typeASCII(_ text: String, into editor: NSTextView) async throws {
        guard let window = editor.window,
              window.firstResponder === editor,
              text.isEmpty == false
        else {
            throw Failure.failed("text editor was not ready for keyboard input")
        }
        for character in text {
            let stroke = try keystroke(for: character)
            guard let keyDown = keyEvent(type: .keyDown, stroke: stroke, window: window),
                  let keyUp = keyEvent(type: .keyUp, stroke: stroke, window: window)
            else {
                throw Failure.failed("could not construct text input events")
            }
            let expected = editor.string + String(character)
            NSApp.postEvent(keyDown, atStart: false)
            NSApp.postEvent(keyUp, atStart: false)
            try await waitUntil("queued text input was not delivered") {
                window.firstResponder === editor && editor.string == expected
            }
        }
    }

    private func replaceEditorContents(
        with value: String,
        in editor: NSTextView
    ) throws {
        guard value.isEmpty else {
            throw Failure.failed("E2E editor replacement only supports clearing")
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        try sendKeyDown(
            Keystroke(
                characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}",
                keyCode: 51,
                modifiers: []
            ),
            to: try editor.window.unwrapped("editor window was missing"),
            requiring: editor
        )
    }

    private func sendKeyDown(
        _ stroke: Keystroke,
        to window: NSWindow,
        requiring editor: NSTextView
    ) throws {
        guard window.firstResponder === editor,
              let event = keyEvent(type: .keyDown, stroke: stroke, window: window)
        else {
            throw Failure.failed("window rejected keyboard input because focus changed")
        }
        window.sendEvent(event)
    }

    private func keyEvent(
        type: NSEvent.EventType,
        stroke: Keystroke,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: stroke.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: stroke.characters,
            charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: stroke.keyCode
        )
    }

    private func keystroke(for character: Character) throws -> Keystroke {
        let rendered = String(character)
        guard character.isASCII,
              let keyCode = Self.keyCodes[Character(rendered.lowercased())]
        else {
            throw Failure.failed("fixture contained an unsupported keyboard character")
        }
        return Keystroke(
            characters: rendered,
            charactersIgnoringModifiers: rendered.lowercased(),
            keyCode: keyCode,
            modifiers: rendered == rendered.lowercased() ? [] : .shift
        )
    }

    private func click(
        _ view: NSView,
        identifier: String,
        input: WindowServerInputDriver
    ) async throws {
        guard let window = view.window,
              window.isVisible,
              window.isKeyWindow,
              NSApp.isActive,
              view.isHiddenOrHasHiddenAncestor == false,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            throw Failure.failed(
                "text field was not available for WindowServer click: \(identifier)"
            )
        }
        do {
            let resolveTarget = { () throws -> WindowServerInputDriver.PointerCoordinate in
                guard let currentView = AppViewTreeE2E.view(
                    identifier: identifier,
                    in: window
                ),
                      let currentWindow = currentView.window,
                currentWindow === window,
                currentWindow.isKeyWindow,
                currentView.isHiddenOrHasHiddenAncestor == false,
                currentView.bounds.width > 0,
                currentView.bounds.height > 0
                else {
                    throw Failure.failed(
                        "text field changed before WindowServer mouseDown: \(identifier)"
                    )
                }
                let currentPoint = currentView.convert(
                    NSPoint(
                        x: currentView.bounds.midX,
                        y: currentView.bounds.midY
                    ),
                    to: nil
                )
                return try input.pointerCoordinate(
                    windowPoint: currentPoint,
                    in: currentWindow
                )
            }
            let coordinate = try resolveTarget()
            try await input.postClick(
                at: coordinate,
                modifiers: [],
                resolveTarget: resolveTarget
            )
        } catch {
            throw Failure.failed(
                "WindowServer click failed for \(identifier): "
                    + error.localizedDescription
            )
        }
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil("main window did not become visible") {
            resolved = NSApp.windows.first {
                $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
            }
            return resolved != nil
        }
        return try resolved.unwrapped("main window disappeared")
    }

    private func visibleWindow(
        identifier: NSUserInterfaceItemIdentifier,
        failure: String
    ) async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil(failure) {
            let matches = NSApp.windows.filter {
                $0.identifier == identifier
                    && $0.isVisible
                    && $0.isMiniaturized == false
                    && $0.isKeyWindow
            }
            guard matches.count == 1 else { return false }
            resolved = matches[0]
            return true
        }
        return try resolved.unwrapped(failure)
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("window did not become key: \(window.identifier?.rawValue ?? "unknown")") {
            window.isKeyWindow && NSApp.isActive
        }
    }

    private func assertAnchor(
        _ identifier: String,
        verificationText: String,
        in window: NSWindow
    ) async throws {
        try await waitUntil("native window content anchor was missing: \(identifier)") {
            guard let anchor = self.uniqueView(
                identifier: identifier,
                in: window
            ) else {
                return false
            }
            return (anchor as? AppE2EAnchorView)?.verificationText
                == verificationText
        }
    }

    private func uniqueView(identifier: String, in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview ?? window.contentView else {
            return nil
        }
        let matches = allViews(from: root).filter {
            $0.identifier?.rawValue == identifier
                && $0.isHiddenOrHasHiddenAncestor == false
                && $0.bounds.width > 0
                && $0.bounds.height > 0
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func hasVisibleView(identifier: String, in window: NSWindow) -> Bool {
        uniqueView(identifier: identifier, in: window) != nil
    }

    private func hasEnabledButton(identifier: String, in window: NSWindow) -> Bool {
        guard let anchor = uniqueView(identifier: identifier, in: window),
              let root = window.contentView?.superview ?? window.contentView
        else {
            return false
        }
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        let anchorArea = anchorFrame.width * anchorFrame.height
        guard anchorArea > 0 else { return false }

        let matches = allViews(from: root).compactMap { view -> NSButton? in
            guard let button = view as? NSButton,
                  button.isEnabled,
                  button.isHiddenOrHasHiddenAncestor == false
            else {
                return nil
            }
            let buttonFrame = button.convert(button.bounds, to: nil)
            let intersection = anchorFrame.intersection(buttonFrame)
            let intersectionArea = intersection.width * intersection.height
            return intersectionArea >= anchorArea * 0.8 ? button : nil
        }
        return matches.count == 1
    }

    private func allViews(from root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []
        while let view = pending.popLast(), result.count < 5000 {
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    private func taskRecord(
        titled title: String,
        in store: NoonmarkStore
    ) -> (trace: DayTrace, definition: TaskDefinition)? {
        let matches: [(trace: DayTrace, definition: TaskDefinition)] = store
            .engine.traces.values.compactMap { trace in
            guard trace.formsDayHistory,
                  let definition = store.engine.definitions[trace.definitionID],
                  definition.title == title
            else {
                return nil
            }
            return (trace: trace, definition: definition)
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func requireTaskRecord(
        titled title: String,
        in store: NoonmarkStore
    ) throws -> (trace: DayTrace, definition: TaskDefinition) {
        guard let record = taskRecord(titled: title, in: store) else {
            throw Failure.failed("expected exactly one task titled \(title)")
        }
        return record
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

    private func normalizedModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers.intersection(.deviceIndependentFlagsMask)
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

    private func writeWindowDump() throws {
        var lines: [String] = []
        for window in NSApp.windows {
            lines.append(
                "window=\(window.windowNumber) id=\(window.identifier?.rawValue ?? "") "
                + "type=\(String(describing: type(of: window))) visible=\(window.isVisible) "
                + "main=\(window.isMainWindow) key=\(window.isKeyWindow) "
                + "title=\(window.title) frame=\(NSStringFromRect(window.frame)) "
                + "responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            )
            guard let root = window.contentView?.superview ?? window.contentView else {
                continue
            }
            for view in allViews(from: root) where view is NSControl {
                let text = (view as? NSTextField)?.stringValue ?? ""
                let label = view.accessibilityLabel() ?? ""
                let enabled = (view as? NSControl)?.isEnabled ?? true
                lines.append(
                    "  view=\(String(describing: type(of: view))) "
                        + "id=\(view.identifier?.rawValue ?? "") "
                        + "axid=\(view.accessibilityIdentifier()) "
                        + "label=\(label) enabled=\(enabled) "
                        + "text=\(text) "
                        + "frame=\(NSStringFromRect(view.convert(view.bounds, to: nil)))"
                )
            }
        }
        let dumpURL = resultURL
            .deletingPathExtension()
            .appendingPathExtension("windows.txt")
        try lines.joined(separator: "\n").write(
            to: dumpURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, ",": 43, "n": 45, "m": 46
    ]
}

private extension Optional {
    func unwrapped(_ failure: String) throws -> Wrapped {
        guard let self else {
            throw NativeCommandSurfaceE2EAutomation.Failure.failed(failure)
        }
        return self
    }
}

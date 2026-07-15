import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

/// Exercises Noonmark's native command surface inside the real application.
///
/// Commands are dispatched through `NSMenu.performKeyEquivalent(with:)`; text
/// is entered as window keyboard events. The driver never invokes a controller
/// action or mutates the store directly.
@MainActor
struct NativeCommandSurfaceE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
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
        if AppLaunchArguments.contains("--e2e-native-command-surface-exercise") {
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
        try assertMenuContract(copy: store.copy)
        guard taskRecord(titled: Self.fixtureTitle, in: store) == nil else {
            throw Failure.failed("isolated command database already contained the fixture")
        }

        try await exerciseSettingsShortcut(mainWindow: mainWindow, copy: store.copy)
        try await exerciseQuickEntry(mainWindow: mainWindow, store: store)

        let created = try requireTaskRecord(titled: Self.fixtureTitle, in: store)
        guard created.trace.date == store.today,
              created.trace.status == .pending,
              store.canUndoDomainAction,
              store.canRedoDomainAction == false
        else {
            throw Failure.failed("Quick Entry did not create one undoable task for today")
        }

        try await exerciseMenuUndoRedo(mainWindow: mainWindow, store: store)
        let restored = try requireTaskRecord(titled: Self.fixtureTitle, in: store)
        guard restored.trace.id == created.trace.id,
              restored.trace.chainID == created.trace.chainID
        else {
            throw Failure.failed("menu Redo did not restore the original task identity")
        }

        try await exerciseSearch(
            mainWindow: mainWindow,
            store: store,
            expectedTraceID: restored.trace.id
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
            expectedTraceID: restored.trace.id
        )
    }

    private func exerciseSettingsShortcut(
        mainWindow: NSWindow,
        copy: AppCopy
    ) async throws {
        try await activate(mainWindow)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showSettings,
                key: ",",
                modifiers: .command
            )
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
              settingsWindow.styleMask.contains([.titled, .closable, .resizable]),
              settingsWindow.contentMinSize.width >= 680,
              settingsWindow.contentMinSize.height >= 500
        else {
            throw Failure.failed(
                "Settings was not presented as a standalone native window: "
                    + "panel=\(settingsWindow is NSPanel), "
                    + "parent=\(parentIdentifier), "
                    + "key=\(settingsWindow.isKeyWindow), "
                    + "title=\(settingsWindow.title), "
                    + "autosave=\(settingsWindow.frameAutosaveName), "
                    + "style=\(settingsWindow.styleMask.rawValue), "
                    + "min=\(settingsWindow.contentMinSize)"
            )
        }
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
            )
        )
        try await waitUntil("Close Window did not close Settings") {
            settingsWindow.isVisible == false && mainWindow.isVisible
        }
    }

    private func exerciseQuickEntry(
        mainWindow: NSWindow,
        store: NoonmarkStore
    ) async throws {
        try await activate(mainWindow)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showQuickEntry,
                key: "n",
                modifiers: .command
            )
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
            in: panel
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
        store: NoonmarkStore
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
            )
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
            )
        )
        try await waitUntil("Shift-Command-Z did not redo the Quick Entry task") {
            taskRecord(titled: Self.fixtureTitle, in: store) != nil
                && store.canUndoDomainAction
                && store.canRedoDomainAction == false
        }
    }

    private func exerciseSearch(
        mainWindow: NSWindow,
        store: NoonmarkStore,
        expectedTraceID: DayTraceID
    ) async throws {
        try await activate(mainWindow)
        mainWindow.makeFirstResponder(nil)
        try performMenuShortcut(
            MenuShortcut(
                action: NoonmarkMenuAction.showSearch,
                key: "f",
                modifiers: .command
            )
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
        try await assertAnchor(
            "search.window",
            verificationText: store.copy.searchCommand,
            in: searchWindow
        )

        let editor = try await focusedTextEditor(
            identifier: "search.field",
            in: searchWindow
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

    private func assertMenuContract(copy: AppCopy) throws {
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

        let shortcuts = [
            MenuShortcut(action: NoonmarkMenuAction.showSettings, key: ",", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.showQuickEntry, key: "n", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.importData, key: "i", modifiers: [.command, .shift]),
            MenuShortcut(action: NoonmarkMenuAction.showSearch, key: "f", modifiers: .command),
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
            MenuShortcut(action: NoonmarkMenuAction.toggleSidebar, key: "s", modifiers: [.command, .control]),
            MenuShortcut(action: NoonmarkMenuAction.toggleDetailRail, key: "i", modifiers: [.command, .option]),
            MenuShortcut(action: #selector(NSApplication.terminate(_:)), key: "q", modifiers: .command),
            MenuShortcut(action: #selector(NSWindow.performMiniaturize(_:)), key: "m", modifiers: .command),
            MenuShortcut(action: NoonmarkMenuAction.showHelp, key: "?", modifiers: [.command, .shift])
        ]
        for shortcut in shortcuts {
            let item = try menuItem(action: shortcut.action)
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

    private func performMenuShortcut(_ shortcut: MenuShortcut) throws {
        let item = try menuItem(action: shortcut.action)
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
        guard let mainMenu = NSApp.mainMenu,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let event = menuKeyEvent(shortcut, window: window),
              mainMenu.performKeyEquivalent(with: event)
        else {
            throw Failure.failed(
                "menu shortcut was not handled: \(NSStringFromSelector(shortcut.action))"
            )
        }
    }

    private func menuItem(action: Selector) throws -> NSMenuItem {
        guard let matches = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter({ $0.action == action }),
            matches.count == 1,
            let item = matches.first
        else {
            throw Failure.failed(
                "menu action was missing or duplicated: \(NSStringFromSelector(action))"
            )
        }
        return item
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

    private func menuKeyEvent(
        _ shortcut: MenuShortcut,
        window: NSWindow
    ) -> NSEvent? {
        guard let keyCode = Self.keyCodes[Character(shortcut.key.lowercased())]
        else {
            return nil
        }
        let characters = shortcut.modifiers.contains(.shift)
            ? shortcut.key.uppercased()
            : shortcut.key
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shortcut.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func focusedTextEditor(
        identifier: String,
        in window: NSWindow
    ) async throws -> NSTextView {
        var identifiedView: NSView?
        try await waitUntil("text field was missing: \(identifier)") {
            identifiedView = self.uniqueView(identifier: identifier, in: window)
            return identifiedView != nil
        }
        guard let identifiedView else {
            throw Failure.failed("text field disappeared: \(identifier)")
        }
        let clickTarget = ([identifiedView] + allViews(from: identifiedView)).first {
            $0 is NSTextField
        } ?? editableTextField(overlapping: identifiedView, in: window)
        guard let clickTarget else {
            throw Failure.failed("editable text field was missing: \(identifier)")
        }
        guard realClick(clickTarget) else {
            throw Failure.failed("text field rejected a real mouse click: \(identifier)")
        }

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

    private func realClick(_ view: NSView) -> Bool {
        guard let window = view.window,
              window.isVisible,
              view.isHiddenOrHasHiddenAncestor == false,
              view.bounds.width > 0,
              view.bounds.height > 0
        else {
            return false
        }
        let point = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
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
            guard let definition = store.engine.definitions[trace.definitionID],
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

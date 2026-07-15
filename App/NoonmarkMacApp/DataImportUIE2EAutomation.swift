import AppKit
import ApplicationServices
import Foundation
import NoonmarkCore
import NoonmarkStorage

/// Exercises the destructive import through Noonmark's real File menu,
/// `NSOpenPanel`, SwiftUI confirmation sheet, and pointer events.
///
/// Direct Store import APIs are deliberately absent from this driver. Store
/// access is limited to fixture setup and post-interaction assertions.
@MainActor
struct DataImportUIE2EAutomation: LaunchAutomationRunnable {
    private enum Mode {
        case setup
        case exercise
        case verifyRestart
    }

    private struct ProbeState: Codable {
        let baselineTitle: String
        let scheduledImportTitle: String
        let poolImportTitle: String
        let scheduledDate: String
        let cancellationConfirmationWasVisible: Bool
        let destructiveConfirmationWasVisible: Bool
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

    private static let e2eBundleIdentifier = "app.noonmark.mac.e2e"
    private static let baselineTitle = "E2E UI import baseline 7319"
    private static let scheduledImportTitle = "E2E UI import scheduled 7319"
    private static let poolImportTitle = "E2E UI import pool 7319"

    private let mode: Mode
    private let fixtureURL: URL
    private let stateURL: URL
    private let resultURL: URL
    private let databaseURL: URL

    static func fromCommandLine() -> Self? {
        guard Bundle.main.bundleIdentifier == e2eBundleIdentifier else {
            return nil
        }

        let mode: Mode
        if AppLaunchArguments.contains("--e2e-data-import-ui-setup") {
            mode = .setup
        } else if AppLaunchArguments.contains("--e2e-data-import-ui-exercise") {
            mode = .exercise
        } else if AppLaunchArguments.contains("--e2e-data-import-ui-verify") {
            mode = .verifyRestart
        } else {
            return nil
        }

        guard let fixturePath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-fixture-url"
        ), let statePath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-state-url"
        ), let resultPath = AppLaunchArguments.value(
            after: "--e2e-data-import-ui-result-url"
        ), let databasePath = AppLaunchArguments.value(after: "--data-url")
        else {
            return nil
        }

        return Self(
            mode: mode,
            fixtureURL: URL(fileURLWithPath: fixturePath),
            stateURL: URL(fileURLWithPath: statePath),
            resultURL: URL(fileURLWithPath: resultPath),
            databaseURL: URL(fileURLWithPath: databasePath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .setup:
                    try setup(on: store)
                case .exercise:
                    try await exercise(on: store)
                case .verifyRestart:
                    try verifyRestart(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeWindowDump()
                try? writeResult("failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func setup(on store: NoonmarkStore) throws {
        let baselineEngine = NoonmarkEngine()
        _ = try baselineEngine.createPoolTask(
            title: Self.baselineTitle,
            descriptionText: "Cancel must retain this persisted task."
        )
        store.engine = baselineEngine
        store.persist()

        let persistedBaseline = try persistedEngine()
        guard persistedBaseline.definitions.values.filter({
            $0.title == Self.baselineTitle
        }).count == 1,
            persistedBaseline.definitions.count == 1,
            persistedBaseline.traces.isEmpty
        else {
            throw Failure.failed("baseline fixture was not committed to SQLite")
        }

        let importEngine = NoonmarkEngine()
        let scheduledChainID = try importEngine.createPoolTask(
            title: Self.scheduledImportTitle,
            descriptionText: "Selected through the real NSOpenPanel."
        )
        _ = try importEngine.scheduleFromPool(
            chainID: scheduledChainID,
            date: store.today,
            today: store.today
        )
        _ = try importEngine.createPoolTask(
            title: Self.poolImportTitle,
            descriptionText: "Confirms the complete package replaced current data."
        )
        try NoonmarkDataPackage.write(importEngine.snapshot(), to: fixtureURL)

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw Failure.failed("import fixture JSON was not created")
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        guard fixtureURL.path.hasPrefix("/tmp/"),
              FileManager.default.fileExists(atPath: fixtureURL.path)
        else {
            throw Failure.failed("UI import fixture must be an existing isolated /tmp JSON file")
        }
        let mainWindow = try await visibleMainWindow()
        try await activate(mainWindow)
        let panelTraceURL = resultURL
            .deletingLastPathComponent()
            .appendingPathComponent("panel-events.txt")
        try? FileManager.default.removeItem(at: panelTraceURL)

        let baseline = store.engine.snapshot()
        let persistedBaseline = try persistedSnapshot()
        guard definitionCount(titled: Self.baselineTitle, in: store) == 1,
              definitionCount(titled: Self.scheduledImportTitle, in: store) == 0
        else {
            throw Failure.failed("exercise did not start from its persisted baseline")
        }

        try chooseFixtureThroughFileMenu(
            mainWindow: mainWindow,
            panelTraceURL: panelTraceURL,
            interactionLabel: "cancel"
        )
        try await waitForConfirmation(
            store: store,
            failure: "first import selection did not present data-import.confirmation"
        )
        let cancellationConfirmationWasVisible = true
        try clickConfirmationButton(
            identifier: "data-import.cancel",
            title: store.copy.cancel
        )
        try await waitUntil("Cancel did not dismiss the import confirmation") {
            store.preparedDataImport == nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "data-import.confirmation"
                )
                && AppViewTreeE2E.hasNoAttachedSheets()
        }
        guard store.engine.snapshot() == baseline,
              try persistedSnapshot() == persistedBaseline,
              definitionCount(titled: Self.baselineTitle, in: store) == 1,
              definitionCount(titled: Self.scheduledImportTitle, in: store) == 0
        else {
            throw Failure.failed("Cancel changed memory or SQLite before confirmation")
        }

        try await activate(mainWindow)
        try chooseFixtureThroughFileMenu(
            mainWindow: mainWindow,
            panelTraceURL: panelTraceURL,
            interactionLabel: "confirm"
        )
        try await waitForConfirmation(
            store: store,
            failure: "second import selection did not present data-import.confirmation"
        )
        let destructiveConfirmationWasVisible = true
        try clickConfirmationButton(
            identifier: "data-import.confirm",
            title: store.copy.confirmImport
        )
        try await waitUntil("destructive confirmation did not commit the selected package") {
            store.preparedDataImport == nil
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "data-import.confirmation"
                )
                && AppViewTreeE2E.hasNoAttachedSheets()
                && self.definitionCount(
                    titled: Self.scheduledImportTitle,
                    in: store
                ) == 1
                && self.definitionCount(titled: Self.poolImportTitle, in: store) == 1
        }

        let persistedAfterImport = try persistedEngine()
        guard definitionCount(titled: Self.baselineTitle, in: store) == 0,
              definitionCount(
                  titled: Self.baselineTitle,
                  in: persistedAfterImport
              ) == 0,
              definitionCount(
                  titled: Self.scheduledImportTitle,
                  in: persistedAfterImport
              ) == 1,
              definitionCount(
                  titled: Self.poolImportTitle,
                  in: persistedAfterImport
              ) == 1
        else {
            throw Failure.failed("confirmed UI import did not atomically replace SQLite")
        }

        try writeState(
            ProbeState(
                baselineTitle: Self.baselineTitle,
                scheduledImportTitle: Self.scheduledImportTitle,
                poolImportTitle: Self.poolImportTitle,
                scheduledDate: store.today.description,
                cancellationConfirmationWasVisible: cancellationConfirmationWasVisible,
                destructiveConfirmationWasVisible: destructiveConfirmationWasVisible
            )
        )
    }

    private func verifyRestart(on store: NoonmarkStore) throws {
        let state = try JSONDecoder().decode(
            ProbeState.self,
            from: Data(contentsOf: stateURL)
        )
        guard state.cancellationConfirmationWasVisible,
              state.destructiveConfirmationWasVisible,
              state.baselineTitle == Self.baselineTitle,
              state.scheduledImportTitle == Self.scheduledImportTitle,
              state.poolImportTitle == Self.poolImportTitle,
              definitionCount(titled: state.baselineTitle, in: store) == 0,
              definitionCount(titled: state.scheduledImportTitle, in: store) == 1,
              definitionCount(titled: state.poolImportTitle, in: store) == 1,
              store.engine.traces.values.contains(where: { trace in
                  trace.date.description == state.scheduledDate
                      && store.engine.definitions[trace.definitionID]?.title
                      == state.scheduledImportTitle
              }),
              store.preparedDataImport == nil
        else {
            throw Failure.failed("UI-imported package did not survive a clean restart")
        }
        let persisted = try persistedEngine()
        guard definitionCount(titled: state.baselineTitle, in: persisted) == 0,
              definitionCount(titled: state.scheduledImportTitle, in: persisted) == 1,
              definitionCount(titled: state.poolImportTitle, in: persisted) == 1
        else {
            throw Failure.failed("restarted UI import did not match SQLite")
        }
    }

    private func chooseFixtureThroughFileMenu(
        mainWindow: NSWindow,
        panelTraceURL: URL,
        interactionLabel: String
    ) throws {
        let interaction = OpenPanelKeyboardSelection(
            fixtureURL: fixtureURL,
            traceURL: panelTraceURL,
            interactionLabel: interactionLabel
        )
        interaction.start()
        defer { interaction.stop() }

        let item = try menuItem(action: NoonmarkMenuAction.importData)
        let expectedModifiers: NSEvent.ModifierFlags = [.command, .shift]
        guard item.keyEquivalent == "i",
              normalizedModifiers(item.keyEquivalentModifierMask)
              == normalizedModifiers(expectedModifiers),
              validate(item),
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: expectedModifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: mainWindow.windowNumber,
                  context: nil,
                  characters: "I",
                  charactersIgnoringModifiers: "i",
                  isARepeat: false,
                  keyCode: 34
              ),
              NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        else {
            throw Failure.failed("File > Import keyboard command was unavailable")
        }
        if let failure = interaction.failure {
            throw Failure.failed(failure)
        }
        guard interaction.didSelectFixtureUsingInput else {
            throw Failure.failed("NSOpenPanel closed without input selection of the fixture")
        }
    }

    private func waitForConfirmation(
        store: NoonmarkStore,
        failure: String
    ) async throws {
        try await waitUntil(failure) {
            store.preparedDataImport?.sourceURL.standardizedFileURL
                == fixtureURL.standardizedFileURL
                && AppViewTreeE2E.view(
                    identifier: "data-import.confirmation"
                ) != nil
        }
    }

    private func clickConfirmationButton(
        identifier: String,
        title: String
    ) throws {
        if let button = anchoredConfirmationButton(identifier: identifier) {
            if AppViewTreeE2E.click(button) {
                return
            }
        }
        guard let button = visibleButtons().first(where: {
            $0.title == title || $0.accessibilityLabel() == title
        }), AppViewTreeE2E.click(button)
        else {
            throw Failure.failed("confirmation button was not clickable: \(identifier)")
        }
    }

    private func anchoredConfirmationButton(identifier: String) -> NSButton? {
        guard let anchor = AppViewTreeE2E.view(identifier: identifier) else {
            return nil
        }
        return (anchor as? NSButton) ?? AppViewTreeE2E.button(overlapping: anchor)
    }

    private func visibleButtons() -> [NSButton] {
        let windows = NSApp.windows.filter {
            $0.isVisible && $0.isMiniaturized == false && $0.alphaValue > 0
        }
        return windows.flatMap { window -> [NSButton] in
            guard let root = window.contentView?.superview ?? window.contentView else {
                return []
            }
            return allViews(from: root).compactMap { view in
                guard let button = view as? NSButton,
                      button.isHiddenOrHasHiddenAncestor == false,
                      button.bounds.width > 0,
                      button.bounds.height > 0
                else {
                    return nil
                }
                return button
            }
        }
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

    private func menuItem(action: Selector) throws -> NSMenuItem {
        let matches = NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.action == action } ?? []
        guard matches.count == 1, let item = matches.first else {
            throw Failure.failed("File menu import action was missing or duplicated")
        }
        return item
    }

    private func validate(_ item: NSMenuItem) -> Bool {
        guard let validator = item.target as? NSMenuItemValidation else {
            return item.isEnabled
        }
        let enabled = validator.validateMenuItem(item)
        item.isEnabled = enabled
        return enabled
    }

    private func definitionCount(titled title: String, in store: NoonmarkStore) -> Int {
        store.engine.definitions.values.filter { $0.title == title }.count
    }

    private func definitionCount(titled title: String, in engine: NoonmarkEngine) -> Int {
        engine.definitions.values.filter { $0.title == title }.count
    }

    private func persistedSnapshot() throws -> NoonmarkSnapshot {
        try persistedEngine().snapshot()
    }

    private func persistedEngine() throws -> NoonmarkEngine {
        try SQLiteEngineRepository(databaseURL: databaseURL).load()
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var resolved: NSWindow?
        try await waitUntil("main window did not become visible") {
            resolved = NSApp.windows.first {
                $0 is NoonmarkWindow && $0.isVisible && $0.isMiniaturized == false
            }
            return resolved != nil
        }
        guard let resolved else {
            throw Failure.failed("main window disappeared")
        }
        return resolved
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("main window did not remain visible for menu input") {
            window.isVisible && window.isMiniaturized == false
        }
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 200,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
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

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    private func writeWindowDump() throws {
        let lines = NSApp.windows.map { window in
            "window=\(window.windowNumber) type=\(String(describing: type(of: window))) "
                + "visible=\(window.isVisible) key=\(window.isKeyWindow) "
                + "title=\(window.title) frame=\(NSStringFromRect(window.frame))"
        }
        try lines.joined(separator: "\n").write(
            to: resultURL.deletingPathExtension().appendingPathExtension("windows.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@MainActor
private final class OpenPanelKeyboardSelection: NSObject {
    private enum Stage {
        case waitingForPanel
        case waitingForDirectory
        case waitingForSelection
        case waitingForPanelClose
        case finished
    }

    private let fixtureURL: URL
    private let traceURL: URL
    private let interactionLabel: String
    private var timer: Timer?
    private weak var panel: NSOpenPanel?
    private var stage = Stage.waitingForPanel
    private var tickCount = 0

    private(set) var failure: String?
    private(set) var didSelectFixtureUsingInput = false

    init(
        fixtureURL: URL,
        traceURL: URL,
        interactionLabel: String
    ) {
        self.fixtureURL = fixtureURL
        self.traceURL = traceURL
        self.interactionLabel = interactionLabel
    }

    func start() {
        let timer = Timer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        trace("timer-started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        tickCount += 1
        if tickCount > 240 {
            fail("timed out while driving the real NSOpenPanel")
            return
        }

        do {
            try advanceInteraction()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func advanceInteraction() throws {
        switch stage {
        case .waitingForPanel:
            waitForPanel()
        case .waitingForDirectory:
            try waitForDirectory()
        case .waitingForSelection:
            try waitForSelection()
        case .waitingForPanelClose:
            waitForPanelClose()
        case .finished:
            stop()
        }
    }

    private func waitForPanel() {
        guard let panel = (NSApp.modalWindow as? NSOpenPanel)
            ?? NSApp.windows.compactMap({ $0 as? NSOpenPanel }).first(where: \.isVisible)
        else {
            return
        }
        self.panel = panel
        trace(
            "panel-visible title=\(panel.title ?? "") "
                + "key=\(panel.isKeyWindow) responder="
                + String(describing: type(of: panel.firstResponder))
        )
        tracePanelControls(panel)
        panel.directoryURL = fixtureURL.deletingLastPathComponent()
        stage = .waitingForDirectory
        trace(
            "set-initial-directory "
                + fixtureURL.deletingLastPathComponent().path
        )
    }

    private func waitForDirectory() throws {
        guard let panel else { return }
        guard panel.directoryURL?.standardizedFileURL
            == fixtureURL.deletingLastPathComponent().standardizedFileURL
        else {
            return
        }
        try postHIDKey(keyCode: 125)
        stage = .waitingForSelection
        trace(
            "sent-down-arrow-for-only-visible-file responder="
                + String(describing: type(of: panel.firstResponder))
        )
    }

    private func waitForSelection() throws {
        guard let panel, panel.isVisible else {
            stage = .finished
            return
        }
        guard panel.urls.map(\.standardizedFileURL).contains(
            fixtureURL.standardizedFileURL
        ) else {
            if tickCount.isMultiple(of: 20) {
                trace("waiting-selection urls=\(panel.urls.map(\.path))")
            }
            return
        }
        didSelectFixtureUsingInput = true
        try postHIDKey(keyCode: 36)
        stage = .waitingForPanelClose
        trace("selected-visible-fixture-and-sent-open-return")
    }

    private func waitForPanelClose() {
        guard panel?.isVisible != false else {
            stage = .finished
            trace("panel-closed")
            return
        }
    }

    private func postHIDKey(keyCode: CGKeyCode) throws {
        guard CGPreflightPostEventAccess() else {
            throw DataImportPanelInputError.windowServerEventAccessUnavailable
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: true
              ), let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: false
              )
        else {
            throw DataImportPanelInputError.eventConstructionFailed
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func fail(_ message: String) {
        trace("failed \(message)")
        failure = message
        stage = .finished
        if let panel, panel.isVisible {
            panel.cancel(nil)
        }
        stop()
    }

    private func traceWindowState(panel: NSOpenPanel) {
        var windows: [NSWindow] = [panel]
        windows.append(contentsOf: panel.childWindows ?? [])
        if let attachedSheet = panel.attachedSheet {
            windows.append(attachedSheet)
        }
        if let keyWindow = NSApp.keyWindow {
            windows.append(keyWindow)
        }
        let descriptions = windows.map { window in
            "\(String(describing: type(of: window)))"
                + "[title=\(window.title),key=\(window.isKeyWindow),"
                + "sheetParent=\(window.sheetParent === panel),"
                + "responder=\(String(describing: type(of: window.firstResponder)))]"
        }
        trace("waiting-path-window " + descriptions.joined(separator: " | "))
    }

    private func tracePanelControls(_ panel: NSOpenPanel) {
        guard let root = panel.contentView else { return }
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []
        var lines = [
            "directory=\(panel.directoryURL?.path ?? "nil")",
            "selected=\(panel.urls.map(\.path))"
        ]
        while let view = pending.popLast(), visited.count < 1000 {
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            pending.append(contentsOf: view.subviews)
            let label = view.accessibilityLabel() ?? ""
            let identifier = view.identifier?.rawValue ?? ""
            let text = if let button = view as? NSButton {
                button.title
            } else if let field = view as? NSTextField {
                field.stringValue
            } else {
                ""
            }
            guard label.isEmpty == false
                || identifier.isEmpty == false
                || text.isEmpty == false
                || view is NSPathControl
                || view is NSOutlineView
                || view is NSTableView
                || view is NSBrowser
            else {
                continue
            }
            lines.append(
                "\(String(describing: type(of: view))) "
                    + "id=\(identifier) label=\(label) text=\(text) "
                    + "frame=\(NSStringFromRect(view.frame))"
            )
        }
        trace("panel-controls\n" + lines.joined(separator: "\n"))
    }

    private func trace(_ message: String) {
        let line = "\(interactionLabel) \(tickCount) \(message)\n"
        try? FileManager.default.createDirectory(
            at: traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: traceURL.path) == false {
            try? Data().write(to: traceURL, options: .atomic)
        }
        guard let handle = try? FileHandle(forWritingTo: traceURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            return
        }
    }
}

private enum DataImportPanelInputError: LocalizedError {
    case eventConstructionFailed
    case windowServerEventAccessUnavailable

    var errorDescription: String? {
        switch self {
        case .eventConstructionFailed:
            "could not construct a real NSOpenPanel keyboard event"
        case .windowServerEventAccessUnavailable:
            "WindowServer denied real keyboard events for the NSOpenPanel"
        }
    }
}

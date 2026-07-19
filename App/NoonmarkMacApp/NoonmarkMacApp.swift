import AppKit
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

enum NoonmarkToolbarIdentifier {
    static let toolbar = NSToolbar.Identifier("Noonmark.MainToolbar")
}

@main
@MainActor
final class NoonmarkMacApp: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowRestoration, NoonmarkMenuCommandTarget {
    private static var retainedDelegate: NoonmarkMacApp?
    private var window: NSWindow?
    private let store: NoonmarkStore
    private let fixedNaturalDayEnvironment: FixedNaturalDayEnvironment?
    private let workspaceStateRepository: WorkspaceStateRepository
    private let windowStatePersistenceEnabled: Bool
    private lazy var settingsWindowController = NoonmarkSettingsWindowController(
        store: store
    )
    private lazy var quickEntryWindowController = NoonmarkQuickEntryWindowController(
        store: store
    )
    private lazy var searchWindowController = NoonmarkSearchWindowController(
        store: store
    )
    private lazy var helpWindowController = NoonmarkHelpWindowController(
        store: store
    )

    private init(
        store: NoonmarkStore,
        fixedNaturalDayEnvironment: FixedNaturalDayEnvironment?,
        workspaceStateRepository: WorkspaceStateRepository,
        windowStatePersistenceEnabled: Bool
    ) {
        self.store = store
        self.fixedNaturalDayEnvironment = fixedNaturalDayEnvironment
        self.workspaceStateRepository = workspaceStateRepository
        self.windowStatePersistenceEnabled = windowStatePersistenceEnabled
        super.init()
    }

    static func main() {
        do {
            _ = try CloudKitSyncLaunchConfiguration.resolve(
                arguments: AppLaunchArguments.values
            )
        } catch {
            let message = "Invalid Noonmark CloudKit launch arguments.\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EX_USAGE)
        }
        let app = NSApplication.shared
        if let inputCleanup = WindowServerInputCleanupE2EAutomation.fromCommandLine() {
            app.setActivationPolicy(.prohibited)
            inputCleanup.run()
            app.run()
            return
        }
        let delegate: NoonmarkMacApp
        do {
            let windowStatePersistenceEnabled = NoonmarkMainWindowState
                .persistenceEnabled(
                    arguments: AppLaunchArguments.values,
                    bundleIdentifier: Bundle.main.bundleIdentifier
                )
            let workspaceStateRepository = WorkspaceStateRepository(
                persistenceEnabled: windowStatePersistenceEnabled
            )
            if AppLaunchArguments.contains("--e2e-reset-workspace-state") {
                workspaceStateRepository.reset()
                NoonmarkMainWindowState.resetSavedState()
            }
            let environment = try NaturalDayEnvironmentFactory.make(
                arguments: AppLaunchArguments.values,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
            let dayContext = NaturalDayContext(environment: environment)
            delegate = NoonmarkMacApp(
                store: try NoonmarkStore(dayContext: dayContext),
                fixedNaturalDayEnvironment: environment
                    as? FixedNaturalDayEnvironment,
                workspaceStateRepository: workspaceStateRepository,
                windowStatePersistenceEnabled: windowStatePersistenceEnabled
            )
            let workspaceState = workspaceStateRepository.load()
            delegate.store.isSidebarExpanded = workspaceState.sidebarExpanded
            delegate.store.isDetailRailExpanded = workspaceState.detailExpanded
        } catch {
            if let status = DataRootLeaseConflictE2EObserver.record(error) {
                exit(status)
            }
            presentStartupFailure(error)
        }
        if AppLaunchArguments.contains("--e2e-enable-zhulong") {
            delegate.store.zhulongProviderDraft.enabled = true
        }
        if AppLaunchArguments.contains("--e2e-reset-selection") {
            delegate.store.resetLaunchSelection()
        }
        if AppLaunchArguments.contains("--e2e-collapse-sidebar") {
            delegate.store.isSidebarExpanded = false
        }
        if AppLaunchArguments.contains("--e2e-expand-detail-rail") {
            delegate.store.isDetailRailExpanded = true
        }
        let requestedPageName = AppLaunchArguments.value(after: "--page")
        if let requestedPageName, let page = NoonmarkStore.Page(commandLineValue: requestedPageName) {
            delegate.store.page = page
        }
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static func requestedE2EWindowSize() -> NSSize? {
        guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e",
              let value = AppLaunchArguments.value(after: "--e2e-window-size")
        else { return nil }
        let components = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width >= NoonmarkVisualMetrics.minimumSize.width,
              height >= NoonmarkVisualMetrics.minimumSize.height,
              width <= 2400,
              height <= 1600
        else { return nil }
        return NSSize(width: width, height: height)
    }

    private static func presentStartupFailure(_ error: Error) -> Never {
        let usesChinese = Locale.preferredLanguages.first?
            .lowercased()
            .hasPrefix("zh") == true
        let copy = AppCopy(language: usesChinese ? .chinese : .english)
        let diagnostic = "Noonmark startup failed: \(String(reflecting: error))\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = copy.startupFailureTitle
        alert.informativeText = copy.startupFailureMessage
        alert.addButton(withTitle: copy.quit)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(EX_SOFTWARE)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        store.onLanguageChange = { [weak self] in
            self?.installMainMenu()
            self?.settingsWindowController.refreshLocalizedChrome()
            self?.quickEntryWindowController.refreshLocalizedChrome()
            self?.searchWindowController.refreshLocalizedChrome()
            self?.helpWindowController.refreshLocalizedChrome()
        }
        let shouldOpenSettings = store.page == .settings
        if shouldOpenSettings {
            store.page = .day
        }
        store.ensureVisiblePage()
        registerCloudKitRemoteNotificationsIfNeeded()
        openMainWindow()
        if shouldOpenSettings {
            // `openMainWindow()` orders the main window on the next run-loop
            // turn. Present Settings afterwards so the main window cannot
            // steal key status from the native Settings window at launch.
            DispatchQueue.main.async { [weak self] in
                self?.settingsWindowController.show()
            }
        }
        runLaunchAutomationIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refreshNaturalDay()
        store.refreshCloudKitAccountAvailability()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NSLog(
            "Noonmark CloudKit remote notifications registered (%d-byte token)",
            deviceToken.count
        )
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog(
            "Noonmark CloudKit remote notification registration failed: %@",
            error.localizedDescription
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e" {
            NSLog("Noonmark E2E applicationWillTerminate reached")
        }
        store.prepareForTermination()
    }

    func openMainWindow() {
        guard window == nil else {
            if window?.isMiniaturized == true {
                window?.deminiaturize(nil)
            }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = NoonmarkRootView(
            workspaceStateRepository: workspaceStateRepository
        )
            .environmentObject(store)
            .preferredColorScheme(.light)

        let launchSize = Self.requestedE2EWindowSize()
            ?? NoonmarkVisualMetrics.launchSize
        let window = NoonmarkWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: launchSize.width,
                height: launchSize.height
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = store.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.enableNoonmarkDynamicKeyViewLoop()
        window.identifier = NoonmarkMainWindowState.identifier
        window.isRestorable = windowStatePersistenceEnabled
        window.restorationClass = windowStatePersistenceEnabled ? Self.self : nil
        self.window = window
        installToolbar(on: window)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hostingView)
        let minimumFrame = NSRect(
            origin: .zero,
            size: NoonmarkVisualMetrics.minimumSize
        )
        window.contentMinSize = window.contentRect(
            forFrameRect: minimumFrame
        ).size
        if windowStatePersistenceEnabled {
            let restoredFrame = window.setFrameUsingName(
                NoonmarkMainWindowState.frameAutosaveName
            )
            _ = window.setFrameAutosaveName(
                NoonmarkMainWindowState.frameAutosaveName
            )
            if restoredFrame == false {
                window.center()
            }
        } else {
            window.center()
        }

        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            // AppKit otherwise chooses the first inline editor as the initial
            // responder, which presents an input-state HUD over the workspace.
            // Explicit quick-add and navigation commands request focus later.
            window.makeFirstResponder(nil)
        }
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: NoonmarkToolbarIdentifier.toolbar)
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        guard identifier == NoonmarkMainWindowState.identifier,
              let delegate = retainedDelegate
        else {
            completionHandler(nil, nil)
            return
        }
        delegate.openMainWindow()
        completionHandler(delegate.window, nil)
    }

    private func installMainMenu() {
        NSApp.mainMenu = NoonmarkMainMenuFactory.make(
            copy: store.copy,
            target: self
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSidebarAction(_:)):
            menuItem.title = store.isSidebarExpanded
                ? store.copy.collapseSidebar
                : store.copy.expandSidebar
            return true
        case #selector(toggleDetailRailAction(_:)):
            menuItem.title = store.isDetailRailExpanded
                ? store.copy.collapseDetailRail
                : store.copy.expandDetailRail
            return store.hasDetailRailContent
        case #selector(undoAction(_:)):
            if let undoManager = activeTextResponder?.undoManager, undoManager.canUndo {
                menuItem.title = store.copy.undoNamed(undoManager.undoActionName)
                return true
            }
            menuItem.title = store.domainUndoMenuTitle
            return mainWindowIsKey && store.canUndoDomainAction
        case #selector(redoAction(_:)):
            if let undoManager = activeTextResponder?.undoManager, undoManager.canRedo {
                menuItem.title = store.copy.redoNamed(undoManager.redoActionName)
                return true
            }
            menuItem.title = store.domainRedoMenuTitle
            return mainWindowIsKey && store.canRedoDomainAction
        case #selector(selectAllAction(_:)):
            return activeTextResponder != nil
                || (window?.isKeyWindow == true && store.canSelectAllWorkspaceItems)
        case NoonmarkMenuAction.showQuickEntry:
            return store.canPerformEngineMutation
        case NoonmarkMenuAction.importData:
            return store.canBeginDataImport
        default:
            return true
        }
    }

    @objc func showAboutAction(_ sender: Any?) {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: store.copy.appName,
            .applicationVersion: shortVersion,
            .version: build
        ]
        let poemPolicy = store.engine.preferences.settingsPoemDisplayPolicy
        if poemPolicy.enabled, poemPolicy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            options[.credits] = NSAttributedString(
                string: poemPolicy.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettingsAction(_ sender: Any?) {
        settingsWindowController.show()
    }

    @objc func showQuickEntryAction(_ sender: Any?) {
        quickEntryWindowController.show { [weak self] text in
            guard let self else { return false }
            let didCreate = store.addQuickTaskForToday(text)
            if didCreate {
                openMainWindow()
            }
            return didCreate
        }
    }

    @objc func showSearchAction(_ sender: Any?) {
        searchWindowController.show { [weak self] result in
            guard let self else { return }
            store.revealSearchResult(result)
            openMainWindow()
        }
    }

    @objc func exportDataAction(_ sender: Any?) {
        store.exportDataPackage()
    }

    @objc func importDataAction(_ sender: Any?) {
        store.importDataPackage()
    }

    @objc func showMainWindowAction(_ sender: Any?) {
        openMainWindow()
    }

    @objc func showHelpAction(_ sender: Any?) {
        helpWindowController.show()
    }

    @objc func toggleSidebarAction(_ sender: Any?) {
        store.toggleSidebar()
    }

    @objc func toggleDetailRailAction(_ sender: Any?) {
        store.toggleDetailRail()
    }

    @objc func undoAction(_ sender: Any?) {
        if let textResponder = activeTextResponder {
            if textResponder.undoManager?.canUndo == true {
                textResponder.undoManager?.undo()
            }
            return
        }
        guard mainWindowIsKey,
              store.showingClassificationManager == false
        else { return }
        store.undo()
    }

    @objc func redoAction(_ sender: Any?) {
        if let textResponder = activeTextResponder {
            if textResponder.undoManager?.canRedo == true {
                textResponder.undoManager?.redo()
            }
            return
        }
        guard mainWindowIsKey,
              store.showingClassificationManager == false
        else { return }
        store.redo()
    }

    @objc private func cutAction(_ sender: Any?) {
        performTextAction(#selector(NSText.cut(_:)), sender: sender)
    }

    @objc private func copyAction(_ sender: Any?) {
        performTextAction(#selector(NSText.copy(_:)), sender: sender)
    }

    @objc private func pasteAction(_ sender: Any?) {
        performTextAction(#selector(NSText.paste(_:)), sender: sender)
    }

    @objc private func deleteTextAction(_ sender: Any?) {
        performTextAction(#selector(NSText.delete(_:)), sender: sender)
    }

    @objc func selectAllAction(_ sender: Any?) {
        if activeTextResponder != nil {
            performTextAction(#selector(NSResponder.selectAll(_:)), sender: sender)
        } else if window?.isKeyWindow == true {
            store.selectAllWorkspaceItems()
        }
    }

    private func performTextAction(_ action: Selector, sender: Any?) {
        guard let textResponder = activeTextResponder else { return }
        NSApp.sendAction(action, to: textResponder, from: sender)
    }

    private var activeTextResponder: NSTextView? {
        NSApp.keyWindow?.firstResponder as? NSTextView
    }

    private var mainWindowIsKey: Bool {
        window?.isKeyWindow == true
    }

    private func runLaunchAutomationIfNeeded() {
        guard let automation = LaunchAutomation.fromCommandLine() else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [store, automation] in
            automation.run(
                on: store,
                fixedNaturalDayEnvironment: self.fixedNaturalDayEnvironment
            )
        }
    }

    private func registerCloudKitRemoteNotificationsIfNeeded() {
        guard let configuration = store.cloudKitSyncConfiguration else { return }
        do {
            try CloudKitEntitlementProbe.validateCurrentProcess(
                containerIdentifier: configuration.containerIdentifier
            )
            NSApp.registerForRemoteNotifications()
        } catch {
            NSLog(
                "Noonmark CloudKit capability validation failed: %@",
                error.localizedDescription
            )
        }
    }
}

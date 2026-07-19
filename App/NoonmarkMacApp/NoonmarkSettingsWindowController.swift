import AppKit
import SwiftUI

@MainActor
final class NoonmarkSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.SettingsWindow")
    static let frameAutosaveName = "Noonmark.SettingsWindow.Frame"
    static let toolbarIdentifier = NSToolbar.Identifier("Noonmark.SettingsWindow.Toolbar")
    static let minimumContentSize = NSSize(width: 680, height: 500)

    private let store: NoonmarkStore

    init(store: NoonmarkStore) {
        self.store = store

        let root = NoonmarkSettingsWindowRoot(
            initialPane: Self.commandLineInitialPane
        )
            .environmentObject(store)
            .preferredColorScheme(.light)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.navSettings
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.tabbingMode = .disallowed
        window.enableNoonmarkDynamicKeyViewLoop()
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.installNoonmarkResizableHostingContent(
            root,
            minimumContentSize: Self.minimumContentSize
        )

        super.init(window: window)
        windowFrameAutosaveName = Self.frameAutosaveName
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        window.title = store.copy.navSettings
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.navSettings
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        window.endEditing(for: nil)
    }

    private static var commandLineInitialPane: SettingsPane {
        if AppLaunchArguments.contains("--e2e-settings-groups") {
            return .groups
        }
        if AppLaunchArguments.contains("--e2e-settings-sync") {
            return .sync
        }
        return .general
    }
}

private struct NoonmarkSettingsWindowRoot: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var selectedPane: SettingsPane

    init(initialPane: SettingsPane) {
        _selectedPane = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title(copy: store.copy), systemImage: pane.systemImage)
                    .tag(pane)
                    .accessibilityIdentifier("settings.sidebar.\(pane.rawValue)")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "settings.sidebar.\(pane.rawValue)",
                            verificationText: pane.title(copy: store.copy)
                        )
                    }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .accessibilityIdentifier("settings.sidebar")
            .background {
                AppE2EViewAnchor(identifier: "settings.sidebar")
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selectedPane.title(copy: store.copy))
                        .font(.noonmarkSystem(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .accessibilityAddTraits(.isHeader)

                    SettingsPaneContent(pane: selectedPane)
                        .frame(maxWidth: 620, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .background(Theme.background)
            .accessibilityIdentifier("settings.content")
        }
        .background {
            AppE2EViewAnchor(
                identifier: "settings.window",
                verificationText: store.copy.navSettings
            )
        }
    }
}

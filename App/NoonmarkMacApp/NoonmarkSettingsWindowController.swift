import AppKit
import SwiftUI

@MainActor
final class NoonmarkSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.SettingsWindow")
    static let frameAutosaveName = "Noonmark.SettingsWindow.Frame"

    private let store: NoonmarkStore
    private let model: NoonmarkSettingsWindowModel

    init(store: NoonmarkStore) {
        self.store = store
        model = NoonmarkSettingsWindowModel()

        let root = NoonmarkSettingsWindowRoot(model: model)
            .environmentObject(store)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.navSettings
        window.contentMinSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.tabbingMode = .disallowed
        window.contentView = hostingView

        super.init(window: window)
        windowFrameAutosaveName = Self.frameAutosaveName
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(pane: SettingsPane? = nil) {
        model.selectedPane = pane ?? commandLineInitialPane
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

    private var commandLineInitialPane: SettingsPane {
        if AppLaunchArguments.contains("--e2e-settings-groups") {
            return .groups
        }
        if AppLaunchArguments.contains("--e2e-settings-sync") {
            return .sync
        }
        return .general
    }
}

@MainActor
final class NoonmarkSettingsWindowModel: ObservableObject {
    @Published var selectedPane: SettingsPane = .general
}

private struct NoonmarkSettingsWindowRoot: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var model: NoonmarkSettingsWindowModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $model.selectedPane) { pane in
                Label(pane.title(copy: store.copy), systemImage: pane.systemImage)
                    .tag(pane)
                    .accessibilityIdentifier("settings.sidebar.\(pane.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .accessibilityIdentifier("settings.sidebar")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.selectedPane.title(copy: store.copy))
                        .font(.noonmarkSystem(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .accessibilityAddTraits(.isHeader)

                    SettingsPaneContent(pane: model.selectedPane)
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

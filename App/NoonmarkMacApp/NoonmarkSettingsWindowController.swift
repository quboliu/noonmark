import AppKit
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

@MainActor
final class NoonmarkSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.SettingsWindow")
    static let frameAutosaveName = "Noonmark.SettingsWindow.Frame"
    static let minimumContentSize = NSSize(
        width: CGFloat(MacUISettingsWindowLayout.minimumContentWidth),
        height: CGFloat(MacUISettingsWindowLayout.minimumContentHeight)
    )

    private let store: NoonmarkStore

    init(
        store: NoonmarkStore,
        globalQuickEntryShortcutCoordinator:
            GlobalQuickEntryShortcutCoordinator
    ) {
        self.store = store

        let root = NoonmarkSettingsWindowRoot(
            initialPane: Self.commandLineInitialPane
        )
            .environmentObject(store)
            .environmentObject(globalQuickEntryShortcutCoordinator)
            .preferredColorScheme(.light)

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: CGFloat(MacUISettingsWindowLayout.initialContentWidth),
                height: CGFloat(MacUISettingsWindowLayout.initialContentHeight)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.navSettings
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.tabbingMode = .disallowed
        window.enableNoonmarkDynamicKeyViewLoop()
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
        if AppLaunchArguments.contains("--e2e-settings-zhulong") {
            return .zhulong
        }
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
        ZStack {
            // Settings always keeps its navigation visible.
            // NavigationSplitView adds a sidebar-toggle toolbar item on macOS,
            // even though this window has no compact sidebar state. HSplitView
            // preserves the native, resizable sidebar without advertising that
            // unavailable action in the title bar.
            HSplitView {
                List(SettingsPane.allCases, selection: $selectedPane) { pane in
                    Label(
                        pane.title(copy: store.copy),
                        systemImage: pane.systemImage
                    )
                        .tag(pane)
                        .accessibilityIdentifier(
                            "settings.sidebar.\(pane.rawValue)"
                        )
                        .background {
                            AppE2EViewAnchor(
                                identifier:
                                "settings.sidebar.\(pane.rawValue)",
                                verificationText: pane.title(copy: store.copy)
                            )
                        }
                }
                .listStyle(.sidebar)
                .frame(
                    minWidth: CGFloat(
                        MacUISettingsWindowLayout.sidebarMinimumWidth
                    ),
                    idealWidth: CGFloat(
                        MacUISettingsWindowLayout.sidebarIdealWidth
                    ),
                    maxWidth: CGFloat(
                        MacUISettingsWindowLayout.sidebarMaximumWidth
                    )
                )
                .accessibilityIdentifier("settings.sidebar")
                .background {
                    AppE2EViewAnchor(identifier: "settings.sidebar")
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(selectedPane.title(copy: store.copy))
                            .font(
                                .noonmarkSystem(
                                    size: 20,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(Theme.text1)
                            .accessibilityAddTraits(.isHeader)

                        SettingsPaneContent(pane: selectedPane)
                            .frame(
                                maxWidth: 660,
                                alignment: .topLeading
                            )
                            .background {
                                AppE2EViewAnchor(
                                    identifier:
                                    "settings.content.\(selectedPane.rawValue)",
                                    verificationText:
                                    selectedPane.title(copy: store.copy)
                                )
                            }
                    }
                    .frame(
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                    .padding(.horizontal, 34)
                    .padding(.vertical, 30)
                }
                .background(Theme.background)
                .accessibilityIdentifier("settings.content")
            }

            if let operationFailure = store.operationFailureNotice {
                OperationFailureBanner(
                    message: operationFailure.message,
                    dismissTitle: store.copy.dismiss,
                    accessibilityIdentifier:
                    "settings.operation-failure",
                    bottomPadding: 20
                ) {
                    store.dismissOperationFailure()
                }
                .zIndex(1)
            }
        }
        .background {
            AppE2EViewAnchor(
                identifier: "settings.window",
                verificationText: store.copy.navSettings
            )
        }
    }
}

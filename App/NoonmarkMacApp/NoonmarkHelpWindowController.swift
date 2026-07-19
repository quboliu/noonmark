import AppKit
import SwiftUI

@MainActor
final class NoonmarkHelpWindowController: NSWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.HelpWindow")
    static let frameAutosaveName = "Noonmark.HelpWindow.Frame"
    static let minimumContentSize = NSSize(width: 520, height: 420)

    private let store: NoonmarkStore

    init(store: NoonmarkStore) {
        self.store = store
        let root = NoonmarkHelpView()
            .environmentObject(store)
            .preferredColorScheme(.light)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.noonmarkHelp
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.enableNoonmarkDynamicKeyViewLoop()
        window.installNoonmarkResizableHostingContent(
            root,
            minimumContentSize: Self.minimumContentSize
        )

        super.init(window: window)
        windowFrameAutosaveName = Self.frameAutosaveName
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        window?.title = store.copy.noonmarkHelp
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.noonmarkHelp
    }
}

private struct NoonmarkHelpView: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.copy.appName)
                        .font(.noonmarkSystem(size: 28, weight: .bold))
                        .foregroundStyle(Theme.text1)
                    Text(store.copy.helpQuickStartTitle)
                        .font(.noonmarkSystem(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text2)
                    Text(store.copy.helpQuickStartBody)
                        .font(.noonmarkSystem(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle(store.copy.helpShortcutsTitle)
                    NoonmarkShortcutRow(title: store.copy.quickEntryCommand, keys: "⌘N")
                    NoonmarkShortcutRow(title: store.copy.searchCommand, keys: "⌘F")
                    NoonmarkShortcutRow(title: store.copy.settingsCommand, keys: "⌘,")
                    NoonmarkShortcutRow(title: store.copy.collapseSidebar, keys: "⌃⌘S")
                    NoonmarkShortcutRow(title: store.copy.collapseDetailRail, keys: "⌥⌘I")
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle(store.copy.helpDataTitle)
                    Text(store.copy.helpDataBody)
                        .font(.noonmarkSystem(size: 13))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
        }
        .background(Theme.background)
        .background {
            AppE2EViewAnchor(
                identifier: "help.window",
                verificationText: store.copy.noonmarkHelp
            )
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.noonmarkSystem(size: 15, weight: .semibold))
            .foregroundStyle(Theme.text1)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NoonmarkShortcutRow: View {
    let title: String
    let keys: String

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.noonmarkSystem(size: 13))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 12)
            Text(keys)
                .font(.noonmarkSystem(size: 12, weight: .medium))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line2))
        }
        .accessibilityElement(children: .combine)
    }
}

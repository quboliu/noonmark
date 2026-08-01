import AppKit
import NoonmarkDiagnostics
import SwiftUI

@MainActor
final class NoonmarkAboutWindowController: NSWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier(
        "Noonmark.AboutWindow"
    )
    static let minimumContentSize = NSSize(width: 540, height: 440)

    private let store: NoonmarkStore

    init(
        store: NoonmarkStore,
        appIdentity: DiagnosticAppIdentity = .current
    ) {
        self.store = store
        let root = NoonmarkAboutView(appIdentity: appIdentity)
            .environmentObject(store)
            .preferredColorScheme(.light)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.aboutApp
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.enableNoonmarkDynamicKeyViewLoop()
        window.installNoonmarkResizableHostingContent(
            root,
            minimumContentSize: Self.minimumContentSize
        )
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        window?.title = store.copy.aboutApp
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.aboutApp
    }
}

private struct NoonmarkAboutView: View {
    @EnvironmentObject private var store: NoonmarkStore
    @State private var didCopyVersionInformation = false

    let appIdentity: DiagnosticAppIdentity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.copy.appName)
                            .font(.noonmarkSystem(size: 26, weight: .bold))
                            .foregroundStyle(Theme.text1)
                        Text(appIdentity.versionSummary)
                            .font(.noonmarkSystem(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text2)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(store.copy.versionInformationTitle)
                        .font(.noonmarkSystem(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .accessibilityAddTraits(.isHeader)

                    Text(appIdentity.versionInformationText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "about.version-information"
                        )
                }

                if let poemText {
                    Divider()
                    Text(poemText)
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("about.poem")
                }

                HStack {
                    Spacer()
                    Button(
                        didCopyVersionInformation
                            ? store.copy.versionInformationCopied
                            : store.copy.copyVersionInformation
                    ) {
                        copyVersionInformation()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .accessibilityIdentifier(
                        "about.copy-version-information"
                    )
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
        }
        .background(Theme.background)
        .background {
            AppE2EViewAnchor(
                identifier: "about.window",
                verificationText: store.copy.aboutApp
            )
        }
    }

    private var poemText: String? {
        let policy = store.engine.preferences.settingsPoemDisplayPolicy
        let text = policy.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard policy.enabled, text.isEmpty == false else { return nil }
        return text
    }

    private func copyVersionInformation() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        didCopyVersionInformation = pasteboard.setString(
            appIdentity.versionInformationText,
            forType: .string
        )
    }
}

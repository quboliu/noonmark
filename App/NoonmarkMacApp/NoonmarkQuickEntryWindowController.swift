import AppKit
import SwiftUI

@MainActor
final class NoonmarkQuickEntryWindowController: NSWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.QuickEntryWindow")

    private let store: NoonmarkStore
    private let model = NoonmarkQuickEntryWindowModel()

    init(store: NoonmarkStore) {
        self.store = store
        let root = NoonmarkQuickEntryView(model: model)
            .environmentObject(store)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 168),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.windowIdentifier
        panel.title = store.copy.quickEntryTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.contentView = hostingView

        super.init(window: panel)
        model.onClose = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(onSubmit: @escaping (String) -> Bool) {
        model.onSubmit = onSubmit
        model.prepareForPresentation()
        window?.title = store.copy.quickEntryTitle
        positionOverMainWindow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.quickEntryTitle
    }

    private func positionOverMainWindow() {
        guard let panel = window,
              let mainWindow = NSApp.windows.first(where: { $0 is NoonmarkWindow })
        else {
            window?.center()
            return
        }
        let origin = NSPoint(
            x: mainWindow.frame.midX - panel.frame.width / 2,
            y: mainWindow.frame.midY - panel.frame.height / 2 + 80
        )
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class NoonmarkQuickEntryWindowModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var focusRequest = 0
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?

    func prepareForPresentation() {
        text = ""
        focusRequest &+= 1
    }

    func submit() {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            NSSound.beep()
            return
        }
        guard onSubmit?(normalized) == true else {
            NSSound.beep()
            return
        }
        onClose?()
    }
}

private struct NoonmarkQuickEntryView: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var model: NoonmarkQuickEntryWindowModel
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.copy.quickEntryTitle)
                    .font(.noonmarkSystem(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .accessibilityAddTraits(.isHeader)
                Text(store.copy.quickEntryTodayHint)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(store.copy.quickEntryPlaceholder, text: $model.text)
                .textFieldStyle(.roundedBorder)
                .font(.noonmarkSystem(size: 14))
                .focused($inputIsFocused)
                .onSubmit(model.submit)
                .accessibilityIdentifier("quick-entry.field")
                .background {
                    AppE2EViewAnchor(identifier: "quick-entry.field")
                }

            HStack {
                Spacer()
                Button(store.copy.cancel) {
                    model.onClose?()
                }
                .keyboardShortcut(.cancelAction)
                Button(store.copy.addTask) {
                    model.submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("quick-entry.add")
                .background {
                    AppE2EViewAnchor(identifier: "quick-entry.add")
                }
                .disabled(
                    model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
        .onAppear { inputIsFocused = true }
        .onChange(of: model.focusRequest) { _, _ in inputIsFocused = true }
        .background {
            AppE2EViewAnchor(
                identifier: "quick-entry.window",
                verificationText: store.copy.quickEntryTitle
            )
        }
    }
}

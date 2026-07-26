import AppKit
import Combine
import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

@MainActor
final class NoonmarkQuickEntryWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.QuickEntryWindow")

    private let store: NoonmarkStore
    private let model = NoonmarkQuickEntryWindowModel()
    private var contentHeightObservation: AnyCancellable?
    private var onDismiss: (() -> Void)?

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
        panel.enableNoonmarkDynamicKeyViewLoop()
        panel.contentView = hostingView

        super.init(window: panel)
        panel.delegate = self
        model.onClose = { [weak self] in self?.finishPresentation() }
        contentHeightObservation = model.$contentHeight
            .removeDuplicates()
            .sink { [weak panel] contentHeight in
                guard let panel else { return }
                let top = panel.frame.maxY
                panel.setContentSize(
                    NSSize(width: panel.contentView?.frame.width ?? 520, height: contentHeight)
                )
                var frame = panel.frame
                frame.origin.y = top - frame.height
                panel.setFrame(frame, display: true)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(onSubmit: @escaping (String) -> Bool) {
        present(
            onSubmit: onSubmit,
            onDismiss: nil
        )
    }

    func showFromGlobalShortcut(
        previousApplication: NSRunningApplication?,
        onSubmit: @escaping (String) -> Bool
    ) {
        present(
            onSubmit: onSubmit,
            onDismiss: {
                previousApplication?.activate(options: [])
            }
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finishPresentation()
        return false
    }

    private func present(
        onSubmit: @escaping (String) -> Bool,
        onDismiss: (() -> Void)?
    ) {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.requestFocus()
            return
        }

        model.onSubmit = onSubmit
        self.onDismiss = onDismiss
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

    private func finishPresentation() {
        guard window?.isVisible == true else { return }
        window?.orderOut(nil)
        model.onSubmit = nil
        let dismiss = onDismiss
        onDismiss = nil
        dismiss?()
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
    @Published fileprivate(set) var contentHeight: CGFloat = 168
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?

    func prepareForPresentation() {
        text = ""
        contentHeight = 168
        focusRequest &+= 1
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func updatePresentation(suggestionCount: Int, showsIssue: Bool) {
        let suggestionHeight = suggestionCount > 0
            ? CGFloat(min(suggestionCount, 4) * 28 + 12)
            : 0
        let issueHeight: CGFloat = showsIssue ? 28 : 0
        contentHeight = 168 + suggestionHeight + issueHeight
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

    private var suggestions: [ClassificationCatalogItemProjection] {
        Array(store.newTaskClassificationSuggestions(for: model.text).prefix(4))
    }

    private var activeToken: NewTaskClassificationToken? {
        store.newTaskClassificationToken(for: model.text)
    }

    private var issueMessage: String? {
        store.newTaskDraftIssueMessage(for: model.text)
    }

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

            if suggestions.isEmpty == false, let activeToken {
                NewTaskClassificationSuggestionList(
                    tokenKind: activeToken.kind,
                    suggestions: suggestions
                ) { suggestion in
                    model.text = store.completeNewTaskClassificationToken(
                        in: model.text,
                        with: suggestion.name
                    )
                }
            }

            if let issueMessage {
                Text(issueMessage)
                    .font(.noonmarkSystem(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warn)
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
                        || issueMessage != nil
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
        .onAppear { inputIsFocused = true }
        .onChange(of: model.focusRequest) { _, _ in inputIsFocused = true }
        .onChange(of: model.text, initial: true) { _, _ in
            model.updatePresentation(
                suggestionCount: suggestions.count,
                showsIssue: issueMessage != nil
            )
        }
        .background {
            AppE2EViewAnchor(
                identifier: "quick-entry.window",
                verificationText: store.copy.quickEntryTitle
            )
        }
    }
}

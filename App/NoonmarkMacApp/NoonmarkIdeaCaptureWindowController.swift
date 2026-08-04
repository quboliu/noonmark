import AppKit
import Combine
import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

@MainActor
final class NoonmarkIdeaCaptureWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.IdeaCaptureWindow")

    private let store: NoonmarkStore
    private let model: NoonmarkIdeaCaptureWindowModel
    private var contentHeightObservation: AnyCancellable?
    private var onDismiss: (() -> Void)?

    init(store: NoonmarkStore) {
        self.store = store
        model = NoonmarkIdeaCaptureWindowModel(
            session: store.ideaComposerSession
        )
        let root = NoonmarkIdeaCaptureView(model: model)
            .environmentObject(store)
            .preferredColorScheme(.light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 226),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.windowIdentifier
        panel.title = store.copy.ideaCapturePanelTitle
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
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            model.requestFocus()
            return
        }

        model.onSubmit = onSubmit
        self.onDismiss = onDismiss
        model.prepareForPresentation()
        window?.title = store.copy.ideaCapturePanelTitle
        positionOverMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.requestFocus()
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.ideaCapturePanelTitle
    }

    private func finishPresentation() {
        guard window?.isVisible == true else { return }
        model.session.dismiss()
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
final class NoonmarkIdeaCaptureWindowModel: ObservableObject {
    @Published private(set) var focusRequest = 0
    @Published fileprivate(set) var contentHeight: CGFloat = 226
    let session: IdeaComposerSession
    var onSubmit: ((String) -> Bool)?
    var onClose: (() -> Void)?

    init(session: IdeaComposerSession) {
        self.session = session
    }

    func prepareForPresentation() {
        if contentHeight != 226 {
            contentHeight = 226
        }
        focusRequest &+= 1
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    func updatePresentation(showsIssue: Bool) {
        let nextContentHeight: CGFloat = 226 + (showsIssue ? 28 : 0)
        guard contentHeight != nextContentHeight else { return }
        contentHeight = nextContentHeight
    }

    func submit() {
        guard session.submit(using: { [onSubmit] body in
            onSubmit?(body) == true
        }) else {
            NSSound.beep()
            return
        }
        onClose?()
    }
}

private struct NoonmarkIdeaCaptureView: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var model: NoonmarkIdeaCaptureWindowModel
    @ObservedObject private var session: IdeaComposerSession

    init(model: NoonmarkIdeaCaptureWindowModel) {
        self.model = model
        session = model.session
    }

    private var text: Binding<String> {
        Binding(
            get: { session.text },
            set: { session.updateText($0) }
        )
    }

    private var issueMessage: String? {
        store.ideaDraftIssueMessage(for: session.text)
            ?? session.failureMessage
    }

    private var composerState: FlylightComposerState {
        FlylightComposerState(
            session.submissionState,
            isDirty: session.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false,
            isInvalid: issueMessage != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.copy.ideaCapturePanelTitle)
                    .font(.noonmarkSystem(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .accessibilityAddTraits(.isHeader)
                Text(store.copy.ideaCapturePanelHint)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlylightComposerSurface(
                text: text,
                mode: .globalCapture,
                state: composerState,
                issueMessage: issueMessage,
                identifier: "idea-capture.field",
                placeholder: store.copy.ideaCapturePanelPlaceholder,
                primaryIdentifier: "idea-capture.add",
                secondaryIdentifier: "idea-capture.cancel",
                focusesOnAppear: true,
                focusRequest: model.focusRequest,
                onSubmit: model.submit,
                onSecondary: {
                    model.onClose?()
                }
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
        .onChange(of: issueMessage, initial: true) { _, _ in
            model.updatePresentation(showsIssue: issueMessage != nil)
        }
        .background {
            AppE2EViewAnchor(
                identifier: "idea-capture.window",
                verificationText: store.copy.ideaCapturePanelTitle
            )
        }
    }
}

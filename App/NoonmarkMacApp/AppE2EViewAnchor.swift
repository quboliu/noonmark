import AppKit
import SwiftUI

/// Passive geometry and state marker for real-App E2E interaction.
///
/// The anchor deliberately exposes no accessibility element and owns no action.
/// Pointer hit testing therefore continues through to the visible product control.
struct AppE2EViewAnchor: NSViewRepresentable {
    let identifier: String
    var verificationText: String?

    init(identifier: String, verificationText: String? = nil) {
        self.identifier = identifier
        self.verificationText = verificationText
    }

    func makeNSView(context: Context) -> AppE2EAnchorView {
        let view = AppE2EAnchorView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: AppE2EAnchorView, context: Context) {
        configure(view)
    }

    private func configure(_ view: AppE2EAnchorView) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.verificationText = verificationText
        view.setAccessibilityElement(false)
    }
}

final class AppE2EAnchorView: NSView {
    var verificationText: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

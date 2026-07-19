import AppKit
import SwiftUI

@MainActor
extension NSWindow {
    /// Installs SwiftUI content whose declared minimum is the single source of
    /// truth for this resizable window's AppKit size constraints.
    func installNoonmarkResizableHostingContent(
        _ rootView: some View,
        minimumContentSize: NSSize
    ) {
        let hostingView = NSHostingView(
            rootView: rootView.frame(
                minWidth: minimumContentSize.width,
                minHeight: minimumContentSize.height
            )
        )
        hostingView.sizingOptions = [.minSize]
        contentView = hostingView
        // Seed AppKit's initial window constraint before SwiftUI publishes the
        // same minimum during its first constraint pass.
        contentMinSize = minimumContentSize
    }
}

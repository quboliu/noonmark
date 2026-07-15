import AppKit

enum NoonmarkMainWindowState {
    static let identifier = NSUserInterfaceItemIdentifier("Noonmark.MainWindow")
    static let frameAutosaveName = "Noonmark.MainWindow.Frame"
    static let splitViewAutosaveName = "Noonmark.WorkspaceSplit"

    /// UI-state persistence is always active in production. E2E bundles opt in
    /// only for the dedicated restart probe so screenshots and unrelated probes
    /// continue to start from clean, deterministic geometry.
    static func persistenceEnabled(
        arguments: [String],
        bundleIdentifier: String?
    ) -> Bool {
        guard bundleIdentifier == "app.noonmark.mac.e2e" else { return true }
        return arguments.contains("--e2e-workspace-restoration")
    }

    static func resetSavedState(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "NSWindow Frame \(frameAutosaveName)")
        defaults.removeObject(
            forKey: "NSSplitView Subview Frames \(splitViewAutosaveName)"
        )
    }
}

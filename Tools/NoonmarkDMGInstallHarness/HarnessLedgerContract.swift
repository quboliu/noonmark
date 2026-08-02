import Foundation

enum HarnessLedgerContract {
    static func expectedPassSteps(
        for mode: NoonmarkDMGInstallHarness.Mode
    ) -> [String] {
        switch mode {
        case .preflight:
            ["arguments", "process", "exit-observer", "permissions", "complete"]
        case .exercise:
            [
                "arguments", "process", "exit-observer", "permissions",
                "activation", "target", "main-window", "settings-menu",
                "settings-window", "settings-close", "quick-entry-menu",
                "quick-entry-input", "quick-entry-add", "exercise-title-visible",
                "quit-menu", "quit", "complete"
            ]
        case .restart:
            [
                "arguments", "process", "exit-observer", "permissions",
                "activation", "target", "main-window", "restart-title-visible",
                "quit-menu", "quit", "complete"
            ]
        case .e2eInspect:
            [
                "arguments", "process", "exit-observer", "permissions",
                "activation", "target", "e2e-window", "e2e-remove-buttons",
                "complete"
            ]
        case .e2eMenuCommand:
            [
                "arguments", "process", "exit-observer", "permissions",
                "activation", "target", "e2e-window", "menu-bar", "menu-item",
                "menu-command", "completion", "complete"
            ]
        case .diagnosticExport:
            [
                "arguments", "process", "exit-observer", "permissions",
                "activation", "target", "diagnostic-locks-before-export",
                "diagnostic-window", "diagnostic-menu", "diagnostic-preview",
                "diagnostic-export-ui", "diagnostic-locks-after-export",
                "diagnostic-package", "diagnostic-lock-holder-exit", "complete"
            ]
        case .diagnosticExportScope:
            []
        }
    }
}

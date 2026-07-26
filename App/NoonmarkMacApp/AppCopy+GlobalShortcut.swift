extension AppCopy {
    var globalQuickEntryShortcutTitle: String {
        language == .chinese
            ? "全局快速记录"
            : "Global Quick Entry"
    }

    var globalQuickEntryShortcutEnabled: String {
        language == .chinese
            ? "启用全局快捷键"
            : "Enable global shortcut"
    }

    var globalQuickEntryShortcutRecorderHint: String {
        language == .chinese
            ? "点按后输入新组合"
            : "Click, then press a new combination"
    }

    var globalQuickEntryShortcutRecording: String {
        language == .chinese
            ? "请按快捷键…"
            : "Press shortcut…"
    }

    var globalQuickEntryShortcutUnsupportedKey: String {
        language == .chinese
            ? "请使用字母、数字或空格键"
            : "Use a letter, number, or Space"
    }

    var globalQuickEntryShortcutRestoreDefault: String {
        language == .chinese
            ? "恢复默认 ⌃⇧N"
            : "Restore default ⌃⇧N"
    }

    var globalQuickEntryShortcutActive: String {
        language == .chinese
            ? "已启用 · 未发现系统冲突"
            : "Enabled · No system conflict found"
    }

    var globalQuickEntryShortcutDisabled: String {
        language == .chinese ? "已关闭" : "Off"
    }

    var globalQuickEntryShortcutUnsafe: String {
        language == .chinese
            ? "未启用：至少使用两个修饰键，并包含 Control 或 Command。"
            : "Not enabled: use at least two modifiers including Control or Command."
    }

    var globalQuickEntryShortcutNoonmarkConflict: String {
        language == .chinese
            ? "与晷迹现有快捷键冲突，未启用。"
            : "Conflicts with a Noonmark shortcut and was not enabled."
    }

    var globalQuickEntryShortcutSystemConflict: String {
        language == .chinese
            ? "与 macOS 系统快捷键冲突，未启用。"
            : "Conflicts with a macOS system shortcut and was not enabled."
    }

    func globalQuickEntryShortcutRegistrationFailed(
        retainedShortcut: String?
    ) -> String {
        switch (language, retainedShortcut) {
        case let (.chinese, retainedShortcut?):
            "注册失败，已保留原快捷键 \(retainedShortcut)。"
        case (.chinese, nil):
            "注册失败，快捷键未启用。"
        case let (.english, retainedShortcut?):
            "Registration failed; \(retainedShortcut) remains active."
        case (.english, nil):
            "Registration failed; the shortcut is not enabled."
        }
    }

    var globalQuickEntryShortcutRunningBoundary: String {
        language == .chinese
            ? "晷迹运行时，即使主窗口关闭也可使用；完全退出晷迹后失效。应用内仍可使用 ⌘N。"
            : "Works while Noonmark is running, even with its main window closed. It stops after you quit Noonmark. ⌘N remains available inside the app."
    }

    var globalQuickEntryShortcutConflictBoundary: String {
        language == .chinese
            ? "macOS 无法列出所有 App 的自定义快捷键。晷迹不会改写其他 App 的快捷键设置；如果组合重复，可能两个 App 同时响应，也可能只有其中一个响应。保存后请在常用 App 中试按。"
            : "macOS cannot list every app-specific shortcut. Noonmark never changes another app’s shortcuts; if a combination overlaps, both apps may respond or only one may respond. Test it in the apps you use after saving."
    }
}

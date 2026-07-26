import AppKit
import NoonmarkMacRuntime
import SwiftUI

struct GlobalQuickEntryShortcutSettingsSection: View {
    @EnvironmentObject private var store: NoonmarkStore
    @EnvironmentObject private var coordinator:
        GlobalQuickEntryShortcutCoordinator

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.preference.isEnabled },
            set: { isEnabled in
                coordinator.apply(
                    GlobalQuickEntryShortcutPreference(
                        isEnabled: isEnabled,
                        shortcut: coordinator.preference.shortcut
                    )
                )
            }
        )
    }

    private var statusPresentation: (text: String, color: Color) {
        switch coordinator.status {
        case .active:
            (store.copy.globalQuickEntryShortcutActive, Theme.ok)
        case .disabled:
            (store.copy.globalQuickEntryShortcutDisabled, Theme.text3)
        case let .validationFailed(reason, retainedShortcut):
            (
                validationMessage(
                    reason,
                    retainedShortcut: retainedShortcut
                ),
                Theme.warn
            )
        case let .registrationFailed(retainedShortcut):
            (
                store.copy.globalQuickEntryShortcutRegistrationFailed(
                    retainedShortcut: retainedShortcut?.displayText
                ),
                Theme.warn
            )
        }
    }

    var body: some View {
        SettingSection(title: store.copy.globalQuickEntryShortcutTitle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle(
                        store.copy.globalQuickEntryShortcutEnabled,
                        isOn: enabledBinding
                    )
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(
                        "settings.preferences.global-shortcut.enabled"
                    )

                    Spacer()

                    GlobalShortcutRecorder(
                        shortcut: coordinator.preference.shortcut,
                        idleHint: store.copy
                            .globalQuickEntryShortcutRecorderHint,
                        recordingHint: store.copy
                            .globalQuickEntryShortcutRecording,
                        unsupportedKeyHint: store.copy
                            .globalQuickEntryShortcutUnsupportedKey
                    ) { shortcut in
                        coordinator.apply(
                            GlobalQuickEntryShortcutPreference(
                                isEnabled: true,
                                shortcut: shortcut
                            )
                        )
                    }
                    .frame(width: 158, height: 28)
                    .accessibilityIdentifier(
                        "settings.preferences.global-shortcut.recorder"
                    )
                }

                Text(statusPresentation.text)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(statusPresentation.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "settings.preferences.global-shortcut.status"
                    )

                Button(store.copy.globalQuickEntryShortcutRestoreDefault) {
                    coordinator.apply(
                        GlobalQuickEntryShortcutPreference(
                            isEnabled: coordinator.preference.isEnabled,
                            shortcut: .standard
                        )
                    )
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(
                    "settings.preferences.global-shortcut.restore-default"
                )

                Text(store.copy.globalQuickEntryShortcutRunningBoundary)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(store.copy.globalQuickEntryShortcutConflictBoundary)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func validationMessage(
        _ validation: GlobalQuickEntryShortcutValidation,
        retainedShortcut: GlobalQuickEntryShortcut?
    ) -> String {
        let message = switch validation {
        case .allowed:
            store.copy.globalQuickEntryShortcutActive
        case .unsafeModifierCombination:
            store.copy.globalQuickEntryShortcutUnsafe
        case .noonmarkCommandConflict:
            store.copy.globalQuickEntryShortcutNoonmarkConflict
        case .systemShortcutConflict:
            store.copy.globalQuickEntryShortcutSystemConflict
        case .conflictInspectionUnavailable:
            retainedShortcut == nil
                ? store.copy.globalQuickEntryShortcutInspectionUnavailable
                : store.copy
                    .globalQuickEntryShortcutCandidateInspectionUnavailable
        }
        guard let retainedShortcut else { return message }
        return switch store.copy.language {
        case .chinese:
            "\(message) 原快捷键 \(retainedShortcut.displayText) 仍然有效。"
        case .english:
            "\(message) \(retainedShortcut.displayText) remains active."
        }
    }
}

private struct GlobalShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalQuickEntryShortcut
    let idleHint: String
    let recordingHint: String
    let unsupportedKeyHint: String
    let onRecord: (GlobalQuickEntryShortcut) -> Void

    func makeNSView(context: Context) -> GlobalShortcutRecorderButton {
        let button = GlobalShortcutRecorderButton()
        button.identifier = NSUserInterfaceItemIdentifier(
            "settings.preferences.global-shortcut.recorder"
        )
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(
            GlobalShortcutRecorderButton.beginRecording
        )
        update(button)
        return button
    }

    func updateNSView(
        _ button: GlobalShortcutRecorderButton,
        context: Context
    ) {
        update(button)
    }

    private func update(_ button: GlobalShortcutRecorderButton) {
        button.shortcut = shortcut
        button.idleHint = idleHint
        button.recordingHint = recordingHint
        button.unsupportedKeyHint = unsupportedKeyHint
        button.onRecord = onRecord
        button.updateTitle()
    }
}

private final class GlobalShortcutRecorderButton: NSButton {
    var shortcut = GlobalQuickEntryShortcut.standard
    var idleHint = ""
    var recordingHint = ""
    var unsupportedKeyHint = ""
    var onRecord: ((GlobalQuickEntryShortcut) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    @objc
    func beginRecording() {
        isRecording = true
        toolTip = nil
        title = recordingHint
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        guard let key = GlobalShortcutKey(
            virtualKeyCode: event.keyCode
        )
        else {
            NSSound.beep()
            toolTip = unsupportedKeyHint
            return
        }

        let shortcut = GlobalQuickEntryShortcut(
            key: key,
            modifiers: GlobalShortcutModifiers(
                appKitFlags: event.modifierFlags
            )
        )
        finishRecording()
        onRecord?(shortcut)
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    func updateTitle() {
        guard isRecording == false else { return }
        title = shortcut.displayText
        toolTip = idleHint
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
    }
}
